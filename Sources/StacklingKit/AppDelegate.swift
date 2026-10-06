import AppKit
import Combine

/// What happens at launch, in order. Stackling Dev runs only the hidden stack: everything else touches
/// the Mac you're using (menu bar, Dock, screenshot settings, files, global keys) or the real app's things.
enum LaunchStep: CaseIterable {
    case findClaude, mainMenu, stackPanel, statusItem, dockBadge, recordingIcon, nativeThumbnail, adoptDesktopShots
    case restoreStack, watchScreenshots, tidying, libraryIndex, warmUpGrabber, observeSettings, excludeStackFromCaptures
    case shortcuts, welcome

    static let touchesTheMac: Set<LaunchStep> = [
        .findClaude, .statusItem, .dockBadge, .recordingIcon, .nativeThumbnail, .adoptDesktopShots, .watchScreenshots,
        .tidying, .libraryIndex, .warmUpGrabber, .observeSettings, .shortcuts, .welcome,
    ]

    static func plan(dev: Bool) -> [LaunchStep] { dev ? [.stackPanel] : allCases }
}

/// What happens on quit. Stackling Dev never took ⇧⌘4, so it never hands it back either.
enum QuitStep {
    case handBackAreaShortcut, log

    static func plan(dev: Bool) -> [QuitStep] { dev ? [.log] : [.handBackAreaShortcut, .log] }
}

