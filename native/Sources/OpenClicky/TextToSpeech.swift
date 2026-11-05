//
//  TextToSpeech.swift
//  Speaks Claude's reply. Three backends, tried in this order:
//
//    1. ElevenLabs — if ElevenLabsConfig.load() returns a key (env var
//       or JSON file). Streams MP3 from the text-to-speech API and
//       plays via AVAudioPlayer. Falls back on any error.
//    2. Ahenk Cep — local Turkish model, for Turkish text only, when
//       installed by scripts/setup-ahenk. Falls back on any error.
//    3. AVSpeechSynthesizer — default, zero-config, picks an installed
//       voice for the text's language.
//
//  Backend selection is sticky for the lifetime of the process; users
//  who add/remove the key need to quit + relaunch (same shape as the
//  Screen Recording TCC quit-and-relaunch requirement).
//

import AVFoundation
import Foundation
import NaturalLanguage
import os

@MainActor
final class TextToSpeech: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.proyecto26.openclicky", category: "TextToSpeech")
    @Published private(set) var elevenLabsConfig: ElevenLabsConfig?

    @Published private(set) var isSpeaking: Bool = false

    /// Human-readable message set whenever the ElevenLabs backend
    /// fell back to AVSpeech on the most recent turn. Cleared on
    /// success. Surfaced in the panel so users can tell why their
    /// premium voice didn't play without digging through os_log.
    @Published private(set) var lastBackendError: String?

    // System speech path
    private let synthesizer = AVSpeechSynthesizer()
    private var synthContinuation: CheckedContinuation<Void, Never>?

    // ElevenLabs playback path
    private var audioPlayer: AVAudioPlayer?
    private var audioPlayerDelegate: AudioPlayerCompletionBridge?
    private var playerContinuation: CheckedContinuation<Void, Never>?

    // Ahenk Cep path
    private let ahenk = AhenkTTSClient.installed()
    /// Bumped by stop() and speak(), so audio that finishes synthesizing
    /// after being cancelled or replaced is dropped instead of played.
    private var speechGeneration = 0

    /// Human-readable label for the footer / diagnostics. Honest about
    /// which backend is actually active so users can tell without
    /// wading through logs.
    var activeBackendDisplayName: String {
        if let elevenLabsConfig {
            return "ElevenLabs (\(elevenLabsConfig.voiceId.prefix(8))…)"
        }
        return ahenk == nil ? "macOS Speech" : "Ahenk Cep + macOS Speech"
    }

    override init() {
        self.elevenLabsConfig = ElevenLabsConfig.load()
        super.init()
        synthesizer.delegate = self
        logger.info("TTS backend: \(self.activeBackendDisplayName, privacy: .public)")
    }

    /// Loads the local voice so the first reply doesn't wait for it.
    func warmUpLocalVoice() {
        guard elevenLabsConfig == nil, let ahenk else { return }
        DispatchQueue.global(qos: .utility).async { ahenk.warmUp() }
    }

    /// Re-reads ElevenLabsConfig from all three sources (env, Keychain,
    /// JSON file). Called by the Settings view after the user saves or
    /// clears the ElevenLabs key so the new backend takes effect on the
    /// very next turn — no relaunch required.
    func reloadConfiguration() {
        stop()
        let previous = elevenLabsConfig?.voiceId
        elevenLabsConfig = ElevenLabsConfig.load()
        lastBackendError = nil
        logger.info("TTS backend reloaded: \(self.activeBackendDisplayName, privacy: .public) (was voice: \(previous ?? "<system>", privacy: .public))")
    }

    /// Speaks `text` and returns when playback finishes (or is cancelled
    /// via `stop()`). Concurrent calls replace the in-flight utterance.
    func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop() // replace any in-flight utterance
        let generation = speechGeneration

        if let config = elevenLabsConfig {
            do {
                try await speakViaElevenLabs(trimmed, config: config)
                lastBackendError = nil
                return
            } catch {
                // Network / API / playback error. Don't leave the user
                // in silence — fall back to the system voice, and
                // surface the reason so the panel can show a chip.
                let description = (error as NSError).localizedDescription
                logger.warning("ElevenLabs TTS failed, falling back to AVSpeech: \(description, privacy: .public)")
                lastBackendError = "ElevenLabs: \(description)"
            }
        } else if let ahenk, SpeechVoicePicker.isTurkish(trimmed) {
            do {
                let wav = try await ahenk.synthesize(trimmed)
                guard generation == speechGeneration else { return }
                try await playAudio(wav)
                lastBackendError = nil
                return
            } catch {
                guard generation == speechGeneration else { return }
                let description = error.localizedDescription
                logger.warning("Ahenk TTS failed, falling back to AVSpeech: \(description, privacy: .public)")
                lastBackendError = "Ahenk: \(description)"
            }
        }
        await speakViaSystem(trimmed)
    }

    /// Cancels any in-flight utterance.
    func stop() {
        speechGeneration += 1
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            resume(&synthContinuation)
        }
        if audioPlayer?.isPlaying == true {
            audioPlayer?.stop()
            resume(&playerContinuation)
        }
        isSpeaking = false
    }

    // MARK: - System speech path

    private func speakViaSystem(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechVoicePicker.voice(for: text)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            synthContinuation = cont
            isSpeaking = true
            synthesizer.speak(utterance)
        }
    }

    // MARK: - ElevenLabs path

    private func speakViaElevenLabs(_ text: String, config: ElevenLabsConfig) async throws {
        let mp3Data = try await fetchElevenLabsAudio(text: text, config: config)
        try await playAudio(mp3Data)
    }

    private func fetchElevenLabsAudio(text: String, config: ElevenLabsConfig) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(config.voiceId)")!)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabs", code: -1, userInfo: [NSLocalizedDescriptionKey: "no HTTP response"])
        }
        guard (200...299).contains(http.statusCode) else {
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            throw NSError(
                domain: "ElevenLabs",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(preview)"]
            )
        }
        return data
    }

    private func playAudio(_ mp3Data: Data) async throws {
        let player = try AVAudioPlayer(data: mp3Data)
        let bridge = AudioPlayerCompletionBridge { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isSpeaking = false
                self.resume(&self.playerContinuation)
            }
        }
        player.delegate = bridge
        self.audioPlayer = player
        self.audioPlayerDelegate = bridge
        player.prepareToPlay()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            playerContinuation = cont
            isSpeaking = true
            player.play()
        }
    }

    // MARK: - Helpers

    private func resume(_ continuation: inout CheckedContinuation<Void, Never>?) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume()
    }
}

