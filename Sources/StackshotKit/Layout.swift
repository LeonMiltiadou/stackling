import AppKit

/// Sizes of the stack and its cards, shared by the SwiftUI views and the panel that holds them.
enum Layout {
    static let cardW: CGFloat = 340
    static let cardH: CGFloat = 214
    static let corner: CGFloat = 14
    static let pad: CGFloat = 20          // room for shadows around the content
    static let ghostStep: CGFloat = 9     // how far each card behind peeks out
    static let maxGhosts = 2
    static let pillH: CGFloat = 28
    /// Between the "N more" pill and the collapsed stack.
    static let pillSpacing: CGFloat = 8
    static let headerH: CGFloat = 32
    /// Between the expanded stack's header and its list.
    static let headerSpacing: CGFloat = 8
    static let gap: CGFloat = 10
    static let listVPad: CGFloat = 8
    static let screenMargin: CGFloat = 2
    static let miniW: CGFloat = 84
    static let miniH: CGFloat = 56

    static var panelWidth: CGFloat { cardW + pad * 2 }

    static func ghosts(_ count: Int) -> Int { min(max(count - 1, 0), maxGhosts) }

    static func collapsedHeight(_ count: Int) -> CGFloat {
        let pill = count > 1 ? pillH + pillSpacing : 0
        return pad + pill + CGFloat(ghosts(count)) * ghostStep + cardH + pad
    }

    static func listHeight(_ count: Int, max: CGFloat) -> CGFloat {
        let full = CGFloat(count) * cardH + CGFloat(count - 1) * gap + listVPad * 2
        return min(full, max)
    }

    static func expandedHeight(_ count: Int, maxList: CGFloat) -> CGFloat {
        pad + headerH + headerSpacing + listHeight(count, max: maxList) + (pad - listVPad)
    }

    /// The tallest the expanded list may get on a screen with this much usable room.
    static func maxListHeight(in visible: CGRect) -> CGFloat {
        visible.height - screenMargin * 2 - pad * 2 - headerH - headerSpacing
    }

    /// The panel's size for this many cards in this state, before it's fitted to the screen.
    static func panelSize(count: Int, expanded: Bool, minimized: Bool, maxList: CGFloat) -> CGSize {
        if minimized { return CGSize(width: miniW + pad * 2, height: miniH + pad * 2) }
        let height = expanded ? expandedHeight(count, maxList: maxList) : collapsedHeight(count)
        return CGSize(width: panelWidth, height: height)
    }

    /// Where the panel's bottom-left sits when the stack is in its usual corner of a screen.
    static func cornerOrigin(in visible: CGRect) -> NSPoint {
        NSPoint(x: visible.minX + screenMargin, y: visible.minY + screenMargin)
    }
}
