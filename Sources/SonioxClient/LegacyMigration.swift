import Foundation

/// One-time move of data left by the app's working title, "Subveil" (renamed to Babelcap on 25 Nov 2026).
/// Safe to call on every launch: each step runs only when the old data exists and the new location is empty.
/// Keychain items are migrated lazily by `KeychainStore` on first read.
public enum LegacyMigration {
    public static let oldName = "Subveil"
    public static let newName = "Babelcap"
    public static let oldBundleID = "app.subveil.Subveil"

    public static func run() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        moveFolder(from: support.appendingPathComponent(oldName), to: support.appendingPathComponent(newName))
        renameModelManifests(in: support.appendingPathComponent("\(newName)/Models"))
        let config = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        moveFolder(from: config.appendingPathComponent("subveil"), to: config.appendingPathComponent("babelcap"))
        if let old = UserDefaults(suiteName: oldBundleID) { copyDefaults(from: old, to: .standard) }
    }

    /// Moves `old` to `new` when only `old` exists. Returns true when something was moved.
    @discardableResult
    public static func moveFolder(from old: URL, to new: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return false }
        if fm.fileExists(atPath: new.path) {
            // Something may have created empty folders under the new name first (e.g. a model or history lookup).
            guard !containsFiles(new) else { return false }
            try? fm.removeItem(at: new)
        }
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            Trace.log("migrate", "moved \(old.lastPathComponent) → \(new.lastPathComponent)")
            return true
        } catch {
            Trace.log("migrate", "move \(old.lastPathComponent) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// True when `url` holds at least one regular file anywhere inside it.
    static func containsFiles(_ url: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let f as URL in e where (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { return true }
        return false
    }

    /// Model folders carry a manifest named after the app; rename the old one so installed models stay installed.
    public static func renameModelManifests(in models: URL) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: models, includingPropertiesForKeys: nil) else { return }
        for d in dirs {
            let old = d.appendingPathComponent("subveil-model.json"), new = d.appendingPathComponent("babelcap-model.json")
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new) }
        }
    }

    /// Copies window frames and other preferences, renaming keys that contain the old name. Existing keys win.
    public static func copyDefaults(from old: UserDefaults, to new: UserDefaults) {
        let keys = old.persistentDomain(forName: oldBundleID).map { Array($0.keys) } ?? Array(old.dictionaryRepresentation().keys)
        var copied = 0
        for k in keys where k.contains(oldName) {
            let nk = k.replacingOccurrences(of: oldName, with: newName)
            guard new.object(forKey: nk) == nil, let v = old.object(forKey: k) else { continue }
            new.set(v, forKey: nk); copied += 1
        }
        if copied > 0 { Trace.log("migrate", "copied \(copied) preferences") }
    }
}
