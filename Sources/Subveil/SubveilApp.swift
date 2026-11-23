import AppSettings
import CaptionsCore
import SwiftUI

@main
struct SubveilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let ctx = AppContext.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(ctx: ctx)
        } label: {
            // Always visible while capturing: filled icon.
            Image(systemName: ctx.engine.isRunning ? "captions.bubble.fill" : "captions.bubble")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(settings: ctx.settings, engine: ctx.engine, store: ctx.store)
        }
    }
}

struct MenuContent: View {
    let ctx: AppContext

    var body: some View {
        let e = ctx.engine
        Button(e.isRunning ? "Stop" : "Start") { Task { await e.toggleStartStop() } }
            .keyboardShortcut(.space, modifiers: [.option, .command])
        Button(e.runState == .paused ? "Resume" : "Pause") { Task { await e.togglePause() } }
            .disabled(!e.isRunning)
        Divider()
        Menu("Source") {
            ForEach(SourceMode.allCases, id: \.self) { m in
                Button((ctx.settings.profile.sources == m ? "✓ " : "") + m.title) { Task { await e.setSources(m) } }
            }
        }
        Button("Show / hide control panel") { ctx.hud.toggleVisible() }
        Button("Show / hide subtitles") { ctx.overlay.toggleVisible() }
        Button("Move / resize subtitles") { ctx.toggleEditing() }
        Divider()
        Button("Welcome & permissions…") { ctx.showOnboarding() }
        Button("Settings…") { ctx.openSettings() }.keyboardShortcut(",")
        Divider()
        Button("Quit Subveil") { Task { await e.stop(); NSApp.terminate(nil) } }.keyboardShortcut("q")
    }
}
