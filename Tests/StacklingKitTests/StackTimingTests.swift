import AppKit
import Testing
@testable import StacklingKit

/// The stack's timing, on a hidden stack with a scripted pointer and a clock that only moves when told:
/// when it shrinks, and that it doesn't shrink away from under you as you reach for "3 more".
@MainActor @Suite struct StackTimingTests {
    private func hiddenStack(_ count: Int, in folder: TempFolder) throws -> (ShotStore, StackPanelController, SteppedDriver) {
        Outside.makeInert()
        let store = ShotStore()
        store.animates = false
        let driver = SteppedDriver()
        let controller = StackPanelController(store: store, senses: driver.senses(shrinkDelay: 2), hidden: true)
        driver.controller = controller
        for i in 0..<count { store.add(try folder.file("Screenshot \(i).png")) }
        controller.layoutNow()
        return (store, controller, driver)
    }

    private func farFrom(_ stack: CGRect) -> NSPoint { NSPoint(x: stack.maxX + 600, y: stack.maxY + 400) }

    @Test func aStackLeftAloneShrinksOnceTheDelayIsUp() throws {
        let folder = try TempFolder()
        let (store, controller, driver) = try hiddenStack(4, in: folder)
        driver.pointer = farFrom(controller.frame)
        driver.wait(1.9)
        #expect(!store.minimized)
        driver.wait(0.3)
        #expect(store.minimized)
        #expect(!controller.isOnScreen, "the hidden stack is never ordered in")
    }

    @Test func aHandRestingOnTheMouseStillLetsItShrink() throws {
        let folder = try TempFolder()
        let (store, controller, driver) = try hiddenStack(4, in: folder)
        driver.pointer = farFrom(controller.frame)
        for _ in 0..<16 {
            driver.pointer.x -= 1
            driver.wait(StackPanelController.pollInterval)
        }
        #expect(store.minimized)
    }

    @Test func aPointerMovingAwayLetsItShrink() throws {
        let folder = try TempFolder()
        let (store, controller, driver) = try hiddenStack(4, in: folder)
        driver.pointer = NSPoint(x: controller.frame.maxX + 20, y: controller.frame.maxY)
        for _ in 0..<16 {
            driver.pointer.x += 30
            driver.wait(StackPanelController.pollInterval)
        }
        #expect(store.minimized)
    }

    @Test func aPointerOnTheStackKeepsItOpen() throws {
        let folder = try TempFolder()
        let (store, controller, driver) = try hiddenStack(4, in: folder)
        driver.pointer = NSPoint(x: controller.frame.midX, y: controller.frame.midY)
        driver.wait(6)
        #expect(!store.minimized)
    }

    /// The "3 more" bug: capture, wait a moment, reach for the pill. The stack must still be open when the
    /// pointer gets there, and the pill must be what's under it. The press is the pill's own action, not a
    /// real mouse event: macOS sends none to a window that was never shown.
    @Test func reachingForThreeMoreOpensTheStack() throws {
        let folder = try TempFolder()
        Outside.makeInert()
        let store = ShotStore()
        store.animates = false
        let driver = SteppedDriver()
        let controller = StackPanelController(store: store, senses: driver.senses(shrinkDelay: 2), hidden: true)
        driver.controller = controller
        let shots = try (0..<4).map { try folder.file("Screenshot \($0).png") }
        let report = DevCopy.reachForMore(store: store, controller: controller, driver: driver, captures: shots)
        #expect(report.refused == nil)
        #expect(!report.shrankDuringReach)
        #expect(report.hitView == "StackHostingView", "no card or other AppKit view sits on top of the pill")
        #expect(report.target == .more)
        #expect(store.expanded)
    }

    @Test func reachingAfterItShrankFindsNoPill() throws {
        let folder = try TempFolder()
        Outside.makeInert()
        let store = ShotStore()
        store.animates = false
        let driver = SteppedDriver()
        let controller = StackPanelController(store: store, senses: driver.senses(shrinkDelay: 2), hidden: true)
        driver.controller = controller
        let shots = try (0..<4).map { try folder.file("Screenshot \($0).png") }
        let report = DevCopy.reachForMore(store: store, controller: controller, driver: driver, captures: shots, waitFirst: 2.5)
        #expect(report.target != .more)
        #expect(!store.expanded)
    }
}

/// Card keys are claimed while the mouse moves on a card and let go once it rests, so a parked mouse
/// never takes keys you're typing elsewhere. Scripted: no real hot keys are registered.
@MainActor @Suite(.serialized) struct CardKeyTimingTests {
    @Test func keysAreClaimedWhileTheMouseMovesAndLetGoWhenItRests() throws {
        let folder = try TempFolder()
        let shot = Shot(url: try folder.file("Screenshot.png"), created: Date())
        var now = Date(timeIntervalSinceReferenceDate: 0)
        var mouse = NSPoint(x: 10, y: 10)
        var claims: [Bool] = []
        CardKeys.senses = CardKeys.Senses(now: { now }, pointer: { mouse }, isOnStack: { $0 === shot },
                                          claim: { claims.append($0) }, polls: false)
        defer { CardKeys.senses = .live }
        CardKeys.hover(shot)
        #expect(claims == [true])
        now += 2.9; CardKeys.tick()
        #expect(claims == [true])
        now += 0.2; CardKeys.tick()
        #expect(claims == [true, false], "a parked mouse lets go of the keys")
        mouse.x += 3; now += 0.25; CardKeys.tick()
        #expect(claims == [true, false, true], "moving again claims them back")
        CardKeys.leave(shot)
        #expect(claims == [true, false, true, false])
    }

    @Test func aCardThatLeftTheStackLetsGoOfTheKeys() throws {
        let folder = try TempFolder()
        let shot = Shot(url: try folder.file("Screenshot.png"), created: Date())
        var onStack = true
        var claims: [Bool] = []
        CardKeys.senses = CardKeys.Senses(now: { Date(timeIntervalSinceReferenceDate: 0) }, pointer: { .zero },
                                          isOnStack: { _ in onStack }, claim: { claims.append($0) }, polls: false)
        defer { CardKeys.senses = .live }
        CardKeys.hover(shot)
        onStack = false
        CardKeys.tick()
        #expect(claims == [true, false])
    }
}
