import AppKit
import CoreAudio
import Foundation

/// Fires (debounced) when the default output device, the device list, or the audio-process list changes,
/// and on system sleep/wake. Callers recreate taps / engines in response.
public final class DeviceMonitor: @unchecked Sendable {
    public enum Event: Sendable { case outputChanged, inputChanged, devicesChanged, processesChanged, didWake }

    private let handler: @Sendable (Event) -> Void
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "subveil.devicemonitor")
    private var debounce: [String: DispatchWorkItem] = [:]

    public init(handler: @escaping @Sendable (Event) -> Void) { self.handler = handler }

    public func start() {
        add(kAudioHardwarePropertyDefaultOutputDevice, .outputChanged)
        add(kAudioHardwarePropertyDefaultInputDevice, .inputChanged)
        add(kAudioHardwarePropertyDevices, .devicesChanged)
        add(kAudioHardwarePropertyProcessObjectList, .processesChanged, delay: 1.0)
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.fire("wake", .didWake, delay: 1.5)
        })
    }

    public func stop() {
        for (var addr, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        }
        listeners.removeAll()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    private func add(_ sel: AudioObjectPropertySelector, _ event: Event, delay: TimeInterval = 0.4) {
        var addr = HAL.address(sel)
        let key = "\(sel)"
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.fire(key, event, delay: delay) }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
            listeners.append((addr, block))
        }
    }

    private func fire(_ key: String, _ event: Event, delay: TimeInterval) {
        queue.async { [self] in
            debounce[key]?.cancel()
            let item = DispatchWorkItem { [handler] in handler(event) }
            debounce[key] = item
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }
}
