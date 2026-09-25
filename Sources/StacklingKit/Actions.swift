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
        note(.copy, shot)
        Clipboard.write(shot: shot)
        Usage.used(shot.url, how: "copy")
        store.finish(shot, message: "Copied")
    }

    /// Image data (with edits) for apps that paste pictures, plus the file for apps that take files.
    static func writeToPasteboard(_ shot: Shot) {
        Clipboard.write(shot: shot)
    }

    /// Files a shot into a library folder and takes it off the stack.
    static func file(_ shot: Shot, into folder: URL) {
        note(.file, shot)
        guard Library.file(shot, into: folder) else { return }
        store.finish(shot, message: "Filed in \(folder.lastPathComponent)")
    }

    /// Every shot as files, oldest first (edits drawn in), ready to drop into a PR or chat in order.
    static func copyAll(_ shots: [Shot]) {
        let ordered = shots.sorted { $0.created < $1.created }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(ordered.map { $0.exportURL() as NSURL })
        ordered.forEach { Usage.used($0.url, how: "copy-all") }
        Log.actions.info("copy-all count=\(ordered.count)")
        ActivityLog.record(.copyAll, ["count": ordered.count])
        ordered.last?.flashDone("Copied \(ordered.count)")
    }

    static func fileAll(_ shots: [Shot], into folder: URL) {
        Log.actions.info("file-all count=\(shots.count) folder=\(folder.lastPathComponent, privacy: .public)")
        ActivityLog.record(.fileAll, ["count": shots.count])
        for shot in shots { file(shot, into: folder) }
    }

    static func fileIntoNewFolder(_ shot: Shot) {
        note(.file, shot, ["folder": "new"])
        guard let folder = Library.askForNewFolder() else { return }
        file(shot, into: folder)
    }

    /// Makes a GIF of a recording and puts it on the clipboard.
    /// Asks Claude Code for a descriptive name and renames the file where it is. The card stays put.
    static func nameWithClaude(_ shot: Shot) {
        Log.actions.info("name-with-claude file=\(shot.url.lastPathComponent, privacy: .public)")
        ActivityLog.record(.nameWithClaude, activityDetails(for: shot))
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
        note(.copyGIF, shot)
        shot.flashWorking("Making GIF…", timeout: gifToastTimeout)
        Task {
            do {
                let gif = try await GIFMaker.cached(for: shot)
                Clipboard.writeGIF(at: gif)
                Usage.used(shot.url, how: "copy-gif")
                if GIFMaker.isTooBigToShare(gif) {
                    // Keep the card: it'll need trimming before GitHub takes it.
                    shot.flashFailed("Copied · over 10 MB")
                } else {
                    store.finish(shot, message: "GIF copied")
                }
            } catch {
                Log.actions.error("copy-gif.failed file=\(shot.url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                shot.flashFailed("Couldn't make a GIF")
            }
        }
    }

    /// Saves a GIF next to the recording. It lands on the stack as its own card.
    static func saveGIF(_ shot: Shot, then done: ((Bool) -> Void)? = nil) {
        note(.saveGIF, shot)
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
                done?(true)
            } catch {
                Log.actions.error("save-gif.failed file=\(video.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                shot.flashFailed("Couldn't make a GIF")
                done?(false)
            }
        }
    }

    static func openInQuickTime(_ shot: Shot) {
        note(.openInApp, shot, ["app": "quicktime"])
        open(shot.url, with: "/System/Applications/QuickTime Player.app")
    }

    /// Writes the annotations into the image file for good and removes the sidecar.
    static func flatten(_ shot: Shot) {
        note(.flatten, shot)
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
        note(.copyText, shot)
        shot.flashWorking("Reading text…", timeout: textToastTimeout)
        let url = shot.url
        Task {
            let text = await recognizeText(at: url)
            if let text, !text.isEmpty {
                Clipboard.write(string: text)
                Usage.used(url, how: "copy-text")
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
                try await VisionWork.perform([request], on: image)
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
        note(shot.isStill ? .edit : .preview, shot)
        if !shot.isStill {
            PreviewWindowController.show(shot)
            return
        }
        EditorWindowController.open(shot)
    }

    /// Keep marks a shot so clean-up never clears it; pressing it again lets it go as normal.
    static func toggleKeep(_ shot: Shot) {
        shot.setKept(!shot.kept)
        ActivityLog.record(.keep, activityDetails(for: shot).merging(["on": shot.kept]) { a, _ in a })
        shot.flashDone(shot.kept ? "Kept" : "Not kept")
        LibraryIndex.shared.scheduleRescan()
    }

    static func pin(_ shot: Shot) {
        note(.pin, shot)
        guard !shot.isVideo, let image = NSImage(contentsOf: shot.exportURL()) else { return }
        Usage.used(shot.url, how: "pin")
        PinWindow.show(image, shot: shot)
        store.finish(shot, message: "Pinned")
    }

    static func openInPreview(_ shot: Shot) {
        note(.openInApp, shot, ["app": "preview"])
        if shot.isVideo {
            NSWorkspace.shared.open(shot.url)
            return
        }
        open(shot.url, with: "/System/Applications/Preview.app")
    }

    static func reveal(_ shot: Shot) {
        note(.reveal, shot)
        NSWorkspace.shared.activateFileViewerSelecting([shot.url])
    }

    static func copyPath(_ shot: Shot) {
        note(.copyPath, shot)
        // With edits, the path is to a copy with them drawn in, so a hidden secret stays hidden.
        Clipboard.write(string: shot.exportURL().path)
        Usage.used(shot.url, how: "copy-path")
        shot.flashDone("Path copied")
    }

    static func moveTo(_ shot: Shot) {
        note(.moveTo, shot)
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
        ActivityLog.record(.share, activityDetails(for: shot).merging(["service": service.title]) { a, _ in a })
        NSApp.activate()
        service.perform(withItems: [shot.exportURL()])
        Usage.used(shot.url, how: "share")
        store.dismiss(shot)
    }

    // MARK: Helpers

    private static func open(_ url: URL, with appPath: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: appPath), configuration: config)
    }

    /// Logs which action ran on which file, and notes it in the activity log (without the file name):
    /// what kind of shot, and how long after it was taken.
    private static func note(_ event: ActivityLog.Event, _ shot: Shot, _ details: [String: Any] = [:]) {
        Log.actions.info("\(event.rawValue, privacy: .public) file=\(shot.url.lastPathComponent, privacy: .public)")
        ActivityLog.record(event, details.merging(activityDetails(for: shot)) { mine, _ in mine })
    }

    /// What the activity log keeps about a shot: its kind, age in seconds, and a random tag that links
    /// its events together (so "copied 6 s after it was taken" can be worked out). Never its name.
    static func activityDetails(for shot: Shot) -> [String: Any] {
        ["kind": shot.isVideo ? "video" : shot.isGIF ? "gif" : "still", "age": Int(Date().timeIntervalSince(shot.created)),
         "shot": String(shot.id.uuidString.prefix(8))]
    }
}
