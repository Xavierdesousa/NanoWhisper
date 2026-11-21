import SwiftUI

// MARK: - Setup page

/// The second page, a grouped form in four sections: Getting ready (the two permissions),
/// Model, Dictation (the shortcut) and Settings (four switches). Continue is always available.
struct SetupPage: View {
    let context: SettingsContext
    let appIcon: NSImage
    let onChangeModel: () -> Void
    let onContinue: () -> Void
    /// Renders only: show the Model row's Change… as under the pointer.
    var revealsModelChange = false
    /// Renders only: the shortcut row recording a new shortcut.
    var recordsShortcut = false

    private var model: ModelChecklistDisplay {
        ModelChecklistDisplay.resolve(
            applied: context.appliedEngine, state: context.engineState,
            availability: context.availability(context.appliedEngine)
        )
    }

    var body: some View {
        let model = self.model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                header
                OnboardingSection(title: OnboardingText.gettingReady) {
                    permissionRow(.microphone)
                    OnboardingRowDivider()
                    permissionRow(.accessibility)
                }
                OnboardingSection(title: OnboardingText.modelSection) {
                    ModelChecklistRow(
                        display: model, onChange: onChangeModel, onRetry: context.loadAppliedModel,
                        revealsChange: revealsModelChange
                    )
                }
                OnboardingSection(title: OnboardingText.dictationSection) {
                    ShortcutRecorderRow(
                        shortcut: context.shortcut, onChange: context.setShortcut,
                        isCompact: true, isRecording: recordsShortcut
                    )
                    .font(.system(size: 13))
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(minHeight: 34)
                }
                OnboardingSection(title: OnboardingText.settingsSection) {
                    toggleRow(SettingsText.openAtLogin, isOn: context.launchAtLogin)
                    OnboardingRowDivider()
                    toggleRow(SettingsText.pauseMedia, isOn: context.pauseMediaEnabled)
                    OnboardingRowDivider()
                    toggleRow(
                        SettingsText.keepHistory,
                        caption: context.historyUnavailable ? SettingsText.historyUnavailable : SettingsText.keepHistoryCaption,
                        captionIsProblem: context.historyUnavailable,
                        isOn: context.historyEnabled
                    )
                    .disabled(context.historyUnavailable)
                    OnboardingRowDivider()
                    toggleRow(SettingsText.sounds, isOn: context.soundEnabled)
                }
            }
            .padding(.top, 32)
            .padding(.horizontal, 28)
            .padding(.bottom, 10)

            Spacer(minLength: 0)
            footer(note: SetupFooterNote.resolve(
                microphone: context.microphone, model: model, engine: context.appliedEngine.modelType))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(OnboardingText.setupTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(OnboardingPalette.label)
                    .accessibilityAddTraits(.isHeader)
                Text(OnboardingText.setupSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingPalette.secondaryLabel)
            }
        }
    }

    private func permissionRow(_ permission: Permission) -> some View {
        let status = context.status(of: permission)
        return PermissionChecklistRow(
            title: permission == .microphone ? OnboardingText.microphone : OnboardingText.pasting,
            tag: permission == .microphone ? OnboardingText.required : OnboardingText.recommended,
            tagIsStrong: permission == .microphone,
            display: .resolve(permission, status: status, historyEnabled: context.historyEnabled.wrappedValue),
            onRequest: { context.requestPermission(permission) }
        )
    }

    private func toggleRow(
        _ title: String, caption: String? = nil, captionIsProblem: Bool = false, isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingPalette.label)
                if let caption {
                    OnboardingCaption(caption, isProblem: captionIsProblem)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 34)
        .accessibilityElement(children: .combine)
    }

    private func footer(note: String) -> some View {
        VStack(spacing: 0) {
            OnboardingRowDivider()
            HStack(spacing: 12) {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OnboardingPalette.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onContinue) {
                    Text(OnboardingText.continueButton)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.leading, 24)
            .padding(.trailing, 20)
            .frame(height: 56)
        }
    }
}

