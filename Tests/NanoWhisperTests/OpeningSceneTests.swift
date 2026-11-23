import Foundation
import Testing
@testable import NanoWhisper

/// The opening scene's values and frames (a port of the prototype `onb4-proto`, its saved Tweaks).
@Suite("Opening scene")
struct OpeningSceneTests {
    typealias Scene = OpeningScene
    typealias Tweak = OpeningScene.Tweak
    typealias Times = OpeningScene.Times
    typealias Layout = OpeningScene.Layout

    static func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }

    @Test("The prototype's saved values, including the button the maintainer retouched after the notes")
    func savedValues() {
        // The notes board said 2 s, 0.45 s, 88 %, 0.15: the prototype's saved values win.
        #expect(Tweak.buttonAt == 1.2)
        #expect(Tweak.buttonDuration == 1.1)
        #expect(Tweak.buttonScaleFrom == 0.9)
        #expect(Tweak.buttonBounce == 0.17)
        #expect(Tweak.sunriseDelay == 0.3 && Tweak.sunriseDuration == 1.7 && Tweak.balloonOvershoot == 0.04)
        #expect(Tweak.travelDelay == 0.05 && Tweak.travelDuration == 0.75)
        #expect(Tweak.settleDuration == 0.7 && Tweak.finalOpacity == 0.35 && Tweak.glowSize == 330)
        #expect(Tweak.recorderAt == 0.25 && Tweak.catchPhraseAt == 0.45 && Tweak.factsAt == 0.55 && Tweak.continueAt == 0.6)
    }

    @Test("Moments: the title moment complete at 2.7 s, Return from 1.83 s; after the press the recorder records at 0.825 s")
    func times() {
        #expect(Self.close(Times.sunriseEnds, 2.0))
        #expect(Self.close(Times.logo, 1.1) && Self.close(Times.title, 1.5) && Self.close(Times.button, 1.5))
        #expect(Self.close(Times.titleMomentEnds, 2.7))
        #expect(Self.close(Times.buttonPressable, 1.83))
        #expect(Self.close(Times.recordingStarts, 0.825))
        #expect(Self.close(Times.recordingEnds, 6.125))
        #expect(Self.close(Times.sceneSettles, 1.4))
        #expect(WelcomeDictation.recordingStarts == Times.recordingStarts, "the recorder's clock is the press")
    }

    @Test("The title moment's layout, centred, and the aura reaching the far top corner")
    func layout() {
        #expect(Self.close(Layout.groupTop, 165.286))
        #expect(Self.close(Layout.iconCenterY, 224.286))
        #expect(Self.close(Layout.titleTop, 303.286))
        #expect(Self.close(Layout.headlineCenterY, 367))
        #expect(Self.close(Layout.buttonTop, 410.714))
        #expect(Layout.auraCenter == CGPoint(x: 290, y: 700))
        let radii = Layout.auraRadii
        #expect(Self.close(Double(radii.width) / Double(radii.height), 1.3))
        // The last solid colour (70 % of the radius) reaches the top corners.
        let corner = ((290 / Double(radii.width)) * (290 / Double(radii.width)) + (700 / Double(radii.height)) * (700 / Double(radii.height))).squareRoot()
        #expect(Self.close(corner, 0.7, 0.0005))
    }

    @Test("At the start: an empty window")
    func start() {
        for dark in [false, true] {
            let frame = Scene.frame(t: 0.1, pt: nil, dark: dark, reduceMotion: false)
            #expect(frame.aura.opacity == 0)
            #expect(frame.icon.opacity == 0 && frame.title.opacity == 0 && frame.headline.opacity == 0)
            #expect(frame.button.opacity == 0)
            #expect(([frame.catchPhrase, frame.recorder, frame.continueButton] + frame.facts).allSatisfy { $0.opacity == 0 })
        }
    }

    @Test("The sunrise: up to 104 % (the balloon), back to 100 %, its rim fading by 75 % of the rise")
    func sunrise() {
        let scales = stride(from: 0.3, through: 2.1, by: 0.01).map { Scene.frame(t: $0, pt: nil, dark: true, reduceMotion: false).aura.scaleX }
        #expect(Self.close(scales.max()!, 1.04, 0.002))
        #expect(scales.last == 1)
        #expect(Scene.frame(t: 0.3 + 0.8 * 1.7, pt: nil, dark: true, reduceMotion: false).aura.scaleX > 1.039)
        #expect(Scene.frame(t: 0.6, pt: nil, dark: true, reduceMotion: false).aura.rimOpacity > 0.25)
        #expect(Scene.frame(t: 0.3 + 0.76 * 1.7, pt: nil, dark: true, reduceMotion: false).aura.rimOpacity == 0)
    }

    @Test("The title moment: icon 118 pt, NanoWhisper and the headline (82 %), Get Started at full size")
    func titleMoment() {
        let dark = Scene.frame(t: Times.titleMomentEnds, pt: nil, dark: true, reduceMotion: false)
        #expect(Self.close(dark.icon.scale, 118.0 / 104))
        #expect(Self.close(dark.icon.offsetY, Layout.iconCenterY - 102))
        #expect(dark.icon.opacity == 1 && dark.icon.blur == 0)
        #expect(dark.title.opacity == 1 && dark.title.offsetY == 0)
        #expect(dark.titleColor == Scene.RGBA(0xFFFFFF))
        #expect(Self.close(dark.headline.scale, 16.0 / 28))
        #expect(dark.headline.color == Scene.RGBA(0xFFFFFF, alpha: 0.82))
        #expect(Self.close(dark.button.scale, 1, 0.005) && dark.button.opacity == 1)
        #expect(dark.aura.scaleX == 1 && dark.aura.opacity == 1)
        let light = Scene.frame(t: Times.titleMomentEnds, pt: nil, dark: false, reduceMotion: false)
        #expect(light.titleColor == Scene.RGBA(0x1C1C1E), "dark text on the lavender dawn")
        #expect(light.aura.stops.first?.color == Scene.RGBA(Tweak.lightCore))
    }

    @Test("Get Started pops from the back: from 90 %, a soft overshoot, no vertical travel")
    func buttonPop() {
        let start = Scene.frame(t: Times.button, pt: nil, dark: true, reduceMotion: false).button
        #expect(start.scale == 0.9 && start.opacity == 0)
        let scales = stride(from: Times.button, through: Times.titleMomentEnds, by: 0.01)
            .map { Scene.frame(t: $0, pt: nil, dark: true, reduceMotion: false).button.scale }
        #expect(scales.max()! > 1.0 && scales.max()! < 1.02, "a small overshoot (bounce 0.17)")
        // Opacity over the first 60 % of the spring.
        #expect(Scene.frame(t: Times.button + 0.66, pt: nil, dark: true, reduceMotion: false).button.opacity == 1)
    }

    @Test("After the press: icon and headline at their welcome places, the aura a 330 pt halo at 35 % behind the icon")
    func rest() {
        for dark in [false, true] {
            let frame = Scene.frame(t: Times.titleMomentEnds, pt: .infinity, dark: dark, reduceMotion: false)
            #expect(frame.icon.offsetY == 0 && frame.icon.scale == 1 && frame.icon.opacity == 1)
            #expect(frame.headline.offsetY == 0 && frame.headline.scale == 1 && frame.headline.opacity == 1)
            #expect(frame.headline.color == Scene.label(dark: dark))
            #expect(frame.title.opacity == 0 && frame.button.opacity == 0)
            #expect(([frame.catchPhrase, frame.recorder, frame.continueButton] + frame.facts).allSatisfy { $0 == .init(opacity: 1, offsetY: 0) })
            let radii = Layout.auraRadii
            #expect(Self.close(frame.aura.scaleX * 2 * Double(radii.width), 330))
            #expect(Self.close(frame.aura.scaleY * 2 * Double(radii.height), 330))
            #expect(Self.close(Double(Layout.auraCenter.x) + frame.aura.offset.width, 290))
            #expect(Self.close(Double(Layout.auraCenter.y) + frame.aura.offset.height, 102), "centred on the icon")
            #expect(Self.close(frame.aura.opacity, 0.35))
            #expect(frame.aura.stops[2].color.alpha == 0 && frame.aura.stops[3].color.alpha == 0, "outer colours thinned out")
            let core = frame.aura.stops[0].color, violet = Scene.RGBA(dark ? Tweak.darkStop2 : Tweak.lightStop2)
            #expect(Self.close(core.red, violet.red) && Self.close(core.green, violet.green) && Self.close(core.blue, violet.blue),
                    "the core turned violet")
            #expect(frame.aura.glowOpacity == 0)
        }
    }

    @Test("The welcome arrives in order: recorder, catch phrase, facts together, Continue")
    func arrival() {
        func at(_ pt: Double) -> Scene.Frame { Scene.frame(t: 99, pt: pt, dark: true, reduceMotion: false) }
        #expect(at(0.24).recorder.opacity == 0 && at(0.3).recorder.opacity > 0)
        #expect(at(0.44).catchPhrase.opacity == 0 && at(0.5).catchPhrase.opacity > 0)
        #expect(at(0.54).facts.allSatisfy { $0.opacity == 0 })
        let facts = at(0.7).facts.map(\.opacity)
        #expect(facts.allSatisfy { $0 > 0 && $0 == facts[0] }, "the four together")
        #expect(at(0.59).continueButton.opacity == 0 && at(0.65).continueButton.opacity > 0)
        // The title leaves first, the button with it.
        #expect(at(0.25).title.opacity == 0 && at(0.2).button.opacity == 0)
        // The catch phrase rides with the headline.
        let travel = at(0.5)
        #expect(Self.close(travel.catchPhrase.offsetY - travel.headline.offsetY, Tweak.fadeRise * (1 - travel.catchPhrase.opacity)))
    }

    @Test("Reduce Motion: the title moment at once, then one 0.3 s cross-fade to the welcome with a halo")
    func reduceMotion() {
        let title = Scene.frame(t: 0, pt: nil, dark: true, reduceMotion: true)
        #expect(title.aura.scaleX == 1 && title.aura.opacity == 1 && title.aura.rimOpacity == 0)
        #expect(title.icon.opacity == 1 && title.title.opacity == 1 && title.button.opacity == 1 && title.button.scale == 1)
        let middle = Scene.frame(t: 0, pt: 0.15, dark: true, reduceMotion: true)
        #expect(middle.icon.opacity == 0, "the icon fades out, then in at its place")
        #expect(middle.recorder.offsetY == 0, "no rise")
        let rest = Scene.frame(t: 0, pt: .infinity, dark: true, reduceMotion: true)
        #expect(rest.icon.offsetY == 0 && rest.icon.opacity == 1)
        #expect(rest.aura.opacity == 0 && Self.close(rest.aura.glowOpacity, 0.35))
        #expect(rest.recorder == .init(opacity: 1, offsetY: 0))
    }

    @Test("Curves as SwiftUI defines them")
    func curves() {
        #expect(Scene.Curve.spring(duration: 1, bounce: 0, 0) == 0)
        #expect(Scene.Curve.spring(duration: 1, bounce: 0, 3.1) == 1)
        #expect(Self.close(Scene.Curve.bezier(0, 0, 1, 1, 0.37), 0.37))
        let sunrise = stride(from: 0, through: 1, by: 0.01).map { Scene.Curve.bezier(0.6, 0, 0.3, 1, $0) }
        #expect(sunrise.first == 0 && sunrise.last == 1 && sunrise == sunrise.sorted())
        #expect(sunrise[25] < 0.25, "the sunrise starts slowly")
        let travel = stride(from: 0, through: 2.25, by: 0.01).map(Scene.Curve.travel)
        #expect(travel == travel.sorted(), ".smooth has no bounce")
    }
}

