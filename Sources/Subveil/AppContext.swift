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
                export: { [weak self] in self?.export($0) }))
        hud.show()
        overlay.start()
        HotKeys.shared.registerDefaults(self)
        if !settings.onboardingDone || !settings.hasAPIKey { showOnboarding() }
    }

    // MARK: Actions

    func openSettings() {
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func toggleEditing() {
        overlay.toggleEditing()
        hud.overlayInfo.isEditing = overlay.isEditing
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

    func applicationWillTerminate(_ notification: Notification) {
        // Best effort: persist the history of a running session.
        MainActor.assumeIsolated {
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in await AppContext.shared.engine.stop(); sem.signal() }
            _ = sem.wait(timeout: .now() + 0.01)
        }
    }
}
