@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

/// Microphone via AVAudioEngine, with optional voice processing (echo cancellation).
public final class MicCapture: AudioSource, @unchecked Sendable {
    public let ring = RingBuffer(capacity: 48_000 * 20)
    public private(set) var sampleRate: Double = 48_000
    /// Voice processing is actually active (it depends on the output device, so it must follow output changes).
    public private(set) var usesVoiceProcessing = false

    private let deviceUID: String?
    private let voiceProcessing: Bool
    private var engine: AVAudioEngine?
    private let downmixer = Downmixer()
    private let log = Logger(subsystem: "app.subveil", category: "MicCapture")

    public init(deviceUID: String?, voiceProcessing: Bool) {
        self.deviceUID = deviceUID
        self.voiceProcessing = voiceProcessing
    }

    deinit { stop() }

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    public func start() throws {
        stop()
        guard Self.isAuthorized else { throw CaptureError.micDenied }
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let uid = deviceUID, var dev = AudioDevices.deviceID(forUID: uid), let unit = input.audioUnit {
            let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioObjectID>.size))
            if st != noErr { log.error("set input device failed: \(st)") }
        }

        var vpActive = false
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Keep ducking of other audio to a minimum.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                vpActive = true
            } catch {
                log.error("voice processing unavailable: \(error.localizedDescription)")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CaptureError.osStatus("input format", -1) }
        sampleRate = format.sampleRate

        let ring = self.ring
        let downmixer = self.downmixer
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            if vpActive || buffer.format.channelCount == 1 {
                // With voice processing the processed signal is on channel 0.
                ring.write(data[0], count: frames)
            } else {
                // Planar: wrap each channel as its own AudioBuffer and let the downmixer average.
                let n = Int(buffer.format.channelCount)
                let abl = buffer.mutableAudioBufferList
                _ = n
                downmixer.push(UnsafeMutableAudioBufferListPointer(abl), into: ring)
            }
        }
        usesVoiceProcessing = vpActive
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        self.engine = engine
        log.info("mic started, rate \(self.sampleRate), vp \(vpActive)")
    }

    public func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        ring.reset()
    }
}
