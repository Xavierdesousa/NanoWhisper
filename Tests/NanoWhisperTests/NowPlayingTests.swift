import Foundation
import Testing
@testable import NanoWhisper

// MARK: - Fake Now Playing session

/// Simulates the system Now Playing session: commands change the playing state of whatever
/// session is current, like a real player would.
@MainActor
private final class FakeNowPlaying: NowPlayingSource {
    var reading: NowPlayingReading
    private(set) var sent: [NowPlayingCommand] = []
    private(set) var readCount = 0

    init(_ reading: NowPlayingReading) {
        self.reading = reading
    }

    func read() async -> NowPlayingReading {
        readCount += 1
        return reading
    }

    func send(_ command: NowPlayingCommand) async -> Bool {
        sent.append(command)
        if case .session(let session) = reading {
            reading = .session(session.with(isPlaying: command == .play))
        }
        return true
    }
}

private extension NowPlayingSession {
    static let vlc = NowPlayingSession(processIdentifier: 24655, bundleIdentifier: "org.videolan.vlc", title: "quiet.wav", isPlaying: true)
    static let chrome = NowPlayingSession(processIdentifier: 25221, bundleIdentifier: "com.google.Chrome", title: "Some video - YouTube", isPlaying: true)

    func with(isPlaying: Bool) -> NowPlayingSession {
        NowPlayingSession(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier, title: title, isPlaying: isPlaying)
    }

    func with(title: String?) -> NowPlayingSession {
        NowPlayingSession(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier, title: title, isPlaying: isPlaying)
    }
}

