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
        identifier = NSUserInterfaceItemIdentifier(autosaveName)
    }
}

/// Owns the subtitle window(s): one combined panel, or two ("System" / "Mic") in Both mode.
///
/// - The panel is draggable and resizable by default; "click-through" turns both off (hold ⌘ to override).
/// - It is on screen only while a session is active (or while `preview` is on), so it never lingers.
/// - Every panel's position and size are remembered (across hide/show, sessions and launches).
/// - Split / merge from the toolbar lasts for the current session only; a new session starts from the setting.
@MainActor
public final class OverlayController {
    private let store: TranscriptStore
    private let settings: SettingsStore
    public let state = OverlayState()
    public var openSettings: (() -> Void)?

    /// A capture session is running (or ended moments ago).
    public var isActive = false {
        didSet {
            if isActive && !oldValue { splitOverride = nil }   // a new session starts from the default layout
            apply()
        }
    }
    /// Show the (empty) panel while idle so it can be positioned.
    public var preview = false { didSet { apply() } }

    private var panels: [String: CaptionPanel] = [:]
    private var splitMode = false
    /// Toolbar split / merge choice — not persisted.
    private var splitOverride: Bool?
    /// Last Width-slider value applied, so a manual resize is never overridden.
    private var appliedWidth: Double?
    private var gesture: (frame: NSRect, mouse: NSPoint, edges: ResizeEdges, panel: CaptionPanel)?

    public init(store: TranscriptStore, settings: SettingsStore) {
        self.store = store; self.settings = settings
        state.onHide = { [weak self] in self?.settings.profile.layout.showSubtitles = false }
        state.onToggleClickThrough = { [weak self] in self?.toggleClickThrough() }
        state.onOpenSettings = { [weak self] in self?.openSettings?() }
        state.onToggleSplit = { [weak self] in
            guard let self else { return }
            splitOverride = !wantsSplit
            apply()
        }
        state.onMoveBegan = { [weak self] in self?.moveBegan() }
        state.onMoveChanged = { [weak self] in self?.moveChanged() }
        state.onMoveEnded = { [weak self] in self?.moveEnded() }
        state.onResizeBegan = { [weak self] in self?.resizeBegan($0) }
        state.onResizeChanged = { [weak self] in self?.resizeChanged() }
        state.onResizeEnded = { [weak self] in self?.resizeEnded() }
    }

    /// Two panels only make sense for two separate streams; the toolbar choice beats the setting for this session.
    private var wantsSplit: Bool {
        let p = settings.profile
        guard p.sources == .both, !p.session.mixIntoOne else { return false }
        return splitOverride ?? p.layout.separateSources
    }

    public func start() {
        appliedWidth = settings.profile.layout.width
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        rebuild()
        track()
        watchCommandKey()
    }

    /// true = the panel can be moved / resized.
    public var isEditing: Bool { !settings.profile.layout.clickThrough }

    public func toggleClickThrough() { settings.profile.layout.clickThrough.toggle() }
    public func toggleVisible() { settings.profile.layout.showSubtitles.toggle() }

    private func track() {
        withObservationTracking {
            _ = settings.profile.layout
            _ = settings.profile.sources
            _ = settings.profile.session.mixIntoOne
            _ = settings.profile.appearance.original.size
            _ = settings.profile.content.mode
            _ = state.isFaded
        } onChange: { [weak self] in
            Task { @MainActor in self?.apply(); self?.track() }
        }
    }

    // MARK: Panels

