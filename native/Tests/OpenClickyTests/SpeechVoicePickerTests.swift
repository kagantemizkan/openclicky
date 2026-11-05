//
//  SpeechVoicePickerTests.swift
//  Language detection is pure; voice lookup depends on the voices installed
//  on the machine, so it is skipped where no Turkish voice exists.
//

import AVFoundation
import XCTest
@testable import OpenClicky

final class SpeechVoicePickerTests: XCTestCase {
    private let turkish = "sağ üstteki simgeye tıkla, sonra açılan menüden ayarları seç."
    private let english = "click the icon in the top right, then choose settings from the menu."

    func testDetectsTurkish() {
        XCTAssertEqual(SpeechVoicePicker.languageCode(of: turkish), "tr")
    }

    func testDetectsEnglish() {
        XCTAssertEqual(SpeechVoicePicker.languageCode(of: english), "en")
    }

    func testTurkishLettersSettleShortText() {
        XCTAssertTrue(SpeechVoicePicker.isTurkish("şuna bak"))
        XCTAssertTrue(SpeechVoicePicker.isTurkish(turkish))
        XCTAssertFalse(SpeechVoicePicker.isTurkish(english))
    }

    func testTurkishTextGetsTurkishVoice() throws {
        let hasTurkishVoice = AVSpeechSynthesisVoice.speechVoices().contains { $0.language.hasPrefix("tr") }
        try XCTSkipUnless(hasTurkishVoice, "no Turkish voice installed")
        XCTAssertEqual(SpeechVoicePicker.voice(for: turkish)?.language, "tr-TR")
    }

    func testEmptyTextFallsBackToSystemDefault() {
        XCTAssertNil(SpeechVoicePicker.voice(for: ""))
    }
}
