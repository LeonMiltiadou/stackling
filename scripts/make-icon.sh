#!/bin/zsh
# Builds Resources/AppIcon.icns (and AppIcon.png) from scripts/make-icon.swift
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
swift scripts/make-icon.swift "$tmp/icon.png"
set=$tmp/AppIcon.iconset
mkdir -p $set
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/icon.png" --out "$set/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$tmp/icon.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns $set -o Resources/AppIcon.icns
cp "$tmp/icon.png" Resources/AppIcon.png
rm -rf $tmp
echo "Icon written to Resources/AppIcon.icns"
