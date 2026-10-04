#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/pulse-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/pulse-swift-cache"
build_dir="${TMPDIR:-/tmp}/pulse-release-build"
swift build -c release --disable-sandbox --scratch-path "$build_dir"
app="$PWD/dist/Nori.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build_dir/release/Nori" "$app/Contents/MacOS/Nori"
swift scripts/draw-icon.swift Assets/NoriIcon.png
iconset="$build_dir/Nori.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/NoriIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Assets/NoriIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
python3 scripts/package-icon.py "$iconset" "$app/Contents/Resources/Nori.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Nori</string>
<key>CFBundleIdentifier</key><string>local.mk.nori</string>
<key>CFBundleName</key><string>Nori</string>
<key>CFBundleIconFile</key><string>Nori.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.0</string>
<key>CFBundleVersion</key><string>8</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
print "Built $app"
