import Carbon

/// Hardware key codes Stackshot reacts to, named. Values come from Carbon's kVK_ constants.
enum KeyCode {
    static let escape = UInt16(kVK_Escape)
    static let space = UInt16(kVK_Space)
    static let delete = UInt16(kVK_Delete)
    static let forwardDelete = UInt16(kVK_ForwardDelete)
    static let returnKey = UInt16(kVK_Return)
    static let enter = UInt16(kVK_ANSI_KeypadEnter)
    static let left = UInt16(kVK_LeftArrow)
    static let right = UInt16(kVK_RightArrow)
    static let down = UInt16(kVK_DownArrow)
    static let up = UInt16(kVK_UpArrow)
}
