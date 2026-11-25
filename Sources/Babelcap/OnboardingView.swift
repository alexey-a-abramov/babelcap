import AppKit
import AppSettings
import CaptionsCore
import ModelHub
import SonioxClient
import SwiftUI

struct OnboardingView: View {
    @Bindable var settings: SettingsStore
    let done: () -> Void

    @State private var step = 0
    @State private var key = ""
    @State private var keyStatus: String?
    @State private var verifying = false
    @State private var probe = LevelProbe()
    @State private var mode: Mode?
    @State private var downloads = ModelDownloads.shared

    enum Mode { case cloud, local }

    /// The offline starter kit: best local recogniser + the recommended translator.
    static let localKit = ["whisperkit-large-v3-turbo", "mlx-translategemma-4b"]

    private var kitEntries: [CatalogEntry] { Self.localKit.compactMap(ModelCatalog.entry) }
    private var kitInstalled: Bool { Self.localKit.allSatisfy { downloads.isInstalled($0) } }
    private var kitBytes: Int64 { kitEntries.reduce(0) { $0 + $1.downloadBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step \(step + 1) of 4").font(.caption).foregroundStyle(.secondary)
            Group {
                switch step {
                case 0: engineStep
                case 1: mode == .local ? AnyView(localStep) : AnyView(keyStep)
                case 2: micStep
                default: systemStep
                }
            }
            Spacer(minLength: 0)
            Text("Recording other people's conversations may require their consent. This is a reminder, not legal advice.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                if step > 0 { Button("Back") { probe.stop(); step -= 1 } }
                Spacer()
                if step < 3 { Button("Next") { probe.stop(); step += 1 }.keyboardShortcut(.defaultAction).disabled(!canContinue) }
                else { Button("Finish") { probe.stop(); settings.onboardingDone = true; done() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
        .onDisappear { probe.stop() }
    }

    private var canContinue: Bool {
        switch step {
        case 0: mode != nil
        case 1: mode == .local ? kitEntries.allSatisfy { downloads.status($0.id).phase != .notInstalled } : settings.hasAPIKey
        default: true
        }
    }

    // MARK: Engine choice

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How should Babelcap listen?").font(.title2.bold())
            choice(.cloud, icon: "cloud.fill", title: "Cloud — Soniox",
                   text: "The most accurate, words appear instantly, 60+ languages with translation. About $0.12–0.18 per hour; you need your own Soniox API key.")
            choice(.local, icon: "desktopcomputer", title: "On this Mac — free and offline",
                   text: "Nothing leaves the Mac, no key, no cost. Downloads Whisper large-v3 turbo + TranslateGemma 4B (\(kitBytes.humanBytes)). Needs Apple Silicon with 8 GB+; text appears about a second later than with Soniox.")
            Text("You can switch any time in Models & Providers, and use both.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choice(_ m: Mode, icon: String, title: String, text: String) -> some View {
        Button { mode = m } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.title2).frame(width: 30).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: mode == m ? "checkmark.circle.fill" : "circle").foregroundStyle(mode == m ? Color.accentColor : .secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(mode == m ? Color.accentColor : .secondary.opacity(0.3), lineWidth: mode == m ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Local download

    private var localStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download the offline models").font(.title2.bold())
            Text("Stored only in Babelcap's own folder. Downloads continue in the background and resume after a pause or restart — you can go on with the setup meanwhile.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(kitEntries) { e in
                let st = downloads.status(e.id)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(e.name).fontWeight(.semibold)
                        Spacer()
                        Text(st.phase == .installed ? "✓ Installed" : "\(st.received.humanBytes) / \(e.downloadBytes.humanBytes)")
                            .font(.caption).foregroundStyle(st.phase == .installed ? .green : .secondary)
                    }
                    ProgressView(value: st.phase == .installed ? 1 : st.fraction)
                    if case let .failed(msg) = st.phase { Text(msg).font(.caption).foregroundStyle(.red) }
                }
            }
            HStack {
                Button(kitInstalled ? "Installed" : "Download \(kitBytes.humanBytes)") {
                    kitEntries.forEach { downloads.start($0) }
                }
                .buttonStyle(.borderedProminent).disabled(kitInstalled)
            }
        }
        .onAppear {
            settings.providerID = Self.localKit[0]
            settings.translatorID = TranslatorChoice.auto
        }
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Soniox API key").font(.title2.bold())
            Text("Babelcap sends audio only to Soniox, over TLS. Paste your own key — it is stored in the macOS Keychain.")
                .foregroundStyle(.secondary)
            SecureField("Soniox API key", text: $key).textFieldStyle(.roundedBorder)
            HStack {
                Button("Verify & save") { verify() }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || verifying)
                if verifying { ProgressView().controlSize(.small) }
                if let s = keyStatus { Text(s).font(.callout).foregroundStyle(s.hasPrefix("✓") ? .green : .red) }
                else if settings.hasAPIKey { Text("✓ Key already saved").foregroundStyle(.green).font(.callout) }
            }
            HStack(spacing: 14) {
                Link("Get a key at console.soniox.com", destination: URL(string: "https://console.soniox.com")!)
                if let guide = ModelCatalog.entry("soniox")?.keyGuideURL { Link("Step-by-step guide ↗", destination: guide) }
            }.font(.callout)
        }
    }

    private var micStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Microphone").font(.title2.bold())
            Text("Needed for your own voice (the “Mic” stream). Skip it if you only caption system audio.").foregroundStyle(.secondary)
            Button("Allow & test microphone") { Task { await probe.start(.mic) } }
            levelRow
        }
    }

    private var systemStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System audio").font(.title2.bold())
            Text("macOS will ask for “System Audio Recording” the first time. Play something (a video, music), then check the meter moves. Silence = permission denied.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Allow & test system audio") { Task { await probe.start(.system) } }
                Button("Open Privacy & Security") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
            }
            levelRow
        }
    }

    private var levelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(probe.level)).tint(probe.gotSignal ? .green : .gray)
            if let e = probe.error { Text(e).foregroundStyle(.red).font(.callout) }
            else if probe.gotSignal { Text("✓ Signal detected").foregroundStyle(.green).font(.callout) }
        }
    }

    private func verify() {
        verifying = true; keyStatus = nil
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.modelName
        Task {
            let r = await SonioxKeyVerifier.verify(apiKey: k, model: model)
            verifying = false
            switch r {
            case .valid: settings.setAPIKey(k); key = ""; keyStatus = "✓ Key accepted and saved"
            case let .invalid(m): keyStatus = m
            case let .unreachable(m): keyStatus = "Could not reach Soniox: \(m)"
            }
        }
    }
}
