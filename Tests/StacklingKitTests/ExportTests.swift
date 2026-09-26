import AppKit
import Foundation
import Testing
@testable import StacklingKit

/// Everything that leaves Stackling must carry its edits, so a hidden secret can't slip out in the original.
@MainActor
struct ExportTests {
    private func whitePicture(in folder: TempFolder) throws -> URL {
        let url = folder.url.appendingPathComponent("Screenshot 2026-09-25 at 10.00.00.png")
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private func blackBox() -> Markup {
        var markup = Markup()
        markup.items.append(Annotation(tool: .redact, points: [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 100)],
                                       color: RGBA.redactFill, width: 4, solid: true))
        return markup
    }

    private func centreBrightness(_ url: URL) throws -> CGFloat {
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        return try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)?.brightnessComponent)
    }

    @Test func aShotWithoutEditsIsSharedAsItIs() throws {
        let folder = try TempFolder()
        let shot = try whitePicture(in: folder)
        #expect(Export.url(for: shot) == shot)
    }

    @Test func hiddenSecretsAreDrawnIntoWhatIsShared() throws {
        let folder = try TempFolder()
        let shot = try whitePicture(in: folder)
        blackBox().save(for: shot)

        let shared = try #require(Export.url(for: shot))
        #expect(shared != shot, "never the untouched original")
        #expect(try centreBrightness(shot) > 0.9)
        #expect(try centreBrightness(shared) < 0.1, "the black box is in the pixels")
    }

    @Test func theCopyIsReusedUntilTheEditsChange() throws {
        let folder = try TempFolder()
        let shot = try whitePicture(in: folder)
        blackBox().save(for: shot)
        let first = try #require(Export.url(for: shot))
        let made = try #require(first.modificationDate)
        #expect(Export.url(for: shot)?.modificationDate == made, "no redraw when nothing changed")

        // Newer edits (here: all removed but beautify on) must produce a fresh copy.
        Thread.sleep(forTimeInterval: 1.1)
        var edited = Markup()
        edited.beautify.enabled = true
        edited.save(for: shot)
        let second = try #require(Export.url(for: shot))
        #expect(try #require(second.modificationDate) > made)
    }
}
