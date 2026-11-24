import Foundation
import SonioxClient

/// Lock-protected flag that decides whether audio chunks are forwarded (Pause = closed).
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    var isOpen: Bool {
        get { lock.lock(); defer { lock.unlock() }; return open }
        set { lock.lock(); open = newValue; lock.unlock() }
    }
}

/// Holder for the *current* Soniox session so it can be swapped without interrupting the audio flow.
final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: (any SpeechStream)?
    func get() -> (any SpeechStream)? { lock.lock(); defer { lock.unlock() }; return session }
    func set(_ s: (any SpeechStream)?) { lock.lock(); session = s; lock.unlock() }
    func take() -> (any SpeechStream)? { lock.lock(); defer { lock.unlock() }; let s = session; session = nil; return s }
}

/// Combines 100 ms chunks from N inputs. With one input it is a pass-through; with two it sums the PCM
/// (the "Mix into one stream" option). If one input stalls (> 3 chunks behind) the other is forwarded alone.
final class ChunkMixer: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [[Data]]
    private let out: @Sendable (Data) -> Void

    init(inputs: Int, out: @escaping @Sendable (Data) -> Void) {
        queues = Array(repeating: [], count: inputs)
        self.out = out
    }

    func push(_ index: Int, _ data: Data) {
        var emit: [Data] = []
        lock.lock()
        queues[index].append(data)
        while true {
            if queues.allSatisfy({ !$0.isEmpty }) {
                emit.append(Self.mix(queues.indices.map { queues[$0].removeFirst() }))
            } else if let j = queues.indices.first(where: { queues[$0].count > 3 }) {
                emit.append(queues[j].removeFirst())
            } else { break }
        }
        lock.unlock()
        emit.forEach(out)
    }

    static func mix(_ parts: [Data]) -> Data {
        guard parts.count > 1 else { return parts.first ?? Data() }
        let n = parts.map(\.count).min() ?? 0
        var result = Data(count: n)
        result.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            let d = dst.bindMemory(to: Int16.self)
            for p in parts.indices {
                parts[p].withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                    let s = src.bindMemory(to: Int16.self)
                    for i in 0..<(n / 2) {
                        let v = p == 0 ? Int32(s[i]) : Int32(d[i]) + Int32(s[i])
                        d[i] = Int16(max(-32768, min(32767, v)))
                    }
                }
            }
        }
        return result
    }
}
