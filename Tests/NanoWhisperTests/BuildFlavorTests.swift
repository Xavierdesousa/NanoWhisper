import AppKit
import Carbon
import Foundation
import Testing
@testable import NanoWhisper

@Suite("Build flavor")
struct BuildFlavorTests {

    // MARK: - Resolution

    @Test("Production bundle identifier resolves to production")
    func productionIdentifier() {
        #expect(BuildFlavor(bundleIdentifier: "com.moonji.nanowhisper") == .production)
    }

    @Test("Debug bundle identifier resolves to debug")
    func debugIdentifier() {
        #expect(BuildFlavor(bundleIdentifier: "com.moonji.nanowhisper.debug") == .debug)
    }

    @Test("Unbundled executable (no identifier) resolves to debug")
    func unbundled() {
        #expect(BuildFlavor(bundleIdentifier: nil) == .debug)
    }

    @Test("Any other identifier resolves to debug", arguments: [
        "", "com.apple.dt.xctest.tool", "com.moonji.NanoWhisper", "com.moonji.nanowhisper.beta",
    ])
    func otherIdentifiers(identifier: String) {
        #expect(BuildFlavor(bundleIdentifier: identifier) == .debug)
    }

    @Test("Each flavor resolves back from its own bundle identifier", arguments: BuildFlavor.allCases)
    func roundTrip(flavor: BuildFlavor) {
        #expect(BuildFlavor(bundleIdentifier: flavor.bundleIdentifier) == flavor)
    }

    @Test("Names and log subsystems")
    func names() {
        #expect(BuildFlavor.production.displayName == "NanoWhisper")
        #expect(BuildFlavor.debug.displayName == "NanoWhisper Debug")
        #expect(BuildFlavor.production.logSubsystem == "com.moonji.nanowhisper")
        #expect(BuildFlavor.debug.logSubsystem == "com.moonji.nanowhisper.debug")
    }

    // MARK: - History directory

    @Test("History folders: production keeps its existing path, debug gets its own")
    func historyDirectories() {
        let base = URL(fileURLWithPath: "/Users/test/Library/Application Support", isDirectory: true)
        let production = BuildFlavor.production.supportDirectory(in: base)
        let debug = BuildFlavor.debug.supportDirectory(in: base)
        #expect(production.path == "/Users/test/Library/Application Support/NanoWhisper")
        #expect(debug.path == "/Users/test/Library/Application Support/NanoWhisper Debug")
        #expect(production != debug)
    }

    // MARK: - Temporary recordings

    @Test("Temp recording prefixes: production unchanged, neither prefix matches the other")
    func temporaryPrefixes() {
        let production = BuildFlavor.production.temporaryAudioFilePrefix
        let debug = BuildFlavor.debug.temporaryAudioFilePrefix
        #expect(production == "nanowhisper_")
        #expect(!debug.hasPrefix(production))
        #expect(!production.hasPrefix(debug))
    }

    @Test("Each flavor only cleans up its own recordings")
    func temporaryOwnership() {
        let id = UUID()
        let productionFile = BuildFlavor.production.temporaryAudioFileName(id: id)
        let debugFile = BuildFlavor.debug.temporaryAudioFileName(id: id)
        #expect(productionFile == "nanowhisper_\(id.uuidString).wav")

        #expect(BuildFlavor.production.ownsTemporaryAudioFile(named: productionFile))
        #expect(!BuildFlavor.production.ownsTemporaryAudioFile(named: debugFile))
        #expect(BuildFlavor.debug.ownsTemporaryAudioFile(named: debugFile))
        #expect(!BuildFlavor.debug.ownsTemporaryAudioFile(named: productionFile))
        #expect(!BuildFlavor.debug.ownsTemporaryAudioFile(named: "nanowhisper-debug_notes.txt"))
    }

    @Test("Released production builds (cleanup rule before flavors) never delete debug recordings")
    func legacyCleanupRule() {
        // v0.0.4 deletes every temp file with prefix "nanowhisper_" and extension "wav" at launch.
        let debugFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(BuildFlavor.debug.temporaryAudioFileName())
        let matchedByLegacyRule = debugFile.lastPathComponent.hasPrefix("nanowhisper_")
            && debugFile.pathExtension == "wav"
        #expect(!matchedByLegacyRule)
    }

