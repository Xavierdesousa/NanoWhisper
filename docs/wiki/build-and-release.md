# Build flavors, signing and release

Last verified against the code: 2026-11-19 (`main` at 29e84c9); the SDK version section on
2026-11-21 (`fix/welcome-faster`). Source: PR #14, PR #11, the maintainer, `Makefile`,
`.github/workflows/release.yml`.

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

## The SDK version in the binary (macOS 26+ design)

**Trap (found 2026-11-21):** SwiftPM's default build system in Swift 6.4 (`swiftbuild`, "Swift
Build") links the executable with the **deployment target as the SDK version**:
`otool -l .build/release/NanoWhisper | grep -A4 LC_BUILD_VERSION` showed `minos 14.0, sdk 14.0`
although it compiles against `MacOSX27.0.sdk` (`--build-system native` records `sdk 27.0`; same
result in an empty package, so not this project's settings). AppKit decides from that linked
SDK version whether an app gets the macOS 26+ design, so every app build up to then (production
and debug) ran in the **pre-26 compatibility design**: other window, title bar and toolbar
colors (dark: window `#323232`, toolbar `#373837` tinted by the wallpaper), pre-26 controls,
menus and popovers. Finder, and every test process (the Xcode test runner is linked against the
27 SDK), use the new design: offscreen renders and window tests did not show what the app showed.

- **Fix:** `make build` passes the real SDK version to the linker
  (`-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker $(xcrun --show-sdk-version)`)
  and fails if the executable does not record it. `make app`, `ci`, `release` all go through it.
  Plain `swift build` / `swift test` are unchanged (tests run in the runner's design anyway).
- **Consequences of the switch** (checked in the debug app on macOS 27.2, dark): the Settings
  and onboarding windows get Finder's colors from the system
  ([onboarding-and-settings.md](onboarding-and-settings.md#window-colors)); the menu's native
  titles start 16 pt from the edge, not 14 (`MenuMetrics.textInset` moved); the onboarding
  window's `NSHostingView` resized the window to 672 pt even with `sizingOptions = []` (now
  hosted in a plain container view). The History window, the overlay during a real recording
  and the light appearance in the app were not checked.
- `vtool -set-build-version macos 14.0 27.0 -replace` on a built binary does the same (used to
  confirm the cause on a test harness), but would need re-signing; the linker flag avoids that.

## Two flavors from one executable

`BuildFlavor` (`BuildFlavor.swift`) is resolved at runtime from the bundle identifier only: the
production id means production; anything else, including no bundle (`make run`), means debug.
Everything that could collide is derived from it.

| | Production | Debug |
|---|---|---|
| Bundle | `NanoWhisper.app` | `NanoWhisper Debug.app` |
| Bundle id | `com.moonji.nanowhisper` | `com.moonji.nanowhisper.debug` |
| Executable | `NanoWhisper` | `NanoWhisperDebug` (≤ 16 chars, so `pkill -x` matches exactly) |
| Built by | release workflow, `make ci` / `release` / `notarize` / `publish` | `make app`, `make onboarding`, `make handoff`, `make run` (unbundled) |
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

### Models: at every version bump

Rules (maintainer, 2026-11-20): a model stays in the app while it is still downloadable
upstream (exception: deliberate curation, e.g. Whisper Tiny and Large v3); obsolete models are
removed from disk automatically; migrations to the recommended model are automatic and smooth;
still-selectable models are never deleted automatically. Details:
[transcription-engines.md](transcription-engines.md#model-migrations-modelmigrationsswift).

1. **Review upstream** (FluidAudio releases and `AsrModelVersion`, WhisperKit's model-support
   config, the Hugging Face repos): new models, retired ones, changed folder names.
2. **Recommended model changed?** Append one `ModelMigrationStep` to `ModelMigrations.steps` with a
   new `id` and the target for that engine (`parakeet:` / `whisper:`; leave the other engine
   out). Any other model of that engine moves to the target, including users who went back to an
   older model after a previous step. Never edit or reorder a shipped step. Add a test in
   `ModelMigrationTests`.
3. **Update the "Recommended" flags** (`ParakeetVariant.isRecommended`,
   `WhisperModelSize.isRecommended`) and, for Parakeet, `ParakeetVariant.newInstallDefault`.
4. **A model became obsolete** (gone upstream, or curated out)? Declare its replacement
   (`WhisperModelSize.replacement`; Parakeet has none yet), keep the case so stored values decode,
   and mark its folder `isObsolete: true` in `ModelFolder.all`. New folder names NanoWhisper
   downloads go into `ModelFolder.all` too (the deletion allow-list); never remove a name.
5. Update the README's Models section and this wiki.

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
