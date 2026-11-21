import Foundation
import SwiftUI

// The onboarding's opening scene (Claude Design canvas "NanoWhisper Redesign", page
// "Onboarding — opening scene", prototype `onb4-proto`, approved 2026-11-21): the window opens
// at its size, a violet sunrise rises from the bottom and fills it, the icon, "NanoWhisper" and
// the headline arrive, Get Started pops from the back; its press hands over to the welcome page
// (the icon and the headline travel to their places, the aura shrinks into a halo behind the
// icon, the rest of the welcome fades up and the recorder plays its dictation).
//
// Every moment is a pure function of two clocks, as in the prototype: `t`, seconds since the
// welcome appeared, and `pt`, seconds since the press. `OpeningScene.frame` is a port of the
// prototype's `renderVals` (onb4-win), so a render at any moment matches the canvas.

/// The opening scene's values and maths. Pure: tested without a window.
enum OpeningScene {
    /// Every value of the scene, named after the prototype's Tweaks. Source: the **saved** values
    /// of `onb4-proto`'s Tweaks (its `data-props`), read on 2026-11-21. The maintainer retouched
    /// the button's pop after the designer's notes board was published (notes: at 2 s, 0.45 s,
    /// 88 %, bounce 0.15); the prototype's saved values win.
    enum Tweak {
        // 1 · Sunrise
        /// The window shows empty before the sunrise starts.
        static let sunriseDelay: Double = 0.3
        static let sunriseDuration: Double = 1.7
        /// The "sunrise" curve: cubic-bezier(0.6, 0, 0.3, 1), up to 1 + overshoot over 80 % of
        /// the duration, then back to 1 (`SettleCurve`).
        static let sunriseCurve = (x1: 0.6, y1: 0.0, x2: 0.3, y2: 1.0)
        /// "Balloon overshoot": 4 %.
        static let balloonOvershoot: Double = 0.04
        /// "Breathing while waiting": 1.2 % (scale 1 → 1.012 and back).
        static let breathing: Double = 0.012
        /// "Breathing period (in and out)": 5 s (2.5 s each way).
        static let breathingPeriod: Double = 5

        // 2 · Aura shape (an ellipse)
        static let ellipseWidth: Double = 1.3
        /// Centre across the window, as a fraction of its width.
        static let originX: Double = 0.5
        /// Centre below the bottom edge, in points.
        static let originBelow: Double = 60
        /// 1: the last solid colour just reaches the far top corner.
        static let reach: Double = 1
        static let startSize: Double = 0
        /// The last colour stop sits at 1 − softness.
        static let softness: Double = 0.3
        static let auraOpacity: Double = 1
        /// The brighter leading rim of the rise.
        static let rippleRim: Double = 0.3

        // 3 · Aura colours (four stops)
        static let stop2At: Double = 0.16
        static let stop3At: Double = 0.42
        static let darkCore: UInt32 = 0xF4DAFF
        static let darkStop2: UInt32 = 0xA24BFF
        static let darkStop3: UInt32 = 0x3B1B70
        static let darkEdge: UInt32 = 0x1A1424
        static let lightCore: UInt32 = 0xB35CFF
        static let lightStop2: UInt32 = 0xC892FF
        static let lightStop3: UInt32 = 0xE4D0FF
        static let lightEdge: UInt32 = 0xF8F3FF

        // 4 · Title moment (times after the sunrise starts)
        static let iconSize: Double = 118
        static let titleSize: Double = 40
        /// The headline grows to 28 pt on the welcome.
        static let headlineSize: Double = 16
        static let groupOffset: Double = -10
        static let logoAt: Double = 0.8
        static let logoDuration: Double = 0.9
        static let logoBlur: Double = 6
        static let logoScaleFrom: Double = 0.88
        static let titleAt: Double = 1.2
        static let headlineAt: Double = 1.2
        static let textDuration: Double = 1.2
        static let textRise: Double = 8
        static let buttonAt: Double = 1.2
        static let buttonDuration: Double = 1.1
        static let buttonScaleFrom: Double = 0.9
        static let buttonBounce: Double = 0.17

        // 5 · Button: "Get Started", large (44 pt), filled white, at least 100 pt wide.
        static let buttonHeight: Double = 44
        static let buttonWidth: Double = 100
        static let buttonGap: Double = 34
        static let buttonFillColor: UInt32 = 0xFFFFFF
        static let buttonTextColor: UInt32 = 0x4A1C96
        /// Its two shadows: 0 1 2 at 20 %, and 0 8 22 at 28 % (dark) or 16 % (light).
        static let buttonShadowColor: UInt32 = 0x1E003C

