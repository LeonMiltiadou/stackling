import CoreGraphics
import Testing
@testable import StacklingKit

@Suite struct CaptureLoupeTests {
    let screen = CGSize(width: 1000, height: 800)

    @Test func sitsBelowRightOfTheCursor() {
        let frame = Loupe.frame(near: CGPoint(x: 100, y: 100), in: screen)
        #expect(frame.origin == CGPoint(x: 122, y: 122))
        #expect(frame.size == CGSize(width: 132, height: 132))
    }

    @Test func flipsLeftNearTheRightEdge() {
        let frame = Loupe.frame(near: CGPoint(x: 900, y: 100), in: screen)
        #expect(frame.minX == CGFloat(900 - 22 - 132))
        #expect(frame.minY == 122)
    }

    @Test func flipsUpNearTheBottomLeavingRoomForTheLabel() {
        let frame = Loupe.frame(near: CGPoint(x: 100, y: 700), in: screen)
        #expect(frame.minY == CGFloat(700 - 22 - 132 - 44))
    }

    @Test func pixelUnderTheCursorRoundsDown() {
        let pixel = Loupe.pixel(under: CGPoint(x: 10.6, y: 3.9), pixelsPerPoint: 2)
        #expect(pixel.x == 21 && pixel.y == 7)
    }

    @Test func sourceRectCentresOnThePixel() {
        let rect = Loupe.sourceRect(around: (x: 20, y: 30))
        #expect(rect == CGRect(x: 13, y: 23, width: 15, height: 15))
        #expect(rect.midX == 20.5 && rect.midY == 30.5)
    }
}
