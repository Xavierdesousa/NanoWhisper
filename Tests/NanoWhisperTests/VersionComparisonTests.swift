import Testing
@testable import NanoWhisper

@Suite("Version Comparison")
struct VersionComparisonTests {

    @Test("Newer patch version is detected")
    func newerPatch() {
        #expect(AutoUpdater.isNewerVersion("1.0.1", than: "1.0.0") == true)
    }

    @Test("Same version is not newer")
    func sameVersion() {
        #expect(AutoUpdater.isNewerVersion("1.0.0", than: "1.0.0") == false)
    }

    @Test("Older version is not newer")
    func olderVersion() {
        #expect(AutoUpdater.isNewerVersion("0.9.9", than: "1.0.0") == false)
    }

    @Test("Major version bump beats high minor/patch")
    func majorBump() {
        #expect(AutoUpdater.isNewerVersion("2.0.0", than: "1.99.99") == true)
    }

    @Test("Extra segment makes version newer")
    func extraSegment() {
        #expect(AutoUpdater.isNewerVersion("1.0.0.1", than: "1.0.0") == true)
    }

    @Test("Fewer segments with same prefix is not newer")
    func fewerSegments() {
        #expect(AutoUpdater.isNewerVersion("1.0", than: "1.0.0") == false)
    }

    @Test("Single segment comparison")
    func singleSegment() {
        #expect(AutoUpdater.isNewerVersion("2", than: "1") == true)
        #expect(AutoUpdater.isNewerVersion("1", than: "2") == false)
    }

    @Test("Newer minor version")
    func newerMinor() {
        #expect(AutoUpdater.isNewerVersion("0.1.0", than: "0.0.2") == true)
    }
}
