import CryptoKit
import Network
import XCTest
@testable import ModelHub
@testable import SonioxClient

final class WERTests: XCTestCase {
    func testWordErrorRate() {
        XCTAssertEqual(WER.rate(reference: "Good morning everyone", hypothesis: "good morning, everyone!"), 0)
        XCTAssertEqual(WER.rate(reference: "a b c d", hypothesis: "a x c d"), 0.25, accuracy: 1e-9)      // 1 substitution
        XCTAssertEqual(WER.rate(reference: "a b c d", hypothesis: "a b c"), 0.25, accuracy: 1e-9)        // 1 deletion
        XCTAssertEqual(WER.rate(reference: "a b", hypothesis: "a b c d"), 1.0, accuracy: 1e-9)           // 2 insertions
        XCTAssertEqual(WER.rate(reference: "шалом мир", hypothesis: ""), 1)
        XCTAssertEqual(WER.rate(reference: "בוקר טוב", hypothesis: "בוקר טוב"), 0)
    }
}

final class CatalogTests: XCTestCase {
    func testCatalogIntegrity() {
        let ids = ModelCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "ids are unique")
        XCTAssertNotNil(ModelCatalog.entry(ModelCatalog.defaultProviderID)?.engine)
        for e in ModelCatalog.all {
            if e.kind == .cloud {
                XCTAssertNotNil(e.keyURL, "\(e.id): where to get a key")
                XCTAssertNotNil(e.pricingURL, "\(e.id): where to see prices / top up")
                XCTAssertNotNil(e.priceText, "\(e.id): price per hour")
            } else {
                XCTAssertTrue(e.needsDownload || e.engine == .appleSpeech, "\(e.id): local entries say what to download")
                XCTAssertNotNil(e.priceText ?? e.license as String?)
            }
            if case .whisperKit? = e.engine {
                XCTAssertTrue(e.downloads.contains { $0.files?.contains("tokenizer.json") == true },
                              "\(e.id): tokenizer is downloaded next to the model (no hidden cache)")
            }
        }
    }

    func testBenchmarkClipsAreBundled() throws {
        let clips = BenchmarkClips.all()
        XCTAssertGreaterThanOrEqual(clips.count, 6)
        for c in clips {
            let pcm = try BenchmarkClips.pcm(c)
            XCTAssertEqual(Double(pcm.count) / 32_000, c.seconds, accuracy: 0.2, "\(c.id) length")
        }
    }

    @MainActor
    func testProblemsExplainWhatIsMissing() {
        XCTAssertNotNil(EngineFactory.problem(for: ModelCatalog.entry("soniox")!, apiKey: nil), "no key")
        XCTAssertNil(EngineFactory.problem(for: ModelCatalog.entry("soniox")!, apiKey: "k"))
        XCTAssertNotNil(EngineFactory.problem(for: ModelCatalog.entry("deepgram")!, apiKey: "k"), "planned adapter")
        XCTAssertNil(EngineFactory.problem(for: ModelCatalog.entry("azure-translate")!, apiKey: "westeurope|k"), "Azure adapter is built")
        XCTAssertNil(EngineFactory.problem(for: ModelCatalog.entry("gladia")!, apiKey: "k"), "Gladia adapter is built")
    }
}

/// A tiny HTTP server that imitates the Hugging Face API + file endpoint, sends slowly and honours Range.
final class FakeHub: @unchecked Sendable {
    let file: Data
    let fileName = "weights.bin"
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fakehub")
    private let lock = NSLock()
    private var _ranges: [String] = []
    var rangesSeen: [String] { lock.lock(); defer { lock.unlock() }; return _ranges }
    private(set) var port: UInt16 = 0

    init(size: Int) throws {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        file = Data(bytes)
        listener = try NWListener(using: .tcp, on: .any)
    }

