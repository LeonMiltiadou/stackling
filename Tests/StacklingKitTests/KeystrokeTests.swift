import AppKit
import Testing
@testable import StacklingKit

@MainActor
@Suite struct KeystrokeTests {
    @Test func showsShortcutsWithTheirModifiersInMacOSOrder() {
        #expect(KeystrokeOverlay.label(keyCode: 35, modifiers: [.command, .shift], characters: "p") == "⇧⌘P")
        #expect(KeystrokeOverlay.label(keyCode: 8, modifiers: [.control, .option], characters: "c") == "⌃⌥C")
    }

    @Test func showsSpecialKeysOnTheirOwn() {
        #expect(KeystrokeOverlay.label(keyCode: KeyCode.returnKey, modifiers: [], characters: "\r") == "↩")
        #expect(KeystrokeOverlay.label(keyCode: KeyCode.escape, modifiers: [], characters: nil) == "⎋")
        #expect(KeystrokeOverlay.label(keyCode: KeyCode.left, modifiers: [.command], characters: nil) == "⌘←")
    }

    @Test func neverShowsPlainTyping() {
        #expect(KeystrokeOverlay.label(keyCode: 0, modifiers: [], characters: "a") == nil)
        #expect(KeystrokeOverlay.label(keyCode: 0, modifiers: [.shift], characters: "a") == nil)
        #expect(KeystrokeOverlay.label(keyCode: 18, modifiers: [], characters: "1") == nil)
    }
}
