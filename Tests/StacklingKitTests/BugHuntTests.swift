import AppKit
import SwiftUI
import Testing
@testable import StacklingKit

@MainActor
struct SharingFailureTests {
    @Test func failedRenderNeverReturnsTheOriginal() throws {
        let folder = try TempFolder()
        let url = folder.url.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: url)
        #expect(coveredImage().save(for: url))
        #expect(Export.url(for: url) == nil)
        #expect(Export.urls(for: [url]) == nil)
    }

    @Test func failedExportWriteNeverReturnsTheOriginal() throws {
        let folder = try TempFolder()
        let url = try makePicture(in: folder)
        coveredImage().save(for: url)
        let exported = try #require(Export.url(for: url))
        let cache = exported.deletingLastPathComponent()
        try FileManager.default.removeItem(at: exported)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cache.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cache.path) }
        #expect(Export.url(for: url) == nil)
    }

    @Test func corruptEditsStopSharing() throws {
        let folder = try TempFolder()
        let url = try makePicture(in: folder)
        try Data("broken edits".utf8).write(to: Markup.sidecarURL(for: url))
        #expect(Export.url(for: url) == nil)
        #expect(!Clipboard.write(shot: Shot(url: url)), "a failed copy leaves the clipboard alone")
        #expect(LibraryDrag.writer(for: url) == nil)
    }

    @Test func explicitEditsCannotReuseADifferentCachedImage() throws {
        let folder = try TempFolder()
        let url = try makePicture(in: folder)
        var first = Markup(); first.beautify.enabled = true
        _ = try #require(Export.url(for: url, markup: first))
        let covered = try #require(Export.url(for: url, markup: coveredImage()))
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: covered)))
        #expect(try #require(rep.colorAt(x: 100, y: 50)?.usingColorSpace(.deviceRGB)).brightnessComponent < 0.1)
    }

    @Test func previewEditsCannotReplaceTheSavedRedactionsInTheCache() throws {
        let folder = try TempFolder()
        let url = try makePicture(in: folder)
        coveredImage().save(for: url)
        let saved = try #require(Export.url(for: url))
        var preview = Markup(); preview.beautify.enabled = true
        let previewURL = try #require(Export.url(for: url, markup: preview))
        #expect(previewURL != saved)
        let shared = try #require(Export.url(for: url))
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: shared)))
        #expect(try #require(rep.colorAt(x: 100, y: 50)?.usingColorSpace(.deviceRGB)).brightnessComponent < 0.1)
    }

    @Test func failedSaveLeavesTheShotUnchanged() throws {
        let folder = try TempFolder()
        let shot = Shot(url: try makePicture(in: folder))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.url.path) }
        #expect(!shot.setMarkup(coveredImage()))
        #expect(!shot.hasMarkup)
        #expect(!Markup.hasEdits(shot.url))
    }

    @Test func failedRemovalKeepsTheSavedEditsInMemory() throws {
        let folder = try TempFolder()
        let shot = Shot(url: try makePicture(in: folder))
        #expect(shot.setMarkup(coveredImage()))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.url.path) }
        #expect(!shot.setMarkup(Markup()))
        #expect(shot.hasMarkup)
        #expect(Markup.hasEdits(shot.url))
    }
}