private func output(_ stdout: String, stderr: String = "", status: Int32 = 0) -> SubprocessOutput {
    SubprocessOutput(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
}

// MARK: - Adapter output parsing

@Suite("mediaremote-adapter output")
struct MediaRemoteAdapterParsingTests {

    @Test("null means no app owns Now Playing")
    func nullIsNoSession() {
        #expect(MediaRemoteAdapter.parseGetOutput(output("null\n")) == .noSession)
    }

    @Test("null with an error on stderr is a failure (MediaRemote timed out)")
    func nullWithErrorFails() {
        let out = output("null\n", stderr: "Reading now playing information timed out after 2000 milliseconds\n")
        #expect(MediaRemoteAdapter.parseGetOutput(out) == .failed)
    }

    @Test("Native player playing (real output, VLC on macOS 27.2)")
    func nativePlayerPlaying() {
        let json = #"{"playbackRate":1,"album":"","trackNumber":0,"elapsedTime":0,"timestamp":"2026-11-19T13:27:17Z","bundleIdentifier":"org.videolan.vlc","processIdentifier":24655,"title":"quiet.wav","duration":600,"artist":"","contentItemIdentifier":"2F66D8BB-7862-417F-AA66-159C50636AB0","playing":true}"#
        #expect(MediaRemoteAdapter.parseGetOutput(output(json + "\n")) == .session(.vlc))
    }

    @Test("Browser tab paused (real output, Chrome on macOS 27.2)")
    func browserPaused() {
        let json = #"{"artist":"","timestamp":"2026-11-19T13:28:22Z","contentItemIdentifier":"5F1AEDC8-9D89-4682-8828-384B3A2F443B","title":"NanoWhisper media test","elapsedTime":8.2347560000000009,"bundleIdentifier":"com.google.Chrome","playing":false,"processIdentifier":25221,"duration":600,"playbackRate":0,"album":""}"#
        let expected = NowPlayingSession(processIdentifier: 25221, bundleIdentifier: "com.google.Chrome", title: "NanoWhisper media test", isPlaying: false)
        #expect(MediaRemoteAdapter.parseGetOutput(output(json)) == .session(expected))
    }

    @Test("Title and bundle identifier are optional")
    func optionalFields() {
        let expected = NowPlayingSession(processIdentifier: 42, bundleIdentifier: nil, title: nil, isPlaying: true)
        #expect(MediaRemoteAdapter.parseGetOutput(output(#"{"processIdentifier":42,"playing":true}"#)) == .session(expected))
    }

    @Test("A JSON payload with non-fatal warnings on stderr is still used")
    func warningsWithPayload() {
        let out = output(#"{"processIdentifier":42,"playing":false}"#, stderr: "Invalid JSON value type in dictionary for key 'x'\n")
        #expect(MediaRemoteAdapter.parseGetOutput(out) == .session(NowPlayingSession(processIdentifier: 42, bundleIdentifier: nil, title: nil, isPlaying: false)))
    }

    @Test("Anything incomplete or unexpected is a failure", arguments: [
        #"{"processIdentifier":42}"#,                      // no playing state
        #"{"playing":true}"#,                              // no process
        #"{"processIdentifier":0,"playing":true}"#,        // invalid pid
        #"{"processIdentifier":42,"playing":"yes"}"#,      // not a boolean
        #"{"processIdentifier":42,"playing":2}"#,          // not a boolean
        #"{"processIdentifier":99999999999,"playing":true}"#, // pid out of range
        "[]",
        "",
        "Failed to load framework: /x/MediaRemoteAdapter",
    ])
    func unexpectedOutput(stdout: String) {
        #expect(MediaRemoteAdapter.parseGetOutput(output(stdout)) == .failed)
    }

    @Test("A non-zero exit status is a failure, whatever was printed")
    func nonZeroExit() {
        #expect(MediaRemoteAdapter.parseGetOutput(output(#"{"processIdentifier":42,"playing":true}"#, status: 1)) == .failed)
        #expect(MediaRemoteAdapter.parseGetOutput(output("null", status: 1)) == .failed)
    }

    @Test("Failed reading answers unknown, no session answers not playing")
    func playbackStates() {
        #expect(NowPlayingReading.failed.playbackState == .unknown)
        #expect(NowPlayingReading.noSession.playbackState == .notPlaying)
        #expect(NowPlayingReading.session(.vlc).playbackState == .playing)
        #expect(NowPlayingReading.session(.vlc.with(isPlaying: false)).playbackState == .notPlaying)
    }
}

// MARK: - Quarantine

@Suite("mediaremote-adapter quarantine")
struct MediaRemoteAdapterQuarantineTests {

    @Test("Downloaded, unapproved framework is not loaded", arguments: ["0081;6afef9c7;Safari;79ABCCA2-5607-4C26-B9E8-A366C2621769", "0083;6afef9c7;Archive Utility;", "garbage", ""])
    func blocked(value: String) {
        #expect(MediaRemoteAdapter.quarantineBlocksLoading(value))
    }

    @Test("User-approved framework is loaded")
    func approved() {
        #expect(!MediaRemoteAdapter.quarantineBlocksLoading("00c1;6afef9c7;Safari;79ABCCA2-5607-4C26-B9E8-A366C2621769"))
    }

    @Test("Reads the quarantine attribute of a file")
    func readsAttribute() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nanowhisper-qtn-\(UUID().uuidString)")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MediaRemoteAdapter.quarantineValue(of: url) == nil)

        let value = "0081;6afef9c7;Safari;"
        #expect(setxattr(url.path, "com.apple.quarantine", value, value.utf8.count, 0, 0) == 0)
        #expect(MediaRemoteAdapter.quarantineValue(of: url) == value)
    }
}

// MARK: - Resume rule

@Suite("Now Playing resume rule")
struct NowPlayingResumeRuleTests {

    @Test("Resumes the item we paused when it is still paused")
    func samePausedItem() {
        #expect(NowPlayingPlaybackController.shouldResume(paused: .vlc, now: .session(.vlc.with(isPlaying: false))))
    }

    @Test("Does not resume what is already playing again")
    func alreadyPlaying() {
        #expect(!NowPlayingPlaybackController.shouldResume(paused: .vlc, now: .session(.vlc)))
    }

    @Test("Does not resume another app, process or item", arguments: [
        NowPlayingSession.chrome.with(isPlaying: false),
        NowPlayingSession(processIdentifier: 30000, bundleIdentifier: "org.videolan.vlc", title: "quiet.wav", isPlaying: false), // relaunched
        NowPlayingSession.vlc.with(title: "another file").with(isPlaying: false),
        NowPlayingSession.vlc.with(title: nil).with(isPlaying: false),
    ])
    func otherItem(now: NowPlayingSession) {
        #expect(!NowPlayingPlaybackController.shouldResume(paused: .vlc, now: .session(now)))
    }

    @Test("Does not resume when no app owns Now Playing or the state is unreadable")
    func noSessionOrFailure() {
        #expect(!NowPlayingPlaybackController.shouldResume(paused: .vlc, now: .noSession))
        #expect(!NowPlayingPlaybackController.shouldResume(paused: .vlc, now: .failed))
    }
}

// MARK: - Controller

@Suite("NowPlayingPlaybackController")
@MainActor
struct NowPlayingPlaybackControllerTests {

    @Test("Pauses the playing item with an explicit pause and resumes it with an explicit play")
    func pauseThenResume() async {
        let source = FakeNowPlaying(.session(.vlc))
        let controller = NowPlayingPlaybackController(source: source)

        #expect(await controller.playbackState() == .playing)
        await controller.pause()
        #expect(source.sent == [.pause])
        #expect(source.reading == .session(.vlc.with(isPlaying: false)))

        await controller.resume()
        #expect(source.sent == [.pause, .play])
        #expect(source.reading == .session(.vlc))
    }

    @Test("Reports the state without sending anything", arguments: [
        (NowPlayingReading.noSession, MediaPlaybackState.notPlaying),
        (.session(NowPlayingSession.vlc.with(isPlaying: false)), .notPlaying),
        (.failed, .unknown),
    ])
    func states(reading: NowPlayingReading, expected: MediaPlaybackState) async {
        let source = FakeNowPlaying(reading)
        let controller = NowPlayingPlaybackController(source: source)
        #expect(await controller.playbackState() == expected)
        #expect(source.sent.isEmpty)
    }

    @Test("Without the helper, the state is unknown and nothing is sent")
    func noSource() async {
        let controller = NowPlayingPlaybackController(source: nil)
        #expect(await controller.playbackState() == .unknown)
        await controller.pause()
        await controller.resume()
    }

    @Test("Never pauses when the last reading was not playing")
    func pauseWithoutPlaying() async {
        let source = FakeNowPlaying(.session(.vlc.with(isPlaying: false)))
        let controller = NowPlayingPlaybackController(source: source)
        _ = await controller.playbackState()
        await controller.pause()
        await controller.resume()
        #expect(source.sent.isEmpty)
    }

    @Test("Does not resume when another app took over Now Playing")
    func anotherAppTookOver() async {
        let source = FakeNowPlaying(.session(.vlc))
        let controller = NowPlayingPlaybackController(source: source)
        _ = await controller.playbackState()
        await controller.pause()

        source.reading = .session(.chrome)
        await controller.resume()
        #expect(source.sent == [.pause])
    }

    @Test("Does not resume when another tab of the same browser is now shown, paused")
    func anotherTabSameBrowser() async {
        let source = FakeNowPlaying(.session(.chrome))
        let controller = NowPlayingPlaybackController(source: source)
        _ = await controller.playbackState()
        await controller.pause()

        source.reading = .session(NowPlayingSession.chrome.with(title: "Other tab").with(isPlaying: false))
        await controller.resume()
        #expect(source.sent == [.pause])
    }

    @Test("Does not resume when the user already restarted playback")
    func userResumed() async {
        let source = FakeNowPlaying(.session(.vlc))
        let controller = NowPlayingPlaybackController(source: source)
        _ = await controller.playbackState()
        await controller.pause()

        source.reading = .session(.vlc)
        await controller.resume()
        #expect(source.sent == [.pause])
    }

    @Test("Does not resume when the player quit or the state cannot be read", arguments: [NowPlayingReading.noSession, .failed])
    func playerGone(now: NowPlayingReading) async {
        let source = FakeNowPlaying(.session(.vlc))
        let controller = NowPlayingPlaybackController(source: source)
        _ = await controller.playbackState()
        await controller.pause()

        source.reading = now
        await controller.resume()
        #expect(source.sent == [.pause])
    }

    @Test("Resumes at most once per pause, and never without a pause")
    func resumeOnce() async {
        let source = FakeNowPlaying(.session(.vlc.with(isPlaying: false)))
        let controller = NowPlayingPlaybackController(source: source)
        await controller.resume()
        #expect(source.readCount == 0)

        source.reading = .session(.vlc)
        _ = await controller.playbackState()
        await controller.pause()
        await controller.resume()
        source.reading = .session(.vlc.with(isPlaying: false))
        await controller.resume()
        #expect(source.sent == [.pause, .play])
    }

    // MARK: With MediaController

    @Test("Paused media stays paused through a dictation (the toggle key resumed it)")
    func pausedMediaUntouched() async {
        let source = FakeNowPlaying(.session(.vlc.with(isPlaying: false)))
        let media = MediaController(playback: NowPlayingPlaybackController(source: source))

        let session = media.beginSession(pauseMedia: true)
        await media.waitUntilIdle()
        media.endSession(session)
        await media.waitUntilIdle()

        #expect(source.sent.isEmpty)
        #expect(source.reading == .session(.vlc.with(isPlaying: false)))
    }

    @Test("Nothing playing anywhere: no command is sent (the toggle key launched Music)")
    func nothingPlaying() async {
        let source = FakeNowPlaying(.noSession)
        let media = MediaController(playback: NowPlayingPlaybackController(source: source))

        let session = media.beginSession(pauseMedia: true)
        await media.waitUntilIdle()
        media.endSession(session)
        await media.waitUntilIdle()

        #expect(source.sent.isEmpty)
    }

    @Test("Full dictation: pauses, then resumes the same item")
    func fullDictation() async {
        let source = FakeNowPlaying(.session(.chrome))
        let media = MediaController(playback: NowPlayingPlaybackController(source: source))

        let session = media.beginSession(pauseMedia: true)
        await media.waitUntilIdle()
        #expect(source.reading == .session(.chrome.with(isPlaying: false)))

        media.endSession(session)
        await media.waitUntilIdle()
        #expect(source.sent == [.pause, .play])
        #expect(source.reading == .session(.chrome))
    }
}

// MARK: - Subprocess

@Suite("Subprocess")
struct SubprocessTests {

    @Test("Captures exit status, stdout and stderr")
    func capturesOutput() async throws {
        let out = try #require(await Subprocess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 5))
        #expect(out.status == 3)
        #expect(String(decoding: out.stdout, as: UTF8.self) == "out\n")
        #expect(out.stderrText == "err")
    }

    @Test("Runs with an empty environment")
    func emptyEnvironment() async throws {
        let out = try #require(await Subprocess.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: [], timeout: 5))
        #expect(out.status == 0)
        #expect(out.stdout.isEmpty)
    }

    @Test("Kills a hung process and returns nil after the timeout")
    func timeout() async {
        let start = Date()
        let out = await Subprocess.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.2)
        #expect(out == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test("Large output does not dead-lock")
    func largeOutput() async throws {
        let out = try #require(await Subprocess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "head -c 1000000 /dev/zero"], timeout: 5))
        #expect(out.stdout.count == 1_000_000)
    }

    @Test("A missing executable returns nil")
    func missingExecutable() async {
        #expect(await Subprocess.run(URL(fileURLWithPath: "/nonexistent/perl"), arguments: [], timeout: 1) == nil)
    }
}