@Suite("Opening scene clock")
@MainActor
struct OpeningSceneClockTests {
    @Test("Get Started takes a press from 1.83 s; the title moment freezes where it was")
    func press() {
        let clock = OpeningSceneClock()
        let start = Date()
        #expect(!clock.canPress(at: start, reduceMotion: false), "not before the scene starts")
        clock.begin(reduceMotion: false, at: start)
        #expect(clock.isAnimating)
        #expect(!clock.press(at: start.addingTimeInterval(1.0), reduceMotion: false), "too early")
        #expect(clock.moment(at: start.addingTimeInterval(1.0)) == .init(t: 1.0, pt: nil))
        #expect(clock.press(at: start.addingTimeInterval(1.9), reduceMotion: false))
        #expect(!clock.press(at: start.addingTimeInterval(2.0), reduceMotion: false), "once")
        let moment = clock.moment(at: start.addingTimeInterval(2.4))
        // Dates keep about 1e-7 s.
        #expect(abs(moment.t - 1.9) < 1e-5)
        #expect(abs((moment.pt ?? 0) - 0.5) < 1e-5)
        #expect(clock.isAnimating)
    }

    @Test("Reduce Motion: waiting at once (no frames), pressable at once, settled after the cross-fade")
    func reduceMotion() async throws {
        let clock = OpeningSceneClock()
        clock.begin(reduceMotion: true)
        #expect(clock.isWaiting && !clock.isAnimating)
        #expect(clock.press(reduceMotion: true))
        #expect(clock.isAnimating)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(clock.isSettled && !clock.isAnimating)
        #expect(clock.moment(at: Date()).pt == .infinity)
    }

