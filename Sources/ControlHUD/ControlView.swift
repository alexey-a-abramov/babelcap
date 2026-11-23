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
    public init(openSettings: @escaping () -> Void, toggleEditing: @escaping () -> Void, export: @escaping (ExportFormat) -> Void) {
        self.openSettings = openSettings; self.toggleEditing = toggleEditing; self.export = export
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
            StatusDot(state: engine.overall)
            LevelBar(level: max(engine.levels[.system] ?? 0, engine.levels[.mic] ?? 0)).frame(width: 60)
            Text(timeString(engine.elapsed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
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
            StatusDot(state: engine.overall).matchedGeometryEffect(id: "dot", in: ns)
            Picker("", selection: Binding(get: { settings.profile.sources },
                                          set: { m in Task { await engine.setSources(m) } })) {
                ForEach(SourceMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)

            VStack(spacing: 4) {
                LevelBar(level: engine.levels[.system] ?? 0).opacity(settings.profile.sources == .mic ? 0.25 : 1)
                LevelBar(level: engine.levels[.mic] ?? 0).opacity(settings.profile.sources == .system ? 0.25 : 1)
            }.frame(width: 38)

            Spacer(minLength: 0)
            controls
            Button { hud.expanded.toggle(); hud.touch() } label: {
                Image(systemName: "chevron.down").rotationEffect(.degrees(hud.expanded ? 180 : 0))
            }.buttonStyle(.plain).help("History and options")
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder private var controls: some View {
        switch engine.runState {
        case .idle:
            Button { Task { await engine.start() } } label: { Label("Start", systemImage: "play.fill").labelStyle(.iconOnly) }
                .buttonStyle(HUDButtonStyle(tint: .green)).help("Start (⌥⌘Space)")
        case .running, .paused:
            Button { Task { await engine.togglePause() } } label: {
                Image(systemName: engine.runState == .paused ? "play.fill" : "pause.fill")
            }.buttonStyle(HUDButtonStyle(tint: .orange)).help("Pause / resume")
            Button { Task { await engine.stop() } } label: { Image(systemName: "stop.fill") }
                .buttonStyle(HUDButtonStyle(tint: .red)).help("Stop")
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
            Button { actions.toggleEditing(); hud.touch() } label: {
                Image(systemName: overlay.isEditing ? "lock.open.fill" : "lock.fill")
            }.help(overlay.isEditing ? "Editing: drag / resize subtitles. Click to lock (click-through)" : "Click-through. Click to move / resize subtitles")
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
            Button(action: actions.openSettings) { Image(systemName: "gearshape") }.buttonStyle(.plain)
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

struct StatusDot: View {
    let state: ConnState
    @State private var pulse = false
    var color: Color {
        switch state {
        case .idle: .gray
        case .connecting, .reconnecting: .yellow
        case .live: .green
        case .autoPaused: .blue
        case .error: .red
        }
    }
    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
            .opacity(pulse && (state == .connecting || state == .reconnecting) ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .help(state.label)
    }
}

struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.25))
                Capsule().fill(level > 0.85 ? Color.red : Color.green).frame(width: g.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }.frame(height: 5)
    }
}

struct HUDButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 30, height: 30)
            .background(Circle().fill(tint.opacity(configuration.isPressed ? 0.55 : 0.85)))
            .foregroundStyle(.white)
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
