#!/bin/zsh
# Removes Stackshot and puts your Mac back the way it was before you installed it.
# Your screenshots themselves are never touched.
APP=/Applications/Stackshot.app
BUNDLE_ID=com.leonmiltiadou.stackshot

echo "Uninstalling Stackshot…"

# 1. Quit it
pkill -f "Stackshot.app/Contents/MacOS/Stackshot" 2>/dev/null && sleep 0.5

# 2. Remove the hidden annotation files Stackshot keeps next to screenshots.
#    (Want to keep your annotations? Use "Save Edits Into Image" on those shots first.)
SHOTS=$(defaults read com.apple.screencapture location 2>/dev/null)
SHOTS=${SHOTS/#\~/$HOME}
for dir in "${SHOTS:-$HOME/Desktop}" "$HOME/Desktop" "$HOME/Pictures/Screenshots" "$HOME/Downloads"; do
  [ -d "$dir" ] && find "$dir" -maxdepth 1 -name '.*.stackshot' -delete 2>/dev/null
done
echo "• Removed Stackshot's hidden annotation files"

# 3. Let the app undo its own changes (login item + macOS screenshot settings).
#    It remembers what those settings were before it first changed them.
if [ -x "$APP/Contents/MacOS/Stackshot" ]; then
  "$APP/Contents/MacOS/Stackshot" --uninstall
else
  # App already gone: at least bring back the native floating thumbnail.
  defaults delete com.apple.screencapture show-thumbnail 2>/dev/null
  echo "• Turned the macOS floating thumbnail back on"
  echo "  (If ⇧⌘4 doesn't work, turn it back on in System Settings → Keyboard → Keyboard Shortcuts → Screenshots.)"
fi

# 4. Take it out of the Dock
if defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "Stackshot.app"; then
  defaults export com.apple.dock - | python3 -c '
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
d["persistent-apps"] = [a for a in d.get("persistent-apps", [])
    if "Stackshot.app" not in a.get("tile-data", {}).get("file-data", {}).get("_CFURLString", "")]
sys.stdout.buffer.write(plistlib.dumps(d))' | defaults import com.apple.dock -
  killall Dock
  echo "• Removed it from the Dock"
fi

# 5. Delete the app and everything it stored
rm -rf "$APP"
defaults delete $BUNDLE_ID 2>/dev/null
rm -rf ~/Library/Caches/$BUNDLE_ID ~/Library/Caches/com.leonmiltiadou.stackshot ~/Library/HTTPStorages/$BUNDLE_ID "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
echo "• Deleted the app and its settings"

# 6. Forget the permissions you gave it (Desktop folder, Screen Recording)
tccutil reset All $BUNDLE_ID >/dev/null 2>&1
echo "• Cleared its privacy permissions"

echo "Done. Stackshot is gone. Your screenshots are still where they were."
