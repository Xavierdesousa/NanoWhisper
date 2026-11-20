import SwiftUI

// MARK: - Model

/// What "Remove Unused Models…" would remove, shown before anything is deleted.
struct UnusedModelsPreview: Equatable, Identifiable, Sendable {
    var id = UUID()
    var removable: [StoredModel]
    /// Known models kept because this app uses them.
    var keptInUse: [StoredModel]
    /// Known models kept because the other NanoWhisper flavor may use them.
    var keptForOtherFlavor: [StoredModel]
    var otherFlavorName: String
    /// The Whisper cache could not be read (Documents access denied).
    var whisperAccessDenied: Bool

    var totalBytes: Int64 { removable.reduce(0) { $0 + $1.bytes } }
}

extension ModelStore {
    /// Scan both caches (the Whisper one may show the Documents prompt: user-initiated).
    func unusedModelsPreview(
        keepingInUse inUse: Set<ModelFolder>,
        otherFlavor: Set<ModelFolder>,
        otherFlavorName: String
    ) -> UnusedModelsPreview {
        var found: [StoredModel] = []
        var denied = false
        for cache in ModelFolder.Cache.allCases {
            switch scan(cache) {
            case .scanned(let models): found += models
            case .accessDenied: denied = denied || cache == .whisperKit
            }
        }
        let removable = ModelCleanupPolicy.unused(in: found, keeping: inUse.union(otherFlavor))
        return UnusedModelsPreview(
            removable: found.filter { removable.contains($0.folder) },
            keptInUse: found.filter { inUse.contains($0.folder) },
            keptForOtherFlavor: found.filter { otherFlavor.contains($0.folder) && !inUse.contains($0.folder) },
            otherFlavorName: otherFlavorName,
            whisperAccessDenied: denied
        )
    }

    /// Remove what `preview` listed (the user confirmed it), minus anything `keep` names now.
    func removeUnusedModels(_ preview: UnusedModelsPreview, keeping keep: Set<ModelFolder>) -> ModelRemovalReport {
        let confirmed = Set(preview.removable.map(\.folder))
        let caches = Set(confirmed.map(\.cache))
        return removeModels(in: caches) { found in
            confirmed.intersection(ModelCleanupPolicy.unused(in: found, keeping: keep))
        }
    }
}

/// The "Remove Unused Models…" action, as the Settings section sees it.
struct ModelStorageContext {
    /// Why the button is disabled; nil when it can be used.
    var unavailableReason: String?
    var preview: @MainActor () async -> UnusedModelsPreview
    var remove: @MainActor (UnusedModelsPreview) async -> ModelRemovalReport

    /// Disabled while a download or a model switch is in progress, or nothing is loaded:
    /// "unused" is only well defined once the selected model is loaded.
    static func unavailableReason(_ state: EngineState) -> String? {
        if state.isSettingUp || state.upgrade?.isDownloading == true {
            return "Unavailable while a model is downloading or loading."
        }
        if !state.isReady {
            return "Available once the selected model is loaded."
        }
        return nil
    }
}

enum ModelStorageText {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static let accessDenied = "Whisper models were not checked: NanoWhisper cannot open the Documents folder. You can allow it in System Settings › Privacy & Security › Files and Folders."

    static func result(_ report: ModelRemovalReport) -> String {
        var parts: [String] = []
        switch report.removed.count {
        case 0: parts.append("Nothing was removed.")
        case 1: parts.append("Removed 1 model and freed \(size(report.freedBytes)).")
        case let count: parts.append("Removed \(count) models and freed \(size(report.freedBytes)).")
        }
        if !report.failed.isEmpty {
            parts.append("Could not remove \(report.failed.map(\.displayName).joined(separator: ", ")).")
        }
        if report.whisperAccessDenied {
            parts.append("Whisper models were not checked (no access to the Documents folder).")
        }
        return parts.joined(separator: " ")
    }
}

