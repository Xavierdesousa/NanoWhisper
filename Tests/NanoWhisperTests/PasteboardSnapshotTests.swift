import AppKit
import Testing
@testable import NanoWhisper

/// Saving and restoring the clipboard around a paste. Private pasteboards only, never the
/// general one; nothing is pasted.
@Suite("Clipboard around a paste")
@MainActor
final class PasteboardSnapshotTests {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("nanowhisper.tests.paste.\(UUID().uuidString)"))

    isolated deinit {
        pasteboard.releaseGlobally()
    }

    private typealias Entry = PasteboardSnapshot.TypedData

    private func write(_ items: [[(NSPasteboard.PasteboardType, Data)]]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        })
    }

    private var contents: [[Entry]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.map { Entry(type: $0, data: item.data(forType: $0) ?? Data()) }
        }
    }

    private func utf8(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - The dictated text

    @Test("The dictated text is plain text, marked transient and confidential")
    func textIsMarked() {
        _ = BorrowedClipboard(pasteboard: pasteboard).put("Dictée")
        #expect(pasteboard.string(forType: .string) == "Dictée")
        #expect(pasteboard.pasteboardItems?.count == 1)
        let types = pasteboard.types ?? []
        #expect(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
        #expect(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
        #expect(pasteboard.canReadObject(forClasses: [NSString.self], options: nil), "an ordinary paste reads it")
    }

    // MARK: - Restoring

    @Test("Everything comes back: several items, every type in order, markers, images, files, rich text")
    func restoresEverything() throws {
        let png = NSPasteboard.PasteboardType.png
        write([
            [(.rtf, utf8(#"{\rtf1 a}"#)), (.html, utf8("<b>a</b>")), (.string, utf8("a"))],
            [(.fileURL, utf8("file:///etc/hosts")), (png, Data([0x89, 0x50, 0, 1]))],
            [(.string, utf8("secret")), (.nspasteboardConcealed, Data()), (NSPasteboard.PasteboardType("org.nspasteboard.source"), utf8("com.example"))],
            [(NSPasteboard.PasteboardType("com.example.private-format"), Data((0..<255).map { UInt8($0) }))],
        ])
        let before = contents
        let clipboard = BorrowedClipboard(pasteboard: pasteboard)
        let count = clipboard.put("text")
        #expect(contents != before)
        clipboard.giveBack(ifUnchangedSince: count)
        #expect(contents == before)
        // The system adds its own conversions of the text next to the types we wrote.
        #expect(Set(contents[0].map(\.type)).isSuperset(of: [.rtf, .html, .string]))
        #expect(contents[2].map(\.type).contains(.nspasteboardConcealed))
    }

    @Test("An empty clipboard is empty again")
    func restoresEmpty() {
        pasteboard.clearContents()
        let clipboard = BorrowedClipboard(pasteboard: pasteboard)
        clipboard.giveBack(ifUnchangedSince: clipboard.put("text"))
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(contents.isEmpty)
    }

    @Test("A clipboard changed since our write is left alone")
    func changedClipboardKept() {
        write([[(.string, utf8("before"))]])
        let clipboard = BorrowedClipboard(pasteboard: pasteboard)
        let count = clipboard.put("text")
        write([[(.string, utf8("copied by the user"))]])
        let changeCount = pasteboard.changeCount
        clipboard.giveBack(ifUnchangedSince: count)
        #expect(pasteboard.string(forType: .string) == "copied by the user")
        #expect(pasteboard.changeCount == changeCount)
    }

    @Test("Two dictations in a row: the second gives back what was there before the first")
    func overlappingDictations() {
        write([[(.string, utf8("before"))]])
        let clipboard = BorrowedClipboard(pasteboard: pasteboard)
        let first = clipboard.put("one")
        let second = clipboard.put("two")
        clipboard.giveBack(ifUnchangedSince: first)
        #expect(pasteboard.string(forType: .string) == "two", "still needed by the second paste")
        clipboard.giveBack(ifUnchangedSince: second)
        #expect(pasteboard.string(forType: .string) == "before")
    }

    @Test("A copy between two dictations is what the second gives back")
    func copyBetweenDictations() {
        write([[(.string, utf8("before"))]])
        let clipboard = BorrowedClipboard(pasteboard: pasteboard)
        let first = clipboard.put("one")
        write([[(.string, utf8("copied"))]])
        let second = clipboard.put("two")
        clipboard.giveBack(ifUnchangedSince: first)
        clipboard.giveBack(ifUnchangedSince: second)
        #expect(pasteboard.string(forType: .string) == "copied")
    }

    // MARK: - Bounds

    @Test("A type over the size bound is dropped; the item's others, its text and its markers stay")
    func sizeBound() {
        let big = NSPasteboard.PasteboardType("com.example.big")
        write([[(big, Data(count: 5000)), (.html, utf8("<b>a</b>")), (.string, utf8("a")), (.nspasteboardConcealed, Data())]])
        let snapshot = PasteboardSnapshot(of: pasteboard, limits: .init(maximumBytes: 1000))
        #expect(snapshot.items.map { $0.map(\.type) } == [[.html, .string, .nspasteboardConcealed]])
        #expect(snapshot.droppedTypes == 1)
        #expect(snapshot.isMarkedPrivate)
    }

    @Test("An item that cannot be kept: only the plain text comes back, with the markers")
    func lostItem() {
        write([
            [(.string, utf8("name")), (.nspasteboardConcealed, Data())],
            [(.png, Data(count: 5000))],
            [(.html, utf8("<i>c</i>"))],
        ])
        let snapshot = PasteboardSnapshot(of: pasteboard, limits: .init(maximumBytes: 1000))
        snapshot.restore(to: pasteboard)
        #expect(contents.count == 1)
        #expect(pasteboard.string(forType: .string) == "name")
        #expect(contents[0].map(\.type) == [.string, .nspasteboardConcealed])
    }

    @Test("A single image over the bound is not kept: nothing is restored")
    func lostImage() {
        write([[(.png, Data(count: 5000))]])
        let snapshot = PasteboardSnapshot(of: pasteboard, limits: .init(maximumBytes: 1000))
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.droppedTypes == 1)
    }

    /// Delivers promised data when asked, after a delay.
    private final class Provider: NSObject, NSPasteboardItemDataProvider {
        let delay: TimeInterval
        var asked: [NSPasteboard.PasteboardType] = []
        init(delay: TimeInterval = 0) { self.delay = delay }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            asked.append(type)
            Thread.sleep(forTimeInterval: delay)
            item.setData(Data(type.rawValue.utf8), forType: type)
        }
    }

    @Test("Promised data is delivered and kept")
    func promisedData() {
        let provider = Provider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.html, .string])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let snapshot = PasteboardSnapshot(of: pasteboard)
        #expect(snapshot.items == [[
            Entry(type: .html, data: Data(NSPasteboard.PasteboardType.html.rawValue.utf8)),
            Entry(type: .string, data: Data(NSPasteboard.PasteboardType.string.rawValue.utf8)),
        ]])
        #expect(snapshot.droppedTypes == 0)
    }

    @Test("A slow owner: the plain text is asked for first, the rest until the time bound")
    func timeBound() {
        let provider = Provider(delay: 0.05)
        let item = NSPasteboardItem()
        let formats = (0..<40).map { NSPasteboard.PasteboardType("com.example.format\($0)") }
        item.setDataProvider(provider, forTypes: formats + [.string])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let snapshot = PasteboardSnapshot(of: pasteboard, limits: .init(maximumDuration: 0.3))
        #expect(provider.asked.first == .string)
        #expect(provider.asked.count < formats.count, "stopped at the bound")
        #expect(snapshot.items.first?.last?.type == .string)
        #expect(snapshot.droppedTypes > 0)
    }

    @Test("File promises are not asked for; content of another device keeps its plain text only")
    func promisesAndRemote() {
        write([[(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"), utf8("file:///x"))]])
        #expect(PasteboardSnapshot(of: pasteboard).items.isEmpty)

        write([[(.remoteClipboard, Data()), (.png, Data(count: 10)), (.string, utf8("a"))]])
        #expect(PasteboardSnapshot(of: pasteboard).items == [[Entry(type: .string, data: utf8("a"))]])
    }
}
