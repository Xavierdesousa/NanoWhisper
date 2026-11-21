import AppKit
import Carbon
import Combine
import SwiftUI
@testable import NanoWhisper

/// Fixed inputs for one render of the Settings window.
@MainActor
struct SettingsFixture {
    var applied = Fixtures.parakeetUltra
    var draft: EngineConfiguration?
    var state = Fixtures.ready
    var microphone: PermissionStatus = .notDetermined
    var accessibility: PermissionStatus = .notDetermined
    var offersLiveTranscription = true
    var shortcut: Shortcut = Fixtures.productionShortcut
    var historyEnabled = true
    var recorderPosition: RecorderPosition = .defaultPosition
    var appearance: AppAppearance = .system
    /// The build drawn: debug shows Advanced's "Open Onboarding", production does not.
    var flavor: BuildFlavor = .debug
    var updates = Fixtures.updates(.upToDate(lastChecked: Fixtures.checkDate))

    init(applied: EngineConfiguration = Fixtures.parakeetUltra) {
        self.applied = applied
    }

    var context: SettingsContext {
        var context = Fixtures.context(
            applied: applied, state: state, microphone: microphone, accessibility: accessibility,
            offersLiveTranscription: offersLiveTranscription, shortcut: shortcut,
            historyEnabled: historyEnabled, recorderPosition: recorderPosition
        )
        context.appearance = .constant(appearance)
        return context
    }

    func view(for pane: SettingsPane) -> AnyView {
        let context = context
        switch pane {
        case .general:
            return AnyView(GeneralPane(context: context))
        case .engine:
            return AnyView(EnginePane(draft: .constant(draft ?? applied), context: context))
        case .recorder:
            return AnyView(RecorderPane(context: context))
        case .permissions:
            return AnyView(PermissionsPane(context: context))
        case .advanced:
            return AnyView(AdvancedPane(
                updates: updates, actions: UpdateActions(check: {}, install: {}),
                debugMode: .constant(false),
                openOnboarding: AdvancedPane.openOnboardingAction(flavor: flavor) {}
            ))
        }
    }
}

extension Fixtures {
    /// ⌥Space, the production default, as on the design boards.
    static let productionShortcut = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    static let checkDate = Date()

    static func updates(_ state: UpdateStatus.State, appName: String = "NanoWhisper") -> UpdateStatus {
        UpdateStatus(appName: appName, currentVersion: "0.0.6", state: state)
    }
}

/// A pane whose height changes, for the window sizing test.
@MainActor
final class PaneHeightModel: ObservableObject {
    @Published var isTall = false
}

struct ResizingPane: View {
    @ObservedObject var model: PaneHeightModel

    var body: some View {
        SettingsPaneForm {
            SettingsSection("A") {
                Text("First row").settingsRow()
                if model.isTall {
                    ForEach(0..<8) { Text("Row \($0)").settingsRow() }
                }
            }
        }
    }
}

// MARK: - Menu

@MainActor
enum MenuFixtures {
    static let shortcut = Fixtures.productionShortcut

    static func state(_ change: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var state = MenuState(
            appName: "NanoWhisper", debugHeader: nil, setupUnfinished: false,
            microphoneGranted: true, accessibilityGranted: true,
            engine: EngineState(isReady: true, setupComplete: true, progressText: "Setup complete!"),
            modelName: "Parakeet Ultra", modelSize: "~630 MB",
            isRecording: false, isTranscribing: false, lastError: nil,
            update: .upToDate(lastChecked: nil)
        )
        change(&state)
        return state
    }

    /// Every state the menu can show, by render name.
    static var all: [(String, MenuState)] {
        [
            ("ready", state()),
            ("ready-debug", state {
                $0.appName = "NanoWhisper Debug"
                $0.debugHeader = "v0.0.6 · 43c1f2d"
            }),
            ("setup-unfinished-downloading", state {
                $0.setupUnfinished = true
                $0.microphoneGranted = false
                $0.engine = EngineState(isSettingUp: true, progressText: "Downloading model (64%)...")
            }),
            ("first-launch-not-downloaded", state {
                $0.setupUnfinished = true
                $0.accessibilityGranted = false
                $0.engine = EngineState()
            }),
            ("downloading-no-percentage", state {
                $0.modelName = "Whisper Small"
                $0.engine = EngineState(isSettingUp: true, progressText: "Downloading Whisper Small...")
            }),
            ("compiling", state { $0.engine = EngineState(isSettingUp: true, progressText: "Compiling model...") }),
            ("loading", state { $0.engine = EngineState(setupComplete: true) }),
            ("setup-failed", state {
                $0.engine = EngineState(error: "Model setup failed. Please check your internet connection and try again.")
            }),
            ("engine-failed", state {
                $0.engine = EngineState(setupComplete: true, initializationError: AppState.engineStartFailedMessage)
            }),
            ("recording", state { $0.isRecording = true }),
            ("transcribing", state { $0.isTranscribing = true }),
            ("error-line", state { $0.lastError = "Empty transcription" }),
            ("upgrade-downloading", state {
                $0.engine.upgrade = ModelUpgrade(from: .parakeet(.v3), to: .parakeet(.ultra), status: .downloading(fraction: 0.42))
            }),
            ("upgrade-deferred", state {
                $0.engine.upgrade = ModelUpgrade(from: .parakeet(.v3), to: .parakeet(.ultra), status: .deferred)
            }),
            ("update-available", state { $0.update = .available(version: "0.0.7") }),
            ("update-downloading", state { $0.update = .downloading(version: "0.0.7", progress: 0.3) }),
        ]
    }
}