        // 6 · Press and travel (times after the press)
        static let travelDelay: Double = 0.05
        /// `.smooth(duration: 0.75)`: a spring without bounce.
        static let travelDuration: Double = 0.75
        static let nameFade: Double = 0.25
        static let buttonFade: Double = 0.2

        // 7 · After the press: the aura "shrinks into the icon".
        static let settleDuration: Double = 0.7
        static let finalOpacity: Double = 0.35
        static let glowSize: Double = 330

        // 8 · Welcome arrives (times after the press)
        static let catchPhraseAt: Double = 0.45
        static let recorderAt: Double = 0.25
        static let fadeDuration: Double = 0.45
        static let fadeRise: Double = 10
        static let recordingStartsAfter: Double = 0.125
        /// The welcome's recording, 0:00 → 0:05 (maintainer, 2026-11-21; was 3 s then frozen,
        /// then 4 s). Its pace and the steps after it: `WelcomeDictation`.
        static let recordingLength: Double = 5.3
        static let factsAt: Double = 0.55
        /// "Facts arrive: together" (one by one would be 0.07 s apart).
        static let factsStagger: Double = 0
        static let continueAt: Double = 0.6
    }

    /// The window and the welcome's fixed places (points, y down), as built and as drawn.
    enum Layout {
        static let width: Double = 580
        static let height: Double = 640
        /// The welcome's icon: 104 pt, its centre 102 pt from the top.
        static let welcomeIconSize: Double = 104
        static let welcomeIconCenterY: Double = 102
        /// The welcome's headline: 28 pt, centred 187 pt from the top.
        static let welcomeHeadlineSize: Double = 28
        static let welcomeHeadlineCenterY: Double = 187
        static var centerX: Double { width / 2 }

        static let titleLineHeight = (Tweak.titleSize * 1.2).rounded()
        static let headlineLineHeight = Tweak.headlineSize * 34 / 28
        /// The title moment's group: icon, 20, title, 6, headline, gap, button; centred, moved by
        /// `groupOffset`.
        static var groupTop: Double {
            let height = Tweak.iconSize + 20 + titleLineHeight + 6 + headlineLineHeight + Tweak.buttonGap + Tweak.buttonHeight
            return (Self.height - height) / 2 + Tweak.groupOffset
        }
        static var iconCenterY: Double { groupTop + Tweak.iconSize / 2 }
        static var titleTop: Double { groupTop + Tweak.iconSize + 20 }
        static var headlineCenterY: Double { titleTop + titleLineHeight + 6 + headlineLineHeight / 2 }
        static var buttonTop: Double { titleTop + titleLineHeight + 6 + headlineLineHeight + Tweak.buttonGap }

        /// The aura's centre, below the bottom edge.
        static var auraCenter: CGPoint { CGPoint(x: Tweak.originX * width, y: height + Tweak.originBelow) }
        /// The aura's radii at scale 1: its last solid colour reaches the far top corner.
        static var auraRadii: CGSize {
            let center = auraCenter
            let far = ((max(center.x, width - center.x) / Tweak.ellipseWidth).squared + Double(center.y).squared).squareRoot()
            let ry = max(40, Tweak.reach * far / max(0.3, 1 - Tweak.softness))
            return CGSize(width: ry * Tweak.ellipseWidth, height: ry)
        }
    }

    // MARK: - Times

    /// The sequence's moments, in seconds. Before the press: from the welcome appearing.
    /// After: from the press.
    enum Times {
        static var sunriseStarts: Double { Tweak.sunriseDelay }
        static var sunriseEnds: Double { sunriseStarts + Tweak.sunriseDuration }
        static var logo: Double { sunriseStarts + Tweak.logoAt }
        static var title: Double { sunriseStarts + Tweak.titleAt }
        static var headline: Double { sunriseStarts + Tweak.headlineAt }
        static var button: Double { sunriseStarts + Tweak.buttonAt }
        /// The title moment is complete: the aura starts breathing.
        static var titleMomentEnds: Double {
            max(sunriseEnds, logo + Tweak.logoDuration, title + Tweak.textDuration,
                headline + Tweak.textDuration, button + Tweak.buttonDuration)
        }
        /// From then, Return presses Get Started (the prototype's rule).
        static var buttonPressable: Double { button + 0.3 * Tweak.buttonDuration }

