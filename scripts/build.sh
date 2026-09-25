#!/bin/zsh
# Builds Stackshot.app.
#   scripts/build.sh           build to build/Stackshot.app
#   scripts/build.sh install   also copy it into /Applications and launch it
#   scripts/build.sh package   build for Apple Silicon + Intel and zip it for sharing
#
# Set VERSION (and optionally BUILD_NUMBER) to stamp a release version into the app.
set -e
cd "$(dirname "$0")/.."

if [ "$1" = "package" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Stackshot
else
  swift build -c release
  BIN=.build/release/Stackshot
fi
[ -f Resources/AppIcon.icns ] || scripts/make-icon.sh

APP=build/Stackshot.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/Stackshot
cp Resources/Info.plist $APP/Contents/Info.plist
# Release builds stamp the version from the tag (VERSION=v0.2.0 or 0.2.0) and the CI run number.
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" $APP/Contents/Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" $APP/Contents/Info.plist
fi
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

if [ "$1" = "package" ]; then
  rm -f build/Stackshot.zip
  ditto -c -k --keepParent $APP build/Stackshot.zip
  echo "Packaged build/Stackshot.zip ($(du -h build/Stackshot.zip | cut -f1)), ready to send"
fi
