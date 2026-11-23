import AppKit
import AudioCapture
import AppSettings
import Foundation
import Observation
import os
import SonioxClient
import Transcript

public enum ConnState: Equatable, Sendable {
    case idle, connecting, live, reconnecting, autoPaused
    case error(String)

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .connecting: "Connecting"
        case .live: "Live"
        case .reconnecting: "Reconnecting"
        case .autoPaused: "Auto-paused (silence)"
        case let .error(m): m
        }
    }
}

public enum RunState: Sendable { case idle, running, paused }

@MainActor
final class Runtime {
    let kind: SourceKind
    var captures: [SourceKind: any AudioSource] = [:]
    var pumps: [SourceKind: AudioPump] = [:]
    let gate = Gate()
    let box = SessionBox()
    var tasks: [Task<Void, Never>] = []
    var sessionID = 0
    var lastVoice = Date()
    var billedSeconds: Double = 0
    var conn: ConnState = .connecting
    var hasTranslation = false
    var mixer: ChunkMixer?

    init(kind: SourceKind) { self.kind = kind }

    /// Physical audio sources feeding this runtime.
    var physical: [SourceKind] { kind == .mixed ? [.system, .mic] : [kind] }
}

@MainActor @Observable
public final class CaptionsEngine {
    public let settings: SettingsStore
    public let store: TranscriptStore

    public internal(set) var runState: RunState = .idle
    /// Connection state per stream (system / mic / mixed).
    public internal(set) var conn: [SourceKind: ConnState] = [:]
    /// 0…1 level per physical source.
    public private(set) var levels: [SourceKind: Float] = [:]
    public internal(set) var elapsed: TimeInterval = 0
    public private(set) var estimatedCost: Double = 0
    public private(set) var lastError: String?
    public private(set) var needsKey = false
    /// Tap delivers zeros although something is playing → permission probably denied.
    public private(set) var systemPermissionHint = false
    /// Both sources on, output through built-in speakers → echo risk.
    public private(set) var speakerEchoHint = false
    public private(set) var captureErrors: [SourceKind: String] = [:]

    /// Test / debugging seams.
    @ObservationIgnored public var captureFactory: (@MainActor (SourceKind, RecognitionSettings) -> any AudioSource)?
    @ObservationIgnored public var endpoint: URL = SonioxSession.endpoint
    @ObservationIgnored public var historyDirectory: URL = AppPaths.historyDir
    @ObservationIgnored private var apiKey = ""

    @ObservationIgnored private var runtimes: [SourceKind: Runtime] = [:]
    @ObservationIgnored private var meterCounts: [SourceKind: Int] = [:]
    /// Watchdog bookkeeping per physical source.
    @ObservationIgnored private var lastSamplesAt: [SourceKind: Date] = [:]
    @ObservationIgnored private var lastRebuildAt: [SourceKind: Date] = [:]
    /// Seconds without any samples (or, for the mic, with exact digital silence) before a capture is rebuilt.
    @ObservationIgnored public var watchdogSeconds: TimeInterval = 4
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: DeviceMonitor?
    @ObservationIgnored private var zeroSince: [SourceKind: Date] = [:]
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var reconcileAgain = false
    @ObservationIgnored private let log = Logger(subsystem: "app.subveil", category: "Engine")

    public init(settings: SettingsStore, store: TranscriptStore) {
        self.settings = settings
        self.store = store
    }

    public var isRunning: Bool { runState != .idle }

    /// Aggregate status for the status dot.
    public var overall: ConnState {
        guard runState != .idle else { return .idle }
        let all = Array(conn.values)
        if let e = all.first(where: { if case .error = $0 { true } else { false } }) { return e }
        if all.contains(.reconnecting) { return .reconnecting }
        if all.contains(.connecting) { return .connecting }
        if !all.isEmpty, all.allSatisfy({ $0 == .autoPaused }) { return .autoPaused }
        return .live
    }

    // MARK: Lifecycle

