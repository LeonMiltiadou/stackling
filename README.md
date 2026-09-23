# Stackshot

<img src="Resources/AppIcon.png" width="128" align="right" alt="Stackshot icon">

Screenshots that wait for you.

The Mac shows a little thumbnail after a screenshot, then it slides away on its own.
Stackshot swaps that for a stack in the bottom-left corner. Every shot stays there
until you actually do something with it.

## Install

```sh
git clone https://github.com/LeonMiltiadou/stackshot.git
cd stackshot
scripts/build.sh install
```

That builds the app, copies it to `/Applications` and opens it.
Needs macOS 14 or newer and Xcode (or the Xcode command line tools).

The first time it runs, macOS asks if Stackshot can see your Desktop folder.
Say yes, that's where your screenshots land.

## Using it

**Take screenshots the normal way.** Nothing new to learn:

| Shortcut | What it does |
| --- | --- |
| `⇧⌘3` | Whole screen |
| `⇧⌘4` | Drag to pick an area (press Space to grab a window instead) |
| `⇧⌘5` | The full toolbar: screen recording, timer, options |

Each new shot slides into the stack. With more than one, the older ones peek out
behind the newest.

### Things you can do with a card

Hover a card to see its buttons.

| Do this | What happens | Does the card leave? |
| --- | --- | --- |
| **Click** the image | Opens it in Preview so you can draw, crop, add text | No |
| **Drag** it into any app | Drops the file there (Slack, Mail, Figma, Finder…) | Yes |
| Drag it onto the **Trash** in the Dock | Deletes it | Yes |
| **Copy** | Puts the image on your clipboard | Yes (hold `⌥` to keep it) |
| **Text** | Reads the words in the screenshot and copies them | Yes (hold `⌥` to keep it) |
| **✕** (top left) | Hides the card. The file stays on disk | Yes |
| **🗑** (top right) | Moves the file to the Trash | Yes |
| **…** | Move to…, Show in Finder, Open in Preview, Share, Copy File Path | Depends |

### The stack

- **N more** above the stack fans everything out into a scrollable list. The arrow collapses it again.
- **Clear all** hides every card. The files stay where they are.
- Closed one by accident? Menu bar icon → **Recently Dismissed** brings it back.

### Fading

After a few quiet seconds the stack fades so it stays out of your way.
While faded, clicks go straight through it to whatever is underneath.

Move your mouse over the corner and it comes straight back.
It fades again a few seconds after you move away, or after you do something with a card.

Change it from the menu bar icon:

- **Fade When Idle**: after 2, 5 (default), 10 or 30 seconds, or never
- **When Faded**: invisible, 10%, 20% (default) or 50%

### Other bits

- The **Dock badge** shows how many shots are waiting.
- **Clicking the Dock icon** starts an area capture.
- **Right-click the Dock icon** for all the capture options.
- The **menu bar icon** has captures, where screenshots get saved, Open at Login, and the fade settings.

## What it changes on your Mac

Only two things, and it remembers what they were before so it can undo them:

1. **Turns off the Mac's floating thumbnail.** Otherwise you'd see two previews, and the Mac
   holds back saving the file until its thumbnail slides away. You can switch it back on from
   the menu bar (**Show macOS Floating Thumbnail Too**).
2. **Where screenshots are saved**, but only if you pick a new folder from the menu.

If you turn on **Open at Login**, it also adds itself to your Login Items.

## Uninstall (as if it was never there)

From this folder, run:

```sh
scripts/uninstall.sh
```

It does all of this for you:

| Step | What gets undone |
| --- | --- |
| 1 | Quits Stackshot |
| 2 | Removes it from Login Items |
| 3 | Puts the Mac's screenshot settings back to exactly what they were (floating thumbnail and save folder) |
| 4 | Takes it out of the Dock |
| 5 | Deletes `/Applications/Stackshot.app` and its saved settings |
| 6 | Clears the permissions you gave it (Desktop folder, Screen Recording) |

Your screenshots are **never** touched. They stay wherever they were saved.

Then delete this folder if you want the code gone too.

<details>
<summary>Doing it by hand instead</summary>

```sh
# Quit the app (or use Quit from its menu bar icon)
pkill -f Stackshot.app/Contents/MacOS/Stackshot

# Undo login item + screenshot settings (run this before deleting the app)
/Applications/Stackshot.app/Contents/MacOS/Stackshot --uninstall

# If the app is already deleted, just bring the floating thumbnail back
defaults delete com.apple.screencapture show-thumbnail

# Delete the app and its settings, clear permissions
rm -rf /Applications/Stackshot.app
defaults delete com.leonmiltiadou.stackshot
tccutil reset All com.leonmiltiadou.stackshot
```

Then right-click Stackshot in the Dock → Options → Remove from Dock.
</details>

## For development

```sh
scripts/build.sh            # build to build/Stackshot.app
scripts/build.sh install    # build, install to /Applications, relaunch
scripts/make-icon.sh        # redraw the icon
```

The stack hides itself from screenshots so it doesn't end up in your full-screen shots.
To see it while testing, launch with `STACKSHOT_DEBUG=1`:

```sh
STACKSHOT_DEBUG=1 build/Stackshot.app/Contents/MacOS/Stackshot
```

| File | What's in it |
| --- | --- |
| `Watcher.swift` | Watches the screenshot folder and spots new screenshots |
| `Shot.swift` | A screenshot on the stack, and the stack itself |
| `StackView.swift` | Everything you see: cards, buttons, the expanded list |
| `StackPanel.swift` | The floating window in the corner, sizing and fading |
| `DragSurface.swift` | Click and drag handling on each card |
| `Actions.swift` | Copy, grab text, edit, move, share |
| `Prefs.swift` | Reading and restoring the Mac's screenshot settings, plus Stackshot's own settings |
| `AppDelegate.swift` | Menu bar icon, Dock menu, welcome message |
