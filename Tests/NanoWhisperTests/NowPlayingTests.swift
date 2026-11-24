import Foundation
import Testing
@testable import NanoWhisper

// MARK: - Fake Now Playing session

/// Simulates the system Now Playing session and `MediaRemoteJXA.send`'s guard: a command is
/// issued only if the target item (app, title, unique identifier) owns Now Playing and is not
/// already in the requested state; it then changes that state like a real player would.
@MainActor
private final class FakeNowPlaying: NowPlayingSource {
    var reading: NowPlayingReading
    /// Commands actually issued.
    private(set) var sent: [NowPlayingCommand] = []
    private(set) var readCount = 0
    /// When `false`, issued commands fail (`send` returns false, state unchanged).
    var deliver = true

    init(_ reading: NowPlayingReading) {
        self.reading = reading
    }

    func read() async -> NowPlayingReading {
        readCount += 1
        return reading
    }

    func send(_ command: NowPlayingCommand, to session: NowPlayingSession) async -> Bool {
        guard case .session(let current) = reading,
              current.processIdentifier == session.processIdentifier,
              current.title == session.title,
              current.uniqueIdentifier == session.uniqueIdentifier,
              current.isPlaying != (command == .play),
              deliver
        else { return false }
        sent.append(command)
        reading = .session(current.with(isPlaying: command == .play))
        return true
    }
}

private extension NowPlayingSession {
    static let vlc = NowPlayingSession(processIdentifier: 41313, bundleIdentifier: "org.videolan.vlc", title: "quiet.wav", isPlaying: true)
    static let chrome = NowPlayingSession(processIdentifier: 41652, bundleIdentifier: "com.google.Chrome", title: "NanoWhisper media test", isPlaying: true)

    func with(isPlaying: Bool) -> NowPlayingSession {
        NowPlayingSession(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier, title: title, uniqueIdentifier: uniqueIdentifier, isPlaying: isPlaying)
    }

    func with(title: String?) -> NowPlayingSession {
        NowPlayingSession(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier, title: title, uniqueIdentifier: uniqueIdentifier, isPlaying: isPlaying)
    }

    func with(uniqueIdentifier: String?) -> NowPlayingSession {
        NowPlayingSession(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier, title: title, uniqueIdentifier: uniqueIdentifier, isPlaying: isPlaying)
    }
}

