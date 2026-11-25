import AppSettings
import Foundation
import SonioxClient
import XCTest

/// The rename Subveil → Babelcap must keep settings, downloaded models and window frames.
final class LegacyMigrationTests: XCTestCase {
    func testFolderMovesAndModelManifestsAreRenamed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("babelcap-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Subveil"), new = root.appendingPathComponent("Babelcap")
        let model = old.appendingPathComponent("Models/whisperkit-tiny")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: model.appendingPathComponent("subveil-model.json"))
        try Data("{\"a\":1}".utf8).write(to: old.appendingPathComponent("settings.json"))

        XCTAssertTrue(LegacyMigration.moveFolder(from: old, to: new))
        LegacyMigration.renameModelManifests(in: new.appendingPathComponent("Models"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("settings.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("Models/whisperkit-tiny/babelcap-model.json").path))
        XCTAssertFalse(LegacyMigration.moveFolder(from: old, to: new), "second run is a no-op")
    }

    func testExistingNewFolderIsNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("babelcap-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Subveil"), new = root.appendingPathComponent("Babelcap")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: new.appendingPathComponent("settings.json"))
        XCTAssertFalse(LegacyMigration.moveFolder(from: old, to: new))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testEmptyFoldersUnderTheNewNameDoNotBlockTheMove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("babelcap-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Subveil"), new = root.appendingPathComponent("Babelcap")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: old.appendingPathComponent("settings.json"))
        try FileManager.default.createDirectory(at: new.appendingPathComponent("Models"), withIntermediateDirectories: true)
        XCTAssertTrue(LegacyMigration.moveFolder(from: old, to: new))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("settings.json").path))
    }

    func testPreferencesAreCopiedWithNewKeyNames() throws {
        let oldSuite = "babelcap.tests.old.\(UUID().uuidString)", newSuite = "babelcap.tests.new.\(UUID().uuidString)"
        let old = try XCTUnwrap(UserDefaults(suiteName: oldSuite)), new = try XCTUnwrap(UserDefaults(suiteName: newSuite))
        defer { old.removePersistentDomain(forName: oldSuite); new.removePersistentDomain(forName: newSuite) }
        old.set("{{1, 2}, {3, 4}}", forKey: "SubveilCaption.main.frame")
        old.set("kept", forKey: "NSWindow Frame SubveilHUD")
        new.set("mine", forKey: "NSWindow Frame BabelcapHUD")

        LegacyMigration.copyDefaults(from: old, to: new)

        XCTAssertEqual(new.string(forKey: "BabelcapCaption.main.frame"), "{{1, 2}, {3, 4}}")
        XCTAssertEqual(new.string(forKey: "NSWindow Frame BabelcapHUD"), "mine", "existing keys win")
    }

    func testKeychainServicesKeepTheirProviderSuffix() {
        XCTAssertEqual(KeychainStore.standard.service, "app.babelcap.soniox")
        XCTAssertEqual(KeychainStore.forProvider("gladia").service, "app.babelcap.gladia")
    }
}
