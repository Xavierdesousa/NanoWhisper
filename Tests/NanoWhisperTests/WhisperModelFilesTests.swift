import CryptoKit
import Foundation
import Testing
import WhisperKit
import os
@testable import NanoWhisper

/// Loading a Whisper model from disk. In the `ModelDownloadTests` suite, which is serialized:
/// the environment and the server address are global.
extension ModelDownloadTests {
    private struct LoadError: Error {}

    /// The public repositories, as the fake server publishes them: path ("<repository>/<file>")
    /// to content. Large files get a SHA-256 ETag and the others a git one, like the real server.
    private struct Published {
        static let model = "argmaxinc/whisperkit-coreml"

        var files: [String: Data] = [:]

        init(_ size: WhisperModelSize) {
            for name in WhisperModelFiles.expectedFiles {
                files["\(Self.model)/\(size.whisperKitModel)/\(name)"] = Data("content of \(name)".utf8)
            }
            // Published too for some sizes; nothing loads it.
            files["\(Self.model)/\(size.whisperKitModel)/TextDecoder.mlmodelc/model.mlmodel"] = Data("unused".utf8)
            for name in WhisperModelFiles.tokenizerFiles {
                files["\(size.tokenizerRepository)/\(name)"] = Data(#"{"name": "\#(name)"}"#.utf8)
            }
        }

        static func digest(of path: String, _ data: Data) -> String {
            let bytes: [UInt8] = path.hasSuffix(".bin")
                ? Array(SHA256.hash(data: data))
                : Array(Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data))
            return bytes.map { String(format: "%02x", $0) }.joined()
        }

        func respond(_ request: FakeModelServer.Request) -> FakeModelServer.Response {
            let path = String(request.path.split(separator: "?")[0].dropFirst())
            if path.hasPrefix("api/models/") {
                let repository = path.dropFirst("api/models/".count).components(separatedBy: "/revision/")[0]
                let names = files.keys.filter { $0.hasPrefix("\(repository)/") }.map { $0.dropFirst(repository.count + 1) }
                return .json(["siblings": names.map { ["rfilename": String($0)] }])
            }
            let name = path.replacingOccurrences(of: "/resolve/main/", with: "/")
            let data = files[name] ?? Data()
            return .init(headers: [
                "Content-Type": "application/octet-stream",
                "X-Repo-Commit": String(repeating: "0", count: 40),
                "ETag": "\"\(Self.digest(of: name, data))\"",
            ], body: data)
        }

        /// Write everything as a finished download left it.
        func write(to cache: URL, sidecars: Bool = true) throws {
            for (path, data) in files {
                let parts = path.split(separator: "/", maxSplits: 2).map(String.init)
                let repository = cache.appending(path: "models/\(parts[0])/\(parts[1])")
                try Self.write(data, to: repository.appending(path: parts[2]))
                guard sidecars else { continue }
                try Self.write(
                    Data("\(String(repeating: "0", count: 40))\n\(Self.digest(of: path, data))\n1795101265.4\n".utf8),
                    to: repository.appending(path: ".cache/huggingface/download/\(parts[2]).metadata")
                )
            }
        }

        static func write(_ data: Data, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        func content(of path: String, size: WhisperModelSize) -> Data? {
            files["\(Self.model)/\(size.whisperKitModel)/\(path)"]
        }
    }

    /// A model cache, a server that publishes the model, and the calls to the loader.
    private final class Fixture: Sendable {
        let size: WhisperModelSize
        let cache: URL
        let published: Published
        let server: FakeModelServer
        private let calls = OSAllocatedUnfairLock(initialState: [URL]())
        private let phaseLog = OSAllocatedUnfairLock(initialState: [WhisperLoadPhase]())

        var loadedFolders: [URL] { calls.withLock { $0 } }
        var phases: [WhisperLoadPhase] { phaseLog.withLock { $0 } }

