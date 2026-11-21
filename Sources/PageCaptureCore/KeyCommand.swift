import AppKit

/// Maps key presses to capture events, independent of where focus is (SPEC "Shortcut and banner").
public enum KeyCommand {
    /// Modifiers that count: Caps Lock, numeric-pad and function flags are ignored.
    public static func significantModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }

    /// The event for a key press, or `nil` when the key is not ours and must pass through.
    /// ⌘⇧S works in every phase and window; Esc and Return (main or keypad) only while picking, with no
    /// modifiers, and only in the capture window, so a pop-up's form or a dialog keeps its own Return.
    /// - Parameter characters: `NSEvent.charactersIgnoringModifiers`, so ⌘⇧S follows the keyboard layout.
    /// - Parameter inCaptureWindow: the key went to the main web view's window, with no sheet attached to it.
    public static func event(
        keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags, phase: CapturePhase,
        inCaptureWindow: Bool
    ) -> CaptureEvent? {
        let modifiers = significantModifiers(flags)
        if modifiers == [.command, .shift], characters?.lowercased() == "s" { return .shortcut }
        guard phase == .picking, inCaptureWindow, modifiers.isEmpty else { return nil }
        switch keyCode {
        case 53: return .escape
        case 36, 76: return .returnKey
        default: return nil
        }
    }
}