        // After the press.
        static var recorderIn: Double { Tweak.recorderAt + Tweak.fadeDuration }
        static var recordingStarts: Double { recorderIn + Tweak.recordingStartsAfter }
        static var recordingEnds: Double { recordingStarts + Tweak.recordingLength }
        static var factsEnd: Double { Tweak.factsAt + Tweak.fadeDuration + 3 * Tweak.factsStagger }
        /// The scene's own motion is over (the recorder's dictation runs on its own clock).
        static var sceneSettles: Double {
            max(Tweak.travelDelay + Tweak.travelDuration * 1.6, Tweak.settleDuration * 1.2,
                Tweak.continueAt + Tweak.fadeDuration, Tweak.catchPhraseAt + Tweak.fadeDuration, factsEnd) + 0.15
        }
        /// Reduce Motion: the press is one cross-fade.
        static let reduceMotionCrossFade: Double = 0.3
        static var reduceMotionSettles: Double { reduceMotionCrossFade + 0.05 }
    }

    // MARK: - Curves (as SwiftUI defines them)

    enum Curve {
        /// cubic-bezier(x1, y1, x2, y2), as CSS and SwiftUI's `.timingCurve`.
        static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ u: Double) -> Double {
            if u <= 0 { return 0 }
            if u >= 1 { return 1 }
            let cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
            let cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
            func sx(_ s: Double) -> Double { ((ax * s + bx) * s + cx) * s }
            func sy(_ s: Double) -> Double { ((ay * s + by) * s + cy) * s }
            func dx(_ s: Double) -> Double { (3 * ax * s + 2 * bx) * s + cx }
            var s = u
            for _ in 0..<10 {
                let e = sx(s) - u, d = dx(s)
                if abs(e) < 1e-6 || abs(d) < 1e-6 { break }
                s -= e / d
            }
            if s < 0 || s > 1 {
                var lo = 0.0, hi = 1.0
                s = u
                for _ in 0..<30 {
                    if sx(s) < u { lo = s } else { hi = s }
                    s = (lo + hi) / 2
                }
            }
            return sy(s)
        }

        /// The onboarding's fade up: cubic-bezier(0.2, 0.7, 0.2, 1).
        static func fadeUp(_ u: Double) -> Double { bezier(0.2, 0.7, 0.2, 1, u) }

        /// SwiftUI's `.spring(duration:bounce:)` at `tau` seconds: ω = 2π / duration, damping
        /// ratio 1 − bounce. Settled (1) after three durations.
        static func spring(duration: Double, bounce: Double, _ tau: Double) -> Double {
            if tau <= 0 { return 0 }
            if tau > duration * 3 { return 1 }
            let w = 2 * Double.pi / duration, z = 1 - bounce
            if z >= 0.999 { return 1 - exp(-w * tau) * (1 + w * tau) }
            let wd = w * (1 - z * z).squareRoot()
            return 1 - exp(-z * w * tau) * (cos(wd * tau) + (z * w / wd) * sin(wd * tau))
        }

        /// The sunrise's scale at `tau` seconds into it: the sunrise curve up to 1 + overshoot
        /// over 80 % of the duration, then an ease-in-out back to 1.
        static func rise(_ tau: Double) -> Double {
            let duration = Tweak.sunriseDuration, overshoot = Tweak.balloonOvershoot
            let c = Tweak.sunriseCurve
            let u = tau / duration
            if u <= 0 { return 0 }
            guard overshoot > 0 else { return bezier(c.x1, c.y1, c.x2, c.y2, min(1, u)) }
            let split = 0.8
            if u < split { return bezier(c.x1, c.y1, c.x2, c.y2, u / split) * (1 + overshoot) }
            if u >= 1 { return 1 }
            return 1 + overshoot - overshoot * bezier(0.45, 0, 0.55, 1, (u - split) / (1 - split))
        }

