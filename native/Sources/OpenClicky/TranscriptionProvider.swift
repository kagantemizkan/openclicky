//
//  TranscriptionProvider.swift
//  Speech-to-text protocol surface + Apple Speech implementation.
//
//  v0.2 only supports Apple Speech (on-device when possible).
//  AssemblyAI and OpenAI Whisper were API-key-based providers retired
//  by the spec — no way to offer them without shipping a key.
//
//  Future extension: a third-party key pasted into Keychain could
//  activate an AssemblyAI branch here; not wired up in v0.2.
//

import AVFoundation
import Foundation
import Speech
import os

// MARK: - Public protocol surface

protocol TranscriptionSession: AnyObject {
    /// When the user releases the hotkey we call `requestFinalTranscript()`
    /// and wait up to this many seconds for SFSpeechRecognitionTask to
    /// deliver the best-effort final result. If it doesn't fire in time,
    /// the dictation manager uses the latest partial transcript instead.
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol TranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }

    func startStreamingSession(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any TranscriptionSession
}

// MARK: - Factory

enum TranscriptionProviderFactory {
    private static let logger = Logger(subsystem: "com.kagantemizkan.openclicky", category: "TranscriptionProvider")

    /// Returns the best available STT provider for the current
    /// environment. Today that's always Apple Speech — a single
    /// implementation keeps the surface deliberately minimal so the
    /// dictation manager can treat transcription as a black box.
    static func makeDefault() -> any TranscriptionProvider {
        let provider = AppleSpeechTranscriptionProvider()
        logger.info("Transcription provider: \(provider.displayName, privacy: .public)")
        return provider
    }
}

// MARK: - Apple Speech implementation

struct AppleSpeechTranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class AppleSpeechTranscriptionProvider: TranscriptionProvider {
    let displayName = "Apple Speech"
    let requiresSpeechRecognitionPermission = true
    let isConfigured = true

    func startStreamingSession(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any TranscriptionSession {
        guard let recognizer = Self.bestAvailableSpeechRecognizer() else {
            throw AppleSpeechTranscriptionError(message: "Dictation is not available on this Mac.")
        }
        return try AppleSpeechTranscriptionSession(
            speechRecognizer: recognizer,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    /// The user's system languages in order, then en-US. Not Locale.current:
    /// this app ships only an English localization, so on a Turkish Mac that
    /// is en_TR, and Turkish speech would be transcribed as English.
    static func recognizerLocales(preferredLanguages: [String]) -> [Locale] {
        (preferredLanguages + ["en-US"]).map { Locale(identifier: $0) }
    }

    private static func bestAvailableSpeechRecognizer() -> SFSpeechRecognizer? {
        for locale in recognizerLocales(preferredLanguages: Locale.preferredLanguages) {
            if let recognizer = SFSpeechRecognizer(locale: locale) {
                return recognizer
            }
        }
        return SFSpeechRecognizer()
    }
}

private final class AppleSpeechTranscriptionSession: NSObject, TranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1.8

    private let recognitionRequest: SFSpeechAudioBufferRecognitionRequest
    private var recognitionTask: SFSpeechRecognitionTask?
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private var latestRecognizedText = ""
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false

    init(
        speechRecognizer: SFSpeechRecognizer,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        super.init()

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        recognitionRequest.addsPunctuation = true

        // On-device recognition when available: keeps mic audio local
        // (privacy + cheap repeat runs). Falls back to server recognition
        // automatically if the model isn't downloaded yet.
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            self?.handleRecognitionEvent(result: result, error: error)
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinalTranscript else { return }
        recognitionRequest.append(audioBuffer)
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript else { return }
        hasRequestedFinalTranscript = true
        recognitionRequest.endAudio()
    }

    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    deinit {
        recognitionTask?.cancel()
    }

    private func handleRecognitionEvent(
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        if let result {
            latestRecognizedText = result.bestTranscription.formattedString
            onTranscriptUpdate(latestRecognizedText)
            if result.isFinal {
                deliverFinalTranscriptIfNeeded(latestRecognizedText)
                return
            }
        }

        guard let error else { return }

        // If we've already asked for the final transcript and have at least
        // some recognized text, treat the error as "end of session" and
        // deliver what we have rather than bubbling it up as a real failure.
        if hasRequestedFinalTranscript && !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deliverFinalTranscriptIfNeeded(latestRecognizedText)
        } else {
            onError(error)
        }
    }

    private func deliverFinalTranscriptIfNeeded(_ text: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(text)
    }
}
