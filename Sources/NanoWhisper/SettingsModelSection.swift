import SwiftUI

/// Engine and model choice, shared by Settings and onboarding.
///
/// Apply rule (both screens): every control edits `draft` only. Nothing is downloaded or
/// switched until the user clicks Apply / Download & Apply, whose caption states the
/// download size first. Revert drops the draft. The status row always describes the model
/// in effect, with its download progress, error and Retry.
struct ModelSettingsSection: View {
    @Binding var draft: EngineConfiguration
    let context: SettingsContext

    private var applied: EngineConfiguration { context.appliedEngine }
    private var isDirty: Bool { draft != applied }

    var body: some View {
        Section("Model") {
            Picker("Engine", selection: $draft.modelType) {
                ForEach(TranscriptionModelType.allCases, id: \.self) { model in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.displayName)
                        Text(model.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 2)
                    .tag(model)
                }
            }
            .pickerStyle(.radioGroup)

            switch draft.modelType {
            case .parakeet:
                Picker("Version", selection: $draft.parakeetVariant) {
                    ForEach(ParakeetVariant.allCases, id: \.self) { variant in
                        Text(ModelLabel.pickerTitle(
                            name: variant.displayName, size: variant.sizeDescription,
                            isRecommended: variant.isRecommended
                        )).tag(variant)
                    }
                }
            case .whisper:
                WhisperOptionsRows(settings: $draft.whisperSettings)
            }
        }

        // Status and Apply right under the choice, so the cost and the action stay visible.
        Section {
            ModelStatusRow(context: context)
            if isDirty {
                applyRow
            }
        }

        Section {
            ModelComparisonView(
                modelType: draft.modelType,
                parakeetVariant: draft.parakeetVariant,
                whisperModelSize: draft.whisperSettings.modelSize
            )
        } header: {
            Text("About \(draft.modelName)")
        }
    }

    private var applyRow: some View {
        let availability = context.availability(draft)
        let loadsModel = context.engineState.applyLoadsModel(changesModel: draft.changesModel(from: applied))
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Changes not applied")
                Text(ModelActionText.applyDetail(draft, availability: availability, loadsModel: loadsModel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Revert") { draft = applied }
            Button(ModelActionText.applyTitle(availability: availability, loadsModel: loadsModel)) {
                context.applyEngine(draft)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Whisper model size, language and vocabulary hint.
private struct WhisperOptionsRows: View {
    @Binding var settings: WhisperSettings

    var body: some View {
        Picker("Model size", selection: $settings.modelSize) {
            ForEach(WhisperModelSize.selectable, id: \.self) { size in
                Text(ModelLabel.pickerTitle(
                    name: size.displayName, size: size.sizeDescription, isRecommended: size.isRecommended
                )).tag(size)
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            Picker("Language", selection: languageBinding) {
                Text("Auto-detect").tag("")
                Divider()
                ForEach(WhisperLanguage.supported, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            if settings.language == nil {
                Text("Auto-detect works best on longer audio. For short clips, choosing the language improves accuracy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            TextField("Vocabulary hint", text: $settings.promptText, prompt: Text("Optional"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
            Text("Words or phrases to help recognition, such as names or technical terms.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { settings.language ?? "" },
            set: { settings.language = $0.isEmpty ? nil : $0 }
        )
    }
}

/// Name and live status of the model in effect: Ready, download progress, error with
/// Retry, or Download / Load when nothing is loaded yet.
struct ModelStatusRow: View {
    let context: SettingsContext

    private var applied: EngineConfiguration { context.appliedEngine }
    private var status: ModelStatus { context.modelStatus }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(applied.modelName)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing
            }
            if case .downloading(let fraction) = status {
                progressBar(fraction)
            } else if status == .ready, let upgrade = context.engineState.upgrade {
                // A migration's new model downloading while the previous one is in use.
                if case .downloading(let fraction) = upgrade.status {
                    progressBar(fraction)
                }
            }
        }
    }

    @ViewBuilder
    private func progressBar(_ fraction: Double?) -> some View {
        if let fraction {
            ProgressView(value: fraction)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    private var detail: String {
        if status == .ready, let upgrade = context.engineState.upgrade {
            switch upgrade.status {
            case .downloading: return "\(ModelUpgradeText.progress(upgrade))\n\(ModelUpgradeText.detail(upgrade))"
            case .deferred: return ModelUpgradeText.detail(upgrade)
            }
        }
        switch status {
        case .ready: return "In use · \(applied.downloadSize)"
        case .downloading(let fraction):
            guard let fraction else { return "Downloading \(applied.downloadSize)…" }
            return "Downloading \(applied.downloadSize)… \(Int((fraction * 100).rounded()))%"
        case .compiling: return "Optimizing for this Mac…"
        case .loading: return "Loading…"
        case .failed(let message): return message
        case .notLoaded:
            return ModelActionText.notLoadedDetail(applied, availability: context.availability(applied))
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading, .compiling, .loading:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Button("Retry", action: context.loadAppliedModel)
        case .notLoaded:
            Button(ModelActionText.loadTitle(availability: context.availability(applied)),
                   action: context.loadAppliedModel)
                .buttonStyle(.borderedProminent)
        }
    }
}
