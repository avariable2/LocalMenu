#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/platform.sh
ensure_native_shell "$PWD/scripts/build-app.sh" "$@"
check_hardware
check_build_tools
swift build -c release --arch arm64
bin_dir="$(swift build -c release --arch arm64 --show-bin-path)"
app="dist/LocalMenu.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/LocalMenu" "$app/Contents/MacOS/LocalMenu"
cp Resources/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp scripts/runtime.sh scripts/platform.sh "$app/Contents/Resources/"
lipo -verify_arch arm64 "$app/Contents/MacOS/LocalMenu"
codesign --force --sign - "$app"
printf 'Application prête : %s/%s\n' "$PWD" "$app"
