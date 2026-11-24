import CryptoKit
import Foundation
import Observation
import SonioxClient

/// Downloads catalog models into `ModelStorage`, resumable (HTTP Range) across pauses, failures and app restarts,
/// with SHA-256 verification of every LFS file.
@MainActor @Observable
public final class ModelDownloads {
    public static let shared = ModelDownloads()

    public enum Phase: Equatable, Sendable {
        case notInstalled, listing, downloading, paused, verifying, installed
        case failed(String)
    }

    public struct Status: Equatable, Sendable {
        public var phase: Phase = .notInstalled
        public var received: Int64 = 0
        public var total: Int64 = 0
        public var bytesPerSecond: Double = 0
        public var currentFile = ""
        public var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
        public var eta: TimeInterval? { bytesPerSecond > 0 && total > received ? Double(total - received) / bytesPerSecond : nil }
    }

    public private(set) var status: [String: Status] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    public init() {
        for e in ModelCatalog.all where e.needsDownload { status[e.id] = Self.statusFromDisk(e) }
    }

    public func status(_ id: String) -> Status { status[id] ?? Status() }
    public func isInstalled(_ id: String) -> Bool { status(id).phase == .installed }

    /// Start or resume.
    public func start(_ entry: CatalogEntry) {
        guard tasks[entry.id] == nil, entry.needsDownload else { return }
        var s = status(entry.id); s.phase = .listing; status[entry.id] = s
        tasks[entry.id] = Task { [weak self] in
            await self?.run(entry)
            self?.tasks[entry.id] = nil
        }
    }

    public func pause(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        var s = status(id)
        if s.phase != .installed { s.phase = .paused; s.bytesPerSecond = 0 }
        status[id] = s
    }

    public func delete(_ id: String) throws {
        pause(id)
        try ModelStorage.delete(id)
        status[id] = Status()
        Trace.log("models", "deleted \(id)")
    }

    // MARK: Worker

    private struct PlannedFile: Codable, Sendable {
        let repo: String
        let path: String        // path in the repo
        let localPath: String   // relative to the model folder
        let size: Int64
        let sha256: String?
    }

