import AppKit

/// What a pasteboard held, copied so it can be put back: every item with every type, in order,
/// markers included (`org.nspasteboard.*`, https://nspasteboard.org).
///
/// Copying makes the owner of the content deliver the data it had only promised, so the copy is
/// bounded (`Limits`). Markers and plain text are read first; then the other types, in the
/// owner's order (richest first). Beyond a bound:
/// - a type that does not fit in `maximumBytes` is not kept (the item's others are);
/// - after `maximumDuration` nothing more is read (checked between two types: one read that
///   the owner answers slowly cannot be interrupted);
/// - if an item would come back without any content (or is a file promise, which only its owner
///   can fulfill), only the plain text is put back, with the markers; without plain text,
///   nothing is.
struct PasteboardSnapshot: Equatable, Sendable {
    struct Limits: Sendable {
        /// Total size of the copied data: a full-screen uncompressed image of a 6K display fits.
        var maximumBytes = 128 * 1024 * 1024
        var maximumDuration: TimeInterval = 0.5
    }

    struct TypedData: Equatable, Sendable {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    /// The items to put back, each with its types in their original order.
    private(set) var items: [[TypedData]] = []
    /// Types that were not kept (too large, too late, not delivered, or a promise).
    private(set) var droppedTypes = 0

    /// The content asked not to be recorded.
    var isMarkedPrivate: Bool {
        items.joined().contains { $0.type == .nspasteboardConcealed || $0.type == .nspasteboardTransient }
    }

    init(of pasteboard: NSPasteboard, limits: Limits = Limits()) {
        guard let sources = pasteboard.pasteboardItems, !sources.isEmpty else { return }
        let deadline = ContinuousClock.now + .seconds(limits.maximumDuration)
        // Plain text on its own, as a fallback. Several items give their text joined.
        let text = pasteboard.string(forType: .string)
        let sourceTypes = sources.map(\.types)
        var kept: [[NSPasteboard.PasteboardType: Data]] = Array(repeating: [:], count: sources.count)
        var bytes = 0

        // Markers have no content (some apps declare them without any data).
        for (index, types) in sourceTypes.enumerated() {
            for type in types where type.isNSPasteboardMarker {
                let data = sources[index].data(forType: type) ?? Data()
                // The marker itself is always kept.
                let fits = bytes + data.count <= limits.maximumBytes
                kept[index][type] = fits ? data : Data()
                bytes += fits ? data.count : 0
            }
        }

        func read(_ type: NSPasteboard.PasteboardType, of index: Int) {
            guard ContinuousClock.now < deadline, let data = sources[index].data(forType: type),
                  bytes + data.count <= limits.maximumBytes else { return }
            bytes += data.count
            kept[index][type] = data
        }
        for (index, types) in sourceTypes.enumerated() where types.contains(.string) {
            read(.string, of: index)
        }
        // Content on another device (Universal Clipboard) is downloaded when it is read: only
        // its plain text is.
        if !sourceTypes.joined().contains(.remoteClipboard) {
            for (index, types) in sourceTypes.enumerated() {
                for type in types where kept[index][type] == nil && !type.isFilePromise {
                    read(type, of: index)
                }
            }
        }

        var lostItem = false
        for (index, types) in sourceTypes.enumerated() {
            let item = types.compactMap { type in kept[index][type].map { TypedData(type: type, data: $0) } }
            let contentTypes = types.filter { !$0.isNSPasteboardMarker && $0 != .remoteClipboard }
            let keptContent = item.count { !$0.type.isNSPasteboardMarker }
            droppedTypes += contentTypes.count - keptContent
            lostItem = lostItem || (!contentTypes.isEmpty && keptContent == 0)
            if !item.isEmpty { items.append(item) }
        }
        guard lostItem else { return }

        var fallback: [TypedData] = []
        if let text {
            fallback.append(TypedData(type: .string, data: Data(text.utf8)))
            for entry in items.joined() where entry.type.isNSPasteboardMarker
                && !fallback.contains(where: { $0.type == entry.type }) {
                fallback.append(entry)
            }
        }
        items = fallback.isEmpty ? [] : [fallback]
    }

    /// Replaces the content of `pasteboard`. An empty snapshot empties it. Content marked
    /// private is put back for this Mac only (not for Universal Clipboard).
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.prepareForNewContents(with: isMarkedPrivate ? .currentHostOnly : [])
        let objects = items.map { item in
            let object = NSPasteboardItem()
            for entry in item {
                object.setData(entry.data, forType: entry.type)
            }
            return object
        }
        if !objects.isEmpty {
            pasteboard.writeObjects(objects)
        }
    }
}

extension NSPasteboard.PasteboardType {
    /// The content is on the pasteboard for a moment only: clipboard managers skip it.
    static let nspasteboardTransient = Self("org.nspasteboard.TransientType")
    /// The content is confidential: clipboard managers do not record or show it.
    static let nspasteboardConcealed = Self("org.nspasteboard.ConcealedType")
    /// Set by the system on content that comes from another device.
    static let remoteClipboard = Self("com.apple.is-remote-clipboard")

    var isNSPasteboardMarker: Bool { rawValue.hasPrefix("org.nspasteboard.") }

    /// `NSFilePromiseProvider` types: useless without their owner.
    var isFilePromise: Bool {
        rawValue.hasPrefix("com.apple.pasteboard.promised-") || rawValue == "com.apple.NSFilePromiseItemMetaData"
    }
}