    public func start() async {
        Trace.log("engine", "start requested (state \(runState))")
        guard runState == .idle else { return }
        // Off the main thread: macOS may show a "Subveil wants to use your confidential information" dialog here.
        let keychain = settings.keychain
        let keyResult = await Task.detached { keychain.read() }.value
        guard runState == .idle else { return }
        switch keyResult {
        case let .found(k):
            apiKey = k
        case .notFound:
            needsKey = true
            lastError = "No Soniox API key saved. Open Settings → Account."
            Trace.log("engine", "start aborted: no key")
            return
        case let .failed(st):
            needsKey = true
            lastError = "Keychain refused access (\(KeychainStore.message(st))). Re-enter the key in Settings → Account."
            Trace.log("engine", "start aborted: keychain status \(st)")
            return
        }
        needsKey = false; lastError = nil
        store.clear()   // every session starts from a clean transcript
        store.dedupeEchoes = settings.profile.session.dedupeEchoes
        elapsed = 0; estimatedCost = 0; systemPermissionHint = false
        runState = .running
        Trace.log("engine", "running; sources=\(settings.profile.sources.rawValue) mix=\(settings.profile.session.mixIntoOne) model=\(settings.modelName)")
        await reconcile()
        startTick()
        startMonitor()
        if runtimes.isEmpty {
            Trace.log("engine", "no runtime could start → stopping")
            await stop()
        }
    }

    public func pause() async {
        guard runState == .running else { return }
        runState = .paused
        for rt in runtimes.values {
            rt.gate.isOpen = false
            await rt.box.get()?.finalize()
        }
    }

    public func resume() {
        guard runState == .paused else { return }
        runState = .running
        for rt in runtimes.values { rt.gate.isOpen = true }
    }

    public func toggleStartStop() async {
        if runState == .idle { await start() } else { await stop() }
    }

    public func togglePause() async {
        if runState == .paused { resume() } else { await pause() }
    }

    public func stop() async {
        guard runState != .idle else { return }
        Trace.log("engine", "stop (elapsed \(Int(elapsed)) s, segments \(store.segments.count))")
        runState = .idle
        tickTask?.cancel(); tickTask = nil
        monitor?.stop(); monitor = nil
        for rt in runtimes.values { await teardown(rt) }
        runtimes.removeAll()
        for k in SourceKind.allCases { store.closeOpenSegment(k) }
        conn.removeAll(); levels.removeAll(); zeroSince.removeAll(); lastSamplesAt.removeAll(); lastRebuildAt.removeAll()
        saveHistory()
    }

    // MARK: Live switching (history is kept, only capture / sessions change)

    public func setSources(_ mode: SourceMode) async {
        settings.profile.sources = mode
        if isRunning { await reconcile() }
    }

    public func setMix(_ on: Bool) async {
        settings.profile.session.mixIntoOne = on
        if isRunning { await reconcile() }
    }

    public func setMicDevice(_ uid: String?) async {
        settings.profile.recognition.micDeviceUID = uid
        for rt in runtimes.values where rt.physical.contains(.mic) { await rebuildCapture(.mic, in: rt) }
    }

    public func setApps(_ ids: [String]) async {
        settings.profile.recognition.appBundleIDs = ids
        for rt in runtimes.values where rt.physical.contains(.system) { await rebuildCapture(.system, in: rt) }
    }

    /// Language / translation / context changes need a new server session: open it before closing the old one.
    public func applyConfigChange() async {
        guard isRunning else { return }
        for rt in runtimes.values where !(rt.conn == .autoPaused) { await swapSession(rt) }
    }

    // MARK: Runtimes

    private func desiredKinds() -> Set<SourceKind> {
        let p = settings.profile
        switch p.sources {
        case .system: return [.system]
        case .mic: return [.mic]
        case .both: return p.session.mixIntoOne ? [.mixed] : [.system, .mic]
        }
    }

    private func reconcile() async {
        if reconciling { reconcileAgain = true; return }
        reconciling = true
        defer { reconciling = false }
        repeat {
            reconcileAgain = false
            let want = desiredKinds()
            for (k, rt) in runtimes where !want.contains(k) {
                await teardown(rt)
                runtimes[k] = nil; conn[k] = nil
                store.closeOpenSegment(k)
            }
            for k in want where runtimes[k] == nil && runState != .idle { await startRuntime(k) }
        } while reconcileAgain && runState != .idle
    }

    private func makeCapture(_ k: SourceKind) -> any AudioSource {
        let r = settings.profile.recognition
        if let f = captureFactory { return f(k, r) }
        switch k {
        case .mic:
            // Voice processing reconfigures the audio hardware and knocks out a concurrently running system-audio tap
            // (observed: one of the two inputs goes silent). Use it only when the mic is the sole capture.
            let systemToo = runtimes.values.contains { $0.physical.contains(.system) } || desiredKinds().contains(where: { $0 != .mic })
            return MicCapture(deviceUID: r.micDeviceUID, voiceProcessing: r.voiceProcessing && !systemToo)
        default: return SystemAudioTap(scope: r.appBundleIDs.isEmpty ? .all : .apps(bundleIDs: r.appBundleIDs))
        }
    }

