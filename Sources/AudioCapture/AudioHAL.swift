import AppKit
import CoreAudio
import Foundation

enum HAL {
    static func address(_ sel: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var addr = address(sel, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, p) == noErr else { return nil }
        return p.pointee
    }

    static func array<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of: T.Type = T.self) -> [T] {
        var addr = address(sel, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let n = Int(size) / MemoryLayout<T>.stride
        let p = UnsafeMutablePointer<T>.allocate(capacity: n)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, p) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(sel, scope: scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let st = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
        }
        guard st == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func inputChannelCount(_ dev: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
}

public enum AudioDevices {
    public static func inputDevices() -> [AudioInputDevice] {
        let ids: [AudioObjectID] = HAL.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        return ids.compactMap { id in
            guard HAL.inputChannelCount(id) > 0,
                  let uid = HAL.string(id, kAudioDevicePropertyDeviceUID),
                  let name = HAL.string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    public static func defaultOutputDevice() -> AudioObjectID? {
        let id: AudioObjectID? = HAL.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    public static func defaultOutputUID() -> String? {
        defaultOutputDevice().flatMap { HAL.string($0, kAudioDevicePropertyDeviceUID) }
    }

    /// True when output goes through the built-in speakers (echo risk when mic is also on).
    public static func defaultOutputIsBuiltInSpeaker() -> Bool {
        guard let dev = defaultOutputDevice() else { return false }
        let transport: UInt32? = HAL.get(dev, kAudioDevicePropertyTransportType)
        return transport == kAudioDeviceTransportTypeBuiltIn
    }
}

public struct AudioProcessInfo: Identifiable, Hashable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let isRunningOutput: Bool
    public var id: AudioObjectID { objectID }
}

/// An app the user can pick for per-process capture (grouped by bundle ID).
public struct AudioApp: Identifiable, Hashable, Sendable {
    public let bundleID: String
    public let name: String
    public let isPlaying: Bool
    public var id: String { bundleID }
}

public enum AudioProcessList {
    public static func current() -> [AudioProcessInfo] {
        let objs: [AudioObjectID] = HAL.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return objs.compactMap { o in
            guard let pid: pid_t = HAL.get(o, kAudioProcessPropertyPID) else { return nil }
            let bid = HAL.string(o, kAudioProcessPropertyBundleID) ?? ""
            let running: UInt32 = HAL.get(o, kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioProcessInfo(objectID: o, pid: pid, bundleID: bid, isRunningOutput: running != 0)
        }
    }

    public static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = HAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return (st == noErr && obj != kAudioObjectUnknown) ? obj : nil
    }

    /// Process objects belonging to the app (main process + helpers like `com.foo.App.helper`).
    public static func processObjects(forBundleIDs ids: [String]) -> [AudioObjectID] {
        current().filter { p in
            ids.contains { p.bundleID == $0 || p.bundleID.hasPrefix($0 + ".") }
        }.map(\.objectID)
    }

    /// Apps currently registered with Core Audio, grouped to their user-visible parent app.
    public static func apps() -> [AudioApp] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        var result: [String: AudioApp] = [:]
        for p in current() where !p.bundleID.isEmpty {
            guard let parent = running.first(where: { r in
                let b = r.bundleIdentifier!
                return p.bundleID == b || p.bundleID.hasPrefix(b + ".")
            }) else { continue }
            let b = parent.bundleIdentifier!
            let playing = (result[b]?.isPlaying ?? false) || p.isRunningOutput
            result[b] = AudioApp(bundleID: b, name: parent.localizedName ?? b, isPlaying: playing)
        }
        return result.values.sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
    }

    public static func icon(forBundleID id: String) -> NSImage? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.icon
    }
}
