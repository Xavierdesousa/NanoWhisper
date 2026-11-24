import Foundation
import Testing
import FluidAudio
import WhisperKit
import os
@testable import NanoWhisper

/// Downloads run against a server on 127.0.0.1, into a temporary directory. Serialized: the
/// environment and FluidAudio's server address are global.
@Suite("Model download", .serialized)
struct ModelDownloadTests {
    private let fm = FileManager.default

    private static let serverVariables = ["REGISTRY_URL", "MODEL_REGISTRY_URL", "HF_ENDPOINT"]
    private static let tokenVariables = ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACEHUB_API_TOKEN"]

    private func setVariables(server: String) {
        for name in Self.serverVariables { setenv(name, server, 1) }
        for name in Self.tokenVariables { setenv(name, "hf_test_token", 1) }
    }

    private func reset() {
        ModelServer.configure()
    }

    /// A temporary directory, checked whole after a download, with the cache inside it.
    private func withRoot(_ body: (_ root: URL, _ cache: URL) async throws -> Void) async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("NanoWhisperDownloadTests-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent("a/b/cache", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        defer {
            reset()
            try? fm.removeItem(at: root)
        }
        try await body(root, cache)
    }

    /// Regular files under `root`, relative to it.
    private func files(under root: URL) -> Set<String> {
        guard let enumerator = fm.enumerator(atPath: root.path) else { return [] }
        var found: Set<String> = []
        for case let path as String in enumerator
        where enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
            found.insert(path)
        }
        return found
    }

    // MARK: - Server

    @Test("The server address is the app's, whatever the environment says")
    func fixedAddress() throws {
        setVariables(server: "https://models.example.com")
        setenv("https_proxy", "http://127.0.0.1:9", 1)
        defer {
            unsetenv("https_proxy")
            reset()
        }
        ModelServer.configure()

        #expect(ModelRegistry.baseURL == "https://huggingface.co")
        let list = try ModelRegistry.apiModels(Repo.parakeetUltra.remotePath, "tree/main")
        #expect(list.absoluteString == "https://huggingface.co/api/models/FluidInference/parakeet-ultra-coreml/tree/main")
        let file = try ModelRegistry.resolveModel(Repo.parakeetV3.remotePath, "config.json")
        #expect(file.host() == "huggingface.co" && file.scheme == "https")

        // What WhisperKit (and FluidAudio, for the token) reads, at each use.
        let environment = ProcessInfo.processInfo.environment
        for name in Self.serverVariables + Self.tokenVariables {
            #expect(environment[name] == nil, "\(name)")
            #expect(ModelServer.ignoredEnvironmentVariables.contains(name))
        }
        // A proxy stays usable.
        #expect(environment["https_proxy"] == "http://127.0.0.1:9")
    }

    @Test("FluidAudio's address is fixed even if a variable is set after launch")
    func variableSetLater() {
        ModelServer.configure()
        setVariables(server: "https://models.example.com")
        defer { reset() }
        #expect(ModelRegistry.baseURL == "https://huggingface.co")
    }

    @Test("WhisperKit gets the server address and a folder, and does not download the model itself")
    func whisperConfiguration() {
        let config = WhisperEngine.configuration(model: "openai_whisper-base", folder: URL(fileURLWithPath: "/tmp/openai_whisper-base"))
        #expect(config.modelEndpoint == "https://huggingface.co")
        #expect(config.modelToken == "")
        #expect(config.modelFolder == "/tmp/openai_whisper-base")
        #expect(!config.download)
    }

    // MARK: - File names

    private let rule = ModelFileRule(folders: ["Encoder.mlmodelc"], files: ["parakeet_vocab.json"])

    @Test("Plain paths in the model's own folders are accepted", arguments: [
        "Encoder.mlmodelc",
        "Encoder.mlmodelc/coremldata.bin",
        "Encoder.mlmodelc/weights/weight.bin",
        "Encoder.mlmodelc/analytics/coremldata.bin",
        "parakeet_vocab.json",
    ])
    func acceptedPath(_ path: String) {
        #expect(rule.accepts(path))
    }

    @Test("Any other path is refused", arguments: [
        "", "/", ".", "..", "/etc/hosts", "~/x", "file:///etc/hosts",
        "/Encoder.mlmodelc/coremldata.bin",
        "Encoder.mlmodelc/../x.txt",
        "Encoder.mlmodelc/../../../x.txt",
        "Encoder.mlmodelc/weights/../../../x.txt",
        "../Encoder.mlmodelc/x",
        "./Encoder.mlmodelc/x",
        "Encoder.mlmodelc//x", "Encoder.mlmodelc/", "Encoder.mlmodelc/./x",
        "Encoder.mlmodelc/..%2f..%2fx", "Encoder.mlmodelc/a\\..\\x",
        "Encoder.mlmodelc/a\u{0}b", "Encoder.mlmodelc/a\nb", "Encoder.mlmodelc/a b",
        "Encoder.mlmodelc/*", "Encoder.mlmodelc/[a]", "Encoder.mlmodelc/?",
        "Encoder.mlmodelc/\u{301}../x", "Encoder.mlmodelc/\u{2025}/x",
        "Encoder.mlmodelc2/x", "encoder.mlmodelc/x", "Decoder.mlmodelc/x",
        "x/Encoder.mlmodelc/x",
        "config.json", "../x.json", "x.json", "parakeet_vocab.json/x", "x/parakeet_vocab.json",
        "Encoder.mlmodelc/a/a/a/a/a/a/a/a/a",
    ])
    func refusedPath(_ path: String) {
        #expect(!rule.accepts(path))
    }

    @Test("The Parakeet rule covers exactly what FluidAudio needs to load the model")
    func parakeetRule() throws {
        #expect(ParakeetModelFiles.rule.folders == [
            "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc",
        ])
        #expect(ParakeetModelFiles.rule.files == ["parakeet_vocab.json"])
        for variant in ParakeetVariant.allCases {
            #expect(ParakeetModelFiles.repository(of: variant).rawValue == variant.huggingFaceRepo)
            #expect(ParakeetModelFiles.repository(of: variant).revision == "main")
            let folder = ModelFolder.parakeet(variant).name
            #expect(ParakeetModelFiles.repository(of: variant).folderName == folder)

            // A folder holding these files, and only these, is complete for FluidAudio.
            let root = fm.temporaryDirectory.appendingPathComponent("NanoWhisperDownloadTests-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            let directory = root.appendingPathComponent(folder)
            for bundle in ParakeetModelFiles.rule.folders {
                try fm.createDirectory(at: directory.appendingPathComponent(bundle), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: directory.appendingPathComponent("\(bundle)/coremldata.bin"))
            }
            #expect(!AsrModels.modelsExist(at: directory, version: variant.asrModelVersion))
            for file in ParakeetModelFiles.rule.files {
                try Data("{}".utf8).write(to: directory.appendingPathComponent(file))
            }
            #expect(AsrModels.modelsExist(at: directory, version: variant.asrModelVersion))
        }
    }

    @Test("Vocabulary check: every token before the blank")
    func vocabulary() throws {
        let directory = fm.temporaryDirectory.appendingPathComponent("NanoWhisperDownloadTests-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let file = directory.appendingPathComponent("parakeet_vocab.json")
        #expect(!ParakeetModelFiles.isVocabularyComplete(in: directory, version: .ultra))
        var tokens = Dictionary(uniqueKeysWithValues: (0..<AsrModelVersion.ultra.blankId).map { (String($0), "t\($0)") })
        try JSONEncoder().encode(tokens).write(to: file)
        #expect(ParakeetModelFiles.isVocabularyComplete(in: directory, version: .ultra))
        tokens["12"] = nil
        try JSONEncoder().encode(tokens).write(to: file)
        #expect(!ParakeetModelFiles.isVocabularyComplete(in: directory, version: .ultra))
    }

    // MARK: - Parakeet

    /// The tree API: every entry's path, listed under the directory it was asked for.
    private static func tree(_ files: [String], directories: [String] = []) -> FakeModelServer.Response {
        .json(
            directories.map { ["type": "directory", "path": $0] as [String: Any] }
                + files.map { ["type": "file", "path": $0, "size": payload.count] as [String: Any] }
        )
    }

    private static let payload = Data("model file".utf8)

    @Test("Parakeet: the model's files are downloaded, anything else in the listing is ignored")
    func parakeetDownload() async throws {
        try await withRoot { root, cache in
            let directory = cache.appendingPathComponent("parakeet-ultra", isDirectory: true)
            let server = try await FakeModelServer { request in
                let tree = "/api/models/FluidInference/parakeet-ultra-coreml/tree/main"
                switch request.path {
                case tree:
                    return Self.tree(
                        [
                            "parakeet_vocab.json", "config.json", "README.md",
                            "Encoder.mlmodelc/../other-1.txt", "../other-2.json", "/other-3.txt",
                        ],
                        directories: ["Encoder.mlmodelc", "Decoder.mlmodelc", "Other.mlmodelc", "..", "Encoder.mlmodelc/.."]
                    )
                case tree + "/Encoder.mlmodelc":
                    return Self.tree(
                        ["Encoder.mlmodelc/coremldata.bin", "Encoder.mlmodelc/weights/../../other-4.txt"],
                        directories: ["Encoder.mlmodelc/weights", "Encoder.mlmodelc/../other"]
                    )
                case tree + "/Encoder.mlmodelc/weights":
                    return Self.tree(["Encoder.mlmodelc/weights/weight.bin"])
                case tree + "/Decoder.mlmodelc":
                    return Self.tree(["Decoder.mlmodelc/coremldata.bin"])
                case let path where path.hasPrefix("/api/"):
                    return Self.tree(["parakeet_vocab.json"])
                default:
                    return .init(headers: ["Content-Type": "application/octet-stream"], body: Self.payload)
                }
            }
            defer { server.stop() }
            setVariables(server: "http://127.0.0.1:9")
            try await ParakeetModelFiles.download(.ultra, to: directory, server: server.address)

            #expect(files(under: root) == [
                "a/b/cache/parakeet-ultra/parakeet_vocab.json",
                "a/b/cache/parakeet-ultra/Encoder.mlmodelc/coremldata.bin",
                "a/b/cache/parakeet-ultra/Encoder.mlmodelc/weights/weight.bin",
                "a/b/cache/parakeet-ultra/Decoder.mlmodelc/coremldata.bin",
            ])
            // Nothing else was asked for, and no token was sent.
            #expect(!server.requests.contains { $0.path.contains("..") || $0.path.lowercased().contains("other") })
            #expect(!server.requests.contains { $0.headers["authorization"] != nil })
        }
    }

    @Test("Parakeet: an endless listing is bounded")
    func parakeetNestedFolders() async throws {
        try await withRoot { root, cache in
            let directory = cache.appendingPathComponent("parakeet-ultra", isDirectory: true)
            let server = try await FakeModelServer { request in
                // Every folder lists one more folder.
                let listed = request.path.components(separatedBy: "/tree/main/").dropFirst().first
                return Self.tree([], directories: [listed.map { "\($0)/a" } ?? "Encoder.mlmodelc"])
            }
            defer { server.stop() }
            try await ParakeetModelFiles.download(.ultra, to: directory, server: server.address)
            #expect(server.requests.count == ModelFileRule.maxDepth + 1)
            #expect(files(under: root).isEmpty)
        }
    }

    @Test("Parakeet: files already on disk are kept, missing ones are downloaded")
    func parakeetResume() async throws {
        try await withRoot { _, cache in
            let directory = cache.appendingPathComponent("parakeet-ultra", isDirectory: true)
            let kept = directory.appendingPathComponent("Encoder.mlmodelc/coremldata.bin")
            try fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("already here".utf8).write(to: kept)
            let server = try await FakeModelServer { request in
                if request.path.hasSuffix("/tree/main") {
                    return Self.tree(["parakeet_vocab.json", "Encoder.mlmodelc/coremldata.bin"])
                }
                return .init(headers: ["Content-Type": "application/octet-stream"], body: Self.payload)
            }
            defer { server.stop() }
            try await ParakeetModelFiles.download(.ultra, to: directory, server: server.address)
            #expect(try Data(contentsOf: kept) == Data("already here".utf8))
            #expect(try Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json")) == Self.payload)
        }
    }

    @Test("Parakeet: a file in place of a compiled model's folder is replaced")
    func parakeetBlockedFolder() async throws {
        try await withRoot { root, cache in
            let directory = cache.appendingPathComponent("parakeet-ultra", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("stray".utf8).write(to: directory.appendingPathComponent("Encoder.mlmodelc"))
            let server = try await FakeModelServer { request in
                if request.path.hasSuffix("/tree/main") { return Self.tree(["Encoder.mlmodelc/coremldata.bin"]) }
                return .init(headers: ["Content-Type": "application/octet-stream"], body: Self.payload)
            }
            defer { server.stop() }
            try await ParakeetModelFiles.download(.ultra, to: directory, server: server.address)
            #expect(files(under: root) == ["a/b/cache/parakeet-ultra/Encoder.mlmodelc/coremldata.bin"])
        }
    }

    @Test("Parakeet: files that do not load are downloaded again, once")
    func parakeetRepair() async throws {
        try await withRoot { root, cache in
            let directory = cache.appendingPathComponent("parakeet-ultra", isDirectory: true)
            var names: [String] = []
            for bundle in ParakeetModelFiles.rule.folders.sorted() {
                try fm.createDirectory(at: directory.appendingPathComponent(bundle), withIntermediateDirectories: true)
                names.append("\(bundle)/coremldata.bin")
            }
            for name in names { try Data("damaged".utf8).write(to: directory.appendingPathComponent(name)) }
            // Complete for the on-disk check; the vocabulary is fine, the models do not load.
            let tokens = Dictionary(uniqueKeysWithValues: (0..<AsrModelVersion.ultra.blankId).map { (String($0), "t") })
            let vocabulary = directory.appendingPathComponent("parakeet_vocab.json")
            try JSONEncoder().encode(tokens).write(to: vocabulary)
            let unrelated = directory.appendingPathComponent("config.json")
            try Data("kept".utf8).write(to: unrelated)
            #expect(AsrModels.modelsExist(at: directory, version: .ultra))

            let listed = names
            let server = try await FakeModelServer { request in
                if request.path.hasSuffix("/tree/main") { return Self.tree(listed + ["parakeet_vocab.json", "config.json"]) }
                return .init(headers: ["Content-Type": "application/octet-stream"], body: Self.payload)
            }
            defer { server.stop() }
            // The served files are not models either: the second failure is the caller's.
            await #expect(throws: (any Error).self) {
                _ = try await ParakeetModelFiles.load(.ultra, from: directory, server: server.address) { _ in }
            }
            #expect(server.requests.filter { $0.path.hasSuffix("/tree/main") }.count == 1)
            for name in names {
                #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == Self.payload)
            }
            #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: vocabulary)) == tokens)
            #expect(try Data(contentsOf: unrelated) == Data("kept".utf8))
        }
    }

    // MARK: - Whisper

    private static let model = "openai_whisper-base"

    private static func siblings(_ names: [String]) -> FakeModelServer.Response {
        .json(["siblings": names.map { ["rfilename": $0] }])
    }

    private static func whisperFile(_ request: FakeModelServer.Request) -> FakeModelServer.Response {
        .init(
            headers: [
                "Content-Type": "application/octet-stream",
                "X-Repo-Commit": String(repeating: "0", count: 40),
                "ETag": "\"abc\"",
            ],
            body: payload
        )
    }

    private static let whisperNames = [
        "\(model)/config.json",
        "\(model)/AudioEncoder.mlmodelc/coremldata.bin",
        "\(model)/AudioEncoder.mlmodelc/weights/weight.bin",
    ]

    /// Everything WhisperKit writes for `whisperNames`: the files and their sidecars.
    private static var whisperFiles: Set<String> {
        let repository = "a/b/cache/models/argmaxinc/whisperkit-coreml"
        return Set(whisperNames.map { "\(repository)/\($0)" }
            + whisperNames.map { "\(repository)/.cache/huggingface/download/\($0).metadata" })
    }

    @Test("Whisper: the model's files are downloaded, anything else in the listing is ignored")
    func whisperDownload() async throws {
        try await withRoot { root, cache in
            let server = try await FakeModelServer { request in
                guard request.path.hasPrefix("/api/") else { return Self.whisperFile(request) }
                return Self.siblings(Self.whisperNames + [
                    "\(Self.model)/../other-1.txt",
                    "../\(Self.model)/other-2.txt",
                    "/\(Self.model)/other-3.txt",
                    "other/\(Self.model)/x.bin",
                    "\(Self.model)/*",
                    "openai_whisper-base.en/config.json",
                ])
            }
            defer { server.stop() }
            // Another server in the environment must not be used.
            let other = try await FakeModelServer { _ in Self.siblings(["\(Self.model)/wrong.bin"]) }
            defer { other.stop() }
            setVariables(server: other.address)

            let folder = try await WhisperModelFiles.download(Self.model, downloadBase: cache, server: server.address)

            #expect(folder.path == cache.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(Self.model)").path)
            #expect(files(under: root) == Self.whisperFiles)
            #expect(other.requests.isEmpty)
            #expect(!server.requests.contains { $0.headers["authorization"] != nil })
            #expect(!server.requests.contains { $0.path.contains("..") || $0.path.contains("other") })
        }
    }

    @Test("Whisper: only the names asked for are downloaded, whatever a later listing holds")
    func whisperListingChanges() async throws {
        try await withRoot { root, cache in
            let listings = OSAllocatedUnfairLock(initialState: 0)
            let server = try await FakeModelServer { request in
                guard request.path.hasPrefix("/api/") else { return Self.whisperFile(request) }
                let count = listings.withLock { $0 += 1; return $0 }
                return Self.siblings(Self.whisperNames + (count == 1 ? [] : [
                    "\(Self.model)/../other.txt",
                    "\(Self.model)/AudioEncoder.mlmodelc/../other.txt",
                    "\(Self.model)/added.bin",
                ]))
            }
            defer { server.stop() }
            _ = try await WhisperModelFiles.download(Self.model, downloadBase: cache, server: server.address)
            #expect(listings.withLock { $0 } >= 2)
            #expect(files(under: root) == Self.whisperFiles)
        }
    }

    @Test("Whisper: a listing without the model is an error, and downloads nothing")
    func whisperNoFiles() async throws {
        try await withRoot { root, cache in
            let server = try await FakeModelServer { request in
                guard request.path.hasPrefix("/api/") else { return Self.whisperFile(request) }
                return Self.siblings(["\(Self.model)/../../x", "other/config.json"])
            }
            defer { server.stop() }
            await #expect(throws: ModelDownloadError.noFiles(model: Self.model)) {
                _ = try await WhisperModelFiles.download(Self.model, downloadBase: cache, server: server.address)
            }
            #expect(files(under: root).isEmpty)
        }
    }

    @Test("Whisper: accepted names match only themselves as patterns")
    func whisperNamesAreLiteralPatterns() {
        let names = WhisperModelFiles.accepted(Self.whisperNames, of: Self.model)
        #expect(Set(names) == Set(Self.whisperNames))
        for name in names {
            #expect(fnmatch(name, name, 0) == 0)
            for other in [name + "x", "x" + name, "\(Self.model)/../x", "\(Self.model)/configXjson"] {
                #expect(fnmatch(name, other, 0) != 0)
            }
        }
    }
}