    private func startRuntime(_ kind: SourceKind) async {
        let rt = Runtime(kind: kind)
        rt.gate.isOpen = runState != .paused
        runtimes[kind] = rt
        conn[kind] = .connecting

        Trace.log("engine", "startRuntime \(kind.rawValue)")
        if captureFactory == nil, rt.physical.contains(.mic), !(await MicCapture.requestAccess()) {
            captureErrors[.mic] = CaptureError.micDenied.localizedDescription
            lastError = "Microphone access denied — enable it in System Settings → Privacy & Security → Microphone"
            if kind == .mic { runtimes[kind] = nil; conn[kind] = nil; return }
        }

        let (stream, cont) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(600))
        let mixer = ChunkMixer(inputs: rt.physical.count) { cont.yield($0) }
        rt.mixer = mixer

        for (i, phys) in rt.physical.enumerated() {
            let pump = AudioPump { [weak self] meter in
                Task { @MainActor in self?.handleMeter(meter, physical: phys, runtime: kind) }
            }
            rt.pumps[phys] = pump
            await attachCapture(phys, to: rt, pump: pump)
            await pump.start()
            let chunks = pump.chunks
            rt.tasks.append(Task.detached { for await c in chunks { mixer.push(i, c) } })
        }
        guard !rt.captures.isEmpty else {
            runtimes[kind] = nil
            conn[kind] = .error(lastError ?? "No audio source could be started")
            return
        }

        // Sequential consumer: forwards chunks to whichever session is current; preroll while none is open.
        let gate = rt.gate, box = rt.box
        rt.tasks.append(Task.detached {
            var pending: [Data] = []
            for await c in stream {
                guard gate.isOpen else { pending.removeAll(); continue }
                if let s = box.get() {
                    for p in pending { await s.send(p) }
                    pending.removeAll()
                    await s.send(c)
                } else {
                    pending.append(c)
                    if pending.count > 15 { pending.removeFirst() }
                }
            }
        })
        rt.tasks.append(Task { _ = cont }) // keep continuation alive for the runtime's lifetime

