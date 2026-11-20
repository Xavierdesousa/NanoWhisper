import Foundation
import Testing
@testable import NanoWhisper

/// Text contrast of the translucent overlay (WCAG 2 relative luminance), with the HUD material
/// ignored: the surface alone over the wallpaper. The real material darkens and blurs the
/// wallpaper first, so these are lower bounds. Worst cases are light wallpapers.
@Suite("Overlay contrast")
struct OverlayContrastTests {
    typealias RGB = (r: Double, g: Double, b: Double)

    static func rgb(_ hex: UInt32) -> RGB {
        (Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
    }

    static func over(_ top: RGB, _ alpha: Double, _ bottom: RGB) -> RGB {
        (alpha * top.r + (1 - alpha) * bottom.r,
         alpha * top.g + (1 - alpha) * bottom.g,
         alpha * top.b + (1 - alpha) * bottom.b)
    }

    static func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double {
            let s = v / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// White, a light gray, a pale yellow and a light sky blue (bright wallpapers), and black.
    static let wallpapers: [UInt32] = [0xFFFFFF, 0xE5E5EA, 0xFFE45C, 0x9FD3FF, 0x000000]

    static let white = rgb(0xFFFFFF)

    /// Lowest contrast of a text color (with its opacity) over the surface, across wallpapers.
    static func worstContrast(text: RGB, opacity: Double) -> Double {
        wallpapers.map { wallpaper in
            let background = over(rgb(OverlayPalette.surfaceColor), OverlayPalette.surfaceOpacity, rgb(wallpaper))
            return ratio(over(text, opacity, background), background)
        }.min() ?? 0
    }

    @Test("Text, tail, timer and labels stay at 4.5:1 or more on the worst wallpaper")
    func textContrast() {
        for (name, opacity) in [
            ("text", OverlayPalette.textOpacity), ("tail", OverlayPalette.tailOpacity),
            ("timer", OverlayPalette.timerOpacity), ("stopped timer", OverlayPalette.timerStoppedOpacity),
        ] {
            let contrast = Self.worstContrast(text: Self.white, opacity: opacity)
            #expect(contrast >= 4.5, "\(name): \(contrast)")
        }
        let transcribing = Self.worstContrast(text: Self.rgb(OverlayPalette.transcribingLabelColor), opacity: 1)
        #expect(transcribing >= 4.5, "Transcribing…: \(transcribing)")
    }

    @Test("The surface is translucent, and the tail stays dimmer than the settled text")
    func translucent() {
        #expect(OverlayPalette.surfaceOpacity < 0.85)
        #expect(OverlayPalette.tailOpacity < OverlayPalette.textOpacity - 0.2)
    }
}
