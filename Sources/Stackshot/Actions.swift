import AppKit
import UniformTypeIdentifiers
import Vision

@MainActor
enum Actions {
    static var store: ShotStore { .shared }

    static func copy(_ shot: Shot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        let file = shot.isVideo ? shot.url : shot.exportURL()
        if !shot.isVideo, let data = try? Data(contentsOf: file) {
            let type = UTType(filenameExtension: file.pathExtension) ?? .png
            if type.conforms(to: .png) {
                item.setData(data, forType: .png)
            } else if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
        }
        item.setString(file.absoluteString, forType: .fileURL)
        pb.writeObjects([item])
        store.finish(shot, message: "Copied")
    }

    /// Writes the annotations into the image file for good and removes the sidecar.
    static func flatten(_ shot: Shot) {
        guard let markup = shot.markup, !markup.isEmpty,
              let base = MarkupRenderer.loadImage(shot.url),
              let rendered = MarkupRenderer.render(base: base, markup: markup) else { return }
        do {
            try MarkupRenderer.writePNG(rendered, to: shot.url, pixelScale: MarkupRenderer.pixelScale(shot.url))
            shot.setMarkup(Markup())
            shot.flash("Saved into image")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func copyText(_ shot: Shot) {
        shot.flash("Reading text…", for: 10)
        let url = shot.url
        Task {
            let text = await recognizeText(at: url)
            if let text, !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                store.finish(shot, message: "Text copied")
            } else {
                shot.flash("No text found")
            }
        }
    }

    nonisolated static func recognizeText(at url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                return nil
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }

    /// Opens the Stackshot editor. Videos open in their default app.
    static func edit(_ shot: Shot) {
        if shot.isVideo {
            NSWorkspace.shared.open(shot.url)
            return
        }
        EditorWindowController.open(shot)
    }

    static func pin(_ shot: Shot) {
        guard !shot.isVideo, let image = NSImage(contentsOf: shot.exportURL()) else { return }
        PinWindow.show(image, shot: shot)
        store.finish(shot, message: "Pinned")
    }

    static func openInPreview(_ shot: Shot) {
        if shot.isVideo {
            NSWorkspace.shared.open(shot.url)
            return
        }
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([shot.url], withApplicationAt: preview, configuration: config)
    }

    static func reveal(_ shot: Shot) {
        NSWorkspace.shared.activateFileViewerSelecting([shot.url])
    }

    static func copyPath(_ shot: Shot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shot.url.path, forType: .string)
        shot.flash("Path copied")
    }

    static func moveTo(_ shot: Shot) {
        NSApp.activate()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = shot.url.lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: shot.url.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.trashItem(at: dest, resultingItemURL: nil)
            }
            try FileManager.default.moveItem(at: shot.url, to: dest)
            let sidecar = Markup.sidecarURL(for: shot.url)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.moveItem(at: sidecar, to: Markup.sidecarURL(for: dest))
            }
            shot.url = dest
            store.dismiss(shot)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func shareServices(for shot: Shot) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: [shot.url])
    }

    static func share(_ shot: Shot, with service: NSSharingService) {
        NSApp.activate()
        service.perform(withItems: [shot.exportURL()])
        store.dismiss(shot)
    }
}
