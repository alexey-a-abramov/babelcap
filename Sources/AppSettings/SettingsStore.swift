import Foundation
import Observation

public enum AppPaths {
    public static var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Subveil", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    public static var historyDir: URL {
        let u = supportDir.appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

struct PersistedState: Codable {
    var profiles: [Profile]
    var activeID: UUID
    var modelName: String
    var onboardingDone: Bool
    var schemaVersion: Int?
    var showInDock: Bool?
}

@MainActor @Observable
public final class SettingsStore {
    public var profiles: [Profile] { didSet { scheduleSave() } }
    public var activeID: UUID { didSet { scheduleSave() } }
    /// Hidden parameter: Soniox model name (models rotate every few months).
    public var modelName: String { didSet { scheduleSave() } }
    public var onboardingDone: Bool { didSet { scheduleSave() } }
    /// Show a Dock icon (regular app) in addition to the menu bar item.
    public var showInDock: Bool { didSet { scheduleSave() } }
    public private(set) var hasAPIKey: Bool

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL
    public let keychain: KeychainStore

    /// `directory` / `keychain` are injectable so tests never touch the user's real settings or key.
    public init(directory: URL = AppPaths.supportDir, keychain: KeychainStore = .standard) {
        self.keychain = keychain
        let url = directory.appendingPathComponent("settings.json")
        fileURL = url

        var loaded = Profile.presets
        var active = loaded[0].id
        var model = "stt-rt-v6"
        var onboarded = false
        var dock = true
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(PersistedState.self, from: d), !s.profiles.isEmpty {
            loaded = s.profiles; active = s.activeID; model = s.modelName; onboarded = s.onboardingDone
            dock = s.showInDock ?? true
            if (s.schemaVersion ?? 1) < 4 {
                // v4: no transcript history by default.
                for i in loaded.indices { loaded[i].session.saveHistory = false }
            }
            if (s.schemaVersion ?? 1) < 3 {
                // v3: show only the target language by default.
                for i in loaded.indices where loaded[i].name.hasPrefix("Default") { loaded[i].content.mode = .translation }
            }
            if (s.schemaVersion ?? 1) < 2 {
                // v2: translate everything to English by default; "Them/Me" labels off by default.
                for i in loaded.indices where loaded[i].name == "Default" {
                    loaded[i].name = "Default (→ English)"
                    if loaded[i].translationSystem.kind == .off { loaded[i].translationSystem = .init(kind: .oneWay, target: "en") }
                    if loaded[i].translationMic.kind == .off { loaded[i].translationMic = .init(kind: .oneWay, target: "en") }
                    loaded[i].content.showSourceLabel = false
                }
            }
        }
        if !loaded.contains(where: { $0.id == active }) { active = loaded[0].id }
        profiles = loaded; activeID = active; modelName = model; onboardingDone = onboarded; showInDock = dock
        hasAPIKey = keychain.exists()
    }

    public var activeIndex: Int { profiles.firstIndex { $0.id == activeID } ?? 0 }

    /// The active profile (read/write — bind UI to `\.profile.…`).
    public var profile: Profile {
        get { profiles[activeIndex] }
        set { profiles[activeIndex] = newValue }
    }

    /// Blocking read of the secret (may show a Keychain prompt). Prefer `keychain.read()` off the main thread.
    public var apiKey: String? { keychain.load() }

    public func setAPIKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { keychain.delete() } else { keychain.save(k) }
        hasAPIKey = !k.isEmpty
    }

    // MARK: Profiles

    public func addProfile(named name: String) {
        var p = profile; p.id = UUID(); p.name = name
        profiles.append(p); activeID = p.id
    }

    public func deleteActiveProfile() {
        guard profiles.count > 1 else { return }
        profiles.remove(at: activeIndex)
        activeID = profiles[0].id
    }

    /// Profile JSON never contains the API key (it lives only in the Keychain).
    public func exportActiveProfile() throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(profile)
    }

    public func importProfile(_ data: Data) throws {
        var p = try JSONDecoder().decode(Profile.self, from: data)
        p.id = UUID()
        profiles.append(p); activeID = p.id
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let state = PersistedState(profiles: profiles, activeID: activeID, modelName: modelName, onboardingDone: onboardingDone, schemaVersion: 4, showInDock: showInDock)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(state) { try? d.write(to: fileURL, options: .atomic) }
        }
    }
}
