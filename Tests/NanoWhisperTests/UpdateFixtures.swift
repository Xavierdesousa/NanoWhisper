import Foundation
import os
import Testing
@testable import NanoWhisper

/// Small signed apps and archives in a temporary directory, removed with the instance. The
/// apps are copies of `/usr/bin/true` under NanoWhisper's identifier, signed ad hoc; nothing
/// here is ever launched.
final class UpdateSandbox {
    /// Ad-hoc signatures satisfy this; they never satisfy the real requirements.
    static let requirements = [#"identifier "com.moonji.nanowhisper""#]

    let directory: URL
    /// Stands for the installed app.
    let installed: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("nanowhisper-update-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        installed = directory.appendingPathComponent("Applications/NanoWhisper.app", isDirectory: true)
        try makeApp(at: installed, version: "0.1.0")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func url(_ path: String) -> URL { directory.appendingPathComponent(path) }

    /// An installer that replaces `installed`, whose running app passes as verified.
    func installer(
        limits: UpdateInstaller.Limits = .init(), requirements: [String] = UpdateSandbox.requirements
    ) -> UpdateInstaller {
        let staging = stagingDirectory
        return UpdateInstaller(
            installedApp: installed, installedVersion: "0.1.0", requirements: requirements, limits: limits,
            session: StubProtocol.session(),
            verifyRunningApp: {},
            makeStagingDirectory: { _ in
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                return staging
            }
        )
    }

    /// Where `installer` works; it must be gone afterwards.
    var stagingDirectory: URL { url("staging") }

    // MARK: Apps

    @discardableResult
    func makeApp(
        at url: URL, version: String, identifier: String = "com.moonji.nanowhisper", signed: Bool = true,
        links: [String: String] = [:]
    ) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        for folder in ["MacOS", "Resources"] {
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent(folder), withIntermediateDirectories: true
            )
        }
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "NanoWhisper", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("resource of \(version)".utf8).write(to: contents.appendingPathComponent("Resources/file.txt"))
        for (path, target) in links {
            try FileManager.default.createSymbolicLink(
                atPath: url.appendingPathComponent(path).path, withDestinationPath: target
            )
        }
        let executable = contents.appendingPathComponent("MacOS/NanoWhisper")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: executable.path)
        if signed {
            try Self.run("/usr/bin/codesign", "--force", "--sign", "-", url.path)
        } else {
            try Self.run("/usr/bin/codesign", "--remove-signature", executable.path)
        }
        return url
    }

    /// A zip made like the release's (`ditto -c -k --keepParent`).
    func zip(_ app: URL, name: String = "update.zip") throws -> Data {
        try Self.run("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, url(name).path)
        return try Data(contentsOf: url(name))
    }

    /// A zip of everything in `folder`, at its top level.
    func zip(contentsOf folder: URL, name: String = "update.zip") throws -> URL {
        try Self.run("/usr/bin/ditto", "-c", "-k", folder.path, url(name).path)
        return url(name)
    }

    /// Every file of an app with its content: equal before and after means untouched.
    static func snapshot(_ app: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: app.path) {
            let file = app.appendingPathComponent(path)
            files[path] = file.hasDirectoryPath ? Data() : (try? Data(contentsOf: file)) ?? Data()
        }
        let inode = try FileManager.default.attributesOfItem(atPath: app.path)[.systemFileNumber] as? Int
        files["inode"] = Data("\(inode ?? 0)".utf8)
        return files
    }

    static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(tool) \(arguments) failed")
    }
}

/// Answers every request of `session()` without any network. One handler at a time: the
/// suites that use it are serialized.
final class StubProtocol: URLProtocol {
    enum Reply: Sendable {
        case data(Data, status: Int = 200, declaresLength: Bool = true)
        case redirect(String)
    }

    private static let handler = OSAllocatedUnfairLock<(@Sendable (URL) -> Reply)?>(initialState: nil)
    private static let requested = OSAllocatedUnfairLock<[URL]>(initialState: [])

    static var requestedURLs: [URL] { requested.withLock { $0 } }

    static func reply(_ newHandler: @escaping @Sendable (URL) -> Reply) {
        handler.withLock { $0 = newHandler }
        requested.withLock { $0 = [] }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return UpdateInstaller.makeSession(configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let handler = Self.handler.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.requested.withLock { $0.append(url) }
        switch handler(url) {
        case .data(let data, let status, let declaresLength):
            let headers = declaresLength ? ["Content-Length": "\(data.count)"] : [:]
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

/// A zip with any entry names (`ditto` only writes well-formed ones). Entries are stored.
struct ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var count: UInt16 = 0

    /// `mode` is the Unix mode: a link's is `S_IFLNK`, its content the target.
    mutating func add(_ name: String, _ content: String, mode: mode_t = S_IFREG | 0o644) {
        let name = Data(name.utf8), content = Data(content.utf8)
        // Version, flags, method (stored), time, date, checksum, sizes, name and extra lengths.
        var common = Data()
        for value in [20, 0, 0, 0, 0x21] as [UInt16] { common.appendLE(value) }
        for value in [Self.crc32(content), UInt32(content.count), UInt32(content.count)] { common.appendLE(value) }
        for value in [UInt16(name.count), 0] { common.appendLE(value) }

        let offset = UInt32(body.count)
        body.appendLE(UInt32(0x0403_4b50))
        body.append(common + name + content)

        directory.appendLE(UInt32(0x0201_4b50))
        directory.appendLE(UInt16(3 << 8 | 20)) // made by Unix
        directory.append(common)
        for value in [0, 0, 0] as [UInt16] { directory.appendLE(value) } // comment, disk, internal attributes
        directory.appendLE(UInt32(mode) << 16)
        directory.appendLE(offset)
        directory.append(name)
        count += 1
    }

    var data: Data {
        var end = Data()
        end.appendLE(UInt32(0x0605_4b50))
        for value in [0, 0, count, count] as [UInt16] { end.appendLE(value) }
        for value in [UInt32(directory.count), UInt32(body.count)] { end.appendLE(value) }
        end.appendLE(UInt16(0))
        return body + directory + end
    }

    private static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in
            (0..<8).reduce(crc ^ UInt32(byte)) { value, _ in (value >> 1) ^ (value & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
    }
}

private extension Data {
    mutating func appendLE(_ value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