    private func run(_ entry: CatalogEntry) async {
        let id = entry.id
        let folder = ModelStorage.folder(for: id)
        let partial = folder.appendingPathComponent(".partial", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)

            // 1. Plan: list every file of every spec (sizes + checksums from the Hub).
            var plan: [PlannedFile] = []
            for spec in entry.downloads {
                var files = try await HuggingFace.listFiles(repo: spec.repo, path: spec.path)
                if let only = spec.files { files = files.filter { only.contains($0.path) } }
                let contentDir = ModelStorage.contentFolder(for: id, spec: spec).lastPathComponent
                for f in files where !f.path.hasSuffix(".gitattributes") {
                    let rel = spec.path.isEmpty ? f.path : String(f.path.dropFirst(spec.path.count).drop { $0 == "/" })
                    plan.append(PlannedFile(repo: spec.repo, path: f.path, localPath: "\(contentDir)/\(rel)", size: f.size, sha256: f.sha256))
                }
            }
            try JSONEncoder().encode(plan).write(to: partial.appendingPathComponent("plan.json"))
            let total = plan.reduce(0) { $0 + $1.size }

            // 2. Disk space for what is still missing.
            let already = plan.reduce(Int64(0)) { acc, f in acc + Self.bytesOnDisk(f, folder: folder, partial: partial) }
            let free = ModelStorage.freeDiskBytes
            if free > 0, total - already + 200_000_000 > free {
                throw DownloadError.noSpace(needed: total - already, free: free)
            }

            var s = status(id); s.total = total; s.received = already; s.phase = .downloading; status[id] = s
            Trace.log("models", "download \(id): \(plan.count) files, \(total.humanBytes), \(already.humanBytes) already here")

            // 3. Files, one after another (resumable).
            let meter = SpeedMeter()
            for f in plan {
                try Task.checkCancellation()
                let dest = folder.appendingPathComponent(f.localPath)
                if Self.isComplete(dest, size: f.size) { continue }
                let part = partial.appendingPathComponent(f.localPath.replacingOccurrences(of: "/", with: "__") + ".part")
                var st = status(id); st.currentFile = (f.path as NSString).lastPathComponent; status[id] = st

                let downloader = RangeFileDownloader(url: HuggingFace.downloadURL(repo: f.repo, path: f.path), part: part) { [weak self] n in
                    Task { @MainActor in
                        guard let self else { return }
                        var st = self.status(id)
                        st.received += n
                        st.bytesPerSecond = meter.add(n)
                        self.status[id] = st
                    }
                }
                try await downloader.run()

                // Verify, then move into place.
                var vs = status(id); vs.phase = .verifying; status[id] = vs
                let size = Int64((try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0)
                guard size == f.size else {
                    try? FileManager.default.removeItem(at: part)
                    throw DownloadError.corrupt(f.path, "size \(size) ≠ \(f.size)")
                }
                if let expected = f.sha256 {
                    let actual = try await Self.sha256(of: part)
                    guard actual == expected else {
                        try? FileManager.default.removeItem(at: part)
                        throw DownloadError.corrupt(f.path, "checksum mismatch")
                    }
                }
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: part, to: dest)
                vs = status(id); vs.phase = .downloading; status[id] = vs
            }

            // 4. Manifest + README; remove the partial folder.
            try writeManifest(entry, plan: plan)
            try? FileManager.default.removeItem(at: partial)
            var done = status(id); done.phase = .installed; done.received = total; done.bytesPerSecond = 0; done.currentFile = ""
            status[id] = done
            Trace.log("models", "installed \(id) (\(total.humanBytes))")
        } catch is CancellationError {
            var s = status(id); s.phase = .paused; s.bytesPerSecond = 0; status[id] = s
            Trace.log("models", "paused \(id)")
        } catch let e as URLError where e.code == .cancelled {
            var s = status(id); s.phase = .paused; s.bytesPerSecond = 0; status[id] = s
        } catch {
            var s = status(id); s.phase = .failed(error.localizedDescription); s.bytesPerSecond = 0; status[id] = s
            Trace.log("models", "download \(id) failed: \(error.localizedDescription)")
        }
    }

    private func writeManifest(_ entry: CatalogEntry, plan: [PlannedFile]) throws {
        let m = InstalledManifest(id: entry.id, name: entry.name, license: entry.license,
                                  files: plan.map { .init(repo: $0.repo, path: $0.path, size: $0.size, sha256: $0.sha256) },
                                  installedAt: Date(), totalBytes: plan.reduce(0) { $0 + $1.size })
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(m).write(to: ModelStorage.manifestURL(for: entry.id))
        var readme = """
        \(entry.name)
        \(String(repeating: "=", count: entry.name.count))

        \(entry.summary)

        Vendor:    \(entry.vendor)
        Licence:   \(entry.license)\(entry.licenseWarning.map { " — \($0)" } ?? "")
        Languages: \(entry.languages)
        Runtime:   \(entry.runtime)
        Installed: \(Date().formatted(date: .abbreviated, time: .shortened)) by Subveil
        Size:      \(m.totalBytes.humanBytes) in \(plan.count) files (every file checked against its SHA-256)

        Sources:

        """
        for spec in entry.downloads { readme += "  - \(spec.role): \(spec.pageURL.absoluteString)\n" }
        readme += "\nDelete this folder (or use Subveil → Models & Providers → Delete) to remove the model.\n"
        try readme.write(to: ModelStorage.folder(for: entry.id).appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    private static func isComplete(_ url: URL, size: Int64) -> Bool {
        let s = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).map(Int64.init) ?? -1
        return s == size
    }

    private static func bytesOnDisk(_ f: PlannedFile, folder: URL, partial: URL) -> Int64 {
        let dest = folder.appendingPathComponent(f.localPath)
        if isComplete(dest, size: f.size) { return f.size }
        let part = partial.appendingPathComponent(f.localPath.replacingOccurrences(of: "/", with: "__") + ".part")
        return min(f.size, Int64((try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0))
    }

    /// State after a relaunch: installed, or paused with what is already on disk.
    private static func statusFromDisk(_ e: CatalogEntry) -> Status {
        var s = Status()
        if ModelStorage.isInstalled(e.id) {
            s.phase = .installed
            s.total = ModelStorage.manifest(for: e.id)?.totalBytes ?? 0
            s.received = s.total
            return s
        }
        let folder = ModelStorage.folder(for: e.id)
        let partial = folder.appendingPathComponent(".partial")
        guard let d = try? Data(contentsOf: partial.appendingPathComponent("plan.json")),
              let plan = try? JSONDecoder().decode([PlannedFile].self, from: d) else { return s }
        s.total = plan.reduce(0) { $0 + $1.size }
        s.received = plan.reduce(0) { $0 + bytesOnDisk($1, folder: folder, partial: partial) }
        s.phase = s.received > 0 ? .paused : .notInstalled
        return s
    }

    static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            var hasher = SHA256()
            while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

public enum DownloadError: LocalizedError {
    case noSpace(needed: Int64, free: Int64)
    case corrupt(String, String)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case let .noSpace(n, f): "Not enough disk space: needs \(n.humanBytes), \(f.humanBytes) free"
        case let .corrupt(file, why): "\(file) failed verification (\(why)); it will be downloaded again"
        case let .http(code): "Server returned HTTP \(code)"
        }
    }
}

/// Bytes/second over a ~3 s sliding window.
final class SpeedMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(Date, Int64)] = []
    func add(_ n: Int64) -> Double {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        samples.append((now, n))
        samples.removeAll { now.timeIntervalSince($0.0) > 3 }
        guard let first = samples.first else { return 0 }
        let span = max(0.25, now.timeIntervalSince(first.0))
        return Double(samples.reduce(0) { $0 + $1.1 }) / span
    }
}

/// Downloads one URL into a `.part` file, continuing from its current size with an HTTP Range request.
final class RangeFileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let part: URL
    private let onBytes: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var failure: Error?
    private let lock = NSLock()

    init(url: URL, part: URL, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.url = url; self.part = part; self.onBytes = onBytes
    }

    func run() async throws {
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let existing = Int64((try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0)
        var req = URLRequest(url: url)
        req.setValue("Subveil (macOS model downloader)", forHTTPHeaderField: "User-Agent")
        if existing > 0 { req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock(); continuation = c; lock.unlock()
                let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                session = s
                let t = s.dataTask(with: req)
                task = t
                t.resume()
            }
        } onCancel: {
            self.task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            let h = try FileHandle(forWritingTo: part)
            switch code {
            case 206: try h.seekToEnd()                       // resuming
            case 200: try h.truncate(atOffset: 0)              // server ignored Range: start over
            case 416: try h.close(); completionHandler(.cancel); return   // already complete
            default: try h.close(); failure = DownloadError.http(code); completionHandler(.cancel); return
            }
            handle = h
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch { failure = error; dataTask.cancel(); return }
        onBytes(Int64(data.count))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        session.finishTasksAndInvalidate()
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        if let failure { c?.resume(throwing: failure); return }
        if let error {
            // A 416 cancel means "nothing left to fetch".
            if (error as? URLError)?.code == .cancelled, (task.response as? HTTPURLResponse)?.statusCode == 416 { c?.resume(); return }
            c?.resume(throwing: error)
            return
        }
        c?.resume()
    }
}
