import AppKit
import Carbon.HIToolbox

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case toggleMute

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .playPause: "Play / Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .toggleMute: "Mute / Unmute"
        }
    }

    var symbolName: String {
        switch self {
        case .playPause: "playpause.fill"
        case .nextTrack: "forward.fill"
        case .previousTrack: "backward.fill"
        case .volumeUp: "speaker.plus.fill"
        case .volumeDown: "speaker.minus.fill"
        case .toggleMute: "speaker.slash.fill"
        }
    }
}

struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifierFlags: UInt

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags.intersection([.command, .option, .shift, .control]).rawValue
    }

    var nsModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
    }

    var carbonModifiers: UInt32 {
        var mods: UInt32 = 0
        let flags = nsModifierFlags
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    var displayString: String {
        var parts: [String] = []
        let flags = nsModifierFlags
        if flags.contains(.control) { parts.append("\u{2303}") }
        if flags.contains(.option) { parts.append("\u{2325}") }
        if flags.contains(.shift) { parts.append("\u{21E7}") }
        if flags.contains(.command) { parts.append("\u{2318}") }
        parts.append(Self.stringForKeyCode(keyCode))
        return parts.joined()
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func stringForKeyCode(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_Equal: "="
        case kVK_ANSI_Minus: "-"
        case kVK_ANSI_RightBracket: "]"
        case kVK_ANSI_LeftBracket: "["
        case kVK_ANSI_Quote: "'"
        case kVK_ANSI_Semicolon: ";"
        case kVK_ANSI_Backslash: "\\"
        case kVK_ANSI_Comma: ","
        case kVK_ANSI_Slash: "/"
        case kVK_ANSI_Period: "."
        case kVK_ANSI_Grave: "`"
        case kVK_Return: "\u{21A9}"
        case kVK_Tab: "\u{21E5}"
        case kVK_Space: "Space"
        case kVK_Delete: "\u{232B}"
        case kVK_ForwardDelete: "\u{2326}"
        case kVK_Escape: "\u{238B}"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        case kVK_F13: "F13"
        case kVK_F14: "F14"
        case kVK_F15: "F15"
        case kVK_LeftArrow: "\u{2190}"
        case kVK_RightArrow: "\u{2192}"
        case kVK_UpArrow: "\u{2191}"
        case kVK_DownArrow: "\u{2193}"
        case kVK_Home: "\u{2196}"
        case kVK_End: "\u{2198}"
        case kVK_PageUp: "\u{21DE}"
        case kVK_PageDown: "\u{21DF}"
        default: "Key\(keyCode)"
        }
    }
}
