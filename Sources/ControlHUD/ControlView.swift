import AppKit
import AppSettings
import AudioCapture
import CaptionsCore
import SonioxClient
import SwiftUI
import Transcript

@MainActor @Observable
public final class HUDState {
    public var expanded = false
    public var compact = false
    public var lastInteraction = Date()
    public init() {}
    public func touch() { lastInteraction = Date(); if compact { compact = false } }
}

public struct HUDActions {
    public var openSettings: () -> Void
    public var toggleEditing: () -> Void
    public var export: (ExportFormat) -> Void
    public var hidePanel: () -> Void
    public var quit: () -> Void
    public init(openSettings: @escaping () -> Void, toggleEditing: @escaping () -> Void, export: @escaping (ExportFormat) -> Void,
                hidePanel: @escaping () -> Void, quit: @escaping () -> Void) {
        self.openSettings = openSettings; self.toggleEditing = toggleEditing; self.export = export
        self.hidePanel = hidePanel; self.quit = quit
    }
}

public struct ControlView: View {
    @Bindable var settings: SettingsStore
    let engine: CaptionsEngine
    let store: TranscriptStore
    var hud: HUDState
    var overlay: ControlOverlayInfo
    let actions: HUDActions

    @State private var devices: [AudioInputDevice] = []
    @State private var apps: [AudioApp] = []
    @State private var showApps = false
    @State private var search = ""
    @State private var configTask: Task<Void, Never>?
    @Namespace private var ns

    public init(settings: SettingsStore, engine: CaptionsEngine, store: TranscriptStore, hud: HUDState,
                overlay: ControlOverlayInfo, actions: HUDActions) {
        self.settings = settings; self.engine = engine; self.store = store; self.hud = hud
        self.overlay = overlay; self.actions = actions
    }

