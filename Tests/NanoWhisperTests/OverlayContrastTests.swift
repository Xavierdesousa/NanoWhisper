import AppKit
import Foundation
import SwiftUI
import Testing
@testable import NanoWhisper

/// Text contrast of the translucent overlay (WCAG 2 relative luminance), dark and light: the
/// text at its opacity over the surface, the surface at its opacity over each wallpaper, no
/// blur counted (lower bounds). With Reduce Transparency, the opaque surface. The method of the
/// light design's notes (`ovl-light-notes`), which list the figures this reproduces.
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
    static let plainWallpapers: [UInt32] = [0xFFFFFF, 0xE5E5EA, 0xFFE45C, 0x9FD3FF, 0x000000]
    /// Six saturated wallpapers (the light design's notes): navy, raspberry, forest green,
    /// purple, red, orange.
    static let saturatedWallpapers: [UInt32] = [0x0A2A6B, 0xC2185B, 0x1B5E20, 0x4A1A8C, 0xE53935, 0xFF7A00]
    static var wallpapers: [UInt32] { plainWallpapers + saturatedWallpapers }

    /// Every text of the overlay: its colour and opacity in `colors`.
    static func texts(_ colors: OverlayColors) -> [(name: String, hex: UInt32, opacity: Double)] {
        [
            ("settled text", colors.ink, colors.textOpacity),
            ("tail", colors.ink, colors.tailOpacity),
            ("timer", colors.ink, colors.timerOpacity),
            ("stopped timer", colors.ink, colors.timerStoppedOpacity),
            ("result label", colors.ink, colors.labelOpacity),
            ("Transcribing…", colors.transcribingLabel, 1),
        ]
    }

    /// Contrast of a text over the surface laid on `wallpaper`.
    static func contrast(hex: UInt32, opacity: Double, colors: OverlayColors, wallpaper: UInt32) -> Double {
        let surface = over(rgb(colors.surface.hex), colors.surface.opacity, rgb(wallpaper))
        return ratio(over(rgb(hex), opacity, surface), surface)
    }

    /// With Reduce Transparency the surface is opaque: the wallpaper does not matter.
    static func solidContrast(hex: UInt32, opacity: Double, colors: OverlayColors) -> Double {
        let surface = rgb(colors.solidSurface.hex)
        return ratio(over(rgb(hex), opacity, surface), surface)
    }

    /// The lowest contrast of a text across the wallpapers, and the wallpaper giving it.
    static func worst(hex: UInt32, opacity: Double, colors: OverlayColors) -> (ratio: Double, wallpaper: UInt32) {
        wallpapers.map { (contrast(hex: hex, opacity: opacity, colors: colors, wallpaper: $0), $0) }
            .min { $0.0 < $1.0 }!
    }

    @Test("Every text is at 4.5:1 or more on the worst of eleven wallpapers, dark and light",
          arguments: [("dark", OverlayColors.dark), ("light", OverlayColors.light)])
    func textContrast(appearance: String, colors: OverlayColors) {
        for text in Self.texts(colors) {
            let worst = Self.worst(hex: text.hex, opacity: text.opacity, colors: colors)
            #expect(worst.ratio >= 4.5, "\(appearance), \(text.name): \(worst.ratio) on #\(String(worst.wallpaper, radix: 16))")
            let solid = Self.solidContrast(hex: text.hex, opacity: text.opacity, colors: colors)
            #expect(solid >= 4.5, "\(appearance), \(text.name), Reduce Transparency: \(solid)")
        }
    }

    @Test("The figures of the light design's notes (worst wallpaper and Reduce Transparency)")
    func designFigures() {
        // (text, light worst, light RT, dark worst, dark RT), from `ovl-light-notes`.
        let figures: [(String, Double, Double, Double, Double)] = [
            ("settled text", 12.99, 14.60, 15.52, 15.12),
            ("tail", 5.16, 5.42, 8.58, 8.43),
            ("timer", 5.89, 6.24, 9.49, 9.30),
            ("stopped timer", 5.16, 5.42, 8.58, 8.43),
            ("Transcribing…", 6.14, 7.01, 11.49, 11.17),
        ]
        for (name, lightWorst, lightSolid, darkWorst, darkSolid) in figures {
            for (colors, worst, solid) in [(OverlayColors.light, lightWorst, lightSolid), (.dark, darkWorst, darkSolid)] {
                let text = Self.texts(colors).first { $0.name == name }!
                let measured = Self.worst(hex: text.hex, opacity: text.opacity, colors: colors).ratio
                #expect(abs(measured - worst) < 0.02, "\(name) \(colors.isDark ? "dark" : "light"): \(measured), notes \(worst)")
                let measuredSolid = Self.solidContrast(hex: text.hex, opacity: text.opacity, colors: colors)
                #expect(abs(measuredSolid - solid) < 0.02, "\(name) RT: \(measuredSolid), notes \(solid)")
            }
        }
        // For the light overlay the worst wallpaper is black (its 6 % shows through).
        #expect(Self.worst(hex: OverlayColors.light.ink, opacity: OverlayColors.light.tailOpacity, colors: .light).wallpaper == 0x000000)
    }

    @Test("Translucent surfaces, and the tail dimmer than the settled text")
    func translucent() {
        for colors in [OverlayColors.dark, .light] {
            #expect(colors.surface.opacity >= 0.85 && colors.surface.opacity < 1)
            #expect(colors.solidSurface.opacity == 1)
            #expect(colors.tailOpacity < colors.textOpacity - 0.2)
        }
    }

    @Test("The palette follows the appearance: dark ones get .dark, the others .light")
    func paletteSelection() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let light = try #require(NSAppearance(named: .aqua))
        #expect(OverlayColors.forAppearance(dark) == .dark)
        #expect(OverlayColors.forAppearance(light) == .light)
        if let highContrastDark = NSAppearance(named: .accessibilityHighContrastDarkAqua) {
            #expect(OverlayColors.forAppearance(highContrastDark) == .dark)
        }
        if let vibrantLight = NSAppearance(named: .vibrantLight) {
            #expect(OverlayColors.forAppearance(vibrantLight) == .light)
        }
        #expect(OverlayColors.forScheme(.dark) == .dark)
        #expect(OverlayColors.forScheme(.light) == .light)
        // The light palette's own values, as the notes give them.
        #expect(OverlayColors.light.rim == .init(hex: 0x1A1325, opacity: 0.14))
        #expect(OverlayColors.dark.rim == nil)
        #expect(OverlayColors.light.surface == .init(hex: 0xFFFFFF, opacity: 0.94))
        #expect(OverlayColors.light.transcribingLabel == 0x7A1FD6)
    }
}
