#!/bin/zsh
# Builds Stackling.app.
#   scripts/build.sh           build to build/Stackling.app
#   scripts/build.sh install   also copy it into /Applications and launch it
#   scripts/build.sh package   build for Apple Silicon + Intel and zip it for sharing
#
# Set VERSION (and optionally BUILD_NUMBER) to stamp a release version into the app.
set -e
cd "$(dirname "$0")/.."

if [ "$1" = "package" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Stackling
else
  swift build -c release
  BIN=.build/release/Stackling
fi
[ -f Resources/AppIcon.icns ] || scripts/make-icon.sh

APP=build/Stackling.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/Stackling
cp Resources/Info.plist $APP/Contents/Info.plist
# Release builds stamp the version from the tag (VERSION=v0.2.0 or 0.2.0) and the CI run number.
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" $APP/Contents/Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" $APP/Contents/Info.plist
fi
cp Resources/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
# Shipped inside the app so Stackling › Uninstall Stackling… works without this folder.
cp scripts/uninstall.sh $APP/Contents/Resources/uninstall.sh

# Signing:
# - SIGN_IDENTITY, when set, always wins (e.g. "Developer ID Application: Your Name (TEAMID)").
# - Builds you share (package) only ever use a Developer ID certificate, the kind that opens cleanly on
#   other Macs. A personal or work "Apple Development" certificate carries your email and team, so it
#   stays off anything you hand to someone else; without a Developer ID the zip is ad-hoc signed.
# - Local builds use any development certificate, so macOS keeps your permissions between builds.
if [ -n "$SIGN_IDENTITY" ]; then
  IDENTITY=$SIGN_IDENTITY
elif [ "$1" = "package" ]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
else
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID/ {print $2; exit}')
fi
if [[ "$IDENTITY" == Developer\ ID* ]]; then
  # Hardened runtime and a secure timestamp are what Apple's notary service requires.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" $APP
else
  codesign --force --sign "${IDENTITY:--}" $APP
fi
if [ -n "$IDENTITY" ]; then echo "Built $APP (signed with a certificate)"; else echo "Built $APP (ad-hoc signed)"; fi

if [ "$1" = "install" ]; then
  pkill -f "Stackling.app/Contents/MacOS/Stackling" 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/Stackling.app
  cp -R $APP /Applications/
  open /Applications/Stackling.app
  echo "Installed to /Applications and launched"
fi

if [ "$1" = "package" ]; then
  rm -f build/Stackling.zip
  ditto -c -k --keepParent $APP build/Stackling.zip
  echo "Packaged build/Stackling.zip ($(du -h build/Stackling.zip | cut -f1)), ready to send"
fi
