import AppKit
import Carbon.HIToolbox

/// Global hotkeys through RegisterEventHotKey (no Accessibility permission, no event tap).
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    nonisolated(unsafe) fileprivate static var actions: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false
    private var nextID: UInt32 = 1

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(keyCode: Int, modifiers: Int = optionKey | cmdKey, action: @escaping @MainActor () -> Void) {
        install()
        let id = nextID; nextID += 1
        Self.actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x5342564C), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    func registerDefaults(_ ctx: AppContext) {
        register(keyCode: kVK_Space) { Task { await ctx.engine.toggleStartStop() } }
        register(keyCode: kVK_ANSI_P) { Task { await ctx.engine.togglePause() } }
        register(keyCode: kVK_ANSI_H) { ctx.hud.toggleVisible() }
        register(keyCode: kVK_ANSI_C) { ctx.overlay.toggleVisible() }
        register(keyCode: kVK_ANSI_L) { ctx.toggleEditing() }
        register(keyCode: kVK_ANSI_S) { ctx.cycleSource() }
        register(keyCode: kVK_ANSI_T) { ctx.toggleTranslation() }
        register(keyCode: kVK_ANSI_K) { ctx.store.clear() }
    }

    static let descriptions: [(String, String)] = [
        ("⌥⌘Space", "Start / Stop"), ("⌥⌘P", "Pause / Resume"), ("⌥⌘H", "Show / hide control panel"),
        ("⌥⌘C", "Show / hide subtitles"), ("⌥⌘L", "Move/resize vs click-through"), ("⌥⌘S", "Cycle source"),
        ("⌥⌘T", "Translation on / off"), ("⌥⌘K", "Clear history"),
    ]
}