        /// The travel: `.smooth(duration:)`, a spring with no bounce.
        static func travel(_ tau: Double) -> Double {
            spring(duration: Tweak.travelDuration, bounce: 0, tau)
        }
    }

    // MARK: - A frame

    /// An sRGB colour with opacity (Equatable, for tests).
    struct RGBA: Equatable {
        var red: Double, green: Double, blue: Double, alpha: Double

        init(_ hex: UInt32, alpha: Double = 1) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
            self.alpha = alpha
        }

        init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }

        func with(alpha: Double) -> RGBA { RGBA(red: red, green: green, blue: blue, alpha: alpha) }

        /// `self` mixed toward `other` by `k` (0…1), as the prototype's `mixc`.
        func mixed(with other: RGBA, _ k: Double, alpha: Double? = nil) -> RGBA {
            RGBA(red: lerp(red, other.red, k), green: lerp(green, other.green, k),
                 blue: lerp(blue, other.blue, k), alpha: alpha ?? lerp(self.alpha, other.alpha, k))
        }

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    }

    /// One element's fade: opacity and vertical offset (points, down).
    struct Fade: Equatable {
        var opacity: Double
        var offsetY: Double
    }

    struct Aura: Equatable {
        /// Scale of the ellipse (its radii at 1: `Layout.auraRadii`), around its centre.
        var scaleX: Double
        var scaleY: Double
        /// The centre's move from `Layout.auraCenter` (toward the icon after the press).
        var offset: CGSize
        var opacity: Double
        /// Gradient stops from the centre (0) to the ellipse's edge (1).
        var stops: [(color: RGBA, location: Double)]
        var rimColor: RGBA
        var rimOpacity: Double
        /// Reduce Motion only: a halo of the second colour behind the icon.
        var glowOpacity: Double

        static func == (a: Aura, b: Aura) -> Bool {
            a.scaleX == b.scaleX && a.scaleY == b.scaleY && a.offset == b.offset && a.opacity == b.opacity
                && a.stops.map(\.color) == b.stops.map(\.color) && a.stops.map(\.location) == b.stops.map(\.location)
                && a.rimColor == b.rimColor && a.rimOpacity == b.rimOpacity && a.glowOpacity == b.glowOpacity
        }
    }

    struct Icon: Equatable {
        /// From the welcome's place (centre 102 pt from the top).
        var offsetY: Double
        /// Of the 104 pt icon.
        var scale: Double
        var opacity: Double
        var blur: Double
        var shadowColor: RGBA
        /// SwiftUI shadow radius (half the CSS blur).
        var shadowRadius: Double
        var shadowY: Double
    }

    struct Headline: Equatable {
        /// From the welcome's place (centre 187 pt from the top).
        var offsetY: Double
        /// Of the 28 pt headline.
        var scale: Double
        var opacity: Double
        var color: RGBA
    }

    struct Button: Equatable {
        var opacity: Double
        var scale: Double
        /// 0…1: the shadow grows with the pop, as if the button came forward.
        var shadow: Double
    }

    struct Frame: Equatable {
        var aura: Aura
        var icon: Icon
        /// "NanoWhisper": at `Layout.titleTop`, moved down by `offsetY`.
        var title: Fade
        var titleColor: RGBA
        var headline: Headline
        var button: Button
        var catchPhrase: Fade
        var recorder: Fade
        var facts: [Fade]
        var continueButton: Fade
    }

    static let gradientWhite: UInt32 = 0xFFFFFF
    /// The onboarding's label colour (`OnboardingPalette.label`).
    static func label(dark: Bool) -> RGBA { RGBA(dark ? 0xF2F2F4 : 0x1C1C1E) }

    /// The scene at `t` seconds after the welcome appeared and, once pressed, `pt` seconds after
    /// the press (`nil`: not pressed). A port of the prototype's `renderVals`, "shrinks into the
    /// icon". With Reduce Motion: no sunrise (the title moment at once), then a 0.3 s
    /// cross-fade to the welcome with a halo behind the icon.
    static func frame(t inputT: Double, pt: Double?, dark: Bool, reduceMotion: Bool) -> Frame {
        typealias T = Tweak
        typealias L = Layout
        let rm = reduceMotion
        let pressed = pt != nil
        let pt = pt ?? -1
        let t = rm ? max(inputT, Times.titleMomentEnds + 10) : inputT

        let label = label(dark: dark)
        let colors = dark ? [T.darkCore, T.darkStop2, T.darkStop3, T.darkEdge] : [T.lightCore, T.lightStop2, T.lightStop3, T.lightEdge]
        let onAura = dark ? RGBA(gradientWhite) : RGBA(0x1C1C1E)

        // A: the sunrise and the title moment.
        let tauA = t - Times.sunriseStarts
        let sA = tauA <= 0 ? T.startSize : T.startSize + (1 - T.startSize) * Curve.rise(tauA)
        let auraIn = tauA <= 0 ? 0 : clamp(tauA / 0.2)
        let riseLinear = clamp(tauA / T.sunriseDuration)
        let logoE = Curve.fadeUp(clamp((t - Times.logo) / T.logoDuration))
        let logoS = Curve.spring(duration: T.logoDuration, bounce: 0, t - Times.logo)
        let nameK = Curve.fadeUp(clamp((t - Times.title) / T.textDuration))
        let headK = Curve.fadeUp(clamp((t - Times.headline) / T.textDuration))
        let buttonOpacity = Curve.fadeUp(clamp((t - Times.button) / (T.buttonDuration * 0.6)))
        let buttonS = Curve.spring(duration: T.buttonDuration, bounce: T.buttonBounce, t - Times.button)

        // B: after the press.
        var kT = 0.0, kS = 0.0
        if pressed {
            if rm {
                kT = clamp(pt / Times.reduceMotionCrossFade)
                kS = kT
            } else {
                kT = Curve.travel(pt - T.travelDelay)
                kS = Curve.spring(duration: T.settleDuration, bounce: 0, pt)
            }
        }
        let posK = rm ? (kT < 0.5 ? 0 : 1) : kT
        let colK = clamp(rm ? posK : kT)

        // The icon: the title moment's size and place, then the welcome's 104 pt at the top.
        let iconSize = lerp(T.iconSize, L.welcomeIconSize, posK)
        let iconCenterY = lerp(L.iconCenterY, L.welcomeIconCenterY, posK)
        let iconScale = iconSize / L.welcomeIconSize * (pressed || rm ? 1 : lerp(T.logoScaleFrom, 1, logoS))
        let iconOpacity = pressed ? (rm ? abs(1 - 2 * kT) : 1) : (rm ? 1 : logoE)
        let shadowTint = dark ? (10.0, 0.0, 30.0) : (70.0, 20.0, 130.0)
        let icon = Icon(
            offsetY: iconCenterY - L.welcomeIconCenterY,
            scale: iconScale,
            opacity: iconOpacity,
            blur: pressed || rm ? 0 : T.logoBlur * (1 - logoE),
            shadowColor: RGBA(red: lerp(shadowTint.0, 0, colK) / 255, green: lerp(shadowTint.1, 0, colK) / 255,
                              blue: lerp(shadowTint.2, 0, colK) / 255, alpha: lerp(dark ? 0.45 : 0.22, 0.16, colK)),
            shadowRadius: lerp(14, 6, colK) / 2,
            shadowY: lerp(10, 6, colK)
        )

        // "NanoWhisper": fades up, then leaves with the icon.
        var titleOpacity = rm ? 1 : nameK
        var titleOffset = rm ? 0 : T.textRise * (1 - nameK)
        if pressed {
            titleOpacity *= 1 - (rm ? clamp(pt / 0.15) : Curve.fadeUp(clamp(pt / T.nameFade)))
            titleOffset += iconCenterY - L.iconCenterY
        }

        // The headline: the 28 pt text, scaled, so it stays sharp as it grows.
        let headlineSize = lerp(T.headlineSize, L.welcomeHeadlineSize, posK)
        let headlineCenterY = lerp(L.headlineCenterY, L.welcomeHeadlineCenterY, posK)
        let headlineRise = pressed || rm ? 0 : T.textRise * (1 - headK)
        let headline = Headline(
            offsetY: headlineCenterY - L.welcomeHeadlineCenterY + headlineRise,
            scale: headlineSize / L.welcomeHeadlineSize,
            opacity: pressed ? (rm ? abs(1 - 2 * kT) : 1) : (rm ? 1 : headK),
            // The second line of the pair is the quieter one (82 %).
            color: onAura.mixed(with: label, colK, alpha: lerp(0.82, 1, colK))
        )

        // Get Started: pops from the back (scale on a soft spring, opacity over the first 60 %).
        var button = Button(opacity: rm ? 1 : buttonOpacity,
                            scale: rm ? 1 : lerp(T.buttonScaleFrom, 1, buttonS),
                            shadow: rm ? 1 : clamp(buttonS))
        if pressed {
            button.opacity *= 1 - (rm ? clamp(pt / 0.15) : Curve.fadeUp(clamp(pt / T.buttonFade)))
            button.scale = rm ? 1 : (pt < 0.1 ? 0.97 : lerp(0.97, 0.94, clamp((pt - 0.1) / T.buttonFade)))
        }

        // The aura: an ellipse whose centre sits below the bottom edge; it scales up.
        let radii = L.auraRadii
        var scaleX = sA, scaleY = sA, offset = CGSize.zero
        var auraOpacity = T.auraOpacity * auraIn, outerAlpha = 1.0, coreK = 0.0, glowOpacity = 0.0
        if rm && !pressed {
            scaleX = 1; scaleY = 1; auraOpacity = T.auraOpacity
        }
        if pressed {
            let k = clamp(kS)
            if rm {
                // Reduce Motion: the aura fades in place; a halo rises behind the icon.
                auraOpacity = T.auraOpacity * (1 - k) * (1 - k * 0.35)
                glowOpacity = T.finalOpacity * k
            } else {
                // Shrinks into the icon: the centre follows the icon, the outer colours thin
                // out and the pale core turns to the violet, so it ends as a soft halo.
                scaleX = lerp(sA, T.glowSize / 2 / Double(radii.width), k)
                scaleY = lerp(sA, T.glowSize / 2 / Double(radii.height), k)
                offset = CGSize(width: (L.centerX - Double(L.auraCenter.x)) * k,
                                height: (iconCenterY - Double(L.auraCenter.y)) * k)
                auraOpacity = lerp(T.auraOpacity, T.finalOpacity, k)
                outerAlpha = 1 - k
                coreK = k
            }
        }
        let edge = 1 - T.softness
        let stop3 = min(T.stop3At, edge - 0.01)
        let stop2 = min(T.stop2At, stop3 - 0.01)
        let core = coreK > 0 ? RGBA(colors[0]).mixed(with: RGBA(colors[1]), coreK, alpha: 1) : RGBA(colors[0])
        let stops: [(color: RGBA, location: Double)] = [
            (core, 0), (RGBA(colors[1]), stop2), (RGBA(colors[2], alpha: outerAlpha), stop3),
            (RGBA(colors[3], alpha: outerAlpha), edge), (RGBA(colors[3], alpha: 0), 1),
        ]
        let rimColor = dark ? RGBA(colors[0]).mixed(with: RGBA(colors[1]), 0.35, alpha: 1) : RGBA(colors[1])
        let rimOpacity = pressed || rm ? 0 : T.rippleRim * (1 - smoothStep(0.2, 0.75, riseLinear)) * auraIn
        let aura = Aura(scaleX: scaleX, scaleY: scaleY, offset: offset, opacity: max(0, auraOpacity),
                        stops: stops, rimColor: rimColor, rimOpacity: rimOpacity, glowOpacity: glowOpacity)

        // The rest of the welcome, as built, timed from the press.
        func fadeUp(_ delay: Double) -> Fade {
            guard pressed else { return Fade(opacity: 0, offsetY: T.fadeRise) }
            let k = rm ? clamp(pt / Times.reduceMotionCrossFade) : Curve.fadeUp(clamp((pt - delay) / T.fadeDuration))
            return Fade(opacity: k, offsetY: rm ? 0 : T.fadeRise * (1 - k))
        }
        var catchPhrase = fadeUp(T.catchPhraseAt)
        if pressed && !rm {
            // It rides with the headline (one group), so they never overlap.
            catchPhrase.offsetY += headlineCenterY - L.welcomeHeadlineCenterY
        }

        return Frame(
            aura: aura, icon: icon,
            title: Fade(opacity: titleOpacity, offsetY: titleOffset), titleColor: onAura,
            headline: headline, button: button,
            catchPhrase: catchPhrase,
            recorder: fadeUp(T.recorderAt),
            facts: (0..<4).map { fadeUp(T.factsAt + Double($0) * T.factsStagger) },
            continueButton: fadeUp(T.continueAt)
        )
    }

    /// The halo Reduce Motion leaves behind the icon: the second colour, from the centre out.
    static func glowStops(dark: Bool) -> [(color: RGBA, location: Double)] {
        let color = RGBA(dark ? Tweak.darkStop2 : Tweak.lightStop2)
        return [(color, 0), (color.with(alpha: 0.7), 0.3), (color.with(alpha: 0.22), 0.62), (color.with(alpha: 0), 1)]
    }

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func smoothStep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let k = clamp((x - a) / (b - a))
        return k * k * (3 - 2 * k)
    }
}