@MainActor
struct FilingRegressionTests {
    @Test func editedDragFilesTheOriginalAndSharesTheRenderedCopy() async throws {
        let folder = try TempFolder()
        let url = try makePicture(in: folder)
        let edits = coveredImage()
        edits.save(for: url)
        let writer = try #require(LibraryDrag.writer(for: url))
        let token = try #require(writer.string(forType: LibraryDrag.originalType))
        #expect(UUID(uuidString: token) != nil)
        let externalString = try #require(writer.string(forType: .fileURL))
        let external = try #require(URL(string: externalString))
        #expect(external != url)
        let provider = NSItemProvider()
        for type in writer.types {
            let data = try #require(writer.data(forType: type))
            provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { done in
                done(data, nil)
                return nil
            }
        }
        let urls = await LibraryDrag.urls(from: [provider])
        #expect(urls == [url])
        let dest = folder.url.appendingPathComponent("Filed")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let moved = try Library.move(try #require(urls.first), into: dest)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(Markup.load(for: moved) == edits)
        #expect(Markup.load(for: moved)?.items.first?.solid == true)
    }

    @Test func finderFileURLsStillLoadForDrops() async throws {
        let url = URL(fileURLWithPath: "/tmp/A picture.png")
        let provider = NSItemProvider(object: url as NSURL)
        #expect(await LibraryDrag.urls(from: [provider]) == [url])
    }

    @Test func sidecarCollisionDoesNotSeparateTheOriginalFromItsEdits() throws {
        let folder = try TempFolder()
        let url = try makePicture(in: folder)
        let edits = coveredImage()
        edits.save(for: url)
        let dest = folder.url.appendingPathComponent("destination.png")
        var stale = Markup(); stale.beautify.enabled = true
        stale.save(for: dest)
        #expect(throws: (any Error).self) { try Library.move(url, to: dest) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(Markup.load(for: url) == edits)
        #expect(Markup.load(for: dest) == stale)
    }

    @Test func movingAnUnopenedLegacyShotKeepsItsRedactions() throws {
        let folder = try TempFolder()
        let url = try makePicture(in: folder)
        let edits = coveredImage()
        try JSONEncoder().encode(edits).write(to: Markup.legacySidecarURL(for: url))
        let dest = folder.url.appendingPathComponent("moved.png")
        try Library.move(url, to: dest)
        #expect(Markup.load(for: dest) == edits)
        #expect(!Markup.hasEdits(url))
    }

    @Test func aFailedSidecarMoveRollsTheImageBack() throws {
        let folder = try TempFolder()
        let url = try makePicture(in: folder)
        let edits = coveredImage()
        edits.save(for: url)
        let sidecar = Markup.sidecarURL(for: url)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: sidecar.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: sidecar.path) }
        let dest = folder.url.appendingPathComponent("moved.png")
        #expect(throws: (any Error).self) { try Library.move(url, to: dest) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(Markup.load(for: url) == edits)
    }

    @Test func flatteningAJPEGKeepsItsFileFormat() throws {
        let folder = try TempFolder()
        let url = try makePicture(in: folder, jpeg: true)
        let shot = Shot(url: url)
        shot.setMarkup(coveredImage())
        Actions.flatten(shot)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        #expect(!shot.hasMarkup)
        #expect(!Markup.hasEdits(url))
    }
}

@MainActor
struct EditorInteractionTests {
    @Test func anEmptyGesturePreservesRedo() throws {
        let folder = try TempFolder()
        let model = try #require(EditorModel(shot: Shot(url: makePicture(in: folder))))
        let canvas = CanvasView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        canvas.mouseDown(with: mouse(.leftMouseDown, x: 300, y: 200))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, x: 400, y: 250))
        canvas.mouseUp(with: mouse(.leftMouseUp, x: 400, y: 250))
        let arrow = model.markup
        #expect(arrow.items.count == 1)
        canvas.undo(nil)
        #expect(model.canRedo)
        canvas.mouseDown(with: mouse(.leftMouseDown, x: 350, y: 200))
        canvas.mouseUp(with: mouse(.leftMouseUp, x: 350, y: 200))
        #expect(model.canRedo)
        canvas.redo(nil)
        #expect(model.markup == arrow)
    }

    @Test func sliderGestureUndoesAsOneStep() throws {
        let folder = try TempFolder()
        let model = try #require(EditorModel(shot: Shot(url: makePicture(in: folder))))
        model.updateBeautify { $0.enabled = true }
        let before = model.markup
        model.checkpoint()
        model.updateBeautify(checkpoint: false) { $0.padding = 0.12 }
        model.updateBeautify(checkpoint: false) { $0.padding = 0.18 }
        model.undo()
        #expect(model.markup == before)
        model.redo()
        #expect(model.markup.beautify.padding == 0.18)
    }

    private func mouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                          windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
}

private func makePicture(in folder: TempFolder, jpeg: Bool = false) throws -> URL {
    let url = folder.url.appendingPathComponent(jpeg ? "picture.jpg" : "picture.png")
    let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: jpeg ? .jpeg : .png, properties: [:])!.write(to: url)
    return url
}

private func coveredImage() -> Markup {
    Markup(items: [Annotation(tool: .redact, points: [.zero, CGPoint(x: 200, y: 100)], color: .redactFill, width: 4, solid: true)])
}
