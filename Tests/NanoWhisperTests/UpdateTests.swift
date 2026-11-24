import Foundation
import os
import Testing
@testable import NanoWhisper

@Suite("Update: versions and release archive")
struct UpdateReleaseTests {
    private let url = "https://github.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip"
    private let digest = String(repeating: "0a", count: 32)

    private func release(
        tag: String = "v0.1.1", name: String = "NanoWhisper-v0.1.1.zip", url: String? = nil, digest: String? = nil
    ) -> GitHubRelease {
        GitHubRelease(tagName: tag, assets: [
            .init(name: "Source.zip", browserDownloadUrl: "https://example.com/Source.zip", digest: nil),
            .init(name: name, browserDownloadUrl: url ?? self.url, digest: digest),
        ])
    }

    @Test("Versions compare number by number")
    func versions() throws {
        let ordered = ["0.0.9", "0.0.10", "0.1.0", "0.1.1", "0.2", "0.10.0", "1"]
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(try #require(AppVersion(lower)) < #require(AppVersion(higher)), "\(lower) < \(higher)")
        }
        #expect(AppVersion("1.0") == AppVersion("1.0.0"))
        #expect(AutoUpdater.isNewerVersion("0.0.10", than: "0.0.9"))
        #expect(!AutoUpdater.isNewerVersion("0.0.9", than: "0.0.10"))
    }

    @Test("Text that is not a version", arguments: [
        "", ".", "1.", ".1", "1..2", "v1.0", "1.0-beta.1", "1.x", " 1.0", "+1.0", "-1", "١.٢", "99999999999999999999",
    ])
    func notAVersion(text: String) {
        #expect(AppVersion(text) == nil)
        #expect(!AutoUpdater.isNewerVersion(text, than: "0.0.1"))
        #expect(!AutoUpdater.isNewerVersion("0.0.1", than: text))
    }

    @Test("The archive is the asset with the exact name, whatever its position")
    func exactName() throws {
        let offer = try UpdateOffer(release: release(digest: "sha256:" + digest.uppercased()))
        #expect(offer.version == "0.1.1")
        #expect(offer.archiveURL.absoluteString == url)
        #expect(offer.sha256 == digest)
        #expect(try UpdateOffer(release: release()).sha256 == nil)
    }

    @Test("No other asset is taken", arguments: [
        "NanoWhisper-v0.1.1.zip.zip", "nanowhisper-v0.1.1.zip", "NanoWhisper-v0.1.0.zip", "NanoWhisper.zip",
    ])
    func otherName(name: String) {
        #expect(throws: UpdateError.noArchive(version: "0.1.1")) {
            try UpdateOffer(release: release(name: name))
        }
    }

    @Test("A tag that is not a version is refused")
    func tagIsNotAVersion() {
        #expect(throws: UpdateError.noArchive(version: "0.1.1-beta.1")) {
            try UpdateOffer(release: release(tag: "v0.1.1-beta.1", name: "NanoWhisper-v0.1.1-beta.1.zip"))
        }
    }

    @Test("A digest that cannot be compared is refused", arguments: ["sha256:", "sha256:00", "md5:00", "x"])
    func unusableDigest(digest: String) {
        #expect(throws: UpdateError.digestMismatch) { try UpdateOffer(release: release(digest: digest)) }
    }

    @Test("Owner and repository in any case, as GitHub accepts them", arguments: [
        "https://github.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip",
        "https://github.com/xavierdesousa/nanowhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip",
        "HTTPS://GitHub.com/XAVIERDESOUSA/NANOWHISPER/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip",
    ])
    func acceptedURL(url: String) throws {
        #expect(try UpdateOffer(release: release(url: url)).archiveURL.absoluteString == url)
    }

    @Test("Any other address is refused", arguments: [
        "http://github.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip",
        "file:///Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip",
        "https://example.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip",
        "https://github.com.example.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip",
        "https://github.com@example.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip",
        "https://user@github.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip",
        "https://github.com:8443/Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip",
        "https://github.com/someone/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip",
        "https://github.com/Xavierdesousa/other/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip",
        "https://github.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.0/NanoWhisper-v0.1.1.zip",
        "https://github.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.0.zip",
        "https://github.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.1/../v0.1.0/NanoWhisper-v0.1.1.zip",
        "https://github.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.1%2F..%2Fv0.1.0/NanoWhisper-v0.1.1.zip",
        "https://github.com/Xavierdesousa/NanoWhisper/raw/download/v0.1.1/NanoWhisper-v0.1.1.zip",
        "https://github.com//Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip",
        "https://github.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip?x=1",
        "https://github.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip#x",
        "not a url", "",
    ])
    func refusedURL(url: String) {
        #expect(throws: UpdateError.noArchive(version: "0.1.1")) { try UpdateOffer(release: release(url: url)) }
    }

    @Test("Decodes the digest of GitHub's answer")
    func decodesDigest() throws {
        let json = """
        {"tag_name": "v0.1.1", "assets": [{"name": "NanoWhisper-v0.1.1.zip", "size": 12,
          "digest": "sha256:\(digest)", "browser_download_url": "\(url)"}]}
        """
        let offer = try UpdateOffer(release: JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8)))
        #expect(offer.sha256 == digest)
    }
}

