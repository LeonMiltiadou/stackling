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

    /// Displays from the last look at what's on screen. Listing shareable content takes about a third of a
    /// freeze, and displays rarely change, so it's reused until a screen appears that isn't in it.
    private static var cachedDisplays: [SCDisplay] = []

    /// Looks up the displays ahead of the first capture, so the first ⇧⌘4 after launch is as quick as the rest.
    static func warmUp() async {
        guard CGPreflightScreenCaptureAccess() else { return }
        cachedDisplays = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays) ?? []
        Log.capture.debug("freeze.warm displays=\(cachedDisplays.count)")
    }

    /// A picture of every display, leaving out the windows numbered in `windowNumbers`. All displays are
    /// captured at once.
    static func freezeScreens(excluding windowNumbers: [Int]) async throws -> [FrozenScreen] {
        do {
            return try await freeze(excluding: windowNumbers)
        } catch where !cachedDisplays.isEmpty {
            // A display from the cache may have gone stale (a monitor reconnected, say): look again and retry once.
            Log.capture.notice("freeze.retry reason=\(error.localizedDescription, privacy: .public)")
            cachedDisplays = []
            return try await freeze(excluding: windowNumbers)
        }
    }

    private static func freeze(excluding windowNumbers: [Int]) async throws -> [FrozenScreen] {
        let started = CFAbsoluteTimeGetCurrent()
        let screens = NSScreen.screens
        var excluded: [SCWindow] = []
        let cacheCovers = screens.allSatisfy { s in cachedDisplays.contains { $0.displayID == s.displayID } }
        if !windowNumbers.isEmpty || !cacheCovers {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cachedDisplays = content.displays
            let own = Set(windowNumbers.map { CGWindowID($0) })
            excluded = content.windows.filter { own.contains($0.windowID) }
        }
        let jobs: [(Int, NSScreen, SCDisplay)] = screens.enumerated().compactMap { i, screen in
            guard let display = cachedDisplays.first(where: { $0.displayID == screen.displayID }) else {
                Log.capture.notice("freeze.display-missing screen=\(screen.displayID ?? 0)")
                return nil
            }
            return (i, screen, display)
        }
        let result = try await withThrowingTaskGroup(of: (Int, FrozenScreen).self) { group in
            for (i, screen, display) in jobs {
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let config = imageConfiguration(points: screen.frame.size, scale: screen.backingScaleFactor)
                group.addTask { (i, FrozenScreen(screen: screen, image: try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config))) }
            }
            var frozen: [(Int, FrozenScreen)] = []
            for try await item in group { frozen.append(item) }
            return frozen.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        Log.capture.debug("freeze.done screens=\(result.count) excluded=\(excluded.count) ms=\(ms) cached=\(windowNumbers.isEmpty && cacheCovers)")
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

    /// Ordinary app windows on screen, front to back, Stackling's own library, editor and settings included.
    /// (The stack and the capture tools float above normal windows, so they're never offered.)
    static func pickableWindows() -> [PickableWindow] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
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