// MARK: - Voice selection

/// Picks an on-device voice matching the language of the text, so a Turkish
/// reply is read by a Turkish voice and an English one by an English voice.
/// Prefers the highest-quality installed voice, so downloading an enhanced
/// voice in System Settings takes effect without further configuration.
enum SpeechVoicePicker {
    static func languageCode(of text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
    }

    /// The recognizer is unreliable on a few words, so letters that only
    /// Turkish uses among the languages this app speaks settle it first.
    static func isTurkish(_ text: String) -> Bool {
        text.rangeOfCharacter(from: CharacterSet(charactersIn: "ğĞıİşŞ")) != nil
            || languageCode(of: text) == "tr"
    }

    /// Nil lets AVSpeech use the system default voice.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        guard let code = isTurkish(text) ? "tr" : languageCode(of: text) else { return nil }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == code || $0.language.hasPrefix("\(code)-") }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }
}

// MARK: - AVSpeechSynthesizer delegate

extension TextToSpeech: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.resume(&self.synthContinuation)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.resume(&self.synthContinuation)
        }
    }
}

// MARK: - AVAudioPlayer completion bridge

/// NSObject subclass that implements AVAudioPlayerDelegate with a
/// closure-style completion. Separated from TextToSpeech so the
/// delegate doesn't need @MainActor isolation negotiation.
private final class AudioPlayerCompletionBridge: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish()
    }
}
