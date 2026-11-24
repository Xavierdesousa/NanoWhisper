import CoreML
import FluidAudio
import Foundation
import WhisperKit
import os

// MARK: - Server

/// The server models are downloaded from. The app fixes its address: the download libraries
/// would otherwise take it, and an access token, from the process environment. See
/// docs/wiki/transcription-engines.md (Download).
enum ModelServer {
    static let address = "https://huggingface.co"

    /// Variables the libraries read that the app does not use, removed from this process:
    /// - server address: `REGISTRY_URL`, `MODEL_REGISTRY_URL` (FluidAudio), `HF_ENDPOINT`
    ///   (WhisperKit, for the tokenizer);
    /// - access token, sent with every request: the models are in public repositories.
    ///
    /// The proxy variables (`https_proxy`, `http_proxy`, read by FluidAudio) are left alone.
    static let ignoredEnvironmentVariables = [
        "REGISTRY_URL", "MODEL_REGISTRY_URL", "HF_ENDPOINT",
        "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACEHUB_API_TOKEN",
    ]

    /// The address given to FluidAudio, if any yet.
    private static let configuredAddress = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Called first thing at launch, and again before each download (it then changes nothing).
    /// - Parameter address: another server, in tests.
    static func configure(address: String = ModelServer.address) {
        for name in ignoredEnvironmentVariables where getenv(name) != nil {
            unsetenv(name)
        }
        configuredAddress.withLock { configured in
            // A plain global variable in FluidAudio: written at launch, before anything reads it.
            guard configured != address else { return }
            configured = address
            ModelRegistry.baseURL = address
        }
    }
}

// MARK: - File names

enum ModelDownloadError: Error, Equatable {
    /// The server lists no file of the model.
    case noFiles(model: String)
}

/// Which files of a model repository the app downloads: plain relative paths in the model's
/// own folders, and named top-level files.
struct ModelFileRule: Sendable {
    /// Top-level folders, taken whole.
    var folders: Set<String>
    /// Top-level files.
    var files: Set<String> = []

    /// Deeper than any published model (3); bounds how far a listing is followed.
    static let maxDepth = 8

    /// Whether a repository path (a file or a folder) may be downloaded.
    func accepts(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= Self.maxDepth, components.allSatisfy(Self.isPlainName) else { return false }
        return files.contains(path) || folders.contains(String(components[0]))
    }

    /// ASCII letters, digits, `.`, `_` and `-`; not empty, `.` or `..`. Also free of the
    /// characters that are special in a file name pattern.
    static func isPlainName(_ name: some StringProtocol) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Parakeet

/// Downloads a Parakeet model (the files of `rule`, applied to the listing being downloaded),
/// then loads it from its folder without any request (`AsrModels.loadLocal`). Same cache folder
/// and file names as `AsrModels.downloadAndLoad`.
enum ParakeetModelFiles {
    private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "ModelDownload")

    /// The compiled models and the vocabulary FluidAudio loads: the same files
    /// `AsrModels.modelsExist(at:version:)` requires.
    static let rule = ModelFileRule(
        folders: ModelNames.ASR.requiredModelsV3(),
        files: [ModelNames.ASR.vocabularyFile]
    )

    static func repository(of variant: ParakeetVariant) -> Repo {
        switch variant {
        case .v3: return .parakeetV3
        case .ultra: return .parakeetUltra
        }
    }

