import Foundation
import Network

/// Local WebSocket server that behaves like Soniox just enough for session tests.
final class MockSonioxServer: @unchecked Sendable {
    final class Conn: @unchecked Sendable {
        let connection: NWConnection
        let index: Int
        private let lock = NSLock()
        private var _texts: [String] = []
        private var _binary = 0
        var texts: [String] { lock.lock(); defer { lock.unlock() }; return _texts }
        var binaryCount: Int { lock.lock(); defer { lock.unlock() }; return _binary }
        var onText: (@Sendable (Conn, String) -> Void)?
        var onBinary: (@Sendable (Conn, Int) -> Void)?

        init(_ c: NWConnection, index: Int) { connection = c; self.index = index }

        func start(queue: DispatchQueue) {
            connection.start(queue: queue)
            receive()
        }

        private func receive() {
            connection.receiveMessage { [self] data, context, _, error in
                if error != nil { return }
                let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if let data, let meta {
                    switch meta.opcode {
                    case .text:
                        let s = String(decoding: data, as: UTF8.self)
                        lock.lock(); _texts.append(s); lock.unlock()
                        onText?(self, s)
                    case .binary:
                        lock.lock(); _binary += 1; let n = _binary; lock.unlock()
                        onBinary?(self, n)
                    default: break
                    }
                }
                receive()
            }
        }

        func sendText(_ s: String) {
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
            connection.send(content: Data(s.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
        }

        func close() { connection.cancel() }
    }

    private let queue = DispatchQueue(label: "mock.soniox")
    private var listener: NWListener!
    private let lock = NSLock()
    private var _conns: [Conn] = []
    private var _auth: [String] = []

    /// Called for every accepted connection before it starts receiving.
    var onConnection: (@Sendable (Conn) -> Void)?

    var connections: [Conn] { lock.lock(); defer { lock.unlock() }; return _conns }
    var authHeaders: [String] { lock.lock(); defer { lock.unlock() }; return _auth }
    private(set) var port: UInt16 = 0
    var url: URL { URL(string: "ws://127.0.0.1:\(port)/transcribe-websocket")! }

    func start() throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.setClientRequestHandler(queue) { [weak self] _, headers in
            if let auth = headers.first(where: { $0.name.lowercased() == "authorization" }) {
                self?.lock.lock(); self?._auth.append(auth.value); self?.lock.unlock()
            } else {
                self?.lock.lock(); self?._auth.append(""); self?.lock.unlock()
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            lock.lock()
            let conn = Conn(c, index: _conns.count)
            _conns.append(conn)
            lock.unlock()
            onConnection?(conn)
            conn.start(queue: queue)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] st in
            if case .ready = st { self?.port = self?.listener.port?.rawValue ?? 0; ready.signal() }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw URLError(.cannotConnectToHost) }
    }

    func stop() {
        listener?.cancel()
        connections.forEach { $0.close() }
    }
}

/// Polls until `cond` is true or the timeout elapses.
func waitUntil(_ timeout: TimeInterval = 5, _ cond: @Sendable () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return cond()
}

final class EventLog<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
    func add(_ x: T) { lock.lock(); items.append(x); lock.unlock() }
}

/// Same as `waitUntil` but the condition runs on the main actor (for engine / store state).
@MainActor
func waitMain(_ timeout: TimeInterval = 5, _ cond: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return cond()
}
