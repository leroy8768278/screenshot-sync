#!/bin/zsh
set -eu

mac_dir=${0:A:h}
configuration=${CONFIGURATION:-release}
output_dir=${1:-"$mac_dir/dist"}
mkdir -p "$output_dir"
output_dir=${output_dir:A}

swift build --package-path "$mac_dir" -c "$configuration"
bin_dir=$(swift build --package-path "$mac_dir" -c "$configuration" --show-bin-path)
app="$output_dir/即图.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin_dir/ScreenshotSyncMac" "$app/Contents/MacOS/ScreenshotSyncMac"
install -m 644 "$mac_dir/Info.plist" "$app/Contents/Info.plist"
install -m 644 "$mac_dir/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
for strings in "$mac_dir"/Resources/*.lproj/InfoPlist.strings; do
  localization=${strings:h:t}
  install -d "$app/Contents/Resources/$localization"
  install -m 644 "$strings" "$app/Contents/Resources/$localization/InfoPlist.strings"
done
codesign --force --sign "${SIGNING_IDENTITY:--}" "$app"
printf '%s\n' "$app"