        init(_ size: WhisperModelSize = .base, cache: URL) async throws {
            let published = Published(size)
            self.size = size
            self.cache = cache
            self.published = published
            server = try await FakeModelServer { published.respond($0) }
        }

        var repository: URL { cache.appending(path: "models/\(Published.model)") }
        var model: URL { repository.appending(path: size.whisperKitModel) }
        var tokenizer: URL { cache.appending(path: "models/\(size.tokenizerRepository)") }

        /// Requested file contents (not the listings or the HEAD requests).
        var downloaded: Set<String> {
            Set(server.requests.filter { $0.method == "GET" && !$0.path.hasPrefix("/api/") }.map {
                $0.path.components(separatedBy: "/resolve/main/")[1]
            })
        }

        /// - Parameter failures: how many of the first attempts to load fail.
        func load(localOnly: Bool = false, server address: String? = nil, failures: Int = 0) async throws {
            try await WhisperModelFiles.load(
                size, localOnly: localOnly, downloadBase: cache, server: address ?? server.address,
                onPhase: { phase in phaseLog.withLock { $0.append(phase) } }
            ) { folder in
                let attempts = calls.withLock { $0.append(folder); return $0.count }
                if attempts <= failures { throw LoadError() }
            }
        }
    }

    /// - Parameter written: write the finished download to the cache first.
    private func withFixture(
        _ size: WhisperModelSize = .base, written: Bool = true, sidecars: Bool = true,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        try await withRoot { _, cache in
            let fixture = try await Fixture(size, cache: cache)
            defer { fixture.server.stop() }
            // A client that takes its server from the environment would reach this one too.
            setVariables(server: fixture.server.address)
            if written { try fixture.published.write(to: cache, sidecars: sidecars) }
            try await body(fixture)
        }
    }

    // MARK: No request

    @Test("Whisper: a complete model and tokenizer are loaded without any request", arguments: WhisperModelSize.allCases)
    func whisperCompleteMakesNoRequest(_ size: WhisperModelSize) async throws {
        try await withFixture(size) { fixture in
            try await fixture.load()
            #expect(fixture.server.requests.isEmpty)
            #expect(fixture.loadedFolders.map(\.path) == [fixture.model.path])
            #expect(fixture.phases == [.loading])
        }
    }

    @Test("Whisper: a complete download without sidecars or marker is recognised, without any request")
    func whisperCompleteWithoutSidecars() async throws {
        try await withFixture(sidecars: false) { fixture in
            try await fixture.load()
            #expect(fixture.server.requests.isEmpty)
            #expect(fixture.loadedFolders.count == 1)
        }
    }

    @Test("Whisper: a file nothing loads may be missing, and others may be added")
    func whisperUnusedFiles() async throws {
        try await withFixture { fixture in
            try fm.removeItem(at: fixture.model.appending(path: "TextDecoder.mlmodelc/model.mlmodel"))
            try Data("x".utf8).write(to: fixture.model.appending(path: ".DS_Store"))
            try await fixture.load()
            #expect(fixture.server.requests.isEmpty)
        }
    }

    @Test("Whisper: a model that fails to load although every file is what was published makes no request")
    func whisperVerifiedModelIsNotDownloadedAgain() async throws {
        try await withFixture { fixture in
            await #expect(throws: LoadError.self) { try await fixture.load(failures: 1) }
            #expect(fixture.server.requests.isEmpty)
            #expect(fixture.loadedFolders.count == 1)
        }
    }

    @Test("Whisper: what was downloaded once is not asked for again")
    func whisperDownloadedOnce() async throws {
        try await withFixture(written: false) { fixture in
            try await fixture.load()
            #expect(fixture.downloaded == Set(
                fixture.published.files.keys.filter { $0.hasPrefix(Published.model) }
                    .map { String($0.dropFirst(Published.model.count + 1)) }
            ).union(WhisperModelFiles.tokenizerFiles))
            #expect(fixture.phases == [.downloading, .loading])
            let requests = fixture.server.requests.count

