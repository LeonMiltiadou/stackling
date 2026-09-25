import AppKit
import ScreenCaptureKit

/// One display's picture, taken the moment a capture starts, so menus and hover states stay put.
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage
}

/// A window you can click on while picking.
struct PickableWindow {
    let id: CGWindowID
    let frame: CGRect   // global, top-left origin (CoreGraphics space)
    let app: String
}

enum CaptureError: LocalizedError {
    case windowGone

    var errorDescription: String? {
        switch self {
        case .windowGone: "That window closed before it could be captured"
        }
    }
}

/// Takes pictures of the screen with ScreenCaptureKit.
@MainActor
enum ScreenGrabber {
    /// Windows smaller than this on either side aren't worth offering for a window capture.
    static let minimumWindowSide: CGFloat = 40

    /// A picture of every display, leaving out the windows numbered in `windowNumbers` (the stack itself).
    static func freezeScreens(excluding windowNumbers: [Int]) async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownNumbers = Set(windowNumbers.map { CGWindowID($0) })
        let excluded = content.windows.filter { ownNumbers.contains($0.windowID) }
        var result: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else {
                Log.capture.notice("freeze.display-missing screen=\(screen.displayID ?? 0)")
                continue
            }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let config = imageConfiguration(points: screen.frame.size, scale: screen.backingScaleFactor)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(FrozenScreen(screen: screen, image: image))
        }
        Log.capture.debug("freeze.done screens=\(result.count) excluded=\(excluded.count)")
        return result
    }

    /// A fresh picture of just that window, clean even if something was covering it.
    static func captureWindow(_ window: PickableWindow, scale: CGFloat) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == window.id }) else { throw CaptureError.windowGone }
        let config = imageConfiguration(points: window.frame.size, scale: scale)
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config
        )
    }

    /// Ordinary app windows on screen, front to back, other than Stackshot's own.
    static func pickableWindows() -> [PickableWindow] {
        let own = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != own,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict),
                  frame.width > minimumWindowSide, frame.height > minimumWindowSide else { return nil }
            return PickableWindow(id: id, frame: frame, app: w[kCGWindowOwnerName as String] as? String ?? "")
        }
    }

    /// Full-resolution stills without the cursor, the part screen and window captures share.
    private static func imageConfiguration(points: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(points.width * scale)
        config.height = Int(points.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return config
    }
}
