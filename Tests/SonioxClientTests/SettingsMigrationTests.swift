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
        XCTAssertFalse(p.content.showSourceLabel, "System/Mic labels are opt-in")
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

final class SpeakerColorTests: XCTestCase {
    func testColourModes() {
        var a = AppearanceSettings()
        XCTAssertEqual(a.colorMode, .speaker, "speaker colours by default")
        XCTAssertEqual(a.color(isMic: false, speaker: "2"), a.speakerPalette[1])
        XCTAssertEqual(a.color(isMic: false, speaker: "7"), a.speakerPalette[0], "palette cycles")
        XCTAssertEqual(a.color(isMic: true, speaker: nil), a.meColor, "no diarization → source colour")
        a.colorMode = .source
        XCTAssertEqual(a.color(isMic: false, speaker: "2"), a.themColor)
        a.colorMode = .single
        XCTAssertEqual(a.color(isMic: true, speaker: "1"), a.textColor)
    }

    func testOldAppearanceDecodes() throws {
        // Saved before colour modes existed, with "colour by source" switched off.
        let enc = try JSONEncoder().encode(AppearanceSettings())
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: enc) as? [String: Any])
        obj.removeValue(forKey: "colorMode"); obj.removeValue(forKey: "speakerPalette"); obj["speakerColors"] = false
        let a = try JSONDecoder().decode(AppearanceSettings.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(a.colorMode, .single)
        XCTAssertFalse(a.speakerPalette.isEmpty)
    }
}

@MainActor
final class HotKeyBindingTests: XCTestCase {
    func testDefaultsDisplayAndOverrides() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SettingsStore(directory: dir, keychain: KeychainStore(service: "app.subveil.tests.\(UUID().uuidString)"))
        XCTAssertEqual(s.binding(.startStop).display, "⌥⌘Space")
        XCTAssertFalse(HotKeyBinding(keyCode: 0, modifiers: 0x200, key: "A").isUsable, "Shift alone would steal typing")
        s.hotkeys[HotKeyAction.clear.rawValue] = HotKeyBinding(keyCode: 40, modifiers: 0x1000 | 0x100, key: "K")
        XCTAssertEqual(s.binding(.clear).display, "⌃⌘K")
        XCTAssertEqual(Set(HotKeyAction.allCases.map { $0.defaultBinding }).count, HotKeyAction.allCases.count, "defaults don't collide")
    }
}
