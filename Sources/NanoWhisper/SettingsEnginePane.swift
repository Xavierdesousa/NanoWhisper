import SwiftUI

// MARK: - Wording

extension TranscriptionModelType {
    /// Who publishes the engine's models, shown after its name.
    var vendor: String {
        switch self {
        case .parakeet: return "NVIDIA"
        case .whisper: return "OpenAI"
        }
    }

    /// One line under the engine name in Settings › Engine.
    var summary: String {
        switch self {
        case .parakeet: return "The fastest. 25 European languages, detected automatically."
        case .whisper: return "99 languages. Set yours and add words it should know."
        }
    }

    /// The engine of the recommended models' default: Parakeet (Parakeet Ultra is the
    /// default for new installs, `ParakeetVariant.newInstallDefault`).
    var isRecommended: Bool { self == .parakeet }
}

/// The status row of Settings › Engine, for the model in effect (not the draft).
struct EngineStatusDisplay: Equatable {
    enum Accessory: Equatable {
        case none
        /// Green dot and "Ready".
        case ready
        case spinner
        /// "Try Again": retries the download or the engine start.
        case tryAgain
        /// Nothing loaded yet: "Download" or "Load".
        case load(String)
    }

    enum Progress: Equatable {
        case none
        case indeterminate
        case fraction(Double)
    }

    var title: String
    var detail: String
    var isFailure = false
    var progress: Progress = .none
    var accessory: Accessory = .none

    static let tryAgainTitle = "Try Again"

    static func resolve(
        applied: EngineConfiguration, state: EngineState, availability: ModelAvailability
    ) -> EngineStatusDisplay {
        let name = applied.modelName
        let status = ModelStatus.resolve(state)
        // A migration's new model downloading in the background while the previous one works.
        if status == .ready, let upgrade = state.upgrade {
            switch upgrade.status {
            case .downloading(let fraction):
                return EngineStatusDisplay(
                    title: "Downloading \(upgrade.to.displayName)",
                    detail: "\(amount(fraction, of: upgrade.to.sizeDescription)) \(upgrade.from.displayName) stays in use until it is ready.",
                    progress: fraction.map(Progress.fraction) ?? .indeterminate
                )
            case .deferred:
                return EngineStatusDisplay(
                    title: upgrade.from.displayName,
                    detail: "In use, on this Mac. \(upgrade.to.displayName) will download at next launch.",
                    accessory: .ready
                )
            }
        }
        switch status {
        case .ready:
            return EngineStatusDisplay(title: name, detail: "In use, on this Mac.", accessory: .ready)
        case .downloading(let fraction):
            return EngineStatusDisplay(
                title: "Downloading \(name)",
                detail: amount(fraction, of: applied.downloadSize),
                progress: fraction.map(Progress.fraction) ?? .indeterminate
            )
        case .compiling:
            return EngineStatusDisplay(title: name, detail: "Optimizing for this Mac…", accessory: .spinner)
        case .loading:
            return EngineStatusDisplay(title: name, detail: "Loading…", accessory: .spinner)
        case .failed(let message):
            let title = state.error != nil ? "Could not set up \(name)" : "\(name) could not start"
            return EngineStatusDisplay(title: title, detail: message, isFailure: true, accessory: .tryAgain)
        case .notLoaded:
            return EngineStatusDisplay(
                title: name,
                detail: ModelActionText.notLoadedDetail(applied, availability: availability),
                accessory: .load(ModelActionText.loadTitle(availability: availability))
            )
        }
    }

    /// "42% of ~630 MB." or "~630 MB." when the download reports no percentage.
    static func amount(_ fraction: Double?, of size: String) -> String {
        guard let fraction else { return "\(size)." }
        return "\(Int((fraction * 100).rounded()))% of \(size)."
    }
}

/// The row offered when the draft differs from the applied configuration.
struct EngineApplyDisplay: Equatable {
    var title: String
    var detail: String
    var applyTitle: String