@Suite("Update: code signature")
struct UpdateSignatureTests {
    private let sandbox: UpdateSandbox
    private let app: URL

    init() throws {
        sandbox = try UpdateSandbox()
        app = sandbox.url("New.app")
    }

    @Test("The accepted requirements are valid and name the production app")
    func requirementsParse() throws {
        _ = try UpdateSignature.makeRequirement(anyOf: UpdateSignature.acceptedRequirements)
        #expect(!UpdateSignature.acceptedRequirements.isEmpty)
        for requirement in UpdateSignature.acceptedRequirements {
            #expect(requirement.hasPrefix(#"identifier "\#(BuildFlavor.productionBundleIdentifier)" and "#))
        }
    }

    @Test("A valid bundle gives its sealed identifier and version")
    func validBundle() throws {
        try sandbox.makeApp(at: app, version: "0.1.1")
        #expect(try UpdateSignature.verify(app, requirements: UpdateSandbox.requirements)
            == .init(identifier: "com.moonji.nanowhisper", version: "0.1.1"))
    }

    @Test("One of several requirements is enough; none of them, or no requirement, is refused")
    func severalRequirements() throws {
        try sandbox.makeApp(at: app, version: "0.1.1")
        let other = #"identifier "com.example.other""#
        _ = try UpdateSignature.verify(app, requirements: [other] + UpdateSandbox.requirements)
        #expect(throws: UpdateError.signature) { try UpdateSignature.verify(app, requirements: [other, other]) }
        #expect(throws: UpdateError.signature) { try UpdateSignature.verify(app, requirements: []) }
    }

    @Test("An ad-hoc signature is refused by the releases' requirements")
    func adHoc() throws {
        try sandbox.makeApp(at: app, version: "0.1.1")
        #expect(throws: UpdateError.signature) { try UpdateSignature.verify(app) }
    }

    @Test("An unsigned bundle is refused")
    func unsigned() throws {
        try sandbox.makeApp(at: app, version: "0.1.1", signed: false)
        #expect(throws: UpdateError.signature) {
            try UpdateSignature.verify(app, requirements: UpdateSandbox.requirements)
        }
    }

    @Test("A bundle changed after signing is refused", arguments: [
        "Contents/Resources/file.txt", "Contents/Info.plist", "Contents/MacOS/NanoWhisper",
    ])
    func changedFile(path: String) throws {
        try sandbox.makeApp(at: app, version: "0.1.1")
        let file = app.appendingPathComponent(path)
        var data = try Data(contentsOf: file)
        // In the middle: inside the plist's text, and inside a signed page of the executable.
        data[data.count / 2] ^= 0x01
        try data.write(to: file)
        #expect(throws: UpdateError.signature) {
            try UpdateSignature.verify(app, requirements: UpdateSandbox.requirements)
        }
    }

    @Test("A bundle with a file added after signing is refused")
    func addedFile() throws {
        try sandbox.makeApp(at: app, version: "0.1.1")
        try Data("x".utf8).write(to: app.appendingPathComponent("Contents/Resources/added.txt"))
        #expect(throws: UpdateError.signature) {
            try UpdateSignature.verify(app, requirements: UpdateSandbox.requirements)
        }
    }

    @Test("A process that is not a release cannot update itself")
    func runningApp() {
        // The test runner: validly signed, but not NanoWhisper.
        #expect(throws: UpdateError.runningAppNotVerified) { try UpdateSignature.verifyRunningApp() }
        #expect(throws: UpdateError.runningAppNotVerified) { try UpdateSignature.verifyRunningApp(requirements: []) }
    }
}

