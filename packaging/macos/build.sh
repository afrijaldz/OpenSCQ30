#!/usr/bin/env bash
# Builds build-output/OpenSCQ30.app from the gui binary in build-output. The gui must be built first.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$script_dir/../.."
input_binary="$project_root/build-output/openscq30-gui"
icon_png="$project_root/fastlane/metadata/android/en-US/images/icon.png"
app="$project_root/build-output/OpenSCQ30.app"

version="$(grep -m1 '^version' "$project_root/Cargo.toml" | sed 's/.*"\(.*\)".*/\1/')"

iconset="$(mktemp -d)/OpenSCQ30.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$icon_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$input_binary" "$app/Contents/MacOS/openscq30-gui"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/OpenSCQ30.icns"
sed "s/@VERSION@/$version/g" "$script_dir/Info.plist" > "$app/Contents/Info.plist"

# Ad-hoc signature so Gatekeeper allows running a locally built app
codesign --force --sign - "$app"

rm -rf "$(dirname -- "$iconset")"
echo "Built $app ($version)"