    static func resolve(
        draft: EngineConfiguration, applied: EngineConfiguration,
        state: EngineState, availability: ModelAvailability
    ) -> EngineApplyDisplay {
        let loadsModel = state.applyLoadsModel(changesModel: draft.changesModel(from: applied))
        let applyTitle = ModelActionText.applyTitle(availability: availability, loadsModel: loadsModel)
        if loadsModel && availability == .notDownloaded {
            return EngineApplyDisplay(
                title: "\(draft.modelName) needs a \(draft.downloadSize) download",
                detail: "Dictation pauses until it is ready.",
                applyTitle: applyTitle
            )
        }
        return EngineApplyDisplay(
            title: "Changes not applied",
            detail: ModelActionText.applyDetail(draft, availability: availability, loadsModel: loadsModel),
            applyTitle: applyTitle
        )
    }
}

// MARK: - Pane

/// Settings › Engine: the engine and its model, the model status with Apply / Download &
/// Apply and Revert, Whisper's language and vocabulary, and the downloaded models.
///
/// Apply rule: the engine and the model are a draft until Apply / Download & Apply, whose
/// wording states the download first; Revert drops it. Whisper's language and vocabulary never
/// load a model, so they apply right away here.
struct EnginePane: View {
    @Binding var draft: EngineConfiguration
    let context: SettingsContext

    var body: some View {
        SettingsPaneForm {
            EngineChoiceSection(draft: $draft, context: context)
            SettingsSection("Downloaded models") {
                ModelStorageRow(storage: context.storage)
                    .settingsRow()
            }
        }
    }
}

/// The "Engine" section: the two engines, then the model of the selected one with its speed,
/// accuracy and key points (always shown, at the same place, updated in place when the engine
/// or the model changes), Whisper's options, the status of the model in effect and the apply
/// row. Settings › Engine and onboarding's model sheet (Change… on the setup page's Model row)
/// both show it.
struct EngineChoiceSection: View {
    @Binding var draft: EngineConfiguration
    let context: SettingsContext

    private var applied: EngineConfiguration { context.appliedEngine }
    private var isDirty: Bool { draft != applied }

    var body: some View {
        SettingsSection("Engine") {
            ForEach(TranscriptionModelType.allCases, id: \.self) { engine in
                if engine != TranscriptionModelType.allCases.first {
                    GroupedRowDivider()
                }
                EngineChoiceRow(
                    engine: engine,
                    isSelected: draft.modelType == engine,
                    select: { draft.modelType = engine }
                )
                .settingsRow()
            }
            GroupedRowDivider()
            modelRow
                .settingsRow()
            if draft.modelType == .whisper {
                GroupedRowDivider()
                WhisperOptionsGrid(settings: $draft.whisperSettings, apply: context.setWhisperOptions)
                    .settingsRow()
            }
            statusRows
        }
    }

    // MARK: Model of the selected engine

    /// The model picker and, right under it, the comparison. The picker is one row for both
    /// engines and the comparison keeps the height of its longest version, so changing the
    /// engine or the model moves nothing: the bars slide and the text cross-fades.
    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(EngineChoiceText.modelLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: WhisperOptionsGrid.labelWidth, alignment: .leading)
                modelPicker
                    .labelsHidden()
                    .fixedSize()
                Spacer(minLength: 0)
            }
            ModelComparisonView(
                modelType: draft.modelType,
                parakeetVariant: draft.parakeetVariant,
                whisperModelSize: draft.whisperSettings.modelSize
            )
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        switch draft.modelType {
        case .parakeet:
            Picker(EngineChoiceText.modelLabel, selection: $draft.parakeetVariant) {
                ForEach(ParakeetVariant.allCases, id: \.self) {
                    Text(ModelLabel.pickerTitle(name: $0.displayName, size: $0.sizeDescription, isRecommended: $0.isRecommended)).tag($0)
                }
            }
        case .whisper:
            Picker(EngineChoiceText.modelLabel, selection: $draft.whisperSettings.modelSize) {
                ForEach(WhisperModelSize.selectable, id: \.self) {
                    Text(ModelLabel.pickerTitle(name: $0.displayName, size: $0.sizeDescription, isRecommended: $0.isRecommended)).tag($0)
                }
            }
        }
    }

    // MARK: Status and apply

    @ViewBuilder
    private var statusRows: some View {
        let status = EngineStatusDisplay.resolve(
            applied: applied, state: context.engineState, availability: context.availability(applied)
        )
        // As drawn: a pending change replaces the status row while the model in use is ready;
        // a download, a failure or a not-loaded model stays visible above it.
        if !(isDirty && status.accessory == .ready && status.progress == .none) {
            GroupedRowDivider()
            EngineStatusRow(display: status, action: context.loadAppliedModel)
                .settingsRow()
        }
        if isDirty {
            let availability = context.availability(draft)
            let display = EngineApplyDisplay.resolve(
                draft: draft, applied: applied, state: context.engineState, availability: availability
            )
            GroupedRowDivider()
            SettingsRow(title: display.title, caption: display.detail) {
                Button("Revert") { draft = applied }
                Button(display.applyTitle) { context.applyEngine(draft) }
                    .buttonStyle(.borderedProminent)
            }
            .settingsRow()
        }
    }
}

