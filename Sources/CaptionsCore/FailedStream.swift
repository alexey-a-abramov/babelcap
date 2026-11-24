import Foundation
import SonioxClient

/// Stands in for an engine that could not be created, so the failure shows up like any other stream error.
final class FailedStream: SpeechStream, @unchecked Sendable {
    let events: AsyncStream<SonioxEvent>
    private let continuation: AsyncStream<SonioxEvent>.Continuation
    private let message: String

    init(_ message: String) {
        self.message = message
        var c: AsyncStream<SonioxEvent>.Continuation!
        events = AsyncStream { c = $0 }
        continuation = c
    }

    func start() async {
        continuation.yield(.error(SonioxError(code: 1000, message: message)))
        continuation.yield(.state(.failed))
        continuation.finish()
    }
    func send(_ chunk: Data) async {}
    func finalize() async {}
    func stop() async { continuation.finish() }
}
