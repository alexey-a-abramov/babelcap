import AudioCapture
import Foundation
import Observation
import SonioxClient

/// Short-lived capture used by onboarding to show a live level for a source.
@MainActor @Observable
public final class LevelProbe {
    public private(set) var level: Float = 0
    public private(set) var error: String?
    public private(set) var gotSignal = false
    @ObservationIgnored private var capture: (any AudioSource)?
    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    public func start(_ kind: SourceKind, micUID: String? = nil) async {
        stop()
        error = nil; gotSignal = false
        if kind == .mic, !(await MicCapture.requestAccess()) { error = "Microphone access denied"; return }
        let cap: any AudioSource = kind == .mic ? MicCapture(deviceUID: MicSelection.deviceUID(for: micUID), voiceProcessing: false) : SystemAudioTap(scope: .all)
        do { try cap.start() } catch { self.error = error.localizedDescription; return }
        capture = cap
        task = Task { [weak self] in
            var buf = [Float](repeating: 0, count: 48_000)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, let cap = self.capture else { return }
                let n = buf.withUnsafeMutableBufferPointer { cap.ring.read(into: $0.baseAddress!, max: $0.count) }
                var peak: Float = 0
                for i in 0..<n { peak = max(peak, abs(buf[i])) }
                self.level = max(min(1, peak * 3), self.level * 0.85)
                if peak > 0.002 { self.gotSignal = true }
            }
        }
    }

    public func stop() {
        task?.cancel(); task = nil
        capture?.stop(); capture = nil
        level = 0
    }
}
