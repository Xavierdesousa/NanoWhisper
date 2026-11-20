import AppKit

/// Menu bar icon marker for debug builds: the usual monochrome glyph crossed by an orange
/// band across its full width, like the "DEBUG" banner on the debug app icon (no text: it
/// would be unreadable at this size).
///
/// A template image cannot carry a color, so the marked icon is a regular image whose
/// drawing handler paints the glyph in `labelColor`. The handler runs at draw time with
/// the status item's appearance, so the glyph stays black on a light menu bar and white
/// on a dark one, like a template image. A transparent gap cut above and below the band
/// separates it from the glyph; orange reads on both light and dark menu bars.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)
    static var bandColor: NSColor { NSColor(srgbRed: 1.0, green: 0.55, blue: 0.0, alpha: 1) }
    /// Darker edge lines, so the band keeps its outline on a light menu bar.
    static var bandEdgeColor: NSColor { NSColor(srgbRed: 0.78, green: 0.33, blue: 0.0, alpha: 1) }
    static let bandGap: CGFloat = 1

    /// Band frame in the icon's (unflipped) coordinate space: full width, across the bottom
    /// of the glyph (no sliver of glyph is left below it), on whole points so it stays crisp
    /// at 1x.
    static var bandRect: NSRect {
        NSRect(x: 0, y: 1, width: size.width, height: 4)
    }

    /// `glyph` drawn in the label color with the debug band. Square glyphs fill the icon;
    /// other aspect ratios (SF Symbols) are centered at their natural size, scaled down to fit.
    static func badged(_ glyph: NSImage) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            context.beginTransparencyLayer(auxiliaryInfo: nil)
            glyph.draw(in: glyphRect(for: glyph.size, in: rect), from: .zero, operation: .sourceOver, fraction: 1)
            // Recolor the glyph's opaque pixels with the appearance's label color.
            NSColor.labelColor.setFill()
            rect.fill(using: .sourceIn)
            // Cut a transparent gap around the band.
            context.setBlendMode(.clear)
            bandRect.insetBy(dx: 0, dy: -bandGap).fill()
            context.endTransparencyLayer()

            bandColor.setFill()
            bandRect.fill()
            bandEdgeColor.setFill()
            NSRect(x: bandRect.minX, y: bandRect.minY, width: bandRect.width, height: 0.5).fill()
            NSRect(x: bandRect.minX, y: bandRect.maxY - 0.5, width: bandRect.width, height: 0.5).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "NanoWhisper Debug"
        return image
    }

    /// Marked SF Symbol (used for the setup / loading states).
    static func badged(systemSymbolName name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        return badged(symbol)
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    /// Returns the image cached under `key`, creating it once. The menu bar label is
    /// re-evaluated on every app state change; reusing the image avoids redrawing it.
    @MainActor static func cached(_ key: String, make: () -> NSImage?) -> NSImage? {
        if let image = cache[key] { return image }
        let image = make()
        cache[key] = image
        return image
    }

    private static func glyphRect(for glyphSize: NSSize, in rect: NSRect) -> NSRect {
        guard glyphSize.width > 0, glyphSize.height > 0,
              abs(glyphSize.width - glyphSize.height) > 0.5 else { return rect }
        let scale = min(1, rect.width / glyphSize.width, rect.height / glyphSize.height)
        let width = glyphSize.width * scale, height = glyphSize.height * scale
        // Whole-point origin, so the glyph's strokes land on pixels at 1x.
        return NSRect(x: (rect.midX - width / 2).rounded(), y: (rect.midY - height / 2).rounded(),
                      width: width, height: height)
    }
}
