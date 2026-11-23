import Foundation
import Observation
import SonioxClient

/// UI-facing transcript. Collects tokens per stream, merges segments in time order and coalesces updates to ~1 per frame.
@MainActor @Observable
public final class TranscriptStore {
    public private(set) var segments: [Segment] = []
    public private(set) var sessionStart = Date()
    public var dedupeEchoes = true

    @ObservationIgnored private var assemblers: [SourceKind: TokenAssembler] = [
        .system: TokenAssembler(source: .system, idOffset: 0),
        .mic: TokenAssembler(source: .mic, idOffset: 1),
        .mixed: TokenAssembler(source: .mixed, idOffset: 2),
    ]
    @ObservationIgnored private var rebuildScheduled = false
    @ObservationIgnored private var idleTasks: [SourceKind: Task<Void, Never>] = [:]
    /// A segment with no new tokens for this long is closed.
    public var pauseCloseSeconds: Double = 2.5

    public init() {}

    public func apply(_ tokens: [SonioxToken], from source: SourceKind) {
        assemblers[source]?.handle(tokens)
        scheduleRebuild()
        idleTasks[source]?.cancel()
        idleTasks[source] = Task { [weak self, pauseCloseSeconds] in
            try? await Task.sleep(for: .seconds(pauseCloseSeconds))
            guard !Task.isCancelled else { return }
            self?.closeOpenSegment(source)
        }
    }

    public func closeOpenSegment(_ source: SourceKind) {
        assemblers[source]?.closeOpenSegment()
        scheduleRebuild()
    }

    public func clear() {
        for k in assemblers.keys { assemblers[k] = TokenAssembler(source: k, idOffset: [.system: 0, .mic: 1, .mixed: 2][k]!) }
        sessionStart = Date()
        rebuild()
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            self?.rebuildScheduled = false
            self?.rebuild()
        }
    }

    private func rebuild() {
        var all = assemblers.values.flatMap(\.snapshot).filter { !$0.isEmpty }
        all.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        if dedupeEchoes {
            let system = all.filter { $0.source == .system }
            for i in all.indices where all[i].source == .mic {
                all[i].hidden = EchoDeduper.isEcho(mic: all[i], system: system)
            }
        }
        segments = all
    }

    public func export(_ format: ExportFormat) -> String {
        Exporters.export(segments, format: format, start: sessionStart)
    }
}