func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }

private extension Double {
    var squared: Double { self * self }
}

// MARK: - Clock

/// When the scene is: the welcome's appearance, the press, and the moments it rests (no frame
/// needed: the title moment waiting, the welcome after its arrival). Renders build a fixed one.
@MainActor
final class OpeningSceneClock: ObservableObject {
    /// A moment of the scene (see `OpeningScene.frame`).
    struct Moment: Equatable {
        var t: Double
        var pt: Double?
    }

    @Published private(set) var startDate: Date?
    @Published private(set) var pressDate: Date?
    /// The title moment is complete and waits for the press (the aura breathes).
    @Published private(set) var isWaiting = false
    /// The welcome has arrived: nothing in the scene moves any more.
    @Published private(set) var isSettled = false
    /// Continue is arriving (`continueAt` after the press): Return now continues.
    @Published private(set) var canContinue = false
    /// Renders: a fixed moment.
    private let fixed: Moment?
    var fixedMoment: Moment? { fixed }
    /// `t` when the button was pressed: the title moment stays as it was.
    private var tAtPress: Double = 0
    private var generation = 0

    init() { fixed = nil }

    /// A still moment, for renders: `t` after the welcome appeared, `pt` after the press.
    init(fixedAt t: Double, pressedFor pt: Double? = nil) {
        fixed = Moment(t: t, pt: pt)
        startDate = .distantPast
        if let pt {
            pressDate = .distantPast
            canContinue = pt >= OpeningScene.Tweak.continueAt
        }
    }

