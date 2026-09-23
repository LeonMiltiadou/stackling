import AppKit

/// A screenshot floating above everything, like a sticky note you can reference while you work.
/// Drag to move, scroll to zoom, double-click or Esc to close, right-click for more.
final class PinWindow: NSPanel {
    private static var pins: [PinWindow] = []

    let image: NSImage
    weak var shot: Shot?
    private let naturalSize: NSSize

    @MainActor
    static func show(_ image: NSImage, shot: Shot?) {
        let pin = PinWindow(image: image, shot: shot)
        pins.append(pin)
        pin.orderFrontRegardless()
        pin.makeKey()
    }

    private init(image: NSImage, shot: Shot?) {
        self.image = image
        self.shot = shot
        self.naturalSize = image.size

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = min(1, (screen.width * 0.5) / max(image.size.width, 1), (screen.height * 0.5) / max(image.size.height, 1))
        let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        let offset = CGFloat(PinWindow.pins.count % 6) * 28
        let origin = CGPoint(x: screen.midX - size.width / 2 + offset, y: screen.midY - size.height / 2 - offset)

        super.init(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = image.size
        contentView = PinView(pin: self)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copyImage(); return }
        super.keyDown(with: event)
    }

    override func close() {
        super.close()
        PinWindow.pins.removeAll { $0 === self }
    }

    /// Scroll up to grow, down to shrink, around the window's centre.
    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        let factor = 1 + delta * 0.006
        resize(by: factor)
    }

    override func magnify(with event: NSEvent) {
        resize(by: 1 + event.magnification)
    }

    private func resize(by factor: CGFloat) {
        let old = frame
        let screen = self.screen?.visibleFrame ?? old
        var w = old.width * factor
        w = min(max(w, 80), screen.width * 1.5)
        let h = w * naturalSize.height / max(naturalSize.width, 1)
        setFrame(CGRect(x: old.midX - w / 2, y: old.midY - h / 2, width: w, height: h), display: true)
    }

    @objc func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc func actualSize() {
        let old = frame
        setFrame(CGRect(x: old.midX - naturalSize.width / 2, y: old.midY - naturalSize.height / 2,
                        width: naturalSize.width, height: naturalSize.height), display: true)
    }

    @objc func setOpacity(_ sender: NSMenuItem) {
        alphaValue = CGFloat(sender.tag) / 100
    }

    @objc func edit() {
        guard let shot else { return }
        MainActor.assumeIsolated { EditorWindowController.open(shot) }
        close()
    }

    @objc func closePin() { close() }
}

private final class PinView: NSView {
    weak var pin: PinWindow?
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    private var hovering = false { didSet { closeButton.isHidden = !hovering } }
    private let closeButton = NSButton()

    init(pin: PinWindow) {
        self.pin = pin
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        closeButton.contentTintColor = .white
        closeButton.isBordered = false
        closeButton.target = pin
        closeButton.action = #selector(PinWindow.closePin)
        closeButton.isHidden = true
        closeButton.shadow = {
            let s = NSShadow()
            s.shadowColor = .black.withAlphaComponent(0.6)
            s.shadowBlurRadius = 3
            return s
        }()
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        closeButton.frame = CGRect(x: 8, y: bounds.height - 30, width: 22, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        pin?.image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            pin?.close()
            return
        }
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let window else { return }
        let now = NSEvent.mouseLocation
        window.setFrameOrigin(CGPoint(x: start.origin.x + now.x - start.mouse.x, y: start.origin.y + now.y - start.mouse.y))
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let pin else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(PinWindow.copyImage), keyEquivalent: "").target = pin
        if pin.shot != nil {
            menu.addItem(withTitle: "Edit", action: #selector(PinWindow.edit), keyEquivalent: "").target = pin
        }
        menu.addItem(withTitle: "Actual Size", action: #selector(PinWindow.actualSize), keyEquivalent: "").target = pin
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for value in [100, 80, 60, 40, 20] {
            let item = sub.addItem(withTitle: "\(value)%", action: #selector(PinWindow.setOpacity(_:)), keyEquivalent: "")
            item.tag = value
            item.target = pin
            item.state = Int((pin.alphaValue * 100).rounded()) == value ? .on : .off
        }
        opacity.submenu = sub
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(PinWindow.closePin), keyEquivalent: "").target = pin
        return menu
    }
}