private func output(_ stdout: String, stderr: String = "", status: Int32 = 0) -> SubprocessOutput {
    SubprocessOutput(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
}

// MARK: - Script output

@Suite("JXA script output")
struct MediaRemoteJXAOutputTests {

    @Test("No app owns Now Playing")
    func noSession() {
        #expect(MediaRemoteJXA.parse(output("null\n")) == .noSession)
    }

    @Test("Browser tab paused (real output, Chrome on macOS 27.2)")
    func browserPaused() {
        let json = #"{"processIdentifier":41652,"playing":false,"bundleIdentifier":"com.google.Chrome","title":"NanoWhisper media test"}"#
        #expect(MediaRemoteJXA.parse(output(json + "\n")) == .session(NowPlayingSession.chrome.with(isPlaying: false)))
    }

    @Test("Native player playing (VLC on macOS 27.2)")
    func nativePlaying() {
        let json = #"{"processIdentifier":41313,"playing":true,"bundleIdentifier":"org.videolan.vlc","title":"quiet.wav"}"#
        #expect(MediaRemoteJXA.parse(output(json)) == .session(.vlc))
    }

    @Test("The unique identifier is read when the player publishes one")
    func uniqueIdentifier() {
        let json = #"{"processIdentifier":51000,"playing":true,"bundleIdentifier":"com.apple.Music","title":"Song","uniqueIdentifier":"8143521470562135962"}"#
        let expected = NowPlayingSession(processIdentifier: 51000, bundleIdentifier: "com.apple.Music", title: "Song", uniqueIdentifier: "8143521470562135962", isPlaying: true)
        #expect(MediaRemoteJXA.parse(output(json)) == .session(expected))
    }

    @Test("Title and bundle identifier are optional")
    func optionalFields() {
        let expected = NowPlayingSession(processIdentifier: 42, bundleIdentifier: nil, title: nil, isPlaying: true)
        #expect(MediaRemoteJXA.parse(output(#"{"processIdentifier":42,"playing":true}"#)) == .session(expected))
    }

    @Test("Script error (real output: osascript exits 1)")
    func scriptError() {
        let out = output("", stderr: "execution error: Error: Error: unsupported arguments (-2700)", status: 1)
        #expect(MediaRemoteJXA.parse(out) == .failed)
    }

    @Test("Anything on stderr is a failure, even with valid stdout")
    func stderrFails() {
        #expect(MediaRemoteJXA.parse(output("null", stderr: "warning")) == .failed)
        #expect(MediaRemoteJXA.parse(output(#"{"processIdentifier":42,"playing":true}"#, stderr: "warning")) == .failed)
    }

    @Test("A non-zero exit status is a failure, whatever was printed")
    func nonZeroExit() {
        #expect(MediaRemoteJXA.parse(output(#"{"processIdentifier":42,"playing":true}"#, status: 1)) == .failed)
        #expect(MediaRemoteJXA.parse(output("null", status: 1)) == .failed)
    }

    @Test("Anything incomplete or unexpected is a failure", arguments: [
        #"{"processIdentifier":42}"#,                          // no playing state
        #"{"playing":true}"#,                                  // no process
        #"{"processIdentifier":0,"playing":true}"#,            // invalid pid
        #"{"processIdentifier":-1,"playing":false}"#,          // invalid pid
        #"{"processIdentifier":42,"playing":"yes"}"#,          // not a boolean
        #"{"processIdentifier":42,"playing":2}"#,              // not a boolean
        #"{"processIdentifier":99999999999,"playing":true}"#,  // pid out of range
        #"{"processIdentifier":"42","playing":true}"#,         // pid not a number
        "[]",
        "",
        "undefined",
        "skipped",
        "null\nnull",
    ])
    func unexpectedOutput(stdout: String) {
        #expect(MediaRemoteJXA.parse(output(stdout)) == .failed)
    }

    @Test("Failed reading answers unknown, no session answers not playing")
    func playbackStates() {
        #expect(NowPlayingReading.failed.playbackState == .unknown)
        #expect(NowPlayingReading.noSession.playbackState == .notPlaying)
        #expect(NowPlayingReading.session(.vlc).playbackState == .playing)
        #expect(NowPlayingReading.session(.vlc.with(isPlaying: false)).playbackState == .notPlaying)
    }

    @Test("A command counts as issued only when the script prints `sent`", arguments: [
        ("sent", true), ("skipped", false), ("not-sent", false), ("", false), ("execution error", false),
    ])
    func sentLine(line: String, expected: Bool) {
        #expect(MediaRemoteJXA.isSent(line) == expected)
    }

    @Test("No output at all is not sent")
    func noLine() {
        #expect(!MediaRemoteJXA.isSent(nil))
    }

    @Test("Arguments: inline script, explicit play (0) / pause (1), the process; the item is on standard input")
    func arguments() {
        #expect(MediaRemoteJXA.arguments("get") == ["-l", "JavaScript", "-e", MediaRemoteJXA.script, "get"])
        let arguments = ["-l", "JavaScript", "-e", MediaRemoteJXA.script]
        #expect(MediaRemoteJXA.sendArguments(.pause, to: .vlc) == arguments + ["send", "1", "41313"])
        #expect(MediaRemoteJXA.sendInput(for: .vlc) == Data("some:cXVpZXQud2F2\nnone\n".utf8))
        let identified = NowPlayingSession.vlc.with(title: nil).with(uniqueIdentifier: "42")
        #expect(MediaRemoteJXA.sendArguments(.play, to: identified) == arguments + ["send", "0", "41313"])
        #expect(MediaRemoteJXA.sendInput(for: identified) == Data("none\nsome:NDI=\n".utf8))
        #expect(NowPlayingCommand.play.rawValue == 0)
        #expect(NowPlayingCommand.pause.rawValue == 1)
    }

    @Test("Identity lines: no title and a title reading \"none\" stay distinct")
    func identityLines() {
        #expect(MediaRemoteJXA.identityLine(nil) == "none")
        #expect(MediaRemoteJXA.identityLine("none") == "some:bm9uZQ==")
        #expect(MediaRemoteJXA.identityLine("") == "some:")
    }

    @Test("Identity lines carry the exact UTF-8 on one ASCII line")
    func identityLinesExactBytes() throws {
        let title = "Ça \"quoted\" it's $HOME; `x` \\n — none" // precomposed Ç
        let line = MediaRemoteJXA.identityLine(title)
        let isASCII = line.unicodeScalars.allSatisfy { $0.isASCII }
        #expect(isASCII)
        let encoded = try #require(line.split(separator: ":", maxSplits: 1).last)
        let bytes = try #require(Data(base64Encoded: String(encoded)))
        #expect(bytes == Data(title.utf8))
        #expect(bytes.prefix(2) == Data([0xC3, 0x87])) // Ç stays U+00C7, not C + U+0327
    }

    @Test("The script refuses the toggle and checks the target item before sending")
    func scriptGuards() {
        let script = MediaRemoteJXA.script
        #expect(script.contains("(argv[1] === '0' || argv[1] === '1')"))
        #expect(script.contains("state.pid !== Number(argv[2]) || state.playing === play"))
        #expect(script.contains("item.title !== expected.title || item.uniqueIdentifier !== expected.uniqueIdentifier"))
        #expect(!script.contains("'2'"))
    }

    @Test("The script reads the expected item before the state it checks")
    func scriptReadsInputFirst() throws {
        let send = try #require(MediaRemoteJXA.script.range(of: "argv[0] === 'send'")).upperBound
        let body = MediaRemoteJXA.script[send...]
        let input = try #require(body.range(of: "readIdentity()"))
        let state = try #require(body.range(of: "nowPlaying(request)"))
        #expect(input.upperBound < state.lowerBound)
    }

    @Test("A failed read logs its status; stderr, which could quote the title, is private")
    func readFailureLog() async throws {
        let start = Date()
        let secret = "secret-title-\(UUID().uuidString)"
        MediaRemoteJXA.logReadFailure(output("", stderr: secret, status: 173))
        let messages = try await LogCapture.messages(category: "NowPlaying", since: start, until: "status 173")
        #expect(messages.contains { $0.contains("status 173") }, "\(messages)")
        #expect(!messages.contains { $0.contains(secret) })
    }
}

// MARK: - Script input

/// Runs the part of the script that reads standard input in the real `osascript`: no
/// MediaRemote, no player.
@Suite("JXA script input")
struct MediaRemoteJXAInputTests {
    private static let script = MediaRemoteJXA.identityReader + """
    function run(argv) {
        const text = JSON.stringify(readIdentity()) + '\\n';
        $.NSFileHandle.fileHandleWithStandardOutput.writeData($(text).dataUsingEncoding($.NSUTF8StringEncoding));
    }
    """

    private struct Identity: Decodable, Equatable {
        var title: String?
        var uniqueIdentifier: String?
    }

    private func read(_ input: Data, executable: URL = MediaRemoteJXA.osascriptURL, arguments: [String]? = nil) async throws -> Identity? {
        let (line, process) = await Subprocess.start(
            executable, arguments: arguments ?? ["-l", "JavaScript", "-e", Self.script],
            input: input, lineTimeout: 20, killAfter: 20
        )
        _ = await process?.waitForExit(timeout: 20)
        return try line.map { try JSONDecoder().decode(Identity.self, from: Data($0.utf8)) }
    }

    @Test("osascript reads back exactly what was written", arguments: [
        (nil, nil), ("", ""), ("none", nil), (nil, "42"),
        ("Ça \"quoted\" it's $HOME; `x` \\n — none", "8143521470562135962"),
        ("two\nlines\u{0301} 🎧", "some:none"),
    ] as [(String?, String?)])
    func roundTrip(title: String?, identifier: String?) async throws {
        let session = NowPlayingSession.vlc.with(title: title).with(uniqueIdentifier: identifier)
        let result = try #require(try await read(MediaRemoteJXA.sendInput(for: session)))
        // Compared by scalar: the composition of accents must not change.
        #expect(result.title.map { Array($0.unicodeScalars) } == title.map { Array($0.unicodeScalars) })
        #expect(result.uniqueIdentifier.map { Array($0.unicodeScalars) } == identifier.map { Array($0.unicodeScalars) })
    }

    @Test("A title larger than a pipe's buffer is read whole")
    func longTitle() async throws {
        let title = String(repeating: "é", count: 200_000)
        let session = NowPlayingSession.vlc.with(title: title)
        let result = try #require(try await read(MediaRemoteJXA.sendInput(for: session)))
        #expect(result.title == title)
        #expect(result.uniqueIdentifier == nil)
    }

    @Test("Input arriving in pieces, then left open, is enough")
    func pieces() async throws {
        // The input stays open longer than the line is waited for.
        let feed = #"{ printf 'some:QQ='; sleep 0.2; printf '=\nnone\n'; sleep 20; } | /usr/bin/osascript -l JavaScript -e "$1""#
        let (line, _) = await Subprocess.start(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", feed, "sh", Self.script], lineTimeout: 15, killAfter: 16
        )
        #expect(line == #"{"title":"A","uniqueIdentifier":null}"#)
    }

    @Test("Missing or malformed input: the script fails, nothing is printed", arguments: [
        "", "none\n", "none\nnone", "other\nnone\n", "some:***\nnone\n", "\n\n", "some:é\nnone\n",
    ])
    func malformed(input: String) async throws {
        #expect(try await read(Data(input.utf8)) == nil)
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
        NowPlayingSession.vlc.with(uniqueIdentifier: "other track").with(isPlaying: false), // same title, other item
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
        #expect(await controller.pause())
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

    @Test("Never pauses when the last reading was not playing")
    func pauseWithoutPlaying() async {
        let source = FakeNowPlaying(.session(.vlc.with(isPlaying: false)))
        let controller = NowPlayingPlaybackController(source: source)
        _ = await controller.playbackState()
        #expect(await controller.pause() == false)
        await controller.resume()
        #expect(source.sent.isEmpty)
    }

    @Test("A pause that was not issued is never resumed (the user paused in between)")
    func pauseSkipped() async {
        let source = FakeNowPlaying(.session(.vlc))
        let controller = NowPlayingPlaybackController(source: source)
        _ = await controller.playbackState()

        source.reading = .session(.vlc.with(isPlaying: false)) // paused by the user meanwhile
        #expect(await controller.pause() == false)
        await controller.resume()
        #expect(source.sent.isEmpty)
        #expect(source.reading == .session(.vlc.with(isPlaying: false)))
    }

    @Test("A pause that failed is never resumed")
    func pauseFailed() async {
        let source = FakeNowPlaying(.session(.vlc))
        source.deliver = false
        let controller = NowPlayingPlaybackController(source: source)
        _ = await controller.playbackState()
        #expect(await controller.pause() == false)
        source.deliver = true
        source.reading = .session(.vlc.with(isPlaying: false))
        await controller.resume()
        #expect(source.sent.isEmpty)
    }

    @Test("Does not resume when another app took over Now Playing")
    func anotherAppTookOver() async {
        let source = FakeNowPlaying(.session(.vlc))
        let controller = NowPlayingPlaybackController(source: source)
        _ = await controller.playbackState()
        #expect(await controller.pause())

        source.reading = .session(.chrome)
        await controller.resume()
        #expect(source.sent == [.pause])
    }

    @Test("Does not resume when another tab of the same browser is now shown, paused")
    func anotherTabSameBrowser() async {
        let source = FakeNowPlaying(.session(.chrome))
        let controller = NowPlayingPlaybackController(source: source)
        _ = await controller.playbackState()
        #expect(await controller.pause())

        source.reading = .session(NowPlayingSession.chrome.with(title: "Other tab").with(isPlaying: false))
        await controller.resume()
        #expect(source.sent == [.pause])
    }

    @Test("Does not resume when the user already restarted playback")
    func userResumed() async {
        let source = FakeNowPlaying(.session(.vlc))
        let controller = NowPlayingPlaybackController(source: source)
        _ = await controller.playbackState()
        #expect(await controller.pause())

        source.reading = .session(.vlc)
        await controller.resume()
        #expect(source.sent == [.pause])
    }

    @Test("Does not resume when the player quit or the state cannot be read", arguments: [NowPlayingReading.noSession, .failed])
    func playerGone(now: NowPlayingReading) async {
        let source = FakeNowPlaying(.session(.vlc))
        let controller = NowPlayingPlaybackController(source: source)
        _ = await controller.playbackState()
        #expect(await controller.pause())

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
        #expect(await controller.pause())
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
    private static let sh = URL(fileURLWithPath: "/bin/sh")

    /// No such process, not even a zombie: it exited and was reaped.
    private static func isGone(_ pid: Int32) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    @Test("Captures exit status, stdout and stderr")
    func capturesOutput() async throws {
        let out = try #require(await Subprocess.run(Self.sh, arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 5))
        #expect(out.status == 3)
        #expect(String(decoding: out.stdout, as: UTF8.self) == "out\n")
        #expect(out.stderrText == "err")
    }

    @Test("Passes arguments verbatim, without a shell")
    func verbatimArguments() async throws {
        let tricky = #"it's "quoted" $HOME `x` ; \n"#
        let out = try #require(await Subprocess.run(URL(fileURLWithPath: "/bin/echo"), arguments: [tricky], timeout: 5))
        #expect(String(decoding: out.stdout, as: UTF8.self) == tricky + "\n")
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
        let out = await Subprocess.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["120"], timeout: 0.2)
        #expect(out == nil)
        // Killed, not waited for. The time also counts the wait for a free dispatch thread: several
        // seconds on a CI runner that runs the whole suite in parallel (2.7 s on 2026-11-24).
        #expect(Date().timeIntervalSince(start) < 60)
    }

    @Test("Large output does not dead-lock")
    func largeOutput() async throws {
        let out = try #require(await Subprocess.run(Self.sh, arguments: ["-c", "head -c 1000000 /dev/zero"], timeout: 5))
        #expect(out.stdout.count == 1_000_000)
    }

    @Test("A missing executable returns nil")
    func missingExecutable() async {
        #expect(await Subprocess.run(URL(fileURLWithPath: "/nonexistent/osascript"), arguments: [], timeout: 1) == nil)
    }

    // MARK: Background start (JXA send)

    @Test("Returns the first line without waiting for the process, then reaps it when it exits")
    func firstLineThenReaped() async throws {
        // The child prints its line, then blocks until the test creates `gate`: no timing.
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("nanowhisper-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: gate) }
        let script = #"echo sent; while [ ! -e "$1" ]; do sleep 0.01; done; echo done"#
        let (line, process) = await Subprocess.start(Self.sh, arguments: ["-c", script, "sh", gate.path], lineTimeout: 30, killAfter: 60)
        #expect(line == "sent")
        let running = try #require(process)
        let pid = running.processIdentifier
        #expect(!Self.isGone(pid), "start() returned while the process still runs")

        try Data().write(to: gate)
        #expect(await running.waitForExit(timeout: 30))
        #expect(Self.isGone(pid))
    }

    @Test("A hung process is killed after killAfter and reaped")
    func hungProcessKilled() async throws {
        let (line, process) = await Subprocess.start(Self.sh, arguments: ["-c", "echo sent; exec sleep 30"], lineTimeout: 5, killAfter: 0.3)
        #expect(line == "sent")
        let running = try #require(process)
        #expect(await running.waitForExit(timeout: 3))
        #expect(Self.isGone(running.processIdentifier))
    }

    @Test("No line within the timeout: nil, and the process is killed")
    func noLineKilled() async throws {
        let start = Date()
        let (line, process) = await Subprocess.start(Self.sh, arguments: ["-c", "exec sleep 30"], lineTimeout: 0.2, killAfter: 30)
        #expect(line == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        let running = try #require(process)
        #expect(await running.waitForExit(timeout: 3))
        #expect(Self.isGone(running.processIdentifier))
    }

    @Test("Standard input is delivered, then closed")
    func standardInput() async throws {
        // `cat` ends only at the end of its input; the line then proves it.
        let script = "text=$(cat); echo \"got $text\""
        let (line, process) = await Subprocess.start(Self.sh, arguments: ["-c", script], input: Data("hello".utf8), lineTimeout: 30, killAfter: 30)
        #expect(line == "got hello")
        #expect(await (try #require(process)).waitForExit(timeout: 30))
    }

    @Test("A process that exits without reading a large input neither blocks nor ends the app")
    func unreadInput() async throws {
        let (line, process) = await Subprocess.start(Self.sh, arguments: ["-c", "echo sent"], input: Data(count: 5_000_000), lineTimeout: 30, killAfter: 30)
        #expect(line == "sent")
        #expect(await (try #require(process)).waitForExit(timeout: 30))
        // Time for a write to the dead process to fail (SIGPIPE would end the tests here).
        try await Task.sleep(for: .milliseconds(200))
    }

    @Test("A process that never reads its input is still killed after the line timeout")
    func hungOnInput() async throws {
        let start = Date()
        let (line, process) = await Subprocess.start(Self.sh, arguments: ["-c", "exec sleep 30"], input: Data(count: 5_000_000), lineTimeout: 0.2, killAfter: 30)
        #expect(line == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(await (try #require(process)).waitForExit(timeout: 3))
    }

    @Test("Without input, standard input is empty")
    func noInput() async {
        let (line, _) = await Subprocess.start(Self.sh, arguments: ["-c", "cat; echo end"], lineTimeout: 30, killAfter: 30)
        #expect(line == "end")
    }

    @Test("Exit without output gives nil")
    func exitWithoutLine() async {
        let (line, _) = await Subprocess.start(Self.sh, arguments: ["-c", "exit 1"], lineTimeout: 5, killAfter: 5)
        #expect(line == nil)
    }

    @Test("A missing executable gives no line and no process")
    func startMissingExecutable() async {
        let (line, process) = await Subprocess.start(URL(fileURLWithPath: "/nonexistent/osascript"), arguments: [], lineTimeout: 1, killAfter: 1)
        #expect(line == nil)
        #expect(process == nil)
    }
}
