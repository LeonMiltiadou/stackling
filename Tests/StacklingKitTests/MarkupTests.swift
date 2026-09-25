import AppKit
import Testing
@testable import StacklingKit

@Suite struct RGBATests {
    @Test func paleColoursAreLight() {
        #expect(RGBA(1, 1, 1).isLight)
        #expect(RGBA(1.00, 0.80, 0.70).isLight)
        #expect(!RGBA(1.00, 0.80, 0.00).isLight)
        #expect(!RGBA.redactFill.isLight)
    }
}

@Suite struct AnnotationTests {
    @Test func hollowShapesAreGrabbedByTheirOutline() {
        let box = Annotation(tool: .rect, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)], color: RGBA.palette[0], width: 4)
        #expect(box.hitTest(CGPoint(x: 2, y: 50), tolerance: 6))
        #expect(!box.hitTest(CGPoint(x: 50, y: 50), tolerance: 6))
    }

    @Test func linesAreGrabbedNearTheSegment() {
        let line = Annotation(tool: .line, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], color: RGBA.palette[0], width: 2)
        #expect(line.hitTest(CGPoint(x: 50, y: 5), tolerance: 6))
        #expect(!line.hitTest(CGPoint(x: 50, y: 10), tolerance: 6))
    }
}

@Suite struct MarkupSidecarTests {
    let dir: URL
    let image: URL
    let markup = Markup(items: [Annotation(tool: .arrow, points: [.zero, CGPoint(x: 10, y: 10)], color: RGBA.palette[1], width: 9)])

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        image = dir.appendingPathComponent("shot.png")
    }

    private func sidecarExists(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: Markup.sidecarURL(for: url).path)
    }

    @Test func sidecarIsAHiddenFileBesideTheImage() {
        #expect(Markup.sidecarURL(for: image) == dir.appendingPathComponent(".shot.png.stackling"))
    }

    @Test func savesAndLoads() {
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Markup.load(for: image) == nil)
        markup.save(for: image)
        #expect(Markup.load(for: image) == markup)
    }

    @Test func savingNothingRemovesTheSidecar() {
        defer { try? FileManager.default.removeItem(at: dir) }
        markup.save(for: image)
        Markup().save(for: image)
        #expect(!sidecarExists(for: image))
    }

    @Test func unreadableSidecarLoadsAsNothing() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: Markup.sidecarURL(for: image))
        #expect(Markup.load(for: image) == nil)
    }

    @Test func sidecarMovesWithTheImage() {
        defer { try? FileManager.default.removeItem(at: dir) }
        let moved = dir.appendingPathComponent("moved.png")
        markup.save(for: image)
        Markup.moveSidecar(from: image, to: moved)
        #expect(!sidecarExists(for: image))
        #expect(Markup.load(for: moved) == markup)
    }

    @Test func deletesTheSidecar() {
        defer { try? FileManager.default.removeItem(at: dir) }
        markup.save(for: image)
        Markup.deleteSidecar(for: image)
        #expect(!sidecarExists(for: image))
        Markup.deleteSidecar(for: image)
    }
}

@Suite struct ImageFileTests {
    private func solidImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    @Test func pngKeepsItsSizeAndPixelScale() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageFile.writePNG(solidImage(width: 40, height: 20), to: url, pixelScale: 2)
        let loaded = try #require(ImageFile.load(url))
        #expect(loaded.width == 40 && loaded.height == 20)
        #expect(ImageFile.pixelScale(url) == 2)
    }

    @Test func missingFilesLoadAsNothing() {
        #expect(ImageFile.load(URL(fileURLWithPath: "/nope/missing.png")) == nil)
        #expect(ImageFile.pixelScale(URL(fileURLWithPath: "/nope/missing.png")) == 2)
    }

    @MainActor
    @Test func beautifyPaddingGrowsTheRenderedImage() throws {
        var markup = Markup()
        markup.beautify.enabled = true
        let base = solidImage(width: 100, height: 50)
        let rendered = try #require(MarkupRenderer.render(base: base, markup: markup))
        #expect(rendered.width == 116 && rendered.height == 66)
    }
}
