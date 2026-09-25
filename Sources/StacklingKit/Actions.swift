import AppKit
import UniformTypeIdentifiers
import Vision

/// Everything you can do with a card, from its buttons, its menu, its keys, the editor and the preview.
@MainActor
enum Actions {
    static var store: ShotStore { .shared }

    /// Making a GIF can take a while for a long recording. The "working" message gives up after this.
    static let gifToastTimeout: TimeInterval = 120
    /// Same for reading text, which is quicker.
    static let textToastTimeout: TimeInterval = 10

    static func copy(_ shot: Shot) {
        note("copy", shot)
        Clipboard.write(shot: shot)
        store.finish(shot, message: "Copied")
    }

    /// Image data (with edits) for apps that paste pictures, plus the file for apps that take files.
    static func writeToPasteboard(_ shot: Shot) {
        Clipboard.write(shot: shot)
    }

    /// Files a shot into a library folder and takes it off the stack.
    static func file(_ shot: Shot, into folder: URL) {
        note("file", shot)
        guard Library.file(shot, into: folder) else { return }
        store.finish(shot, message: "Filed in \(folder.lastPathComponent)")
    }

    static func fileIntoNewFolder(_ shot: Shot) {
        note("file-into-new-folder", shot)
        guard let folder = Library.askForNewFolder() else { return }
        file(shot, into: folder)
    }

    /// Makes a GIF of a recording and puts it on the clipboard.
    /// Asks Claude Code for a descriptive name and renames the file where it is. The card stays put.
    static func nameWithClaude(_ shot: Shot) {
        Log.actions.info("name-with-claude file=\(shot.url.lastPathComponent, privacy: .public)")
        shot.flashWorking("Asking Claude…", timeout: 120)
        Task {
            do {
                let folder = shot.url.deletingLastPathComponent()
                let suggestions = try await ClaudeCode.suggest(for: [shot.url], in: folder, existingFolders: [], model: AppSettings.claudeModel)
                guard let entry = GroomPlan.entries(for: [shot.url], suggestions: suggestions).first, !entry.name.isEmpty else {
                    shot.flashFailed("No name suggested")
                    return
                }
                let dest = CaptureFile.freeURL(for: "\(entry.name).\(shot.url.pathExtension)", in: folder)
                try Library.move(shot.url, to: dest)
                ShotStore.shared.relocate([shot.url.standardizedFileURL: dest])
                shot.flashDone("Renamed")
            } catch {
                Log.actions.error("name-with-claude.failed error=\(error.localizedDescription, privacy: .public)")
                shot.flashFailed("Couldn't name it")
            }
        }
    }

    static func copyGIF(_ shot: Shot) {
        note("copy-gif", shot)
        shot.flashWorking("Making GIF…", timeout: gifToastTimeout)
        Task {
            do {
                let gif = try await GIFMaker.cached(for: shot)
                Clipboard.writeGIF(at: gif)
                store.finish(shot, message: "GIF copied")
            } catch {
                Log.actions.error("copy-gif.failed file=\(shot.url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                shot.flashFailed("Couldn't make a GIF")
            }
        }
    }

    /// Saves a GIF next to the recording. It lands on the stack as its own card.
    static func saveGIF(_ shot: Shot) {
        note("save-gif", shot)
        shot.flashWorking("Making GIF…", timeout: gifToastTimeout)
        let video = shot.url
        Task {
            do {
                let gif = try await GIFMaker.cached(for: shot)
                let out = CaptureFile.freeURL(
                    for: video.deletingPathExtension().lastPathComponent + ".gif",
                    in: video.deletingLastPathComponent()
                )
                try FileManager.default.copyItem(at: gif, to: out)
                shot.flashDone("GIF saved")
                store.add(out)
            } catch {
                Log.actions.error("save-gif.failed file=\(video.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                shot.flashFailed("Couldn't make a GIF")
            }
        }
    }

    static func openInQuickTime(_ shot: Shot) {
        note("open-in-quicktime", shot)
        open(shot.url, with: "/System/Applications/QuickTime Player.app")
    }

    /// Writes the annotations into the image file for good and removes the sidecar.
    static func flatten(_ shot: Shot) {
        note("flatten", shot)
        guard let rendered = shot.renderedWithMarkup() else { return }
        do {
            try MarkupRenderer.writePNG(rendered, to: shot.url, pixelScale: MarkupRenderer.pixelScale(shot.url))
            shot.setMarkup(Markup())
            shot.flashDone("Saved into image")
        } catch {
            Log.actions.error("flatten.failed file=\(shot.url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            NSAlert(error: error).runModal()
        }
    }

    static func copyText(_ shot: Shot) {
        note("copy-text", shot)
        shot.flashWorking("Reading text…", timeout: textToastTimeout)
        let url = shot.url
        Task {
            let text = await recognizeText(at: url)
            if let text, !text.isEmpty {
                Clipboard.write(string: text)
                store.finish(shot, message: "Text copied")
            } else {
                Log.actions.info("copy-text.empty file=\(url.lastPathComponent, privacy: .public)")
                // A tick, not a warning: finding nothing isn't an error.
                shot.flashDone("No text found")
            }
        }
    }

    nonisolated static func recognizeText(at url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                Log.actions.error("copy-text.unreadable file=\(url.lastPathComponent, privacy: .public)")
                return nil
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                Log.actions.error("copy-text.failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return nil
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }

    /// Opens the Stackling editor. Recordings and GIFs open in the preview instead.
    static func edit(_ shot: Shot) {
        note("edit", shot)
        if !shot.isStill {
            PreviewWindowController.show(shot)
            return
        }
        EditorWindowController.open(shot)
    }

    static func pin(_ shot: Shot) {
        note("pin", shot)
        guard !shot.isVideo, let image = NSImage(contentsOf: shot.exportURL()) else { return }
        PinWindow.show(image, shot: shot)
        store.finish(shot, message: "Pinned")
    }

    static func openInPreview(_ shot: Shot) {
        note("open-in-preview", shot)
        if shot.isVideo {
            NSWorkspace.shared.open(shot.url)
            return
        }
        open(shot.url, with: "/System/Applications/Preview.app")
    }

    static func reveal(_ shot: Shot) {
        note("reveal", shot)
        NSWorkspace.shared.activateFileViewerSelecting([shot.url])
    }

    static func copyPath(_ shot: Shot) {
        note("copy-path", shot)
        Clipboard.write(string: shot.url.path)
        shot.flashDone("Path copied")
    }

    static func moveTo(_ shot: Shot) {
        note("move-to", shot)
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
            try Library.move(shot.url, to: dest)
            shot.url = dest
            Log.actions.info("move-to.done dest=\(dest.path, privacy: .public)")
            store.dismiss(shot)
        } catch {
            Log.actions.error("move-to.failed file=\(shot.url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            NSAlert(error: error).runModal()
        }
    }

    static func shareServices(for shot: Shot) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: [shot.url])
    }

    static func share(_ shot: Shot, with service: NSSharingService) {
        Log.actions.info("share file=\(shot.url.lastPathComponent, privacy: .public) service=\(service.title, privacy: .public)")
        NSApp.activate()
        service.perform(withItems: [shot.exportURL()])
        store.dismiss(shot)
    }

    // MARK: Helpers

    private static func open(_ url: URL, with appPath: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: appPath), configuration: config)
    }

    /// Logs which action ran on which file.
    private static func note(_ action: String, _ shot: Shot) {
        Log.actions.info("\(action, privacy: .public) file=\(shot.url.lastPathComponent, privacy: .public)")
    }
}