// MARK: - Rows

/// A permission: the circle (a check once allowed), the name, its tag and caption, and the one
/// action it needs.
struct PermissionChecklistRow: View {
    let title: String
    let tag: String
    var tagIsStrong = false
    let display: PermissionChecklistDisplay
    let onRequest: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SetupMarkView(mark: display.mark)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.system(size: 13))
                            .foregroundStyle(OnboardingPalette.label)
                        OnboardingTag(text: tag, isStrong: tagIsStrong)
                    }
                    .frame(minHeight: 18)
                    OnboardingCaption(display.caption, isProblem: display.isProblem)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityValue(display.mark == .checked ? OnboardingText.allowed : OnboardingText.notAllowed)
            if let buttonTitle = display.buttonTitle {
                Button(buttonTitle, action: onRequest)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The model in effect: its status on the left (a ring while it downloads, then a check), the
/// name and what it is, and on the right the download amount. Change… appears there under the
/// pointer or with keyboard focus, and opens the model choice.
struct ModelChecklistRow: View {
    let display: ModelChecklistDisplay
    let onChange: () -> Void
    let onRetry: () -> Void
    var revealsChange = false
    @State private var isHovering = false
    @FocusState private var changeHasFocus: Bool

    private var showsChange: Bool { isHovering || changeHasFocus || revealsChange }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SetupMarkView(mark: display.mark)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(display.title)
                        .font(.system(size: 13))
                        .foregroundStyle(OnboardingPalette.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailing
                }
                .frame(minHeight: 18)
                OnboardingCaption(display.caption, isProblem: display.isProblem)
                    .accessibilityValue(display.isDone ? OnboardingText.modelDone : (display.detail ?? ""))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: showsChange)
        // Change… is invisible until hovered or focused: VoiceOver reaches it as an action too.
        .accessibilityAction(named: Text(OnboardingText.change), onChange)
    }

    @ViewBuilder
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            if let detail = display.detail {
                Text(detail)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(OnboardingPalette.secondaryLabel)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(showsChange ? 0 : 1)
                    .accessibilityHidden(showsChange)
            }
            Button(OnboardingText.change, action: onChange)
                .buttonStyle(.link)
                .font(.system(size: 12.5, weight: .medium))
                .focused($changeHasFocus)
                .opacity(showsChange ? 1 : 0)
                .fixedSize()
        }
        if display.offersRetry {
            Button(OnboardingText.tryAgain, action: onRetry)
                .controlSize(.small)
                .fixedSize()
        }
    }
}

// MARK: - Model choice (Change…)

/// The model choice, as in Settings › Engine: the engines with their versions, the status and
/// the apply row (nothing downloads until Apply / Download & Apply). Done closes it; a change
/// not applied is dropped, as when Settings closes.
struct ModelChoiceSheet: View {
    @Binding var draft: EngineConfiguration
    let context: SettingsContext
    let onDone: () -> Void

    static let width: CGFloat = 540

    var body: some View {
        VStack(spacing: 0) {
            Form {
                EngineChoiceSection(draft: $draft, context: context, showsModelPicker: true)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(OnboardingText.modelChoiceDone, action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: Self.width)
    }
}

/// The sheet bound to the running app; its draft starts from the model in effect.
struct LiveModelChoiceSheet: View {
    @ObservedObject var appState: AppState
    @ObservedObject var permissions: PermissionMonitor
    let onDone: () -> Void
    @State private var draft: EngineConfiguration

    init(appState: AppState, permissions: PermissionMonitor, onDone: @escaping () -> Void) {
        self.appState = appState
        self.permissions = permissions
        self.onDone = onDone
        _draft = State(initialValue: appState.engineConfiguration)
    }

    var body: some View {
        ModelChoiceSheet(draft: $draft, context: appState.settingsContext(permissions: permissions), onDone: onDone)
            // Applied: an untouched draft follows the configuration in effect.
            .onChange(of: appState.engineConfiguration) { old, new in
                if draft == old { draft = new }
            }
    }
}
