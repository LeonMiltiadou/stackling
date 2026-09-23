import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ShotStore.shared
    private var panel: StackPanelController!
    private var watcher: ScreenshotWatcher!
    private var statusItem: NSStatusItem!
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        panel = StackPanelController(store: store)
        watcher = ScreenshotWatcher(store: store)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Stackshot")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        store.$shots
            .receive(on: RunLoop.main)
            .sink { shots in NSApp.dockTile.badgeLabel = shots.isEmpty ? nil : "\(shots.count)" }
            .store(in: &bag)

        // The native thumbnail delays saving the file and would double up with our stack.
        if Prefs.nativeThumbnailEnabled && !UserDefaults.standard.bool(forKey: "leaveNativeThumbnail") {
            Prefs.setNativeThumbnail(false)
        }

        watcher.start()

        CaptureController.shared.excludedWindowNumbers = { [weak self] in
            [self?.panel.windowNumber].compactMap { $0 }
        }
        // Stackshot takes over ⇧⌘4 by default so area captures get the frozen screen and loupe.
        if UserDefaults.standard.object(forKey: "takeOverArea") == nil {
            UserDefaults.standard.set(true, forKey: "takeOverArea")
        }
        applyShortcuts()

        if !UserDefaults.standard.bool(forKey: "welcomed.v2") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            UserDefaults.standard.set(true, forKey: "welcomed.v2")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showWelcome() }
        }
    }

    private var takeOverArea: Bool { UserDefaults.standard.bool(forKey: "takeOverArea") }

    private func applyShortcuts() {
        let keys = HotKeys.shared
        if takeOverArea {
            if NativeShortcuts.areaShortcutEnabled { NativeShortcuts.setAreaShortcut(enabled: false) }
            keys.register(.four) { CaptureController.shared.start(.area) }
        } else {
            keys.unregister(.four)
            if !NativeShortcuts.areaShortcutEnabled { NativeShortcuts.setAreaShortcut(enabled: true) }
        }
        keys.register(.eight) { CaptureController.shared.start(.window) }
        keys.register(.nine) { CaptureController.shared.captureFullScreen() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon starts an area capture.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        CaptureController.shared.start(.area)
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        addCaptureItems(to: menu)
        if !store.shots.isEmpty {
            menu.addItem(.separator())
            menu.addItem(item("Clear Stack (\(store.shots.count))") { [weak self] in self?.store.clearAll() })
        }
        return menu
    }

    // MARK: - Menus

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Stackshot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Stackshot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Stackshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Standard Edit menu: gives the editor ⌘Z, ⇧⌘Z, ⌘C and text editing shortcuts.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addCaptureItems(to: menu)
        menu.addItem(.separator())

        let count = store.shots.count
        if count > 1 {
            menu.addItem(item(store.expanded ? "Collapse Stack" : "Expand Stack") { [weak self] in self?.store.toggleExpanded() })
        }
        let clear = item(count > 0 ? "Clear Stack (\(count))" : "Stack is empty") { [weak self] in self?.store.clearAll() }
        clear.isEnabled = count > 0
        menu.addItem(clear)

        let recentItem = NSMenuItem(title: "Recently Dismissed", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let recent = store.recent.filter(\.exists)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        } else {
            for shot in recent {
                let entry = item(shot.url.deletingPathExtension().lastPathComponent) { [weak self] in self?.store.restore(shot) }
                if let thumb = shot.thumbnail {
                    let icon = NSImage(size: NSSize(width: 32, height: 20), flipped: false) { rect in
                        thumb.draw(in: rect.aspectFit(thumb.size))
                        return true
                    }
                    entry.image = icon
                }
                recentMenu.addItem(entry)
            }
            recentMenu.addItem(.separator())
            recentMenu.addItem(item("Bring All Back") { [weak self] in self?.store.restoreAllRecent() })
        }
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())
        menu.addItem(saveLocationItem())
        menu.addItem(item("Open Screenshots Folder") { NSWorkspace.shared.open(Prefs.screenshotFolder) })

        let native = item("Show macOS Floating Thumbnail Too") {
            let on = !Prefs.nativeThumbnailEnabled
            Prefs.setNativeThumbnail(on)
            UserDefaults.standard.set(on, forKey: "leaveNativeThumbnail")
        }
        native.state = Prefs.nativeThumbnailEnabled ? .on : .off
        native.toolTip = "Leave this off. With it on, macOS waits for its own thumbnail to vanish before saving, so screenshots show up late."
        menu.addItem(native)

        let area = item("Use Stackshot for ⇧⌘4") { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(!self.takeOverArea, forKey: "takeOverArea")
            self.applyShortcuts()
        }
        area.state = takeOverArea ? .on : .off
        area.toolTip = "On: ⇧⌘4 freezes the screen and shows the loupe. Off: ⇧⌘4 is the Mac's own capture (still lands on the stack)."
        menu.addItem(area)

        menu.addItem(fadeItem())
        menu.addItem(opacityItem())

        let login = item("Open at Login") {
            let service = SMAppService.mainApp
            if service.status == .enabled { try? service.unregister() } else { try? service.register() }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("How It Works…") { [weak self] in self?.showWelcome() })
        menu.addItem(item("Quit Stackshot") { NSApp.terminate(nil) })
    }

    private func fadeItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Fade When Idle", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, seconds) in [("After 2 seconds", 2.0), ("After 5 seconds", 5), ("After 10 seconds", 10), ("After 30 seconds", 30), ("Never", 0)] {
            let entry = item(title) { [weak self] in
                Settings.fadeDelay = seconds
                self?.panel.poke()
            }
            entry.state = Settings.fadeDelay == seconds ? .on : .off
            sub.addItem(entry)
        }
        parent.submenu = sub
        return parent
    }

    private func opacityItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "When Faded", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, value) in [("Invisible", 0.0), ("Barely there (10%)", 0.1), ("Faint (20%)", 0.2), ("Half (50%)", 0.5)] {
            let entry = item(title) { [weak self] in
                Settings.fadedOpacity = value
                self?.panel.poke()
            }
            entry.state = abs(Settings.fadedOpacity - value) < 0.01 ? .on : .off
            sub.addItem(entry)
        }
        sub.addItem(.separator())
        let note = NSMenuItem(title: "Hover the corner to bring it back", action: nil, keyEquivalent: "")
        note.isEnabled = false
        sub.addItem(note)
        parent.submenu = sub
        return parent
    }

    private func addCaptureItems(to menu: NSMenu) {
        menu.addItem(item("Capture Area", hint: takeOverArea ? "⇧⌘4" : nil) { CaptureController.shared.start(.area) })
        menu.addItem(item("Capture Window", hint: "⇧⌘8") { CaptureController.shared.start(.window) })
        menu.addItem(item("Capture Full Screen", hint: "⇧⌘9") { CaptureController.shared.captureFullScreen() })
        menu.addItem(item("Record or Use macOS Toolbar…", hint: "⇧⌘5") { Capture.toolbar.run() })
    }

    private func saveLocationItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Save Screenshots To", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let current = Prefs.screenshotFolder.standardizedFileURL
        let options: [(String, URL)] = [
            ("Desktop", home.appendingPathComponent("Desktop")),
            ("Pictures › Screenshots", home.appendingPathComponent("Pictures/Screenshots")),
            ("Downloads", home.appendingPathComponent("Downloads")),
        ]
        var matched = false
        for (title, url) in options {
            let entry = item(title) { [weak self] in
                Prefs.setScreenshotFolder(url)
                self?.watcher.checkLocation()
            }
            if url.standardizedFileURL == current { entry.state = .on; matched = true }
            sub.addItem(entry)
        }
        if !matched {
            let custom = NSMenuItem(title: current.lastPathComponent, action: nil, keyEquivalent: "")
            custom.state = .on
            custom.isEnabled = false
            sub.addItem(custom)
        }
        sub.addItem(.separator())
        sub.addItem(item("Choose Folder…") { [weak self] in
            NSApp.activate()
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Use Folder"
            panel.directoryURL = current
            if panel.runModal() == .OK, let url = panel.url {
                Prefs.setScreenshotFolder(url)
                self?.watcher.checkLocation()
            }
        })
        parent.submenu = sub
        return parent
    }

    private func item(_ title: String, hint: String? = nil, _ action: @escaping () -> Void) -> NSMenuItem {
        let entry = ClosureMenuItem(title: title, action: action)
        if let hint {
            let text = NSMutableAttributedString(string: title)
            text.append(NSAttributedString(
                string: "   \(hint)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)]
            ))
            entry.attributedTitle = text
        }
        return entry
    }

    private func showWelcome() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Stackshot is running"
        alert.informativeText = """
        ⇧⌘4  Area, on a frozen screen with a pixel loupe
        ⇧⌘8  Window
        ⇧⌘9  Full screen
        ⇧⌘3 and ⇧⌘5 still work as usual (⇧⌘5 for recording).

        Each shot lands in a stack in the bottom-left corner and stays there until you do something with it: copy, drag it into an app, edit, pin, grab its text, or dismiss it.

        Tips
        • Click a card to annotate it: arrows, boxes, text, numbers, highlight, redact, and a nice background.
        • Edits stay editable. Copy and drag include them automatically.
        • Hold ⌥ while copying to keep the card.
        • Dismissed cards live in the menu bar under Recently Dismissed.
        • Clicking the Dock icon starts an area capture.
        • After a few quiet seconds the stack fades. Hover the corner to bring it back.

        I switched off the macOS floating thumbnail so you don't get two previews.
        """
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Got it")
        alert.runModal()
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

extension NSRect {
    func aspectFit(_ size: NSSize) -> NSRect {
        guard size.width > 0, size.height > 0 else { return self }
        let scale = min(width / size.width, height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }
}
