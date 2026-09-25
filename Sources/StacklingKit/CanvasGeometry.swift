import CoreGraphics

/// Where the image sits in the editor canvas: the image (plus any beautify padding) is fitted
/// and centred in the view, never shown bigger than its real size on screen.
struct CanvasGeometry {
    /// Room left around the image so it doesn't touch the window edges.
    static let inset: CGFloat = 28

    /// The screenshot in pixels.
    var imageSize: CGSize
    /// Beautify padding around the image, in image pixels.
    var pad: CGFloat
    /// The canvas view's size in points.
    var viewSize: CGSize
    /// Pixels per point of the screenshot, so a Retina capture shows at its real size at most.
    var pixelScale: CGFloat

    /// The image plus padding, in image pixels.
    var contentSize: CGSize {
        CGSize(width: imageSize.width + pad * 2, height: imageSize.height + pad * 2)
    }

    /// View points per image pixel.
    var scale: CGFloat {
        let availWidth = viewSize.width - CanvasGeometry.inset * 2
        let availHeight = viewSize.height - CanvasGeometry.inset * 2
        guard contentSize.width > 0, contentSize.height > 0 else { return 1 }
        return max(0.01, min(availWidth / contentSize.width, availHeight / contentSize.height, 1 / pixelScale))
    }

    /// Top-left of the padded content, in view points.
    var contentOrigin: CGPoint {
        CGPoint(x: (viewSize.width - contentSize.width * scale) / 2, y: (viewSize.height - contentSize.height * scale) / 2)
    }

    /// Top-left of the image itself, in view points.
    var imageOrigin: CGPoint {
        CGPoint(x: contentOrigin.x + pad * scale, y: contentOrigin.y + pad * scale)
    }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - imageOrigin.x) / scale, y: (p.y - imageOrigin.y) / scale)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: imageOrigin.x + p.x * scale, y: imageOrigin.y + p.y * scale)
    }

    func toView(_ r: CGRect) -> CGRect {
        CGRect(origin: toView(r.origin), size: CGSize(width: r.width * scale, height: r.height * scale))
    }
}
