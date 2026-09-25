import AppKit

extension NSScreen {
    /// The display's id, for matching an NSScreen to a ScreenCaptureKit display.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The screen containing a point in AppKit's global coordinates (bottom-left origin).
    static func containing(_ point: CGPoint) -> NSScreen? {
        screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// The screen the mouse is on, falling back to the main screen.
    static var underMouse: NSScreen {
        containing(NSEvent.mouseLocation) ?? main ?? screens[0]
    }

    /// The main screen's usable area, with a sensible fallback when there's somehow no screen.
    static var mainVisibleFrame: CGRect {
        main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Height of the primary display, the pivot between CoreGraphics (top-left) and AppKit (bottom-left) coordinates.
    static var primaryHeight: CGFloat { screens.first?.frame.height ?? 0 }
}

extension CGPoint {
    /// Converts between CoreGraphics global coordinates (top-left origin) and AppKit's (bottom-left). Works both ways.
    var flippedVertically: CGPoint { CGPoint(x: x, y: NSScreen.primaryHeight - y) }
}

extension CGRect {
    /// This rect, given in `screen`'s own points with a top-left origin, as an AppKit window frame.
    func appKitFrame(inTopLeftSpaceOf screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.minX + minX, y: screen.frame.maxY - maxY, width: width, height: height)
    }

    /// The largest rect of `size`'s shape that fits inside this one, centred.
    func aspectFit(_ size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return self }
        let scale = min(width / size.width, height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }
}

/// Holding ⇧ while dragging: the end point that makes the drag a square.
func squareConstrained(from start: CGPoint, to point: CGPoint) -> CGPoint {
    let side = max(abs(point.x - start.x), abs(point.y - start.y))
    return CGPoint(x: start.x + (point.x < start.x ? -side : side), y: start.y + (point.y < start.y ? -side : side))
}

extension NSWindow.CollectionBehavior {
    /// On every desktop, over full-screen apps, and left out of Mission Control and ⌘`.
    static let overlayOnAllSpaces: Self = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
}

extension NSWindow {
    /// The shared setup for Stackshot's floating, see-through windows (the stack, the recording bar, outlines).
    func configureAsOverlay(level: NSWindow.Level, sharing: NSWindow.SharingType = .none, ignoresMouse: Bool = false) {
        self.level = level
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = ignoresMouse
        sharingType = sharing
        collectionBehavior = .overlayOnAllSpaces
    }
}
