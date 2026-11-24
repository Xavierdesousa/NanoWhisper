import Foundation

/// The GitHub API's description of a release (the fields the updater uses).
struct GitHubRelease: Codable {
    let tagName: String
    let assets: [Asset]

    struct Asset: Codable {
        let name: String
        let browserDownloadUrl: String
        /// `sha256:<hex>`, computed by GitHub at upload. Nil when the API gives none.
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
            case digest
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    /// The tag without its "v" (`v0.1.0` is version 0.1.0).
    var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}

/// A version made of numbers separated by periods ("0.1.0"), compared number by number.
/// Any other text has no `AppVersion`.
struct AppVersion: Comparable {
    /// Without trailing zeros, so that 1.0 and 1.0.0 are equal.
    private let components: [Int]

    init?(_ text: String) {
        var components: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  let number = Int(part) else { return nil }
            components.append(number)
        }
        while components.last == 0 { components.removeLast() }
        self.components = components
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

/// The archive of a release, once its name, address and digest have been checked.
struct UpdateOffer: Equatable, Sendable {
    let version: String
    let archiveURL: URL
    /// Lowercase hex. Nil when the API gives no digest.
    let sha256: String?

    init(release: GitHubRelease) throws {
        version = release.version
        let name = Self.archiveName(version: version)
        guard AppVersion(version) != nil,
              let asset = release.assets.first(where: { $0.name == name }),
              let url = URL(string: asset.browserDownloadUrl),
              Self.isArchiveURL(url, tag: release.tagName, name: name) else {
            throw UpdateError.noArchive(version: version)
        }
        archiveURL = url
        sha256 = try asset.digest.map {
            guard let hex = Self.sha256Hex(digest: $0) else { throw UpdateError.digestMismatch }
            return hex
        }
    }

    /// The only asset name accepted; the release workflow checks it (`make release-zip-name`).
    static func archiveName(version: String) -> String { "NanoWhisper-v\(version).zip" }

    /// Whether `url` is this repository's download of `name` for `tag` on github.com, over https.
    /// GitHub ignores case in the owner and repository names (the API answers with its own
    /// spelling, `Xavierdesousa/NanoWhisper`), not in the tag and the file name.
    static func isArchiveURL(_ url: URL, tag: String, name: String) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "github.com",
              parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return false }
        let path = parts.percentEncodedPath.components(separatedBy: "/")
        guard path.count == 7 else { return false }
        return path[0].isEmpty
            && path[1].lowercased() == UpdateRepository.owner.lowercased()
            && path[2].lowercased() == UpdateRepository.name.lowercased()
            && path[3...4] == ["releases", "download"]
            && path[5] == tag
            && path[6] == name
    }

    private static func sha256Hex(digest: String) -> String? {
        let parts = digest.lowercased().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "sha256", parts[1].utf8.count == 64,
              parts[1].utf8.allSatisfy({ "0123456789abcdef".utf8.contains($0) }) else { return nil }
        return String(parts[1])
    }
}

/// Where releases are published.
enum UpdateRepository {
    static let owner = "Xavierdesousa"
    static let name = "nanowhisper"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(owner)/\(name)/releases/latest")!
    /// Shown to users, to download by hand.
    static let releasesPage = "github.com/\(owner)/\(name)/releases"
}

/// Why an update was not installed, in words shown in Settings › Advanced.
enum UpdateError: LocalizedError, Equatable {
    /// The running app is not a release, or its executable was replaced while it runs.
    case runningAppNotVerified
    case noArchive(version: String)
    case download
    case downloadTooLarge
    case digestMismatch
    case extraction
    case extractedTooLarge
    case unexpectedContents
    case signature
    case wrongApp
    case wrongVersion(found: String, expected: String)
    case notNewer(found: String, installed: String)
    case replacement(String)
    case relaunch(version: String)

    var errorDescription: String? {
        switch self {
        case .runningAppNotVerified:
            return "This copy of NanoWhisper cannot update itself, because it could not be verified as a release. "
                + "Download the latest version from \(UpdateRepository.releasesPage)."
        case .noArchive(let version):
            return "Version \(version) has no download that NanoWhisper can install. "
                + "See \(UpdateRepository.releasesPage)."
        case .download:
            return "The update could not be downloaded."
        case .downloadTooLarge, .extractedTooLarge:
            return "The update was not installed: it is larger than expected."
        case .digestMismatch:
            return "The update was not installed: the downloaded file does not match the one published on GitHub."
        case .extraction:
            return "The update was not installed: its archive could not be opened."
        case .unexpectedContents:
            return "The update was not installed: its archive does not contain exactly one app."
        case .signature:
            return "The update was not installed: its signature is not the one NanoWhisper expects. "
                + "Download the latest version from \(UpdateRepository.releasesPage)."
        case .wrongApp:
            return "The update was not installed: it is not NanoWhisper."
        case .wrongVersion(let found, let expected):
            return "The update was not installed: it contains version \(found) instead of \(expected)."
        case .notNewer(let found, let installed):
            return "The update was not installed: version \(found) is not newer than version \(installed)."
        case .replacement(let reason):
            return "The update was not installed: the app could not be replaced. \(reason)"
        case .relaunch(let version):
            return "Version \(version) is installed. Quit NanoWhisper and open it again to use it."
        }
    }
}