/// Labels of the Engine section.
enum EngineChoiceText {
    /// The picker's label, for both engines (Parakeet's versions and Whisper's sizes).
    static let modelLabel = "Model"
}

/// Radio mark, name, vendor, "Recommended" and summary of an engine.
private struct EngineChoiceRow: View {
    let engine: TranscriptionModelType
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        // A button, so the engine can be chosen with the keyboard (focus, Space) too.
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                RadioMark(isOn: isSelected)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(engine.displayName).fontWeight(.semibold)
                        Text(engine.vendor)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if engine.isRecommended {
                            Text(ModelLabel.recommendedBadge)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    SettingsCaption(engine.summary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A radio button mark in the brand color.
struct RadioMark: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(Color.accentColor)
                Circle().fill(.white).frame(width: 6, height: 6)
            } else {
                Circle().fill(Color(nsColor: .controlBackgroundColor))
                Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// Whisper language and vocabulary hint. They edit the draft and are applied at once.
private struct WhisperOptionsGrid: View {
    @Binding var settings: WhisperSettings
    let apply: (_ language: String?, _ promptText: String) -> Void

    static let labelWidth: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                label("Language")
                Picker("Language", selection: languageBinding) {
                    Text("Detect automatically").tag("")
                    Divider()
                    ForEach(WhisperLanguage.supported, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                label("Vocabulary")
                TextField("Vocabulary", text: promptBinding, prompt: Text("Names and terms, separated by commas"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            SettingsCaption(caption)
        }
    }

    private var caption: String {
        let applies = "Language and vocabulary apply right away; nothing downloads."
        guard settings.language == nil else { return applies }
        return "Detecting the language works best on longer audio; for short clips, choose it. \(applies)"
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: Self.labelWidth, alignment: .leading)
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { settings.language ?? "" },
            set: {
                settings.language = $0.isEmpty ? nil : $0
                apply(settings.language, settings.promptText)
            }
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { settings.promptText },
            set: {
                settings.promptText = $0
                apply(settings.language, settings.promptText)
            }
        )
    }
}

/// The status of the model in effect: name, detail, progress, and Ready / Try Again / Download.
struct EngineStatusRow: View {
    let display: EngineStatusDisplay
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow(
                title: display.title, caption: display.detail,
                titleColor: display.isFailure ? .red : nil
            ) {
                switch display.accessory {
                case .none:
                    EmptyView()
                case .ready:
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Ready").font(.callout)
                    }
                    .accessibilityElement(children: .combine)
                case .spinner:
                    ProgressView().controlSize(.small)
                case .tryAgain:
                    Button(EngineStatusDisplay.tryAgainTitle, action: action)
                case .load(let title):
                    Button(title, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
            switch display.progress {
            case .none:
                EmptyView()
            case .indeterminate:
                ProgressView().progressViewStyle(.linear)
            case .fraction(let value):
                ProgressView(value: value)
            }
        }
    }
}
