//
//  ClaudeCLIRunnerTests.swift
//  Pure-logic tests for the CLI transport's flag assembly. The subprocess
//  itself is NOT spawned in these tests — we verify the argument vector
//  ClaudeCLIRunner.ask() would pass to `claude`. Pins the flag combo
//  against regression.
//

import XCTest
@testable import OpenClicky

final class ClaudeCLIRunnerTests: XCTestCase {
    private var runner: ClaudeCLIRunner!

    override func setUp() {
        super.setUp()
        // Binary URL is never dereferenced in buildArgs — a placeholder is fine.
        runner = ClaudeCLIRunner(binaryURL: URL(fileURLWithPath: "/usr/bin/true"))
    }

    override func tearDown() {
        runner = nil
        super.tearDown()
    }

    // MARK: - Always-present flags

    func testBuildArgsIncludesPrintAndVerbose() {
        let args = runner.buildArgs(systemPrompt: "x", model: "claude-sonnet-4-6", resumeSessionId: nil)
        XCTAssertTrue(args.contains("--print"), "--print is required for non-interactive use")
        XCTAssertTrue(args.contains("--verbose"), "--verbose is mandatory with --output-format stream-json + --print")
    }

    func testBuildArgsSelectsStreamJsonIOPair() {
        let args = runner.buildArgs(systemPrompt: "x", model: "sonnet", resumeSessionId: nil)
        XCTAssertTrue(flagValue(args, "--output-format") == "stream-json")
        XCTAssertTrue(flagValue(args, "--input-format") == "stream-json")
        XCTAssertTrue(args.contains("--include-partial-messages"), "token-level streaming needs this flag")
    }

    func testBuildArgsAppliesIsolationCombo() {
        let args = runner.buildArgs(systemPrompt: "x", model: "sonnet", resumeSessionId: nil)
        XCTAssertEqual(flagValue(args, "--setting-sources"), "", "must skip user/project/local settings")
        XCTAssertTrue(args.contains("--disable-slash-commands"))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertEqual(flagValue(args, "--mcp-config"), #"{"mcpServers":{}}"#)
        XCTAssertTrue(args.contains("--exclude-dynamic-system-prompt-sections"))
    }

    func testBuildArgsDisablesAllToolsWithoutBypassingPermissions() {
        let args = runner.buildArgs(systemPrompt: "x", model: "sonnet", resumeSessionId: nil)
        XCTAssertEqual(flagValue(args, "--tools"), "", "an empty allowlist disables every built-in tool")
        XCTAssertFalse(args.contains("--permission-mode"), "no tools means nothing to bypass")
        XCTAssertFalse(args.contains("--disallowedTools"))
    }

    // MARK: - Forbidden flags

    func testBuildArgsDoesNotContainBare() {
        // --bare forbids OAuth/keychain reads → would force an ANTHROPIC_API_KEY,
        // which breaks the whole project premise. Ensure it never sneaks back in.
        let args = runner.buildArgs(systemPrompt: "x", model: "sonnet", resumeSessionId: nil)
        XCTAssertFalse(args.contains("--bare"), "--bare breaks subscription auth; must never be present")
    }

    func testBuildArgsDoesNotContainNoSessionPersistence() {
        // --no-session-persistence conflicts with --resume (per CLI help:
        // "sessions will not be saved to disk and cannot be resumed").
        let args = runner.buildArgs(systemPrompt: "x", model: "sonnet", resumeSessionId: nil)
        XCTAssertFalse(args.contains("--no-session-persistence"),
                       "--no-session-persistence conflicts with --resume support")
    }

    // MARK: - System prompt and model passthrough

    func testBuildArgsPassesSystemPromptVerbatim() {
        let prompt = "you're openclicky. reply in one sentence."
        let args = runner.buildArgs(systemPrompt: prompt, model: "sonnet", resumeSessionId: nil)
        XCTAssertEqual(flagValue(args, "--system-prompt"), prompt)
    }

    func testBuildArgsPassesModelAlias() {
        let args = runner.buildArgs(systemPrompt: "x", model: "claude-opus-4-6", resumeSessionId: nil)
        XCTAssertEqual(flagValue(args, "--model"), "claude-opus-4-6")
    }

    // MARK: - Resume wiring

    func testBuildArgsOmitsResumeWhenSessionIdIsNil() {
        let args = runner.buildArgs(systemPrompt: "x", model: "sonnet", resumeSessionId: nil)
        XCTAssertFalse(args.contains("--resume"))
    }

    func testBuildArgsIncludesResumeWhenSessionIdIsSet() {
        let sid = "359641a7-9bb1-4791-9f9f-7385c43303d3"
        let args = runner.buildArgs(systemPrompt: "x", model: "sonnet", resumeSessionId: sid)
        XCTAssertEqual(flagValue(args, "--resume"), sid)
    }

    // MARK: - Helpers

    private func flagValue(_ args: [String], _ name: String) -> String? {
        guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}
