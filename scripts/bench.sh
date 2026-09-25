#!/bin/zsh
# Times Stackling's hot paths (library scan, search, reading text, thumbnails, the ⇧⌘4 freeze)
# on a made-up 2,000-shot library in a temp folder. Nothing appears on screen.
#   scripts/bench.sh
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
swiftc -O -module-name StacklingKit Sources/StacklingKit/*.swift scripts/bench/main.swift -o "$out/bench"
"$out/bench"
rm -rf "$out"
