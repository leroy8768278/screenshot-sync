#!/bin/zsh
set -eu

mac_dir=${0:A:h}
configuration=${CONFIGURATION:-release}
output_dir=${1:-"$mac_dir/dist"}
mkdir -p "$output_dir"
output_dir=${output_dir:A}
app="$output_dir/即图.app"

signing_identity=${SIGNING_IDENTITY:-}
if [[ -z "$signing_identity" ]]; then
  # security may list revoked certificates with a status after the quoted name.
  signing_identity=$(security find-identity -v -p codesigning |
    awk '/"Apple Development: .*"[[:space:]]*$/ { print $2 }')
  if [[ "$signing_identity" == *$'\n'* ]]; then
    print -u2 "找到多个可用的 Apple Development 签名身份。请通过 SIGNING_IDENTITY 指定用于即图的证书。"
    exit 1
  elif [[ -z "$signing_identity" ]]; then
    print -u2 "未找到 Apple Development 签名身份，将使用临时签名。更新后可能需要重新授权屏幕录制。"
    signing_identity=-
  fi
fi

swift build --package-path "$mac_dir" -c "$configuration"
bin_dir=$(swift build --package-path "$mac_dir" -c "$configuration" --show-bin-path)
stage=$(mktemp -d "$output_dir/.package.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
package="$stage/即图.app"
mkdir -p "$package/Contents/MacOS" "$package/Contents/Resources"
install -m 755 "$bin_dir/ScreenshotSyncMac" "$package/Contents/MacOS/ScreenshotSyncMac"
install -m 644 "$mac_dir/Info.plist" "$package/Contents/Info.plist"
install -m 644 "$mac_dir/Resources/AppIcon.icns" "$package/Contents/Resources/AppIcon.icns"
for strings in "$mac_dir"/Resources/*.lproj/InfoPlist.strings; do
  localization=${strings:h:t}
  install -d "$package/Contents/Resources/$localization"
  install -m 644 "$strings" "$package/Contents/Resources/$localization/InfoPlist.strings"
done
codesign --force --sign "$signing_identity" "$package"
codesign --verify --strict "$package"

if [[ -z "${SIGNING_IDENTITY:-}" && -d "$app" ]] && codesign -dvv "$app" 2>&1 | grep -q '^Authority='; then
  old_requirement=$(codesign -d -r- "$app" 2>/dev/null)
  if ! codesign --verify -R="${old_requirement#designated => }" "$package"; then
    print -u2 "新安装包与旧版签名身份不匹配。请用 SIGNING_IDENTITY 指定签名证书。"
    exit 1
  fi
fi

# Publish the verified bundle in one rename. Both paths are on the same volume.
swift - "$package" "$app" <<'SWIFT'
import Darwin
let source = CommandLine.arguments[1], destination = CommandLine.arguments[2]
if renamex_np(source, destination, UInt32(RENAME_EXCL)) != 0 {
    guard errno == EEXIST, renamex_np(source, destination, UInt32(RENAME_SWAP)) == 0 else {
        perror("发布即图安装包失败")
        exit(1)
    }
}
SWIFT
printf '%s\n' "$app"
