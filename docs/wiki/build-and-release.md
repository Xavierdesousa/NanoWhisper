# Build flavors, signing and release

Last verified against the code: 2026-11-19 (`main` at 29e84c9). Source: PR #14, PR #11, the
maintainer, `Makefile`, `.github/workflows/release.yml`.

## Distribution decisions

- **GitHub releases only.** Never the Mac App Store.
- Releases are signed with the self-signed **"Moonji Dev"** certificate (`SIGN_IDENTITY`,
  default in the `Makefile`; the release workflow imports it from the
  `SIGNING_CERTIFICATE_BASE64` / `SIGNING_CERTIFICATE_PASSWORD` secrets). Hardened runtime is on
  (`codesign --options runtime`); entitlements: audio input and network client
  (`Resources/NanoWhisper.entitlements`). No app sandbox.
- **Not notarized.** Notarization with a Developer ID is planned "long term", not now. A
  `make notarize` target exists (needs `NOTARY_PROFILE`) but is not used.
  Consequence: anything that would need Gatekeeper's approval on its own (a bundled native
  framework or helper) is a problem on a quarantined first install; see the rejected
  `mediaremote-adapter` in [media-pause.md](media-pause.md).
- Built with the macOS 27 SDK / Swift 6.4 (Xcode 27.1); deployment target macOS 14
  (`Package.swift` `.macOS(.v14)`, `LSMinimumSystemVersion` 14.0). Apple Silicon only.

## Two flavors from one executable

`BuildFlavor` (`BuildFlavor.swift`) is resolved at runtime from the bundle identifier only: the
production id means production; anything else, including no bundle (`make run`), means debug.
Everything that could collide is derived from it.

| | Production | Debug |
|---|---|---|
| Bundle | `NanoWhisper.app` | `NanoWhisper Debug.app` |
| Bundle id | `com.moonji.nanowhisper` | `com.moonji.nanowhisper.debug` |
| Executable | `NanoWhisper` | `NanoWhisperDebug` (≤ 16 chars, so `pkill -x` matches exactly) |
| Built by | release workflow, `make ci` / `release` / `notarize` / `publish` | `make app`, `make onboarding`, `make run` (unbundled) |
| Default hotkey | ⌥Space | ⌃⌥Space (`BuildFlavor.defaultShortcut`; Carbon hotkeys are system-wide) |
| History folder | `Application Support/NanoWhisper` | `Application Support/NanoWhisper Debug` |
| Temp recordings | `nanowhisper_*.wav` | `nanowhisper-debug_*.wav` |
| Auto-updater | on | off (`BuildFlavor.autoUpdatesEnabled`) |
| Live transcription (beta) | not offered: toggle hidden, forced off | offered (`BuildFlavor.supportsLiveTranscription`, [live-transcription.md](live-transcription.md#debug-build-only)) |
| Log subsystem | bundle id | bundle id |
| Markers | none | "DEBUG" icon banner, orange band across the bottom of the menu bar glyph (`MenuBarIcon`, since 2026-11-20; was an orange dot), `v<version> · <commit>` in the menu (`BuildInfo`, Info.plist key `NWGitCommit`) |

Separate automatically because the bundle ids differ: TCC permissions, `UserDefaults`, the login
item (`SMAppService.mainApp`).

**Shared on purpose:** downloaded models (FluidAudio and WhisperKit caches). Hence the `flock`
around the legacy cache migration ([transcription-engines.md](transcription-engines.md#legacy-v3-cache-migration)).

Why the updater is off in debug: it installs the latest GitHub release over the running bundle,
which would turn a debug build into the production app.

The debug Info.plist and icon are generated at build time in `.build/flavors/debug` from the
production ones (`plutil`, `scripts/make-debug-icon.swift`).

### Rules for agents

- `make app` only stops processes named `NanoWhisperDebug`; it never touches production.
- The debug app is a shared resource: when the maintainer is testing in it, do not relaunch or
  quit it and do not edit its defaults. See [`CLAUDE.md`](../../CLAUDE.md#rules).

## Release

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`.
2. Push tag `v<version>`. `.github/workflows/release.yml` (runner `xcode-27`) imports the
   certificate, checks that `make -s release-zip-name` equals `NanoWhisper-<tag>.zip` (fails if
   Info.plist was not bumped), runs `make release`, and creates the GitHub release with generated
   notes. If the release already exists, it only uploads the zip when missing.
3. **Fallback** when the hosted runner is unavailable: `make publish` from a clean checkout. It
   refuses a dirty tree (SwiftPM compiles untracked sources too) and requires tag `v<version>` to
   exist on `origin` at HEAD (lightweight or annotated), then runs `make release` and
   `gh release create … --verify-tag --generate-notes`.

Agents never push tags, create releases or run `make publish` unless asked.

Not yet exercised: the release workflow on GitHub since PR #14 (needs a tag push) and
`make publish` for real (its guards were tested by hand). The current released version is
0.0.4.

## Auto-updater

`AutoUpdater` (`AutoUpdater.swift`), production only: checks
`api.github.com/repos/Xavierdesousa/nanowhisper/releases/latest` 5 s after launch and every hour,
compares versions numerically (`isNewerVersion(_:than:)`), and on request downloads the first
`.zip` asset, unzips it with `/usr/bin/unzip`, swaps the bundle (keeping a backup until the move
succeeds) and relaunches. The updater only needs a `.zip` asset, but the tag must match the
version in Info.plist: otherwise the installed version stays below the tag and the updater keeps
offering the same release (this is what the workflow's name check guards).

Not verified: an update from 0.0.4 to the next release through this path
([open-questions.md](open-questions.md)).
