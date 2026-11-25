import AppKit
import AppSettings
import XCTest
@testable import Overlay
@testable import Transcript

@MainActor
final class OverlayPanelTests: XCTestCase {
    func testSplitAndMergeRestoreEachPanelExactlyAndSplitChoiceIsPerSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ovl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for k in ["main", "system", "mic"] { UserDefaults.standard.removeObject(forKey: OverlayController.defaultsKey(k)) }

        let settings = SettingsStore(directory: dir, keychain: KeychainStore(service: "app.babelcap.tests.\(UUID().uuidString)"))
        settings.profile.sources = .both
        let overlay = OverlayController(store: TranscriptStore(), settings: settings)
        overlay.start()
        overlay.isActive = true
        XCTAssertEqual(Set(overlay.panelFrames.keys), ["system", "mic"], "Both mode starts with two panels")

        func place(_ key: String, _ r: NSRect) {
            let p = try! XCTUnwrap(overlay.panelForTesting(key))
            p.setFrame(r, display: false)   // saved by the controller's move/resize observers
        }
        let sys = NSRect(x: 100, y: 120, width: 500, height: 150)
        let mic = NSRect(x: 900, y: 400, width: 420, height: 130)
        place("system", sys); place("mic", mic)

        overlay.state.onToggleSplit?()                       // merge
        XCTAssertEqual(Set(overlay.panelFrames.keys), ["main"])
        let main = NSRect(x: 300, y: 600, width: 1000, height: 200)
        place("main", main)

        overlay.state.onToggleSplit?()                       // split again
        XCTAssertEqual(overlay.panelFrames["system"], sys, "System panel is back exactly where it was")
        XCTAssertEqual(overlay.panelFrames["mic"], mic, "Mic panel is back exactly where it was")

        overlay.state.onToggleSplit?()                       // merge again
        XCTAssertEqual(overlay.panelFrames["main"], main, "the combined panel is back where it was")

        // Merge was a toolbar choice: the next session starts from the default (two panels) again.
        overlay.isActive = false
        overlay.isActive = true
        XCTAssertEqual(Set(overlay.panelFrames.keys), ["system", "mic"])
        XCTAssertEqual(overlay.panelFrames["system"], sys)
        XCTAssertTrue(settings.profile.layout.separateSources, "the toolbar choice is not persisted")
    }
}
