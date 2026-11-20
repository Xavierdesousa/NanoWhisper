import AppKit
import SwiftUI

/// A key combination drawn the usual macOS way: one small flat rounded box per key, with a
/// thin border and the glyph inside (⌥ ⌘ Y). No fill, no shadow, no 3D. The one view used
/// wherever the app shows the shortcut: Settings, the menu bar menu, onboarding's Try-it row.
struct ShortcutKeysView: View {
    let shortcut: Shortcut
    var size: KeyCapSize = .regular
    /// Draws glyphs and borders in this color instead of the default ones (a highlighted
    /// menu item draws them white).
    var color: Color?

    var body: some View {
        HStack(spacing: size.spacing) {
            ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { _, key in
                KeyCapView(glyph: key.glyph, size: size, color: color)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shortcut \(shortcut.spokenDescription)")
    }
}

/// Size of a key cap. Design spec (Settings build notes): 20 pt caps with an 11.5 pt glyph;
/// 16 pt caps with a 10 pt glyph in captions and menus.
enum KeyCapSize {
    case regular
    case small

    var height: CGFloat { self == .regular ? 20 : 16 }
    var fontSize: CGFloat { self == .regular ? 11.5 : 10 }
    var cornerRadius: CGFloat { self == .regular ? 5 : 4 }
    var spacing: CGFloat { self == .regular ? 3 : 2 }
    var horizontalPadding: CGFloat { self == .regular ? 5 : 4 }
}

/// One key: the glyph in a flat rounded box with a 1 pt border.
struct KeyCapView: View {
    let glyph: String
    var size: KeyCapSize = .regular
    var color: Color?

    var body: some View {
        Text(glyph)
            .font(.system(size: size.fontSize, weight: .medium))
            .foregroundStyle(color ?? Self.glyphColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size.horizontalPadding)
            .frame(minWidth: size.height, minHeight: size.height, maxHeight: size.height)
            .overlay(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .strokeBorder(color.map { $0.opacity(0.6) } ?? Self.borderColor, lineWidth: 1)
            )
    }

    /// #3C3C43 on light, white 85 % on dark.
    static let glyphColor = Color(nsColor: NSColor(name: "nwKeyGlyph") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.85)
            : NSColor(srgbRed: 0x3C / 255, green: 0x3C / 255, blue: 0x43 / 255, alpha: 1)
    })

    /// Black 22 % on light, white 28 % on dark.
    static let borderColor = Color(nsColor: NSColor(name: "nwKeyBorder") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.28)
            : NSColor(white: 0, alpha: 0.22)
    })
}