/// The menu's lines drawn like a menu, for renders: an `NSMenu` cannot be drawn offscreen.
/// View-based items use the app's own views (`MenuRowLabel`, `MenuProgressLabel`); native
/// items are approximated with text.
struct MenuPreview: View {
    let lines: [MenuLine]
    let shortcut: Shortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .padding(.vertical, 5)
        .frame(minWidth: 290, alignment: .leading)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
        .padding(12)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var font: Font { .system(size: NSFont.menuFont(ofSize: 0).pointSize) }

    @ViewBuilder
    private func row(_ line: MenuLine) -> some View {
        switch line {
        case .separator:
            Divider().padding(.horizontal, 10).padding(.vertical, 5)
        case .header(let title, let detail):
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(font.bold())
                Text(detail).font(.system(size: NSFont.smallSystemFontSize)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, MenuMetrics.textInset)
            .padding(.vertical, 3)
        case .status(let text, let tone):
            Text(text)
                .font(font)
                .foregroundStyle(tone == .normal ? Color(nsColor: .disabledControlTextColor) : .red)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, MenuMetrics.textInset)
                .frame(height: MenuMetrics.rowHeight)
        case .progress(let text, let fraction):
            MenuProgressLabel(text: text, fraction: fraction)
        case .action(_, let title, let isEnabled, let detail, let showsShortcut, let keyEquivalent):
            if detail != nil || showsShortcut {
                MenuRowLabel(
                    model: .init(title: title, detail: detail, shortcut: showsShortcut ? shortcut : nil, isEnabled: isEnabled),
                    isHighlighted: false
                )
                .frame(height: MenuMetrics.rowHeight)
            } else {
                HStack {
                    Text(title)
                    Spacer()
                    if let keyEquivalent {
                        Text("⌘\(keyEquivalent.uppercased())").foregroundStyle(.secondary)
                    }
                }
                .font(font)
                .foregroundStyle(isEnabled ? Color.primary : Color(nsColor: .disabledControlTextColor))
                .padding(.horizontal, MenuMetrics.textInset)
                .frame(height: MenuMetrics.rowHeight)
            }
        }
    }
}

// MARK: - Recording overlay

/// Every state of the recording overlay in the sheet's appearance, over a wallpaper, each drawn
/// as on screen: the overlay view with its drop shadows behind it (`OverlayDropShadowView`, the
/// shadow window's content, card knocked out).
struct OverlaySheet: View {
    enum Wallpaper: String { case pale, saturated }

    let wallpaper: Wallpaper
    let reduceTransparency: Bool
    private let compact: [(String, RecordingOverlayViewModel)]
    private let cards: [(String, RecordingOverlayViewModel)]

