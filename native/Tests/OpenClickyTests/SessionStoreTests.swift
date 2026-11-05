//
//  SessionStoreTests.swift
//  Sessions, token counting and the cursor's pure logic. Uses a temporary
//  file, so running the tests never touches the user's real sessions.
//

import XCTest
@testable import OpenClicky

@MainActor
final class SessionStoreTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    private func store() -> SessionStore { SessionStore(fileURL: file) }

    func testStartsWithOneEmptySession() {
        let sessions = store()
        XCTAssertEqual(sessions.sessions.count, 1)
        XCTAssertTrue(sessions.active.isEmpty)
        XCTAssertNil(sessions.resumeIdForNextTurn())
    }

    func testRecordingATurnAddsUsageAndKeepsLastContextSize() {
        let sessions = store()
        sessions.recordTurn(claudeSessionId: "a", usage: TokenUsage(input: 10, cacheWrite: 100, cacheRead: 0, output: 5), prompt: "first")
        sessions.recordTurn(claudeSessionId: "b", usage: TokenUsage(input: 2, cacheWrite: 50, cacheRead: 110, output: 7), prompt: "second")
        let active = sessions.active
        XCTAssertEqual(active.turns, 2)
        XCTAssertEqual(active.usage.total, 174, "cache reads must not inflate the total")
        XCTAssertEqual(active.usage.cacheRead, 110)
        XCTAssertEqual(active.lastContextTokens, 162)
        XCTAssertEqual(active.claudeSessionId, "b", "the latest CLI session id is the one to resume")
    }

    func testFirstQuestionNamesAnUnnamedSession() {
        let sessions = store()
        sessions.recordTurn(claudeSessionId: "a", usage: nil, prompt: "vinyet  efekti\nnasıl eklerim")
        XCTAssertEqual(sessions.active.name, "vinyet efekti nasıl eklerim")
        sessions.recordTurn(claudeSessionId: "a", usage: nil, prompt: "başka bir soru")
        XCTAssertEqual(sessions.active.name, "vinyet efekti nasıl eklerim")
    }

    func testAutomaticLooksAndUserNamesKeepTheName() {
        let sessions = store()
        let original = sessions.active.name
        sessions.recordTurn(claudeSessionId: "a", usage: nil, prompt: nil)
        XCTAssertEqual(sessions.active.name, original)

        let named = sessions.startNew(name: "Affinity")
        sessions.recordTurn(claudeSessionId: "b", usage: nil, prompt: "soru")
        XCTAssertEqual(sessions.active.id, named.id)
        XCTAssertEqual(sessions.active.name, "Affinity")
    }

    func testLongQuestionsAreShortenedForTheName() {
        let sessions = store()
        sessions.recordTurn(claudeSessionId: "a", usage: nil, prompt: String(repeating: "uzun ", count: 40))
        XCTAssertLessThanOrEqual(sessions.active.name.count, 41)
        XCTAssertTrue(sessions.active.name.hasSuffix("…"))
    }

    func testStaleUnnamedSessionStartsOverButKeepsItsRecord() {
        let sessions = store()
        let start = Date()
        sessions.recordTurn(claudeSessionId: "old", usage: nil, prompt: "soru", now: start)
        let fresh = start.addingTimeInterval(SessionStore.maxIdleSeconds - 60)
        XCTAssertEqual(sessions.resumeIdForNextTurn(now: fresh), "old")

        let stale = start.addingTimeInterval(SessionStore.maxIdleSeconds + 60)
        XCTAssertNil(sessions.resumeIdForNextTurn(now: stale))
        XCTAssertEqual(sessions.sessions.count, 2)
        XCTAssertTrue(sessions.active.isEmpty)
    }

    func testNamedSessionResumesHoweverOld() {
        let sessions = store()
        let start = Date()
        sessions.recordTurn(claudeSessionId: "old", usage: nil, prompt: "soru", now: start)
        sessions.rename(sessions.activeId, to: "Affinity")
        let later = start.addingTimeInterval(SessionStore.maxIdleSeconds * 10)
        XCTAssertEqual(sessions.resumeIdForNextTurn(now: later), "old")
    }

    func testNewSessionReusesAnEmptyOne() {
        let sessions = store()
        sessions.startNew()
        sessions.startNew()
        XCTAssertEqual(sessions.sessions.count, 1)
    }

    func testSwitchingAndDeleting() {
        let sessions = store()
        sessions.recordTurn(claudeSessionId: "a", usage: nil, prompt: "bir")
        let first = sessions.activeId
        sessions.startNew(name: "iki")
        let second = sessions.activeId
        XCTAssertNotEqual(first, second)
        sessions.activate(first)
        XCTAssertEqual(sessions.resumeIdForNextTurn(), "a")

        sessions.delete(first)
        XCTAssertEqual(sessions.activeId, second)
        sessions.delete(second)
        XCTAssertEqual(sessions.sessions.count, 1, "there is always a session to talk in")
    }

    func testBlankRenameIsIgnored() {
        let sessions = store()
        let original = sessions.active.name
        sessions.rename(sessions.activeId, to: "   ")
        XCTAssertEqual(sessions.active.name, original)
        XCTAssertFalse(sessions.active.isNamedByUser)
    }

    func testSurvivesARestart() {
        let sessions = store()
        sessions.recordTurn(claudeSessionId: "a", usage: TokenUsage(input: 1, cacheWrite: 2, cacheRead: 3, output: 4), prompt: "soru")
        sessions.rename(sessions.activeId, to: "Kalıcı")
        let reloaded = store()
        XCTAssertEqual(reloaded.active.name, "Kalıcı")
        XCTAssertEqual(reloaded.active.usage.total, 7)
        XCTAssertEqual(reloaded.resumeIdForNextTurn(), "a")
    }

    func testMalformedFileStartsClean() throws {
        try Data("not json".utf8).write(to: file)
        XCTAssertTrue(store().active.isEmpty)
    }

    func testForgettingAClaudeSessionStartsTheConversationOver() {
        let sessions = store()
        sessions.recordTurn(claudeSessionId: "gone", usage: nil, prompt: "soru")
        sessions.forgetClaudeSession()
        XCTAssertNil(sessions.resumeIdForNextTurn())
    }

    // MARK: - Token parsing, from the real CLI's stream

    private func parsed(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testReadsUsageFromMessageStart() throws {
        let line = try parsed(#"{"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":766,"cache_read_input_tokens":0,"output_tokens":1}}}}"#)
        XCTAssertEqual(TokenUsage(streamLine: line), TokenUsage(input: 2, cacheWrite: 766, cacheRead: 0, output: 1))
    }

    func testReadsFinalUsageFromMessageDelta() throws {
        let line = try parsed(#"{"type":"stream_event","event":{"type":"message_delta","usage":{"input_tokens":2,"cache_creation_input_tokens":766,"cache_read_input_tokens":9,"output_tokens":5}}}"#)
        XCTAssertEqual(TokenUsage(streamLine: line), TokenUsage(input: 2, cacheWrite: 766, cacheRead: 9, output: 5))
    }

    func testOtherLinesCarryNoUsage() throws {
        XCTAssertNil(TokenUsage(streamLine: try parsed(#"{"type":"stream_event","event":{"type":"content_block_delta"}}"#)))
        XCTAssertNil(TokenUsage(streamLine: try parsed(#"{"type":"system","subtype":"init"}"#)))
    }

    /// Real tokens from the real CLI, across a resume, through to the store.
    /// Uses the Claude plan, so it runs only when asked for.
    func testLiveTurnsRecordRealTokens() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["OPENCLICKY_LIVE_TOKENS"] == nil, "set OPENCLICKY_LIVE_TOKENS to run")
        let runner = ClaudeCLIRunner(binaryURL: try ClaudeCLIRunner.locate())
        let sessions = store()

        for question in ["bir kelimeyle merhaba de", "şimdi iki kelimeyle tekrar de"] {
            let result = try await runner.ask(
                messages: [ClaudeCLIMessage(role: .user, text: question)],
                systemPrompt: "be brief",
                model: ClaudeModel.sonnet.rawValue,
                resumeSessionId: sessions.resumeIdForNextTurn()
            ) { _ in }
            print("LIVE \(result.sessionId ?? "nil") \(String(describing: result.usage))")
            XCTAssertGreaterThan(result.usage?.output ?? 0, 0)
            sessions.recordTurn(claudeSessionId: result.sessionId, usage: result.usage, prompt: question)
        }

        XCTAssertEqual(sessions.active.turns, 2)
        XCTAssertGreaterThan(sessions.active.usage.total, 0)
        XCTAssertGreaterThan(sessions.active.lastContextTokens, 0)
        XCTAssertEqual(sessions.active.name, "bir kelimeyle merhaba de")
    }

    // MARK: - Cursor

    func testCaptionFollowsState() {
        XCTAssertEqual(CursorCaption.resolve(state: .idle, reply: "", label: nil, transcript: ""), .none)
        XCTAssertEqual(CursorCaption.resolve(state: .idle, reply: "", label: "Vinyet", transcript: ""), .text("Vinyet"))
        XCTAssertEqual(CursorCaption.resolve(state: .listening, reply: "eski", label: "Vinyet", transcript: "merhaba"), .listening(transcript: "merhaba"))
        XCTAssertEqual(CursorCaption.resolve(state: .thinking, reply: "", label: "Vinyet", transcript: ""), .thinking)
        XCTAssertEqual(CursorCaption.resolve(state: .thinking, reply: "yanıt", label: nil, transcript: ""), .text("yanıt"))
        XCTAssertEqual(CursorCaption.resolve(state: .speaking, reply: "yanıt", label: "Vinyet", transcript: ""), .text("yanıt"))
    }

    func testFlightStartsAndEndsExactlyAndArcsUpwards() {
        let start = CGPoint(x: 100, y: 100), end = CGPoint(x: 700, y: 100)
        XCTAssertEqual(CursorFlight.position(at: 0, from: start, to: end), start)
        XCTAssertEqual(CursorFlight.position(at: 1, from: start, to: end), end)
        XCTAssertEqual(CursorFlight.position(at: 2, from: start, to: end), end)
        XCTAssertGreaterThan(CursorFlight.position(at: 0.5, from: start, to: end).y, 100)
    }
}