        let session = await openSession(rt)
        rt.box.set(session)
    }

    private func attachCapture(_ phys: SourceKind, to rt: Runtime, pump: AudioPump) async {
        let cap = makeCapture(phys)
        do {
            try cap.start()
            rt.captures[phys] = cap
            captureErrors[phys] = nil
            await pump.setSource(cap)
            Trace.log("capture", "\(phys.rawValue) started, rate \(cap.sampleRate)")
            lastSamplesAt[phys] = Date()
        } catch {
            Trace.log("capture", "\(phys.rawValue) FAILED: \(error.localizedDescription)")
            captureErrors[phys] = error.localizedDescription
            lastError = "\(phys == .mic ? "Microphone" : "System audio"): \(error.localizedDescription)"
            log.error("capture \(phys.rawValue) failed: \(error.localizedDescription)")
        }
    }

    /// Rebuilds a capture that stopped delivering audio — a tap knocked out by another audio client, an engine that
    /// stalled after a device change, or a mic stuck at exact digital zeros (a real mic always has a noise floor).
    private func watchdog() async {
        guard runState == .running else { return }
        let now = Date()
        for rt in runtimes.values {
            for phys in rt.physical where rt.captures[phys] != nil {
                let starved = now.timeIntervalSince(lastSamplesAt[phys] ?? now) > watchdogSeconds
                let digitalSilence = phys == .mic && now.timeIntervalSince(zeroSince[.mic] ?? now) > watchdogSeconds + 2
                guard starved || digitalSilence, now.timeIntervalSince(lastRebuildAt[phys] ?? .distantPast) > 10 else { continue }
                Trace.log("watchdog", "\(phys.rawValue) \(starved ? "delivers no samples" : "is digitally silent") → rebuilding capture")
                lastRebuildAt[phys] = now
                await rebuildCapture(phys, in: rt)
                lastSamplesAt[phys] = Date()
                zeroSince[phys] = nil
            }
        }
    }

    private func rebuildCapture(_ phys: SourceKind, in rt: Runtime) async {
        guard let pump = rt.pumps[phys] else { return }
        let old = rt.captures[phys]
        let cap = makeCapture(phys)
        do {
            try cap.start()
            await pump.setSource(cap)
            rt.captures[phys] = cap
            old?.stop()
            captureErrors[phys] = nil
        } catch {
            captureErrors[phys] = error.localizedDescription
            lastError = "\(phys == .mic ? "Microphone" : "System audio"): \(error.localizedDescription)"
        }
    }

    private func teardown(_ rt: Runtime) async {
        rt.gate.isOpen = false
        if let s = rt.box.take() { await s.finalize(); await s.stop() }
        for p in rt.pumps.values { await p.stop() }
        for c in rt.captures.values { c.stop() }
        rt.tasks.forEach { $0.cancel() }
        rt.tasks.removeAll()
    }

    // MARK: Sessions

    func makeConfig(for kind: SourceKind) -> SonioxConfig {
        let p = settings.profile, r = p.recognition
        var c = SonioxConfig(model: settings.modelName)
        let tr = p.translation(for: kind == .mixed ? .system : kind)
        var hints = r.languageHints
        if tr.kind == .twoWay { for l in [tr.languageA, tr.languageB] where !hints.contains(l) { hints.append(l) } }
        c.languageHints = hints.isEmpty ? nil : hints
        c.languageHintsStrict = r.strictHints ? true : nil
        c.enableSpeakerDiarization = kind == .mic ? r.diarizationMic : (kind == .mixed ? (r.diarizationSystem || r.diarizationMic) : r.diarizationSystem)
        c.maxEndpointDelayMs = r.endpointDelayMs
        var ctx = SonioxConfig.Context()
        if !r.domain.isEmpty { ctx.general = [.init(key: "domain", value: r.domain)] }
        if !r.contextText.isEmpty { ctx.text = r.contextText }
        if !r.terms.isEmpty { ctx.terms = r.terms }
        if !r.glossary.isEmpty { ctx.translationTerms = r.glossary.map { .init(source: $0.source, target: $0.target) } }
        c.context = ctx.isEmpty ? nil : ctx
        c.translation = tr.soniox
        return c
    }

    private func openSession(_ rt: Runtime) async -> SonioxSession {
        let cfg = makeConfig(for: rt.kind)
        rt.hasTranslation = cfg.translation != nil
        Trace.log("engine", "open session \(rt.kind.rawValue): translation=\(cfg.translation != nil) diarization=\(cfg.enableSpeakerDiarization) hints=\(cfg.languageHints ?? [])")
        let s = SonioxSession(apiKey: apiKey, config: cfg, endpoint: endpoint)
        rt.sessionID += 1
        let id = rt.sessionID
        await s.start()
        rt.tasks.append(Task { [weak self] in
            for await e in s.events { self?.handle(e, runtime: rt, sessionID: id) }
        })
        return s
    }

    private func swapSession(_ rt: Runtime) async {
        let new = await openSession(rt)
        try? await Task.sleep(for: .milliseconds(800)) // let the new stream connect before cutting over
        let old = rt.box.get()
        rt.box.set(new)
        if let old { await old.finalize(); await old.stop() }
    }

    private func closeSessionForAutoPause(_ rt: Runtime) async {
        rt.conn = .autoPaused; conn[rt.kind] = .autoPaused
        if let s = rt.box.take() { await s.finalize(); await s.stop() }
    }

    private func reopenAfterAutoPause(_ rt: Runtime) async {
        guard rt.conn == .autoPaused, rt.box.get() == nil else { return }
        rt.conn = .connecting; conn[rt.kind] = .connecting
        rt.box.set(await openSession(rt))
    }

    private func handle(_ e: SonioxEvent, runtime rt: Runtime, sessionID: Int) {
        switch e {
        case let .tokens(t):
            store.apply(t, from: rt.kind)
        case let .state(s):
            Trace.log("session", "\(rt.kind.rawValue)#\(sessionID) state \(s)")
            guard sessionID == rt.sessionID, rt.conn != .autoPaused else { return }
            let mapped: ConnState = switch s {
            case .connecting: .connecting
            case .live: .live
            case .reconnecting: .reconnecting
            case .closed: rt.conn
            case .failed: .error(lastError ?? "Connection failed")
            }
            rt.conn = mapped; conn[rt.kind] = mapped
            if mapped == .live { lastError = nil }
        case let .error(err):
            Trace.log("session", "\(rt.kind.rawValue)#\(sessionID) error \(err.code) \(err.message)")
            guard sessionID == rt.sessionID else { return }
            lastError = err.localizedDescription
            if err.action == .fatalKey { needsKey = true; Task { await stop() } }
            else if err.action == .fatalBalance { Task { await stop() } }
        case .finished:
            break
        }
    }

    // MARK: Meters, tick, devices

    private func handleMeter(_ m: AudioMeter, physical: SourceKind, runtime: SourceKind) {
        guard let rt = runtimes[runtime] else { return }
        meterCounts[physical, default: 0] += 1
        if meterCounts[physical]! % 20 == 1 {
            Trace.log("meter", "\(physical.rawValue) rms \(String(format: "%.4f", m.rms)) peak \(String(format: "%.4f", m.peak))")
        }
        let db = 20 * log10(max(m.rms, 1e-6))
        let norm = Float(max(0, min(1, (db + 60) / 60)))
        levels[physical] = max(norm, (levels[physical] ?? 0) * 0.8)

        if m.samples > 0 { lastSamplesAt[physical] = Date() }
        if m.peak == 0 { zeroSince[physical] = zeroSince[physical] ?? Date() } else { zeroSince[physical] = nil }
        if m.rms > 0.004 {
            rt.lastVoice = Date()
            if rt.conn == .autoPaused, runState == .running { Task { await reopenAfterAutoPause(rt) } }
        }
    }

    private func startTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick(n); n += 1
            }
        }
    }

    private func tick(_ n: Int) async {
        guard runState != .idle else { return }
        elapsed += 1
        if n % 30 == 29 { saveHistory() }
        var cost = estimatedCost
        for rt in runtimes.values where rt.box.get() != nil {
            rt.billedSeconds += 1
            cost += (rt.hasTranslation ? 0.18 : 0.12) / 3600
        }
        estimatedCost = cost

        // Silent permission failure: zeros for > 8 s while some app is actually playing audio.
        if let z = zeroSince[.system], Date().timeIntervalSince(z) > 8, runtimes.values.contains(where: { $0.physical.contains(.system) }) {
            if n % 3 == 0 { systemPermissionHint = AudioProcessList.current().contains { $0.isRunningOutput } }
        } else if zeroSince[.system] == nil { systemPermissionHint = false }

        await watchdog()

        if n % 5 == 0 {
            speakerEchoHint = settings.profile.sources == .both && !settings.profile.session.mixIntoOne
                && AudioDevices.defaultOutputIsBuiltInSpeaker()
        }
        for k in levels.keys { levels[k] = (levels[k] ?? 0) * 0.85 }

        let minutes = settings.profile.session.autoPauseMinutes
        if minutes > 0, runState == .running {
            for rt in runtimes.values where rt.conn != .autoPaused && Date().timeIntervalSince(rt.lastVoice) > Double(minutes) * 60 {
                await closeSessionForAutoPause(rt)
            }
        }
    }

    private func startMonitor() {
        monitor?.stop()
        let m = DeviceMonitor { [weak self] event in
            Task { @MainActor in await self?.handleDevice(event) }
        }
        m.start()
        monitor = m
    }

    private func handleDevice(_ e: DeviceMonitor.Event) async {
        guard runState != .idle else { return }
        switch e {
        case .outputChanged, .didWake:
            for rt in runtimes.values {
                for p in rt.physical { await rebuildCapture(p, in: rt) }
            }
        case .devicesChanged:
            for rt in runtimes.values where rt.physical.contains(.mic) { await rebuildCapture(.mic, in: rt) }
        case .processesChanged:
            // Global taps follow new processes by themselves; only retry a capture that failed earlier.
            for rt in runtimes.values where rt.physical.contains(.system) && rt.captures[.system] == nil {
                await rebuildCapture(.system, in: rt)
            }
        }
    }

    // MARK: History

    /// Optional (off by default): writes the session's transcript to History/<sessionStart>.json every 30 s, on stop and on quit.
    public func saveHistory() {
        guard settings.profile.session.saveHistory else { return }
        HistoryFiles.save(store.segments, sessionStart: store.sessionStart, to: historyDirectory)
    }
}
