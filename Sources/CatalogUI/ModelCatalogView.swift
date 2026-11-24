import AppKit
import AppSettings
import CaptionsCore
import LocalEngines
import ModelHub
import SonioxClient
import SwiftUI

/// "Models & Providers": choose the speech engine, add API keys, download open models, and test them.
public struct ModelCatalogView: View {
    @Bindable var settings: SettingsStore
    let engine: CaptionsEngine

    public init(settings: SettingsStore, engine: CaptionsEngine, initialTab: Tab = .browse, initialSelection: String? = nil) {
        self.settings = settings; self.engine = engine
        _tab = State(initialValue: initialTab)
        _selection = State(initialValue: initialSelection)
    }

    public enum Tab: String, CaseIterable, Sendable { case browse = "Browse", compare = "Compare", benchmark = "Benchmark" }
    enum Filter: String, CaseIterable { case all = "All", cloud = "Cloud", local = "On this Mac", ready = "Ready to use" }

    @State private var tab: Tab = .browse
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var selection: String?

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                Spacer()
                Label("In use: \(engine.provider.name)", systemImage: "waveform.badge.mic").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            switch tab {
            case .browse: browse
            case .compare: CompareTable(settings: settings, engine: engine) { id in selection = id; tab = .browse }
            case .benchmark: BenchmarkPanel(settings: settings)
            }
        }
        .frame(minWidth: 980, minHeight: 660)
        .onAppear { if selection == nil { selection = settings.providerID } }
    }

    // MARK: Browse

    private var entries: [CatalogEntry] {
        ModelCatalog.all.filter { e in
            switch filter {
            case .all: true
            case .cloud: e.kind == .cloud
            case .local: e.kind == .local
            case .ready: e.isReady
            }
        }.filter { search.isEmpty || "\($0.name) \($0.vendor) \($0.summary)".localizedCaseInsensitiveContains(search) }
    }

    private var browse: some View {
        HSplitView {
            VStack(spacing: 8) {
                TextField("Search engines", text: $search).textFieldStyle(.roundedBorder)
                Picker("", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                List(selection: $selection) {
                    ForEach(EngineKind.allCases, id: \.self) { kind in
                        let items = entries.filter { $0.kind == kind }
                        if !items.isEmpty {
                            Section(kind.title) {
                                ForEach(items) { e in EntryRow(entry: e, inUse: e.id == settings.providerID).tag(e.id) }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .padding(10)
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)

            Group {
                if let id = selection, let e = ModelCatalog.entry(id) {
                    EntryDetail(entry: e, settings: settings, engine: engine).id(e.id)
                } else {
                    ContentUnavailableView("Choose an engine", systemImage: "waveform", description: Text("Cloud APIs on top, models that run on this Mac below."))
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Row

private struct EntryRow: View {
    let entry: CatalogEntry
    let inUse: Bool
    @State private var downloads = ModelDownloads.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind == .cloud ? "cloud" : "desktopcomputer")
                .frame(width: 22).foregroundStyle(entry.isReady ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).fontWeight(inUse ? .semibold : .regular).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            badge
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        if entry.kind == .cloud { return entry.priceText ?? entry.vendor }
        if entry.needsDownload { return "\(entry.downloadBytes.humanBytes) · \(entry.minRAMGB.map { "\($0)+ GB RAM" } ?? "")" }
        return entry.priceText ?? entry.vendor
    }

    @ViewBuilder private var badge: some View {
        let st = downloads.status(entry.id)
        if inUse {
            Tag(text: "In use", color: .blue)
        } else if st.phase == .downloading || st.phase == .listing || st.phase == .verifying {
            ProgressView(value: st.fraction).progressViewStyle(.circular).controlSize(.small)
        } else if entry.needsDownload && st.phase == .installed {
            Tag(text: "Installed", color: .green)
        } else if st.phase == .paused {
            Tag(text: "Paused", color: .orange)
        } else if !entry.isReady {
            Tag(text: "Planned", color: .gray)
        }
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
    }
}

// MARK: - Detail

private struct EntryDetail: View {
    let entry: CatalogEntry
    @Bindable var settings: SettingsStore
    let engine: CaptionsEngine
    @State private var downloads = ModelDownloads.shared
    @State private var key = ""
    @State private var keyStatus: String?
    @State private var hasKey = false
    @State private var verifying = false
    @State private var confirmLicence = false
    @State private var translationPack: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Text(entry.summary).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                facts
                macCheck
                if entry.kind == .cloud { keySection }
                if entry.needsDownload { downloadSection }
                if entry.engine == .appleSpeech { appleSection }
                if entry.isReady { TestCard(entry: entry, settings: settings) }
                if !entry.notes.isEmpty {
                    Block(title: "Notes") {
                        ForEach(entry.notes, id: \.self) { Label($0, systemImage: "info.circle").fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            .padding(22)
        }
        .task { await refreshKey() }
        .task { await checkTranslationPack() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: entry.kind == .cloud ? "cloud.fill" : "desktopcomputer")
                .font(.system(size: 34)).foregroundStyle(Color.accentColor).frame(width: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.name).font(.largeTitle.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(entry.vendor).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Tag(text: entry.kind == .cloud ? "Cloud" : "Offline", color: entry.kind == .cloud ? .blue : .green)
                    if entry.realtime.hasPrefix("Yes") || entry.realtime.hasPrefix("Near") { Tag(text: "Real time", color: .purple) }
                    if !entry.translation.hasPrefix("No") && entry.translation != "None" { Tag(text: "Translation", color: .teal) }
                    Tag(text: entry.license, color: entry.licenseWarning == nil ? .gray : .red)
                    if !entry.isReady { Tag(text: "Adapter planned", color: .orange) }
                }
            }
            Spacer()
            useButton
        }
    }

    private var problem: String? { EngineFactory.problem(for: entry, apiKey: entry.needsAPIKey ? (hasKey ? "x" : nil) : nil) }

    @ViewBuilder private var useButton: some View {
        let inUse = settings.providerID == entry.id
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                settings.providerID = entry.id
            } label: {
                Label(inUse ? "In use" : "Use this engine", systemImage: inUse ? "checkmark.circle.fill" : "arrow.right.circle")
                    .frame(minWidth: 150)
            }
            .controlSize(.large).buttonStyle(.borderedProminent)
            .disabled(inUse || problem != nil)
            if let p = problem, !inUse { Text(p).font(.caption).foregroundStyle(.secondary).frame(maxWidth: 220, alignment: .trailing).multilineTextAlignment(.trailing) }
            if inUse && engine.isRunning { Text("Switching takes effect immediately").font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Facts

    private var facts: some View {
        Block(title: "At a glance") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                fact("Output", entry.outputs)
                fact("Languages", entry.languages)
                fact("Translation", entry.translation)
                fact("Real time", entry.realtime)
                fact("Runs on", entry.runtime)
                if let p = entry.priceText { fact(entry.kind == .cloud ? "Price" : "Cost", p) }
                if entry.needsDownload { fact("Download", entry.downloadBytes.humanBytes + " · stored in Subveil's own folder") }
                if let r = entry.minRAMGB { fact("Memory", "\(r) GB minimum" + (entry.recommendedRAMGB.map { " · \($0) GB recommended" } ?? "")) }
                fact("Licence", entry.license + (entry.licenseWarning.map { " — \($0)" } ?? ""))
            }
            HStack(spacing: 14) {
                if let u = entry.docsURL { Link("Documentation ↗", destination: u) }
                ForEach(entry.downloads, id: \.self) { d in Link("\(d.role) on Hugging Face ↗", destination: d.pageURL) }
            }.font(.callout)
        }
    }

    private func fact(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Your Mac

    private var macCheck: some View {
        Block(title: "This Mac — \(MachineInfo.chip)") {
            VStack(alignment: .leading, spacing: 6) {
                if let r = entry.minRAMGB {
                    check(MachineInfo.ramGB >= r, "Memory: \(MachineInfo.ramGB) GB (needs \(r) GB" + (entry.recommendedRAMGB.map { ", \($0) GB recommended" } ?? "") + ")",
                          warn: entry.recommendedRAMGB.map { MachineInfo.ramGB < $0 } ?? false)
                }
                if entry.needsDownload {
                    let free = ModelStorage.freeDiskBytes
                    check(free > entry.downloadBytes + 500_000_000, "Disk: \(free.humanBytes) free (needs \(entry.downloadBytes.humanBytes))")
                }
                if let v = entry.minMacOS { check(MachineInfo.macOSMajor >= v, "macOS \(MachineInfo.macOSMajor) (needs \(v)+)") }
                if entry.kind == .cloud { check(true, "Needs an internet connection; audio is sent to \(entry.vendor)") }
                if entry.minRAMGB == nil && entry.minMacOS == nil && entry.kind == .local { check(true, "No special requirements") }
            }
        }
    }

    private func check(_ ok: Bool, _ text: String, warn: Bool = false) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: ok ? (warn ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") : "xmark.circle.fill")
                .foregroundStyle(ok ? (warn ? .orange : .green) : .red)
        }
    }

    // MARK: API key

    private var keySection: some View {
        Block(title: "API key") {
            VStack(alignment: .leading, spacing: 10) {
                Text("How to get one: 1) create an account, 2) create an API key in the console, 3) paste it here. You pay \(entry.vendor) directly for what you use; top up or set a budget on their billing page.")
                    .fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
                HStack {
                    SecureField(hasKey ? "•••••••• saved in the Keychain" : "Paste the \(entry.vendor) API key", text: $key)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                    Button(entry.engine == .soniox ? "Verify & save" : "Save") { saveKey() }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || verifying)
                    if hasKey { Button("Remove", role: .destructive) { removeKey() } }
                    if verifying { ProgressView().controlSize(.small) }
                }
                if let keyStatus { Text(keyStatus).foregroundStyle(keyStatus.hasPrefix("✓") ? .green : .red) }
                HStack(spacing: 14) {
                    if let u = entry.keyURL { Link("Get an API key ↗", destination: u) }
                    if let u = entry.pricingURL { Link("Pricing / top up balance ↗", destination: u) }
                }
                if !entry.isReady {
                    Text("You can save a key now; this provider will work once its adapter ships.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var keychain: KeychainStore { entry.id == "soniox" ? settings.keychain : .forProvider(entry.id) }

    private func refreshKey() async {
        let kc = keychain
        hasKey = await Task.detached { kc.exists() }.value
    }

    private func saveKey() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        if entry.engine == .soniox {
            verifying = true
            let model = settings.modelName
            Task {
                let r = await SonioxKeyVerifier.verify(apiKey: k, model: model)
                verifying = false
                switch r {
                case .valid: settings.setAPIKey(k); key = ""; hasKey = true; keyStatus = "✓ Key accepted by Soniox and saved"
                case let .invalid(m): keyStatus = m
                case let .unreachable(m): keyStatus = "Could not reach Soniox: \(m)"
                }
            }
        } else {
            keychain.save(k); key = ""; hasKey = true; keyStatus = "✓ Saved in the Keychain"
        }
    }

    private func removeKey() {
        if entry.id == "soniox" { settings.setAPIKey("") } else { keychain.delete() }
        hasKey = false; keyStatus = "Key removed"
    }

    // MARK: Download

    private var downloadSection: some View {
        let st = downloads.status(entry.id)
        return Block(title: "Download") {
            VStack(alignment: .leading, spacing: 10) {
                switch st.phase {
                case .installed:
                    Label("Installed · \(ModelStorage.sizeOnDisk(entry.id).humanBytes) on disk, every file verified (SHA-256)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                case .downloading, .listing, .verifying:
                    ProgressView(value: st.fraction) {
                        Text(st.phase == .listing ? "Preparing…" : st.phase == .verifying ? "Verifying \(st.currentFile)…" : "Downloading \(st.currentFile)")
                    } currentValueLabel: {
                        Text(progressText(st))
                    }
                case .paused:
                    ProgressView(value: st.fraction) { Text("Paused — continues where it stopped") } currentValueLabel: { Text(progressText(st)) }
                case let .failed(msg):
                    Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                case .notInstalled:
                    Text("\(entry.downloadBytes.humanBytes) from Hugging Face. Downloads resume after a pause, a lost connection or a restart.")
                        .foregroundStyle(.secondary)
                }
                if !entry.isReady, st.phase != .installed {
                    Text("Subveil cannot run this model yet (its adapter is planned). Downloading now only saves the weights for later.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    switch st.phase {
                    case .downloading, .listing, .verifying:
                        Button("Pause") { downloads.pause(entry.id) }
                    case .installed:
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ModelStorage.folder(for: entry.id)]) }
                        Button("Delete", role: .destructive) { try? downloads.delete(entry.id) }
                    default:
                        Button(st.phase == .paused ? "Resume" : "Download \(entry.downloadBytes.humanBytes)") {
                            if entry.licenseWarning != nil { confirmLicence = true } else { downloads.start(entry) }
                        }
                        .buttonStyle(.borderedProminent)
                        if st.received > 0 { Button("Discard partial download", role: .destructive) { try? downloads.delete(entry.id) } }
                    }
                }
                Text("Folder: \(ModelStorage.folder(for: entry.id).path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .alert("Licence: \(entry.license)", isPresented: $confirmLicence) {
            Button("Download anyway") { downloads.start(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { Text(entry.licenseWarning ?? "") }
    }

    private func progressText(_ s: ModelDownloads.Status) -> String {
        var t = "\(s.received.humanBytes) of \(s.total.humanBytes)"
        if s.bytesPerSecond > 0 { t += " · \(Int64(s.bytesPerSecond).humanBytes)/s" }
        if let eta = s.eta { t += " · \(Duration.seconds(eta).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left" }
        return t
    }

    // MARK: Apple

    private func checkTranslationPack() async {
        guard entry.engine == .appleSpeech, #available(macOS 26.0, *) else { return }
        let src = settings.profile.recognition.languageHints.first ?? "en"
        let tr = settings.profile.translationSystem
        guard tr.kind == .oneWay, tr.target.prefix(2) != src.prefix(2) else { translationPack = nil; return }
        let names = "\(Languages.name(src)) → \(Languages.name(tr.target))"
        switch await AppleTranslator.readiness(from: src, to: tr.target) {
        case .installed: translationPack = "✓ Apple Translation \(names) is installed"
        case .needsDownload: translationPack = "Apple Translation \(names) is not installed yet — add it in Translation Languages"
        case .unsupported: translationPack = "Apple Translation does not support \(names)"
        }
    }

    private var appleSection: some View {
        Block(title: "Languages") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Spoken language: \(Languages.name(settings.profile.recognition.languageHints.first ?? "en")) (the first language in Settings → Recognition). macOS downloads the speech model for it on first use.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Translation uses Apple Translation. Install the languages you need once in System Settings → General → Language & Region → Translation Languages.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let translationPack { Label(translationPack, systemImage: translationPack.hasPrefix("✓") ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(translationPack.hasPrefix("✓") ? .green : .orange) }
                Button("Open Language & Region settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                }
            }
        }
    }
}

// MARK: - Test card

private struct TestCard: View {
    let entry: CatalogEntry
    @Bindable var settings: SettingsStore
    @State private var clipID = "en"
    @State private var target = "en"
    @State private var running = false
    @State private var status = ""
    @State private var result: BenchmarkResult?
    private let clips = BenchmarkClips.all()

    var body: some View {
        Block(title: "Test on a sample") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Runs a short recorded clip through this engine and reports accuracy (word error rate against the script), speed and whether it keeps up with live speech.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker("Clip", selection: $clipID) { ForEach(clips) { Text($0.title).tag($0.id) } }.frame(maxWidth: 380)
                    Picker("Translate into", selection: $target) {
                        Text("No translation").tag("none")
                        ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                    }.frame(maxWidth: 240)
                    Button(running ? "Testing…" : "Run test") { run() }.disabled(running || clips.isEmpty).buttonStyle(.borderedProminent)
                    if running { ProgressView().controlSize(.small) }
                }
                if running { Text(status).font(.caption).foregroundStyle(.secondary) }
                if let r = result, let clip = clips.first(where: { $0.id == r.clipID }) { ResultView(result: r, clip: clip) }
            }
        }
    }

    private func run() {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return }
        running = true; result = nil
        let entry = entry, tgt = target == "none" ? nil : target
        let kc = entry.id == "soniox" ? settings.keychain : KeychainStore.forProvider(entry.id)
        Task {
            let key = entry.needsAPIKey ? await Task.detached { kc.load() }.value : nil
            let r = await BenchmarkRunner.run(entry: entry, clip: clip, target: tgt, apiKey: key) { msg in
                Task { @MainActor in status = msg }
            }
            result = r
            running = false
        }
    }
}

struct ResultView: View {
    let result: BenchmarkResult
    let clip: BenchmarkClip

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(result.verdict.title, systemImage: result.verdict.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(result.verdict == .excellent || result.verdict == .good ? .green : result.verdict == .borderline ? .orange : .red)
            if let e = result.error { Text(e).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let w = result.warning { Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Accuracy").foregroundStyle(.secondary); Text(result.wer.map { String(format: "%.0f%% word error rate (%.0f%% correct)", $0 * 100, max(0, 100 - $0 * 100)) } ?? "—") }
                GridRow { Text("Speed").foregroundStyle(.secondary); Text(result.speedText) }
                if let f = result.firstTextAfter { GridRow { Text("First words").foregroundStyle(.secondary); Text(String(format: "%.1f s after the audio started", f)) } }
                GridRow { Text("Start-up").foregroundStyle(.secondary); Text(String(format: "%.1f s (connect / load the model)", result.setupSeconds)) }
            }
            if let rtf = result.rtf, result.error == nil, case .whisperKit? = ModelCatalog.entry(result.entryID)?.engine {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Expected on other Macs — rough estimate from GPU size and chip generation").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                        ForEach(DeviceEstimate.laptops) { m in
                            if let e = DeviceEstimate.rtf(rtf, on: m) {
                                GridRow {
                                    Text(m.name)
                                    Text(DeviceEstimate.speedText(e) + " real time").monospacedDigit()
                                    Text(DeviceEstimate.verdict(e)).foregroundStyle(e < 0.8 ? .green : e < 1 ? .orange : .red)
                                }
                            }
                        }
                    }.font(.caption)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                textBox("Script", clip.text)
                textBox("Heard", result.transcript.isEmpty ? "—" : result.transcript)
            }
            if let t = result.targetLanguage {
                HStack(alignment: .top, spacing: 12) {
                    textBox("Reference (English)", clip.english)
                    textBox("Translation → \(Languages.name(t))", result.translation.isEmpty ? "— (no translation produced)" : result.translation)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private func textBox(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Titled group used throughout the catalog.
private struct Block<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Compare

private struct CompareTable: View {
    @Bindable var settings: SettingsStore
    let engine: CaptionsEngine
    let open: (String) -> Void
    @State private var downloads = ModelDownloads.shared
    @State private var order = [KeyPathComparator(\Row.sortPrice)]

    struct Row: Identifiable {
        let e: CatalogEntry
        var id: String { e.id }
        var name: String { e.name }
        var type: String { e.kind == .cloud ? "Cloud" : "Local" }
        var sortPrice: Double { e.pricePerHour ?? 0 }
        var sortSize: Int64 { e.downloadBytes }
    }

    var body: some View {
        let rows = ModelCatalog.all.map(Row.init).sorted(using: order)
        Table(rows, sortOrder: $order) {
            TableColumn("Engine", value: \.name) { r in
                Button(r.e.name) { open(r.id) }.buttonStyle(.link)
            }.width(min: 200, ideal: 260)
            TableColumn("Type", value: \.type).width(70)
            TableColumn("Status") { r in
                if r.id == settings.providerID { Tag(text: "In use", color: .blue) }
                else if !r.e.isReady { Tag(text: "Planned", color: .gray) }
                else if r.e.needsDownload { Tag(text: downloads.isInstalled(r.id) ? "Installed" : "Download", color: downloads.isInstalled(r.id) ? .green : .orange) }
                else { Tag(text: "Ready", color: .green) }
            }.width(90)
            TableColumn("Real time") { r in Text(r.e.realtime).lineLimit(2) }.width(min: 120, ideal: 170)
            TableColumn("Translation") { r in Text(r.e.translation).lineLimit(2) }.width(min: 140, ideal: 220)
            TableColumn("Languages") { r in Text(r.e.languages).lineLimit(2) }.width(min: 110, ideal: 160)
            TableColumn("Price / hour", value: \.sortPrice) { r in Text(r.e.kind == .cloud ? (r.e.priceText ?? "—") : "Free") .lineLimit(2) }
                .width(min: 120, ideal: 200)
            TableColumn("Download", value: \.sortSize) { r in Text(r.e.needsDownload ? r.e.downloadBytes.humanBytes : "—") }.width(80)
            TableColumn("RAM") { r in Text(r.e.minRAMGB.map { "\($0)+ GB" } ?? "—") }.width(60)
            TableColumn("Licence") { r in Text(r.e.license).lineLimit(1) }.width(min: 90, ideal: 130)
        }
    }
}

// MARK: - Benchmark

private struct BenchmarkPanel: View {
    @Bindable var settings: SettingsStore
    @State private var clipID = "en"
    @State private var target = "en"
    @State private var running = false
    @State private var current = ""
    @State private var results: [BenchmarkResult] = []
    private let clips = BenchmarkClips.all()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Runs the same clip through every engine that is ready on this Mac (installed models, cloud providers with a key) and compares accuracy and speed.")
                .foregroundStyle(.secondary)
            Text("Speed for local models: how many times faster than real time they process audio — live captions need comfortably more than 1×, ideally 2× or more. For cloud engines: how long after the speaker stops the final text arrives.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("Clip", selection: $clipID) { ForEach(clips) { Text($0.title).tag($0.id) } }.frame(maxWidth: 380)
                Picker("Translate into", selection: $target) {
                    Text("No translation").tag("none")
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }.frame(maxWidth: 240)
                Button(running ? "Running…" : "Run all ready engines") { runAll() }.buttonStyle(.borderedProminent).disabled(running)
                if running { ProgressView().controlSize(.small); Text(current).foregroundStyle(.secondary) }
            }
            Table(results) {
                TableColumn("Engine") { r in Text(ModelCatalog.entry(r.entryID)?.name ?? r.entryID) }.width(min: 200, ideal: 260)
                TableColumn("Verdict") { r in Label(r.verdict.title, systemImage: r.verdict.symbol) }.width(min: 180, ideal: 220)
                TableColumn("Accuracy") { r in Text(r.wer.map { String(format: "%.0f%% WER", $0 * 100) } ?? "—") }.width(80)
                TableColumn("Speed") { r in Text(r.speedText) }.width(min: 170, ideal: 240)
                TableColumn("Start-up") { r in Text(String(format: "%.1f s", r.setupSeconds)) }.width(70)
                TableColumn("Heard") { r in Text(r.error ?? r.transcript).lineLimit(2) }.width(min: 200, ideal: 320)
                TableColumn("Translation") { r in Text(r.translation).lineLimit(2) }.width(min: 160, ideal: 260)
            }
        }
        .padding(16)
    }

    private func runAll() {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return }
        running = true; results = []
        let tgt = target == "none" ? nil : target
        let keychain = settings.keychain
        Task {
            for entry in ModelCatalog.all where entry.isReady {
                let kc = entry.id == "soniox" ? keychain : KeychainStore.forProvider(entry.id)
                let key = entry.needsAPIKey ? await Task.detached { kc.load() }.value : nil
                guard EngineFactory.problem(for: entry, apiKey: key) == nil else { continue }
                current = entry.name
                results.append(await BenchmarkRunner.run(entry: entry, clip: clip, target: tgt, apiKey: key))
            }
            running = false; current = ""
        }
    }
}
