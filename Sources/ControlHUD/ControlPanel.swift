import AppKit
import AppSettings
import CaptionsCore
import SwiftUI
import Transcript

public final class ControlPanel: NSPanel {
    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }
}

@MainActor
public final class ControlPanelController {
    public let hud = HUDState()
    public let overlayInfo = ControlOverlayInfo()
    private let panel: ControlPanel
    private var idleTask: Task<Void, Never>?
    private let engine: CaptionsEngine

    static let normal = NSSize(width: 380, height: 56)
    static let expanded = NSSize(width: 380, height: 520)
    static let compact = NSSize(width: 200, height: 40)

    public init(settings: SettingsStore, engine: CaptionsEngine, store: TranscriptStore, actions: HUDActions) {
        self.engine = engine
        panel = ControlPanel(contentRect: NSRect(origin: .zero, size: Self.normal),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 22
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        panel.contentView = fx

        let host = NSHostingView(rootView: ControlView(settings: settings, engine: engine, store: store, hud: hud,
                                                       overlay: overlayInfo, actions: actions))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor), host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor), host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])

        if !panel.setFrameUsingName("SubveilHUD"), let vis = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: vis.midX - Self.normal.width / 2, y: vis.maxY - 40))
        }
        panel.setFrameAutosaveName("SubveilHUD")
        applySize(animated: false)
        track()
        idleLoop()
    }

    public func show() { panel.orderFrontRegardless() }
    public func hide() { panel.orderOut(nil) }
    public var isVisible: Bool { panel.isVisible }
    public func toggleVisible() { isVisible ? hide() : show() }

    private func track() {
        withObservationTracking {
            _ = hud.expanded; _ = hud.compact
        } onChange: { [weak self] in
            Task { @MainActor in self?.applySize(animated: true); self?.track() }
        }
    }

    private func applySize(animated: Bool) {
        let size = hud.compact ? Self.compact : (hud.expanded ? Self.expanded : Self.normal)
        let old = panel.frame
        let frame = NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true, animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        (panel.contentView as? NSVisualEffectView)?.layer?.cornerRadius = hud.compact ? 20 : 22
    }

    /// Collapse into a pill after a few idle seconds while capturing.
    private func idleLoop() {
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if engine.runState == .running, !hud.expanded, !hud.compact, Date().timeIntervalSince(hud.lastInteraction) > 8 {
                    hud.compact = true
                }
            }
        }
    }
}
