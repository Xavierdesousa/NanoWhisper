# mediaremote-adapter (vendored)

Source: https://github.com/ungive/mediaremote-adapter (BSD 3-Clause, see `LICENSE`)
Pinned commit: `14eed9389241d06e29f7326c19e9ebc6ec8a5f36` (2026-11-11)

NanoWhisper uses it to read the system Now Playing state and send explicit pause / play
commands (see `Sources/NanoWhisper/NowPlayingPlaybackController.swift`). Since macOS 15.4
only Apple-signed processes may use the private MediaRemote framework, so the adapter runs
inside `/usr/bin/perl`, which loads `MediaRemoteAdapter.framework`.

Vendored as is: `LICENSE`, `bin/`, `include/`, `src/`. Not vendored: CMake files, tooling,
upstream README. `build-framework.sh` is ours; it replaces the CMake framework target.

In the app bundle (`make app` / `make ci`):

- `Contents/Frameworks/MediaRemoteAdapter.framework`, built by `build-framework.sh` (with
  `LICENSE` in its `Resources`), then signed together with the app.
- `Contents/Resources/mediaremote-adapter.pl`, copied from `bin/`.

## Updating

1. Clone upstream and check out the new commit.
2. Replace `LICENSE`, `bin/`, `include/` and `src/` here with upstream's.
3. Compare upstream `CMakeLists.txt` with `build-framework.sh` (source list, frameworks,
   flags) and port any change.
4. Check the `get` output keys and `send` command IDs used by
   `NowPlayingPlaybackController.swift` against upstream's README.
5. Update the pinned commit above, run `make app`, and test pause / resume with a native
   player and a browser tab.
