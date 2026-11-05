//
//  VoiceChainTests.swift
//  The user's voice order, and moving on when a voice fails.
//

import XCTest
@testable import OpenClicky

@MainActor
final class VoiceChainTests: XCTestCase {
    private struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private func preferences() -> AppPreferences {
        let suite = "openclicky-voice-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return AppPreferences(defaults: UserDefaults(suiteName: suite)!)
    }

    func testDefaultOrderKeepsTheVoicesPeopleAlreadyHad() {
        XCTAssertEqual(preferences().voiceOrder, [.elevenLabs, .ahenk, .system])
    }

    func testSkipsVoicesThatCantReadThisText() {
        let all: [VoiceEngine] = [.elevenLabs, .ahenk, .system]
        XCTAssertEqual(VoiceChain.attempts(enabled: all, isTurkish: true, hasElevenLabsKey: true, hasAhenk: true), all)
        XCTAssertEqual(VoiceChain.attempts(enabled: all, isTurkish: true, hasElevenLabsKey: false, hasAhenk: true), [.ahenk, .system])
        XCTAssertEqual(VoiceChain.attempts(enabled: all, isTurkish: false, hasElevenLabsKey: false, hasAhenk: true), [.system])
        XCTAssertEqual(VoiceChain.attempts(enabled: all, isTurkish: true, hasElevenLabsKey: false, hasAhenk: false), [.system])
        XCTAssertEqual(VoiceChain.attempts(enabled: [.ahenk], isTurkish: false, hasElevenLabsKey: true, hasAhenk: true), [])
    }

    func testUsedUpKeyMovesOnToTheNextVoiceAndSaysWhy() async {
        var tried: [VoiceEngine] = []
        let outcome = await VoiceChain.run([.elevenLabs, .ahenk, .system], isCurrent: { true }) { engine in
            tried.append(engine)
            if engine == .elevenLabs { throw Failure(errorDescription: "HTTP 401: quota_exceeded") }
        }
        XCTAssertEqual(tried, [.elevenLabs, .ahenk], "the voice after a working one must not also speak")
        XCTAssertEqual(outcome.used, .ahenk)
        XCTAssertEqual(outcome.failures, ["ElevenLabs: HTTP 401: quota_exceeded"])
    }

    func testEveryVoiceFailing() async {
        let outcome = await VoiceChain.run([.elevenLabs, .ahenk], isCurrent: { true }) { _ in
            throw Failure(errorDescription: "no")
        }
        XCTAssertNil(outcome.used)
        XCTAssertEqual(outcome.failures.count, 2)
    }

    func testStoppingDuringAFailureDoesntStartTheNextVoice() async {
        var current = true
        var tried: [VoiceEngine] = []
        let outcome = await VoiceChain.run([.elevenLabs, .system], isCurrent: { current }) { engine in
            tried.append(engine)
            current = false
            throw Failure(errorDescription: "cancelled")
        }
        XCTAssertEqual(tried, [.elevenLabs])
        XCTAssertTrue(outcome.wasInterrupted)
    }

    func testMovingVoicesStaysInBoundsAndIsSaved() {
        let suite = "openclicky-voice-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let first = AppPreferences(defaults: defaults)
        first.moveVoice(.ahenk, by: -1)
        XCTAssertEqual(first.voiceOrder, [.ahenk, .elevenLabs, .system])
        first.moveVoice(.ahenk, by: -1)
        first.moveVoice(.system, by: 1)
        XCTAssertEqual(first.voiceOrder, [.ahenk, .elevenLabs, .system])
        first.setVoice(.system, enabled: false)

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.voiceOrder, [.ahenk, .elevenLabs, .system])
        XCTAssertEqual(reloaded.enabledVoices, [.ahenk, .elevenLabs])
    }

    func testTheLastVoiceCantBeTurnedOff() {
        let prefs = preferences()
        prefs.setVoice(.elevenLabs, enabled: false)
        prefs.setVoice(.ahenk, enabled: false)
        prefs.setVoice(.system, enabled: false)
        XCTAssertEqual(prefs.enabledVoices, [.system])
    }

    func testSavedOrderSurvivesVoicesChanging() {
        XCTAssertEqual(VoiceEngine.order(saved: ["system", "gone", "system"]), [.system, .elevenLabs, .ahenk])
        XCTAssertEqual(VoiceEngine.order(saved: nil), VoiceEngine.allCases)
    }
}
