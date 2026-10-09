import AppKit
import GhosttyKit

// Input translation helpers, adapted from Ghostty's macOS host
// (macos/Sources/Ghostty/Ghostty.Input.swift and NSEvent+Extension.swift, MIT license).

enum GhosttyInput {
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    static func mouseButton(_ number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    static func momentum(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
        switch phase {
        case .began: return GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: return GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: return GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: return GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: return GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: return GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: return GHOSTTY_MOUSE_MOMENTUM_NONE
        }
    }
}

extension NSEvent {
    /// Key event without `text`/`composing`; the caller sets those (C string lifetimes).
    func ghosttyKeyEvent(_ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = GhosttyInput.mods(modifierFlags)
        // Control and command never contribute to text translation.
        ev.consumed_mods = GhosttyInput.mods((translationMods ?? modifierFlags).subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
           let chars = characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            ev.unshifted_codepoint = scalar.value
        }
        return ev
    }

    /// Text for Ghostty: control characters are sent unmodified (Ghostty encodes them),
    /// and function-key private-use characters are dropped.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }
}

extension String {
    /// Ghostty ignores text that is only control characters; avoid sending empty strings.
    var keyEventText: String? { isEmpty ? nil : self }
}