    private func rebuild() {
        splitMode = wantsSplit
        state.isSplit = splitMode
        let wanted: [(String, SourceKind?)] = splitMode ? [("system", .system), ("mic", .mic)] : [("main", nil)]

        // Remember the frames of panels going away (they are restored next time they appear).
        var known: [String: NSRect] = [:]
        for (k, p) in panels { known[k] = p.frame }
        for (k, p) in panels where !wanted.contains(where: { $0.0 == k }) {
            Self.saveFrame(p.frame, key: k)
            if let o = observers.removeValue(forKey: k) { o.forEach { NotificationCenter.default.removeObserver($0) } }
            p.orderOut(nil)
            panels[k] = nil
        }

        for (key, filter) in wanted where panels[key] == nil {
            let panel = CaptionPanel(autosaveName: Self.name(key))
            let root = CaptionView(store: store, settings: settings, state: state, filter: filter)
            let host = FirstMouseHostingView(rootView: root)
            host.sizingOptions = []
            panel.contentView = host
            panels[key] = panel
            panel.setFrame(Self.savedFrame(key) ?? initialFrame(for: key, known: known), display: true)
            // Remember every move / resize, whatever caused it.
            observers[key] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak panel] _ in
                    guard let panel else { return }
                    MainActor.assumeIsolated { Self.saveFrame(panel.frame, key: key) }
                }
            }
        }
        apply()
    }

    private static func name(_ key: String) -> String { "SubveilCaption.\(key)" }
    private var observers: [String: [NSObjectProtocol]] = [:]
    private var screenObserver: NSObjectProtocol?

    /// Monitor plugged in / out: go to the place remembered for this setup, or back onto a visible screen.
    private func screensChanged() {
        for (key, p) in panels {
            if let saved = UserDefaults.standard.string(forKey: Self.screenKey(key)).map(NSRectFromString), saved.width > 0 {
                p.setFrame(saved, display: true)
            } else if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(p.frame) }), let vis = NSScreen.main?.visibleFrame {
                var f = p.frame
                f.size.width = min(f.width, vis.width - 40)
                f.origin = NSPoint(x: vis.midX - f.width / 2, y: vis.minY + 70)
                p.setFrame(f, display: true)
            }
        }
    }

    // Own frame storage: the system frame autosave does not restore the size of panels that are not resizable
    // at creation time (and click-through panels are not resizable).
    static func defaultsKey(_ key: String) -> String { "SubveilCaption.\(key).frame" }

    /// Positions are remembered per monitor setup: laptop alone vs. laptop + HDMI display keep their own places.
    static var screenSignature: String {
        NSScreen.screens.map { s in "\(Int(s.frame.minX)),\(Int(s.frame.minY)),\(Int(s.frame.width))x\(Int(s.frame.height))" }
            .sorted().joined(separator: "|")
    }
    static func screenKey(_ key: String) -> String { defaultsKey(key) + "." + screenSignature }

    static func saveFrame(_ r: NSRect, key: String) {
        guard r.width > 0, r.height > 0 else { return }
        UserDefaults.standard.set(NSStringFromRect(r), forKey: screenKey(key))
        UserDefaults.standard.set(NSStringFromRect(r), forKey: defaultsKey(key))   // fallback for an unknown setup
    }

    /// The saved frame, if it is still (at least partly) on a connected screen.
    static func savedFrame(_ key: String) -> NSRect? {
        var r = NSRect.zero
        if let s = UserDefaults.standard.string(forKey: screenKey(key)) {
            r = NSRectFromString(s)
        } else if let s = UserDefaults.standard.string(forKey: defaultsKey(key)) {
            r = NSRectFromString(s)
        } else if let legacy = UserDefaults.standard.string(forKey: "NSWindow Frame \(name(key))") {
            // Frame saved by the earlier system autosave ("x y w h …"): keep the user's position after the update.
            let n = legacy.split(separator: " ").prefix(4).compactMap { Double($0) }
            if n.count == 4 { r = NSRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
        }
        guard r.width >= 100, r.height >= 40 else { return nil }
        let screens = NSScreen.screens.map(\.frame)
        guard screens.isEmpty || screens.contains(where: { $0.intersects(r) }) else { return nil }
        return r
    }

    /// Current panel frames by key ("main", "system", "mic") — for tests and diagnostics.
    var panelFrames: [String: NSRect] { panels.mapValues(\.frame) }
    var panelForTesting: (String) -> CaptionPanel? { { self.panels[$0] } }

    /// Only for a panel that has never been shown (otherwise its saved frame is restored exactly as it was):
    /// bottom of the screen, the two source panels side by side.
    private func initialFrame(for key: String, known: [String: NSRect]) -> NSRect {
        let gap: CGFloat = 12
        let l = settings.profile.layout
        let w = key == "main" ? l.width : min(l.width, 640)
        let h = defaultHeight()
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = key == "main" ? vis.midX - w / 2 : (key == "system" ? vis.midX - w - gap / 2 : vis.midX + gap / 2)
        return NSRect(x: x, y: vis.minY + 70, width: w, height: h)
    }

    private func defaultHeight() -> Double {
        let l = settings.profile.layout, a = settings.profile.appearance
        let both = settings.profile.content.mode == .both || l.mode == .dual
        let per = (a.original.size * 1.25 + a.original.lineSpacing) * (both ? 2 : 1)
        return l.mode == .feed ? 360 : per * Double(max(1, l.lines)) + a.padding * 2 + 16
    }

    private func apply() {
        if wantsSplit != splitMode { rebuild(); return }
        let l = settings.profile.layout
        // Click-through can always be overridden by holding ⌘ over the panel.
        let editing = !l.clickThrough || commandOverride || gesture != nil
        state.isEditing = editing
        state.isActive = isActive || preview

        // Panels keep the size the user gave them — text scrolls inside, a panel never grows.
        // Only moving the Width slider in Settings resizes the combined panel.
        let widthChanged = appliedWidth != nil && appliedWidth != l.width
        appliedWidth = l.width
        for (key, p) in panels {
            if widthChanged, !splitMode, gesture == nil, abs(p.frame.width - l.width) > 0.5 {
                var f = p.frame
                f.origin.x = f.midX - l.width / 2
                f.size.width = l.width
                p.setFrame(f, display: true)
            }

            p.ignoresMouseEvents = !editing || (state.isFaded && !commandOverride)
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

    // MARK: ⌘ override for click-through

    private var commandOverride = false
    private var commandTask: Task<Void, Never>?

    /// Polls the modifier state (no Accessibility permission needed): while ⌘ is held with the pointer over a
    /// click-through panel, the panel accepts the mouse so it can be dragged or resized.
    private func watchCommandKey() {
        commandTask?.cancel()
        commandTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self else { return }
                let visible = panels.values.contains { $0.isVisible }
                let over = panels.values.contains { $0.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) }
                let want = visible && settings.profile.layout.clickThrough && over && NSEvent.modifierFlags.contains(.command)
                if want != commandOverride, gesture == nil {
                    commandOverride = want
                    apply()
                }
            }
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
        apply()
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
        if let g = gesture {
            if !splitMode {
                appliedWidth = g.panel.frame.width          // the slider follows the manual resize, without a re-apply
                settings.profile.layout.width = g.panel.frame.width
            }
        }
        gesture = nil
        apply()
    }
}
