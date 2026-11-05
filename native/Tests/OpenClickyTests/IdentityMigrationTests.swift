//
//  IdentityMigrationTests.swift
//

import XCTest
@testable import OpenClicky

final class IdentityMigrationTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "openclicky-identity-\(UUID().uuidString)")!
    }

    func testSettingsMoveToTheNewIdentifier() {
        let defaults = freshDefaults()
        IdentityMigration.moveSettings(
            ["com.proyecto26.openclicky.cursorSize": 1.5, "plainKey": "kept"],
            into: defaults
        )
        XCTAssertEqual(defaults.double(forKey: "com.kagantemizkan.openclicky.cursorSize"), 1.5)
        XCTAssertEqual(defaults.string(forKey: "plainKey"), "kept")
        XCTAssertNil(defaults.object(forKey: "com.proyecto26.openclicky.cursorSize"))
    }

    func testANewerSettingIsNotOverwritten() {
        let defaults = freshDefaults()
        defaults.set(2.0, forKey: "com.kagantemizkan.openclicky.cursorSize")
        IdentityMigration.moveSettings(["com.proyecto26.openclicky.cursorSize": 1.5], into: defaults)
        XCTAssertEqual(defaults.double(forKey: "com.kagantemizkan.openclicky.cursorSize"), 2.0)
    }

    func testItOnlyRunsOnce() {
        let defaults = freshDefaults()
        var keychainMoves = 0
        let old = ["com.proyecto26.openclicky.cursorSize": 1.5]
        IdentityMigration.run(defaults: defaults, oldSettings: old) { keychainMoves += 1 }
        XCTAssertTrue(defaults.bool(forKey: IdentityMigration.doneKey))
        XCTAssertEqual(defaults.double(forKey: "com.kagantemizkan.openclicky.cursorSize"), 1.5)

        defaults.set(3.0, forKey: "com.kagantemizkan.openclicky.cursorSize")
        IdentityMigration.run(defaults: defaults, oldSettings: old) { keychainMoves += 1 }
        XCTAssertEqual(defaults.double(forKey: "com.kagantemizkan.openclicky.cursorSize"), 3.0)
        XCTAssertEqual(keychainMoves, 1)
    }

    func testKeychainItemMovesAndTheOldOneGoes() throws {
        let old = "openclicky-test-old-\(UUID().uuidString)"
        let new = "openclicky-test-new-\(UUID().uuidString)"
        defer {
            KeychainStorage.delete(service: old, account: "a")
            KeychainStorage.delete(service: new, account: "a")
        }
        try XCTSkipUnless(KeychainStorage.write(service: old, account: "a", value: "value"), "no keychain here")
        IdentityMigration.moveKeychainItem(from: old, to: new, account: "a")
        XCTAssertEqual(KeychainStorage.read(service: new, account: "a"), "value")
        XCTAssertNil(KeychainStorage.read(service: old, account: "a"))
    }

    func testAnExistingKeychainItemIsKept() throws {
        let old = "openclicky-test-old-\(UUID().uuidString)"
        let new = "openclicky-test-new-\(UUID().uuidString)"
        defer {
            KeychainStorage.delete(service: old, account: "a")
            KeychainStorage.delete(service: new, account: "a")
        }
        try XCTSkipUnless(KeychainStorage.write(service: old, account: "a", value: "stale"), "no keychain here")
        KeychainStorage.write(service: new, account: "a", value: "current")
        IdentityMigration.moveKeychainItem(from: old, to: new, account: "a")
        XCTAssertEqual(KeychainStorage.read(service: new, account: "a"), "current")
    }
}
