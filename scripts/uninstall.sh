#!/bin/zsh
# Removes Stackling and puts your Mac back the way it was before you installed it.
# Your screenshots themselves are never touched.
APP=/Applications/Stackling.app
BUNDLE_ID=io.github.leonmiltiadou.stackling
# The app used to be called Stackshot. Clean up after that too.
LEGACY_ID=com.leonmiltiadou.stackshot

echo "Uninstalling Stackling…"

# 1. Quit it
pkill -f "Stackling.app/Contents/MacOS/Stackling" 2>/dev/null && sleep 0.5

# 2. Remove the hidden annotation files Stackling keeps next to screenshots.
#    (Want to keep your annotations? Use "Save Edits Into Image" on those shots first.)
SHOTS=$(defaults read com.apple.screencapture location 2>/dev/null)
SHOTS=${SHOTS/#\~/$HOME}
for dir in "${SHOTS:-$HOME/Desktop}" "$HOME/Desktop" "$HOME/Pictures/Screenshots" "$HOME/Downloads"; do
  [ -d "$dir" ] && find "$dir" -maxdepth 1 \( -name '.*.stackling' -o -name '.*.stackshot' \) -delete 2>/dev/null
done
[ -d "$HOME/Pictures/Stackling" ] && find "$HOME/Pictures/Stackling" \( -name '.*.stackling' -o -name '.*.stackshot' \) -delete 2>/dev/null
echo "• Removed Stackling's hidden annotation files"

# 3. Let the app undo its own changes (login item + macOS screenshot settings).
#    It remembers what those settings were before it first changed them.
if [ -x "$APP/Contents/MacOS/Stackling" ]; then
  "$APP/Contents/MacOS/Stackling" --uninstall
else
  # App already gone: at least bring back the native floating thumbnail.
  defaults delete com.apple.screencapture show-thumbnail 2>/dev/null
  echo "• Turned the macOS floating thumbnail back on"
  echo "  (If ⇧⌘4 doesn't work, turn it back on in System Settings → Keyboard → Keyboard Shortcuts → Screenshots.)"
fi

# 4. Take it out of the Dock
if defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "Stackling.app"; then
  defaults export com.apple.dock - | python3 -c '
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
d["persistent-apps"] = [a for a in d.get("persistent-apps", [])
    if "Stackling.app" not in a.get("tile-data", {}).get("file-data", {}).get("_CFURLString", "")]
sys.stdout.buffer.write(plistlib.dumps(d))' | defaults import com.apple.dock -
  killall Dock
  echo "• Removed it from the Dock"
fi

# 5. Delete the app and everything it stored
rm -rf "$APP" /Applications/Stackshot.app
for id in $BUNDLE_ID $LEGACY_ID; do
  defaults delete $id 2>/dev/null
  rm -rf ~/Library/Caches/$id ~/Library/HTTPStorages/$id "$HOME/Library/Saved Application State/$id.savedState"
done
echo "• Deleted the app and its settings"

# 6. Forget the permissions you gave it (Screen Recording, Accessibility, folders)
tccutil reset All $BUNDLE_ID >/dev/null 2>&1
tccutil reset All $LEGACY_ID >/dev/null 2>&1
echo "• Cleared its privacy permissions"

echo "Done. Stackling is gone. Your screenshots are still where they were."
