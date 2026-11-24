import AppKit
import AppSettings
import SwiftUI
import Transcript
import XCTest
@testable import CaptionsCore
@testable import CatalogUI

/// Renders the Models & Providers window in a real (off-screen) AppKit window — Lists and Tables included.
/// Set SNAPSHOT_DIR to look at the PNGs.
@MainActor
final class CatalogSnapshotTests: XCTestCase {
    private func snapshot(_ view: some View, name: String, size: NSSize = NSSize(width: 1240, height: 800)) async throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded() }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    func testCatalogWindowRenders() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsStore(directory: dir, keychain: KeychainStore(service: "app.subveil.tests.\(UUID().uuidString)"))
        let engine = CaptionsEngine(settings: settings, store: TranscriptStore())
        for (tab, sel, name) in [(ModelCatalogView.Tab.browse, "whisperkit-large-v3-turbo", "catalog-local"),
                                 (.browse, "soniox", "catalog-cloud"),
                                 (.browse, "openai-translate", "catalog-planned"),
                                 (.compare, nil, "catalog-compare"),
                                 (.benchmark, nil, "catalog-benchmark")] {
            let rep = try await snapshot(ModelCatalogView(settings: settings, engine: engine, initialTab: tab, initialSelection: sel), name: name)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
        }
    }
}
