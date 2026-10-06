import AppKit
import Testing
@testable import StacklingKit

@Suite struct StackLayoutTests {
    let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)

    @Test func oneCardHasNoPillOrGhosts() {
        #expect(Layout.collapsedHeight(1) == Layout.pad + Layout.cardH + Layout.pad)
    }

    @Test func collapsedStackShowsAPillAndAtMostTwoGhosts() {
        let pill = Layout.pillH + Layout.pillSpacing
        #expect(Layout.collapsedHeight(2) == Layout.pad * 2 + pill + Layout.ghostStep + Layout.cardH)
        #expect(Layout.collapsedHeight(3) == Layout.collapsedHeight(10))
    }

    @Test func listHeightStopsAtTheMaximum() {
        #expect(Layout.listHeight(1, max: 10_000) == Layout.cardH + Layout.listVPad * 2)
        #expect(Layout.listHeight(50, max: 500) == 500)
    }

    @Test func aFullExpandedStackFillsTheScreenLessItsMargins() {
        let maxList = Layout.maxListHeight(in: visible)
        let tallest = Layout.expandedHeight(100, maxList: maxList)
        #expect(tallest == visible.height - Layout.screenMargin * 2 - Layout.listVPad)
    }

    @Test func cornerOriginSitsJustInsideTheVisibleArea() {
        #expect(Layout.cornerOrigin(in: visible) == NSPoint(x: Layout.screenMargin, y: 25 + Layout.screenMargin))
    }

    @Test func minimizedPanelIsTheLittleBox() {
        let size = Layout.panelSize(count: 5, expanded: true, minimized: true, maxList: 600)
        #expect(size == CGSize(width: Layout.miniW + Layout.pad * 2, height: Layout.miniH + Layout.pad * 2))
    }

    @MainActor @Test func targetFrameDefaultsToTheCorner() {
        let frame = StackPanelController.targetFrame(count: 1, expanded: false, minimized: false, origin: nil, visible: visible)
        #expect(frame.origin == Layout.cornerOrigin(in: visible))
        #expect(frame.size == CGSize(width: Layout.panelWidth, height: Layout.collapsedHeight(1)))
    }

    @MainActor @Test func targetFrameKeepsACustomOriginOnScreen() {
        let offRight = StackPanelController.targetFrame(count: 1, expanded: false, minimized: false,
                                                         origin: NSPoint(x: 5000, y: -300), visible: visible)
        #expect(offRight.maxX == visible.maxX + Layout.pad)
        #expect(offRight.minY == visible.minY - Layout.pad)

        let inside = NSPoint(x: 400, y: 300)
        let kept = StackPanelController.targetFrame(count: 1, expanded: false, minimized: false, origin: inside, visible: visible)
        #expect(kept.origin == inside)
    }

    @MainActor @Test func targetFrameNeverOutgrowsTheScreen() {
        let small = CGRect(x: 0, y: 0, width: 800, height: 200)
        let frame = StackPanelController.targetFrame(count: 3, expanded: false, minimized: false, origin: nil, visible: small)
        #expect(frame.height == small.height)
    }

    /// The stack shrinks after a quiet spell, but not out from under a pointer reaching for "N more":
    /// the pill would vanish and the click land on nothing.
    @MainActor @Test func aPointerOnOrHeadingForTheStackKeepsItOpen() {
        let stack = StackPanelController.targetFrame(count: 4, expanded: false, minimized: false, origin: nil, visible: visible)
        let pill = NSPoint(x: stack.minX + Layout.pad + 50, y: stack.maxY - Layout.pad - Layout.pillH / 2)
        func keeps(_ pointer: NSPoint, from previous: NSPoint?) -> Bool {
            StackPanelController.pointerKeepsOpen(pointer, previous: previous, stack: stack)
        }
        #expect(keeps(pill, from: pill))
        #expect(keeps(NSPoint(x: 400, y: 560), from: NSPoint(x: 600, y: 700)), "heading for the pill")
        #expect(keeps(NSPoint(x: 120, y: 410), from: NSPoint(x: 200, y: 480)), "the last stretch")
        #expect(!keeps(NSPoint(x: 600, y: 700), from: NSPoint(x: 400, y: 560)), "moving away")
        #expect(!keeps(NSPoint(x: 900, y: 600), from: NSPoint(x: 900, y: 600)), "resting elsewhere")
        #expect(!keeps(NSPoint(x: 599, y: 699), from: NSPoint(x: 600, y: 700)), "a hand on the mouse")
        #expect(!keeps(NSPoint(x: 900, y: 600), from: nil), "the first look, far away")
    }

    /// The stack in a panel that's built but never ordered in, as Stackling Dev has it. AppKit only finds
    /// the cards' views when hit-testing inside a window; no window manager sees one that was never shown.
    @MainActor private func hiddenPanel(for store: ShotStore, size: CGSize) -> (StackPanel, NSView) {
        let panel = StackPanel()
        let host = StackPanelController.makeHost(for: store)
        panel.contentView = host
        panel.setFrame(CGRect(origin: .zero, size: size), display: false)
        host.layoutSubtreeIfNeeded()
        return (panel, host)
    }

    /// The panel never becomes key, so the view a click lands on must take the first click itself, or a
    /// click on "N more" can be used up just bringing the panel forward. Aims at where each button is laid
    /// out and checks it's what's there: this test once aimed with the y flipped and hit the card instead.
    @MainActor @Test func theStackTakesTheFirstClick() throws {
        let folder = try TempFolder()
        let store = ShotStore()
        for name in ["a", "b", "c", "d"] { store.add(try folder.file("Screenshot \(name).png")) }
        func firstClick(on target: StackTarget) throws -> Bool? {
            let size = StackPanelController.targetFrame(count: 4, expanded: false, minimized: store.minimized, origin: nil, visible: visible).size
            let (panel, host) = hiddenPanel(for: store, size: size)
            defer { withExtendedLifetime(panel) {} }
            let frame = try #require(store.targetFrames[target], "\(target) is laid out")
            let aimed = StackPanelController.aim(at: NSPoint(x: frame.midX, y: frame.midY), in: host, store: store)
            #expect(aimed.target == target, "\(target) is what's under its own middle, not a card")
            return aimed.hit?.acceptsFirstMouse(for: nil)
        }
        #expect(try firstClick(on: .more) == true, "the \"3 more\" pill")
        store.setMinimized(true, reason: "idle")
        #expect(try firstClick(on: .shrunk) == true, "the shrunk box")
    }

    /// A point on the card is the card's drag surface, not a stack button, so aiming can tell them apart.
    @MainActor @Test func aimingAtTheCardFindsTheCard() throws {
        let folder = try TempFolder()
        let store = ShotStore()
        for name in ["a", "b", "c", "d"] { store.add(try folder.file("Screenshot \(name).png")) }
        let size = StackPanelController.targetFrame(count: 4, expanded: false, minimized: false, origin: nil, visible: visible).size
        let (panel, host) = hiddenPanel(for: store, size: size)
        defer { withExtendedLifetime(panel) {} }
        let aimed = StackPanelController.aim(at: NSPoint(x: size.width / 2, y: size.height - Layout.pad - 20), in: host, store: store)
        #expect(aimed.target == nil)
        #expect(aimed.hit is DragSurfaceView)
    }
}
