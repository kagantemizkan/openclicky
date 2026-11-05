//
//  DictationManager.swift
//  Push-to-talk mic capture + live STT, wired to the user's ⌃⌥ hotkey.
//
//  Flow:
//    hotkey press → startListening()
//      ↓ permission checks (mic + speech)
//      ↓ AVAudioEngine mic tap → TranscriptionSession.appendAudioBuffer
//      ↓ @Published currentAudioLevel drives the waveform
//      ↓ partial transcripts update @Published partialTranscript
//    hotkey release → stopListening()
//      ↓ requestFinalTranscript
//      ↓ wait up to finalTranscriptFallbackDelaySeconds
//      ↓ deliver via `onFinalTranscript` callback; caller runs the turn
//
//  Lean port: upstream's 866-line BuddyDictationManager is trimmed to
//  just the keyboard-shortcut code path (no microphone-button UI, no
//  draft-text editing, no contextual keyterms). v0.3 can re-add those
//  if a non-PTT entry point ever matters.
//

import AVFoundation
import Combine
import Foundation
import Speech
import AppKit
import os

enum DictationPermissionProblem: Equatable {
    case microphoneAccessDenied
    case speechRecognitionDenied
}

@MainActor
final class DictationManager: NSObject, ObservableObject {
    // MARK: - Public observable state

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isFinalizing: Bool = false
    /// Smoothed mic power level in 0.0–1.0 for waveform UI.
    @Published private(set) var currentAudioLevel: CGFloat = 0
    @Published private(set) var partialTranscript: String = ""
    @Published var lastErrorMessage: String? = nil
    @Published private(set) var currentPermissionProblem: DictationPermissionProblem? = nil
    @Published private(set) var providerDisplayName: String = ""

    var isBusy: Bool { isRecording || isFinalizing }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.proyecto26.openclicky", category: "DictationManager")
    private let transcriptionProvider: any TranscriptionProvider
    private let audioEngine = AVAudioEngine()
    private var activeSession: (any TranscriptionSession)?
    private var onFinalTranscript: ((String) -> Void)?
    private var onEndedWithoutTranscript: (() -> Void)?

    /// Identifies the current start attempt, so one that is still awaiting
    /// permissions after being cancelled or superseded never opens the mic.
    private var sessionToken = 0
    private var isStarting = false
    /// The push-to-talk key was released before the mic finished starting.
    private var stopRequestedDuringStart = false

    /// Fires when requestFinalTranscript doesn't deliver within the
    /// provider's fallback window — falls back to the latest partial.
    private var finalizeFallbackWorkItem: DispatchWorkItem?

    private var lastAudioLevelSampleAt = Date.distantPast
    private static let audioLevelSampleIntervalSeconds: TimeInterval = 0.05

    // MARK: - Init

    override init() {
        self.transcriptionProvider = TranscriptionProviderFactory.makeDefault()
        self.providerDisplayName = transcriptionProvider.displayName
        super.init()
    }

    // MARK: - Permissions

    var needsInitialPermissionPrompt: Bool {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        if transcriptionProvider.requiresSpeechRecognitionPermission {
            return mic == .notDetermined || speech == .notDetermined
        }
        return mic == .notDetermined
    }

    /// Asks macOS for mic + speech recognition. Idempotent; safe to
    /// call any number of times. Returns true if both are granted.
    @discardableResult
    func requestPermissions() async -> Bool {
        var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if !micGranted {
            micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        }
        if !micGranted {
            currentPermissionProblem = .microphoneAccessDenied
            return false
        }

        if transcriptionProvider.requiresSpeechRecognitionPermission {
            let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
            }
            if status != .authorized {
                currentPermissionProblem = .speechRecognitionDenied
                return false
            }
        }