    // MARK: - Shortcut

    @Test("Default shortcuts: ⌥Space in production, ⌃⌥Space in debug")
    func defaultShortcuts() {
        let production = BuildFlavor.production.defaultShortcut
        let debug = BuildFlavor.debug.defaultShortcut
        #expect(production == Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)))
        #expect(debug == Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | controlKey)))
        #expect(production != debug)
    }

    // MARK: - Auto-updater

    @Test("Auto-updates only in production")
    func autoUpdatesFlag() {
        #expect(BuildFlavor.production.autoUpdatesEnabled)
        #expect(!BuildFlavor.debug.autoUpdatesEnabled)
    }

    @Test("A disabled updater neither checks nor installs")
    @MainActor
    func disabledUpdater() async {
        let updater = AutoUpdater(isEnabled: false)
        updater.startPeriodicChecks()
        await updater.checkForUpdates()
        #expect(updater.latestVersion == nil)
        #expect(updater.error == nil)
        await updater.downloadAndInstall()
        // An enabled updater with no release would report "No download URL available".
        #expect(updater.error == nil)
        #expect(!updater.isDownloading)
    }
}

@Suite("Build info")
struct BuildInfoTests {

    @Test("Version and commit")
    func versionAndCommit() {
        let info = BuildInfo(infoDictionary: ["CFBundleShortVersionString": "0.0.4", "NWGitCommit": "abc1234"])
        #expect(info.summary == "v0.0.4 · abc1234")
    }

    @Test("Version only (production bundle has no commit)")
    func versionOnly() {
        #expect(BuildInfo(infoDictionary: ["CFBundleShortVersionString": "0.0.4"]).summary == "v0.0.4")
        #expect(BuildInfo(infoDictionary: ["CFBundleShortVersionString": "0.0.4", "NWGitCommit": ""]).summary == "v0.0.4")
    }

    @Test("Unbundled build")
    func unbundled() {
        #expect(BuildInfo(infoDictionary: nil).summary == "unbundled build")
    }
}

@Suite("Debug menu bar icon")
struct MenuBarIconTests {

    /// Renders `image` at 2x under `appearance` and returns the bitmap.
    private func render(_ image: NSImage, appearance: NSAppearance.Name) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = MenuBarIcon.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: MenuBarIcon.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// A fully opaque square template glyph.
    private var solidGlyph: NSImage {
        let glyph = NSImage(size: MenuBarIcon.size, flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        glyph.isTemplate = true
        return glyph
    }

    @Test("Glyph follows the appearance, badge stays orange")
    func adaptsToAppearance() throws {
        let icon = MenuBarIcon.badged(solidGlyph)
        #expect(!icon.isTemplate)

        // Top-left area: glyph only. Bottom-right (pixel rows count from the top): badge.
        let light = render(icon, appearance: .aqua)
        let dark = render(icon, appearance: .darkAqua)
        let lightGlyph = try #require(light.colorAt(x: 6, y: 6)?.usingColorSpace(.sRGB))
        let darkGlyph = try #require(dark.colorAt(x: 6, y: 6)?.usingColorSpace(.sRGB))
        #expect(lightGlyph.brightnessComponent < 0.3)
        #expect(darkGlyph.brightnessComponent > 0.7)

        for rep in [light, dark] {
            let badge = try #require(rep.colorAt(x: 36 - 6, y: 36 - 6)?.usingColorSpace(.sRGB))
            #expect(badge.redComponent > 0.9)
            #expect(badge.greenComponent > 0.4 && badge.greenComponent < 0.7)
            #expect(badge.blueComponent < 0.2)
        }
    }

    @Test("A transparent ring separates the badge from the glyph")
    func badgeGap() {
        let rep = render(MenuBarIcon.badged(solidGlyph), appearance: .aqua)
        // Just outside the badge circle, along its top-left diagonal.
        let badge = MenuBarIcon.badgeRect
        let radius = badge.width / 2
        let offset = (radius + MenuBarIcon.badgeGap / 2) / 2.squareRoot()
        let x = Int(((badge.midX - offset) * 2).rounded())
        let yFromTop = Int(((MenuBarIcon.size.height - (badge.midY + offset)) * 2).rounded())
        #expect((rep.colorAt(x: x, y: yFromTop)?.alphaComponent ?? 1) < 0.5)
    }
}
