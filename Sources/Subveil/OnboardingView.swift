import AppKit
import AppSettings
import CaptionsCore
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step \(step + 1) of 3").font(.caption).foregroundStyle(.secondary)
            Group {
                switch step {
                case 0: keyStep
                case 1: micStep
                default: systemStep
                }
            }
            Spacer(minLength: 0)
            Text("Recording other people's conversations may require their consent. This is a reminder, not legal advice.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                if step > 0 { Button("Back") { probe.stop(); step -= 1 } }
                Spacer()
                if step < 2 { Button("Next") { probe.stop(); step += 1 }.keyboardShortcut(.defaultAction).disabled(step == 0 && !settings.hasAPIKey) }
                else { Button("Finish") { probe.stop(); settings.onboardingDone = true; done() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(24)
        .frame(width: 480, height: 400)
        .onDisappear { probe.stop() }
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Soniox API key").font(.title2.bold())
            Text("Subveil sends audio only to Soniox, over TLS. Paste your own key — it is stored in the macOS Keychain.")
                .foregroundStyle(.secondary)
            SecureField("Soniox API key", text: $key).textFieldStyle(.roundedBorder)
            HStack {
                Button("Verify & save") { verify() }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || verifying)
                if verifying { ProgressView().controlSize(.small) }
                if let s = keyStatus { Text(s).font(.callout).foregroundStyle(s.hasPrefix("✓") ? .green : .red) }
                else if settings.hasAPIKey { Text("✓ Key already saved").foregroundStyle(.green).font(.callout) }
            }
            Link("Get a key at console.soniox.com", destination: URL(string: "https://console.soniox.com")!).font(.callout)
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
