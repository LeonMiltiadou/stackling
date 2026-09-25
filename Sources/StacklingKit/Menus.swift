import AppKit
import ServiceManagement

/// The app's menu bar menus: Stackling, Edit and Window.
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()
        main.addSubmenu(appMenu())
        main.addSubmenu(editMenu())
        let windows = windowMenu()
        main.addSubmenu(windows)
        NSApp.windowsMenu = windows
        NSApp.mainMenu = main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "About Stackling", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(settingsItem())
        menu.addItem(libraryItem())
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Uninstall Stackling…") { Uninstaller.confirmAndRun() })
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Stackling", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Quit Stackling", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// Standard Edit menu: gives the editor ⌘Z, ⇧⌘Z, ⌘C and text editing shortcuts.
    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: #selector(UndoActions.undo(_:)), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: #selector(UndoActions.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        let find = ClosureMenuItem(title: "Find") {
            LibraryWindowController.show()
        }
        find.keyEquivalent = "f"
        menu.addItem(find)
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        return menu
    }

    /// "Settings…" with ⌘, as in every Mac app. Shared with the menu bar icon's menu.
    /// Stackling's library window, ⌘L.
    static func libraryItem() -> NSMenuItem {
        let item = ClosureMenuItem(title: "Library") { LibraryWindowController.show() }
        item.keyEquivalent = "l"
        item.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        return item
    }

    static func settingsItem() -> NSMenuItem {
        let item = ClosureMenuItem(title: "Settings…") { SettingsWindowController.show() }
        item.keyEquivalent = ","
        return item
    }
}

/// The responder chain's Undo and Redo actions, which AppKit doesn't declare for Swift.
@objc private protocol UndoActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

private extension NSMenu {
    func addSubmenu(_ submenu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        addItem(item)
    }
}

/// The menu bar icon's menu, rebuilt each time it opens so it always matches the stack.
/// Also builds the Dock icon's menu, which shares the capture items.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let store: ShotStore

    /// Sizes the Recently Dismissed thumbnails.
    private static let recentThumbnailSize = NSSize(width: 32, height: 20)

    init(store: ShotStore) {
        self.store = store
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Items say for themselves whether they can be used (Paste to Stack, Clear Stack); don't let AppKit re-enable them.
        menu.autoenablesItems = false
        addCaptureItems(to: menu)
        menu.addItem(.separator())
        addStackItems(to: menu)
        menu.addItem(recentlyDismissedItem())
        if PinWindow.count > 0 {
            menu.addItem(ClosureMenuItem(title: "Close All Pins (\(PinWindow.count))") { PinWindow.closeAll() })
        }
        menu.addItem(.separator())
        let library = ClosureMenuItem(title: "Open Library") { LibraryWindowController.show() }
        library.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        library.toolTip = "Every shot in one place, searchable by the words inside them."
        menu.addItem(library)
        let tidy = ClosureMenuItem(title: "Tidy with Claude…") { GroomWindowController.show() }
        tidy.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        tidy.toolTip = "Claude suggests a name and a folder for each loose screenshot. You review everything first."
        menu.addItem(tidy)
        menu.addItem(MainMenu.settingsItem())
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "How It Works…") { WelcomeAlert.show() })
        menu.addItem(ClosureMenuItem(title: "Quit Stackling") { NSApp.terminate(nil) })
    }

    /// Clicking and holding the Dock icon: the capture items, and clearing the stack.
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        addCaptureItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Open Library") { LibraryWindowController.show() })
        menu.addItem(ClosureMenuItem(title: "Add to Stack…") { Importer.chooseFiles() })
        if Importer.clipboardHasSomething {
            menu.addItem(ClosureMenuItem(title: "Paste to Stack") { Importer.pasteFromClipboard() })
        }
        if !store.shots.isEmpty {
            menu.addItem(ClosureMenuItem(title: "Clear Stack (\(store.shots.count))") { [weak self] in self?.store.clearAll() })
        }
        return menu
    }

    private func addCaptureItems(to menu: NSMenu) {
        let recording = Recorder.shared.isRecording
        if recording {
            menu.addItem(ClosureMenuItem(title: "Stop Recording", hint: HotKeys.Key.seven.label) { Recorder.shared.stop() })
            menu.addItem(ClosureMenuItem(title: "Throw Away Recording") { Recorder.shared.stop(discard: true) })
            menu.addItem(.separator())
        }
        let areaHint = AppSettings.takeOverArea ? HotKeys.Key.four.label : nil
        menu.addItem(ClosureMenuItem(title: "Capture Area", hint: areaHint) { CaptureController.shared.start(.area) })
        menu.addItem(ClosureMenuItem(title: "Capture Window", hint: HotKeys.Key.eight.label) { CaptureController.shared.start(.window) })
        menu.addItem(ClosureMenuItem(title: "Capture Full Screen", hint: HotKeys.Key.nine.label) { CaptureController.shared.captureFullScreen() })
        if !recording {
            menu.addItem(ClosureMenuItem(title: "Record Screen…", hint: HotKeys.Key.seven.label) { CaptureController.shared.start(.area, for: .recording) })
        }
        menu.addItem(ClosureMenuItem(title: "macOS Screenshot Toolbar…", hint: "⇧⌘5") { SystemScreenshotToolbar.open() })
    }

    private func addStackItems(to menu: NSMenu) {
        let count = store.shots.count
        // With nothing on the stack, the quickest way back to what you just cleared goes first.
        if count == 0, let last = store.recent.first(where: \.exists) {
            let back = ClosureMenuItem(title: "Bring Back Last Shot") { [weak self] in self?.store.restore(last) }
            back.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
            menu.addItem(back)
        }
        let add = ClosureMenuItem(title: "Add to Stack…") { Importer.chooseFiles() }
        add.image = NSImage(systemSymbolName: "plus.rectangle.on.rectangle", accessibilityDescription: nil)
        add.toolTip = "Bring in any picture or video to mark up, hide secrets in, turn into a GIF or file away. You can also drop files on Stackling's Dock icon."
        menu.addItem(add)
        let paste = ClosureMenuItem(title: "Paste to Stack") { Importer.pasteFromClipboard() }
        paste.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        paste.isEnabled = Importer.clipboardHasSomething
        menu.addItem(paste)
        if count > 1 {
            menu.addItem(ClosureMenuItem(title: store.expanded ? "Collapse Stack" : "Expand Stack") { [weak self] in self?.store.toggleExpanded() })
        }
        if store.customOrigin != nil {
            menu.addItem(ClosureMenuItem(title: "Put Stack Back in Corner") { [weak self] in self?.store.customOrigin = nil })
        }
        let clear = ClosureMenuItem(title: count > 0 ? "Clear Stack (\(count))" : "Stack is empty") { [weak self] in self?.store.clearAll() }
        clear.isEnabled = count > 0
        menu.addItem(clear)
    }

    private func recentlyDismissedItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Recently Dismissed", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let recent = store.recent.filter(\.exists)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for shot in recent {
                let entry = ClosureMenuItem(title: shot.url.deletingPathExtension().lastPathComponent) { [weak self] in self?.store.restore(shot) }
                entry.image = Self.thumbnailIcon(for: shot)
                submenu.addItem(entry)
            }
            submenu.addItem(.separator())
            submenu.addItem(ClosureMenuItem(title: "Bring All Back") { [weak self] in self?.store.restoreAllRecent() })
        }
        item.submenu = submenu
        return item
    }

    private static func thumbnailIcon(for shot: Shot) -> NSImage? {
        guard let thumb = shot.thumbnail else { return nil }
        return NSImage(size: recentThumbnailSize, flipped: false) { rect in
            thumb.draw(in: rect.aspectFit(thumb.size))
            return true
        }
    }
}

