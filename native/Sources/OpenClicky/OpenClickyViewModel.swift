//
//  OpenClickyViewModel.swift
//  Observable state for the panel. Probes the `claude` CLI on launch,
//  orchestrates the push-to-talk flow (hotkey → dictation → Claude →
//  TTS → POINT tag), and persists session IDs across launches.
//

import Combine
import Foundation
import SwiftUI
import os

/// Coarse state for the panel UI — idle / listening / thinking / speaking.
enum CompanionState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
}

/// User-selectable Claude model. Values match the CLI's `--model` slugs.
/// Sonnet is the default (fast, vision-capable); Opus is the opt-in
/// heavier brain for harder reasoning turns.
enum ClaudeModel: String, CaseIterable, Identifiable {
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        }
    }

    private static let defaultsKey = "com.proyecto26.openclicky.selectedModel"

    static func loadPersisted() -> ClaudeModel {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let model = ClaudeModel(rawValue: raw) else {
            return .sonnet
        }
        return model
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

@MainActor
final class OpenClickyViewModel: ObservableObject {
    // MARK: - Claude CLI + session

    @Published var isClaudeCLIAvailable: Bool = true
    @Published var claudeBinaryPath: String?
    @Published var claudeVersion: String?
    @Published var isRunningTurn: Bool = false
    @Published var streamingText: String = ""
    @Published var lastError: String?
    @Published var lastSessionId: String?
    @Published var selectedModel: ClaudeModel = ClaudeModel.loadPersisted() {
        didSet { selectedModel.persist() }
    }

    // MARK: - Screen Recording permission

    let screenRecordingPermission = ScreenRecordingPermission()
    @Published var hasScreenRecordingPermission: Bool
    @Published var requiresRelaunchForScreenRecording: Bool = false

    // MARK: - Push-to-talk (hotkey + mic + STT + TTS)

    let pushToTalkMonitor = PushToTalkMonitor()
    let dictationManager = DictationManager()
    let accessibilityPermission = AccessibilityPermission()
    let textToSpeech = TextToSpeech()
    let overlayManager = OverlayManager()

    @Published var hasAccessibilityPermission: Bool
    @Published var state: CompanionState = .idle
    @Published var currentAudioLevel: CGFloat = 0
    @Published var dictationPermissionProblem: DictationPermissionProblem? = nil

    // MARK: - Private

    private let logger = Logger(subsystem: "com.proyecto26.openclicky", category: "OpenClickyViewModel")
    private var currentTask: Task<Void, Never>?
    /// Monotonically increasing counter incremented every time a turn is
    /// started OR cancelled. Lets in-flight turns recognise when they've
    /// been superseded — their defer blocks and catch handlers check the
    /// generation and skip state mutations if they're no longer current,
    /// so a cancelled turn can't stomp on the state that `cancelCurrentTurn`
    /// (or the new turn the user kicked off) already wrote.
    private var turnGeneration: Int = 0
    /// Pending transcript → runTurn dispatch. Introduces a small
    /// coalesce window so rapid press-release-press-release cycles
    /// don't fire multiple Claude calls back-to-back; only the last
    /// transcript actually hits the CLI.
    private var pendingDispatch: Task<Void, Never>?
    private var observations: Set<AnyCancellable> = []

    init() {
        self.hasScreenRecordingPermission = screenRecordingPermission.isGranted
        self.hasAccessibilityPermission = accessibilityPermission.isGranted

        screenRecordingPermission.$isGranted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in self?.hasScreenRecordingPermission = granted }
            .store(in: &observations)

        screenRecordingPermission.$requiresRelaunch
            .receive(on: DispatchQueue.main)
            .sink { [weak self] req in self?.requiresRelaunchForScreenRecording = req }
            .store(in: &observations)

        accessibilityPermission.$isGranted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in
                self?.hasAccessibilityPermission = granted
                if granted {
                    self?.pushToTalkMonitor.start()
                }
            }
            .store(in: &observations)

        dictationManager.$currentAudioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in self?.currentAudioLevel = level }
            .store(in: &observations)

        dictationManager.$currentPermissionProblem
            .receive(on: DispatchQueue.main)
            .sink { [weak self] problem in self?.dictationPermissionProblem = problem }
            .store(in: &observations)

        pushToTalkMonitor.transitions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleHotkeyTransition(transition)
            }
            .store(in: &observations)

        // Mirror state + mic power into OverlayManager so the always-on
        // cursor buddy can render the right visual (triangle / waveform
        // / spinner) without OverlayManager depending on the view model.
        $state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.overlayManager.voiceState = state }
            .store(in: &observations)
        $currentAudioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in self?.overlayManager.audioLevel = level }
            .store(in: &observations)
        $streamingText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in self?.overlayManager.streamingResponseText = text }
            .store(in: &observations)

        if !hasScreenRecordingPermission {
            screenRecordingPermission.startWatching()
        }
        if hasAccessibilityPermission {
            pushToTalkMonitor.start()
        } else {
            accessibilityPermission.startWatching()
        }
    }

    /// English name of the user's first system language, e.g. "Turkish".
    private static var userLanguageName: String {
        let code = Locale.preferredLanguages.first
            .flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? "English"
    }

    /// System prompt for the OpenClicky persona. Kept tight so the CLI's
    /// input tokens stay low while still carrying the POINT tag contract
    /// the panel parses on every reply.
    static let systemPrompt: String = """
    you're OpenClicky, a friendly screen-aware companion. the user is looking at their mac \
    screen. the user's language is \(userLanguageName). reply in it, using its correct \
    letters, unless they clearly speak another language. their words usually come from \
    speech recognition and can be misheard: infer what they meant from the screen and \
    context, and if it's a meaningless fragment, briefly ask them to repeat it. never \
    switch language because of a garbled transcript. reply in one or two sentences, lowercase, \
    warm, conversational. your name is \
    OpenClicky, written exactly that way with the capital O and C — introduce yourself as \
    "hey, i'm OpenClicky" when a greeting is appropriate; every other word stays lowercase. \
    no emojis, no bullet lists, no markdown. reference specific things on screen when \
    relevant. if you want to flag a ui element, append a tag `[POINT:x,y:label]` at the end \
    where x,y are pixel coordinates in the screenshot's pixel space and label is 1-3 words. \
    if pointing wouldn't help, omit the tag.
    """

    // MARK: - Claude CLI probe

    func refreshClaudeCLIStatus() async {
        do {
            let binary = try ClaudeCLIRunner.locate()
            let version = await ClaudeCLIRunner.probeVersion(at: binary)
            isClaudeCLIAvailable = true
            claudeBinaryPath = binary.path
            claudeVersion = version
        } catch {
            isClaudeCLIAvailable = false
            claudeBinaryPath = nil
            claudeVersion = nil
        }
    }

    // MARK: - Permission helpers

    func requestScreenRecordingPermission() { screenRecordingPermission.request() }
    func openScreenRecordingSettings() { screenRecordingPermission.openSystemSettings() }
    func requestAccessibilityPermission() { accessibilityPermission.request() }
    func openAccessibilitySettings() { accessibilityPermission.openSystemSettings() }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
    func openSpeechRecognitionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") else { return }
        NSWorkspace.shared.open(url)
    }

    func retryPermissions() {
        Task { await dictationManager.requestPermissions() }
    }

    // MARK: - Push-to-talk

    private func handleHotkeyTransition(_ transition: PushToTalkShortcut.Transition) {
        switch transition {
        case .pressed:
            // Already listening → spurious synthetic press (modifier was
            // held through a key tick). Ignore; let the release handle it.
            if state == .listening { return }
            // If Claude or ElevenLabs is taking forever, a second press
            // should cut the in-flight turn and start a fresh one instead
            // of being dropped. Cancel stops the screenshot → CLI → TTS
            // chain synchronously and resets state to idle.
            if isRunningTurn || state != .idle {
                logger.info("hotkey press during state=\(String(describing: self.state), privacy: .public) — cancelling in-flight turn")
                cancelCurrentTurn()
            }
            startListening()
        case .released:
            guard state == .listening else { return }
            finishListening()
        case .none:
            break
        }
    }

    private func startListening() {
        state = .listening
        lastError = nil
        streamingText = ""
        Task { @MainActor in
            await dictationManager.startListening(
                onFinalTranscript: { [weak self] transcript in
                    self?.runTurnFromVoice(userPrompt: transcript)
                },
                onEndedWithoutTranscript: { [weak self] in
                    self?.handleDictationEndedWithoutTranscript()
                }
            )
        }
    }

    /// Without this, `state` stays .listening/.thinking forever and the
    /// spinner never stops when dictation fails or hears nothing.
    private func handleDictationEndedWithoutTranscript() {
        guard state == .listening || state == .thinking,
              !isRunningTurn, pendingDispatch == nil else { return }
        logger.info("Dictation ended without a transcript; returning to idle")
        state = .idle
        lastError = dictationManager.lastErrorMessage
    }

    private func finishListening() {
        state = .thinking
        dictationManager.stopListening()
        // dictationManager will call onFinalTranscript once the STT pipeline
        // delivers; that callback fires runTurnFromVoice below.
    }

    private func runTurnFromVoice(userPrompt: String) {
        // Debounce: drop any previously-queued dispatch, then wait
        // 250 ms before hitting Claude. If the user re-presses within
        // that window, cancelCurrentTurn will kill this pending task
        // and startListening fresh — no wasted Claude call for the
        // discarded transcript.
        pendingDispatch?.cancel()
        pendingDispatch = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.pendingDispatch = nil
            self.runTurn(userPrompt: userPrompt, thenSpeak: true)
        }
    }

    /// Wipe `streamingText` ~6 s after a turn ends successfully, so the
    /// cursor-adjacent reply bubble fades on its own if the user doesn't
    /// start another turn. Guarded by the turn generation — if the user
    /// cancels or kicks off a new turn before the timer fires, this
    /// scheduled clear is skipped so it doesn't wipe fresh text.
    private func scheduleResponseFade(for generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.turnGeneration == generation else { return }
            self.streamingText = ""
        }
    }

    // MARK: - Turn execution

    /// Captures ALL displays, dispatches a single turn to Claude,
    /// streams the reply. When `thenSpeak` is true, plays TTS and then
    /// drives the overlay cursor to any POINT target Claude emitted.
    func runTurn(userPrompt: String, thenSpeak: Bool = false) {
        guard !isRunningTurn else { return }
        currentTask?.cancel()
        turnGeneration += 1
        let thisTurn = turnGeneration
        isRunningTurn = true
        state = thenSpeak ? .thinking : state
        streamingText = ""
        lastError = nil

        currentTask = Task { @MainActor in
            defer {
                // Only clear the flag if this task is still the current
                // generation. If the user interrupted us, cancelCurrentTurn
                // already bumped the counter + reset isRunningTurn, and a
                // new turn may already be underway.
                if self.turnGeneration == thisTurn {
                    self.isRunningTurn = false
                }
            }
            do {
                let manifest = try await ScreenCapture.captureAllDisplays()
                let binary = try ClaudeCLIRunner.locate()
                let runner = ClaudeCLIRunner(binaryURL: binary)
                let resume = SessionPersistence.shared.load()

                // Build one ClaudeCLIMessage containing every display's
                // JPEG + its labeled dimensions, so Claude can reason
                // about multi-monitor layouts and emit :screenN.
                let contentImages = manifest.screens.map {
                    ClaudeCLIMessage.Image(
                        mediaType: "image/jpeg",
                        base64: $0.jpegData.base64EncodedString()
                    )
                }
                let labelText = manifest.screens
                    .map { "\($0.label) (image dimensions: \($0.widthPx)x\($0.heightPx) pixels)" }
                    .joined(separator: "\n")

                let message = ClaudeCLIMessage(
                    role: .user,
                    text: "\(labelText)\n\(userPrompt)",
                    images: contentImages
                )

                let result = try await runner.ask(
                    messages: [message],
                    systemPrompt: Self.systemPrompt,
                    model: selectedModel.rawValue,
                    resumeSessionId: resume
                ) { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        self?.streamingText = chunk.accumulatedText
                    }
                }

                if let sessionId = result.sessionId {
                    lastSessionId = sessionId
                    SessionPersistence.shared.save(sessionId: sessionId)
                }

                // Parse POINT tag + strip it before TTS.
                let parsed = PointTagParser.parse(result.text)
                streamingText = parsed.spokenText

                // Map the tag's screenshot-pixel coords to a global
                // AppKit CGPoint using the freshly-captured manifest.
                let mapped = PointCoordinateMapper.map(point: parsed.point, manifest: manifest)

                // Between every awaited step below, re-check the turn
                // generation. A cancelled turn must not go on to speak
                // or fly — textToSpeech.stop() resumes speak()'s
                // continuation normally (no CancellationError), so
                // without these guards the task falls through and
                // Esc / Control-Option-retry produces stale audio.
                guard self.turnGeneration == thisTurn, !Task.isCancelled else { return }

                if thenSpeak {
                    state = .speaking
                }

                // Fly as the speech starts, so "click here" and the arrow
                // land together. The arrow holds while state is .speaking.
                if let mapped {
                    overlayManager.flyTo(BlueCursorTarget(
                        globalLocation: mapped.globalLocation,
                        displayFrame: mapped.displayFrame,
                        label: mapped.label
                    ))
                }

                if thenSpeak {
                    await textToSpeech.speak(parsed.spokenText)
                }

                guard self.turnGeneration == thisTurn, !Task.isCancelled else { return }

                if self.turnGeneration == thisTurn {
                    state = .idle
                    scheduleResponseFade(for: thisTurn)
                }
            } catch is CancellationError {
                // cancelCurrentTurn already wrote state (and may have
                // started a new listening turn). Don't clobber it.
                if self.turnGeneration == thisTurn {
                    lastError = nil
                    state = .idle
                }
            } catch let error as ClaudeCLIError {
                if self.turnGeneration == thisTurn {
                    lastError = error.description
                    state = .idle
                }
            } catch let error as ScreenCaptureError {
                guard self.turnGeneration == thisTurn else { return }
                if isTCCDeclinedError(error) {
                    lastError = nil
                    screenRecordingPermission.handleRuntimeTCCDenial()
                } else {
                    lastError = error.description
                }
                state = .idle
            } catch {
                if self.turnGeneration == thisTurn {
                    lastError = error.localizedDescription
                    state = .idle
                }
            }
        }
    }

    /// Text-input entry point kept for debugging + users without a mic.
    /// The name preserves the v0.1 "Test Claude" button wiring.
    func runTestTurn(userPrompt: String) {
        runTurn(userPrompt: userPrompt, thenSpeak: false)
    }

    func cancelCurrentTurn() {
        currentTask?.cancel()
        currentTask = nil
        pendingDispatch?.cancel()
        pendingDispatch = nil
        // Bump the generation so the cancelled task's defer/catch blocks
        // see they're no longer current and skip their state mutations.
        turnGeneration += 1
        textToSpeech.stop()
        dictationManager.cancelListening()
        overlayManager.reset()
        isRunningTurn = false
        streamingText = ""
        lastError = nil
        state = .idle
    }

    func clearConversation() {
        SessionPersistence.shared.clear()
        lastSessionId = nil
        streamingText = ""
        lastError = nil
    }

    func openClaudeCodeInstallPage() {
        guard let url = URL(string: "https://claude.com/claude-code") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - ElevenLabs settings

    /// Saves the user's ElevenLabs credentials to Keychain and hot-swaps
    /// the TTS backend. The next reply will play through the new voice
    /// without needing a relaunch.
    func saveElevenLabsSettings(apiKey: String, voiceId: String?) {
        _ = ElevenLabsConfig.saveToKeychain(apiKey: apiKey, voiceId: voiceId)
        textToSpeech.reloadConfiguration()
    }

    /// Removes ElevenLabs credentials from Keychain. Env vars + JSON
    /// file sources are left alone — only the Keychain slot is cleared.
    func clearElevenLabsSettings() {
        ElevenLabsConfig.clearKeychain()
        textToSpeech.reloadConfiguration()
    }

    // MARK: - Private

    private func isTCCDeclinedError(_ error: ScreenCaptureError) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("declined tcc")
            || text.contains("not authorized")
            || text.contains("screen recording")
            || text.contains("could not create image")
    }
}
