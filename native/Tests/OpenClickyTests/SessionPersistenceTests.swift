//
//  SessionPersistenceTests.swift
//  Round-trip the session file at its real path (per-user Application
//  Support). The load()/save()/clear() API promises to never throw, so
//  the tests also cover malformed-file tolerance.
//

import XCTest
@testable import OpenClicky

final class SessionPersistenceTests: XCTestCase {
    private var persistence: SessionPersistence!
    private var savedFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("last-session.json", isDirectory: false)
    }

    override func setUp() {
        super.setUp()
        persistence = SessionPersistence.shared
        persistence.clear()
    }

    override func tearDown() {
        persistence.clear()
        persistence = nil
        super.tearDown()
    }

    func testFreshnessWindow() {
        let now = Date()
        let stamp = { (age: TimeInterval) in ISO8601DateFormatter().string(from: now.addingTimeInterval(-age)) }
        XCTAssertTrue(SessionPersistence.isFresh(updatedAt: stamp(60), now: now))
        XCTAssertFalse(SessionPersistence.isFresh(updatedAt: stamp(SessionPersistence.maxIdleSeconds + 60), now: now))
        XCTAssertFalse(SessionPersistence.isFresh(updatedAt: nil, now: now))
        XCTAssertFalse(SessionPersistence.isFresh(updatedAt: "not a date", now: now))
    }

    func testLoadReturnsNilWhenFileIsMissing() {
        XCTAssertNil(persistence.load())
    }

    func testSaveThenLoadRoundTrip() {
        let sid = "cafe-babe-1234-abcd"
        persistence.save(sessionId: sid)
        XCTAssertEqual(persistence.load(), sid)
    }

    func testSaveOverwritesPriorValue() {
        persistence.save(sessionId: "first")
        persistence.save(sessionId: "second")
        XCTAssertEqual(persistence.load(), "second")
    }

    func testSaveIgnoresEmptyString() {
        persistence.save(sessionId: "seed")
        persistence.save(sessionId: "")
        // The empty save is a no-op; "seed" remains.
        XCTAssertEqual(persistence.load(), "seed")
    }

    func testClearRemovesFile() {
        persistence.save(sessionId: "deleteme")
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedFileURL.path))
        persistence.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedFileURL.path))
        XCTAssertNil(persistence.load())
    }

    func testLoadTolleratesMalformedJson() throws {
        // Write garbage where the session file lives.
        try FileManager.default.createDirectory(
            at: savedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not-json-at-all".data(using: .utf8)?.write(to: savedFileURL)

        // load() must return nil (not throw, not crash).
        XCTAssertNil(persistence.load())
    }

    func testLoadTolleratesJsonWithoutSessionIdField() throws {
        try FileManager.default.createDirectory(
            at: savedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload: [String: Any] = ["version": 1, "notes": "no sessionId here"]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: savedFileURL)

        XCTAssertNil(persistence.load())
    }
}
