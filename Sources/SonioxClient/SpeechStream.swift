import Foundation

/// One live recognition (+ translation) stream, whatever runs it: a cloud API or a model on this Mac.
///
/// Input: 16 kHz mono pcm_s16le, 100 ms chunks. Output: `SonioxEvent`s — Soniox's token model (final / non-final,
/// original / translation tracks, `<end>` markers) is the common format every adapter emits, so the transcript
/// assembler and the UI do not care which engine is running.
public protocol SpeechStream: AnyObject, Sendable {
    var events: AsyncStream<SonioxEvent> { get }
    func start() async
    func send(_ chunk: Data) async
    /// Flush the current draft (pause / source switch).
    func finalize() async
    /// Graceful end: process what was sent, emit the remaining finals, then `.finished` and `.state(.closed)`.
    func stop() async
}

extension SonioxSession: SpeechStream {}
