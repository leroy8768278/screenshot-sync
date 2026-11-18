#!/bin/zsh
set -eu

mac_dir=${0:A:h}
configuration=${CONFIGURATION:-release}
output_dir=${1:-"$mac_dir/dist"}
mkdir -p "$output_dir"
output_dir=${output_dir:A}

swift build --package-path "$mac_dir" -c "$configuration"
bin_dir=$(swift build --package-path "$mac_dir" -c "$configuration" --show-bin-path)
app="$output_dir/截图同步.app"
mkdir -p "$app/Contents/MacOS"
install -m 755 "$bin_dir/ScreenshotSyncMac" "$app/Contents/MacOS/ScreenshotSyncMac"
install -m 644 "$mac_dir/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign "${SIGNING_IDENTITY:--}" "$app"
printf '%s\n' "$app"
