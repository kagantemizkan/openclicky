//
//  AhenkInstallerTests.swift
//  Runs small stand-in scripts, so nothing is downloaded.
//

import XCTest
@testable import OpenClicky

@MainActor
final class AhenkInstallerTests: XCTestCase {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ahenk-installer-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("timed out")
    }

    func testASuccessfulRunReportsInstalledAndFollowsTheSteps() async throws {
        let installer = AhenkInstaller(scriptURL: try script("""
        echo step:packages
        sleep 0.4
        echo step:model
        sleep 0.4
        """))
        var installed = 0
        installer.install { installed += 1 }
        try await waitUntil { installer.state == .running(.packages) }
        try await waitUntil { installer.state == .running(.model) }
        try await waitUntil { installed == 1 }
        XCTAssertEqual(installer.state, .idle)
    }

    func testAFailureShowsTheScriptsLastWordsAndCanBeRetried() async throws {
        let installer = AhenkInstaller(scriptURL: try script("echo step:packages; echo 'no space left' >&2; exit 3"))
        var installed = 0
        installer.install { installed += 1 }
        try await waitUntil {
            if case .failed = installer.state { return true }
            return false
        }
        XCTAssertEqual(installer.state, .failed("no space left"))
        XCTAssertEqual(installed, 0)
        XCTAssertFalse(installer.isRunning)
    }

    func testCancellingStopsItAndCountsAsNotInstalled() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("ahenk-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let installer = AhenkInstaller(scriptURL: try script("""
        echo step:model
        sleep 30
        touch "\(marker.path)"
        """))
        var installed = 0
        installer.install { installed += 1 }
        try await waitUntil { installer.state == .running(.model) }
        installer.cancel()
        try await waitUntil { installer.state == .idle }
        XCTAssertEqual(installed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAMissingScriptSaysSo() {
        let installer = AhenkInstaller(scriptURL: nil)
        installer.install {}
        XCTAssertEqual(installer.state, .failed(Strings.ahenkInstallMissingScript))
    }

    func testItOnlyGetsAMinimalEnvironment() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ahenk-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        setenv("OPENCLICKY_TEST_SECRET", "x", 1)
        defer { unsetenv("OPENCLICKY_TEST_SECRET") }
        let installer = AhenkInstaller(scriptURL: try script("env > \"\(output.path)\""))
        var installed = 0
        installer.install { installed += 1 }
        try await waitUntil { installed == 1 }
        let environment = try String(contentsOf: output, encoding: .utf8)
        XCTAssertFalse(environment.contains("OPENCLICKY_TEST_SECRET"))
        XCTAssertTrue(environment.contains("HOME="))
    }

    /// The real script, through the real class. Downloads, so only on request.
    func testLiveCancelThenInstall() async throws {
        let directory = ProcessInfo.processInfo.environment["OPENCLICKY_AHENK_LIVE_DIR"] ?? ""
        try XCTSkipIf(directory.isEmpty, "set OPENCLICKY_AHENK_LIVE_DIR to run")
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/setup-ahenk")
        let installer = AhenkInstaller(scriptURL: script, arguments: [directory])
        let files = FileManager.default

        var installed = 0
        installer.install { installed += 1 }
        try await waitUntil { installer.state == .running(.packages) }
        installer.cancel()
        try await waitUntil { installer.state == .idle }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(installed, 0)
        XCTAssertFalse(files.fileExists(atPath: "\(directory)/.install"))
        XCTAssertFalse(files.fileExists(atPath: "\(directory)/model/student.pt"))

        installer.install { installed += 1 }
        for _ in 0..<2400 where installed == 0 {
            if case .failed(let message) = installer.state { XCTFail(message); return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertEqual(installed, 1)
        XCTAssertEqual(installer.state, .idle)
        XCTAssertTrue(files.isExecutableFile(atPath: "\(directory)/venv/bin/python"))
        XCTAssertTrue(files.fileExists(atPath: "\(directory)/model/student.pt"))
        XCTAssertFalse(files.fileExists(atPath: "\(directory)/.install"))
    }
}
