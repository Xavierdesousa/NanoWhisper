import SwiftUI

/// User-facing app name of this build ("NanoWhisper" or "NanoWhisper Debug").
private let appName = BuildFlavor.current.displayName

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @StateObject private var permissions = PermissionMonitor()
    @State private var step: OnboardingStep = .welcome
    /// Model choices are edited here and take effect on Apply, as in Settings.
    @State private var draft: EngineConfiguration
    /// Replaying (onboarding already completed): settings are kept as they are.
    private let isReplay: Bool
    var onFinish: () -> Void

    init(appState: AppState, onFinish: @escaping () -> Void) {
        self.appState = appState
        self.onFinish = onFinish
        isReplay = !appState.isFirstLaunch
        _draft = State(initialValue: appState.engineConfiguration)
    }

    var body: some View {
        OnboardingContent(
            step: $step,
            draft: $draft,
            context: appState.settingsContext(permissions: permissions),
            tryIt: TryItState(
                isEngineReady: appState.isEngineReady,
                isRecording: appState.isRecording,
                isTranscribing: appState.isTranscribing,
                transcript: appState.testTranscription,
                toggleRecording: { appState.toggleRecording() }
            ),
            isReplay: isReplay,
            onFinish: onFinish
        )
        .onAppear { permissions.start() }
        .onDisappear {
            permissions.stop()
            appState.capturesTestTranscription = false
        }
        .onChange(of: step) { _, newStep in
            appState.capturesTestTranscription = newStep == .done
        }
    }
}

/// State of the "Try It" box on the last step.
struct TryItState {
    var isEngineReady: Bool
    var isRecording: Bool
    var isTranscribing: Bool
    /// Last test dictation: nil before the first one, empty when nothing was recognized.
    var transcript: String?
    var toggleRecording: () -> Void
}

// MARK: - Layout

/// The onboarding screens: a step indicator, one step at a time, and Back / Continue.
struct OnboardingContent: View {
    @Binding var step: OnboardingStep
    @Binding var draft: EngineConfiguration
    let context: SettingsContext
    let tryIt: TryItState
    let isReplay: Bool
    let onFinish: () -> Void

    /// Fixed window size; fits a 13" display at its largest text size setting.
    static let size = CGSize(width: 560, height: 600)
    /// Only the render tests change it, to see a step's whole content.
    var height: CGFloat = Self.size.height

    private var progress: OnboardingProgress {
        OnboardingProgress(
            modelReady: context.engineState.isReady && draft == context.appliedEngine,
            microphoneGranted: context.microphone.isGranted,
            accessibilityGranted: context.accessibility.isGranted
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStepIndicator(current: step, progress: progress)
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
            Divider()
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: height)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            WelcomeStep(isReplay: isReplay)
        case .model:
            OnboardingForm(
                title: "Choose a speech model",
                subtitle: "It runs entirely on this Mac and is downloaded once. You can continue while it downloads, and change it later in Settings."
            ) {
                ModelSettingsSection(draft: $draft, context: context)
            }
        case .permissions:
            OnboardingForm(
                title: "Allow access",
                subtitle: "\(appName) needs two permissions. Changes made in System Settings show up here automatically."
            ) {
                PermissionsSettingsSection(context: context)
            }
        case .shortcut:
            OnboardingForm(
                title: "Shortcut and essentials",
                subtitle: "Choose how you start dictating. Everything here is also in Settings."
            ) {
                ShortcutSettingsSection(context: context)
                GeneralSettingsSection(context: context)
            }
        case .done:
            DoneStep(context: context, progress: progress, tryIt: tryIt)
        }
    }

    private var footer: some View {
        HStack {
            if step.canSkip {
                Button("Skip Setup", action: onFinish)
                    .help("Close onboarding and keep the current settings")
            }
            Spacer()
            if let previous = step.previous {
                Button("Back") { step = previous }
            }
            Button(step.primaryButtonTitle) {
                if let next = step.next {
                    step = next
                } else {
                    onFinish()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// Step names with their state: done, current, to do, or passed but not done.
struct OnboardingStepIndicator: View {
    let current: OnboardingStep
    let progress: OnboardingProgress

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                if step != OnboardingStep.allCases.first {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
                item(for: step)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count): \(current.title)")
    }

    private func item(for step: OnboardingStep) -> some View {
        let state = progress.indicatorState(of: step, current: current)
        return HStack(spacing: 4) {
            Image(systemName: symbol(for: step, state: state))
                .foregroundStyle(color(for: state))
            Text(step.title)
                .font(.caption)
                .fontWeight(state == .current ? .semibold : .regular)
                .foregroundStyle(state == .current ? .primary : .secondary)
        }
        .fixedSize()
        .help(help(for: step, state: state))
    }

    private func symbol(for step: OnboardingStep, state: StepIndicatorState) -> String {
        switch state {
        case .complete: return "checkmark.circle.fill"
        case .needsAttention: return "exclamationmark.circle.fill"
        case .current: return "\(step.rawValue + 1).circle.fill"
        case .upcoming: return "\(step.rawValue + 1).circle"
        }
    }

    private func color(for state: StepIndicatorState) -> Color {
        switch state {
        case .complete: return .green
        case .needsAttention: return .orange
        case .current: return .accentColor
        case .upcoming: return .secondary
        }
    }

    private func help(for step: OnboardingStep, state: StepIndicatorState) -> String {
        switch state {
        case .complete: return "\(step.title): done"
        case .needsAttention: return "\(step.title): not done yet"
        case .current, .upcoming: return step.title
        }
    }
}

/// A step's title and explanation above its grouped form.
private struct OnboardingForm<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingHeader(title: title, subtitle: subtitle)
                .padding(.horizontal, 20)
                .padding(.top, 18)
            Form { content }
                .formStyle(.grouped)
        }
    }
}

