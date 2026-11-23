import AppKit
import AppSettings
import SonioxClient
import SwiftUI
import Transcript

/// Hosting view that reacts to the very first click even though the panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

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
        isMovableByWindowBackground = false   // moving is done by our own drag gesture (reliable with SwiftUI content)
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
    private var gesture: (frame: NSRect, mouse: NSPoint, edges: ResizeEdges, panel: CaptionPanel)?

    public init(store: TranscriptStore, settings: SettingsStore) {
        self.store = store; self.settings = settings
        state.onHide = { [weak self] in self?.settings.profile.layout.showSubtitles = false }
        state.onToggleClickThrough = { [weak self] in self?.toggleClickThrough() }
        state.onOpenSettings = { [weak self] in self?.openSettings?() }
        state.onMoveBegan = { [weak self] in self?.moveBegan() }
        state.onMoveChanged = { [weak self] in self?.moveChanged() }
        state.onMoveEnded = { [weak self] in self?.moveEnded() }
        state.onResizeBegan = { [weak self] in self?.resizeBegan($0) }
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
            let host = FirstMouseHostingView(rootView: root)
            host.sizingOptions = []
            panel.contentView = host
            let restored = panel.setFrameUsingName("SubveilCaption.\(key)")
            panels[key] = panel
            if !restored { placeFirstTime(panel, index: key == "mic" ? 1 : 0) }
        }
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

        // The panel keeps the size the user gave it — text scrolls inside, the panel never grows.
        // Only the Width slider in Settings changes it (and only when it differs).
        for (key, p) in panels {
            let targetW = splitMode ? min(l.width, 640) : l.width
            if gesture == nil, abs(p.frame.width - targetW) > 0.5 {
                var f = p.frame
                f.origin.x = f.midX - targetW / 2
                f.size.width = targetW
                p.setFrame(f, display: true)
            }

            p.ignoresMouseEvents = !editing || state.isFaded
            if editing { p.styleMask.insert(.resizable) } else { p.styleMask.remove(.resizable) }
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

    // MARK: Move (with snapping) and resize from any edge

    private func panelUnderMouse() -> CaptionPanel? {
        panels.values.first { $0.frame.insetBy(dx: -10, dy: -10).contains(NSEvent.mouseLocation) } ?? panels.values.first
    }

    private func moveBegan() {
        guard let p = panelUnderMouse() else { return }
        gesture = (p.frame, NSEvent.mouseLocation, [], p)
        NSCursor.closedHand.push()
    }

    private func moveChanged() {
        guard let g = gesture, g.edges.isEmpty else { return }
        let m = NSEvent.mouseLocation
        var f = g.frame.offsetBy(dx: m.x - g.mouse.x, dy: m.y - g.mouse.y)
        if let vis = (g.panel.screen ?? NSScreen.main)?.visibleFrame {
            let snap: CGFloat = 14
            if abs(f.midX - vis.midX) < snap { f.origin.x = vis.midX - f.width / 2 }      // centre
            if abs(f.minX - vis.minX) < snap { f.origin.x = vis.minX }                    // edges
            if abs(f.maxX - vis.maxX) < snap { f.origin.x = vis.maxX - f.width }
            if abs(f.minY - vis.minY) < snap { f.origin.y = vis.minY }
            if abs(f.maxY - vis.maxY) < snap { f.origin.y = vis.maxY - f.height }
        }
        g.panel.setFrameOrigin(f.origin)
    }

    private func moveEnded() {
        if gesture != nil { NSCursor.pop() }
        gesture = nil
    }

    private func resizeBegan(_ edges: ResizeEdges) {
        guard let p = panelUnderMouse() else { return }
        gesture = (p.frame, NSEvent.mouseLocation, edges, p)
    }

    private func resizeChanged() {
        guard let g = gesture, !g.edges.isEmpty else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - g.mouse.x, dy = m.y - g.mouse.y
        let minW = g.panel.minSize.width, minH = g.panel.minSize.height
        var f = g.frame
        if g.edges.contains(.right) { f.size.width = max(minW, g.frame.width + dx) }
        if g.edges.contains(.left) {
            let w = max(minW, g.frame.width - dx)
            f.origin.x = g.frame.maxX - w; f.size.width = w
        }
        if g.edges.contains(.top) { f.size.height = max(minH, g.frame.height + dy) }
        if g.edges.contains(.bottom) {
            let h = max(minH, g.frame.height - dy)
            f.origin.y = g.frame.maxY - h; f.size.height = h
        }
        g.panel.setFrame(f, display: true)
    }

    private func resizeEnded() {
        if let g = gesture, !splitMode { settings.profile.layout.width = g.panel.frame.width }
        gesture = nil
    }
}
