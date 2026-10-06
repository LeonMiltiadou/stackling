#!/bin/zsh
# Stackling Dev: a hidden copy of Stackling that checks the stack by using it, while you keep working.
#   scripts/dev.sh build          build "Stackling Dev.app" into .build/dev
#   scripts/dev.sh check [dir]    build it, capture, wait, reach for "3 more", and check the stack opened
#
# It has its own bundle id, and a check runs it with its own throwaway home folder, so none of your
# settings, screenshots, clipboard or keys are touched. It never shows a window, a menu bar icon or a
# Dock icon (see DevCopy.swift). The pictures of its stack, drawn in memory, land in dir
# (default .build/dev/check). Never installs anything.
set -e
setopt no_bg_nice
cd "$(dirname "$0")/.."

swift build
BIN="$(swift build --show-bin-path)/Stackling"
APP=".build/dev/Stackling Dev.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Stackling"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "$1" "$APP/Contents/Info.plist" }
plist "Set :CFBundleIdentifier io.github.leonmiltiadou.stackling.dev"
plist "Set :CFBundleName Stackling Dev"
plist "Set :CFBundleDisplayName Stackling Dev"
# Never offered in Open With, and never in the Dock, even for the moment before it starts.
plist "Delete :CFBundleDocumentTypes"
plist "Add :LSBackgroundOnly bool true"
# Ad-hoc only: a personal certificate would carry your name and team.
codesign --force --sign - "$APP" 2>/dev/null
echo "Built $APP"
[ "$1" = "check" ] || exit 0

OUT=${2:-.build/dev/check}
rm -rf "$OUT"
mkdir -p "$OUT"
HOME_DIR=$(mktemp -d -t stackling-dev)
CFFIXED_USER_HOME="$HOME_DIR" "$APP/Contents/MacOS/Stackling" --dev-check "$OUT" &
pid=$!
code=124
for _ in $(seq 1 600); do
  if ! kill -0 $pid 2>/dev/null; then
    wait $pid && code=0 || code=$?
    break
  fi
  sleep 0.1
done
if [ $code = 124 ]; then
  echo "Stackling Dev still running after 60 s; stopping it"
  kill $pid 2>/dev/null
fi
rm -rf "$HOME_DIR"
echo "Pictures of the hidden stack: $OUT"
exit $code
