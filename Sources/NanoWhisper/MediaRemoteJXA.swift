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
///   `{"processIdentifier","bundleIdentifier","title","uniqueIdentifier","playing"}`.
/// - `send 0|1 PID TITLE ID` sends play (0) or pause (1) only if app PID still owns Now Playing,
///   still shows the item with that title and unique identifier (each `none` or `some:BASE64`),
///   and is in the opposite state; it then prints `sent`, otherwise `skipped`. Checking inside
///   the same process shrinks the window in which another item could take over between our
///   read and the command (and a play with no Now Playing app launches Music).
/// - Anything unexpected (a missing class, selector or symbol on another macOS version, a
///   value of the wrong type) throws: osascript exits 1 and the answer is `.unknown`.
///
/// An osascript that exits right after sending drops the command, so after `sent` the script
/// stays alive until the player's state reflects it (20-80 ms measured, at most 1 s). `send`
/// returns as soon as `sent` is printed; the process finishes in the background, is reaped,
/// and is killed after `timeout`. Calls run one at a time, and each first waits for the
/// previous send's process, so a read never misses the effect of the previous command.
actor MediaRemoteJXA: NowPlayingSource {
    static let osascriptURL = URL(fileURLWithPath: "/usr/bin/osascript")
    private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "NowPlaying")

    let timeout: TimeInterval
    /// Actors are reentrant: without it, a call could start while another awaits its process.
    private let gate = SerialGate()
    /// The last `send`, possibly still confirming delivery.
    private var pendingSend: BackgroundProcess?

    init(timeout: TimeInterval = 3) {
        self.timeout = timeout
    }

    func read() async -> NowPlayingReading {
        await gate.acquire()
        let reading = await readNow()
        await gate.release()
        return reading
    }

    @discardableResult
    func send(_ command: NowPlayingCommand, to session: NowPlayingSession) async -> Bool {
        await gate.acquire()
        let sent = await sendNow(command, to: session)
        await gate.release()
        return sent
    }

    /// Must only run while holding `gate`.
    private func readNow() async -> NowPlayingReading {
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

    /// Must only run while holding `gate`.
    private func sendNow(_ command: NowPlayingCommand, to session: NowPlayingSession) async -> Bool {
        await settlePendingSend()
        let (line, process) = await Subprocess.start(
            Self.osascriptURL,
            arguments: Self.sendArguments(command, to: session),
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

    /// Waits (at most `timeout`) for the previous send to finish delivering its command. The
    /// process stays visible until then, and is forgotten only if no newer send replaced it.
    private func settlePendingSend() async {
        guard let process = pendingSend else { return }
        _ = await process.waitForExit(timeout: timeout)
        if pendingSend === process {
            pendingSend = nil
        }
    }

    // MARK: - Script I/O

    /// The script and its arguments travel as separate arguments (no shell): no quoting.
    static func arguments(_ arguments: String...) -> [String] {
        ["-l", "JavaScript", "-e", script] + arguments
    }

    static func sendArguments(_ command: NowPlayingCommand, to session: NowPlayingSession) -> [String] {
        arguments("send", String(command.rawValue), String(session.processIdentifier),
                  identityArgument(session.title), identityArgument(session.uniqueIdentifier))
    }

    /// `none`, or `some:` followed by the value's UTF-8 in base64, so that no title can pass
    /// for "no title". Base64 because `Process` hands arguments over decomposed (NFD, measured
    /// on macOS 27.2): a title with an accent would otherwise never match the one read back.
    static func identityArgument(_ value: String?) -> String {
        value.map { "some:" + Data($0.utf8).base64EncodedString() } ?? "none"
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
            uniqueIdentifier: object["uniqueIdentifier"] as? String,
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

    // { title, uniqueIdentifier } of the Now Playing item, each a string or null.
    function currentItem(request) {
        const result = { title: null, uniqueIdentifier: null };
        const item = need(request.localNowPlayingItem, 'localNowPlayingItem');
        const info = item.isNil() ? null : need(item.nowPlayingInfo, 'nowPlayingInfo');
        if (info === null || info.isNil()) return result;
        const title = info.objectForKey('kMRMediaRemoteNowPlayingInfoTitle');
        if (!title.isNil()) {
            const text = ObjC.unwrap(title);
            if (typeof text === 'string') result.title = text;
        }
        // Number or string depending on the player: its description is exact for both.
        const identifier = info.objectForKey('kMRMediaRemoteNowPlayingInfoUniqueIdentifier');
        if (!identifier.isNil()) {
            const text = ObjC.unwrap(identifier.description);
            if (typeof text === 'string') result.uniqueIdentifier = text;
        }
        return result;
    }

    // `none` -> null, `some:BASE64` -> the UTF-8 string it encodes.
    function identityArgument(text) {
        if (text === 'none') return null;
        if (!text.startsWith('some:')) throw new Error('unsupported arguments');
        const data = $.NSData.alloc.initWithBase64EncodedStringOptions($(text.slice(5)), 0);
        if (data.isNil()) throw new Error('unsupported arguments');
        const string = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
        if (string.isNil()) throw new Error('unsupported arguments');
        return ObjC.unwrap(string);
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
            const item = currentItem(request);
            if (item.title !== null) result.title = item.title;
            if (item.uniqueIdentifier !== null) result.uniqueIdentifier = item.uniqueIdentifier;
            out(JSON.stringify(result));
            return;
        }

        if (argv.length === 5 && argv[0] === 'send' && (argv[1] === '0' || argv[1] === '1') && /^[1-9][0-9]*$/.test(argv[2])) {
            const play = argv[1] === '0'; // kMRPlay = 0, kMRPause = 1; never the toggle (2)
            const expectedTitle = identityArgument(argv[3]);
            const expectedIdentifier = identityArgument(argv[4]);
            const state = nowPlaying(request);
            const item = currentItem(request);
            if (state.pid !== Number(argv[2]) || state.playing === play
                || item.title !== expectedTitle || item.uniqueIdentifier !== expectedIdentifier) {
                out('skipped');
                return;
            }
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