        currentPermissionProblem = nil
        return true
    }

    // MARK: - Start / stop

    /// Begins listening. The caller supplies a closure that will be
    /// invoked once, on the main actor, with the final transcript
    /// (either the SFSpeech-delivered final result or, if that never
    /// arrives in time, the last partial). If the session ends with nothing
    /// to deliver (permission denied, STT error, no speech),
    /// `onEndedWithoutTranscript` is invoked instead. Neither fires after
    /// an explicit `cancelListening()`.
    func startListening(
        onFinalTranscript: @escaping (String) -> Void,
        onEndedWithoutTranscript: @escaping () -> Void
    ) async {
        guard !isBusy else { return }

        sessionToken += 1
        let token = sessionToken
        isStarting = true
        stopRequestedDuringStart = false
        self.onFinalTranscript = onFinalTranscript
        self.onEndedWithoutTranscript = onEndedWithoutTranscript
        lastErrorMessage = nil
        currentPermissionProblem = nil
        partialTranscript = ""

        let hasPermissions = await requestPermissions()
        guard token == sessionToken else { return }
        guard hasPermissions else {
            logger.warning("Mic or speech permission not granted; aborting session")
            finishWithoutTranscript()
            return
        }

        do {
            let session = try await transcriptionProvider.startStreamingSession(
                onTranscriptUpdate: { [weak self] text in
                    Task { @MainActor [weak self] in
                        self?.partialTranscript = text
                    }
                },
                onFinalTranscriptReady: { [weak self] text in
                    Task { @MainActor [weak self] in
                        self?.deliverFinalTranscript(text)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, token == self.sessionToken else { return }
                        self.logger.error("STT error: \(error.localizedDescription, privacy: .public)")
                        self.lastErrorMessage = error.localizedDescription
                        self.finishWithoutTranscript()
                    }
                }
            )
            guard token == sessionToken else {
                session.cancel()
                return
            }
            activeSession = session
        } catch {
            guard token == sessionToken else { return }
            logger.error("Failed to start transcription session: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            finishWithoutTranscript()
            return
        }

        // Released during the awaits above: don't open the mic after the
        // user has already let go of the key.
        guard !stopRequestedDuringStart else {
            finishWithoutTranscript()
            return
        }

        do {
            try startAudioEngine()
        } catch {
            logger.error("AVAudioEngine start failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            // The tap is installed before start(); cancelListening only
            // removes it from a running engine.
            audioEngine.inputNode.removeTap(onBus: 0)
            finishWithoutTranscript()
            return
        }

        isStarting = false
        isRecording = true
    }

    /// Signals end-of-speech and waits for the final transcript. If no
    /// final arrives within the provider's fallback window, the latest
    /// partial is used instead.
    func stopListening() {
        guard isRecording else {
            if isStarting {
                stopRequestedDuringStart = true
            } else {
                finishWithoutTranscript()
            }
            return
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        currentAudioLevel = 0

        isRecording = false
        isFinalizing = true

        activeSession?.requestFinalTranscript()

        let fallbackDelay = activeSession?.finalTranscriptFallbackDelaySeconds ?? 2.0
        let latestPartial = partialTranscript
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isFinalizing else { return }
                self.logger.info("Final transcript fallback fired; using latest partial (\(latestPartial.count) chars)")
                self.deliverFinalTranscript(latestPartial)
            }
        }
        finalizeFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay, execute: work)
    }

    /// Aborts the current session without emitting a transcript. Used
    /// when the user cancels or on unrecoverable STT errors.
    func cancelListening() {
        sessionToken += 1
        isStarting = false
        stopRequestedDuringStart = false
        onEndedWithoutTranscript = nil
        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        activeSession?.cancel()
        activeSession = nil
        onFinalTranscript = nil

        isRecording = false
        isFinalizing = false
        currentAudioLevel = 0
    }

    // MARK: - Internals

    /// Tears the session down and tells the caller nothing is coming, so
    /// it doesn't wait forever for a transcript.
    private func finishWithoutTranscript() {
        let callback = onEndedWithoutTranscript
        cancelListening()
        callback?()
    }

    private func deliverFinalTranscript(_ text: String) {
        guard isFinalizing || isRecording else { return }
        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        activeSession?.cancel()
        activeSession = nil

        let callback = onFinalTranscript
        let endedCallback = onEndedWithoutTranscript
        onFinalTranscript = nil
        onEndedWithoutTranscript = nil
        isRecording = false
        isFinalizing = false

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            callback?(trimmed)
        } else {
            logger.info("Empty final transcript; skipping callback")
            endedCallback?()
        }
    }

    private func startAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        // A standard buffer size that balances latency and CPU. ~1024
        // frames at 48 kHz ≈ 21 ms per callback.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.forwardToSession(buffer)
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func forwardToSession(_ buffer: AVAudioPCMBuffer) {
        activeSession?.appendAudioBuffer(buffer)
        sampleAudioLevel(from: buffer)
    }

    /// Computes an RMS-style normalized level suitable for a waveform
    /// and throttles updates to ~20 Hz so SwiftUI doesn't redraw the
    /// panel 900 times/second.
    private func sampleAudioLevel(from buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastAudioLevelSampleAt) >= Self.audioLevelSampleIntervalSeconds else { return }
        lastAudioLevelSampleAt = now

        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let channel = channelData[0]
        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(frameCount)).squareRoot()
        // Map 0..0.3 of RMS to 0..1 — human voice rarely exceeds 0.3
        // in normalized float samples. Clamp and smooth toward target.
        let normalized = CGFloat(min(max(rms / 0.3, 0), 1))
        // Simple one-pole smoother so the waveform doesn't twitch.
        currentAudioLevel = currentAudioLevel * 0.5 + normalized * 0.5
    }
}
