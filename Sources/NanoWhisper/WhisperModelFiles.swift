import CoreML
import CryptoKit
import Foundation
import WhisperKit
import os

extension WhisperModelSize {
    /// Repository of the tokenizer WhisperKit loads with this model (`ModelUtilities` chooses
    /// it from the model's dimensions).
    var tokenizerRepository: String {
        switch self {
        case .tiny, .base, .small, .medium, .largev3: return "openai/whisper-\(rawValue)"
        case .largev3Turbo: return "openai/whisper-large-v3"
        }
    }
}

/// What loading a Whisper model is doing.
enum WhisperLoadPhase: Equatable, Sendable {
    case downloading
    /// The files are on disk: Core ML specializes and loads them.
    case loading
}

// MARK: - Files on disk

/// A repository downloaded by WhisperKit's Hub client: the files, and one sidecar per file in
/// `.cache/huggingface/download` with the digest the server announced for it. A file is moved
/// to its place once whole, then its sidecar is written.
struct HubRepositoryFolder: Sendable {
    let url: URL

    enum FileState: Equatable, Sendable {
        case missing
        /// Not a file, empty, or not the content that was downloaded.
        case damaged
        /// `verified`: the content has the digest its sidecar holds.
        case present(verified: Bool)

        var isUsable: Bool {
            if case .present = self { return true }
            return false
        }
    }

    func fileURL(of name: String) -> URL { url.appending(path: name) }

    private func sidecarURL(of name: String) -> URL {
        url.appending(path: ".cache/huggingface/download/\(name).metadata")
    }