/// A menu item that runs a closure, with an optional shortcut shown greyed out after the title.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, hint: String? = nil, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let hint {
            // Shown rather than bound: the shortcuts are global hot keys, not menu key equivalents.
            let text = NSMutableAttributedString(string: title)
            text.append(NSAttributedString(
                string: "   \(hint)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)]
            ))
            attributedTitle = text
        }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { ActivityLog.via("menu") { handler() } }
}

/// The first-launch introduction, also under "How It Works…" in the menu bar menu.
@MainActor
enum WelcomeAlert {
    /// Shown on first launch, and from How It Works… in the menu bar. Short on purpose: what the keys are,
    /// and what Stackling changed on this Mac. Everything else is in the README.
    static func show(firstLaunch: Bool = false) {
        Log.app.info("welcome.shown first=\(firstLaunch)")
        NSApp.activate()
        let needsPermission = !CGPreflightScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "Stackling is running"
        alert.informativeText = """
        \(HotKeys.Key.four.label)  Area, on a frozen screen with a loupe
        \(HotKeys.Key.eight.label)  Window     \(HotKeys.Key.nine.label)  Full screen
        \(HotKeys.Key.seven.label)  Record the screen (press again to stop)

        Every shot waits on the stack in the bottom-left corner: point at a card to copy, drag, edit or pin it. \
        Click the Dock icon for the library, where you can search the words inside every shot.

        What changed on this Mac
        • Screenshots save to Pictures › Stackling instead of the Desktop.
        • \(HotKeys.Key.four.label) is Stackling's while it runs. Quit, and it's the Mac's again.
        • Loose shots you're done with clear themselves out after a few days. Press K on a card to keep one.
        """ + (needsPermission ? "\n\nOne thing left: Stackling needs Screen Recording permission to freeze the screen. Until then, \(HotKeys.Key.four.label) works the Mac's usual way and still lands on the stack." : "")
        alert.icon = NSApp.applicationIconImage
        if needsPermission {
            alert.addButton(withTitle: "Turn On Screen Recording…")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "Got it")
        }
        if firstLaunch {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Open Stackling when I log in"
            alert.suppressionButton?.state = .on
        }
        let answer = alert.runModal()
        if firstLaunch, alert.suppressionButton?.state == .on {
            do { try SMAppService.mainApp.register() } catch {
                Log.app.error("login-item.failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
        if needsPermission, answer == .alertFirstButtonReturn { ScreenCapturePermission.openSettings() }
    }
}

/// Stackling › Uninstall Stackling…: removes the app and puts the Mac back the way it was, using the
/// same script as `scripts/uninstall.sh` (copied into the app when it's built). Screenshots stay put.
@MainActor
enum Uninstaller {
    static func confirmAndRun() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Uninstall Stackling?"
        alert.informativeText = """
        This quits Stackling, deletes the app and its settings, and puts your Mac's screenshot settings and ⇧⌘4 back \
        the way they were before you installed it.

        Your screenshots stay where they are. Edits you haven't saved into an image are removed.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let script = Bundle.main.url(forResource: "uninstall", withExtension: "sh") else {
            Log.app.error("uninstall.script-missing")
            return
        }
        Log.app.notice("uninstall.start")
        // Runs on its own: the script quits this app partway through.
        Shell.run("/bin/zsh", [script.path], wait: false)
    }
}