@Suite("Update: extraction")
struct UpdateExtractionTests {
    private let sandbox: UpdateSandbox
    private let contents: URL
    private let output: URL

    init() throws {
        sandbox = try UpdateSandbox()
        contents = sandbox.url("contents")
        output = sandbox.url("output")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    }

    private func extract(_ archive: URL, limits: UpdateInstaller.Limits = .init()) async throws -> URL {
        try await sandbox.installer(limits: limits).extract(archive, into: output)
    }

    private func refuses(_ archive: URL, with error: UpdateError = .unexpectedContents) async {
        await #expect(throws: error) { try await extract(archive) }
    }

    @Test("One app, its signature intact, in a private directory")
    func oneApp() async throws {
        try sandbox.makeApp(at: contents.appendingPathComponent("NanoWhisper.app"), version: "0.1.1")
        let app = try await extract(sandbox.zip(contentsOf: contents))
        #expect(app.lastPathComponent == "NanoWhisper.app")
        _ = try UpdateSignature.verify(app, requirements: UpdateSandbox.requirements)
        let permissions = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }

    @Test("No app")
    func noApp() async throws {
        try Data("x".utf8).write(to: contents.appendingPathComponent("file.txt"))
        await refuses(try sandbox.zip(contentsOf: contents))
    }

    @Test("Two apps")
    func twoApps() async throws {
        try sandbox.makeApp(at: contents.appendingPathComponent("NanoWhisper.app"), version: "0.1.1")
        try sandbox.makeApp(at: contents.appendingPathComponent("Other.APP"), version: "0.1.1")
        await refuses(try sandbox.zip(contentsOf: contents))
    }

