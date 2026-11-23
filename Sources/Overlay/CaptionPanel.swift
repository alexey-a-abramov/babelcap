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
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        minSize = NSSize(width: 260, height: 56)
        setFrameAutosaveName(autosaveName)
    }
}

/// Owns the subtitle window(s): one for Captions/Feed/Dual, two ("Them" / "Me") for Split.
///
/// - The panel is draggable and resizable by default; "click-through" turns both off.
/// - It is on screen only while a session is active (or while `preview` is on), so it never lingers.
@MainActor
public final class OverlayController {
    private let store: TranscriptStore
    private let settings: SettingsStore
    public let state = OverlayState()
    public var openSettings: (() -> Void)?

    /// A capture session is running (or ended moments ago).
    public var isActive = false { didSet { apply() } }
    /// Show the (empty) panel while idle so it can be positioned.
    public var preview = false { didSet { apply() } }

    private var panels: [String: CaptionPanel] = [:]
    private var splitMode = false
    private var lastHeightKey = ""
    private var resizeStart: (frame: NSRect, mouse: NSPoint)?

    public init(store: TranscriptStore, settings: SettingsStore) {
        self.store = store; self.settings = settings
        state.onHide = { [weak self] in self?.settings.profile.layout.showSubtitles = false }
        state.onToggleClickThrough = { [weak self] in self?.toggleClickThrough() }
        state.onOpenSettings = { [weak self] in self?.openSettings?() }
        state.onResizeBegan = { [weak self] in self?.resizeBegan() }
        state.onResizeChanged = { [weak self] in self?.resizeChanged() }
        state.onResizeEnded = { [weak self] in self?.resizeEnded() }
    }

    public func start() {
        rebuild()
        track()
    }

    /// true = the panel can be moved / resized.
    public var isEditing: Bool { !settings.profile.layout.clickThrough }

    public func toggleClickThrough() { settings.profile.layout.clickThrough.toggle() }
    public func toggleVisible() { settings.profile.layout.showSubtitles.toggle() }

    private func track() {
        withObservationTracking {
            _ = settings.profile.layout
            _ = settings.profile.appearance.original.size
            _ = settings.profile.content.mode
            _ = state.isFaded
        } onChange: { [weak self] in
            Task { @MainActor in self?.apply(); self?.track() }
        }
    }

    // MARK: Panels

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
            if !restored { placeFirstTime(panel, index: key == "mic" ? 1 : 0) }
        }
        lastHeightKey = ""
        apply()
    }

    private func placeFirstTime(_ panel: CaptionPanel, index: Int) {
        let l = settings.profile.layout
        let w = splitMode ? min(l.width, 640) : l.width
        let h = defaultHeight()
        guard let vis = NSScreen.main?.visibleFrame else { return }
        let x = vis.midX - w / 2 + (splitMode ? (index == 0 ? -w / 2 - 10 : w / 2 + 10) : 0)
        panel.setFrame(NSRect(x: x, y: vis.minY + 70, width: w, height: h), display: true)
    }

    private func defaultHeight() -> Double {
        let l = settings.profile.layout, a = settings.profile.appearance
        let both = settings.profile.content.mode == .both || l.mode == .dual
        let per = (a.original.size * 1.25 + a.original.lineSpacing) * (both ? 2 : 1)
        return l.mode == .feed ? 360 : per * Double(max(1, l.lines)) + a.padding * 2 + 16
    }

    private func apply() {
        if (settings.profile.layout.mode == .split) != splitMode { rebuild(); return }
        let l = settings.profile.layout
        let editing = !l.clickThrough
        state.isEditing = editing
        state.isActive = isActive || preview

        // Height follows mode / lines / font size, but a manual resize is otherwise left alone.
        let heightKey = "\(l.mode)|\(l.lines)|\(settings.profile.appearance.original.size)|\(settings.profile.content.mode)"
        let heightChanged = heightKey != lastHeightKey
        lastHeightKey = heightKey

        for (key, p) in panels {
            var f = p.frame
            let targetW = splitMode ? min(l.width, 640) : l.width
            if abs(f.width - targetW) > 0.5 {
                f.origin.x = f.midX - targetW / 2
                f.size.width = targetW
            }
            if heightChanged, resizeStart == nil {
                let h = defaultHeight()
                f.origin.y += f.height - h   // keep the top edge in place
                f.size.height = h
            }
            if f != p.frame { p.setFrame(f, display: true) }

            p.ignoresMouseEvents = !editing || state.isFaded
            if editing { p.styleMask.insert(.resizable) } else { p.styleMask.remove(.resizable) }
            p.isMovableByWindowBackground = editing
            p.level = switch l.level {
            case .statusBar: .statusBar
            case .popUp: .popUpMenu
            case .screenSaver: .screenSaver
            }
            p.sharingType = l.hideFromSharing ? .none : .readOnly
            _ = key
            if l.showSubtitles && (isActive || preview) { p.orderFrontRegardless() } else { p.orderOut(nil) }
        }
    }

    // MARK: Corner-grip resize (top-left stays fixed)

    private func resizeBegan() {
        guard let p = panels.values.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panels.values.first else { return }
        resizeStart = (p.frame, NSEvent.mouseLocation)
        resizeTarget = p
    }

    private var resizeTarget: CaptionPanel?

    private func resizeChanged() {
        guard let start = resizeStart, let p = resizeTarget else { return }
        let m = NSEvent.mouseLocation
        let w = max(p.minSize.width, start.frame.width + (m.x - start.mouse.x))
        let h = max(p.minSize.height, start.frame.height - (m.y - start.mouse.y))
        p.setFrame(NSRect(x: start.frame.minX, y: start.frame.maxY - h, width: w, height: h), display: true)
    }

    private func resizeEnded() {
        if let p = resizeTarget, !splitMode { settings.profile.layout.width = p.frame.width }
        resizeStart = nil
        resizeTarget = nil
    }
}
