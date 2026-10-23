#!/bin/zsh
# Regenerates Resources/Orcy/AppIcon.icns from the orca drawing in Sources/Orcy/Snapshot.swift (IconView).
set -euo pipefail
cd "$(dirname "$0")/.."
S=$HOME/Library/Caches/codexy-build
swift build --product Orcy --scratch-path "$S" >/dev/null
OUT=$(mktemp -d)
"$S/debug/Orcy" --icon "$OUT"
iconutil -c icns "$OUT/AppIcon.iconset" -o Resources/Orcy/AppIcon.icns
echo "wrote Resources/Orcy/AppIcon.icns"