    var hasStarted: Bool { startDate != nil }
    var isPressed: Bool { pressDate != nil }

    /// Whether the scene needs a frame per display refresh now.
    var isAnimating: Bool {
        guard fixed == nil, hasStarted else { return false }
        return isPressed ? !isSettled : !isWaiting
    }

    /// The welcome appeared: the scene starts (once).
    func begin(reduceMotion: Bool, at date: Date = Date()) {
        guard fixed == nil, startDate == nil else { return }
        startDate = date
        let generation = self.generation
        let wait = reduceMotion ? 0 : date.addingTimeInterval(OpeningScene.Times.titleMomentEnds).timeIntervalSinceNow
        schedule(after: wait) { [weak self] in
            guard let self, self.generation == generation, !self.isPressed else { return }
            self.isWaiting = true
        }
    }

    /// Whether Get Started takes a press (and Return) at `date`.
    func canPress(at date: Date = Date(), reduceMotion: Bool) -> Bool {
        guard fixed == nil, let startDate, pressDate == nil else { return false }
        return isWaiting || reduceMotion || date.timeIntervalSince(startDate) >= OpeningScene.Times.buttonPressable
    }

    /// Get Started was pressed: the welcome arrives.
    /// - Returns: whether the press was taken.
    @discardableResult
    func press(at date: Date = Date(), reduceMotion: Bool) -> Bool {
        guard canPress(at: date, reduceMotion: reduceMotion), let startDate else { return false }
        tAtPress = isWaiting ? OpeningScene.Times.titleMomentEnds : date.timeIntervalSince(startDate)
        pressDate = date
        isWaiting = false
        generation += 1
        let generation = self.generation
        let settles = reduceMotion ? OpeningScene.Times.reduceMotionSettles : OpeningScene.Times.sceneSettles
        schedule(after: date.addingTimeInterval(settles).timeIntervalSinceNow) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.isSettled = true
        }
        schedule(after: date.addingTimeInterval(OpeningScene.Tweak.continueAt).timeIntervalSinceNow) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.canContinue = true
        }
        return true
    }

    /// The moment to draw at `date`.
    func moment(at date: Date) -> Moment {
        if let fixed { return fixed }
        guard let startDate else { return Moment(t: 0, pt: nil) }
        if let pressDate {
            return Moment(t: tAtPress, pt: isSettled ? .infinity : max(0, date.timeIntervalSince(pressDate)))
        }
        if isWaiting { return Moment(t: OpeningScene.Times.titleMomentEnds, pt: nil) }
        return Moment(t: min(max(0, date.timeIntervalSince(startDate)), OpeningScene.Times.titleMomentEnds), pt: nil)
    }

    private func schedule(after delay: Double, _ action: @escaping @MainActor () -> Void) {
        guard delay > 0 else {
            action()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            action()
        }
    }
}
