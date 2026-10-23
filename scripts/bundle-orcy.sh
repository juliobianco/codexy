#!/bin/zsh
# Builds ~/Applications/Orcy.app (menu bar app for Orca, no Dock icon), ad-hoc signed. Same package as Codexy.
# APP=<path> puts it elsewhere; ARCHS="arm64 x86_64" makes a universal build.
set -euo pipefail
cd "$(dirname "$0")/.."
# Build outside Documents: its file-provider adds xattrs that break codesign.
S=$HOME/Library/Caches/codexy-build
VERSION=$(tr -d "[:space:]" < Resources/Orcy/VERSION)
APP=${APP:-$HOME/Applications/Orcy.app}
if [ -n "${ARCHS:-}" ]; then
  ARCH_FLAGS=(); for a in ${=ARCHS}; do ARCH_FLAGS+=(--arch $a); done
  swift build -c release --product Orcy --scratch-path "$S" "${ARCH_FLAGS[@]}"
  OUT="$S/out/Products/Release"
else
  swift build -c release --product Orcy --scratch-path "$S"
  OUT="$S/release"
fi
rm -rf "$APP"
mkdir -p "$(dirname "$APP")" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/Orcy" "$APP/Contents/MacOS/Orcy"
# SwiftPM resources (skins, pets): <package>_<target>, the package is "Codexy".
cp -R "$OUT/Codexy_Orcy.bundle" "$APP/Contents/Resources/"
cp Resources/Orcy/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.julio.orcy</string>
  <key>CFBundleName</key><string>Orcy</string>
  <key>CFBundleExecutable</key><string>Orcy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSLocationWhenInUseUsageDescription</key><string>Used only to pick the weather for the sky behind the orca.</string>
</dict></plist>
PLIST
codesign --force -s - "$APP"
echo "built $APP"