    var sha256: String { SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined() }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] s in if case .ready = s { self?.port = self?.listener.port?.rawValue ?? 0; ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw URLError(.cannotConnectToHost) }
    }

    func stop() { listener.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, _, _ in
            let req = String(decoding: data ?? Data(), as: UTF8.self)
            let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            if path.hasPrefix("/api/models/") {
                let json = #"[{"type":"file","path":"pkg/\#(fileName)","size":\#(file.count),"lfs":{"oid":"\#(sha256)","size":\#(file.count)}}]"#
                respond(c, status: "200 OK", body: Data(json.utf8), extra: "Content-Type: application/json\r\n")
                return
            }
            var start = 0
            if let line = req.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }) {
                lock.lock(); _ranges.append(String(line)); lock.unlock()
                start = Int(line.split(separator: "=").last?.split(separator: "-").first ?? "0") ?? 0
            }
            let body = file.subdata(in: start..<file.count)
            let head = "HTTP/1.1 \(start > 0 ? "206 Partial Content" : "200 OK")\r\nContent-Length: \(body.count)\r\n"
                + (start > 0 ? "Content-Range: bytes \(start)-\(file.count - 1)/\(file.count)\r\n" : "") + "Connection: close\r\n\r\n"
            c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            sendSlowly(c, body, offset: 0)
        }
    }

    private func sendSlowly(_ c: NWConnection, _ body: Data, offset: Int) {
        guard offset < body.count else { c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() }); return }
        let end = min(body.count, offset + 32_768)
        c.send(content: body.subdata(in: offset..<end), completion: .contentProcessed { [self] err in
            guard err == nil else { return }
            queue.asyncAfter(deadline: .now() + 0.01) { self.sendSlowly(c, body, offset: end) }
        })
    }

    private func respond(_ c: NWConnection, status: String, body: Data, extra: String = "") {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}

@MainActor
final class DownloadResumeTests: XCTestCase {
    func testPauseThenResumeContinuesWithRangeAndVerifiesChecksum() async throws {
        Trace.fileEnabled = false
        let hub = try FakeHub(size: 3_000_000)
        try hub.start()
        defer { hub.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        ModelStorage.rootOverride = root
        HuggingFace.base = URL(string: "http://127.0.0.1:\(hub.port)")!
        defer {
            ModelStorage.rootOverride = nil
            HuggingFace.base = URL(string: "https://huggingface.co")!
            try? FileManager.default.removeItem(at: root)
        }

        let entry = CatalogEntry(id: "test-model", name: "Test model", vendor: "Test", kind: .local, summary: "", outputs: "",
                                 languages: "", translation: "", realtime: "", runtime: "", license: "MIT",
                                 downloads: [DownloadSpec(repo: "test/repo", path: "pkg", localDir: "model", approxBytes: 3_000_000, role: "weights")])
        let dl = ModelDownloads()
        dl.start(entry)
        // Pause somewhere in the middle.
        let midway = await waitMain(10) { dl.status(entry.id).received > 600_000 }
        XCTAssertTrue(midway)
        dl.pause(entry.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(dl.status(entry.id).phase, .paused)
        XCTAssertFalse(ModelStorage.isInstalled(entry.id))

        // Resume: must continue with a Range request, not start over.
        dl.start(entry)
        let done = await waitMain(20) { dl.status(entry.id).phase == .installed }
        XCTAssertTrue(done, "download finished: \(dl.status(entry.id).phase)")
        XCTAssertTrue(hub.rangesSeen.contains { $0.lowercased().contains("bytes=") }, "resumed with HTTP Range")
        let file = ModelStorage.folder(for: entry.id).appendingPathComponent("model/\(hub.fileName)")
        XCTAssertEqual(try Data(contentsOf: file), hub.file, "file is complete and identical")
        XCTAssertNotNil(ModelStorage.manifest(for: entry.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ModelStorage.folder(for: entry.id).appendingPathComponent("README.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelStorage.folder(for: entry.id).appendingPathComponent(".partial").path))

        try dl.delete(entry.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelStorage.folder(for: entry.id).path))
    }
}
