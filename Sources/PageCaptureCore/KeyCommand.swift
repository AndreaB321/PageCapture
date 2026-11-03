import AppKit

/// Maps key presses to capture events, independent of where focus is (SPEC "Shortcut and banner").
public enum KeyCommand {
    /// Modifiers that count: Caps Lock, numeric-pad and function flags are ignored.
    public static func significantModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }

    /// The event for a key press, or `nil` when the key is not ours and must pass through.
    /// ⌘⇧S works in every phase; Esc and Return (main or keypad) only while picking, with no modifiers.
    /// - Parameter characters: `NSEvent.charactersIgnoringModifiers`, so ⌘⇧S follows the keyboard layout.
    public static func event(
        keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags, phase: CapturePhase
    ) -> CaptureEvent? {
        let modifiers = significantModifiers(flags)
        if modifiers == [.command, .shift], characters?.lowercased() == "s" { return .shortcut }
        guard phase == .picking, modifiers.isEmpty else { return nil }
        switch keyCode {
        case 53: return .escape
        case 36, 76: return .returnKey
        default: return nil
        }
    }
}
