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
}

@MainActor @Observable
public final class SettingsStore {
    public var profiles: [Profile] { didSet { scheduleSave() } }
    public var activeID: UUID { didSet { scheduleSave() } }
    /// Hidden parameter: Soniox model name (models rotate every few months).
    public var modelName: String { didSet { scheduleSave() } }
    public var onboardingDone: Bool { didSet { scheduleSave() } }
    public private(set) var hasAPIKey: Bool

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let fileURL = AppPaths.supportDir.appendingPathComponent("settings.json")

    public init() {
        if let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(PersistedState.self, from: d), !s.profiles.isEmpty {
            profiles = s.profiles; activeID = s.activeID; modelName = s.modelName; onboardingDone = s.onboardingDone
        } else {
            let p = Profile.presets
            profiles = p; activeID = p[0].id; modelName = "stt-rt-v6"; onboardingDone = false
        }
        hasAPIKey = KeychainStore.load() != nil
        if !profiles.contains(where: { $0.id == activeID }) { activeID = profiles[0].id }
    }

    public var activeIndex: Int { profiles.firstIndex { $0.id == activeID } ?? 0 }

    /// The active profile (read/write — bind UI to `\.profile.…`).
    public var profile: Profile {
        get { profiles[activeIndex] }
        set { profiles[activeIndex] = newValue }
    }

    public var apiKey: String? { KeychainStore.load() }

    public func setAPIKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { KeychainStore.delete() } else { KeychainStore.save(k) }
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
            let state = PersistedState(profiles: profiles, activeID: activeID, modelName: modelName, onboardingDone: onboardingDone)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(state) { try? d.write(to: fileURL, options: .atomic) }
        }
    }
}
