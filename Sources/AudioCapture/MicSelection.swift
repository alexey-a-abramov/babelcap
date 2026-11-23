import Foundation

/// How the microphone setting maps to a device.
///
/// - `nil` (default): the **built-in** microphone — new devices (HDMI displays, docks, headsets) are never picked up
///   just because macOS made them the default input.
/// - `MicSelection.systemDefault`: follow the macOS default input.
/// - any other value: that device's UID (falls back to the built-in mic while it is unplugged).
public enum MicSelection {
    public static let systemDefault = "system-default"

    /// Device UID to open, or nil for "the macOS default input".
    public static func deviceUID(for setting: String?, builtIn: String?, available: [String]) -> String? {
        switch setting {
        case systemDefault?: return nil
        case nil: return builtIn
        case let uid?: return available.contains(uid) ? uid : builtIn
        }
    }

    public static func deviceUID(for setting: String?) -> String? {
        deviceUID(for: setting, builtIn: AudioDevices.builtInInputUID(), available: AudioDevices.inputDevices().map(\.uid))
    }

    /// Whether this setting cares about the macOS default input changing.
    public static func followsSystemDefault(_ setting: String?) -> Bool { setting == systemDefault }
}
