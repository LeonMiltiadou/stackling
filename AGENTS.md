# Stackshot for agents

A macOS menu bar app (Swift, SwiftPM, AppKit + SwiftUI, macOS 14+). Captures land on a floating
stack in the bottom-left corner. `README.md` describes every feature from the user's side; read it
before changing behaviour.

## Build, run, verify

```sh
swift build -c release          # compile check
swift test                      # Swift Testing suite, must stay green
scripts/build.sh install        # build, copy to /Applications, relaunch (restarts the user's app)
scripts/logs.sh 10m [category]  # what the app did; `live` streams
swift scripts/windows.swift     # every Stackshot window: frame, on screen, alpha, desktops
```

A change is done when it builds with no new warnings, `swift test` passes, and you have either a
test covering the logic or log output / an off-screen render showing it working.

## Layout

- `Sources/Stackshot/main.swift` is one line. Everything else is `Sources/StackshotKit`, so tests can
  `@testable import StackshotKit`.
- Seams worth knowing: `ShotStore` (the stack's state) → `StackPanelController` (the floating panel's
  size, shrinking, hiding) → `StackView`/`ShotCard` (SwiftUI). `Actions` is every card action.
  `CaptureController` + `ScreenGrabber` do screenshots, `Recorder` + `RecordingSession` do video.
  `Library` owns the save folder, filing and tidying. `ClaudeCode` runs the user's `claude` CLI headless.
- Shared helpers live in `Files.swift` (capture names, capture tag, cache paths), `Geometry.swift`
  (screens, coordinate flips, overlay windows), `Clipboard.swift`, `KeyCode.swift`. Use them rather
  than re-deriving; the refactor removed three to five copies of each.

## Conventions

- **Logging**: `Log.<category>` (`app`, `stack`, `capture`, `recording`, `library`, `actions`, `keys`,
  `editor`). Messages are `event key=value`, lower-case dotted events, e.g.
  `Log.recording.info("stop seconds=\(s) discarded=\(d)")`. `privacy: .public` on names, paths and
  errors. Levels: debug for chatty state, info for user actions, notice for things the app did by
  itself, error for failures. Every caught error gets a log line, even when the fallback is silent to
  the user.
- **Settings**: every UserDefaults key is in `DefaultsKey`; typed access is `AppSettings`; defaults
  go in `AppSettings.registerDefaults`. System settings Stackshot changes (`com.apple.screencapture`,
  the ⇧⌘4 shortcut) go through `ScreenshotPrefs` / `NativeShortcuts`, which back up the original so
  `--uninstall` can restore it.
- **Main actor**: UI types are `@MainActor`. Default arguments can't read main-actor statics, so take
  an optional and fall back inside (see `GroomModel.init`).
- **Comments** are short `///` notes on why, in plain English.

## Checking UI without disturbing the user

The user works on this Mac while you do. Check views by rendering them off-screen: build an
`NSHostingView`, set its frame, `layoutSubtreeIfNeeded()`, then `bitmapImageRepForCachingDisplay` +
`cacheDisplay` to a PNG and read it. To reach internal types, compile a throwaway `main.swift` together
with `Sources/StackshotKit/*.swift` (`swiftc -module-name StackshotKit … main.swift`) in the scratchpad.
Keep these renders window-free and non-activating; installing the real app is the one time windows
appear.

## Gotchas

- **The stack is invisible in screenshots**: the panel has `sharingType = .none`. Launch with
  `STACKSHOT_DEBUG=1` to capture it.
- **"The stack isn't showing"**: run `swift scripts/windows.swift`. A stack window that's ordered in but
  on one desktop only was stranded by macOS; `StackPanelController.rescueIfStranded` rebuilds it.
- **Window sizes**: the user runs a window manager that stretches new windows. A window that's
  suddenly full-screen with 12pt margins is that, not a layout bug.
- **Global keys** use Carbon hot keys (`HotKeys`), which need no permission. The key caps overlay uses
  an `NSEvent` global monitor, which needs Accessibility. Card keys (`CardKeys`) are only registered
  while the mouse is on a card and moving, so a parked mouse never swallows typing.
- **Recordings** exclude Stackshot's own windows via `SCContentFilter(excludingApplications:)`;
  pinned screenshots and key caps are let back in with `exceptingWindows`.
- **Claude Code** is found at `~/.local/bin/claude` and similar (apps don't get the shell PATH). It runs
  with `--setting-sources ""` so the user's own CLAUDE.md and hooks stay out, and only Read/Glob tools.
  The live test costs a few cents and runs only with `STACKSHOT_LIVE_CLAUDE=1 swift test --filter ClaudeCodeTests`.

## Shipping

CI (`.github/workflows/ci.yml`) builds, tests and packages every push and PR. A `v*` tag builds a
universal zip with the version stamped in and publishes a GitHub release.
