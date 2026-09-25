import AppKit
import ScreenCaptureKit

/// Stackshot's own capture: freezes every screen first, so menus and hover states
/// stay put while you pick an area or a window. Includes a pixel loupe and live coordinates.
@MainActor
final class CaptureController {
    static let shared = CaptureController()

    enum Mode { case area, window }
    /// What happens once you've picked: save a screenshot, or start recording it.
    enum Purpose { case screenshot, recording }

    struct PickableWindow {
        let id: CGWindowID
        let frame: CGRect   // global, top-left origin (CoreGraphics space)
        let app: String
    }

    /// Windows to leave out of the frozen image (the stack itself).
    var excludedWindowNumbers: () -> [Int] = { [] }

    private var overlays: [CaptureOverlayWindow] = []
    private var previousApp: NSRunningApplication?
    private var busy = false
    private(set) var purpose: Purpose = .screenshot

    // MARK: Entry points

    func start(_ mode: Mode, for purpose: Purpose = .screenshot) {
        guard !busy, ensurePermission() else { return }
        busy = true
        self.purpose = purpose
        rememberFrontApp()
        Task {
            do {
                let frozen = try await freezeScreens()
                showOverlays(frozen: frozen, windows: windowList(), mode: mode)
            } catch {
                finish()
                report(error)
            }
        }
    }

    func captureFullScreen() {
        guard !busy, ensurePermission() else { return }
        busy = true
        let screen = mouseScreen()
        Task {
            defer { busy = false }
            do {
                guard let shot = try await freezeScreens().first(where: { $0.screen == screen }) else { return }
                save(shot.image, pixelScale: screen.backingScaleFactor)
            } catch {
                report(error)
            }
        }
    }

