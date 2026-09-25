import CoreGraphics
import Testing
@testable import StackshotKit

@Suite struct CanvasGeometryTests {
    /// A 2000×1000 Retina capture in a view with exactly 1000×500 points to spare.
    let retina = CanvasGeometry(imageSize: CGSize(width: 2000, height: 1000), pad: 0, viewSize: CGSize(width: 1056, height: 556), pixelScale: 2)

    @Test func fitsTheImageInsideTheInset() {
        #expect(retina.scale == 0.5)
        #expect(retina.contentOrigin == CGPoint(x: 28, y: 28))
        #expect(retina.imageOrigin == CGPoint(x: 28, y: 28))
    }

    @Test func neverShowsTheImageBiggerThanItsRealSize() {
        let small = CanvasGeometry(imageSize: CGSize(width: 200, height: 100), pad: 0, viewSize: CGSize(width: 1000, height: 800), pixelScale: 2)
        #expect(small.scale == 0.5)
        #expect(small.contentOrigin == CGPoint(x: 450, y: 375))
    }

    @Test func aTinyViewStillHasAUsableScale() {
        let tiny = CanvasGeometry(imageSize: CGSize(width: 200, height: 100), pad: 0, viewSize: CGSize(width: 40, height: 40), pixelScale: 1)
        #expect(tiny.scale == 0.01)
    }

    @Test func paddingShiftsTheImageInsideTheContent() {
        let padded = CanvasGeometry(imageSize: CGSize(width: 1000, height: 1000), pad: 100, viewSize: CGSize(width: 656, height: 656), pixelScale: 1)
        #expect(padded.contentSize == CGSize(width: 1200, height: 1200))
        #expect(padded.scale == 0.5)
        #expect(padded.contentOrigin == CGPoint(x: 28, y: 28))
        #expect(padded.imageOrigin == CGPoint(x: 78, y: 78))
    }

    @Test func convertsBetweenViewAndImagePoints() {
        #expect(retina.toView(CGPoint(x: 200, y: 100)) == CGPoint(x: 128, y: 78))
        #expect(retina.toImage(CGPoint(x: 128, y: 78)) == CGPoint(x: 200, y: 100))
        #expect(retina.toView(CGRect(x: 0, y: 0, width: 100, height: 40)) == CGRect(x: 28, y: 28, width: 50, height: 20))
    }

    @Test func conversionsRoundTrip() {
        let padded = CanvasGeometry(imageSize: CGSize(width: 1234, height: 567), pad: 37, viewSize: CGSize(width: 900, height: 700), pixelScale: 2)
        let p = CGPoint(x: 321, y: 123)
        let back = padded.toImage(padded.toView(p))
        #expect(abs(back.x - p.x) < 0.0001 && abs(back.y - p.y) < 0.0001)
    }
}

@Suite struct StrokeSizeTests {
    @Test func valuesMatchTheToolbar() {
        #expect(StrokeSize.allCases.map(\.width) == [2.5, 4.5, 8])
        #expect(StrokeSize.allCases.map(\.dotDiameter) == [5, 8, 12])
        #expect(StrokeSize.allCases.map(\.title) == ["Thin", "Medium", "Thick"])
        #expect(StrokeSize.allCases.map(\.key) == ["1", "2", "3"])
    }

    @Test func numberKeysPickASize() {
        #expect(StrokeSize(key: "1") == .thin)
        #expect(StrokeSize(key: "3") == .thick)
        #expect(StrokeSize(key: "4") == nil)
        #expect(StrokeSize(key: "a") == nil)
    }
}
