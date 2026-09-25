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

Screenshots save to **Pictures › Stackshot** rather than the Desktop (see [Your library](#your-library)).
If you'd already picked another folder, Stackshot leaves it alone.

## Sharing it with someone

The easy way is a release. Tag a version and push it:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

GitHub Actions builds it for Apple Silicon and Intel, stamps the version in, and attaches `Stackshot.zip`
to a release on the repo's **Releases** page. Send people that link. No Xcode needed on their side.

To make the zip yourself instead, run `scripts/build.sh package`, which writes `build/Stackshot.zip`.

Either way, on their Mac:

1. Unzip it and drag **Stackshot** into **Applications**
2. Open it. macOS will say it can't check it for malware, because it isn't notarised by Apple. Click **Done**.
3. Go to **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to Stackshot, and confirm
4. Allow Screen Recording when it asks

After that it opens normally. To remove it later, they can follow [Uninstall](#uninstall-as-if-it-was-never-there).

## Using it

### Taking screenshots

| Shortcut | What it does |
| --- | --- |
| `⇧⌘4` | **Area.** Freezes the screen first, so menus and hover states stay put. Shows a pixel loupe with exact coordinates and the colour under your cursor. |
| `⇧⌘8` | **Window.** Hover a window and click it. Adds the soft macOS shadow (hold `⌥` when you click to skip it). |
| `⇧⌘9` | **Full screen**, the one your mouse is on |
| `⇧⌘7` | **Record.** Drag an area, click once for the whole screen, or press `Space` to pick a window. Press `⇧⌘7` again (or **Stop**) to finish. |
| `⇧⌘3` / `⇧⌘5` | The Mac's own tools, unchanged. These land on the stack too. |

While picking an area:

| Key | Does |
| --- | --- |
| Drag | Select the area |
| `⇧` while dragging | Keep it square |
| Hold `Space` while dragging | Move the selection around |
| `Space` before dragging | Switch to picking a window |
| `Esc` | Cancel |

While recording, a small bar at the top shows the time, a **Stop** button and a bin to throw the
recording away. The menu bar icon turns into a red stop button, and a dashed line marks the area.
None of that ends up in the video, and neither does the stack. Pinned screenshots do. No sound is recorded.

Recordings land on the stack like screenshots. Their cards show the length, and **GIF** copies a
looping GIF, handy for Slack or a GitHub issue.

Click a recording (or **Preview**) to open it in a preview window. It plays on a loop, and a
**Video / GIF** switch shows you exactly what the GIF will look like, with its size, before you copy it.
**Trim…** cuts the start or end off, **Save GIF** puts the GIF next to the video (and on the stack),
and **Copy Video** / **Copy GIF** copies it and takes the card off the stack. Clicking a GIF card
opens the same preview.

The first time you use these, macOS asks for **Screen Recording** permission. Turn Stackshot on,
then reopen it. Stackshot uses it to freeze the screen, and nothing ever leaves your Mac.

Each new shot slides into the stack in the bottom-left corner. With more than one, the older ones
peek out behind the newest.

If the stack is in the way, drag it by the ✥ on any card (or by the title bar when it's expanded).
New shots join it wherever it is. Drag it near the corner and it snaps back in.
Once the stack is empty it goes back to the corner.

### Things you can do with a card

Hover a card to see its buttons.

| Do this | What happens | Does the card leave? |
| --- | --- | --- |
| **Click** the image or **Edit** | Opens the editor (see below) | No |
| **Drag** it into any app | Drops the file there (Slack, Mail, Figma, Finder…), edits included | Yes |
| Drag it onto the **Trash** in the Dock | Deletes it | Yes |
| **Copy** | Puts the image on your clipboard, edits included | Yes (hold `⌥` to keep it) |
| **Text** | Reads the words in the screenshot and copies them | Yes (hold `⌥` to keep it) |
| **📌** | Pins it to the screen (see below) | Yes (hold `⌥` to keep it) |
| **✕** (top left) | Hides the card. The file stays on disk | Yes |
| Drag **✥** (top middle) | Moves the whole stack somewhere else, handy when you need to screenshot the bottom-left | No |
| **↙** (next to ✥) | Puts the stack back in the corner. Double-clicking ✥ or dropping it near the corner does the same | No |
| **🗑** (top right) | Moves the file to the Trash | Yes |
| **…** | File Into a folder, Move to…, Show in Finder, Open in Preview, Pin, Save Edits Into Image, Share, Copy File Path | Depends |

A little ✏️ on the card means it has edits.

**Keyboard:** while your mouse is on a card, `⌘C` copies, `Space` or `E` edits (or previews a
recording), `T` copies the text, `P` pins, `G` copies a recording as a GIF, `Esc` dismisses and
`⌘⌫` trashes. These only work while you're pointing at a card and have moved the mouse in the last
few seconds, so a mouse parked in the corner never eats what you type elsewhere.

### The editor

Nine tools, each with a one-letter shortcut:

| Tool | Key | Notes |
| --- | --- | --- |
| Select | `V` | Click to pick, drag to move, `Delete` to remove, arrow keys to nudge (`⇧` for 10px). Double-click text to edit it. |
| Arrow | `A` | `⇧` snaps to 45° |
| Rectangle | `R` | `⇧` for a square |
| Ellipse | `O` | `⇧` for a circle |
| Line | `L` | `⇧` snaps to 45° |
| Pen | `P` | Freehand |
| Text | `T` | Click, type, `Return` to finish |
| Counter | `N` | Click to drop numbered steps: 1, 2, 3… |
| Highlighter | `H` | See-through marker |
| Redact | `X` | Pixelates the area. Exports contain the blocks only, the original pixels are gone. |

- **Colours and sizes** are in the toolbar. `1` `2` `3` switch size. Picking a colour or size with something selected changes that thing.
- Hold `⌘` and drag to move a shape without switching to Select.
- **Beautify** (✨) puts the shot on a gradient background with padding, rounded corners and a shadow. Ready to post.
- `⌘Z` / `⇧⌘Z` undo and redo. `⌘C` copies and closes. `Return` or **Done** keeps your edits and closes.

**Your edits stay editable.** They're saved in a hidden file next to the screenshot
(`.Screenshot … .png.stackshot`), and the original image isn't touched. Reopen it any time and
every arrow is still there to move or delete. Copy, drag, share and pin all use the edited
version automatically. When you want the edits burned in for good, use **Save Edits Into Image**.

### Pinning

A pinned shot floats above every window, handy for copying something from one app into another.

- Drag it anywhere
- Scroll or pinch to resize
- Right-click for Copy, Edit, Actual Size and Opacity
- Double-click or `Esc` to close

### The stack

- **N more** above the stack fans everything out into a scrollable list. The arrow collapses it again.
- **Clear all** hides every card. The files stay where they are.
- Closed one by accident? Menu bar icon → **Recently Dismissed** brings it back.
- The stack survives quitting, restarts and updates. It comes back shrunk, so it doesn't jump out at you.
- Want every new shot on the clipboard straight away? Settings → General → **Copy new shots to the clipboard**.

### Shrinking out of the way

After 2 quiet seconds the stack shrinks into a little box in its corner: the newest shot,
with a badge showing how many are waiting. Click the box to open the stack again.
It stays open while your mouse is over it. A new shot opens it by itself.

While the editor or a recording preview is in front, the stack hides completely so the two
don't overlap. It comes back when you close the window or switch apps.

Change the timing in Settings → General: after 1, 2 (default), 5 or 10 seconds, or never.

### Your library

```
~/Pictures/Stackshot/
    new shots land here, and get tidied away after 7 days
    Archive/2026-09/     where tidied shots go
    Checkout bug/        folders you file shots into: yours, never touched
```

- **File Into** (card **…** menu) moves a shot into a folder and takes it off the stack. **New Folder…** makes one.
- **Tidying** runs on launch and every hour. It only touches screenshots and recordings loose at the top of
  the save folder, and never ones still on the stack. Settings → Library picks 1, 7 (default) or 30 days,
  or never, and whether it archives into monthly folders (default) or moves them to the Trash.
- **Got years of screenshots on your Desktop?** Settings → Library → **Move Desktop Screenshots Into the Library…**
  moves only screenshots and recordings into `Stackshot/From Desktop`, after asking.
- Menu bar → **Open Library** opens the save folder in Finder.

### Other bits

- The **Dock badge** shows how many shots are waiting.
- **Clicking the Dock icon** starts an area capture.
- **Right-click the Dock icon** for all the capture options.
- The **menu bar icon** has captures, the stack, Recently Dismissed, Open Library and **Settings…** (`⌘,`).
- **Settings** has three tabs: General (shrinking, copy on capture, open at login), Library (save folder, tidying)
  and Shortcuts (every key, plus **Use Stackshot for ⇧⌘4**: turn it off to give ⇧⌘4 back to macOS).

## What it changes on your Mac

Stackshot remembers what each of these was before it changed them, so uninstalling puts them back exactly.

| Change | Why | Turn it off |
| --- | --- | --- |
| Turns off the Mac's floating thumbnail | Otherwise you'd get two previews, and the Mac holds back the file until its thumbnail slides away | Settings → General → **Show the macOS floating thumbnail too** |
| Takes over `⇧⌘4` | So area captures get the frozen screen and loupe | Settings → Shortcuts → **Use Stackshot for ⇧⌘4** |
| Adds `⇧⌘7`, `⇧⌘8` and `⇧⌘9` | Recording, window and full-screen capture. Only while Stackshot is running. | Quit Stackshot |
| Hidden `.stackshot` files next to screenshots you edit | Keeps your edits editable | **Save Edits Into Image**, or uninstall |
| Where screenshots are saved | Moves them from the Desktop to Pictures › Stackshot, once, if you were still on the Desktop | Settings → Library → **Choose Folder…** |
| Login Items | Only if you turn on **Open at Login** | Turn it off |

## Uninstall (as if it was never there)

From this folder, run:

```sh
scripts/uninstall.sh
```

It does all of this for you:

| Step | What gets undone |
| --- | --- |
| 1 | Quits Stackshot |
| 2 | Deletes the hidden `.stackshot` edit files |
| 3 | Removes it from Login Items |
| 4 | Puts the Mac's screenshot settings back to exactly what they were (floating thumbnail and save folder) |
| 5 | Gives `⇧⌘4` back to macOS |
| 6 | Takes it out of the Dock |
| 7 | Deletes `/Applications/Stackshot.app`, its settings and caches |
| 8 | Clears the permissions you gave it (Desktop folder, Screen Recording) |

Your screenshots are **never** touched. They stay wherever they were saved.
Edits you haven't saved into the image are lost, so use **Save Edits Into Image** first on any you want to keep.

Then delete this folder if you want the code gone too.

<details>
<summary>Doing it by hand instead</summary>

```sh
# Quit the app (or use Quit from its menu bar icon)
pkill -f Stackshot.app/Contents/MacOS/Stackshot

# Undo login item, screenshot settings and ⇧⌘4 (run this before deleting the app)
/Applications/Stackshot.app/Contents/MacOS/Stackshot --uninstall

# If the app is already deleted, bring the floating thumbnail back, then turn ⇧⌘4 back on in
# System Settings → Keyboard → Keyboard Shortcuts → Screenshots
defaults delete com.apple.screencapture show-thumbnail

# Remove hidden edit files next to your screenshots
find ~/Desktop ~/Pictures/Stackshot -name '.*.stackshot' -delete

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
scripts/build.sh package    # universal build, zipped for sharing
scripts/make-icon.sh        # redraw the icon
```

The stack hides itself from screenshots so it doesn't end up in your full-screen shots.
To see it while testing, launch with `STACKSHOT_DEBUG=1`:

```sh
STACKSHOT_DEBUG=1 build/Stackshot.app/Contents/MacOS/Stackshot
```

| File | What's in it |
| --- | --- |
| `CaptureOverlay.swift` | Frozen-screen capture: area, window, full screen, loupe |
| `Hotkeys.swift` | ⇧⌘4 / ⇧⌘8 / ⇧⌘9, and switching the Mac's own ⇧⌘4 off and back on |
| `Editor.swift` | The annotation editor: canvas, tools, toolbar, beautify panel |
| `Markup.swift` | Annotations, the hidden edits file, and drawing/exporting them |
| `PinWindow.swift` | Floating pinned screenshots |
| `Watcher.swift` | Watches the screenshot folder and spots new screenshots |
| `Shot.swift` | A screenshot on the stack, and the stack itself |
| `StackView.swift` | Everything you see: cards, buttons, the expanded list |
| `StackPanel.swift` | The floating window in the corner, sizing and fading |
| `DragSurface.swift` | Click and drag handling on each card |
| `Actions.swift` | Copy, grab text, edit, pin, flatten, move, share |
| `Prefs.swift` | Reading and restoring the Mac's screenshot settings, plus Stackshot's own settings |
| `AppDelegate.swift` | Menu bar icon, Dock menu, welcome message |
