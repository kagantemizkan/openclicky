//
//  TextToSpeech.swift
//  Speaks Claude's reply with the voices the user turned on, in the order
//  they chose. Each is skipped if it can't read this text and passed over if
//  it fails, so a used-up ElevenLabs key just moves on to the next voice.
//
//    ElevenLabs — needs an API key (env var, Keychain or JSON file). Fetches
//       MP3 from the text-to-speech API and plays via AVAudioPlayer.
//    Ahenk Cep — local Turkish model, for Turkish text only, when installed
//       by scripts/setup-ahenk.
//    macOS — AVSpeechSynthesizer, picks an installed voice for the text's
//       language.
//

import AVFoundation
import Combine
import Foundation
import NaturalLanguage
import os

/// The order voices are tried in for one reply.
enum VoiceChain {
    static func attempts(
        enabled: [VoiceEngine],
        isTurkish: Bool,
        hasElevenLabsKey: Bool,
        hasAhenk: Bool
    ) -> [VoiceEngine] {
        enabled.filter { engine in
            switch engine {
            case .elevenLabs: return hasElevenLabsKey
            case .ahenk: return hasAhenk && isTurkish
            case .system: return true
            }
        }
    }

    struct Outcome: Equatable {
        /// Nil if nothing could read it, or it was interrupted.
        var used: VoiceEngine?
        /// Why each voice before it didn't.
        var failures: [String] = []
        var wasInterrupted = false
    }

    /// Tries each voice until one finishes. Once `isCurrent` turns false the
    /// reply was stopped or replaced, so nothing further may play.
    @MainActor
    static func run(
        _ attempts: [VoiceEngine],
        isCurrent: () -> Bool,
        speak: (VoiceEngine) async throws -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        for engine in attempts {
            do {
                try await speak(engine)
                guard isCurrent() else {
                    outcome.wasInterrupted = true
                    return outcome
                }
                outcome.used = engine
                return outcome
            } catch {
                guard isCurrent() else {
                    outcome.wasInterrupted = true
                    return outcome
                }
                outcome.failures.append("\(engine.displayName): \(error.localizedDescription)")
            }
        }
        return outcome
    }
}

@MainActor
final class TextToSpeech: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.proyecto26.openclicky", category: "TextToSpeech")
    @Published private(set) var elevenLabsConfig: ElevenLabsConfig?

    @Published private(set) var isSpeaking: Bool = false

    /// The voice that read the latest reply.
    @Published private(set) var lastUsedEngine: VoiceEngine?

    /// Why voices were passed over on the latest reply, so users can tell
    /// why their chosen voice didn't play without digging through os_log.
    /// Keeps the raw error: 401 means a bad or used-up key, and
    /// voice_not_found a wrong voice id. Cleared when the first voice works.
    @Published private(set) var lastBackendError: String?

    private let preferences: AppPreferences
    private var observations: Set<AnyCancellable> = []

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

    var isAhenkInstalled: Bool { ahenk != nil }

    init(preferences: AppPreferences = .shared) {
        self.preferences = preferences
        self.elevenLabsConfig = ElevenLabsConfig.load()
        super.init()
        synthesizer.delegate = self
        preferences.$disabledVoices
            .dropFirst()
            .map { !$0.contains(.ahenk) }
            .removeDuplicates()
            .sink { [weak self] enabled in self?.setLocalVoiceLoaded(enabled) }
            .store(in: &observations)
    }

    /// Loads the local voice so the first reply, or the first fallback to it,
    /// doesn't wait for it.
    func warmUpLocalVoice() {
        setLocalVoiceLoaded(!preferences.disabledVoices.contains(.ahenk))
    }

    private func setLocalVoiceLoaded(_ loaded: Bool) {
        guard let ahenk else { return }
        DispatchQueue.global(qos: .utility).async {
            if loaded {
                ahenk.warmUp()
            } else {
                ahenk.shutdown()
            }
        }
    }

    /// Re-reads ElevenLabsConfig from all three sources (env, Keychain,
    /// JSON file). Called by the Settings view after the user saves or
    /// clears the ElevenLabs key so the new backend takes effect on the
    /// very next turn — no relaunch required.
    func reloadConfiguration() {
        stop()
        elevenLabsConfig = ElevenLabsConfig.load()
        lastBackendError = nil
    }

    /// Speaks `text` and returns when playback finishes (or is cancelled
    /// via `stop()`). Concurrent calls replace the in-flight utterance.
    func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let attempts = VoiceChain.attempts(
            enabled: preferences.enabledVoices,
            isTurkish: SpeechVoicePicker.isTurkish(trimmed),
            hasElevenLabsKey: elevenLabsConfig != nil,
            hasAhenk: ahenk != nil
        )
        await play(trimmed, attempts: attempts)
    }

    /// Plays a sample in one voice from Settings, so voices can be compared.
    func preview(_ engine: VoiceEngine) async {
        await play(engine == .ahenk ? Strings.voiceSampleTurkish : Strings.voiceSample, attempts: [engine])
    }

    private func play(_ text: String, attempts: [VoiceEngine]) async {
        stop() // replace any in-flight utterance
        let generation = speechGeneration
        guard !attempts.isEmpty else {
            lastUsedEngine = nil
            lastBackendError = Strings.noVoiceForText
            return
        }

        let outcome = await VoiceChain.run(attempts, isCurrent: { generation == speechGeneration }) { engine in
            try await self.speak(text, with: engine, generation: generation)
        }
        guard !outcome.wasInterrupted else { return }
        for failure in outcome.failures {
            logger.warning("Voice failed, moving on: \(failure, privacy: .public)")
        }
        lastUsedEngine = outcome.used
        lastBackendError = outcome.failures.isEmpty ? nil : outcome.failures.joined(separator: "\n")
    }

    private func speak(_ text: String, with engine: VoiceEngine, generation: Int) async throws {
        var audio: Data?
        switch engine {
        case .elevenLabs:
            guard let config = elevenLabsConfig else { throw AhenkTTSError(message: Strings.voiceNeedsKey) }
            audio = try await fetchElevenLabsAudio(text: text, config: config)
        case .ahenk:
            guard let ahenk else { throw AhenkTTSError(message: Strings.voiceNotInstalled) }
            audio = try await ahenk.synthesize(text)
        case .system:
            break
        }
        // Stopped while the audio was being made: it must not start playing.
        guard generation == speechGeneration else { return }
        if let audio {
            try await playAudio(audio)
        } else {
            await speakViaSystem(text)
        }
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

    private func fetchElevenLabsAudio(text: String, config: ElevenLabsConfig) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(config.voiceId)")!)
        request.httpMethod = "POST"
        // A stalled network should reach the next voice, not hold up the reply.
        request.timeoutInterval = 10
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
