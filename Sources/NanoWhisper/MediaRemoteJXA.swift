import Foundation
import os

/// `NowPlayingSource` that reaches the private MediaRemote framework through
/// `osascript -l JavaScript` (JXA).
///
/// Since macOS 15.4 only Apple-signed processes may use MediaRemote; `osascript` is one. The
/// script is passed inline, so no code ships in the bundle (nothing to build, sign, notarize, or
/// for Gatekeeper to assess). Reading through `MRNowPlayingRequest` follows Stephen Kaplan's
/// published snippet (gist SKaplanOfficial/f9f5bdd6455436203d0d318c078358de); pause / play
/// through `MRMediaRemoteSendCommand` is ours.
///
/// - `get` prints one JSON line on stdout: `null` (no app owns Now Playing) or
///   `{"processIdentifier","bundleIdentifier","title","playing"}`.
/// - `send 0|1 PID` sends play (0) or pause (1) only if app PID still owns Now Playing and is
///   in the opposite state, then prints `sent`; otherwise prints `skipped`. Checking inside the
///   same process shrinks the window in which the player could quit between our read and the
///   command (a play with no Now Playing app launches Music).
/// - Anything unexpected (a missing class, selector or symbol on another macOS version, a
///   value of the wrong type) throws: osascript exits 1 and the answer is `.unknown`.
///
/// An osascript that exits right after sending drops the command, so after `sent` the script
/// stays alive until the player's state reflects it (20-80 ms measured, at most 1 s). `send`
/// returns as soon as `sent` is printed; the process finishes in the background, is reaped,
/// and is killed after `timeout`. The next call waits for it first, so a read never misses
/// the effect of the previous command.
actor MediaRemoteJXA: NowPlayingSource {
    static let osascriptURL = URL(fileURLWithPath: "/usr/bin/osascript")
    private static let logger = Logger(subsystem: "com.moonji.nanowhisper", category: "NowPlaying")

    let timeout: TimeInterval
    /// The last `send`, possibly still confirming delivery.
    private var pendingSend: BackgroundProcess?

    init(timeout: TimeInterval = 3) {
        self.timeout = timeout
    }

    func read() async -> NowPlayingReading {
        await settlePendingSend()
        guard let output = await Subprocess.run(Self.osascriptURL, arguments: Self.arguments("get"), timeout: timeout) else {
            Self.logger.error("get: osascript did not start or timed out")
            return .failed
        }
        let reading = Self.parse(output)
        if reading == .failed {
            Self.logger.error("get failed: status \(output.status), stderr: \(output.stderrText, privacy: .public)")
        }
        return reading
    }

    @discardableResult
    func send(_ command: NowPlayingCommand, to session: NowPlayingSession) async -> Bool {
        await settlePendingSend()
        let (line, process) = await Subprocess.start(
            Self.osascriptURL,
            arguments: Self.arguments("send", String(command.rawValue), String(session.processIdentifier)),
            lineTimeout: timeout,
            killAfter: timeout
        )
        pendingSend = process
        let sent = Self.isSent(line)
        if !sent {
            Self.logger.notice("send \(command.rawValue) not sent: \(line ?? "no output", privacy: .public)")
        }
        return sent
    }

    /// Waits (at most `timeout`) for the previous send to finish delivering its command.
    private func settlePendingSend() async {
        guard let process = pendingSend else { return }
        pendingSend = nil
        _ = await process.waitForExit(timeout: timeout)
    }

    // MARK: - Script I/O

    /// The script travels as one argument (no shell), so it needs no quoting.
    static func arguments(_ arguments: String...) -> [String] {
        ["-l", "JavaScript", "-e", script] + arguments
    }

    /// First stdout line of `send`: only `sent` means the command was issued.
    static func isSent(_ line: String?) -> Bool {
        line == "sent"
    }

    /// Parses the output of `get`. Anything but a clean exit with one expected JSON line on
    /// stdout and nothing on stderr is a failure.
    static func parse(_ output: SubprocessOutput) -> NowPlayingReading {
        guard output.status == 0, output.stderr.isEmpty else { return .failed }
        let text = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "null" { return .noSession }
        // Numeric bridging is exact: `playing` must be a boolean, the pid must fit in Int32.
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let playing = object["playing"] as? Bool,
              let pid = object["processIdentifier"] as? Int32,
              pid > 0
        else { return .failed }

        return .session(NowPlayingSession(
            processIdentifier: pid,
            bundleIdentifier: object["bundleIdentifier"] as? String,
            title: object["title"] as? String,
            isPlaying: playing
        ))
    }

    static let script = #"""
    ObjC.import('Foundation');
    ObjC.import('AppKit');

    // JXA returns undefined for a selector that does not exist: fail instead of guessing.
    function need(value, what) {
        if (value === undefined || value === null) throw new Error('missing ' + what);
        return value;
    }

    function out(text) {
        $.NSFileHandle.fileHandleWithStandardOutput.writeData($(text + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
    }

    // { pid, playing } of the app owning Now Playing; pid 0 when there is none.
    function nowPlaying(request) {
        const path = need(request.localNowPlayingPlayerPath, 'localNowPlayingPlayerPath');
        const client = path.isNil() ? null : need(path.client, 'client');
        const pid = (client === null || client.isNil()) ? 0 : client.processIdentifier;
        if (typeof pid !== 'number' || !Number.isInteger(pid) || pid < 0) throw new Error('unexpected pid');
        const playing = request.localIsPlaying;
        if (typeof playing !== 'boolean') throw new Error('unexpected playing state');
        return { pid: pid, playing: playing };
    }

    function run(argv) {
        const bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
        if (bundle.isNil() || bundle.load !== true) throw new Error('MediaRemote not loaded');
        const request = $.NSClassFromString('MRNowPlayingRequest');
        if (request.isNil()) throw new Error('MRNowPlayingRequest missing');

        if (argv.length === 1 && argv[0] === 'get') {
            const state = nowPlaying(request);
            if (state.pid === 0) { out('null'); return; }
            const result = { processIdentifier: state.pid, playing: state.playing };
            const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(state.pid);
            if (!app.isNil() && !app.bundleIdentifier.isNil()) result.bundleIdentifier = ObjC.unwrap(app.bundleIdentifier);
            const item = need(request.localNowPlayingItem, 'localNowPlayingItem');
            const info = item.isNil() ? null : need(item.nowPlayingInfo, 'nowPlayingInfo');
            if (info !== null && !info.isNil()) {
                const title = info.objectForKey('kMRMediaRemoteNowPlayingInfoTitle');
                if (!title.isNil()) {
                    const text = ObjC.unwrap(title);
                    if (typeof text === 'string') result.title = text;
                }
            }
            out(JSON.stringify(result));
            return;
        }

        if (argv.length === 3 && argv[0] === 'send' && (argv[1] === '0' || argv[1] === '1') && /^[1-9][0-9]*$/.test(argv[2])) {
            const play = argv[1] === '0'; // kMRPlay = 0, kMRPause = 1; never the toggle (2)
            const state = nowPlaying(request);
            if (state.pid !== Number(argv[2]) || state.playing === play) { out('skipped'); return; }
            ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
            if ($.MRMediaRemoteSendCommand(play ? 0 : 1, $()) !== true) { out('not-sent'); return; }
            out('sent');
            for (let i = 0; i < 100 && request.localIsPlaying !== play; i++) {
                $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.01));
            }
            return;
        }

        throw new Error('unsupported arguments');
    }
    """#
}