    @Test("An app that is a file, or a link")
    func notADirectory() async throws {
        let app = contents.appendingPathComponent("NanoWhisper.app")
        try Data("x".utf8).write(to: app)
        await refuses(try sandbox.zip(contentsOf: contents, name: "file.zip"))
        try FileManager.default.removeItem(at: app)
        try FileManager.default.removeItem(at: output)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: sandbox.installed)
        await refuses(try sandbox.zip(contentsOf: contents, name: "link.zip"))
    }

    @Test("A link inside the app is accepted")
    func insideLink() async throws {
        try sandbox.makeApp(
            at: contents.appendingPathComponent("NanoWhisper.app"), version: "0.1.1",
            links: ["Contents/Resources/link": "file.txt", "Contents/Resources/up": "../Resources"]
        )
        let app = try await extract(sandbox.zip(contentsOf: contents))
        _ = try UpdateSignature.verify(app, requirements: UpdateSandbox.requirements)
    }

    @Test("A link out of the app is refused", arguments: [
        "/etc/hosts", "../../../..", "../../../Other", "../../../NanoWhisper.app.other", "missing",
    ])
    func outsideLink(target: String) async throws {
        let app = contents.appendingPathComponent("NanoWhisper.app")
        try sandbox.makeApp(at: app, version: "0.1.1")
        for other in ["Other", "NanoWhisper.app.other"] {
            try Data("x".utf8).write(to: contents.appendingPathComponent(other))
        }
        try FileManager.default.createSymbolicLink(
            atPath: app.appendingPathComponent("Contents/Resources/link").path, withDestinationPath: target
        )
        await refuses(try sandbox.zip(contentsOf: contents))
    }

    @Test("A link that only leaves the app through another link is refused")
    func chainedLink() async throws {
        let app = contents.appendingPathComponent("NanoWhisper.app")
        try sandbox.makeApp(at: app, version: "0.1.1", links: [
            "Contents/Resources/short": "..", "Contents/Resources/long": "short/../..",
        ])
        await refuses(try sandbox.zip(contentsOf: contents))
    }

    @Test("Entries named out of the directory stay in it", arguments: ["../escaped.txt", "A.app/../../escaped.txt"])
    func parentEntries(name: String) async throws {
        var zip = ZipWriter()
        zip.add("A.app/file.txt", "x")
        zip.add(name, "x")
        let archive = sandbox.url("entries.zip")
        try zip.data.write(to: archive)
        _ = try? await extract(archive)
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("A.app/file.txt").path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.url("escaped.txt").path))
    }

    @Test("Nothing is written through a link")
    func writeThroughLink() async throws {
        let outside = sandbox.url("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        var zip = ZipWriter()
        zip.add("A.app/link", outside.path, mode: S_IFLNK | 0o777)
        zip.add("A.app/link/written.txt", "x")
        let archive = sandbox.url("through.zip")
        try zip.data.write(to: archive)
        await #expect(throws: UpdateError.self) { try await extract(archive) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("A file that is not an archive")
    func notAnArchive() async throws {
        let archive = sandbox.url("update.zip")
        try Data("not a zip".utf8).write(to: archive)
        await refuses(archive, with: .extraction)
    }

    @Test("More content than the limit")
    func tooLarge() async throws {
        try sandbox.makeApp(at: contents.appendingPathComponent("NanoWhisper.app"), version: "0.1.1")
        // Zeros: 20 MB in an archive of a few kilobytes.
        try Data(count: 20_000_000).write(to: contents.appendingPathComponent("NanoWhisper.app/zeros"))
        let archive = try sandbox.zip(contentsOf: contents)
        #expect(try Data(contentsOf: archive).count < 1_000_000)
        await #expect(throws: UpdateError.extractedTooLarge) {
            try await extract(archive, limits: .init(extracted: 10_000_000))
        }
    }

    @Test("The real release fits the limits at least ten times")
    func limits() {
        #expect(UpdateInstaller.Limits().download >= 10 * 5_736_037)
        #expect(UpdateInstaller.Limits().extracted >= 10 * 15_826_038)
    }

    @Test("A helper process is stopped as soon as the caller says so")
    func stopCondition() async {
        let start = Date()
        let output = await Subprocess.run(
            URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 30, stopWhen: { true }
        )
        #expect(output == nil)
        #expect(Date().timeIntervalSince(start) < 10)
        let finished = await Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/true"), arguments: [], timeout: 30, stopWhen: { false }
        )
        #expect(finished?.status == 0)
    }
}

@Suite("Update: installation", .serialized)
struct UpdateInstallationTests {
    private static let archiveURL =
        "https://github.com/Xavierdesousa/NanoWhisper/releases/download/v0.1.1/NanoWhisper-v0.1.1.zip"
    private static let assetHostURL = "https://release-assets.githubusercontent.com/file?token=x"

    private let sandbox: UpdateSandbox
    private let before: [String: Data]

    init() throws {
        sandbox = try UpdateSandbox()
        before = try UpdateSandbox.snapshot(sandbox.installed)
    }

    private func archive(
        version: String = "0.1.1", identifier: String = "com.moonji.nanowhisper", signed: Bool = true
    ) throws -> Data {
        try sandbox.zip(sandbox.makeApp(
            at: sandbox.url("build/NanoWhisper.app"), version: version, identifier: identifier, signed: signed
        ))
    }

