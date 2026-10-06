import AppKit
import Testing
@testable import StacklingKit

/// Stackling Dev, the hidden copy that tests itself: it must never share anything with the real app,
/// never touch the Mac at launch or quit, and never open anything.
@MainActor @Suite struct DevCopyTests {
    @Test func theDevCopyHasItsOwnIdentityEverywhere() {
        let dev = AppIdentity(bundleID: AppIdentity.devBundleID)
        let real = AppIdentity(bundleID: nil)
        #expect(dev.isDev && !real.isDev)
        #expect(real.bundleID == "io.github.leonmiltiadou.stackling")
        #expect(AppIdentity(bundleID: "com.apple.dt.xctest.tool").bundleID == real.bundleID, "an unknown bundle is the real app")
        let pairs = [(dev.bundleID, real.bundleID), (dev.logSubsystem, real.logSubsystem),
                     (dev.keychainService, real.keychainService), (dev.usageAttribute, real.usageAttribute),
                     (dev.queueLabel("activity"), real.queueLabel("activity")), (dev.support.path, real.support.path)]
        for (mine, theirs) in pairs {
            #expect(mine != theirs)
            #expect(mine.contains(".dev"))
        }
        // The real app's names stay exactly as they were, so nothing it saved is lost.
        #expect(real.usageAttribute == "io.github.leonmiltiadou.stackling.usage")
        #expect(real.keychainService == "io.github.leonmiltiadou.stackling.typesafe")
        #expect(real.pasteboardName == nil && dev.pasteboardName != nil, "Dev never touches your clipboard")
        #expect(real.libraryRoot.path.hasSuffix("Pictures/Stackling"))
        #expect(!dev.libraryRoot.path.contains("Pictures"))
    }

    @Test func theDevLaunchSkipsEverythingThatTouchesTheMac() {
        let dev = LaunchStep.plan(dev: true)
        #expect(Set(dev).isDisjoint(with: LaunchStep.touchesTheMac))
        #expect(dev == [.stackPanel])
        #expect(LaunchStep.plan(dev: false) == LaunchStep.allCases)
        for step in [LaunchStep.statusItem, .dockBadge, .nativeThumbnail, .adoptDesktopShots, .watchScreenshots,
                     .tidying, .libraryIndex, .shortcuts, .welcome] {
            #expect(LaunchStep.touchesTheMac.contains(step))
        }
        #expect(QuitStep.plan(dev: true) == [.log], "Dev never hands ⇧⌘4 back, because it never took it")
        #expect(QuitStep.plan(dev: false) == [.handBackAreaShortcut, .log])
    }

    @Test func aDevLaunchRunsOnlyItsPlan() {
        Outside.makeInert()
        let delegate = AppDelegate(dev: true)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(delegate.ranSteps == [.stackPanel])
    }

    @Test func inertOpenersOpenNothingAndSayWhatWouldHaveOpened() throws {
        Outside.makeInert()
        let folder = try TempFolder()
        let shot = Shot(url: try folder.file("Screenshot.png"), created: Date())
        let before = Outside.blocked.count
        Actions.edit(shot)
        Actions.openInPreview(shot)
        Actions.reveal(shot)
        Actions.openInQuickTime(shot)
        Actions.moveTo(shot)
        Actions.fileIntoNewFolder(shot)
        let bugs = folder.url.appendingPathComponent("Bugs", isDirectory: true)
        try FileManager.default.createDirectory(at: bugs, withIntermediateDirectories: true)
        #expect(!Library.trashFolder(bugs))
        #expect(Library.renameFolder(bugs) == nil)
        Importer.chooseFiles()
        Uninstaller.confirmAndRun()
        #expect(Array(Outside.blocked.dropFirst(before)) == ["editor", "Preview", "finder", "QuickTime Player", "save-panel",
                                                             "name-prompt", "trash-folder-prompt", "name-prompt", "open-panel",
                                                             "uninstall-prompt"])
        #expect(FileManager.default.fileExists(atPath: bugs.path))
        #expect(FileManager.default.fileExists(atPath: shot.url.path), "New Folder… filed nothing")
        #expect(NSApplication.shared.windows.allSatisfy { !$0.isVisible })
    }

    /// The real Stackling Dev app, run by `scripts/dev.sh check` from the release build the check command
    /// makes just before the tests. Skipped when that build is older than the sources.
    @Test(.enabled(if: DevApp.freshRelease != nil, "needs a fresh `swift build -c release`"), .timeLimit(.minutes(1)))
    func theHiddenDevAppReachesForMoreAndOpensTheStack() throws {
        let folder = try TempFolder()
        let yours = try folder.file("yours.txt")
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A relative folder, from where the script is run, that already has something else in it.
        run.currentDirectoryURL = folder.url.deletingLastPathComponent()
        run.arguments = [DevApp.root.appendingPathComponent("scripts/dev.sh").path, "check", folder.url.lastPathComponent]
        run.environment = ProcessInfo.processInfo.environment.merging(["STACKLING_DEV_BIN": try #require(DevApp.freshRelease).path]) { $1 }
        let out = Pipe()
        run.standardOutput = out
        run.standardError = out
        try run.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()
        #expect(run.terminationStatus == 0, "\(output)")
        #expect(output.contains("target=more"))
        #expect(output.contains("expanded=true"))
        #expect(output.contains("shrank-during-reach=false"))
        #expect(output.contains("onscreen-windows=0"))
        #expect(output.contains(#""e":"stack.expand""#))
        #expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("3-after-click.png").path))
        #expect(FileManager.default.fileExists(atPath: yours.path), "the check only replaces its own pictures")
    }

    @Test func theDevCopyRefusesWhileOpenersAreLive() throws {
        let folder = try TempFolder()
        let store = ShotStore()
        let driver = SteppedDriver()
        let controller = StackPanelController(store: store, senses: driver.senses(shrinkDelay: 2), hidden: true)
        driver.controller = controller
        let shots = try (0..<4).map { try folder.file("Screenshot \($0).png") }
        let report = Outside.whileLive {
            DevCopy.reachForMore(store: store, controller: controller, driver: driver, captures: shots)
        }
        #expect(report.refused != nil)
        #expect(store.shots.isEmpty, "refused before touching anything")
        #expect(Outside.isInert)
    }
}

/// Where the package is, and its release build of the app if no source changed since that build.
enum DevApp {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static var freshRelease: URL? {
        let binary = root.appendingPathComponent(".build/release/Stackling")
        // The module's dependency file is rewritten on every release compile; the binary is only relinked
        // when the code really changed, so its own date can be older than an untouched-but-saved source.
        let compiled = root.appendingPathComponent(".build/release/StacklingKit.build/StacklingKit.d")
        guard binary.modificationDate != nil, let built = compiled.modificationDate ?? binary.modificationDate else { return nil }
        let sources = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: [.contentModificationDateKey])
        while let file = sources?.nextObject() as? URL {
            if let changed = file.modificationDate, changed > built { return nil }
        }
        return binary
    }
}
