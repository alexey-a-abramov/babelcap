import Foundation
import os

/// Single-producer / single-consumer ring of mono Float32 samples.
/// The producer (real-time audio thread) never blocks: it uses `try_lock` and drops
/// samples on the (very rare) contention. When full, the oldest samples are overwritten.
public final class RingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var writeIndex = 0
    private var count = 0

    public init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    public var available: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return count
    }

    /// Real-time safe: no allocation, no blocking.
    public func write(_ samples: UnsafePointer<Float>, count n: Int) {
        guard n > 0, os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }
        let n = min(n, capacity)
        let first = min(n, capacity - writeIndex)
        (storage + writeIndex).update(from: samples, count: first)
        if first < n { storage.update(from: samples + first, count: n - first) }
        writeIndex = (writeIndex + n) % capacity
        count = min(capacity, count + n)
    }

    /// Reads up to `max` samples (oldest first). Returns the number read.
    @discardableResult
    public func read(into out: UnsafeMutablePointer<Float>, max: Int) -> Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let n = Swift.min(max, count)
        guard n > 0 else { return 0 }
        var readIndex = (writeIndex - count + capacity) % capacity
        let first = Swift.min(n, capacity - readIndex)
        out.update(from: storage + readIndex, count: first)
        if first < n { (out + first).update(from: storage, count: n - first) }
        readIndex = (readIndex + n) % capacity
        count -= n
        return n
    }

    public func reset() {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        count = 0
        writeIndex = 0
    }
}
