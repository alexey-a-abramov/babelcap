import AppKit
import AppSettings
import CaptionsCore
import CatalogUI
import ControlHUD
import Overlay
import SonioxClient
import LocalEngines
import ModelHub
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
    private var voice: TranslationVoice?
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
                quit: { [weak self] in self?.quit() },
                openModels: { [weak self] in self?.openModelCatalog() }))
        voice = TranslationVoice(store: store, settings: settings)
        hud.show()
        overlay.openSettings = { [weak self] in self?.openSettings() }
        overlay.state.onSetTarget = { [weak self] code, source in self?.setTarget(code, for: source) }
        overlay.start()
        applyDockPolicy()
        trackDock()
        trackEngine()
        trackSettingsForEngine()
        HotKeys.shared.apply(self)
        trackHotkeys()
        if CommandLine.arguments.contains("--selftest-translate") { selfTestTranslate(); return }
        if CommandLine.arguments.contains("--open-models") { openModelCatalog() }
        else if !settings.onboardingDone || (engine.provider.needsAPIKey && !settings.hasAPIKey) { showOnboarding() }
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

    // One place reacts to settings changes during a session (HUD, subtitle toolbar, menu bar, Settings window, profile switch).
    private var syncTask: Task<Void, Never>?

    private func trackSettingsForEngine() {
        withObservationTracking {
            _ = settings.profile
            _ = settings.activeID
            _ = settings.modelName
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncTask?.cancel()
                self.syncTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    self.store.dedupeEchoes = self.settings.profile.session.dedupeEchoes
                    await self.engine.syncWithSettings()
                }
                self.trackSettingsForEngine()
            }
        }
    }

    /// Menu bar / toolbar: translate one source (or both) into `code`; nil turns translation off.
    func setTarget(_ code: String?, for source: SourceKind?) {
        func apply(_ t: inout TranslationSettings) {
            if let code { t.kind = .oneWay; t.target = code } else { t.kind = .off }
        }
        if source != .mic { apply(&settings.profile.translationSystem) }
        if source != .system { apply(&settings.profile.translationMic) }
    }

    private func trackHotkeys() {
        withObservationTracking { _ = settings.hotkeys } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                HotKeys.shared.apply(self)
                self.trackHotkeys()
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

    /// Diagnostics: translate one sentence with the current translator inside the real app bundle, log it, quit.
    private func selfTestTranslate() {
        Task {
            let useApple = CommandLine.arguments.contains("apple")
            let tr: (any TextTranslator)? = useApple ? AppleTextTranslator() : TranslatorChoice.resolve(settings.translatorID)
            let (text, src) = useApple ? ("Guten Morgen zusammen. Heute besprechen wir den Release-Plan.", "de")
                                       : ("Доброе утро всем. Сегодня мы обсудим план релиза.", "ru")
            let t0 = Date()
            do {
                let out = try await tr?.translate(text, from: src, to: "en") ?? "(no translator)"
                Trace.log("selftest", "\(tr?.name ?? "-"): \(out) (\(String(format: "%.2f", Date().timeIntervalSince(t0))) s)")
            } catch {
                Trace.log("selftest", "\(tr?.name ?? "-") failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.terminate(nil)
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
        settings.profile.translationMic.kind = kind   // the settings watcher swaps the affected sessions
    }

    private var catalogWindow: NSWindow?

    /// "Models & Providers" — a large, resizable window.
    func openModelCatalog() {
        NSApp.activate()
        if let w = catalogWindow { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: ModelCatalogView(settings: settings, engine: engine)))
        w.title = "Models & Providers"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 1240, height: 800))
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("SubveilModelCatalog")
        w.center()
        catalogWindow = w
        w.makeKeyAndOrderFront(nil)
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