    // MARK: Permission

    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !UserDefaults.standard.bool(forKey: "askedScreenRecording") {
            UserDefaults.standard.set(true, forKey: "askedScreenRecording")
            CGRequestScreenCaptureAccess()
            return false
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Stackshot needs Screen Recording permission"
        alert.informativeText = """
        To freeze the screen and take screenshots itself, turn on Stackshot in System Settings → Privacy & Security → Screen & System Audio Recording. Then quit and reopen Stackshot.

        Until then, the Mac's own ⇧⌘3 and ⇧⌘5 still land on the stack.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return false
    }

    private func report(_ error: Error) {
        log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
        NSSound.beep()
    }

    // MARK: Freezing

    struct Frozen { let screen: NSScreen; let image: CGImage }

    private func freezeScreens() async throws -> [Frozen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownNumbers = Set(excludedWindowNumbers().map { CGWindowID($0) })
        let excluded = content.windows.filter { ownNumbers.contains($0.windowID) }
        var result: [Frozen] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(Frozen(screen: screen, image: image))
        }
        return result
    }

    private func windowList() -> [PickableWindow] {
        let own = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != own,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict),
                  frame.width > 40, frame.height > 40 else { return nil }
            return PickableWindow(id: id, frame: frame, app: w[kCGWindowOwnerName as String] as? String ?? "")
        }
    }

    // MARK: Overlay

    private func showOverlays(frozen: [Frozen], windows: [PickableWindow], mode: Mode) {
        NSApp.activate()
        let mouse = mouseScreen()
        for f in frozen {
            let window = CaptureOverlayWindow(screen: f.screen)
            let view = CaptureOverlayView(frozen: f, windows: windows, mode: mode, controller: self)
            window.contentView = view
            window.setFrame(f.screen.frame, display: false)
            overlays.append(window)
            if f.screen == mouse {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
            } else {
                window.orderFrontRegardless()
            }
        }
        overlays.forEach { $0.contentView?.needsDisplay = true }
        NSCursor.crosshair.set()
    }

    /// Keeps every overlay in the same mode when Space toggles it.
    func setMode(_ mode: Mode) {
        for case let view as CaptureOverlayView in overlays.compactMap(\.contentView) {
            view.mode = mode
        }
    }

    func cancel() { finish() }

    func finishArea(_ frozen: Frozen, pixelRect: CGRect) {
        finish()
        if purpose == .recording {
            let scale = frozen.screen.backingScaleFactor
            let points = CGRect(x: pixelRect.minX / scale, y: pixelRect.minY / scale,
                                width: pixelRect.width / scale, height: pixelRect.height / scale).integral
            Recorder.shared.start(.area(frozen.screen, points))
            return
        }
        guard let crop = frozen.image.cropping(to: pixelRect.integral) else { return }
        save(crop, pixelScale: frozen.screen.backingScaleFactor)
    }

    func finishWindow(_ window: PickableWindow, frozen: Frozen, pixelRect: CGRect, withShadow: Bool) {
        finish()
        if purpose == .recording {
            Recorder.shared.start(.window(window.id))
            return
        }
        let scale = frozen.screen.backingScaleFactor
        Task {
            // A fresh capture of just that window: clean even if something was covering it.
            var image: CGImage?
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let target = content.windows.first(where: { $0.windowID == window.id }) {
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * scale)
                config.height = Int(window.frame.height * scale)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                config.shouldBeOpaque = false
                config.captureResolution = .best
                image = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config
                )
            }
            if image == nil { image = frozen.image.cropping(to: pixelRect.integral) }
            guard var result = image else { return }
            if withShadow, let shadowed = Self.addShadow(result, scale: scale) { result = shadowed }
            save(result, pixelScale: scale)
        }
    }

    private func finish() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        busy = false
        if let app = previousApp, app != NSRunningApplication.current {
            app.activate()
        }
        previousApp = nil
    }

    private func rememberFrontApp() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? nil : front
    }

    // MARK: Saving

    private func save(_ image: CGImage, pixelScale: CGFloat) {
        let folder = Prefs.screenshotFolder
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Screenshot \(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent("\(stem).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) (\(n)).png")
            n += 1
        }
        do {
            try MarkupRenderer.writePNG(image, to: url, pixelScale: pixelScale)
            setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", Self.plistTrue, Self.plistTrue.count, 0, 0)
            NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)?.play()
            ShotStore.shared.add(url)
        } catch {
            report(error)
        }
    }

    private static let plistTrue: [UInt8] = Array(
        (try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)) ?? Data()
    )

    /// The soft drop shadow macOS puts around window captures.
    private static func addShadow(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let pad = Int(40 * scale)
        let w = image.width + pad * 2, h = image.height + pad * 2
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 34 * scale,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    private func mouseScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

final class CaptureOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Overlay view

final class CaptureOverlayView: NSView {
    private let frozen: CaptureController.Frozen
    private let windows: [(window: CaptureController.PickableWindow, rect: CGRect)]
    private unowned let controller: CaptureController
    private lazy var bitmap = NSBitmapImageRep(cgImage: frozen.image)
    private let frozenImage: NSImage

    var mode: CaptureController.Mode {
        didSet {
            dragStart = nil
            selection = nil
            updateHover()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var spaceHeld = false
    private var lastDrag: CGPoint?
    private var hovered: (window: CaptureController.PickableWindow, rect: CGRect)?

    private var recording: Bool { controller.purpose == .recording }

    /// Pixels in the frozen image per point in this view.
    private var px: CGFloat { CGFloat(frozen.image.width) / max(bounds.width, 1) }

    init(frozen: CaptureController.Frozen, windows: [CaptureController.PickableWindow], mode: CaptureController.Mode, controller: CaptureController) {
        self.frozen = frozen
        self.controller = controller
        self.mode = mode
        self.frozenImage = NSImage(cgImage: frozen.image, size: frozen.screen.frame.size)

        // Convert window frames (global, top-left origin) into this screen's view space.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frozen.screen.frame.height
        let origin = CGPoint(x: frozen.screen.frame.minX, y: primaryHeight - frozen.screen.frame.maxY)
        let local = CGRect(origin: .zero, size: frozen.screen.frame.size)
        self.windows = windows.compactMap { w in
            let r = w.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            return r.intersects(local) ? (w, r.intersection(local)) : nil
        }
        super.init(frame: CGRect(origin: .zero, size: frozen.screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .window ? .pointingHand : .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        (mode == .window ? NSCursor.pointingHand : NSCursor.crosshair).set()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        frozenImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        let dim = NSBezierPath(rect: bounds)
        if let sel = selection, sel.width > 0, sel.height > 0 {
            dim.append(NSBezierPath(rect: sel))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(mode == .window ? 0.18 : 0.32).setFill()
        dim.fill()

        if mode == .window, let h = hovered {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            h.rect.fill()
            let border = NSBezierPath(rect: h.rect.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            border.stroke()
            let size = "\(Int(h.rect.width * px)) × \(Int(h.rect.height * px))"
            drawBadge("\(h.window.app)  ·  \(size)", at: CGPoint(x: h.rect.midX, y: h.rect.midY), centered: true)
            drawHint(recording
                ? "Click a window to record it  ·  Space for area  ·  Esc to cancel"
                : "Click a window to capture it  ·  ⌥ click for no shadow  ·  Space for area  ·  Esc to cancel")
            return
        }

        if let sel = selection, sel.width > 0 || sel.height > 0 {
            let outline = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            outline.lineWidth = 1
            NSColor.white.setStroke()
            outline.stroke()
            let size = "\(Int((sel.width * px).rounded())) × \(Int((sel.height * px).rounded()))"
            var badgePoint = CGPoint(x: sel.maxX, y: sel.maxY + 10)
            if badgePoint.y > bounds.height - 40 { badgePoint.y = sel.maxY - 34 }
            drawBadge(size, at: badgePoint, alignRight: true)
        } else {
            drawHint(recording
                ? "Drag to record an area  ·  Click to record the whole screen  ·  Space for window  ·  Esc to cancel"
                : "Drag to capture an area  ·  Space for window  ·  Esc to cancel")
        }

        if let m = mouse, !spaceHeld { drawLoupe(at: m) }
    }

    private func drawBadge(_ text: String, at p: CGPoint, alignRight: Bool = false, centered: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var rect = CGRect(x: p.x, y: p.y, width: size.width + 16, height: size.height + 8)
        if alignRight { rect.origin.x -= rect.width }
        if centered { rect.origin = CGPoint(x: p.x - rect.width / 2, y: p.y - rect.height / 2) }
        rect.origin.x = min(max(rect.minX, 6), bounds.width - rect.width - 6)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 4), withAttributes: attrs)
    }

    private func drawHint(_ text: String) {
        guard frozen.screen == NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) else { return }
        drawBadge(text, at: CGPoint(x: bounds.midX, y: bounds.height - 60), centered: true)
    }

    /// Magnified pixels around the cursor, with the exact position and colour under it.
    private func drawLoupe(at m: CGPoint) {
        let diameter: CGFloat = 132
        let pixels: CGFloat = 15
        var origin = CGPoint(x: m.x + 22, y: m.y + 22)
        if origin.x + diameter > bounds.width { origin.x = m.x - 22 - diameter }
        if origin.y + diameter + 44 > bounds.height { origin.y = m.y - 22 - diameter - 44 }
        let circle = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))

        let cx = Int((m.x * px).rounded(.down)), cy = Int((m.y * px).rounded(.down))
        let half = Int(pixels) / 2
        let source = CGRect(x: cx - half, y: cy - half, width: Int(pixels), height: Int(pixels))

        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(ovalIn: circle)
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 8
        shadow.set()
        NSColor.black.setFill()
        clip.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSColor.black.setFill()
        circle.fill()
        if let crop = frozen.image.cropping(to: source.intersection(CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height))) {
            NSGraphicsContext.current?.imageInterpolation = .none
            let cell = diameter / pixels
            // Keep the cursor pixel centred even at screen edges.
            let dx = CGFloat(max(0, -(cx - half))), dy = CGFloat(max(0, -(cy - half)))
            let dest = CGRect(x: circle.minX + dx * cell, y: circle.minY + dy * cell,
                              width: CGFloat(crop.width) * cell, height: CGFloat(crop.height) * cell)
            NSImage(cgImage: crop, size: dest.size).draw(in: dest, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                                                         hints: [.interpolation: NSImageInterpolation.none.rawValue])
            // Pixel grid
            NSColor.black.withAlphaComponent(0.12).setStroke()
            let grid = NSBezierPath()
            for i in 0...Int(pixels) {
                let o = CGFloat(i) * cell
                grid.move(to: CGPoint(x: circle.minX + o, y: circle.minY))
                grid.line(to: CGPoint(x: circle.minX + o, y: circle.maxY))
                grid.move(to: CGPoint(x: circle.minX, y: circle.minY + o))
                grid.line(to: CGPoint(x: circle.maxX, y: circle.minY + o))
            }
            grid.lineWidth = 0.5
            grid.stroke()
            // Centre pixel
            let centre = CGRect(x: circle.minX + CGFloat(half) * cell, y: circle.minY + CGFloat(half) * cell, width: cell, height: cell)
            let box = NSBezierPath(rect: centre)
            box.lineWidth = 1.5
            NSColor.white.setStroke()
            box.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.9).setStroke()
        ring.stroke()

        var label = "\(cx), \(cy)"
        if cx >= 0, cy >= 0, cx < bitmap.pixelsWide, cy < bitmap.pixelsHigh,
           let c = bitmap.colorAt(x: cx, y: cy)?.usingColorSpace(.sRGB) {
            label += String(format: "   #%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        drawBadge(label, at: CGPoint(x: circle.midX, y: circle.maxY + 20), centered: true)
    }

    // MARK: Mouse

    private func updateHover() {
        guard mode == .window, let m = mouse else { hovered = nil; return }
        hovered = windows.first { $0.rect.contains(m) }
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        updateHover()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        if mode == .window {
            updateHover()
            guard let h = hovered else { return }
            controller.finishWindow(h.window, frozen: frozen, pixelRect: pixelRect(h.rect),
                                    withShadow: !event.modifierFlags.contains(.option))
            return
        }
        dragStart = p
        lastDrag = p
        selection = CGRect(origin: p, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        guard mode == .area, var start = dragStart else { return }
        if spaceHeld, let last = lastDrag {
            // Space held: move the whole selection instead of resizing it.
            start.x += p.x - last.x
            start.y += p.y - last.y
            dragStart = start
            if let sel = selection { selection = sel.offsetBy(dx: p.x - last.x, dy: p.y - last.y) }
        } else {
            var end = p
            if event.modifierFlags.contains(.shift) {
                let side = max(abs(p.x - start.x), abs(p.y - start.y))
                end = CGPoint(x: start.x + (p.x < start.x ? -side : side), y: start.y + (p.y < start.y ? -side : side))
            }
            selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
        lastDrag = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area, let sel = selection?.intersection(bounds) else { return }
        dragStart = nil
        selection = nil
        if sel.width < 3 || sel.height < 3 {
            // A plain click records the whole screen.
            if recording { controller.finishArea(frozen, pixelRect: pixelRect(bounds)); return }
            needsDisplay = true
            return
        }
        controller.finishArea(frozen, pixelRect: pixelRect(sel))
    }

    private func pixelRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * px, y: r.minY * px, width: r.width * px, height: r.height * px)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // esc
            controller.cancel()
        case 49: // space
            if dragStart != nil {
                spaceHeld = true
            } else if !event.isARepeat {
                controller.setMode(mode == .area ? .window : .area)
            }
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceHeld = false
            needsDisplay = true
        }
    }
}
