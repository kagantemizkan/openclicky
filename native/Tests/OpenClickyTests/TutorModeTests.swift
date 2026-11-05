//
//  TutorModeTests.swift
//  Reply parsing, plus an optional check of how the real model follows the
//  tutor prompts. The live test uses the Claude plan, so it runs only when
//  OPENCLICKY_LIVE_SCREEN points at a screenshot JPEG.
//

import XCTest
@testable import OpenClicky

final class TutorModeTests: XCTestCase {
    func testPlainReplyHasNoSignals() {
        let reply = TutorMode.parse("şuraya tıkla. [POINT:10,20:kaydet]")
        XCTAssertEqual(reply.text, "şuraya tıkla. [POINT:10,20:kaydet]")
        XCTAssertFalse(reply.shouldWait || reply.shouldStart || reply.isFinished)
    }

    func testWaitLeavesNothingToSay() {
        let reply = TutorMode.parse("[WAIT]")
        XCTAssertTrue(reply.shouldWait)
        XCTAssertEqual(reply.text, "")
    }

    func testSignalBeforeAPointTagKeepsTheTagParseable() {
        let reply = TutorMode.parse("ilk adım bu. [TUTOR] [POINT:10,20:menü]")
        XCTAssertTrue(reply.shouldStart)
        let parsed = PointTagParser.parse(reply.text)
        XCTAssertEqual(parsed.spokenText, "ilk adım bu.")
        XCTAssertEqual(parsed.point?.label, "menü")
    }

    func testSignalAfterAPointTagKeepsTheTagParseable() {
        let reply = TutorMode.parse("son adım. [POINT:10,20:menü] [DONE]")
        XCTAssertTrue(reply.isFinished)
        XCTAssertEqual(PointTagParser.parse(reply.text).point?.x, 10)
    }

    func testDisplayTextHidesTagsEvenWhenPartial() {
        XCTAssertEqual(TutorMode.displayText("[WA"), "")
        XCTAssertEqual(TutorMode.displayText("buraya tıkla. [POINT:1"), "buraya tıkla.")
        XCTAssertEqual(TutorMode.displayText("buraya tıkla"), "buraya tıkla")
    }

    func testSystemPromptDiffersByMode() {
        let idle = TutorMode.systemPrompt(base: "base", active: false)
        let active = TutorMode.systemPrompt(base: "base", active: true)
        XCTAssertTrue(idle.contains("[TUTOR]"))
        XCTAssertFalse(idle.contains("[WAIT]"))
        XCTAssertTrue(active.contains("[WAIT]") && active.contains("[DONE]"))
    }

    @MainActor
    func testLiveModelFollowsTutorSignals() async throws {
        let path = try XCTUnwrap(
            ProcessInfo.processInfo.environment["OPENCLICKY_LIVE_SCREEN"] ?? Optional(""),
            "unreachable"
        )
        try XCTSkipIf(path.isEmpty, "set OPENCLICKY_LIVE_SCREEN to run")
        let image = ClaudeCLIMessage.Image(
            mediaType: "image/jpeg",
            base64: try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString()
        )
        let runner = ClaudeCLIRunner(binaryURL: try ClaudeCLIRunner.locate())

        func ask(_ text: String, active: Bool, resume: String?) async throws -> (TutorMode.Reply, String?) {
            let result = try await runner.ask(
                messages: [ClaudeCLIMessage(role: .user, text: "screen1 (1280x832)\n\(text)", images: [image])],
                systemPrompt: TutorMode.systemPrompt(base: OpenClickyViewModel.systemPrompt, active: active),
                model: ClaudeModel.sonnet.rawValue,
                resumeSessionId: resume
            ) { _ in }
            print("LIVE [\(text.prefix(30))] -> \(result.text)")
            return (TutorMode.parse(result.text), result.sessionId)
        }

        let (start, session) = try await ask(
            "bu uygulamada yeni bir sohbet başlatmayı bana adım adım öğret", active: false, resume: nil
        )
        XCTAssertTrue(start.shouldStart, "asking to be taught should start tutor mode")
        XCTAssertFalse(start.text.isEmpty)

        let (unchanged, _) = try await ask(TutorMode.lookPrompt, active: true, resume: session)
        XCTAssertTrue(unchanged.shouldWait, "an unchanged screen should stay silent")

        let (stop, _) = try await ask("tamam yeter, dur", active: true, resume: session)
        XCTAssertTrue(stop.isFinished, "asking to stop should end tutor mode")
    }
}
