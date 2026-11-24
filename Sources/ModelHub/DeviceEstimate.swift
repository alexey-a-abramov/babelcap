import Foundation
import IOKit

/// Rough "how fast would this be on another Mac" from a measurement on this one.
///
/// Whisper on Apple Silicon runs on the GPU here, so throughput scales mostly with GPU size and generation. The score is
/// GPU cores × a per-generation factor; the ratio is tempered (^0.85) because small models and the decoding loop
/// do not scale linearly. It is an estimate for orientation, not a measurement.
public enum DeviceEstimate {
    public struct Mac: Identifiable, Sendable, Hashable {
        public let name: String
        public let generation: Int
        public let gpuCores: Int
        public var id: String { name }
    }

    /// Per-core GPU throughput relative to M1 (approximate, ML-heavy workloads).
    static let generationFactor: [Int: Double] = [1: 1.0, 2: 1.15, 3: 1.35, 4: 1.55, 5: 1.9]

    public static let laptops: [Mac] = [
        Mac(name: "MacBook Air M1 (8-core GPU)", generation: 1, gpuCores: 8),
        Mac(name: "MacBook Air M2 (10-core GPU)", generation: 2, gpuCores: 10),
        Mac(name: "MacBook Pro M3 Pro (18-core GPU)", generation: 3, gpuCores: 18),
        Mac(name: "MacBook Air M4 (10-core GPU)", generation: 4, gpuCores: 10),
        Mac(name: "MacBook Pro M4 Pro (20-core GPU)", generation: 4, gpuCores: 20),
        Mac(name: "MacBook Pro M4 Max (40-core GPU)", generation: 4, gpuCores: 40),
        Mac(name: "MacBook Pro M5 (10-core GPU)", generation: 5, gpuCores: 10),
    ]

    static func score(generation: Int, cores: Int) -> Double { (generationFactor[generation] ?? 1) * Double(cores) }

    /// This Mac: chip generation from the brand string ("Apple M5 Max"), GPU cores from IOKit.
    public static var thisMac: Mac? {
        let chip = MachineInfo.chip
        guard let r = chip.range(of: #"M(\d)"#, options: .regularExpression),
              let gen = Int(chip[r].dropFirst()), let cores = gpuCores else { return nil }
        return Mac(name: "This Mac (\(chip), \(cores)-core GPU)", generation: gen, gpuCores: cores)
    }

    public static var gpuCores: Int? {
        let matching = IOServiceMatching("AGXAccelerator")
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            if let v = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int { return v }
        }
        return nil
    }

    /// Estimated real-time factor (processing ÷ audio) on `mac`, from one measured here.
    public static func rtf(_ measured: Double, on mac: Mac) -> Double? {
        guard let here = thisMac else { return nil }
        let ratio = score(generation: here.generation, cores: here.gpuCores) / score(generation: mac.generation, cores: mac.gpuCores)
        return measured * pow(ratio, 0.85)
    }

    public static func speedText(_ rtf: Double) -> String { rtf > 0 ? String(format: "%.1f×", 1 / rtf) : "—" }

    public static func verdict(_ rtf: Double) -> String {
        switch rtf { case ..<0.4: "comfortable"; case ..<0.8: "OK"; case ..<1.0: "borderline"; default: "too slow" }
    }
}
