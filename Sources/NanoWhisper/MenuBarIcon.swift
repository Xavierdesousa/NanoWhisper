import AppKit

/// Menu bar icon marker for debug builds: the usual monochrome glyph plus an orange dot
/// in the bottom-right corner.
///
/// A template image cannot carry a color, so the badged icon is a regular image whose
/// drawing handler paints the glyph in `labelColor`. The handler runs at draw time with
/// the status item's appearance, so the glyph stays black on a light menu bar and white
/// on a dark one, like a template image. A transparent ring cut around the dot separates
/// it from the glyph; orange reads on both light and dark menu bars.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)
    static var badgeColor: NSColor { NSColor(srgbRed: 1.0, green: 0.55, blue: 0.0, alpha: 1) }
    static let badgeDiameter: CGFloat = 6.5
    static let badgeGap: CGFloat = 1.25

    /// Badge frame in the icon's (unflipped) coordinate space.
    static var badgeRect: NSRect {
        NSRect(x: size.width - badgeDiameter, y: 0, width: badgeDiameter, height: badgeDiameter)
    }

    /// `glyph` drawn in the label color with the debug badge. Square glyphs fill the icon;
    /// other aspect ratios (SF Symbols) are centered at their natural size, scaled down to fit.
    static func badged(_ glyph: NSImage) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            context.beginTransparencyLayer(auxiliaryInfo: nil)
            glyph.draw(in: glyphRect(for: glyph.size, in: rect), from: .zero, operation: .sourceOver, fraction: 1)
            // Recolor the glyph's opaque pixels with the appearance's label color.
            NSColor.labelColor.setFill()
            rect.fill(using: .sourceIn)
            // Cut a transparent ring around the badge.
            context.setBlendMode(.clear)
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -badgeGap, dy: -badgeGap)).fill()
            context.endTransparencyLayer()

            badgeColor.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "NanoWhisper Debug"
        return image
    }

    /// Badged SF Symbol (used for the setup / loading states).
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
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}