    @Test("Waiting: no frames needed, the title moment shown complete")
    func waiting() async throws {
        let clock = OpeningSceneClock()
        let start = Date().addingTimeInterval(-OpeningScene.Times.titleMomentEnds + 0.05)
        clock.begin(reduceMotion: false, at: start)
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(clock.isWaiting && !clock.isAnimating)
        #expect(clock.moment(at: Date()) == .init(t: OpeningScene.Times.titleMomentEnds, pt: nil))
        #expect(clock.press(reduceMotion: false))
        #expect(clock.moment(at: Date()).t == OpeningScene.Times.titleMomentEnds)
    }

    @Test("A fixed clock (renders) never animates and never takes a press")
    func fixed() {
        let clock = OpeningSceneClock(fixedAt: 0.95, pressedFor: nil)
        #expect(!clock.isAnimating)
        #expect(!clock.press(reduceMotion: false))
        #expect(clock.moment(at: Date()) == .init(t: 0.95, pt: nil))
    }

    @Test("A replay starts from the opening scene: what opening onboarding does")
    func presentation() {
        #expect(OnboardingPresentation.resolve(isOpen: false, restart: false) == .open)
        #expect(OnboardingPresentation.resolve(isOpen: false, restart: true) == .open)
        #expect(OnboardingPresentation.resolve(isOpen: true, restart: false) == .bringToFront)
        #expect(OnboardingPresentation.resolve(isOpen: true, restart: true) == .restart)
        // New content has a new clock: the scene starts from its beginning.
        #expect(!OpeningSceneClock().hasStarted)
    }
}