private struct OnboardingHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let isReplay: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                AppIconImage()
                    .frame(width: 72, height: 72)
                Text("Welcome to \(appName)")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Dictate into any app from your menu bar. Speech is transcribed on this Mac and never sent to a server.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            .padding(.top, 24)

            Form {
                Section("Setup takes a minute") {
                    WelcomeRow(systemImage: "cpu", title: "Choose a speech model",
                               detail: "Downloaded once, then everything works offline.")
                    WelcomeRow(systemImage: "lock.shield", title: "Allow the microphone and accessibility",
                               detail: "To hear you, and to paste the text where you type.")
                    WelcomeRow(systemImage: "keyboard", title: "Pick your shortcut",
                               detail: "Press it anywhere to start and stop dictating.")
                }
                if isReplay {
                    Section {
                        Label("Your current settings are kept. Nothing is downloaded unless you apply another model.",
                              systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
    }
}

private struct WelcomeRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DoneStep: View {
    let context: SettingsContext
    let progress: OnboardingProgress
    let tryIt: TryItState

    private var shortcut: String { context.shortcut.displayString }

    var body: some View {
        OnboardingForm(
            title: progress.pendingSteps.isEmpty ? "You're all set" : "Almost done",
            subtitle: progress.pendingSteps.isEmpty
                ? "\(appName) is ready. It lives in your menu bar."
                : "\(appName) lives in your menu bar. A few things still need attention."
        ) {
            Section("How to use it") {
                HStack(spacing: 12) {
                    MenuBarIconImage()
                        .frame(width: 28)
                    Text("Click the \(appName) icon in the menu bar for your history, settings and status.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Image(systemName: "keyboard")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    Text("Press **\(shortcut)** to start recording, and again to stop. The text is pasted where your cursor is.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !progress.pendingSteps.isEmpty {
                Section {
                    if !progress.isComplete(.model) {
                        ModelStatusRow(context: context)
                    }
                    ForEach(Permission.allCases.filter { !context.status(of: $0).isGranted }) { permission in
                        PermissionRow(
                            permission: permission,
                            status: context.status(of: permission),
                            onRequest: { context.requestPermission(permission) }
                        )
                    }
                } header: {
                    Text("Still to do")
                } footer: {
                    if context.modelStatus == .notLoaded {
                        Text("If you finish now, the model downloads in the background.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Section("Try it") {
                TryItRows(tryIt: tryIt, shortcut: shortcut, microphoneGranted: context.microphone.isGranted)
            }
        }
    }
}

/// Record a short test and show the text here instead of pasting it.
private struct TryItRows: View {
    let tryIt: TryItState
    let shortcut: String
    let microphoneGranted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                tryIt.toggleRecording()
            } label: {
                Label(tryIt.isRecording ? "Stop" : "Record a Test",
                      systemImage: tryIt.isRecording ? "stop.fill" : "mic.fill")
            }
            .disabled(!tryIt.isEngineReady || tryIt.isTranscribing)
        }

        if tryIt.isTranscribing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
                    .foregroundStyle(.secondary)
            }
        } else if let transcript = tryIt.transcript {
            if transcript.isEmpty {
                Label("Nothing was recognized. Try again and speak a little longer.",
                      systemImage: "exclamationmark.bubble")
                    .foregroundStyle(.secondary)
            } else {
                Text(transcript)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
        }
    }

    private var caption: String {
        if !tryIt.isEngineReady { return "Available once the model is ready." }
        if !microphoneGranted { return "Allow the microphone first." }
        if tryIt.isRecording { return "Listening… click Stop or press \(shortcut) when done." }
        return "Click the button or press \(shortcut), say a sentence, then stop. The text shows here instead of being pasted."
    }
}

// MARK: - Icons

private struct AppIconImage: View {
    var body: some View {
        if let icon = NSImage(named: "AppIcon") {
            Image(nsImage: icon).resizable()
        } else {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
        }
    }
}

private struct MenuBarIconImage: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "menubar_icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "mic")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Window Controller

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    /// - Parameters:
    ///   - onFinish: Finish or Skip Setup was clicked.
    ///   - onClose: the window closed, by any means (also after `onFinish`).
    func show(appState: AppState, onFinish: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // A new window each time, so a replay starts again from the first step.
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingContent.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = appName
        w.contentView = NSHostingView(rootView: OnboardingView(appState: appState, onFinish: onFinish))
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.collectionBehavior = [.moveToActiveSpace]
        w.delegate = self
        centerOnCurrentScreen(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }
}
