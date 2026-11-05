#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Build on macOS with Xcode Command Line Tools, or use the GitHub Actions macOS build." >&2
  exit 1
fi
# Build Intel for the 2016 Mac; the binary also runs via Rosetta on Apple Silicon.
export MACOSX_DEPLOYMENT_TARGET=12.0
swift build -c release --arch x86_64
bin_dir=$(swift build -c release --arch x86_64 --show-bin-path)
app="$PWD/dist/TuneUp.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/TuneUp" "$app/Contents/MacOS/TuneUp"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TuneUp</string>
<key>CFBundleIdentifier</key><string>dev.tuneup.mac</string>
<key>CFBundleName</key><string>TuneUp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
file "$app/Contents/MacOS/TuneUp"
ditto -c -k --sequesterRsrc --keepParent "$app" "$PWD/dist/TuneUp-Monterey-Intel.zip"
shasum -a 256 "$PWD/dist/TuneUp-Monterey-Intel.zip" > "$PWD/dist/SHA256SUMS.txt"
echo "Built dist/TuneUp-Monterey-Intel.zip"