    public var body: some View {
        Group {
            if hud.compact { pill } else { full }
        }
        .onHover { if $0 { hud.touch() } }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: hud.expanded)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: hud.compact)
        .task { await refreshLoop() }
        .onChange(of: settings.profile.translationSystem) { scheduleConfigChange() }
        .onChange(of: settings.profile.translationMic) { scheduleConfigChange() }
    }

    // MARK: Layouts

    private var pill: some View {
        HStack(spacing: 10) {
            StatusBadge(state: engine.overall, runState: engine.runState, elapsed: engine.elapsed)
            LevelBar(level: max(engine.levels[.system] ?? 0, engine.levels[.mic] ?? 0), height: 4).frame(width: 44)
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", help: "Hide this panel — bring it back from the menu bar / Dock icon or ⌥⌘H",
                       action: actions.hidePanel)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var full: some View {
        VStack(spacing: 0) {
            header.frame(height: 56)
            if hud.expanded {
                Divider().opacity(0.4)
                ScrollView { expandedBody.padding(14) }.scrollIndicators(.never)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusBadge(state: engine.overall, runState: engine.runState, elapsed: engine.elapsed)
                .onTapGesture { if case .error = engine.overall { hud.expanded = true } }
            SourcePicker(selection: settings.profile.sources,
                         system: engine.levels[.system] ?? 0, mic: engine.levels[.mic] ?? 0,
                         running: engine.isRunning) { m in
                hud.touch()
                Task { await engine.setSources(m) }
            }
            Spacer(minLength: 0)
            controls
            IconButton(symbol: settings.profile.layout.showSubtitles ? "captions.bubble" : "captions.bubble.fill",
                       help: settings.profile.layout.showSubtitles ? "Hide subtitles (⌥⌘C)" : "Subtitles are hidden — click to show (⌥⌘C)",
                       highlighted: !settings.profile.layout.showSubtitles) {
                settings.profile.layout.showSubtitles.toggle(); hud.touch()
            }
            IconButton(symbol: "chevron.down", help: hud.expanded ? "Collapse" : "Options, translation and history",
                       rotation: hud.expanded ? 180 : 0) { hud.expanded.toggle(); hud.touch() }
            IconButton(symbol: "xmark", help: "Hide this panel — bring it back from the menu bar / Dock icon or ⌥⌘H",
                       action: actions.hidePanel)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var controls: some View {
        switch engine.runState {
        case .idle:
            Button { Task { await engine.start() } } label: { Label("Start", systemImage: "play.fill").labelStyle(.iconOnly) }
                .buttonStyle(HUDButtonStyle(tint: .green)).help("Start captions (⌥⌘Space)")
        case .running, .paused:
            Button { Task { await engine.togglePause() } } label: {
                Image(systemName: engine.runState == .paused ? "play.fill" : "pause.fill")
            }.buttonStyle(HUDButtonStyle(tint: .orange)).help("Pause / resume")
            Button { Task { await engine.stop() } } label: { Image(systemName: "stop.fill") }
                .buttonStyle(HUDButtonStyle(tint: Color(white: 0.35))).help("Stop and save the transcript")
        }
    }

    // MARK: Expanded

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            hints
            sourcesRow
            translationRow
            displayRow
            sessionRow
            Divider().opacity(0.4)
            historySection
        }
        .font(.callout)
    }

    @ViewBuilder private var hints: some View {
        if engine.needsKey {
            HintRow(icon: "key.fill", text: "Soniox API key required", button: "Open Settings", action: actions.openSettings)
        }
        if engine.systemPermissionHint {
            HintRow(icon: "exclamationmark.triangle.fill", text: "System audio is silent while something is playing — permission may be denied.",
                    button: "Privacy & Security") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
            }
        }
        if engine.speakerEchoHint {
            HintRow(icon: "headphones", text: "Built-in speakers + mic: use headphones to avoid echo/duplicates.")
        }
        if let e = engine.lastError, !engine.needsKey {
            HintRow(icon: "exclamationmark.circle.fill", text: e, tint: .red)
        }
    }

    private var sourcesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    Button("System default") { Task { await engine.setMicDevice(nil) } }
                    Divider()
                    ForEach(devices) { d in
                        Button(d.name) { Task { await engine.setMicDevice(d.uid) } }
                    }
                } label: {
                    Label(micName, systemImage: "mic.fill").lineLimit(1)
                }
                Button { showApps.toggle() } label: {
                    Label(appsSummary, systemImage: "app.badge").lineLimit(1)
                }
                .popover(isPresented: $showApps) { appsPopover }
            }
            Toggle("Mix into one stream", isOn: Binding(get: { settings.profile.session.mixIntoOne },
                                                        set: { v in Task { await engine.setMix(v) } }))
                .toggleStyle(.switch).controlSize(.small)
                .disabled(settings.profile.sources != .both)
        }
    }

    private var micName: String {
        guard let uid = settings.profile.recognition.micDeviceUID else { return "Mic: default" }
        return devices.first { $0.uid == uid }?.name ?? "Mic: missing"
    }

    private var appsSummary: String {
        let ids = settings.profile.recognition.appBundleIDs
        return ids.isEmpty ? "All system audio" : "\(ids.count) app\(ids.count == 1 ? "" : "s")"
    }

    private var appsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("All system audio", isOn: Binding(get: { settings.profile.recognition.appBundleIDs.isEmpty },
                                                     set: { if $0 { Task { await engine.setApps([]) } } }))
            Divider()
            if apps.isEmpty { Text("No apps with audio yet").foregroundStyle(.secondary) }
            ForEach(apps) { app in
                Toggle(isOn: Binding(
                    get: { settings.profile.recognition.appBundleIDs.contains(app.bundleID) },
                    set: { on in
                        var ids = settings.profile.recognition.appBundleIDs
                        if on { ids.append(app.bundleID) } else { ids.removeAll { $0 == app.bundleID } }
                        Task { await engine.setApps(ids) }
                    })) {
                    HStack(spacing: 6) {
                        if let icon = AudioProcessList.icon(forBundleID: app.bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                        Text(app.name)
                        if app.isPlaying { Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundStyle(.green) }
                    }
                }
            }
        }
        .padding(12).frame(minWidth: 240)
    }

    private var translationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Translation").font(.caption).foregroundStyle(.secondary)
            HStack {
                if settings.profile.sources != .mic { translationMenu("Them", $settings.profile.translationSystem) }
                if settings.profile.sources != .system { translationMenu("Me", $settings.profile.translationMic) }
            }
        }
    }

    private func translationMenu(_ title: String, _ b: Binding<TranslationSettings>) -> some View {
        Menu {
            Picker("Mode", selection: b.kind) { ForEach(TranslationSettings.Kind.allCases, id: \.self) { Text($0.title).tag($0) } }
            if b.wrappedValue.kind == .oneWay {
                Picker("Target", selection: b.target) { ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) } }
            }
            if b.wrappedValue.kind == .twoWay {
                Picker("Language A", selection: b.languageA) { ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) } }
                Picker("Language B", selection: b.languageB) { ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) } }
            }
        } label: {
            switch b.wrappedValue.kind {
            case .off: Text("\(title): off")
            case .oneWay: Text("\(title) → \(b.wrappedValue.target.uppercased())")
            case .twoWay: Text("\(title) \(b.wrappedValue.languageA.uppercased())↔\(b.wrappedValue.languageB.uppercased())")
            }
        }
    }

    private var displayRow: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $settings.profile.layout.showSubtitles) { Image(systemName: "captions.bubble") }
                .toggleStyle(.button).help("Show / hide subtitles")
            Picker("", selection: $settings.profile.content.mode) {
                ForEach(ContentDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 100)
            Button { bumpFont(-2) } label: { Text("A−") }.help("Smaller")
            Button { bumpFont(2) } label: { Text("A+") }.help("Larger")
            Toggle(isOn: $settings.profile.content.showSourceLabel) { Image(systemName: "person.text.rectangle") }
                .toggleStyle(.button).help("Show “Them” / “Me” labels in subtitles")
            Button { actions.toggleEditing(); hud.touch() } label: {
                Image(systemName: settings.profile.layout.clickThrough ? "lock.fill" : "lock.open.fill")
            }.help(settings.profile.layout.clickThrough
                   ? "Subtitles are click-through. Click to make them movable / resizable"
                   : "Subtitles can be dragged and resized. Click to make them click-through")
            Spacer()
        }
    }

    private func bumpFont(_ d: Double) {
        let a = settings.profile.appearance
        settings.profile.appearance.original.size = min(96, max(12, a.original.size + d))
        settings.profile.appearance.translation.size = min(96, max(10, a.translation.size + d))
    }

    private var sessionRow: some View {
        HStack {
            Text(timeString(engine.elapsed)).monospacedDigit()
            Text(String(format: "≈ $%.2f", engine.estimatedCost)).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Text(engine.overall.label).foregroundStyle(.secondary).lineLimit(1)
            Menu {
                Picker("Profile", selection: $settings.activeID) { ForEach(settings.profiles) { Text($0.name).tag($0.id) } }
            } label: { Label(settings.profile.name, systemImage: "person.crop.rectangle") }
            .onChange(of: settings.activeID) {
                Task { await engine.setSources(settings.profile.sources); await engine.applyConfigChange() }
            }
            Menu {
                Button("Settings…", action: actions.openSettings)
                Button("Hide panel", action: actions.hidePanel)
                Divider()
                Button("Quit Subveil", action: actions.quit)
            } label: { Image(systemName: "gearshape") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
        }
    }

    private var historySection: some View {
        let q = search.lowercased()
        let items = store.segments.filter { !$0.hidden && (q.isEmpty || $0.fullOriginal.lowercased().contains(q) || $0.fullTranslation.lowercased().contains(q)) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search history", text: $search).textFieldStyle(.roundedBorder)
                Button { copy(items) } label: { Image(systemName: "doc.on.doc") }.help("Copy visible")
                Menu {
                    ForEach(ExportFormat.allCases, id: \.self) { f in Button(f.title) { actions.export(f) } }
                } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).frame(width: 30)
                Button { store.clear() } label: { Image(systemName: "trash") }.help("Clear history")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(items.suffix(200)) { s in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(s.source.label)\(s.speaker.map { " · #\($0)" } ?? "")").font(.caption2).foregroundStyle(.secondary)
                                Text(s.fullOriginal).textSelection(.enabled)
                                if !s.fullTranslation.isEmpty { Text(s.fullTranslation).foregroundStyle(.cyan).textSelection(.enabled) }
                            }.id(s.id)
                        }
                    }
                }
                .frame(height: 170)
                .onChange(of: items.last?.fullOriginal.count) { if let l = items.last { proxy.scrollTo(l.id, anchor: .bottom) } }
            }
        }
    }

    // MARK: Helpers

    private func copy(_ items: [Segment]) {
        let text = items.map { s in "\(s.source.label): \(s.fullOriginal)" + (s.fullTranslation.isEmpty ? "" : "\n→ \(s.fullTranslation)") }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    private func scheduleConfigChange() {
        configTask?.cancel()
        configTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await engine.applyConfigChange()
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            if hud.expanded || showApps {
                devices = AudioDevices.inputDevices()
                apps = AudioProcessList.apps()
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// Minimal view of overlay state needed by the HUD (keeps ControlHUD independent of Overlay).
@MainActor @Observable
public final class ControlOverlayInfo {
    public var isEditing = false
    public init() {}
}

/// One glance tells what the app is doing: ready / connecting / live + timer / paused / sleeping / error.
struct StatusBadge: View {
    let state: ConnState
    let runState: RunState
    let elapsed: TimeInterval
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            icon
            if runState != .idle {
                Text(Self.short(elapsed)).font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(runState == .paused ? .orange : .primary)
            }
        }
        .frame(minWidth: 22, alignment: .leading)
        .help(helpText)
        .onAppear { pulse = true }
    }

    @ViewBuilder private var icon: some View {
        switch (runState, state) {
        case (.idle, _):
            Image(systemName: "captions.bubble").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
        case (.paused, _):
            Image(systemName: "pause.circle.fill").font(.system(size: 13)).foregroundStyle(.orange)
        case (_, .error):
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.red)
        case (_, .autoPaused):
            Image(systemName: "moon.zzz.fill").font(.system(size: 12)).foregroundStyle(.blue)
        case (_, .connecting), (_, .reconnecting):
            dot(.yellow)
        default:
            dot(.red)
        }
    }

    private func dot(_ c: Color) -> some View {
        Circle().fill(c).frame(width: 9, height: 9)
            .shadow(color: c.opacity(0.8), radius: pulse ? 4 : 1)
            .opacity(pulse ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
    }

    private var helpText: String {
        switch (runState, state) {
        case (.idle, _): "Ready — press ▶ or ⌥⌘Space to start captions"
        case (.paused, _): "Paused — audio is not being sent"
        default: state == .live ? "Live — transcribing" : state.label
        }
    }

    static func short(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// System / Mic / Both with icons; the selected segment carries its own live level meter.
struct SourcePicker: View {
    let selection: SourceMode
    let system: Float
    let mic: Float
    let running: Bool
    let onSelect: (SourceMode) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SourceMode.allCases, id: \.self) { m in
                Button { onSelect(m) } label: { segment(m) }
                    .buttonStyle(.plain)
                    .help(help(m))
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.28)))
        .animation(.spring(duration: 0.3, bounce: 0.2), value: selection)
    }

    private func segment(_ m: SourceMode) -> some View {
        let selected = m == selection
        return VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon(m)).font(.system(size: 10, weight: .semibold))
                Text(m.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .fixedSize()
            meter(m)
                .frame(width: 34)
                .opacity(selected && running ? 1 : 0)
        }
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 9).padding(.top, 5).padding(.bottom, 3)
        .contentShape(Rectangle())
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.16))
                    .matchedGeometryEffect(id: "sel", in: ns)
            }
        }
    }

    @ViewBuilder private func meter(_ m: SourceMode) -> some View {
        switch m {
        case .system: LevelBar(level: system, height: 3)
        case .mic: LevelBar(level: mic, height: 3)
        case .both:
            HStack(spacing: 2) { LevelBar(level: system, height: 3); LevelBar(level: mic, height: 3) }
        }
    }

    private func icon(_ m: SourceMode) -> String {
        switch m { case .system: "speaker.wave.2.fill"; case .mic: "mic.fill"; case .both: "person.2.wave.2.fill" }
    }

    private func help(_ m: SourceMode) -> String {
        switch m {
        case .system: "Caption what your Mac plays (calls, videos) — “Them”"
        case .mic: "Caption your microphone — “Me”"
        case .both: "Both, as two separate streams (Them / Me)"
        }
    }
}

/// Small round, low-emphasis icon button used for chevron / close.
struct IconButton: View {
    let symbol: String
    let help: String
    var rotation: Double = 0
    /// Draws attention (e.g. "subtitles are hidden").
    var highlighted = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .rotationEffect(.degrees(rotation))
                .frame(width: 24, height: 24)
                .background(Circle().fill(highlighted ? Color.orange.opacity(hover ? 0.95 : 0.8) : .white.opacity(hover ? 0.18 : 0.08)))
                .foregroundStyle(highlighted ? .white : (hover ? .primary : .secondary))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct LevelBar: View {
    let level: Float
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: level > 0.85 ? [.orange, .red] : [.green.opacity(0.8), .green],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, g.size.width * CGFloat(min(1, level))))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }.frame(height: height)
    }
}

struct HUDButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .frame(width: 30, height: 30)
            .background(Circle().fill(tint.opacity(configuration.isPressed ? 0.6 : 0.9)))
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct HintRow: View {
    let icon: String
    let text: String
    var tint: Color = .orange
    var button: String?
    var action: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let button, let action { Button(button, action: action).controlSize(.small) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.15)))
    }
}
