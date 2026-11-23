import AppKit
import AppSettings
import CaptionsCore
import Overlay
import SonioxClient
import SwiftUI
import Transcript
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    let engine: CaptionsEngine
    let store: TranscriptStore
    @State private var configTask: Task<Void, Never>?

    var body: some View {
        TabView {
            AccountTab(settings: settings).tabItem { Label("Account", systemImage: "key") }
            RecognitionTab(settings: settings).tabItem { Label("Recognition", systemImage: "waveform") }
            TranslationTab(settings: settings).tabItem { Label("Translation", systemImage: "globe") }
            AppearanceTab(settings: settings, store: store).tabItem { Label("Appearance", systemImage: "textformat") }
            LayoutTab(settings: settings).tabItem { Label("Layout", systemImage: "rectangle.on.rectangle") }
            SessionTab(settings: settings).tabItem { Label("Session", systemImage: "clock") }
            ProfilesTab(settings: settings).tabItem { Label("Profiles", systemImage: "person.2") }
            ShortcutsTab().tabItem { Label("Shortcuts", systemImage: "command") }
        }
        .frame(width: 640, height: 640)
        // Recognition / translation / context changes need a new server session → apply (debounced).
        .onChange(of: settings.profile.recognition) { scheduleApply() }
        .onChange(of: settings.profile.translationSystem) { scheduleApply() }
        .onChange(of: settings.profile.translationMic) { scheduleApply() }
        .onChange(of: settings.profile.session.dedupeEchoes) { store.dedupeEchoes = settings.profile.session.dedupeEchoes }
    }

    private func scheduleApply() {
        configTask?.cancel()
        configTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await engine.applyConfigChange()
        }
    }
}

// MARK: Account

private struct AccountTab: View {
    @Bindable var settings: SettingsStore
    @State private var key = ""
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section("Soniox") {
                SecureField("API key", text: $key, prompt: Text(settings.hasAPIKey ? "•••••••• (saved in Keychain)" : "Paste your key"))
                HStack {
                    Button("Verify & save") { verify() }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    Button("Remove key", role: .destructive) { settings.setAPIKey(""); status = "Key removed" }.disabled(!settings.hasAPIKey)
                    if busy { ProgressView().controlSize(.small) }
                    if let status { Text(status).foregroundStyle(status.hasPrefix("✓") ? .green : .secondary) }
                }
                Text("The key is stored only in the macOS Keychain. It is never written to logs or exported profiles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Advanced") {
                TextField("Model", text: $settings.modelName)
                Text("Default stt-rt-v6. Soniox rotates models every few months — change it here without a new release.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func verify() {
        busy = true; status = nil
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines), m = settings.modelName
        Task {
            let r = await SonioxKeyVerifier.verify(apiKey: k, model: m)
            busy = false
            switch r {
            case .valid: settings.setAPIKey(k); key = ""; status = "✓ Key accepted and saved"
            case let .invalid(msg): status = msg
            case let .unreachable(msg): status = "Could not reach Soniox: \(msg)"
            }
        }
    }
}

// MARK: Recognition

private struct RecognitionTab: View {
    @Bindable var settings: SettingsStore
    @State private var newSource = ""
    @State private var newTarget = ""

