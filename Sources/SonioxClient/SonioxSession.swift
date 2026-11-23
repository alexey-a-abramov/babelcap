import Foundation
import os

/// One Soniox real-time WebSocket stream with its own reconnect, keepalive and rotation logic.
///
/// Audio timeline: chunks are 100 ms each and numbered absolutely (`baseIndex + i`). The send buffer keeps the
/// last ~30 s. On reconnect a *new* server session is opened with the same config and audio is replayed from
/// the last finalized position, so nothing already finalized is repeated and nothing unfinalized is lost.
/// Token timestamps are shifted by the replay offset so they stay on one continuous timeline.
public actor SonioxSession {
    public nonisolated let events: AsyncStream<SonioxEvent>
    private let continuation: AsyncStream<SonioxEvent>.Continuation

    public static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    public static let chunkMs = 100
    /// Rotate a little before Soniox's 300-minute stream limit.
    public static let rotationInterval: TimeInterval = 290 * 60

    private let apiKey: String
    private let config: SonioxConfig
    private let endpoint: URL
    private let urlSession = URLSession(configuration: .default)
    private let maxBufferChunks: Int
    private let log = Logger(subsystem: "app.subveil", category: "SonioxSession")

    private var task: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var connected = false
    private var stopping = false
    private var flushing = false
    private var serverFinished = false

    private var buffer: [Data] = []
    private var baseIndex = 0
    private var nextIndex = 0
    private var absFinalMs = 0
    private var offsetMs = 0
    private var lastSend = Date()
    private var connectedAt = Date()
    private var rotating = false
    private var sentChunks = 0
    private var receivedMessages = 0
    private var statsAt = Date()

    public init(apiKey: String, config: SonioxConfig, endpoint: URL = SonioxSession.endpoint, maxBufferChunks: Int = 300) {
        self.apiKey = apiKey
        self.config = config
        self.endpoint = endpoint
        self.maxBufferChunks = maxBufferChunks
        var c: AsyncStream<SonioxEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    // MARK: Public API

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.runLoop() }
    }

    /// Queue a 100 ms chunk of 16 kHz mono s16le audio. Sent immediately when connected.
    public func send(_ chunk: Data) async {
        buffer.append(chunk)
        if buffer.count > maxBufferChunks {
            buffer.removeFirst()
            baseIndex += 1
            nextIndex = max(nextIndex, baseIndex)
        }
        await flush()
    }

    /// Ask the server to finalize the current draft ("pause"/source switch).
    public func finalize() async {
        await sendText(#"{"type":"finalize"}"#)
    }

    /// Graceful shutdown: flush, send the empty frame, wait (briefly) for `finished`, close.
    public func stop() async {
        guard !stopping else { return }
        stopping = true
        if connected {
            await flush()
            try? await task?.send(.string(""))
            for _ in 0..<40 where !serverFinished && connected { try? await Task.sleep(for: .milliseconds(100)) }
        }
        pingTask?.cancel()
        runTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        connected = false
        continuation.yield(.state(.closed))
        continuation.finish()
    }

    // MARK: Run loop

    private func runLoop() async {
        var attempt = 0
        while !stopping, !Task.isCancelled {
            continuation.yield(.state(attempt == 0 ? .connecting : .reconnecting))
            Trace.log("ws", "connect attempt \(attempt + 1) → \(endpoint.host ?? "?")")
            var gotData = false
            do {
                gotData = try await connectAndReceive()
            } catch let e as SonioxError {
                Trace.log("ws", "server error \(e.code) \(e.message) (\(e.action))")
                if e.isFatal {
                    continuation.yield(.error(e))
                    continuation.yield(.state(.failed))
                    continuation.finish()
                    return
                }
                continuation.yield(.error(e))
                if e.code == 429 { attempt = max(attempt, 3) }
            } catch {
                let code = task?.closeCode.rawValue ?? -1
                let reason = task?.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Trace.log("ws", "socket error: \(error.localizedDescription) closeCode=\(code) reason=\(reason)")
                log.error("socket error: \(error.localizedDescription)")
            }
            connected = false
            if stopping || Task.isCancelled { break }
            if rotating { rotating = false; attempt = 0; continue }
            attempt = gotData ? 1 : attempt + 1
            let delay = min(30.0, 0.5 * pow(2.0, Double(attempt - 1)))
            Trace.log("ws", "reconnecting in \(delay) s (attempt \(attempt), gotData=\(gotData), replay from chunk \(max(baseIndex, absFinalMs / Self.chunkMs)))")
            continuation.yield(.state(.reconnecting))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Returns true if any server message was received (used to reset backoff).
    private func connectAndReceive() async throws -> Bool {
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let ws = urlSession.webSocketTask(with: req)
        task = ws
        serverFinished = false
        ws.resume()

        // Resume position on the absolute timeline.
        let resume = max(baseIndex, absFinalMs / Self.chunkMs)
        offsetMs = resume * Self.chunkMs
        nextIndex = resume

        try await ws.send(.data(try config.jsonData()).asString)
        connected = true
        connectedAt = Date()
        Trace.log("ws", "config sent; live (resume chunk \(resume), buffered \(buffer.count))")
        continuation.yield(.state(.live))
        startPing()
        await flush()

        var gotData = false
        defer { pingTask?.cancel(); connected = false }
        while !Task.isCancelled {
            let msg = try await ws.receive()
            gotData = true
            receivedMessages += 1
            let data: Data
            switch msg {
            case let .string(s): data = Data(s.utf8)
            case let .data(d): data = d
            @unknown default: continue
            }
            guard let resp = try? SonioxResponse.decode(data) else { continue }
            if let code = resp.errorCode {
                throw SonioxError(code: code, message: resp.errorMessage ?? "")
            }
            if let f = resp.finalAudioProcMs { absFinalMs = max(absFinalMs, offsetMs + f) }
            if var toks = resp.tokens, !toks.isEmpty {
                for i in toks.indices {
                    if let s = toks[i].startMs { toks[i].startMs = s + offsetMs }
                    if let e = toks[i].endMs { toks[i].endMs = e + offsetMs }
                }
                continuation.yield(.tokens(toks))
            }
            if resp.finished == true {
                Trace.log("ws", "server finished")
                serverFinished = true
                continuation.yield(.finished)
                return gotData
            }
        }
        return gotData
    }

    // MARK: Sending

    private func flush() async {
        guard connected, !flushing, let ws = task else { return }
        flushing = true
        defer { flushing = false }
        while connected, nextIndex < baseIndex + buffer.count {
            let chunk = buffer[nextIndex - baseIndex]
            nextIndex += 1
            do {
                try await ws.send(.data(chunk))
                lastSend = Date()
                sentChunks += 1
            } catch {
                break // the receive loop notices the broken socket and reconnects
            }
        }
    }

    private func sendText(_ s: String) async {
        guard connected, let ws = task else { return }
        try? await ws.send(.string(s))
        lastSend = Date()
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.keepaliveTick()
            }
        }
    }

    private func keepaliveTick() async {
        guard connected else { return }
        if Date().timeIntervalSince(statsAt) >= 10 {
            statsAt = Date()
            Trace.log("ws", "stats: sent \(sentChunks) chunks, received \(receivedMessages) msgs, finalAudio \(absFinalMs) ms, queued \(baseIndex + buffer.count - nextIndex)")
        }
        if Date().timeIntervalSince(connectedAt) > Self.rotationInterval, !rotating {
            await rotate()
            return
        }
        if Date().timeIntervalSince(lastSend) > 4 { await sendText(#"{"type":"ping"}"#) }
    }

    /// Proactively replace the server session before the 300-minute limit.
    private func rotate() async {
        rotating = true
        await sendText(#"{"type":"finalize"}"#)
        try? await Task.sleep(for: .milliseconds(1500))
        task?.cancel(with: .goingAway, reason: nil)
    }
}

private extension URLSessionWebSocketTask.Message {
    var asString: URLSessionWebSocketTask.Message {
        if case let .data(d) = self { return .string(String(decoding: d, as: UTF8.self)) }
        return self
    }
}