    @MainActor
    init(wallpaper: Wallpaper, reduceTransparency: Bool) {
        self.wallpaper = wallpaper
        self.reduceTransparency = reduceTransparency
        let sentence = "So the plan for this week is the payment flow, then the mobile release. Let’s split it in two: "
            + "first the API, then the checkout screens, and we’ll see how far we get by Thursday"
        let words = sentence.split(separator: " ").map(String.init)
        let long = LiveTranscript(stable: words.prefix(34).joined(separator: " "), volatile: " " + words.dropFirst(34).joined(separator: " "))
        let first = LiveTranscript(stable: words.prefix(7).joined(separator: " "), volatile: " " + words[7...8].joined(separator: " "))
        var final = LiveTranscript()
        final.finalize("So the plan for this week is the payment flow, then the mobile release.")
        compact = [
            ("Recording", OverlayFixtures.model(.recording, elapsed: 7)),
            ("Pointer over it: Stop", OverlayFixtures.model(.recording, elapsed: 12, pointerOver: true)),
            ("Transcribing", OverlayFixtures.model(.loading, elapsed: 12)),
            ("Pasted", OverlayFixtures.model(.finished(.pasted), elapsed: 12)),
            ("No speech detected", OverlayFixtures.model(.finished(.noSpeech), elapsed: 4)),
        ]
        cards = [
            ("Live text, first line", OverlayFixtures.model(.recording, elapsed: 2, transcript: first)),
            ("Live text, long", OverlayFixtures.model(.recording, elapsed: 9, transcript: long)),
            ("Pointer over the card: Stop", OverlayFixtures.model(.recording, elapsed: 9, transcript: long, pointerOver: true)),
            ("Transcribing with text", OverlayFixtures.model(.loading, elapsed: 9, transcript: long)),
            ("Pasted: the final text", OverlayFixtures.model(.finished(.pasted), elapsed: 9, transcript: final)),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(compact)
            row(Array(cards.prefix(2)))
            row(Array(cards.dropFirst(2)))
        }
        .padding(20)
        .background(background)
        .environment(\._accessibilityReduceTransparency, reduceTransparency)
    }

    private func row(_ items: [(String, RecordingOverlayViewModel)]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 0) {
                    Text(items[index].0)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(wallpaper == .pale ? Color(white: 0.2) : .white)
                        .padding(.leading, OverlayShadowPanel.margin.left)
                    OverlayOnScreen(model: items[index].1)
                }
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        switch wallpaper {
        case .pale:
            ZStack {
                OverlayPalette.rgb(0xF3F0F7)
                RadialGradient(colors: [OverlayPalette.rgb(0xFAD3E6), .clear], center: UnitPoint(x: 0.12, y: 0.2), startRadius: 0, endRadius: 600)
                RadialGradient(colors: [OverlayPalette.rgb(0xCFE2FF), .clear], center: UnitPoint(x: 0.85, y: 0.15), startRadius: 0, endRadius: 700)
                RadialGradient(colors: [OverlayPalette.rgb(0xFFF0C2), .clear], center: UnitPoint(x: 0.6, y: 1), startRadius: 0, endRadius: 600)
            }
        case .saturated:
            // Five of the contrast test's saturated wallpapers, side by side.
            LinearGradient(stops: [
                .init(color: OverlayPalette.rgb(0x0A2A6B), location: 0), .init(color: OverlayPalette.rgb(0xC2185B), location: 0.25),
                .init(color: OverlayPalette.rgb(0x1B5E20), location: 0.5), .init(color: OverlayPalette.rgb(0xFF7A00), location: 0.75),
                .init(color: OverlayPalette.rgb(0x4A1A8C), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
    }
}

/// The overlay as the panel and its shadow window draw it: the view, with the drop shadows
/// behind it in the shadow window's margins.
struct OverlayOnScreen: View {
    let model: RecordingOverlayViewModel

    var body: some View {
        let margin = OverlayShadowPanel.margin
        RecordingOverlayView(viewModel: model, onStop: {})
            .fixedSize()
            .padding(EdgeInsets(top: margin.top, leading: margin.left, bottom: margin.bottom, trailing: margin.right))
            .background(OverlayDropShadowView(viewModel: model))
    }
}

@MainActor
enum OverlayFixtures {
    /// A view model in `state`: a still waveform of speech (the transcribing sweep mid-row).
    static func model(
        _ state: OverlayState, elapsed: Int, transcript: LiveTranscript? = nil, pointerOver: Bool = false
    ) -> RecordingOverlayViewModel {
        let waveform: OverlayWaveform
        if state == .loading {
            waveform = OverlayWaveform()
            waveform.start(levels: PassthroughSubject<Float, Never>())
            waveform.markStopped(at: Date().addingTimeInterval(-(WaveformMetrics.sinkDuration + 0.6)))
        } else {
            waveform = OverlayWaveform(staticHistory: WelcomeDictation.history(until: WelcomeDictation.recordingStarts + 3.6))
        }
        let model = RecordingOverlayViewModel(waveform: waveform)
        model.state = state
        model.elapsedSeconds = elapsed
        model.transcript = transcript
        model.isPointerOver = pointerOver
        return model
    }
}

/// The handoff popover's content in an approximation of the popover's bubble (an `NSPopover`
/// cannot be drawn offscreen; `HandoffPopoverWindowTests` captures the real one).
struct HandoffPopoverPreview: View {
    let message: HandoffMessage

    var body: some View {
        HandoffPopoverView(message: message, onOK: {})
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.separator))
            .padding(16)
            .background(Color(nsColor: .underPageBackgroundColor))
    }
}