    var body: some View {
        Form {
            Section("Languages") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading) {
                    ForEach(Languages.all, id: \.code) { l in
                        Toggle(l.name, isOn: Binding(
                            get: { settings.profile.recognition.languageHints.contains(l.code) },
                            set: { on in
                                if on { settings.profile.recognition.languageHints.append(l.code) }
                                else { settings.profile.recognition.languageHints.removeAll { $0 == l.code } }
                            })).toggleStyle(.checkbox)
                    }
                }
                Toggle("Strict language hints", isOn: $settings.profile.recognition.strictHints)
            }
            Section("Speakers & endpointing") {
                Toggle("Speaker diarization — system audio", isOn: $settings.profile.recognition.diarizationSystem)
                Toggle("Speaker diarization — microphone (meetups)", isOn: $settings.profile.recognition.diarizationMic)
                Stepper("Endpoint delay: \(settings.profile.recognition.endpointDelayMs) ms",
                        value: $settings.profile.recognition.endpointDelayMs, in: 500...3000, step: 100)
            }
            Section("Context (biggest accuracy lever)") {
                TextField("Domain (e.g. software engineering call)", text: $settings.profile.recognition.domain)
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $settings.profile.recognition.contextText).frame(height: 60).font(.body)
                Text("Terms — one per line").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { settings.profile.recognition.terms.joined(separator: "\n") },
                                         set: { settings.profile.recognition.terms = $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    .frame(height: 70).font(.body)
                ForEach($settings.profile.recognition.glossary) { $g in
                    HStack { TextField("Source", text: $g.source); Image(systemName: "arrow.right"); TextField("Translation", text: $g.target)
                        Button { settings.profile.recognition.glossary.removeAll { $0.id == g.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Glossary: source", text: $newSource); Image(systemName: "arrow.right"); TextField("target", text: $newTarget)
                    Button("Add") {
                        guard !newSource.isEmpty, !newTarget.isEmpty else { return }
                        settings.profile.recognition.glossary.append(.init(source: newSource, target: newTarget)); newSource = ""; newTarget = ""
                    }
                }
            }
            Section("Microphone") {
                Toggle("Voice processing (echo cancellation)", isOn: $settings.profile.recognition.voiceProcessing)
                Text("Subtracts speaker output from the mic. Turn it off for a studio mic with headphones — it can quieten other audio (ducking).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

// MARK: Translation

private struct TranslationTab: View {
    @Bindable var settings: SettingsStore
    var body: some View {
        Form {
            editor("System audio (“Them”)", $settings.profile.translationSystem)
            editor("Microphone (“Me”)", $settings.profile.translationMic)
            Text("Translation runs inside the same Soniox session. Changing it opens a new session before closing the old one.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }

    private func editor(_ title: String, _ b: Binding<TranslationSettings>) -> some View {
        Section(title) {
            Picker("Mode", selection: b.kind) { ForEach(TranslationSettings.Kind.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
            if b.wrappedValue.kind == .oneWay {
                Picker("Target language", selection: b.target) { ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) } }
            }
            if b.wrappedValue.kind == .twoWay {
                Picker("Language A", selection: b.languageA) { ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) } }
                Picker("Language B", selection: b.languageB) { ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) } }
            }
        }
    }
}

// MARK: Appearance (live preview)

private struct AppearanceTab: View {
    @Bindable var settings: SettingsStore
    let store: TranscriptStore
    @State private var overlayState = OverlayState()
    private let fonts = ["System"] + NSFontManager.shared.availableFontFamilies

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [.indigo.opacity(0.7), .teal.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                CaptionView(store: store, settings: settings, state: overlayState, sample: CaptionSamples.segments)
                    .padding(16)
            }
            .frame(height: 190).clipped()
            Form {
                textSection("Original text", $settings.profile.appearance.original)
                textSection("Translation text", $settings.profile.appearance.translation)
                Section("Colors & background") {
                    color("Text", \.textColor); color("Translation", \.translationColor); color("Draft", \.draftColor)
                    color("“Them”", \.themColor); color("“Me”", \.meColor); color("Background", \.backgroundColor)
                    Toggle("Color by source", isOn: $settings.profile.appearance.speakerColors)
                    Toggle("Blur behind", isOn: $settings.profile.appearance.useBlur)
                    Toggle("Shadow", isOn: $settings.profile.appearance.shadow)
                    Toggle("Outline", isOn: $settings.profile.appearance.outline)
                    Slider(value: $settings.profile.appearance.cornerRadius, in: 0...40) { Text("Corner radius") }
                    Slider(value: $settings.profile.appearance.padding, in: 0...40) { Text("Padding") }
                }
            }.formStyle(.grouped)
        }
    }

    private func textSection(_ title: String, _ s: Binding<TextStyle>) -> some View {
        Section(title) {
            Picker("Font", selection: Binding(get: { s.wrappedValue.fontName.isEmpty ? "System" : s.wrappedValue.fontName },
                                              set: { s.wrappedValue.fontName = $0 == "System" ? "" : $0 })) {
                ForEach(fonts, id: \.self) { Text($0).tag($0) }
            }
            Slider(value: s.size, in: 12...96) { Text("Size \(Int(s.wrappedValue.size))") }
            Slider(value: s.lineSpacing, in: 0...30) { Text("Line spacing") }
            Slider(value: s.tracking, in: -2...10) { Text("Tracking") }
            Toggle("Bold", isOn: s.bold)
            Toggle("UPPERCASE", isOn: s.uppercase)
        }
    }

    private func color(_ name: String, _ kp: WritableKeyPath<AppearanceSettings, RGBA>) -> some View {
        ColorPicker(name, selection: Binding(get: { settings.profile.appearance[keyPath: kp].color },
                                             set: { settings.profile.appearance[keyPath: kp] = RGBA($0) }), supportsOpacity: true)
    }
}

// MARK: Layout & content

private struct LayoutTab: View {
    @Bindable var settings: SettingsStore
    var body: some View {
        Form {
            Section("Layout") {
                Picker("Mode", selection: $settings.profile.layout.mode) { ForEach(OverlayMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                Stepper("Lines: \(settings.profile.layout.lines)", value: $settings.profile.layout.lines, in: 1...4)
                Slider(value: $settings.profile.layout.width, in: 300...2000) { Text("Width \(Int(settings.profile.layout.width))") }
                Picker("Alignment", selection: $settings.profile.layout.alignment) {
                    ForEach(CaptionAlignment.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Window level", selection: $settings.profile.layout.level) { ForEach(WindowLevelOption.allCases, id: \.self) { Text($0.title).tag($0) } }
                Stepper(settings.profile.layout.autoHideSeconds == 0 ? "Auto-hide: never" : "Auto-hide after \(Int(settings.profile.layout.autoHideSeconds)) s of silence",
                        value: $settings.profile.layout.autoHideSeconds, in: 0...60, step: 1)
                Toggle("Hide from screen sharing", isOn: $settings.profile.layout.hideFromSharing)
                Text("Best effort only (window sharingType = none). Some capture methods still see the overlay.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Content") {
                Picker("Show", selection: $settings.profile.content.mode) { ForEach(ContentDisplay.allCases, id: \.self) { Text($0.title).tag($0) } }
                Toggle("Source label (Them / Me)", isOn: $settings.profile.content.showSourceLabel)
                Toggle("Speaker number", isOn: $settings.profile.content.showSpeaker)
                Toggle("Language", isOn: $settings.profile.content.showLanguage)
                Toggle("Timestamp", isOn: $settings.profile.content.showTimestamp)
            }
        }.formStyle(.grouped)
    }
}

// MARK: Session

private struct SessionTab: View {
    @Bindable var settings: SettingsStore
    var body: some View {
        Form {
            Section("Cost control") {
                Stepper(settings.profile.session.autoPauseMinutes == 0 ? "Auto-pause: off" : "Close session after \(settings.profile.session.autoPauseMinutes) min of silence",
                        value: $settings.profile.session.autoPauseMinutes, in: 0...60)
                Text("Soniox bills session duration. The session reopens on the first voice.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Echo") {
                Toggle("Hide mic phrases that duplicate system audio", isOn: $settings.profile.session.dedupeEchoes)
            }
            Section("History & export") {
                Toggle("Save transcript history locally", isOn: $settings.profile.session.saveHistory)
                Picker("Export format", selection: $settings.profile.session.exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                HStack {
                    Text(settings.profile.session.exportFolder ?? "Ask every time").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Choose folder…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK { settings.profile.session.exportFolder = p.url?.path }
                    }
                    if settings.profile.session.exportFolder != nil { Button("Reset") { settings.profile.session.exportFolder = nil } }
                }
                Button("Reveal history folder") { NSWorkspace.shared.open(AppPaths.historyDir) }
                Text("Audio is never written to disk. Transcripts live in ~/Library/Application Support/Subveil/.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

// MARK: Profiles

private struct ProfilesTab: View {
    @Bindable var settings: SettingsStore
    @State private var error: String?
    var body: some View {
        Form {
            Section("Active profile") {
                Picker("Profile", selection: $settings.activeID) { ForEach(settings.profiles) { Text($0.name).tag($0.id) } }
                TextField("Name", text: $settings.profile.name)
                Picker("Sources", selection: $settings.profile.sources) { ForEach(SourceMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                HStack {
                    Button("Duplicate") { settings.addProfile(named: settings.profile.name + " copy") }
                    Button("Delete", role: .destructive) { settings.deleteActiveProfile() }.disabled(settings.profiles.count < 2)
                }
            }
            Section("Import / export (JSON — never contains the API key)") {
                HStack {
                    Button("Export…") {
                        let p = NSSavePanel(); p.nameFieldStringValue = "\(settings.profile.name).subveil.json"
                        if p.runModal() == .OK, let u = p.url { do { try settings.exportActiveProfile().write(to: u) } catch { self.error = error.localizedDescription } }
                    }
                    Button("Import…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
                        if p.runModal() == .OK, let u = p.url {
                            do { try settings.importProfile(Data(contentsOf: u)) } catch { self.error = "Not a valid profile: \(error.localizedDescription)" }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
        }.formStyle(.grouped)
    }
}

private struct ShortcutsTab: View {
    var body: some View {
        Form {
            Section("Global shortcuts") {
                ForEach(HotKeys.descriptions, id: \.0) { k, d in
                    HStack { Text(d); Spacer(); Text(k).monospaced().foregroundStyle(.secondary) }
                }
            }
            Text("Registered with RegisterEventHotKey — no Accessibility permission needed.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
