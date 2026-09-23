#!/bin/zsh
# Builds Stackshot.app. Pass "install" to copy it into /Applications and launch it.
set -e
cd "$(dirname "$0")/.."

swift build -c release
[ -f Resources/AppIcon.icns ] || scripts/make-icon.sh

APP=build/Stackshot.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Stackshot $APP/Contents/MacOS/Stackshot
cp Resources/Info.plist $APP/Contents/Info.plist
cp Resources/AppIcon.icns $APP/Contents/Resources/AppIcon.icns

# Sign with a real identity if there is one, so macOS remembers permissions between builds.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" $APP
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

if [ "$1" = "install" ]; then
  pkill -f "Stackshot.app/Contents/MacOS/Stackshot" 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/Stackshot.app
  cp -R $APP /Applications/
  open /Applications/Stackshot.app
  echo "Installed to /Applications and launched"
fi
