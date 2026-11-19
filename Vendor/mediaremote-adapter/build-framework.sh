#!/bin/bash
# Builds MediaRemoteAdapter.framework from the vendored sources with plain clang.
# Equivalent to the upstream CMakeLists.txt framework target (no CMake needed).
#
# Usage: build-framework.sh OUTPUT_DIR
# Produces OUTPUT_DIR/MediaRemoteAdapter.framework (versioned layout, ad-hoc signed;
# `make app` / `make ci` re-sign it with the app).
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="$1"
FW="$OUT/MediaRemoteAdapter.framework"

SOURCES=(
    src/adapter/env.m
    src/adapter/get.m
    src/adapter/globals.m
    src/adapter/keys.m
    src/adapter/now_playing.m
    src/adapter/repeat.m
    src/adapter/seek.m
    src/adapter/send.m
    src/adapter/shuffle.m
    src/adapter/speed.m
    src/adapter/stream.m
    src/adapter/test.m
    src/private/MediaRemote.m
    src/utility/Debounce.m
    src/utility/helpers.m
)

rm -rf "$FW"
mkdir -p "$FW/Versions/A/Resources"

# -fvisibility=default: the Perl script looks the adapter_* symbols up by name.
xcrun clang -dynamiclib -fobjc-arc -fvisibility=default -O2 \
    -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -I "$SRC/include" -I "$SRC/src" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$FW/Versions/A/MediaRemoteAdapter" \
    "${SOURCES[@]/#/$SRC/}"

cat > "$FW/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MediaRemoteAdapter</string>
    <key>CFBundleIdentifier</key>
    <string>com.vandenbe.MediaRemoteAdapter</string>
    <key>CFBundleName</key>
    <string>MediaRemoteAdapter</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
</dict>
</plist>
PLIST
# BSD 3-Clause: binary redistributions carry the license.
cp "$SRC/LICENSE" "$FW/Versions/A/Resources/LICENSE"

ln -s A "$FW/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$FW/Resources"

codesign --force --sign - "$FW"