extension AppState {
    var modelStorageContext: ModelStorageContext {
        let otherName = (BuildFlavor.current == .production ? BuildFlavor.debug : .production).displayName
        return ModelStorageContext(
            unavailableReason: ModelStorageContext.unavailableReason(engineState),
            preview: { [unowned self] in
                let inUse = modelFoldersInUse
                let other = modelFoldersOfOtherFlavor
                let store = modelStore
                return await Task.detached(priority: .userInitiated) {
                    store.unusedModelsPreview(keepingInUse: inUse, otherFlavor: other, otherFlavorName: otherName)
                }.value
            },
            remove: { [unowned self] preview in
                // Recomputed at confirmation: the model in use is never removed.
                let keep = modelFoldersInUse.union(modelFoldersOfOtherFlavor)
                let store = modelStore
                return await Task.detached(priority: .userInitiated) {
                    store.removeUnusedModels(preview, keeping: keep)
                }.value
            }
        )
    }
}

// MARK: - Views

/// Settings › Engine › Downloaded models (not in onboarding): remove downloaded models other
/// than the one in use, after a confirmation sheet listing them.
struct ModelStorageRow: View {
    let storage: ModelStorageContext
    @State private var preview: UnusedModelsPreview?
    @State private var isWorking = false
    @State private var lastReport: ModelRemovalReport?

    var body: some View {
        SettingsRow(title: "Unused models", caption: caption) {
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Button("Remove Unused Models…") {
                Task {
                    isWorking = true
                    preview = await storage.preview()
                    isWorking = false
                }
            }
            .disabled(storage.unavailableReason != nil || isWorking)
        }
        .sheet(item: $preview) { shown in
            UnusedModelsSheet(
                preview: shown,
                onCancel: { preview = nil },
                onRemove: {
                    preview = nil
                    Task {
                        isWorking = true
                        lastReport = await storage.remove(shown)
                        isWorking = false
                    }
                }
            )
        }
    }

    private var caption: String {
        if let reason = storage.unavailableReason { return reason }
        if let lastReport { return ModelStorageText.result(lastReport) }
        return "Deletes downloaded models other than the one in use, after showing the list. Any model can be downloaded again."
    }
}

/// Confirmation: each model with its size, the total, and what is kept.
struct UnusedModelsSheet: View {
    let preview: UnusedModelsPreview
    let onCancel: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(preview.removable.isEmpty ? "No unused models" : "Remove unused models?")
                .font(.headline)
            SettingsCaption(preview.removable.isEmpty
                ? "Every model on this Mac is in use or kept."
                : "These models are on this Mac but not in use. You can download them again at any time.")
                .padding(.top, 4)

            if !preview.removable.isEmpty {
                VStack(spacing: 0) {
                    ForEach(preview.removable) { model in
                        row(model.folder.displayName, ModelStorageText.size(model.bytes))
                        Divider()
                    }
                    row("Total", ModelStorageText.size(preview.totalBytes), emphasized: true)
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
                .padding(.top, 12)
            }

            VStack(alignment: .leading, spacing: 4) {
                if !preview.keptInUse.isEmpty {
                    SettingsCaption("Kept: \(sized(preview.keptInUse)), in use.")
                }
                if !preview.keptForOtherFlavor.isEmpty {
                    SettingsCaption("Kept for \(preview.otherFlavorName): \(sized(preview.keptForOtherFlavor)).")
                }
                if preview.whisperAccessDenied {
                    SettingsCaption(ModelStorageText.accessDenied)
                }
            }
            .padding(.top, 10)

            HStack(spacing: 8) {
                Spacer()
                if preview.removable.isEmpty {
                    Button("OK", action: onCancel)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Remove \(ModelStorageText.size(preview.totalBytes))", role: .destructive, action: onRemove)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 16)
        }
        .tint(.nwAccent)
        .padding(20)
        .frame(width: 430)
    }

    private func row(_ title: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(emphasized ? .primary : .secondary)
        }
        .fontWeight(emphasized ? .semibold : .regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// "Parakeet Ultra (603 MB), Whisper Base (140 MB)".
    private func sized(_ models: [StoredModel]) -> String {
        models.map { "\($0.folder.displayName) (\(ModelStorageText.size($0.bytes)))" }.joined(separator: ", ")
    }
}
