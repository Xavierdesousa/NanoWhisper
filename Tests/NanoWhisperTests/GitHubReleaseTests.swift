import Foundation
import Testing
@testable import NanoWhisper

@Suite("GitHubRelease Decoding")
struct GitHubReleaseTests {

    @Test("Decodes tag_name and assets from GitHub API JSON")
    func decodeRelease() throws {
        let json = """
        {
            "tag_name": "v1.2.3",
            "assets": [
                {
                    "name": "NanoWhisper-v1.2.3.zip",
                    "browser_download_url": "https://github.com/example/releases/download/v1.2.3/NanoWhisper-v1.2.3.zip"
                }
            ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        #expect(release.tagName == "v1.2.3")
        #expect(release.assets.count == 1)
        #expect(release.assets[0].name == "NanoWhisper-v1.2.3.zip")
        #expect(release.assets[0].browserDownloadUrl.contains("v1.2.3"))
    }

    @Test("Decodes release with no assets")
    func decodeEmptyAssets() throws {
        let json = """
        {
            "tag_name": "v0.0.1",
            "assets": []
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        #expect(release.tagName == "v0.0.1")
        #expect(release.assets.isEmpty)
    }

    @Test("Decodes release with multiple assets")
    func decodeMultipleAssets() throws {
        let json = """
        {
            "tag_name": "v2.0.0",
            "assets": [
                {
                    "name": "NanoWhisper-v2.0.0.zip",
                    "browser_download_url": "https://example.com/zip"
                },
                {
                    "name": "NanoWhisper-v2.0.0.dmg",
                    "browser_download_url": "https://example.com/dmg"
                }
            ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        #expect(release.assets.count == 2)
        #expect(release.assets.contains { $0.name.hasSuffix(".zip") })
    }
}
