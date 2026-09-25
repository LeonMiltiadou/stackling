import AppKit
import Testing
@testable import StackshotKit

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
}
