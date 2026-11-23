import AppKit
import AppSettings
import CaptionsCore
import ControlHUD
import Overlay
import SwiftUI
import Transcript

@MainActor
final class AppContext {
    static let shared = AppContext()

    let settings = SettingsStore()
    let store = TranscriptStore()
    let engine: CaptionsEngine
    let overlay: OverlayController
    private(set) var hud: ControlPanelController!
    private var onboardingWindow: NSWindow?
    private var booted = false

    private init() {
        engine = CaptionsEngine(settings: settings, store: store)
        overlay = OverlayController(store: store, settings: settings)
    }

    func boot() {
        guard !booted else { return }
        booted = true
        hud = ControlPanelController(
            settings: settings, engine: engine, store: store,
            actions: HUDActions(
                openSettings: { [weak self] in self?.openSettings() },
                toggleEditing: { [weak self] in self?.toggleEditing() },
                export: { [weak self] in self?.export($0) },
                hidePanel: { [weak self] in self?.hud.hide() },
                quit: { [weak self] in self?.quit() }))
        hud.show()
        overlay.openSettings = { [weak self] in self?.openSettings() }
        overlay.start()
        applyDockPolicy()
        trackDock()
        trackEngine()
        HotKeys.shared.registerDefaults(self)
        if !settings.onboardingDone || !settings.hasAPIKey { showOnboarding() }
    }

    // MARK: Actions

    func openSettings() {
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// ⌥⌘L / lock button: subtitles movable+resizable  ⇄  click-through.
    func toggleEditing() { overlay.toggleClickThrough() }

    /// Show the empty subtitle panel while idle so it can be positioned.
    func togglePositioning() {
        overlay.preview.toggle()
        if overlay.preview {
            settings.profile.layout.showSubtitles = true
            settings.profile.layout.clickThrough = false
        }
    }

    // The subtitle panel exists only while a session runs (and a few seconds after it ends).
    private var hideTask: Task<Void, Never>?

    private func trackEngine() {
        withObservationTracking { _ = engine.runState } onChange: { [weak self] in
            Task { @MainActor in self?.engineStateChanged(); self?.trackEngine() }
        }
    }

    private var lastRunState: RunState = .idle

    private func engineStateChanged() {
        defer { lastRunState = engine.runState }
        hideTask?.cancel()
        if engine.isRunning {
            // A new session always starts with the subtitles visible (hiding is per session).
            if lastRunState == .idle, !settings.profile.layout.showSubtitles { settings.profile.layout.showSubtitles = true }
            overlay.preview = false
            overlay.isActive = true
        } else {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.overlay.isActive = false
            }
        }
    }

    // MARK: Dock icon (menu bar item is always there)

    func applyDockPolicy() {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        if settings.showInDock { NSApp.applicationIconImage = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage }
    }

    private func trackDock() {
        withObservationTracking { _ = settings.showInDock } onChange: { [weak self] in
            Task { @MainActor in self?.applyDockPolicy(); self?.trackDock() }
        }
    }

    func export(_ format: ExportFormat) {
        let text = store.export(format)
        NSApp.activate()
        if let folder = settings.profile.session.exportFolder {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"
            let url = URL(fileURLWithPath: folder).appendingPathComponent("transcript_\(f.string(from: store.sessionStart)).\(format.fileExtension)")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "transcript.\(format.fileExtension)"
        panel.begin { resp in
            if resp == .OK, let url = panel.url { try? text.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    func quit() {
        Task { await engine.stop(); NSApp.terminate(nil) }
    }

    func cycleSource() {
        let all = SourceMode.allCases
        let next = all[(all.firstIndex(of: settings.profile.sources)! + 1) % all.count]
        Task { await engine.setSources(next) }
    }

    func toggleTranslation() {
        let on = settings.profile.translationSystem.kind == .off && settings.profile.translationMic.kind == .off
        let kind: TranslationSettings.Kind = on ? .oneWay : .off
        settings.profile.translationSystem.kind = kind
        settings.profile.translationMic.kind = kind
        Task { await engine.applyConfigChange() }
    }

    func showOnboarding() {
        if let w = onboardingWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let view = OnboardingView(settings: settings) { [weak self] in
            self?.onboardingWindow?.close(); self?.onboardingWindow = nil
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Welcome to Subveil"
        w.styleMask = [.titled, .closable]
        w.center()
        onboardingWindow = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppContext.shared.boot() }
    }

    /// Clicking the Dock icon brings the control panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            AppContext.shared.hud.show()
            if !AppContext.shared.settings.hasAPIKey { AppContext.shared.showOnboarding() }
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        let items: [(String, Selector)] = [("Start / Stop", #selector(dockToggle)), ("Show control panel", #selector(dockShowHUD)),
                                           ("Settings…", #selector(dockSettings))]
        for (t, a) in items { let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; m.addItem(i) }
        return m
    }

    @objc private func dockToggle() { MainActor.assumeIsolated { Task { await AppContext.shared.engine.toggleStartStop() } } }
    @objc private func dockShowHUD() { MainActor.assumeIsolated { AppContext.shared.hud.show() } }
    @objc private func dockSettings() { MainActor.assumeIsolated { AppContext.shared.openSettings() } }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous: persist the running session's transcript before the process exits.
        MainActor.assumeIsolated { AppContext.shared.engine.saveHistory() }
    }
}
