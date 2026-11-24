# Build flavors, signing and release

Last verified against the code: 2026-11-19 (`main` at 29e84c9); the SDK version section on
2026-11-21 (`fix/welcome-faster`); the auto-updater on 2026-11-24 (`fix/updater-hardening`). Source: PR #14, PR #11, the maintainer, `Makefile`,
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
| Live transcription (beta) | offered since 0.1.0, off by default (before: hidden, forced off) | offered (`BuildFlavor.supportsLiveTranscription`, [live-transcription.md](live-transcription.md#in-production-as-a-beta-off-by-default-since-010)) |
| Settings › Advanced › "Open Onboarding" | none (`--onboarding` still works) | offered: replays onboarding from its opening scene, Settings left open (`BuildFlavor.offersOnboardingReplay`, [onboarding-and-settings.md](onboarding-and-settings.md#replay)) |
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

### How a release is cut (the maintainer's flow, 2026-11-23)

1. A PR bumps the version (`chore: bump version to X.Y.Z`): `CFBundleShortVersionString` and
   `CFBundleVersion` (+1) in `Resources/Info.plist`. CI must pass; the maintainer merges.
2. Tag the merged bump on `main` explicitly, not the local checkout's HEAD:
   `git fetch origin && git log -1 --oneline origin/main` (check it is the bump commit), then
   `git tag vX.Y.Z origin/main && git push origin vX.Y.Z` (only when the maintainer asks). The
   release workflow builds, signs, zips and publishes.
3. Test: either a local production release candidate first (`make release` in a separate
   worktree, the production history backed up; the default for big changes), or — the
   maintainer's choice for 0.1.0 — the published GitHub release installed **as an update over the
   running production version** through the in-app updater (keeps the user's settings and
   history; a backup of the production `history.json` is taken before).
4. Release notes are generated by GitHub (`--generate-notes`) for now; a user-facing changelog
   (plain language, images, a short video of the recorder) is planned after 0.1.0.

Version numbers: `0.0.x` were the first releases; **0.1.0** is the redesign (onboarding, Settings,
recorder, History). Patch releases `0.1.x` follow.

### Release channels (planned for 0.1.1, not built yet)

Decision (maintainer, 2026-11-23): two channels, **Stable** (default, everyone) and **Beta**
(opt-in, earlier features, may have bugs). Nightly/Canary builds were judged unnecessary.

- **On GitHub:** a beta is a GitHub release marked **pre-release**, tagged with a SemVer
  pre-release suffix: `v0.1.1-beta.1`, `v0.1.1-beta.2`, then the stable `v0.1.1`. A stable tag
  has no suffix.
- **Stable channel:** the updater keeps asking `GET /repos/{owner}/{repo}/releases/latest`
  (what `AutoUpdater` does today); GitHub's "latest" never returns a pre-release or a draft, so
  stable users never see betas.
- **Beta channel:** the updater lists `GET /repos/{owner}/{repo}/releases` and takes the newest
  release by version, pre-releases included (a stable release newer than the last beta wins too).
  Version comparison must follow SemVer: `0.1.1-beta.2` < `0.1.1` < `0.1.2-beta.1`.
- **Version in the bundle:** `CFBundleShortVersionString` must stay three period-separated
  integers (Apple's rule), so it holds `0.1.1` for every beta of 0.1.1 and the stable; the
  pre-release part (`beta.1`) goes in a separate custom key (e.g. `NWPrereleaseLabel`, empty for
  a stable). The zip name, the release-workflow check (`make -s release-zip-name` must equal
  `NanoWhisper-<tag>.zip`) and the updater's comparison build the full version from both keys
  (`0.1.1-beta.1`). The updater refuses such a version today: `AppVersion` (numbers only) and the
  "bundle version equals the tag's" check (`UpdateInstaller.verify`) have to be extended with it.
- **Workflow:** `release.yml` marks the release as pre-release when the tag contains a `-`
  (`gh release create … --prerelease`).
- **Settings:** Advanced › "Update channel: Stable / Beta" (stored in defaults). Moving from Beta
  back to Stable does not downgrade; the user stays on the beta until a newer stable exists.
- **Auto-update when idle (0.1.1):** download silently, install only when nothing is running
  (no recording, no transcription, no onboarding window), with a setting to turn it off.

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

The release workflow published 0.0.5 and 0.0.6 from tag pushes; `make publish` has not been
used for real (its guards were tested by hand). The current released version is 0.0.6; 0.1.0 is
being cut (2026-11-23).

## Auto-updater

Production only (`BuildFlavor.autoUpdatesEnabled`). `AutoUpdater` asks
`api.github.com/repos/Xavierdesousa/nanowhisper/releases/latest` 5 s after launch and every hour,
and on request installs the release and relaunches. `UpdateRelease.swift` parses the release
(`GitHubRelease`, `AppVersion`, `UpdateOffer`) and holds the messages (`UpdateError`);
`UpdateSignature.swift` holds the accepted signatures; `UpdateInstaller.swift` downloads, verifies
and replaces (`UpdateInstaller`), and relaunches (`Relaunch`). Since the release after 0.1.0.

### What is checked, in order, before the installed app is replaced

1. **The running app** satisfies one of `UpdateSignature.acceptedRequirements`
   (`SecCodeCheckValidity` on the process itself). An ad-hoc or unsigned build, a build signed with
   another certificate, or a bundle whose files changed while it runs cannot update itself; nothing
   is downloaded.
2. **The asset** is the one named exactly `NanoWhisper-v<version>.zip`, at
   `https://github.com/<owner>/<repo>/releases/download/<tag>/<name>`, no port, user, query or
   fragment. Owner and repository are compared without case, as GitHub does: **the API answers with
   the repository's own spelling, `Xavierdesousa/NanoWhisper`**, while the app asks for
   `nanowhisper`.
3. **The download**: at most 100 MB (`UpdateInstaller.Limits`; 0.1.0 is 5.7 MB), status 200,
   redirects over https only (`HTTPSRedirects`). GitHub answers 302 to
   `release-assets.githubusercontent.com` (2026-11-24). That host is not checked: GitHub has renamed
   it several times, and the digest and signature cover the content.
4. **The digest**: the file's SHA-256 equals the asset's `digest` when the API gives one; a `digest`
   that is not `sha256:` and 64 hex digits refuses too.
5. **The archive**: extracted by `/usr/bin/ditto -x -k` (no shell, 120 s at most, stopped when the
   content passes 300 MB; 0.1.0 extracts to 15.8 MB) into a new 0700 directory. Exactly one
   top-level `.app`, which is a directory, and every symbolic link resolves (`realpath`) inside it.
   `ditto` keeps entries named `../x` or `/x` inside the destination and does not write through a
   link (checked on macOS 27.2, and by the tests).
6. **The signature** (`SecStaticCodeCheckValidity`): all architectures, nested code, strict,
   symlinks restricted, app-like bundle only, against the accepted requirements.
7. **The identifier and version**, read from the Info.plist sealed by that signature
   (`SecCodeCopySigningInformation`): production's identifier; the version text equals the tag's;
   strictly newer than the running version. `AppVersion` is numbers separated by periods, compared
   number by number; anything else (`0.1.1-beta.1`) is not a version and is never offered.

The app verified is the app installed: download, extraction and verification happen in one
`itemReplacementDirectory` (0700, on the installed app's volume), then
`FileManager.replaceItemAt` renames that directory over the installed bundle. Checked 2026-11-24 in
a test program: same inode after the replacement on APFS and HFS+; on failure (folder not writable)
the old bundle keeps its inode and content; with `.usingNewMetadataOnly` the old bundle's quarantine
attribute is not copied. The staging directory is removed in every case.

A failure leaves the installed app as it was, with a plain message in Settings › Advanced
(`UpdateError`) and "Could not finish the update: see Settings › Advanced" under the menu's update
line (the menu showed nothing before).

### What a release must look like

Installed versions refuse a release that does not follow this, and their users then have to
download by hand:

- tag `v<version>`, numbers and periods only; `CFBundleShortVersionString` equal to it (the release
  workflow checks both against the zip's name);
- zip made by `make release` (one app at the top level), under 100 MB, 300 MB extracted;
- bundle id `com.moonji.nanowhisper`, signed with the "Moonji Dev" certificate whose SHA-1 is in
  `acceptedRequirements`;
- the repository keeps its owner and name (GitHub redirects the API after a rename, but the download
  address then no longer matches).

### The signing requirement

Pinned text: `identifier "com.moonji.nanowhisper" and certificate root = H"f863580b…b1f4"`, exactly
what `codesign -d -r-` prints for the published 0.0.6 and 0.1.0 (the certificate's O is "Moonji", it
is self-signed, so root and leaf are the same; valid until 2036-03-15). A bundle built with
`make ci SIGN_IDENTITY=` has `cdhash H"…"` instead: an ad-hoc requirement names that one build,
so it can never accept another.

Pinned rather than read from the running app: reading it would need the same fail-closed rule for
ad-hoc builds, and could not express a transition to another certificate. macOS does not need to
trust the certificate: a self-signed root validates on a Mac with no trust settings at all (checked,
macOS 27.2).

### Changing the signing certificate

Planned: from "Moonji Dev" to an Apple Developer ID. A release signed with a certificate that is not
in an installed version's `acceptedRequirements` is refused by it, so the change takes **two
releases**:

1. Get the new requirement from a bundle signed with the new certificate (`codesign -d -r-`); it
   names the team. Do not write it from memory.
2. **Bridge release**: signed with **Moonji Dev**, with both requirements in `acceptedRequirements`.
   Before publishing, check both ways with `codesign --verify --deep --strict -R='<requirement>'`:
   the bridge bundle against the old one, a bundle signed with the new certificate against the new
   one.
3. Keep the bridge as the latest release long enough for most users to install it.
4. **Next release**: signed with the new certificate, still with both requirements.
5. Later, in a release signed with the new certificate, remove the Moonji Dev requirement. Never
   remove the requirement of the certificate that signs the release itself: the running app must
   satisfy one of its own.

**A user who skips the bridge** (updates are offered from `releases/latest` only, so a version older
than the bridge goes straight to the newest release) gets "its signature is not the one NanoWhisper
expects. Download the latest version from …". Their installed app keeps working and keeps saying so;
they download once by hand. Settings, history and models are outside the bundle and stay. Versions
up to 0.1.0 have the previous updater and are not concerned.

Also to expect: macOS attaches Microphone and Accessibility permissions to the designated
requirement, so step 4 may ask for them again (not verified; test it before publishing). Losing or
regenerating the "Moonji Dev" certificate is the same change without the possibility of a bridge:
keep its backup. Whether updates still verify after it expires (2036) was not checked.

### Relaunch

`Relaunch.afterExit` starts `/usr/bin/xargs -0 /usr/bin/open -n` with the app's path in a pipe whose
other end only this process holds: `xargs` runs `open` when the pipe closes, which the process's exit
does. No shell, the path is one literal argument, no fixed delay, and the two instances never
overlap (they share the hotkey, the history and the temporary recordings). Rejected:
`NSWorkspace.openApplication` with `createsNewApplicationInstance` (both run at once for a moment),
a shell with a one-second delay (the previous way; neither is needed). If the relaunch cannot start, the app stays open and says the update is installed.

### Verified and not

- Unit tests: `UpdateTests.swift` (fixtures in `UpdateFixtures.swift`), with ad-hoc signed bundles in
  temporary directories and a stub `URLProtocol`. Ad-hoc bundles satisfy a test requirement; the
  releases' requirement refuses them.
- Harness compiling the app's sources (2026-11-24, macOS 27.2): the real requirement accepts the
  published 0.0.6 and 0.1.0 and refuses a modified copy and an ad-hoc re-signed copy; a temporary copy
  of 0.0.6 was replaced by 0.1.0 downloaded from GitHub through the real redirect, digest and
  signature included; `verifyRunningApp` refuses an ad-hoc process with production's identifier. The
  relaunch was run in a small test app whose path has spaces and `$(…)` and which quits slowly: the
  second instance started 0.1 s after the first ended.
- The dynamic requirement check was confirmed on a running release with `codesign --verify -R=…
  <pid>` (read-only).
- **Not verified:** an update of a real installed release with this code (it can only be tried from
  the first release that contains it to the next one), an install in a folder the user cannot write,
  macOS 14 and 15 ([open-questions.md](open-questions.md)).
