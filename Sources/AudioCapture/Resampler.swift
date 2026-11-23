@preconcurrency import AVFoundation
import Foundation

/// Converts mono Float32 at an arbitrary rate to 16 kHz mono pcm_s16le.
public final class Resampler {
    public static let outputRate: Double = 16_000
    /// 100 ms of 16 kHz mono s16le.
    public static let chunkBytes = 3200

    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let rate: Double

    public init?(inputRate: Double) {
        guard inputRate > 0,
              let i = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let o = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.outputRate, channels: 1, interleaved: true),
              let c = AVAudioConverter(from: i, to: o)
        else { return nil }
        inFormat = i; outFormat = o; converter = c; rate = inputRate
    }

    public func convert(_ samples: UnsafeBufferPointer<Float>) -> Data {
        guard samples.count > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return Data() }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        inBuf.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)

        let cap = AVAudioFrameCount(Double(samples.count) * Self.outputRate / rate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return Data() }

        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return inBuf
        }
        guard error == nil, outBuf.frameLength > 0, let p = outBuf.int16ChannelData?[0] else { return Data() }
        return Data(bytes: p, count: Int(outBuf.frameLength) * MemoryLayout<Int16>.size)
    }
}
