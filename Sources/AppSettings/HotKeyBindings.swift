import Foundation

/// Global shortcut actions and their user-editable bindings (Carbon key codes / modifier masks).
public enum HotKeyAction: String, CaseIterable, Codable, Sendable {
    case startStop, pause, toggleHUD, toggleSubtitles, clickThrough, cycleSource, translation, clear

    public var title: String {
        switch self {
        case .startStop: "Start / Stop"
        case .pause: "Pause / Resume"
        case .toggleHUD: "Show / hide control panel"
        case .toggleSubtitles: "Show / hide subtitles"
        case .clickThrough: "Movable ⇄ click-through subtitles"
        case .cycleSource: "Cycle source (System / Mic / Both)"
        case .translation: "Translation on / off"
        case .clear: "Clear the transcript"
        }
    }

    // Carbon: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000; kVK_* key codes.
    public var defaultBinding: HotKeyBinding {
        let optCmd = 0x800 | 0x100
        return switch self {
        case .startStop: HotKeyBinding(keyCode: 49, modifiers: optCmd, key: "Space")
        case .pause: HotKeyBinding(keyCode: 35, modifiers: optCmd, key: "P")
        case .toggleHUD: HotKeyBinding(keyCode: 4, modifiers: optCmd, key: "H")
        case .toggleSubtitles: HotKeyBinding(keyCode: 8, modifiers: optCmd, key: "C")
        case .clickThrough: HotKeyBinding(keyCode: 37, modifiers: optCmd, key: "L")
        case .cycleSource: HotKeyBinding(keyCode: 1, modifiers: optCmd, key: "S")
        case .translation: HotKeyBinding(keyCode: 17, modifiers: optCmd, key: "T")
        case .clear: HotKeyBinding(keyCode: 40, modifiers: optCmd, key: "K")
        }
    }
}

public struct HotKeyBinding: Codable, Hashable, Sendable {
    public var keyCode: Int
    public var modifiers: Int
    /// Key label captured when recorded (layout-aware), e.g. "K" or "Space".
    public var key: String
    public init(keyCode: Int, modifiers: Int, key: String) { self.keyCode = keyCode; self.modifiers = modifiers; self.key = key }

    public var display: String {
        var s = ""
        if modifiers & 0x1000 != 0 { s += "⌃" }
        if modifiers & 0x800 != 0 { s += "⌥" }
        if modifiers & 0x200 != 0 { s += "⇧" }
        if modifiers & 0x100 != 0 { s += "⌘" }
        return s + key
    }

    /// A global shortcut needs ⌘, ⌥ or ⌃, otherwise it would steal normal typing.
    public var isUsable: Bool { modifiers & (0x100 | 0x800 | 0x1000) != 0 }
}
