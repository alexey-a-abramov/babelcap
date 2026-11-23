import CoreAudio
import Foundation
import os

/// System audio via Core Audio process taps (macOS 14.2+) + private aggregate device.
/// When permission is denied the tap does not fail — it delivers silence (see SilenceDetector).
public final class SystemAudioTap: AudioSource, @unchecked Sendable {
    public enum Scope: Sendable, Equatable {
        case all
        case apps(bundleIDs: [String])
    }

    public let ring = RingBuffer(capacity: 48_000 * 20)
    public private(set) var sampleRate: Double = 48_000

    private let scope: Scope
    private let downmixer = Downmixer()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "subveil.systemtap", qos: .userInteractive)
    private let log = Logger(subsystem: "app.subveil", category: "SystemAudioTap")

    public init(scope: Scope) { self.scope = scope }
    deinit { stop() }

    public func start() throws {
        stop()
        do { try startInternal() } catch { stop(); throw error }
    }

    private func startInternal() throws {
        guard let outputUID = AudioDevices.defaultOutputUID() else { throw CaptureError.noOutputDevice }

        let desc: CATapDescription
        switch scope {
        case .all:
            let own = AudioProcessList.processObject(forPID: getpid())
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        case let .apps(ids):
            let objs = AudioProcessList.processObjects(forBundleIDs: ids)
            guard !objs.isEmpty else { throw CaptureError.noApps }
            desc = CATapDescription(stereoMixdownOfProcesses: objs)
        }
        let tapUUID = UUID()
        desc.uuid = tapUUID
        desc.name = "Subveil tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { throw CaptureError.osStatus("AudioHardwareCreateProcessTap", st) }

        if let asbd: AudioStreamBasicDescription = HAL.get(tapID, kAudioTapPropertyFormat), asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
        }

        let aggUID = UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Subveil aggregate",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        guard st == noErr else { throw CaptureError.osStatus("AudioHardwareCreateAggregateDevice", st) }

        let ring = self.ring
        let downmixer = self.downmixer
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inData, _, _, _ in
            downmixer.push(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)), into: ring)
        }
        guard st == noErr else { throw CaptureError.osStatus("AudioDeviceCreateIOProcIDWithBlock", st) }

        st = AudioDeviceStart(aggregateID, procID)
        guard st == noErr else { throw CaptureError.osStatus("AudioDeviceStart", st) }
        log.info("tap started, rate \(self.sampleRate)")
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        ring.reset()
    }
}
