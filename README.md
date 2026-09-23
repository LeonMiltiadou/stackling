# Stackshot

Screenshots that wait for you.

macOS shows a little thumbnail after a screenshot and then it slides away on its own.
Stackshot replaces that with a stack in the bottom-left corner that stays until you
actually do something with each shot.

![icon](Resources/AppIcon.png)

## How it works

Keep using the normal shortcuts: `⇧⌘3`, `⇧⌘4`, `⇧⌘5` (including screen recordings).
Stackshot watches the folder macOS saves screenshots into, and every new one lands on
the stack. It turns off the native floating thumbnail so you don't get two previews.

| On a card | What it does |
| --- | --- |
| Click | Open in Preview to mark up |
| Drag | Drop the file into any app. The card leaves once dropped. Drag to the Trash to delete. |
| Copy | Copies the image, card leaves. Hold `⌥` to keep it. |
| Text | Copies the text in the screenshot (on-device OCR) |
| `…` | Move to…, Show in Finder, Share, Copy File Path |
| ✕ / 🗑 | Dismiss (file stays) / Move to Trash |

With more than one shot, click **N more** to fan the stack out into a list.
Dismissed shots can be brought back from the menu bar under **Recently Dismissed**.
Clicking the Dock icon starts an area capture. The Dock badge shows how many are waiting.

## Build and install

```sh
scripts/build.sh install   # builds, copies to /Applications, launches
```

Needs Xcode 15+ and macOS 14+. `scripts/make-icon.sh` regenerates the icon.

Set `STACKSHOT_DEBUG=1` to let the stack show up in your own screenshots (it's hidden by default).