    /// Load the model, downloading it first if it is not complete on disk.
    /// - Parameters:
    ///   - cacheDirectory: another folder, in tests.
    ///   - server: another server, in tests.
    static func load(
        _ variant: ParakeetVariant,
        from cacheDirectory: URL? = nil,
        server: String = ModelServer.address,
        progressHandler: @escaping ProgressHandler
    ) async throws -> AsrModels {
        let version = variant.asrModelVersion
        let directory = cacheDirectory ?? AsrModels.defaultCacheDirectory(for: version)
        if !AsrModels.modelsExist(at: directory, version: version) {
            try await download(variant, to: directory, server: server, progressHandler: progressHandler)
        }
        progressHandler(DownloadProgress(fractionCompleted: 1, phase: .compiling(modelName: "")))
        do {
            return try AsrModels.loadLocal(from: directory, version: version)
        } catch {
            // Like FluidAudio's own loader: download again, once, what does not load.
            try Task.checkCancellation()
            let damaged = damagedFiles(in: directory, version: version)
            guard !damaged.isEmpty else { throw error }
            logger.error("Could not load \(damaged.joined(separator: ", "), privacy: .public); downloading again: \(error.localizedDescription, privacy: .public)")
            for name in damaged {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            try await download(variant, to: directory, server: server, progressHandler: progressHandler)
            return try AsrModels.loadLocal(from: directory, version: version)
        }
    }

    /// Download the missing files into `directory` (an interrupted download resumes).
    /// - Parameter server: another server, in tests.
    static func download(
        _ variant: ParakeetVariant,
        to directory: URL,
        server: String = ModelServer.address,
        progressHandler: ProgressHandler? = nil
    ) async throws {
        ModelServer.configure(address: server)
        // A file where a compiled model's folder belongs (an interrupted repair) blocks it.
        for name in rule.folders {
            let url = directory.appendingPathComponent(name)
            let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            if type == .typeRegular { try? FileManager.default.removeItem(at: url) }
        }
        try await ModelHub.download(
            repository(of: variant),
            subdirectory: "",
            to: directory,
            progressHandler: progressHandler,
            shouldSkip: { !rule.accepts($0) }
        )
    }

    /// Required files that Core ML (or the vocabulary parser) cannot load.
    private static func damagedFiles(in directory: URL, version: AsrModelVersion) -> [String] {
        var damaged = rule.folders.sorted().filter { name in
            let configuration = AsrModels.defaultConfiguration()
            if name == ModelNames.ASR.preprocessorFile {
                configuration.computeUnits = .cpuOnly
            }
            let url = directory.appendingPathComponent(name)
            return (try? MLModel(contentsOf: url, configuration: configuration)) == nil
        }
        if !isVocabularyComplete(in: directory, version: version) {
            damaged.append(ModelNames.ASR.vocabularyFile)
        }
        return damaged
    }

    /// The check `AsrModels.loadLocal` makes: a token for every id before the blank.
    static func isVocabularyComplete(in directory: URL, version: AsrModelVersion) -> Bool {
        let url = directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)
        guard let data = try? Data(contentsOf: url),
              let tokens = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return (0..<version.blankId).allSatisfy { tokens[String($0)] != nil }
    }
}

// MARK: - Whisper

/// Downloads a Whisper model: lists its files, keeps the names `ModelFileRule` accepts, and
/// asks WhisperKit for exactly those (each is a pattern that matches only itself, whatever
/// WhisperKit's own listing holds). Same cache folder as `WhisperKit.download`.
enum WhisperModelFiles {
    static let repository = HubApiWrapper.Repo(id: "argmaxinc/whisperkit-coreml")

    private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "ModelDownload")

    /// Download the missing or changed files of a model; returns its folder.
    /// - Parameters:
    ///   - downloadBase: another cache root, in tests.
    ///   - server: another server, in tests.
    static func download(
        _ model: String,
        downloadBase: URL? = nil,
        server: String = ModelServer.address
    ) async throws -> URL {
        ModelServer.configure()
        // An empty token: none is sent.
        let hub = HubApiWrapper(downloadBase: downloadBase, hfToken: "", endpoint: server)
        let listed = try await hub.getFilenames(from: repository, matching: ["\(model)/*"])
        let names = accepted(listed, of: model)
        if names.count < listed.count {
            logger.error("Ignored \(listed.count - names.count) unexpected file name(s) listed for \(model, privacy: .public)")
        }
        guard !names.isEmpty else { throw ModelDownloadError.noFiles(model: model) }
        let root = try await hub.snapshot(from: repository, matching: names)
        return root.appending(path: model)
    }

    static func accepted(_ names: [String], of model: String) -> [String] {
        let rule = ModelFileRule(folders: [model])
        return names.filter(rule.accepts).sorted()
    }
}
