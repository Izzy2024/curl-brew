#!/bin/zsh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build="${BUILD_PATH:-/tmp/curlbrew-build}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
swift build --package-path "$root" --arch arm64 --build-path "$build"

binary=""
for candidate in \
  "$build/debug/Curlbrew" \
  "$build/arm64-apple-macosx/debug/Curlbrew" \
  "$build/out/Products/Debug/Curlbrew"
do
  if [[ -x "$candidate" ]]; then
    binary=$candidate
    break
  fi
done
if [[ -z "$binary" ]]; then
  echo "no está el binario de Curlbrew" >&2
  exit 1
fi

arch=$(lipo -archs "$binary")
if [[ "$arch" != "arm64" ]]; then
  echo "el binario es '$arch' y Curlbrew solo publica arm64" >&2
  exit 1
fi

app="$root/Curlbrew.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/Curlbrew"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Curlbrew</string>
  <key>CFBundleIdentifier</key>
  <string>app.curlbrew.macos</string>
  <key>CFBundleName</key>
  <string>Curlbrew</string>
  <key>CFBundleDisplayName</key>
  <string>Curlbrew</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
</dict>
</plist>
EOF

icon_src="$root/Resources/AppIcon.png"
if [[ -f "$icon_src" ]]; then
  work=$(mktemp -d)
  iconset="$work/AppIcon.iconset"
  mkdir -p "$iconset" "$app/Contents/Resources"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_src" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$icon_src" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
  rm -rf "$work"
fi

# Documents stamps FinderInfo onto the bundle; codesign rejects that.
xattr -cr "$app"
codesign --force --sign - "$app"
echo "$app"
