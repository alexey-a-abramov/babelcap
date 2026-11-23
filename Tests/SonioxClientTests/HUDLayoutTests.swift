import AppKit
import AppSettings
import SwiftUI
import Transcript
import XCTest
@testable import CaptionsCore
@testable import ControlHUD

/// Renders HUD pieces off-screen. Guards against labels wrapping ("Syst em") and the header overflowing.
/// Set SNAPSHOT_DIR to also write PNGs for a visual check.
@MainActor
final class HUDLayoutTests: XCTestCase {
    private func render<V: View>(_ v: V, name: String) -> CGSize {
        let r = ImageRenderer(content: v.environment(\.colorScheme, .dark).background(Color(white: 0.15)))
        r.scale = 2
        guard let img = r.cgImage else { XCTFail("render failed"); return .zero }
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return CGSize(width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2)
    }

    func testSourcePickerLabelsStayOnOneLine() {
        for running in [false, true] {
            for sel in SourceMode.allCases {
                let size = render(SourcePicker(selection: sel, system: 0.6, mic: 0.3, running: running) { _ in },
                                  name: "picker-\(sel.rawValue)-\(running)")
                XCTAssertLessThanOrEqual(size.height, 40, "picker wrapped its labels (\(sel), running \(running))")
                XCTAssertLessThanOrEqual(size.width, 260, "picker too wide")
            }
        }
    }

    func testStatusBadgeStates() {
        XCTAssertLessThanOrEqual(render(StatusBadge(state: .idle, runState: .idle, elapsed: 0), name: "status-idle").width, 30)
        XCTAssertLessThanOrEqual(render(StatusBadge(state: .live, runState: .running, elapsed: 3725), name: "status-live").width, 80)
        _ = render(StatusBadge(state: .live, runState: .paused, elapsed: 65), name: "status-paused")
        _ = render(StatusBadge(state: .error("x"), runState: .running, elapsed: 5), name: "status-error")
    }

    func testIdleHeaderFitsThePanelWidth() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsStore(directory: dir, keychain: KeychainStore(service: "app.subveil.tests.\(UUID().uuidString)"))
        let store = TranscriptStore()
        let engine = CaptionsEngine(settings: settings, store: store)
        let view = ControlView(settings: settings, engine: engine, store: store, hud: HUDState(), overlay: ControlOverlayInfo(),
                               actions: HUDActions(openSettings: {}, toggleEditing: {}, export: { _ in }, hidePanel: {}, quit: {}))
        let size = render(view.frame(width: ControlPanelController.normal.width, height: 56), name: "hud-idle")
        XCTAssertEqual(size.width, ControlPanelController.normal.width)
        let natural = render(view.fixedSize(), name: "hud-natural")
        XCTAssertLessThanOrEqual(natural.width, ControlPanelController.normal.width, "header content wider than the HUD panel")
    }
}
