//
//  RecognizerLocaleTests.swift
//  Pins the fix for Turkish speech being transcribed as English: the
//  recognizer follows the system languages, not the app's en_TR locale.
//

import XCTest
@testable import OpenClicky

final class RecognizerLocaleTests: XCTestCase {
    func testSystemLanguageComesFirstThenEnglishFallback() {
        let locales = AppleSpeechTranscriptionProvider.recognizerLocales(preferredLanguages: ["tr-TR"])
        XCTAssertEqual(locales.map(\.identifier), ["tr-TR", "en-US"])
    }

    func testKeepsTheUsersLanguageOrder() {
        let locales = AppleSpeechTranscriptionProvider.recognizerLocales(preferredLanguages: ["de-DE", "tr-TR"])
        XCTAssertEqual(locales.first?.identifier, "de-DE")
    }
}