            try await fixture.load()
            #expect(fixture.server.requests.count == requests)
            #expect(fixture.loadedFolders.count == 2)
        }
    }

    // MARK: Interrupted download

    @Test("Whisper: an interrupted download is resumed, whichever file is missing", arguments: WhisperModelFiles.expectedFiles)
    func whisperResume(missing name: String) async throws {
        try await withFixture { fixture in
            try fm.removeItem(at: fixture.model.appending(path: name))
            // What an interrupted transfer leaves, for this file.
            let digest = Published.digest(of: name, try #require(fixture.published.content(of: name, size: fixture.size)))
            try Published.write(Data(), to: fixture.repository.appending(
                path: ".cache/huggingface/download/\(fixture.size.whisperKitModel)/\(name).\(digest).incomplete"))

            try await fixture.load()
            #expect(fixture.downloaded == ["\(fixture.size.whisperKitModel)/\(name)"])
            #expect(try Data(contentsOf: fixture.model.appending(path: name)) == fixture.published.content(of: name, size: fixture.size))
            #expect(fixture.loadedFolders.count == 1)
        }
    }

    @Test("Whisper: offline, an incomplete model is not loaded and nothing is removed")
    func whisperIncompleteOffline() async throws {
        try await withFixture { fixture in
            let address = fixture.server.address
            fixture.server.stop()
            try fm.removeItem(at: fixture.model.appending(path: "config.json"))
            let damaged = fixture.model.appending(path: "AudioEncoder.mlmodelc/model.mil")
            try Data("damaged".utf8).write(to: damaged)
            await #expect(throws: (any Error).self) { try await fixture.load(server: address) }
            #expect(fixture.loadedFolders.isEmpty)
            #expect(try Data(contentsOf: damaged) == Data("damaged".utf8))
        }
    }

    @Test("Whisper: a listing without a file Core ML needs is an error")
    func whisperListingIncomplete() async throws {
        try await withRoot { _, cache in
            var published = Published(.base)
            published.files["\(Published.model)/openai_whisper-base/AudioEncoder.mlmodelc/model.mil"] = nil
            let server = try await FakeModelServer { [published] in published.respond($0) }
            defer { server.stop() }
            await #expect(throws: ModelDownloadError.incomplete(model: "openai_whisper-base")) {
                try await WhisperModelFiles.load(.base, downloadBase: cache, server: server.address) { _ in
                    Issue.record("Loaded")
                }
            }
        }
    }

    // MARK: Damage

    private static let damages: [(String, Data)] = [
        ("AudioEncoder.mlmodelc/model.mil", Data("program(".utf8)),
        ("AudioEncoder.mlmodelc/weights/weight.bin", Data(count: 64)),
        ("TextDecoder.mlmodelc/coremldata.bin", Data()),
        ("MelSpectrogram.mlmodelc/metadata.json", Data("{".utf8)),
        ("config.json", Data("{".utf8)),
    ]

    @Test("Whisper: a damaged file is downloaded again before loading, and only that one", arguments: damages)
    func whisperDamaged(_ name: String, _ content: Data) async throws {
        try await withFixture { fixture in
            try content.write(to: fixture.model.appending(path: name))
            try await fixture.load()
            #expect(fixture.downloaded == ["\(fixture.size.whisperKitModel)/\(name)"])
            #expect(try Data(contentsOf: fixture.model.appending(path: name)) == fixture.published.content(of: name, size: fixture.size))

            let requests = fixture.server.requests.count
            try await fixture.load()
            #expect(fixture.server.requests.count == requests)
        }
    }

    @Test("Whisper: a file where a folder belongs, and a folder where a file belongs, are replaced")
    func whisperObstacles() async throws {
        try await withFixture { fixture in
            let encoder = fixture.model.appending(path: "AudioEncoder.mlmodelc")
            try fm.removeItem(at: encoder)
            try Data("file".utf8).write(to: encoder)
            let config = fixture.model.appending(path: "config.json")
            try fm.removeItem(at: config)
            try fm.createDirectory(at: config, withIntermediateDirectories: true)
            try await fixture.load()
            #expect(WhisperModelFiles.isPresent(fixture.size.whisperKitModel, in: fixture.repository))
        }
    }

    @Test("Whisper: without sidecars, compiled models that Core ML cannot load are downloaded again, once")
    func whisperUnreadable() async throws {
        try await withFixture(sidecars: false) { fixture in
            // No fixture file is a model: Core ML loads none of them.
            let damaged = fixture.model.appending(path: "AudioEncoder.mlmodelc/coremldata.bin")
            try Data("damaged".utf8).write(to: damaged)
            try await fixture.load(failures: 1)
            #expect(fixture.downloaded.isSuperset(of: WhisperModelFiles.loadedFiles.map { "\(fixture.size.whisperKitModel)/\($0)" }))
            #expect(try Data(contentsOf: damaged) == fixture.published.content(of: "AudioEncoder.mlmodelc/coremldata.bin", size: fixture.size))
            #expect(fixture.loadedFolders.count == 2)
            #expect(fixture.phases == [.loading, .downloading, .loading])
        }
    }

    @Test("Whisper: a file repaired since it was found damaged is not removed")
    func whisperRepairedMeanwhile() async throws {
        try await withFixture { fixture in
            let names = WhisperModelFiles.expectedFiles.map { "\(fixture.size.whisperKitModel)/\($0)" }
            try await WhisperModelFiles.download(
                fixture.size.whisperKitModel, replacing: names, downloadBase: fixture.cache, server: fixture.server.address
            )
            #expect(fixture.downloaded.isEmpty)
        }
    }

    @Test("Whisper: the second failure is the caller's")
    func whisperRepairOnce() async throws {
        try await withFixture(sidecars: false) { fixture in
            await #expect(throws: LoadError.self) { try await fixture.load(failures: 2) }
            #expect(fixture.loadedFolders.count == 2)
        }
    }

    @Test("Whisper: a sidecar that is not the digest of what the server sends causes one download, not one per launch")
    func whisperWrongDigest() async throws {
        try await withRoot { _, cache in
            let published = Published(.base)
            // The server announces something else than the file's digest.
            let server = try await FakeModelServer { request in
                var response = published.respond(request)
                if request.path.hasSuffix("weight.bin") { response.headers["ETag"] = "\"\(String(repeating: "a", count: 64))\"" }
                return response
            }
            defer { server.stop() }
            func load() async throws {
                try await WhisperModelFiles.load(.base, downloadBase: cache, server: server.address) { _ in }
            }
            try await load()
            try await load()
            let requests = server.requests.count
            try await load()
            #expect(server.requests.count == requests)
        }
    }

    // MARK: Previous model (switchover)

    @Test("Whisper: the previous model is loaded without any request when complete, and never downloaded")
    func whisperLocalOnly() async throws {
        try await withFixture(.medium) { fixture in
            try await fixture.load(localOnly: true)
            #expect(fixture.server.requests.isEmpty)

            // Also when it does not load.
            await #expect(throws: LoadError.self) { try await fixture.load(localOnly: true, failures: 2) }
            try fm.removeItem(at: fixture.model.appending(path: "AudioEncoder.mlmodelc/model.mil"))
            await #expect(throws: ModelDownloadError.incomplete(model: "openai_whisper-medium")) {
                try await fixture.load(localOnly: true)
            }
            #expect(fixture.server.requests.isEmpty)
        }
    }

    // MARK: Tokenizer

    @Test("Whisper: a missing or damaged tokenizer file is downloaded by the app, and only the tokenizer",
          arguments: WhisperModelFiles.tokenizerFiles, [nil, Data(), Data("{".utf8)])
    func whisperTokenizer(_ name: String, _ content: Data?) async throws {
        for sidecars in [true, false] {
            try await withFixture(.largev3Turbo, sidecars: sidecars) { fixture in
                let file = fixture.tokenizer.appending(path: name)
                if let content { try content.write(to: file) } else { try fm.removeItem(at: file) }
                try await fixture.load()
                #expect(fixture.downloaded.contains(name))
                #expect(fixture.downloaded.isSubset(of: WhisperModelFiles.tokenizerFiles))
                #expect(try Data(contentsOf: file) == fixture.published.files["openai/whisper-large-v3/\(name)"])
                #expect(fixture.server.requests.allSatisfy { $0.path.contains("openai/whisper-large-v3/") })
            }
        }
    }

    @Test("Whisper: a tokenizer kept in the model's folder is found, as WhisperKit finds it")
    func whisperTokenizerInModelFolder() async throws {
        try await withFixture { fixture in
            let inModel = fixture.model.appending(path: "models/openai/whisper-base")
            try fm.createDirectory(at: inModel.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: fixture.tokenizer, to: inModel)
            try await fixture.load()
            #expect(fixture.server.requests.isEmpty)
        }
    }

    // MARK: Parts

    @Test("Files a model must have are those all published models have")
    func whisperExpectedFiles() {
        // The listings of base, small and large-v3-v20240930_626MB on 2026-11-24, without the
        // two model.mlmodel files that only base and small have.
        let published: Set<String> = [
            "AudioEncoder.mlmodelc/analytics/coremldata.bin", "AudioEncoder.mlmodelc/coremldata.bin",
            "AudioEncoder.mlmodelc/metadata.json", "AudioEncoder.mlmodelc/model.mil",
            "AudioEncoder.mlmodelc/weights/weight.bin",
            "MelSpectrogram.mlmodelc/analytics/coremldata.bin", "MelSpectrogram.mlmodelc/coremldata.bin",
            "MelSpectrogram.mlmodelc/metadata.json", "MelSpectrogram.mlmodelc/model.mil",
            "MelSpectrogram.mlmodelc/weights/weight.bin",
            "TextDecoder.mlmodelc/analytics/coremldata.bin", "TextDecoder.mlmodelc/coremldata.bin",
            "TextDecoder.mlmodelc/metadata.json", "TextDecoder.mlmodelc/model.mil",
            "TextDecoder.mlmodelc/weights/weight.bin",
            "config.json", "generation_config.json",
        ]
        #expect(Set(WhisperModelFiles.expectedFiles) == published)
        #expect(WhisperModelSize.selectable.map(\.tokenizerRepository)
            == ["openai/whisper-base", "openai/whisper-small", "openai/whisper-large-v3"])
    }

    @Test("Sidecar digests: SHA-256, git blob SHA-1, anything else is ignored")
    func whisperDigests() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("NanoWhisperDigestTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let folder = HubRepositoryFolder(url: root)
        // `printf hello | git hash-object --stdin`, `printf hello | shasum -a 256`
        let git = "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0"
        let sha256 = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        func state(sidecar: String?) throws -> HubRepositoryFolder.FileState {
            folder.removeSidecar(of: "a/b")
            if let sidecar { try Published.write(Data(sidecar.utf8), to: root.appending(path: ".cache/huggingface/download/a/b.metadata")) }
            return folder.state(of: "a/b")
        }
        #expect(try state(sidecar: "c\n\(git)\n1\n") == .missing)
        try Published.write(Data("hello".utf8), to: root.appending(path: "a/b"))
        #expect(try state(sidecar: "c\n\(git)\n1\n") == .present(verified: true))
        #expect(try state(sidecar: "c\n\(sha256)\n1\n") == .present(verified: true))
        #expect(try state(sidecar: "c\n\(git.replacingOccurrences(of: "b6", with: "00"))\n1\n") == .damaged)
        for unusable in ["", "c", "c\nW/abc\n1\n", "c\n\(git.uppercased())\n1\n"] {
            #expect(try state(sidecar: unusable) == .present(verified: false))
        }
        #expect(try state(sidecar: nil) == .present(verified: false))
        #expect(folder.state(of: "a") == .damaged)
    }
}
