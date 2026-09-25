import AppKit
import UniformTypeIdentifiers

/// Everything Stackling puts on the clipboard goes through here.
@MainActor
enum Clipboard {
    static func write(string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func write(image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// A shot as picture data (with edits) for apps that paste images, plus the file for apps that take files.
    static func write(shot: Shot) {
        if shot.isGIF { return writeGIF(at: shot.url) }
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
        write(item)
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }
}
