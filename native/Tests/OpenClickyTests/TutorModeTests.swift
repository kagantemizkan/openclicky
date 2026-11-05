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

    /// One how-to question should carry through a whole task. The directory
    /// holds JPEGs of a mock app: 1-button, 2-menu, 3-settings, 4-other-app,
    /// with the Filters button and Vignette item at known positions.
    @MainActor
    func testLiveOneQuestionCarriesThroughAllSteps() async throws {
        let directory = ProcessInfo.processInfo.environment["OPENCLICKY_LIVE_MOCK_DIR"] ?? ""
        try XCTSkipIf(directory.isEmpty, "set OPENCLICKY_LIVE_MOCK_DIR to run")
        let runner = ClaudeCLIRunner(binaryURL: try ClaudeCLIRunner.locate())

        func ask(
            _ screen: String, _ text: String, active: Bool, resume: String?
        ) async throws -> (TutorMode.Reply, PointParseResult, String?) {
            let data = try Data(contentsOf: URL(fileURLWithPath: "\(directory)/\(screen).jpg"))
            let image = ClaudeCLIMessage.Image(mediaType: "image/jpeg", base64: data.base64EncodedString())
            let result = try await runner.ask(
                messages: [ClaudeCLIMessage(role: .user, text: "screen1 (1280x800)\n\(text)", images: [image])],
                systemPrompt: TutorMode.systemPrompt(base: OpenClickyViewModel.systemPrompt, active: active),
                model: ClaudeModel.sonnet.rawValue,
                resumeSessionId: resume
            ) { _ in }
            print("LIVE \(screen) [\(text.prefix(24))] -> \(result.text)")
            let reply = TutorMode.parse(result.text)
            return (reply, PointTagParser.parse(reply.text), result.sessionId)
        }

        let (simple, _, _) = try await ask("1-button", "filtreler ne işe yarıyor", active: false, resume: nil)
        XCTAssertFalse(simple.shouldStart, "a simple question should not start a lesson")

        let (first, firstPoint, session) = try await ask("1-button", "vinyet efekti nasıl eklerim", active: false, resume: nil)
        XCTAssertTrue(first.shouldStart, "a how-to question should start a lesson unasked")
        XCTAssertEqual(firstPoint.point?.x ?? 0, 1130, accuracy: 70, "first step points at Filters")

        let (second, secondPoint, _) = try await ask("2-menu", TutorMode.lookPrompt, active: true, resume: session)
        XCTAssertFalse(second.shouldWait, "the menu opening should advance the lesson")
        XCTAssertEqual(secondPoint.point?.y ?? 0, 250, accuracy: 50, "second step points at Vignette")

        let (third, _, _) = try await ask("3-settings", TutorMode.lookPrompt, active: true, resume: session)
        XCTAssertFalse(third.shouldWait, "the settings opening should be explained")
        XCTAssertFalse(third.text.isEmpty)

        let (away, _, _) = try await ask("4-other-app", TutorMode.lookPrompt, active: true, resume: session)
        XCTAssertTrue(away.isFinished, "leaving for another app should end the lesson")
    }
}
