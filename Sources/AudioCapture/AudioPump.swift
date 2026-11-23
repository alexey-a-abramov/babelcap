import Foundation

public struct AudioMeter: Sendable {
    public var rms: Float
    public var peak: Float
    /// Samples read this tick; 0 means the capture delivered nothing at all (dead tap / stalled engine).
    public var samples: Int = 0
}

/// Reads a source's ring every 100 ms, resamples to 16 kHz mono s16le and emits 3200-byte chunks.
public actor AudioPump {
    public nonisolated let chunks: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let onMeter: @Sendable (AudioMeter) -> Void

    private var source: (any AudioSource)?
    private var resampler: Resampler?
    private var pending = Data()
    private var task: Task<Void, Never>?
    private var scratch = [Float](repeating: 0, count: 96_000)

    public init(onMeter: @escaping @Sendable (AudioMeter) -> Void) {
        var c: AsyncStream<Data>.Continuation!
        chunks = AsyncStream(bufferingPolicy: .bufferingNewest(600)) { c = $0 }
        continuation = c
        self.onMeter = onMeter
    }

    public func setSource(_ source: any AudioSource) {
        self.source = source
        resampler = Resampler(inputRate: source.sampleRate)
        pending.removeAll(keepingCapacity: true)
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self?.tick()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        continuation.finish()
    }

    private func tick() {
        guard let source, let resampler else { return }
        let n = scratch.withUnsafeMutableBufferPointer { buf in
            source.ring.read(into: buf.baseAddress!, max: buf.count)
        }
        guard n > 0 else { onMeter(AudioMeter(rms: 0, peak: 0)); return }

        var sum: Float = 0
        var peak: Float = 0
        scratch.withUnsafeBufferPointer { buf in
            for i in 0..<n { let v = buf[i]; sum += v * v; peak = max(peak, abs(v)) }
        }
        onMeter(AudioMeter(rms: (sum / Float(n)).squareRoot(), peak: peak, samples: n))

        let out = scratch.withUnsafeBufferPointer { resampler.convert(UnsafeBufferPointer(rebasing: $0[0..<n])) }
        pending.append(out)
        while pending.count >= Resampler.chunkBytes {
            continuation.yield(pending.prefix(Resampler.chunkBytes))
            pending.removeFirst(Resampler.chunkBytes)
        }
    }
}
