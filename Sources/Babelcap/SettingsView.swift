import AppKit
import AppSettings
import CaptionsCore
import CatalogUI
import ModelHub
import Overlay
import SonioxClient
import SwiftUI
import Transcript
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    let engine: CaptionsEngine
    let store: TranscriptStore

    var body: some View {
        TabView {
            AccountTab(settings: settings).tabItem { Label("Account", systemImage: "key") }
            RecognitionTab(settings: settings).tabItem { Label("Recognition", systemImage: "waveform") }
            TranslationTab(settings: settings).tabItem { Label("Translation", systemImage: "globe") }
            AppearanceTab(settings: settings, store: store).tabItem { Label("Appearance", systemImage: "textformat") }
            LayoutTab(settings: settings).tabItem { Label("Layout", systemImage: "rectangle.on.rectangle") }
            SessionTab(settings: settings).tabItem { Label("Session", systemImage: "clock") }
            ProfilesTab(settings: settings).tabItem { Label("Profiles", systemImage: "person.2") }
            ShortcutsTab(settings: settings).tabItem { Label("Shortcuts", systemImage: "command") }
        }
        .frame(width: 640, height: 640)
        // Changes reach a running session through AppContext's settings watcher.
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
                HStack(spacing: 14) {
                    if let guide = ModelCatalog.entry("soniox")?.keyGuideURL { Link("How to get a Soniox key ↗", destination: guide) }
                    Link("Guides for all providers ↗", destination: ModelCatalog.keyGuidesIndex)
                }.font(.caption)
            }
            Section("Speech engine") {
                HStack {
                    Text("In use: \(ModelCatalog.entry(settings.providerID)?.name ?? settings.providerID)")
                    Spacer()
                    Button("Models & Providers…") { AppContext.shared.openModelCatalog() }
                }
                Text("Choose Soniox or another cloud API, or a model that runs on this Mac. Each cloud provider has its own key there.")
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
                Text("Subtracts speaker output from the mic. Used only when the mic is the only source: together with system audio it conflicts with the system-audio capture, so in Both mode use headphones instead.")
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
            editor("System audio", $settings.profile.translationSystem)
            editor("Microphone", $settings.profile.translationMic)
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
                    color("System text", \.themColor); color("Mic text", \.meColor); color("Background", \.backgroundColor)
                    Picker("Colours", selection: $settings.profile.appearance.colorMode) {
                        ForEach(ColorMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if settings.profile.appearance.colorMode == .speaker {
                        HStack {
                            Text("Speakers")
                            ForEach(settings.profile.appearance.speakerPalette.indices, id: \.self) { i in
                                ColorPicker("", selection: Binding(get: { settings.profile.appearance.speakerPalette[i].color },
                                                                   set: { settings.profile.appearance.speakerPalette[i] = RGBA($0) }))
                                    .labelsHidden().help("Speaker \(i + 1)")
                            }
                        }
                        Text("Speakers are told apart by Soniox (diarization). Local engines don't separate speakers — their lines use the System / Mic colours.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
            Section("App") {
                Toggle("Show icon in the Dock", isOn: $settings.showInDock)
                Text("The menu bar icon is always there.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Layout") {
                Toggle("Click-through (mouse passes through subtitles)", isOn: $settings.profile.layout.clickThrough)
                Text("Off: drag the subtitle panel anywhere and resize it from any edge. On: clicks pass through it — hold ⌘ to move it anyway.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Mode", selection: $settings.profile.layout.mode) { ForEach(OverlayMode.selectable, id: \.self) { Text($0.title).tag($0) } }
                Toggle("Both mode: separate panels for “System” and “Mic”", isOn: $settings.profile.layout.separateSources)
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
                Toggle("Source label (System / Mic)", isOn: $settings.profile.content.showSourceLabel)
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
            Section("Spoken translation") {
                Toggle("Read translations of other people's speech aloud", isOn: $settings.profile.session.speakTranslations)
                Slider(value: $settings.profile.session.speechRate, in: 0.35...0.65) { Text("Speed") }
                Text("Uses the macOS voice of the target language. Best with headphones, so the voice is not captured again.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("Audio is never written to disk. Transcripts live in ~/Library/Application Support/Babelcap/.")
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
                        let p = NSSavePanel(); p.nameFieldStringValue = "\(settings.profile.name).babelcap.json"
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
    @Bindable var settings: SettingsStore
    @State private var recording: HotKeyAction?
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section("Global shortcuts") {
                ForEach(HotKeyAction.allCases, id: \.self) { a in
                    HStack {
                        Text(a.title)
                        Spacer()
                        if duplicates.contains(settings.binding(a)) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Used by another action")
                        }
                        Button(recording == a ? "Press keys… (Esc to cancel)" : settings.binding(a).display) {
                            recording == a ? stopRecording() : record(a)
                        }
                        .monospaced()
                        .frame(minWidth: 190)
                        if settings.hotkeys[a.rawValue] != nil {
                            Button { settings.hotkeys[a.rawValue] = nil } label: { Image(systemName: "arrow.uturn.backward") }
                                .buttonStyle(.borderless).help("Back to \(a.defaultBinding.display)")
                        }
                    }
                }
            }
            Section {
                Button("Reset all to defaults") { settings.hotkeys = [:] }
                Text("Click a shortcut and press the new combination — it needs ⌘, ⌥ or ⌃. Works everywhere, no Accessibility permission needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private var duplicates: Set<HotKeyBinding> {
        var seen = Set<HotKeyBinding>(), dup = Set<HotKeyBinding>()
        for a in HotKeyAction.allCases { let b = settings.binding(a); if !seen.insert(b).inserted { dup.insert(b) } }
        return dup
    }

    private func record(_ a: HotKeyAction) {
        stopRecording()
        recording = a
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stopRecording(); return nil }   // Esc
            var mods = 0
            if e.modifierFlags.contains(.command) { mods |= 0x100 }
            if e.modifierFlags.contains(.shift) { mods |= 0x200 }
            if e.modifierFlags.contains(.option) { mods |= 0x800 }
            if e.modifierFlags.contains(.control) { mods |= 0x1000 }
            let key = e.keyCode == 49 ? "Space" : (e.charactersIgnoringModifiers ?? "").uppercased()
            let b = HotKeyBinding(keyCode: Int(e.keyCode), modifiers: mods, key: key.isEmpty ? "#\(e.keyCode)" : key)
            guard b.isUsable else { NSSound.beep(); return nil }
            settings.hotkeys[a.rawValue] = b
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}
