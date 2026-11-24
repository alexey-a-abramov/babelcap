import Foundation
import ModelHub
import SonioxClient

// subveil-bench — download catalog models and test them on the bundled clips, from the terminal.
//
//   swift run subveil-bench list
//   swift run subveil-bench download <id> [<id> …]
//   swift run subveil-bench test <id>|ready [--clip en|ru|…|all] [--target en]
//
// Soniox key: $SONIOX_API_KEY or ~/.config/subveil/soniox_api_key. Models go to the app's own folder.

func usage() -> Never {
    print("""
    usage: subveil-bench list
           subveil-bench download <id> [<id> …]
           subveil-bench test <id>|ready [--clip <id>|all] [--target <lang>]
    """)
    exit(2)
}

func sonioxKey() -> String? {
    if let k = ProcessInfo.processInfo.environment["SONIOX_API_KEY"], !k.isEmpty { return k }
    let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/subveil/soniox_api_key")
    return (try? String(contentsOf: f, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
Trace.fileEnabled = ProcessInfo.processInfo.environment["SUBVEIL_TRACE"] != nil

switch cmd {
case "list":
    print("Machine: \(MachineInfo.chip), \(MachineInfo.ramGB) GB RAM, macOS \(MachineInfo.macOSMajor), \(ModelStorage.freeDiskBytes.humanBytes) free")
    print("Models folder: \(ModelStorage.root.path)\n")
    let dl = ModelDownloads.shared
    for e in ModelCatalog.all {
        let state = e.isReady ? (e.needsDownload ? (dl.isInstalled(e.id) ? "installed" : "ready · download") : "ready") : "catalog only"
        let size = e.needsDownload ? e.downloadBytes.humanBytes : (e.priceText ?? "")
        print("\(pad(e.id, 36)) \(pad(e.kind.rawValue, 6)) \(pad(state, 18)) \(size)")
    }

case "download":
    let ids = Array(args.dropFirst())
    guard !ids.isEmpty else { usage() }
    let dl = ModelDownloads.shared
    for id in ids {
        guard let e = ModelCatalog.entry(id), e.needsDownload else { print("unknown or not downloadable: \(id)"); continue }
        print("⬇︎ \(e.name) → \(ModelStorage.folder(for: id).path)")
        dl.start(e)
        var last = Date.distantPast
        while true {
            try? await Task.sleep(for: .milliseconds(250))
            let s = dl.status(id)
            if Date().timeIntervalSince(last) > 2 || s.phase == .installed {
                last = Date()
                let speed = s.bytesPerSecond > 0 ? " \(Int64(s.bytesPerSecond).humanBytes)/s" : ""
                print("   \(s.phase) \(String(format: "%5.1f", s.fraction * 100))%  \(s.received.humanBytes) / \(s.total.humanBytes)\(speed)  \(s.currentFile)")
            }
            if s.phase == .installed { print("✓ \(id) installed (\(ModelStorage.sizeOnDisk(id).humanBytes) on disk)"); break }
            if case let .failed(msg) = s.phase { print("✗ \(id): \(msg)"); break }
        }
    }

case "test":
    guard args.count >= 2 else { usage() }
    var clipArg = "all", target: String? = "en"
    var i = 2
    while i < args.count {
        if args[i] == "--clip", i + 1 < args.count { clipArg = args[i + 1]; i += 2 }
        else if args[i] == "--target", i + 1 < args.count { target = args[i + 1] == "none" ? nil : args[i + 1]; i += 2 }
        else { i += 1 }
    }
    let key = sonioxKey()
    let entries: [CatalogEntry] = args[1] == "ready"
        ? ModelCatalog.all.filter { EngineFactory.problem(for: $0, apiKey: key) == nil }
        : [ModelCatalog.entry(args[1])].compactMap { $0 }
    let clips = BenchmarkClips.all().filter { clipArg == "all" || $0.id == clipArg }
    guard !entries.isEmpty, !clips.isEmpty else { print("nothing to test (entries \(entries.count), clips \(clips.count))"); exit(1) }

    print("\(pad("engine", 34)) \(pad("clip", 4)) \(pad("WER", 6)) \(pad("speed", 44)) verdict")
    for e in entries {
        if let p = EngineFactory.problem(for: e, apiKey: key) { print("\(pad(e.id, 34)) skipped: \(p)"); continue }
        for c in clips {
            let r = await BenchmarkRunner.run(entry: e, clip: c, target: target, apiKey: key)
            let wer = r.wer.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
            print("\(pad(e.id, 34)) \(pad(c.id, 4)) \(pad(wer, 6)) \(pad(r.speedText, 44)) \(r.verdict.title)\(r.error.map { " — \($0)" } ?? "")")
            print("      heard: \(r.transcript.prefix(160))")
            if !r.translation.isEmpty { print("      → \(r.targetLanguage ?? ""): \(r.translation.prefix(160))") }
            if let w = r.warning { print("      ⚠︎ \(w)") }
            if let rtf = r.rtf, r.error == nil {
                let est = DeviceEstimate.laptops.compactMap { m in DeviceEstimate.rtf(rtf, on: m).map { "\(m.name.replacingOccurrences(of: "MacBook ", with: "")) \(DeviceEstimate.speedText($0))" } }
                print("      ≈ on laptops: " + est.joined(separator: " · "))
            }
        }
    }

default:
    usage()
}
