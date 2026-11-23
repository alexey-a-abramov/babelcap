import CoreAudio
import Foundation

public protocol AudioSource: AnyObject, Sendable {
    /// Mono Float32 samples at `sampleRate`.
    var ring: RingBuffer { get }
    var sampleRate: Double { get }
    func start() throws
    func stop()
}

public enum CaptureError: LocalizedError {
    case osStatus(String, OSStatus)
    case noApps
    case noOutputDevice
    case micDenied

    public var errorDescription: String? {
        switch self {
        case let .osStatus(what, s): "\(what) failed (OSStatus \(s))"
        case .noApps: "None of the selected apps is producing audio yet"
        case .noOutputDevice: "No default output device"
        case .micDenied: "Microphone access denied"
        }
    }
}

/// Mixes interleaved/planar multi-channel float data down to mono and pushes it into a ring.
/// Real-time safe: uses a preallocated scratch buffer.
final class Downmixer: @unchecked Sendable {
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 16_384

    init() { scratch = .allocate(capacity: scratchFrames) }
    deinit { scratch.deallocate() }

    func push(_ list: UnsafeMutableAudioBufferListPointer, into ring: RingBuffer) {
        guard list.count > 0 else { return }
        var totalChannels = 0
        var frames = Int.max
        for b in list {
            let ch = max(1, Int(b.mNumberChannels))
            totalChannels += ch
            frames = min(frames, Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch))
        }
        guard frames > 0, frames != Int.max else { return }
        var offset = 0
        while offset < frames {
            let n = min(scratchFrames, frames - offset)
            for i in 0..<n { scratch[i] = 0 }
            for b in list {
                guard let data = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = max(1, Int(b.mNumberChannels))
                for i in 0..<n {
                    var s: Float = 0
                    for c in 0..<ch { s += data[(offset + i) * ch + c] }
                    scratch[i] += s
                }
            }
            let inv = 1 / Float(totalChannels)
            for i in 0..<n { scratch[i] *= inv }
            ring.write(scratch, count: n)
            offset += n
        }
    }
}
