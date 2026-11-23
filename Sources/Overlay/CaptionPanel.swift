import AppKit
import AppSettings
import SonioxClient
import SwiftUI
import Transcript

public final class CaptionPanel: NSPanel {
    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }

    init(autosaveName: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 900, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        setFrameAutosaveName(autosaveName)
    }
}

/// Owns the subtitle window(s): one for Captions/Feed/Dual, two ("Them" / "Me") for Split.
@MainActor
public final class OverlayController {
    private let store: TranscriptStore
    private let settings: SettingsStore
    public let state = OverlayState()
    private var panels: [String: CaptionPanel] = [:]
    private var splitMode = false

    public init(store: TranscriptStore, settings: SettingsStore) {
        self.store = store; self.settings = settings
    }

    public func start() {
        rebuild()
        track()
    }

    public var isEditing: Bool { state.isEditing }

    public func setEditing(_ on: Bool) {
        state.isEditing = on
        for p in panels.values {
            p.ignoresMouseEvents = !on
            if on { p.styleMask.insert(.resizable) } else { p.styleMask.remove(.resizable) }
        }
    }

    public func toggleEditing() { setEditing(!state.isEditing) }

    public func toggleVisible() { settings.profile.layout.showSubtitles.toggle() }

    private func track() {
        withObservationTracking {
            _ = settings.profile.layout
        } onChange: { [weak self] in
            Task { @MainActor in self?.apply(); self?.track() }
        }
    }

    private func rebuild() {
        splitMode = settings.profile.layout.mode == .split
        let wanted: [(String, SourceKind?)] = splitMode ? [("system", .system), ("mic", .mic)] : [("main", nil)]
        for (k, p) in panels where !wanted.contains(where: { $0.0 == k }) { p.orderOut(nil); panels[k] = nil }
        for (key, filter) in wanted where panels[key] == nil {
            let panel = CaptionPanel(autosaveName: "SubveilCaption.\(key)")
            let root = CaptionView(store: store, settings: settings, state: state, filter: filter)
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            panel.contentView = host
            let restored = panel.setFrameUsingName("SubveilCaption.\(key)")
            panels[key] = panel
            sizePanel(panel, firstPlacement: !restored, offsetIndex: key == "mic" ? 1 : 0)
        }
        apply()
    }

    private func sizePanel(_ panel: CaptionPanel, firstPlacement: Bool, offsetIndex: Int = 0) {
        let l = settings.profile.layout, a = settings.profile.appearance
        let per = (a.original.size * 1.25 + a.original.lineSpacing) * (settings.profile.content.mode == .both || l.mode == .dual ? 2 : 1)
        let h: Double = l.mode == .feed ? 360 : per * Double(max(1, l.lines)) + a.padding * 2 + 16
        let w = splitMode ? min(l.width, 640) : l.width
        let old = panel.frame
        var f = NSRect(x: old.minX, y: old.minY, width: w, height: h)
        if firstPlacement, let vis = NSScreen.main?.visibleFrame {
            f.origin.x = vis.midX - w / 2 + (splitMode ? (offsetIndex == 0 ? -w / 2 - 10 : w / 2 + 10) : 0)
            f.origin.y = vis.minY + 70
        } else if abs(old.width - w) > 0.5 {
            f.origin.x = old.midX - w / 2   // keep horizontally centred while resizing
        }
        panel.setFrame(f, display: true)
    }

    private func apply() {
        if (settings.profile.layout.mode == .split) != splitMode { rebuild(); return }
        let l = settings.profile.layout
        for (key, p) in panels {
            if !state.isEditing { sizePanel(p, firstPlacement: false, offsetIndex: key == "mic" ? 1 : 0) }
            p.level = switch l.level {
            case .statusBar: .statusBar
            case .popUp: .popUpMenu
            case .screenSaver: .screenSaver
            }
            p.sharingType = l.hideFromSharing ? .none : .readOnly
            if l.showSubtitles { p.orderFrontRegardless() } else { p.orderOut(nil) }
        }
    }
}
