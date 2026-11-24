import AppKit
import AppSettings
import Carbon.HIToolbox

/// Global hotkeys through RegisterEventHotKey (no Accessibility permission, no event tap). Bindings come from settings
/// and are re-registered whenever they change.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    nonisolated(unsafe) fileprivate static var actions: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
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

    private func register(_ b: HotKeyBinding, action: @escaping @MainActor () -> Void) {
        install()
        let id = nextID; nextID += 1
        Self.actions[id] = action
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(UInt32(b.keyCode), UInt32(b.modifiers), EventHotKeyID(signature: OSType(0x5342564C), id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        if st == noErr, let ref { refs.append(ref) }
    }

    /// (Re)registers every shortcut from settings.
    func apply(_ ctx: AppContext) {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        Self.actions.removeAll()
        for a in HotKeyAction.allCases {
            let b = ctx.settings.binding(a)
            guard b.isUsable else { continue }
            register(b) { Self.perform(a, ctx) }
        }
    }

    static func perform(_ a: HotKeyAction, _ ctx: AppContext) {
        switch a {
        case .startStop: Task { await ctx.engine.toggleStartStop() }
        case .pause: Task { await ctx.engine.togglePause() }
        case .toggleHUD: ctx.hud.toggleVisible()
        case .toggleSubtitles: ctx.overlay.toggleVisible()
        case .clickThrough: ctx.toggleEditing()
        case .cycleSource: ctx.cycleSource()
        case .translation: ctx.toggleTranslation()
        case .clear: ctx.store.clear()
        }
    }
}
