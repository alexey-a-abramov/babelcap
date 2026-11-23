import XCTest
@testable import AppSettings

@MainActor
final class SettingsMigrationTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("subveil-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testFreshInstallTranslatesEverythingToEnglishWithoutLabels() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SettingsStore(directory: dir, keychain: KeychainStore(service: "app.subveil.tests.\(UUID().uuidString)"))
        let p = s.profile
        XCTAssertEqual(p.translationSystem, TranslationSettings(kind: .oneWay, target: "en"))
        XCTAssertEqual(p.translationMic, TranslationSettings(kind: .oneWay, target: "en"))
        XCTAssertFalse(p.content.showSourceLabel, "Them/Me labels are opt-in")
        XCTAssertFalse(p.layout.clickThrough, "subtitle panel is draggable/resizable by default")
        XCTAssertTrue(s.showInDock)
        XCTAssertEqual(p.content.mode, .translation, "only the target language is shown by default")
    }

    func testOldSettingsFileIsMigratedAndStillDecodes() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kc = KeychainStore(service: "app.subveil.tests.\(UUID().uuidString)")

        // Write a file the way v1 did: no schemaVersion/showInDock, no layout.clickThrough, translation off, labels on.
        let seed = SettingsStore(directory: dir, keychain: kc)
        seed.profiles[0].name = "Default"
        seed.profiles[0].translationSystem = TranslationSettings(kind: .off)
        seed.profiles[0].translationMic = TranslationSettings(kind: .off)
        seed.profiles[0].content.showSourceLabel = true
        seed.profiles[0].content.mode = .both
        try await Task.sleep(for: .milliseconds(900)) // debounced save
        let url = dir.appendingPathComponent("settings.json")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        root.removeValue(forKey: "schemaVersion"); root.removeValue(forKey: "showInDock")
        var profiles = try XCTUnwrap(root["profiles"] as? [[String: Any]])
        var layout = try XCTUnwrap(profiles[0]["layout"] as? [String: Any])
        layout.removeValue(forKey: "clickThrough")
        profiles[0]["layout"] = layout
        root["profiles"] = profiles
        try JSONSerialization.data(withJSONObject: root).write(to: url)

        let s = SettingsStore(directory: dir, keychain: kc)
        XCTAssertEqual(s.profile.name, "Default (→ English)")
        XCTAssertEqual(s.profile.translationSystem.kind, .oneWay)
        XCTAssertEqual(s.profile.translationMic.target, "en")
        XCTAssertFalse(s.profile.content.showSourceLabel)
        XCTAssertFalse(s.profile.layout.clickThrough)
        XCTAssertEqual(s.profile.content.mode, .translation)
        XCTAssertTrue(s.onboardingDone == seed.onboardingDone, "other settings survive the migration")
    }

    func testSeparatePanelsOnlyForTwoSeparateStreams() {
        var p = Profile(name: "x")
        XCTAssertTrue(p.layout.separateSources, "split by default")
        p.sources = .system
        XCTAssertFalse(p.showsSeparatePanels)
        p.sources = .both
        XCTAssertTrue(p.showsSeparatePanels)
        p.session.mixIntoOne = true
        XCTAssertFalse(p.showsSeparatePanels, "a mixed stream has nothing to split")
        p.session.mixIntoOne = false
        p.layout.separateSources = false
        XCTAssertFalse(p.showsSeparatePanels)
    }

    func testLegacySplitModeDecodesAsCaptionsWithSeparatePanels() throws {
        let json = #"{"mode":"split","lines":3,"width":900,"alignment":"center","level":"statusBar","autoHideSeconds":0,"hideFromSharing":false,"showSubtitles":true}"#
        let l = try JSONDecoder().decode(LayoutSettings.self, from: Data(json.utf8))
        XCTAssertEqual(l.mode, .captions)
        XCTAssertTrue(l.separateSources)
    }
}
