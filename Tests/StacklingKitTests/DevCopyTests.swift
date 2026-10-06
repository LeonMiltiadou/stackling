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
        #expect(Array(Outside.blocked.dropFirst(before)) == ["editor", "Preview", "finder", "QuickTime Player", "save-panel"])
        #expect(NSApplication.shared.windows.allSatisfy { !$0.isVisible })
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
