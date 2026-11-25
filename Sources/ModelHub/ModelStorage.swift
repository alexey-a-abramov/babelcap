import Foundation

/// Where models live: one folder per catalog entry under Application Support — never anywhere else on the system.
///
///     ~/Library/Application Support/Babelcap/Models/<entry-id>/
///         README.txt               human-readable: what this model is, where it came from, licence
///         babelcap-model.json       machine-readable manifest (files, sizes, sha256, install date)
///         <repo files …>
///         .partial/                in-progress downloads (resumable)
public enum ModelStorage {
    public static var root: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Babelcap/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Overridable in tests.
    nonisolated(unsafe) public static var rootOverride: URL?

    public static func folder(for id: String) -> URL {
        (rootOverride ?? root).appendingPathComponent(id, isDirectory: true)
    }

    public static func manifestURL(for id: String) -> URL { folder(for: id).appendingPathComponent("babelcap-model.json") }

    public static func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(for: id).path)
    }

    public static func manifest(for id: String) -> InstalledManifest? {
        guard let d = try? Data(contentsOf: manifestURL(for: id)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(InstalledManifest.self, from: d)
    }

    /// Local folder of one download (repo files keep their paths relative to the spec's `path`).
    public static func contentFolder(for id: String, spec: DownloadSpec) -> URL {
        let base = folder(for: id)
        return base.appendingPathComponent(spec.localDir ?? spec.repo.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
    }

    public static func sizeOnDisk(_ id: String) -> Int64 {
        let url = folder(for: id)
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    public static func delete(_ id: String) throws {
        let url = folder(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public static var freeDiskBytes: Int64 {
        let v = try? (rootOverride ?? root).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

public struct InstalledManifest: Codable, Sendable {
    public struct File: Codable, Sendable {
        public var repo: String
        public var path: String
        public var size: Int64
        public var sha256: String?
    }
    public var id: String
    public var name: String
    public var license: String
    public var files: [File]
    public var installedAt: Date
    public var totalBytes: Int64
}

public enum MachineInfo {
    public static var ramGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }
    public static var macOSMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
    public static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

public extension Int64 {
    var humanBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
