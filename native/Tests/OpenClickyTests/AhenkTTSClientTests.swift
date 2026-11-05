//
//  AhenkTTSClientTests.swift
//  Runs the real server and model, so it is skipped where scripts/setup-ahenk
//  hasn't been run.
//

import XCTest
@testable import OpenClicky

final class AhenkTTSClientTests: XCTestCase {
    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky/ahenk", isDirectory: true)
    }

    private var serverScript: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/ahenk_tts_server.py")
    }

    private func makeClient(python: URL? = nil, timeout: TimeInterval = AhenkTTSClient.defaultTimeoutSeconds) throws -> AhenkTTSClient {
        let installed = root.appendingPathComponent("venv/bin/python")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: installed.path), "Ahenk not installed")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("ahenk-test-\(UUID().uuidString).log")
        return AhenkTTSClient(
            pythonURL: python ?? installed,
            serverScriptURL: serverScript,
            modelDirectoryURL: root.appendingPathComponent("model"),
            logFileURL: log,
            timeoutSeconds: timeout
        )
    }

    private func assertIsWAV(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF", file: file, line: line)
        XCTAssertGreaterThan(data.count, 10_000, file: file, line: line)
    }

    func testSynthesizesTurkishSpeechIncludingUnicodeText() async throws {
        let client = try makeClient()
        defer { client.shutdown() }
        assertIsWAV(try await client.synthesize("sağ üstteki simgeye tıkla, sonra şunu seç."))
    }

    func testConcurrentRequestsEachGetAResponse() async throws {
        let client = try makeClient()
        defer { client.shutdown() }
        async let first = client.synthesize("birinci cümle burada.")
        async let second = client.synthesize("ikinci cümle biraz daha uzun olacak.")
        let (a, b) = try await (first, second)
        assertIsWAV(a)
        assertIsWAV(b)
        XCTAssertNotEqual(a, b)
    }

    func testRestartsAfterProcessIsShutDown() async throws {
        let client = try makeClient()
        defer { client.shutdown() }
        assertIsWAV(try await client.synthesize("ilk istek."))
        client.shutdown()
        // Let the termination handler run so the next request starts afresh.
        try await Task.sleep(nanoseconds: 500_000_000)
        assertIsWAV(try await client.synthesize("yeniden başladıktan sonraki istek."))
    }

    func testMissingPythonThrowsInsteadOfHanging() async throws {
        let client = try makeClient(python: URL(fileURLWithPath: "/nonexistent/python"))
        do {
            _ = try await client.synthesize("merhaba")
            XCTFail("expected an error")
        } catch {}
    }

    func testProcessThatNeverAnswersTimesOut() async throws {
        let hanging = FileManager.default.temporaryDirectory.appendingPathComponent("hang-\(UUID().uuidString).sh")
        try "#!/bin/sh\nexec sleep 60\n".write(to: hanging, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hanging.path)
        defer { try? FileManager.default.removeItem(at: hanging) }

        let client = try makeClient(python: hanging, timeout: 1)
        defer { client.shutdown() }
        do {
            _ = try await client.synthesize("merhaba")
            XCTFail("expected a timeout")
        } catch {}
    }
}
