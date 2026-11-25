import AppSettings
import CaptionsCore
import SwiftUI

@main
struct BabelcapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let ctx = AppContext.shared

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(ctx: ctx)
        } label: {
            // Always visible while capturing: filled icon + session timer (h:mm:ss) so a multi-hour session is obvious.
            HStack(spacing: 4) {
                Image(systemName: ctx.engine.runState == .paused ? "pause.circle.fill"
                      : ctx.engine.isRunning ? "captions.bubble.fill" : "captions.bubble")
                if ctx.engine.isRunning {
                    Text(Self.clock(ctx.engine.elapsed)).monospacedDigit()
                }
            }
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
        Menu("Translate to") {
            let t = ctx.settings.profile.translationSystem
            Button((t.kind == .off ? "✓ " : "") + "No translation") { ctx.setTarget(nil, for: nil) }
            Divider()
            ForEach(Languages.all, id: \.code) { l in
                Button((t.kind == .oneWay && t.target == l.code ? "✓ " : "") + l.name) { ctx.setTarget(l.code, for: nil) }
            }
        }
        Button("Show / hide control panel") { ctx.hud.toggleVisible() }
        Button("Show / hide subtitles") { ctx.overlay.toggleVisible() }
        Button("Position subtitles (preview)") { ctx.togglePositioning() }
        Button(ctx.settings.profile.layout.clickThrough ? "Make subtitles movable / resizable" : "Make subtitles click-through") { ctx.toggleEditing() }
        Divider()
        Button("Models & Providers…") { ctx.openModelCatalog() }
        Button("Welcome & permissions…") { ctx.showOnboarding() }
        Button("Settings…") { ctx.openSettings() }.keyboardShortcut(",")
        Divider()
        Button("Quit Babelcap") { ctx.quit() }.keyboardShortcut("q")
    }
}
