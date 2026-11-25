@preconcurrency import AVFoundation
import AppSettings
import Foundation
import Observation
import SonioxClient
import Transcript

/// Reads finished translations of other people's speech (System stream) aloud — handy with headphones.
///
/// Speech is rendered to buffers and played by Babelcap's own audio engine, so it comes from this process — which the
/// system-audio tap excludes — and is never captured and transcribed again.
@MainActor
public final class TranslationVoice: NSObject {
    private let store: TranscriptStore
    private let settings: SettingsStore
    private let synth = AVSpeechSynthesizer()
    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private var spoken = Set<Int>()

    public init(store: TranscriptStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        super.init()
        track()
    }

    private func track() {
        withObservationTracking { _ = store.segments } onChange: { [weak self] in
            Task { @MainActor in self?.speakNew(); self?.track() }
        }
    }

    private func speakNew() {
        guard settings.profile.session.speakTranslations else { spoken = Set(store.segments.map(\.id)); return }
        for s in store.segments where s.isClosed && s.source != .mic && !spoken.contains(s.id) {
            let text = s.translation.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }   // wait until its translation arrives
            spoken.insert(s.id)
            let u = AVSpeechUtterance(string: text)
            let target = settings.profile.translationSystem.target
            u.voice = AVSpeechSynthesisVoice(language: target) ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
            u.rate = Float(settings.profile.session.speechRate)
            play(u)
        }
        if store.segments.isEmpty { spoken.removeAll() }
    }

    private func play(_ utterance: AVSpeechUtterance) {
        synth.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
            Task { @MainActor in self?.schedule(pcm) }
        }
    }

    private func schedule(_ pcm: AVAudioPCMBuffer) {
        if connectedFormat != pcm.format {
            if audio.isRunning { audio.stop() }
            if connectedFormat == nil { audio.attach(player) } else { audio.disconnectNodeOutput(player) }
            audio.connect(player, to: audio.mainMixerNode, format: pcm.format)
            connectedFormat = pcm.format
        }
        if !audio.isRunning { try? audio.start() }
        player.scheduleBuffer(pcm)
        if !player.isPlaying { player.play() }
    }

    public func stop() { player.stop() }
}