/// Wires the pieces together at launch. The menus live in Menus.swift.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ShotStore.shared
    /// Stackling Dev, read once at launch: see `LaunchStep`.
    private let dev: Bool
    private var panel: StackPanelController!
    private var watcher: ScreenshotWatcher?
    private var statusItem: NSStatusItem?
    private var statusMenu: StatusMenu?
    private var bag = Set<AnyCancellable>()
    private var tidyTimer: Timer?
    /// The launch steps that ran, for the test that Dev skips the rest.
    private(set) var ranSteps: [LaunchStep] = []

    init(dev: Bool? = nil) {
        self.dev = dev ?? AppIdentity.current.isDev
    }

    /// Tidy once shortly after launch, then every hour.
    private static let firstTidyDelay: TimeInterval = 10
    private static let tidyInterval: TimeInterval = 3600
    /// How long the stack has to sit still before it's written to disk.
    private static let saveDebounce = RunLoop.SchedulerTimeType.Stride.milliseconds(300)
    /// Lets the menu bar settle before the welcome alert appears.
    private static let welcomeDelay: TimeInterval = 0.4

    private static let stackSymbol = "square.stack.3d.up.fill"

    func applicationDidFinishLaunching(_ notification: Notification) {
        for step in LaunchStep.plan(dev: dev) {
            run(step)
            ranSteps.append(step)
        }
        if dev { DevCopy.startIfAsked(store: store, panel: panel) }
    }

    private func run(_ step: LaunchStep) {
        switch step {
        case .findClaude:
            // Looking for Claude Code can take a moment; do it now, off the main thread, so the stack never waits on it.
            Task.detached(priority: .utility) { _ = ClaudeCode.isInstalled }
        case .mainMenu: MainMenu.install()
        case .stackPanel:
            panel = dev ? StackPanelController(store: store, senses: DevCopy.driver.senses(), hidden: true)
                : StackPanelController(store: store)
        case .statusItem: setUpStatusItem()
        case .dockBadge: observeDockBadge()
        case .recordingIcon: observeRecordingIcon()
        case .nativeThumbnail: turnOffNativeThumbnailUnlessKept()
        case .adoptDesktopShots: Library.adoptIfOnDesktop()
        case .restoreStack: restoreAndPersistStack()
        case .watchScreenshots:
            watcher = ScreenshotWatcher(store: store)
            watcher?.start()
        case .tidying: scheduleTidying()
        case .libraryIndex:
            // Start the library a little after launch, so the words in your shots are ready to search when you look.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { LibraryIndex.shared.start() }
        case .warmUpGrabber: Task { await ScreenGrabber.warmUp() }
        case .observeSettings: observeSettings()
        case .excludeStackFromCaptures:
            CaptureController.shared.excludedWindowNumbers = { [weak self] in
                [self?.panel.windowNumberToExclude].compactMap { $0 }
            }
        case .shortcuts: applyShortcuts()
        case .welcome: showWelcomeOnce()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Files dropped on the Dock icon, or opened with Open With → Stackling, join the stack.
    func application(_ application: NSApplication, open urls: [URL]) {
        Importer.add(urls, from: "open")
    }

    /// Clicking the Dock icon opens the library, like any Mac app's main window. Capturing stays on ⇧⌘4,
    /// and the Dock icon's right-click menu has every capture option.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.app.info("dock.clicked action=open-library")
        ActivityLog.via("dock") { LibraryWindowController.show() }
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        statusMenu?.dockMenu()
    }

    static func toggleRecording() {
        if Recorder.shared.isRecording {
            Recorder.shared.stop()
        } else {
            CaptureController.shared.start(.area, for: .recording)
        }
    }

    // MARK: Launch steps

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: Self.stackSymbol, accessibilityDescription: "Stackling")
        let statusMenu = StatusMenu(store: store)
        let menu = NSMenu()
        menu.delegate = statusMenu
        item.menu = menu
        self.statusMenu = statusMenu
        statusItem = item
    }

    private func observeDockBadge() {
        store.$shots
            .receive(on: RunLoop.main)
            .sink { shots in NSApp.dockTile.badgeLabel = shots.isEmpty ? nil : "\(shots.count)" }
            .store(in: &bag)
    }

    /// While recording, the menu bar icon turns into a red stop button.
    private func observeRecordingIcon() {
        Recorder.shared.$startedAt
            .receive(on: RunLoop.main)
            .sink { [weak self] started in self?.showRecordingIcon(started != nil) }
            .store(in: &bag)
    }

    private func showRecordingIcon(_ recording: Bool) {
        guard let button = statusItem?.button else { return }
        if recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = false
        } else {
            button.image = NSImage(systemSymbolName: Self.stackSymbol, accessibilityDescription: "Stackling")
        }
    }

    /// The native thumbnail delays saving the file and would double up with our stack.
    private func turnOffNativeThumbnailUnlessKept() {
        guard ScreenshotPrefs.nativeThumbnailEnabled else { return }
        if AppSettings.keepNativeThumbnail {
            Log.app.debug("native-thumbnail.kept reason=setting")
            return
        }
        Log.app.notice("native-thumbnail.disabled reason=launch")
        ScreenshotPrefs.setNativeThumbnail(false)
    }

    /// Puts back what was on the stack last time, then saves it whenever it changes.
    private func restoreAndPersistStack() {
        StackMemory.restore(into: store)
        Publishers.CombineLatest(store.$shots, store.$recent)
            .debounce(for: Self.saveDebounce, scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                StackMemory.save(self.store)
            }
            .store(in: &bag)
    }

    private func scheduleTidying() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstTidyDelay) { [weak self] in
            guard let self else { return }
            Cleanup.run(store: self.store)
        }
        tidyTimer = Timer.scheduledTimer(withTimeInterval: Self.tidyInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Cleanup.run(store: self.store)
            }
        }
    }

    private func observeSettings() {
        NotificationCenter.default.publisher(for: .stacklingSettingsChanged)
            .sink { [weak self] _ in
                self?.applyShortcuts()
                self?.panel.noteActivity()
                self?.watcher?.checkLocation()
            }
            .store(in: &bag)
    }

    private func showWelcomeOnce() {
        guard !AppSettings.hasSeenWelcome else { return }
        AppSettings.hasSeenWelcome = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.welcomeDelay) { WelcomeAlert.show(firstLaunch: true) }
    }

    /// Hands ⇧⌘4 back to macOS while Stackling isn't running (quit, log out, restart), so it never goes dead.
    /// Launch takes it over again.
    func applicationWillTerminate(_ notification: Notification) {
        for step in QuitStep.plan(dev: dev) {
            switch step {
            case .handBackAreaShortcut:
                if AppSettings.takeOverArea, !NativeShortcuts.areaShortcutEnabled {
                    NativeShortcuts.setAreaShortcut(enabled: true)
                }
            case .log:
                Log.app.notice("quit")
                ActivityLog.record(.quit)
                ActivityLog.flush()
            }
        }
    }

    // MARK: Shortcuts

    /// Registers the capture shortcuts. ⇧⌘4 is Stackling's by default (frozen screen and loupe),
    /// or handed back to macOS if you've turned that off.
    private func applyShortcuts() {
        let keys = HotKeys.shared
        // Without Screen Recording permission Stackling can't freeze the screen, so ⇧⌘4 stays the Mac's
        // (its shots still land on the stack). The permission needs a relaunch, which takes it over.
        let permitted = CGPreflightScreenCaptureAccess()
        let takeOver = AppSettings.takeOverArea && permitted
        if takeOver {
            if NativeShortcuts.areaShortcutEnabled { NativeShortcuts.setAreaShortcut(enabled: false) }
            keys.register(.four) { CaptureController.shared.start(.area) }
        } else {
            keys.unregister(.four)
            if !NativeShortcuts.areaShortcutEnabled { NativeShortcuts.setAreaShortcut(enabled: true) }
        }
        keys.register(.seven) { Self.toggleRecording() }
        keys.register(.eight) { CaptureController.shared.start(.window) }
        keys.register(.nine) { CaptureController.shared.captureFullScreen() }
        Log.keys.notice("shortcuts.applied area=\(takeOver ? "stackling" : "macos", privacy: .public) permitted=\(permitted)")
    }
}
