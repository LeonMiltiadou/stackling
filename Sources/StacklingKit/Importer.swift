import AppKit
import UniformTypeIdentifiers

/// Brings things into the stack that aren't brand-new captures, so every card feature works on them
/// too: an image someone sent you, an old screenshot, any video, or whatever's on the clipboard.
/// Files stay where they are; only the stack points at them.
@MainActor
enum Importer {
    /// What the stack can hold: pictures (including GIFs and PDFs) and videos.
    static let types: [UTType] = [.image, .movie, .pdf]

    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    /// Adds every supported file, newest-looking last so the first one ends up on top. Returns how many were added.
    @discardableResult
    static func add(_ urls: [URL], from source: String) -> Int {
        let supported = urls.filter(isSupported)
        let skipped = urls.count - supported.count
        var added = 0
        for url in supported.reversed() where ShotStore.shared.add(url, created: url.creationDate ?? Date()) {
            added += 1
        }
        Log.actions.info("import source=\(source, privacy: .public) added=\(added) skipped=\(skipped)")
        if skipped > 0 && added == 0 { NSSound.beep() }
        return added
    }

    /// Stackling › Add to Stack…: pick any pictures or videos, starting in the library.
    static func chooseFiles() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Add to Stack"
        panel.prompt = "Add"
        panel.message = "Pick pictures or videos to mark up, hide secrets in, turn into a GIF, or file away."
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = ScreenshotPrefs.screenshotFolder
        guard panel.runModal() == .OK else { return }
        add(panel.urls, from: "open-panel")
    }

    /// True when there's something on the clipboard that Paste to Stack can use.
    static var clipboardHasSomething: Bool {
        let pb = NSPasteboard.general
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
            || pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Stackling › Paste to Stack: copied files go straight in; a copied picture is saved into the
    /// library first (named like a screenshot, so tidying treats it the same way).
    static func pasteFromClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls, from: "clipboard-files")
            return
        }
        guard let image = NSImage(pasteboard: pb),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            Log.actions.notice("paste.nothing-usable")
            NSSound.beep()
            return
        }
        let url = CaptureFile.newURL(.pasted, ext: "png")
        do {
            try png.write(to: url)
            CaptureFile.markAsCapture(url)
            add([url], from: "clipboard-image")
        } catch {
            Log.actions.error("paste.write-failed error=\(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }
}
