import SwiftUI

/// What the Try it page reads, as values and actions: the live window builds it from
/// `AppState`, the render tests from fixtures.
struct TryItInputs {
    var stage: TryItStage
    var shortcut: Shortcut
    /// Where the recorder appears (the page says where to look).
    var recorderPosition: RecorderPosition
    /// Live transcription is on for this recording (debug builds): the words show in the recorder.
    var showsLiveWords: Bool
    var model: EngineConfiguration
    /// Start Recording and Stop: the same toggle as the shortcut.
    var toggleRecording: () -> Void = {}
    /// Try Again: clears the result, back to the ready state.
    var tryAgain: () -> Void = {}
    /// Allow… (system request) or Open System Settings, by the microphone's status.
    var requestMicrophone: () -> Void = {}
    var retryModel: () -> Void = {}
}

/// The third page: the instructions and the result in the window; the recorder itself is the
/// real overlay, at its real place on the screen (never in the window).
struct TryItPage: View {
    let inputs: TryItInputs
    let onBack: () -> Void
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let stageSize = CGSize(width: 484, height: 356)

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text(OnboardingText.tryTitle)
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.45)
                    .foregroundStyle(OnboardingPalette.label)
                    .accessibilityAddTraits(.isHeader)
                InlineShortcutText(
                    before: OnboardingText.tryInstructionBefore, shortcut: inputs.shortcut,
                    after: OnboardingText.tryInstructionAfter
                )
                .foregroundStyle(OnboardingPalette.secondaryLabel)
                .frame(maxWidth: 440)
                .padding(.top, 6)

                stage
                    .padding(.top, 22)
            }
            .padding(.top, 48)
            .padding(.horizontal, 48)

            Spacer(minLength: 0)
            footer
        }
    }

    // MARK: Stage

    private var stage: some View {
        ZStack {
            // The shared card (`GroupedStyle`): same color and radius, no border.
            RoundedRectangle(cornerRadius: GroupedStyle.cornerRadius, style: .continuous).fill(GroupedStyle.card)
            stageContent
                .id(StageKind(inputs.stage))
                .transition(.opacity)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
        }
        .frame(width: Self.stageSize.width, height: Self.stageSize.height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: StageKind(inputs.stage))
    }

    @ViewBuilder
    private var stageContent: some View {
        switch inputs.stage {
        case .ready:
            VStack(spacing: 10) {
                pressLine(OnboardingText.toStart)
                Text(OnboardingText.or)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OnboardingPalette.secondaryLabel)
                Button(OnboardingText.startRecording, action: inputs.toggleRecording)
                    .controlSize(.large)
                note(OnboardingText.readyNote(inputs.recorderPosition), size: 11.5, maxWidth: 330)
                    .padding(.top, 8)
            }
        case .listening:
            VStack(spacing: 10) {
                title(OnboardingText.listening)
                note(OnboardingText.listeningNote(inputs.recorderPosition, showsWords: inputs.showsLiveWords), maxWidth: 330)
                pressLine(OnboardingText.againToStop)
                    .padding(.top, 6)
                Button(OnboardingText.stop, action: inputs.toggleRecording)
                    .controlSize(.large)
            }
        case .transcribing:
            Text(OnboardingText.transcribing)
                .font(.system(size: 13.5))
                .foregroundStyle(OnboardingPalette.secondaryLabel)
        case .result(let text):
            VStack(spacing: 10) {
                if text.isEmpty {
                    title(OnboardingText.nothingRecognized)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                } else {
                    Text(OnboardingText.youSaid)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OnboardingPalette.secondaryLabel)
                    Text(text)
                        .font(.system(size: 19, weight: .medium))
                        .tracking(-0.2)
                        .lineSpacing(4)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(OnboardingPalette.label)
                        .frame(maxWidth: 400)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(6)
                        .textSelection(.enabled)
                    Text(OnboardingText.transcribedHere)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OnboardingPalette.secondaryLabel)
                        .padding(.top, 2)
                }
                HStack(spacing: 6) {
                    Text(OnboardingText.press)
                    ShortcutKeysView(shortcut: inputs.shortcut, size: .small)
                    Text(OnboardingText.or)
                    Button(OnboardingText.tryAgain, action: inputs.tryAgain)
                        .controlSize(.small)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(OnboardingPalette.secondaryLabel)
                .padding(.top, 10)
            }
        case .microphoneMissing(let status):
            VStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(OnboardingPalette.warningRing, lineWidth: 2)
                    ExclamationGlyph().fill(OnboardingPalette.warning).frame(width: 18, height: 18)
                }
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
                let denied = status == .denied
                title(denied ? OnboardingText.microphoneOff : OnboardingText.microphoneNotAllowed)
                note(denied ? OnboardingText.microphoneOffNote : OnboardingText.microphoneNotAllowedNote, maxWidth: 340)
                if let action = Permission.actionTitle(for: status) {
                    Button(action, action: inputs.requestMicrophone)
                        .controlSize(.large)
                        .padding(.top, 4)
                }
            }
        case .modelNotReady(let status):
            modelNotReady(status)
        }
    }

    @ViewBuilder
    private func modelNotReady(_ status: ModelStatus) -> some View {
        let name = inputs.model.modelName
        VStack(spacing: 10) {
            switch status {
            case .failed(let message):
                title(OnboardingText.modelFailed(name))
                note(message, maxWidth: 360)
                Button(OnboardingText.tryAgain, action: inputs.retryModel)
                    .controlSize(.large)
            case .compiling, .loading:
                title(status == .compiling ? OnboardingText.optimizingModel(name) : OnboardingText.loadingModel(name))
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 260)
                    .padding(.top, 4)
                note(OnboardingText.modelPreparingNote, maxWidth: 360)
                    .padding(.top, 6)
            case .downloading, .notLoaded, .ready:
                let fraction: Double? = if case .downloading(let value) = status { value } else { nil }
                title(OnboardingText.stillDownloading(name))
                Group {
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                .frame(width: 260)
                .padding(.top, 4)
                Text(OnboardingText.downloadAmount(fraction, of: inputs.model.downloadSize))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(OnboardingPalette.secondaryLabel)
                note(OnboardingText.modelNotReadyNote, maxWidth: 360)
                    .padding(.top, 6)
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(OnboardingPalette.label)
    }

    private func note(_ text: String, size: CGFloat = 12.5, maxWidth: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size))
            .lineSpacing(size >= 12.5 ? 3 : 1.5)
            .multilineTextAlignment(.center)
            .foregroundStyle(OnboardingPalette.secondaryLabel)
            .frame(maxWidth: maxWidth)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Press ⌥ Space to start".
    private func pressLine(_ end: String) -> some View {
        HStack(spacing: 6) {
            Text(OnboardingText.press)
            ShortcutKeysView(shortcut: inputs.shortcut)
            Text(end)
        }
        .font(.system(size: 13.5))
        .foregroundStyle(OnboardingPalette.label)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            GroupedRowDivider(inset: 0)
            HStack(spacing: 12) {
                Button(OnboardingText.back, action: onBack)
                    .controlSize(.large)
                Spacer()
                Button(action: onFinish) {
                    Text(OnboardingText.finishSetup)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!inputs.stage.allowsFinish)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
        }
    }
}

/// The stage's state without its values, so a download's progress does not replay the
/// state change's fade.
private enum StageKind: Hashable {
    case ready, listening, transcribing, result, microphoneMissing, modelNotReady

    init(_ stage: TryItStage) {
        switch stage {
        case .ready: self = .ready
        case .listening: self = .listening
        case .transcribing: self = .transcribing
        case .result: self = .result
        case .microphoneMissing: self = .microphoneMissing
        case .modelNotReady: self = .modelNotReady
        }
    }
}
