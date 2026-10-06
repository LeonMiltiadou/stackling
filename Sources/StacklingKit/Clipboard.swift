import AppKit
import UniformTypeIdentifiers

/// Everything Stackling puts on the clipboard goes through here.
@MainActor
enum Clipboard {
    /// The clipboard, or for Stackling Dev a private pasteboard, so testing never replaces what you copied.
    static let board: NSPasteboard = AppIdentity.current.pasteboardName.map { NSPasteboard(name: .init($0)) } ?? .general

    static func write(string: String) {
        board.clearContents()
        board.setString(string, forType: .string)
    }

    /// Several files at once, for pasting into a chat or a pull request.
    static func write(files: [URL]) {
        board.clearContents()
        board.writeObjects(files.map { $0 as NSURL })
    }

    static func write(image: NSImage) {
        board.clearContents()
        board.writeObjects([image])
    }

    /// A shot as picture data (with edits) for apps that paste images, plus the file for apps that take files.
    @discardableResult
    static func write(shot: Shot) -> Bool {
        if shot.isGIF { writeGIF(at: shot.url); return true }
        let item = NSPasteboardItem()
        guard let file = shot.isVideo ? shot.url : shot.exportURL() else { return false }
        if !shot.isVideo, let data = try? Data(contentsOf: file) {
            let type = UTType(filenameExtension: file.pathExtension) ?? .png
            if type.conforms(to: .png) {
                item.setData(data, forType: .png)
            } else if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
        }
        item.setString(file.absoluteString, forType: .fileURL)
        write(item)
        return true
    }

    /// GIF data for apps that paste images (browsers, Slack), plus the file for apps that take files.
    static func writeGIF(at url: URL) {
        let item = NSPasteboardItem()
        if let data = try? Data(contentsOf: url) {
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        }
        item.setString(url.absoluteString, forType: .fileURL)
        write(item)
    }

    private static func write(_ item: NSPasteboardItem) {
        board.clearContents()
        board.writeObjects([item])
    }
}