    private func digest(_ data: Data) throws -> String {
        let file = sandbox.url("digest")
        try data.write(to: file)
        return try UpdateInstaller.sha256(of: file)
    }

    private func offer(tag: String = "v0.1.1", digest: String? = nil) throws -> UpdateOffer {
        let name = "NanoWhisper-\(tag).zip"
        return try UpdateOffer(release: GitHubRelease(tagName: tag, assets: [.init(
            name: name, browserDownloadUrl: "https://github.com/Xavierdesousa/NanoWhisper/releases/download/\(tag)/\(name)",
            digest: digest.map { "sha256:\($0)" }
        )]))
    }

    /// The installed app is the same one, unchanged, and no temporary file is left.
    private func expectUntouched() throws {
        #expect(try UpdateSandbox.snapshot(sandbox.installed) == before)
        #expect(!FileManager.default.fileExists(atPath: sandbox.stagingDirectory.path))
        let folder = sandbox.installed.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["NanoWhisper.app"])
    }

    private func expectRefused(
        _ error: UpdateError, offer: UpdateOffer, installer: UpdateInstaller? = nil
    ) async throws {
        await #expect(throws: error) { try await (installer ?? sandbox.installer()).install(offer) }
        try expectUntouched()
    }

    private func installedVersion() throws -> String? {
        try UpdateSignature.verify(sandbox.installed, requirements: UpdateSandbox.requirements).version
    }

    @Test("A valid update replaces the installed app, and nothing else is left")
    func installs() async throws {
        let data = try archive()
        StubProtocol.reply { _ in .data(data) }
        let progress = OSAllocatedUnfairLock<[Double]>(initialState: [])
        try await sandbox.installer().install(offer(digest: digest(data))) { value in
            progress.withLock { $0.append(value) }
        }
        #expect(try installedVersion() == "0.1.1")
        #expect(!FileManager.default.fileExists(atPath: sandbox.stagingDirectory.path))
        let folder = sandbox.installed.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["NanoWhisper.app"])
        let values = progress.withLock { $0 }
        #expect(values == values.sorted() && values.last == 1)
    }

    @Test("The system's replacement directory is private and on the app's volume")
    func stagingDirectory() throws {
        let staging = try UpdateInstaller().makeStagingDirectory(sandbox.installed)
        defer { try? FileManager.default.removeItem(at: staging) }
        let attributes = try FileManager.default.attributesOfItem(atPath: staging.path)
        let installed = try FileManager.default.attributesOfItem(atPath: sandbox.installed.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
        #expect(attributes[.systemNumber] as? Int == installed[.systemNumber] as? Int)
    }

    @Test("An app that is not a release does not even download")
    func runningAppNotVerified() async throws {
        StubProtocol.reply { _ in .data(Data()) }
        var installer = sandbox.installer()
        installer.verifyRunningApp = UpdateInstaller().verifyRunningApp
        try await expectRefused(.runningAppNotVerified, offer: offer(), installer: installer)
        #expect(StubProtocol.requestedURLs.isEmpty)
    }

    @Test("Another file than the one published is refused")
    func digestMismatch() async throws {
        let data = try archive()
        StubProtocol.reply { _ in .data(data) }
        try await expectRefused(.digestMismatch, offer: offer(digest: String(repeating: "0", count: 64)))
    }

    @Test("An ad-hoc signed update is refused by the releases' requirements")
    func adHocUpdate() async throws {
        let data = try archive()
        StubProtocol.reply { _ in .data(data) }
        let installer = sandbox.installer(requirements: UpdateSignature.acceptedRequirements)
        try await expectRefused(.signature, offer: offer(digest: digest(data)), installer: installer)
    }

    @Test("An unsigned update is refused")
    func unsignedUpdate() async throws {
        let data = try archive(signed: false)
        StubProtocol.reply { _ in .data(data) }
        try await expectRefused(.signature, offer: offer())
    }

    @Test("An update changed after signing is refused")
    func changedUpdate() async throws {
        let app = try sandbox.makeApp(at: sandbox.url("build/NanoWhisper.app"), version: "0.1.1")
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/Resources/file.txt"))
        let data = try sandbox.zip(app)
        StubProtocol.reply { _ in .data(data) }
        try await expectRefused(.signature, offer: offer())
    }

    @Test("Another app is refused, even with an accepted signature")
    func wrongIdentifier() async throws {
        let data = try archive(identifier: "com.moonji.nanowhisper.debug")
        StubProtocol.reply { _ in .data(data) }
        try await expectRefused(.signature, offer: offer())
        let anyone = sandbox.installer(requirements: [#"identifier "com.moonji.nanowhisper.debug""#])
        try await expectRefused(.wrongApp, offer: offer(), installer: anyone)
    }

    @Test("The app's version must be the release's")
    func otherVersion() async throws {
        let data = try archive(version: "0.1.2")
        StubProtocol.reply { _ in .data(data) }
        try await expectRefused(.wrongVersion(found: "0.1.2", expected: "0.1.1"), offer: offer())
    }

    @Test("The same version and an older one are refused", arguments: ["0.1.0", "0.0.10"])
    func notNewer(version: String) async throws {
        let data = try archive(version: version)
        StubProtocol.reply { _ in .data(data) }
        try await expectRefused(.notNewer(found: version, installed: "0.1.0"), offer: offer(tag: "v\(version)"))
    }

    @Test("An unreadable installed version refuses every update")
    func unknownInstalledVersion() async throws {
        let data = try archive()
        StubProtocol.reply { _ in .data(data) }
        var installer = sandbox.installer()
        installer.installedVersion = "?"
        try await expectRefused(.notNewer(found: "0.1.1", installed: "?"), offer: offer(), installer: installer)
    }

    @Test("A download over the limit is refused, declared or not", arguments: [true, false])
    func downloadTooLarge(declaresLength: Bool) async throws {
        StubProtocol.reply { _ in .data(Data(count: 300_000), declaresLength: declaresLength) }
        let installer = sandbox.installer(limits: .init(download: 299_999))
        try await expectRefused(.downloadTooLarge, offer: offer(), installer: installer)
    }

    @Test("A file that is not an archive, and an error page, are refused")
    func badDownload() async throws {
        StubProtocol.reply { _ in .data(Data("not a zip".utf8)) }
        try await expectRefused(.extraction, offer: offer())
        StubProtocol.reply { _ in .data(Data("not found".utf8), status: 404) }
        try await expectRefused(.download, offer: offer())
    }

    @Test("GitHub's redirect to its asset host is followed")
    func httpsRedirect() async throws {
        let data = try archive()
        StubProtocol.reply { $0.host == "github.com" ? .redirect(Self.assetHostURL) : .data(data) }
        try await sandbox.installer().install(offer())
        #expect(StubProtocol.requestedURLs.map(\.absoluteString) == [Self.archiveURL, Self.assetHostURL])
        #expect(try installedVersion() == "0.1.1")
    }

    @Test("A redirect to http is not followed, not even the second one")
    func httpRedirect() async throws {
        let data = try archive()
        StubProtocol.reply { $0.host == "github.com" ? .redirect("http://example.com/update.zip") : .data(data) }
        try await expectRefused(.download, offer: offer())
        #expect(StubProtocol.requestedURLs.map(\.absoluteString) == [Self.archiveURL])

        StubProtocol.reply {
            switch $0.host {
            case "github.com": return .redirect(Self.assetHostURL)
            case "release-assets.githubusercontent.com": return .redirect("http://example.com/update.zip")
            default: return .data(data)
            }
        }
        try await expectRefused(.download, offer: offer())
        #expect(StubProtocol.requestedURLs.map(\.absoluteString) == [Self.archiveURL, Self.assetHostURL])
    }

    @Test("When the app cannot be replaced, it stays as it was")
    func replacementFails() async throws {
        let data = try archive()
        StubProtocol.reply { _ in .data(data) }
        let folder = sandbox.installed.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let error = await #expect(throws: UpdateError.self) { try await sandbox.installer().install(offer()) }
        guard case .replacement = error else {
            Issue.record("\(String(describing: error))")
            return
        }
        try expectUntouched()
    }

    // MARK: The updater as a whole

    @MainActor
    private func updater(_ relaunched: @escaping @MainActor (URL) throws -> Void) -> AutoUpdater {
        AutoUpdater(isEnabled: true, installer: sandbox.installer(), relaunch: relaunched)
    }

    /// GitHub: the latest release, and its archive behind the usual redirect.
    private func publish(_ data: Data, digest: String) {
        let json = """
        {"tag_name": "v0.1.1", "assets": [{"name": "NanoWhisper-v0.1.1.zip", "digest": "sha256:\(digest)",
          "browser_download_url": "\(Self.archiveURL)"}]}
        """
        StubProtocol.reply {
            switch $0.host {
            case "api.github.com": return .data(Data(json.utf8))
            case "github.com": return .redirect(Self.assetHostURL)
            default: return .data(data)
            }
        }
    }

    @Test("Check, install, relaunch")
    @MainActor
    func wholeUpdate() async throws {
        let data = try archive()
        publish(data, digest: try digest(data))
        var relaunched: [URL] = []
        let updater = updater { relaunched.append($0) }
        await updater.checkForUpdates()
        #expect(updater.updateAvailable)
        #expect(updater.latestVersion == "0.1.1")
        await updater.downloadAndInstall()
        #expect(updater.error == nil)
        #expect(updater.downloadProgress == 1)
        #expect(relaunched == [sandbox.installed])
        #expect(try installedVersion() == "0.1.1")
    }

    @Test("A refused update says so, changes nothing and does not relaunch")
    @MainActor
    func wholeUpdateRefused() async throws {
        publish(try archive(), digest: String(repeating: "0", count: 64))
        var relaunched: [URL] = []
        let updater = updater { relaunched.append($0) }
        await updater.checkForUpdates()
        await updater.downloadAndInstall()
        #expect(updater.error == UpdateError.digestMismatch.errorDescription)
        #expect(!updater.isDownloading)
        #expect(relaunched.isEmpty)
        try expectUntouched()
    }

    @Test("When the relaunch fails, the message says the update is installed")
    @MainActor
    func relaunchFails() async throws {
        let data = try archive()
        publish(data, digest: try digest(data))
        let updater = updater { _ in throw CocoaError(.fileNoSuchFile) }
        await updater.checkForUpdates()
        await updater.downloadAndInstall()
        #expect(updater.error == "Version 0.1.1 is installed. Quit NanoWhisper and open it again to use it.")
    }

    @Test("An older or unreadable release is not offered", arguments: ["v0.1.0", "v0.0.10", "nightly", "v0.2.0-beta.1"])
    @MainActor
    func notOffered(tag: String) async {
        StubProtocol.reply { _ in .data(Data(#"{"tag_name": "\#(tag)", "assets": []}"#.utf8)) }
        let updater = updater { _ in }
        await updater.checkForUpdates()
        #expect(!updater.updateAvailable)
        #expect(updater.lastCheckDate != nil)
    }
}

@Suite("Update: relaunch")
struct RelaunchTests {
    @Test("The path is one argument, passed as it is, once the handle is closed", arguments: [
        "NanoWhisper.app", "With space.app", #"Quotes " and ' and \ .app"#, "$(touch other) `touch other`.app",
        "Line\nbreak.app",
    ])
    func opensAfterExit(name: String) async throws {
        let sandbox = try UpdateSandbox()
        let app = sandbox.url(name)
        // Stands for `open`: creates a directory named after its one argument.
        let handle = try Relaunch.afterExit(app, opener: ["/bin/mkdir", "--"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: app.path))

        try handle.close()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: app.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path).sorted()
            == ["Applications", name].sorted())
    }
}