    /// State of a file without reading its content (`verified` is always false).
    func presence(of name: String) -> FileState {
        let path = fileURL(of: name).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return .missing }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size > 0 else { return .damaged }
        return .present(verified: false)
    }

    /// State of a file, its content compared with the digest in its sidecar, if there is one.
    func state(of name: String) -> FileState {
        let presence = presence(of: name)
        guard presence.isUsable, let recorded = recordedDigest(of: name) else { return presence }
        let actual = try? Self.digest(of: fileURL(of: name).resolvingSymlinksInPath(), like: recorded)
        return actual == recorded ? .present(verified: true) : .damaged
    }

    /// The second line of the sidecar: the SHA-256 of a large file, the git blob SHA-1 of
    /// another one. Nil without a sidecar, or when the line is neither.
    func recordedDigest(of name: String) -> String? {
        guard let text = try? String(contentsOf: sidecarURL(of: name), encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return nil }
        let digest = lines[1].trimmingCharacters(in: .whitespaces)
        let isHexadecimal = digest.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
        guard isHexadecimal, digest.utf8.count == 64 || digest.utf8.count == 40 else { return nil }
        return digest
    }

    func removeSidecar(of name: String) {
        try? FileManager.default.removeItem(at: sidecarURL(of: name))
    }

    /// Remove what stands in the way of downloading a file: the file itself, or a file where
    /// one of its folders belongs.
    func removeObstacle(to name: String) {
        let components = name.components(separatedBy: "/")
        for count in 1...components.count {
            let url = fileURL(of: components.prefix(count).joined(separator: "/"))
            let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            if type == .typeRegular || count == components.count {
                try? FileManager.default.removeItem(at: url)
                return
            }
        }
    }

    /// Digest of a file, of the same kind as `recorded`.
    private static func digest(of file: URL, like recorded: String) throws -> String {
        if recorded.utf8.count == 64 {
            return try digest(of: file, with: SHA256())
        }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        return try digest(of: file, with: hasher)
    }

    private static func digest(of file: URL, with hasher: some HashFunction) throws -> String {
        var hasher = hasher
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while try autoreleasepool(invoking: {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Whisper

/// A Whisper model on disk and on the server. A model and a tokenizer that are complete on disk
/// are loaded without any request; what is missing or damaged is downloaded first.
///
/// Download: lists the model's files, keeps the names `ModelFileRule` accepts, and asks
/// WhisperKit for exactly those (each is a pattern that matches only itself, whatever
/// WhisperKit's own listing holds). Same cache folders as `WhisperKit.download`.
enum WhisperModelFiles {
    static let repository = HubApiWrapper.Repo(id: "argmaxinc/whisperkit-coreml")

    private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "ModelDownload")

    /// Client of the app's server. An empty token: none is sent.
    private static func hub(downloadBase: URL?, server: String) -> HubApiWrapper {
        HubApiWrapper(downloadBase: downloadBase, hfToken: "", endpoint: server)
    }

    // MARK: Completeness

    /// The compiled models WhisperKit loads.
    static let components = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]

    /// What Core ML needs in each: without one of them loading fails, or crashes the process.
    static let compiledModelFiles = ["analytics/coremldata.bin", "coremldata.bin", "model.mil", "weights/weight.bin"]

    /// Files of a model that must be on disk to load it.
    static let loadedFiles = components.flatMap { component in
        compiledModelFiles.map { "\(component)/\($0)" }
    }

    /// Files every published model has (some have others, which nothing loads). When all are
    /// there, the download was not interrupted.
    static let expectedFiles = loadedFiles
        + components.map { "\($0)/metadata.json" }
        + ["config.json", "generation_config.json"]

    /// The tokenizer files WhisperKit downloads.
    static let tokenizerFiles = ["config.json", "tokenizer.json", "tokenizer_config.json"]

    /// Whether every expected file of a model is there. Does not read their content.
    static func isPresent(_ model: String, in repositoryFolder: URL) -> Bool {
        let folder = HubRepositoryFolder(url: repositoryFolder)
        return expectedFiles.allSatisfy { folder.presence(of: "\(model)/\($0)").isUsable }
    }

    /// Expected files of a model that are missing or damaged (repository paths). Reads the
    /// whole model.
    static func unusableFiles(of model: String, in folder: HubRepositoryFolder) -> [String] {
        expectedFiles.map { "\(model)/\($0)" }.filter { !folder.state(of: $0).isUsable }
    }

    /// Folder WhisperKit will load the tokenizer from: the first that holds one.
    static func tokenizerFolder(for size: WhisperModelSize, downloadBase: URL?) -> URL? {
        let hub = hub(downloadBase: downloadBase, server: ModelServer.address)
        let tokenizer = HubApiWrapper.Repo(id: size.tokenizerRepository)
        let model = hub.localRepoLocation(repository).appending(path: size.whisperKitModel)
        let candidates = [hub.localRepoLocation(tokenizer)]
            + (downloadBase.map { [$0] } ?? [])
            + [model, model.appending(path: "models/\(tokenizer.id)")]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appending(path: "tokenizer.json").path)
        }
    }

    /// Tokenizer files in `folder` that are missing or damaged. WhisperKit would download the
    /// tokenizer if one of them did not parse.
    static func unusableTokenizerFiles(in folder: HubRepositoryFolder) -> [String] {
        tokenizerFiles.filter { name in
            switch folder.state(of: name) {
            case .missing, .damaged: return true
            case .present(verified: true): return false
            case .present(verified: false):
                let data = try? Data(contentsOf: folder.fileURL(of: name))
                return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } == nil
            }
        }
    }

    // MARK: Loading

    /// Load a model with `load` (given its folder). No request is made when the model and its
    /// tokenizer are complete on disk. Otherwise the files that are missing or damaged are
    /// downloaded first. Files that could not be checked and that Core ML cannot load are
    /// downloaded again, once.
    /// - Parameters:
    ///   - localOnly: never download the model (the tokenizer, small, still is if it is missing).
    ///   - downloadBase: another cache root, in tests.
    ///   - server: another server, in tests.
    static func load<Loaded>(
        _ size: WhisperModelSize,
        localOnly: Bool = false,
        downloadBase: URL? = nil,
        server: String = ModelServer.address,
        onPhase: @Sendable (WhisperLoadPhase) -> Void = { _ in },
        _ load: (URL) async throws -> sending Loaded
    ) async throws -> sending Loaded {
        let model = size.whisperKitModel
        let folder = HubRepositoryFolder(
            url: hub(downloadBase: downloadBase, server: server).localRepoLocation(repository)
        )
        let modelFolder = folder.fileURL(of: model)

        let unusable = unusableFiles(of: model, in: folder)
        try Task.checkCancellation()
        if !unusable.isEmpty {
            guard !localOnly else { throw ModelDownloadError.incomplete(model: model) }
            onPhase(.downloading)
            _ = try await download(model, replacing: unusable, downloadBase: downloadBase, server: server)
            // Core ML can crash on a compiled model without one of these.
            guard loadedFiles.allSatisfy({ folder.presence(of: "\(model)/\($0)").isUsable }) else {
                throw ModelDownloadError.incomplete(model: model)
            }
        }
        try await prepareTokenizer(for: size, downloadBase: downloadBase, server: server)

        onPhase(.loading)
        do {
            return try await load(modelFolder)
        } catch {
            try Task.checkCancellation()
            let unreadable = localOnly ? [] : unreadableFiles(of: model, in: folder)
            guard !unreadable.isEmpty else { throw error }
            logger.error("Could not load \(model, privacy: .public); downloading \(unreadable.count) file(s) again: \(error.localizedDescription, privacy: .public)")
            onPhase(.downloading)
            _ = try await download(model, replacing: unreadable, downloadBase: downloadBase, server: server)
            onPhase(.loading)
            return try await load(modelFolder)
        }
    }

    /// Files of the compiled models that Core ML cannot load, leaving out those known to be
    /// what the server published: downloading them again would change nothing.
    private static func unreadableFiles(of model: String, in folder: HubRepositoryFolder) -> [String] {
        components.flatMap { component -> [String] in
            let unverified = compiledModelFiles.map { "\(model)/\(component)/\($0)" }
                .filter { folder.state(of: $0) != .present(verified: true) }
            guard !unverified.isEmpty else { return [] }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            let url = folder.fileURL(of: "\(model)/\(component)")
            return (try? MLModel(contentsOf: url, configuration: configuration)) == nil ? unverified : []
        }
    }

    // MARK: Download

    /// Download the missing or changed files of a model; returns its folder.
    /// - Parameters:
    ///   - unusable: files of the model to download again even if they are on disk.
    ///   - downloadBase: another cache root, in tests.
    ///   - server: another server, in tests.
    @discardableResult
    static func download(
        _ model: String,
        replacing unusable: [String] = [],
        downloadBase: URL? = nil,
        server: String = ModelServer.address
    ) async throws -> URL {
        ModelServer.configure()
        let hub = hub(downloadBase: downloadBase, server: server)
        let listed = try await hub.getFilenames(from: repository, matching: ["\(model)/*"])
        let names = accepted(listed, of: model)
        if names.count < listed.count {
            logger.error("Ignored \(listed.count - names.count) unexpected file name(s) listed for \(model, privacy: .public)")
        }
        guard !names.isEmpty else { throw ModelDownloadError.noFiles(model: model) }
        let root = try await fetch(names, replacing: unusable, from: repository, with: hub)
        return root.appending(path: model)
    }

    static func accepted(_ names: [String], of model: String) -> [String] {
        let rule = ModelFileRule(folders: [model])
        return names.filter(rule.accepts).sorted()
    }

    /// Make sure the tokenizer is complete on disk, so WhisperKit does not download it.
    private static func prepareTokenizer(for size: WhisperModelSize, downloadBase: URL?, server: String) async throws {
        if let found = tokenizerFolder(for: size, downloadBase: downloadBase),
           unusableTokenizerFiles(in: HubRepositoryFolder(url: found)).isEmpty { return }
        ModelServer.configure()
        let hub = hub(downloadBase: downloadBase, server: server)
        let tokenizer = HubApiWrapper.Repo(id: size.tokenizerRepository)
        let listed = Set(try await hub.getFilenames(from: tokenizer, matching: tokenizerFiles))
        guard listed.isSuperset(of: tokenizerFiles) else { throw ModelDownloadError.noFiles(model: tokenizer.id) }
        let folder = HubRepositoryFolder(url: hub.localRepoLocation(tokenizer))
        _ = try await fetch(tokenizerFiles, replacing: unusableTokenizerFiles(in: folder), from: tokenizer, with: hub)
    }

    /// Download `names`, which the server lists. `unusable` files are removed first: WhisperKit
    /// keeps a file whose sidecar is up to date, whatever its content.
    private static func fetch(
        _ names: [String],
        replacing unusable: [String],
        from repository: HubApiWrapper.Repo,
        with hub: HubApiWrapper
    ) async throws -> URL {
        let folder = HubRepositoryFolder(url: hub.localRepoLocation(repository))
        let replaced = unusable.filter(Set(names).contains)
        replaced.forEach(folder.removeObstacle)
        let root = try await hub.snapshot(from: repository, matching: names)
        // Without a connection, WhisperKit returns what is on disk instead.
        guard names.allSatisfy({ folder.presence(of: $0) != .missing }) else {
            throw ModelDownloadError.incomplete(model: repository.id)
        }
        // A file that was just downloaded and does not match: what the sidecar holds is not its
        // digest, and must not make it look damaged at each launch.
        for name in replaced where folder.state(of: name) == .damaged {
            logger.error("The server's digest of \(name, privacy: .public) does not match the file")
            folder.removeSidecar(of: name)
        }
        return root
    }
}
