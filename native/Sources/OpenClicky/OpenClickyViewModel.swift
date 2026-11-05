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

/// An app the tutor can be started for.
struct LessonChoice: Identifiable, Equatable {
    /// Bundle id, which identifies the app even without a connection.
    let id: String
    let appName: String
    let menuTitle: String
    let appURL: URL?
    let connection: MCPConnection?
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
    let sessions: SessionStore
    let preferences = AppPreferences.shared
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
    private var controlRounds = 0
    private var controlWatchdog: Task<Void, Never>?
    /// The app a request is being carried out in, whatever the user does meanwhile.
    private var controlApp: pid_t?
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

    /// See TutorMode. The global monitor exists only while the mode is on and
    /// watches mouse-up alone: never keyboard, and only that a click happened.
    @Published private(set) var isTutorMode = false
    private var tutorClickMonitor: Any?
    private var tutorSettleTask: Task<Void, Never>?
    private var tutorLookPending = false
    private var tutorAutomaticLooks = 0
    /// The app chosen when a lesson was started from a menu.
    @Published private(set) var lessonChoice: LessonChoice?
    /// A menu-started lesson has no goal yet, so clicks mustn't spend tokens
    /// until the user has said what they want to learn.
    private var lessonAwaitsGoal = false

    var lessonStatus: String {
        lessonChoice.map { Strings.lessonRunning($0.appName) } ?? Strings.lessonRunningGeneric
    }

    /// The front app, then each installed app with a connection.
    func lessonChoices() -> [LessonChoice] {
        var choices: [LessonChoice] = []
        let ownId = Bundle.main.bundleIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           let id = front.bundleIdentifier, id != ownId, let name = front.localizedName {
            choices.append(LessonChoice(
                id: id,
                appName: name,
                menuTitle: Strings.currentAppNamed(name),
                appURL: front.bundleURL,
                connection: MCPConnection.all.first { $0.bundleId == id }
            ))
        }
        for connection in MCPConnection.all where !choices.contains(where: { $0.id == connection.bundleId }) {
            guard let url = connection.appURL else { continue }
            choices.append(LessonChoice(
                id: connection.bundleId,
                appName: connection.displayName,
                menuTitle: connection.displayName,
                appURL: url,
                connection: connection
            ))
        }
        return choices
    }

    /// Brings the app forward and asks what to learn, in a session of its own.
    /// The greeting is local: it costs nothing until the user answers.
    func startLesson(_ choice: LessonChoice) {
        cancelCurrentTurn()
        sessions.startNew(name: Strings.lessonSessionName(choice.appName))
        setTutorMode(false)
        lessonChoice = choice
        setTutorMode(true)
        lessonAwaitsGoal = true

        if let url = choice.appURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }

        turnGeneration += 1
        let thisTurn = turnGeneration
        let greeting = Strings.lessonGreeting(choice.appName)
        streamingText = greeting
        state = .speaking
        currentTask = Task { @MainActor in
            if preferences.speaksReplies {
                await textToSpeech.speak(greeting)
            }
            guard turnGeneration == thisTurn, !Task.isCancelled else { return }
            state = .idle
            scheduleResponseFade(for: thisTurn)
        }
    }

    init(sessions: SessionStore? = nil) {
        self.sessions = sessions ?? SessionStore()
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

        // Closing a message also stops whatever is producing it. A lesson
        // stays on, and carries on from the next click.
        overlayManager.onDismissMessage = { [weak self] in self?.cancelCurrentTurn() }

        // Mirror state into OverlayManager so the cursor can show it
        // without OverlayManager depending on the view model.
        dictationManager.$partialTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in self?.overlayManager.partialTranscript = text }
            .store(in: &observations)
        $isTutorMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in self?.overlayManager.isLessonActive = active }
            .store(in: &observations)
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
    switch language because of a garbled transcript. in turkish, phrase yes/no questions with \
    the question particle (mı, mi, mu, mü) so they sound like questions when read aloud. \
    reply in one or two sentences, lowercase, \
    warm, conversational. your name is \
    OpenClicky, written exactly that way with the capital O and C — introduce yourself as \
    "hey, i'm OpenClicky" when a greeting is appropriate; every other word stays lowercase. \
    no emojis, no bullet lists, no markdown. reference specific things on screen when \
    relevant. if you want to flag a ui element, append a tag `[POINT:x,y:label]` at the end \
    where x,y are pixel coordinates in the screenshot's pixel space and label is 1-3 words. \
    if pointing wouldn't help, omit the tag. you can also draw on the screen with up to three \
    tags at the end, in the same pixel space: `[CIRCLE:x,y,radius]` around one thing, \
    `[BOX:x,y,width,height]` around a group or area with x,y its top left, and \
    `[ARROW:x1,y1,x2,y2]` from one place to another, for a drag or a direction. add `:screenN` \
    before the closing bracket when it isn't screen1. draw only when it explains more than \
    pointing would, like several things at once or where to drag, and make shapes fit closely \
    around what they mark. the user sees the drawings, so don't describe them.
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
        resumePendingTutorLook()
    }

    private func finishListening() {
        state = .thinking
        dictationManager.stopListening()
        // dictationManager will call onFinalTranscript once the STT pipeline
        // delivers; that callback fires runTurnFromVoice below.
    }

    // MARK: - Tutor mode

    func setTutorMode(_ enabled: Bool) {
        guard enabled != isTutorMode else { return }
        isTutorMode = enabled
        tutorAutomaticLooks = 0
        tutorLookPending = false
        tutorSettleTask?.cancel()
        tutorSettleTask = nil
        if !enabled {
            lessonChoice = nil
            lessonAwaitsGoal = false
        }

        if enabled {
            tutorClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.overlayManager.clearLabel()
                    self?.scheduleTutorLook()
                }
            }
        } else if let monitor = tutorClickMonitor {
            NSEvent.removeMonitor(monitor)
            tutorClickMonitor = nil
        }
        logger.info("Tutor mode \(enabled ? "on" : "off", privacy: .public)")
    }

    /// Looks once the UI has settled after the latest click.
    private func scheduleTutorLook() {
        tutorSettleTask?.cancel()
        tutorSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TutorMode.settleSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isTutorMode, !self.lessonAwaitsGoal else { return }
            // Busy talking or thinking: look again when this turn ends.
            guard self.state == .idle, !self.isRunningTurn, self.pendingDispatch == nil else {
                self.tutorLookPending = true
                return
            }
            self.tutorAutomaticLooks += 1
            guard self.tutorAutomaticLooks <= TutorMode.maxAutomaticLooks else {
                self.setTutorMode(false)
                self.lastError = Strings.tutorLimitReached(TutorMode.maxAutomaticLooks)
                return
            }
            self.runTurn(userPrompt: TutorMode.lookPrompt, thenSpeak: true)
        }
    }

    /// Catches a click that arrived while the finished turn was busy.
    private func resumePendingTutorLook() {
        guard tutorLookPending else { return }
        tutorLookPending = false
        scheduleTutorLook()
    }

    private func runTurnFromVoice(userPrompt: String) {
        // Speaking answers any click made meanwhile, and shows they're present.
        tutorLookPending = false
        tutorSettleTask?.cancel()
        tutorAutomaticLooks = 0

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
        overlayManager.show([])
        if userPrompt != TutorMode.lookPrompt { lessonAwaitsGoal = false }
        let isContinuation = userPrompt.hasPrefix(ComputerControl.continuePrefix)
        if !isContinuation {
            controlRounds = 0
            controlApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        // Only a person's request can move the mouse: never an automatic look,
        // and never while a lesson has the user doing the clicking.
        let canControl = preferences.controlEnabled
            && accessibilityPermission.isGranted
            && !isTutorMode
            && userPrompt != TutorMode.lookPrompt
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        currentTask = Task { @MainActor in
            var continuesControl = false
            defer {
                if self.turnGeneration == thisTurn { self.overlayManager.thinkingDetail = nil }
                // Only clear the flag if this task is still the current
                // generation. If the user interrupted us, cancelCurrentTurn
                // already bumped the counter + reset isRunningTurn, and a
                // new turn may already be underway.
                if self.turnGeneration == thisTurn {
                    self.isRunningTurn = false
                    if !continuesControl { self.endControlChain() }
                }
            }
            do {
                let manifest = try await ScreenCapture.captureAllDisplays()
                let binary = try ClaudeCLIRunner.locate()
                let runner = ClaudeCLIRunner(binaryURL: binary)
                let resume = sessions.resumeIdForNextTurn()

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

                // Automatic looks stay read-only: the screen starts those, not the user.
                let isUserTurn = userPrompt != TutorMode.lookPrompt
                let canEdit: (MCPConnection) -> Bool = { [preferences] connection in
                    isUserTurn && !preferences.readOnlyConnections.contains(connection.id)
                }
                let attached = MCPConnections.turnConfig(
                    for: MCPConnections.connections(
                        enabled: preferences.enabledConnections,
                        frontmostBundleId: frontmost,
                        lessonConnection: lessonChoice?.connection
                    ),
                    canEdit: canEdit
                )

                let result = try await runner.ask(
                    messages: [message],
                    systemPrompt: TutorMode.systemPrompt(
                        base: Self.systemPrompt + preferences.replyLength.promptNote
                            + (canControl ? ComputerControl.promptRules : ""),
                        active: isTutorMode,
                        lessonApp: lessonChoice?.appName,
                        connectedApps: attached?.connected.map(\.displayName) ?? [],
                        editableApps: attached?.connected.filter(canEdit).map(\.displayName) ?? []
                    ),
                    model: selectedModel.rawValue,
                    resumeSessionId: resume,
                    mcp: attached?.config
                ) { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        guard let self, self.turnGeneration == thisTurn else { return }
                        self.streamingText = TutorMode.displayText(chunk.accumulatedText)
                        if let tool = chunk.activeTool, let app = MCPConnection.owner(ofTool: tool) {
                            self.overlayManager.thinkingDetail = Strings.lookingAt(app.displayName)
                        }
                    }
                }

                sessions.recordTurn(
                    claudeSessionId: result.sessionId,
                    usage: result.usage,
                    contextTokens: result.contextTokens,
                    prompt: userPrompt == TutorMode.lookPrompt || isContinuation ? nil : userPrompt
                )

                guard self.turnGeneration == thisTurn, !Task.isCancelled else { return }

                let reply = TutorMode.parse(result.text)
                if reply.shouldStart { setTutorMode(true) }
                if reply.isFinished { setTutorMode(false) }

                // Nothing to say yet: stay silent until the next click.
                if reply.shouldWait {
                    streamingText = ""
                    state = .idle
                    Task { @MainActor [weak self] in self?.resumePendingTutorLook() }
                    return
                }

                // Strip control, drawing and POINT tags before TTS.
                let control = ControlTagParser.parse(reply.text)
                let drawing = DrawTagParser.parse(control.text)
                let parsed = PointTagParser.parse(drawing.text)
                streamingText = parsed.spokenText

                // Map the tags' screenshot-pixel coords to global AppKit
                // coordinates using the freshly-captured manifest.
                let mapped = PointCoordinateMapper.map(point: parsed.point, manifest: manifest)
                let annotations = PointCoordinateMapper.annotations(from: drawing.tags, manifest: manifest)

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
                let display = mapped?.displayFrame ?? annotations.first.flatMap { first in
                    manifest.screens.first { first.isOn($0.displayFrame) }?.displayFrame
                }
                if let display, let spot = ScreenAnnotation.cursorSpot(
                    pointing: mapped?.globalLocation,
                    annotations: annotations,
                    display: display
                ) {
                    overlayManager.flyTo(BlueCursorTarget(
                        globalLocation: spot,
                        displayFrame: display,
                        label: mapped?.label
                    ))
                }
                overlayManager.show(annotations)

                if thenSpeak, preferences.speaksReplies {
                    await textToSpeech.speak(parsed.spokenText)
                }

                guard self.turnGeneration == thisTurn, !Task.isCancelled else { return }

                if canControl, !control.actions.isEmpty {
                    continuesControl = await carryOut(control.actions, manifest: manifest, turn: thisTurn)
                    guard self.turnGeneration == thisTurn, !Task.isCancelled else { return }
                    if continuesControl { return }
                }

                if self.turnGeneration == thisTurn {
                    state = .idle
                    scheduleResponseFade(for: thisTurn)
                    // After the defer above clears isRunningTurn.
                    Task { @MainActor [weak self] in self?.resumePendingTutorLook() }
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
                    if error.description.contains("No conversation found") {
                        sessions.forgetClaudeSession()
                        lastError = Strings.sessionGone
                    } else {
                        lastError = error.description
                    }
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

    // MARK: - Claude's own cursor

    /// Runs one reply's actions. True when another round follows with a fresh
    /// screenshot, so the chain and its stop-watching stay on.
    private func carryOut(_ actions: [ControlAction], manifest: CaptureManifest, turn: Int) async -> Bool {
        state = .thinking
        watchControl()
        let executor = ControlExecutor(
            poster: SystemControlPoster(),
            inspector: SystemControlInspector(),
            allowsBrowsers: preferences.controlInBrowsers,
            onStep: { [weak self] point, isDrag, display in
                guard let overlay = self?.overlayManager else { return }
                overlay.flyTo(BlueCursorTarget(globalLocation: point, displayFrame: display, label: nil))
                // A ring marks a click. A drag shows itself as the cursor moves.
                overlay.show(isDrag ? [] : [ScreenAnnotation(shape: .circle(center: point, radius: 14))])
            },
            onDrag: { [weak self] end in
                self?.overlayManager.glide(to: end, duration: ControlTiming.dragSeconds)
            },
            approve: { [weak self] question in
                await self?.askControlApproval(question) ?? false
            }
        )
        let report = await executor.run(
            actions,
            manifest: manifest,
            primaryHeight: NSScreen.screens.first?.frame.height ?? 0,
            app: controlApp
        )
        controlApp = report.app
        guard turnGeneration == turn, !Task.isCancelled else { return false }

        controlRounds += 1
        guard controlRounds < ComputerControl.maxRounds else {
            lastError = Strings.controlLimit(ComputerControl.maxRounds)
            return false
        }
        // After this turn's task has finished and cleared isRunningTurn. The UI
        // gets a moment to react so the next screenshot shows the result.
        let prompt = ComputerControl.continuePrompt(report: report.lines)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, self.turnGeneration == turn, !self.isRunningTurn else { return }
            self.runTurn(userPrompt: prompt, thenSpeak: true)
        }
        return true
    }

    /// Esc stops everything, from the first action until the request is
    /// finished. This reads whether Esc is down right now. It doesn't see other keys.
    private func watchControl() {
        guard controlWatchdog == nil else { return }
        overlayManager.isControlling = true
        controlWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled else { return }
                if CGEventSource.keyState(.hidSystemState, key: 53) {
                    self.stopControl(Strings.controlStoppedEsc)
                    return
                }
            }
        }
    }

    private func stopControl(_ message: String) {
        cancelCurrentTurn()
        streamingText = message
        scheduleResponseFade(for: turnGeneration)
    }

    private func endControlChain() {
        controlWatchdog?.cancel()
        controlWatchdog = nil
        overlayManager.isControlling = false
    }

    /// The system's own alert, which nothing on screen can answer for the user:
    /// clicks on this app are refused. Refuse is the default button.
    private func askControlApproval(_ question: String) async -> Bool {
        let previous = NSWorkspace.shared.frontmostApplication
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.controlAskTitle
        alert.informativeText = question
        alert.addButton(withTitle: Strings.controlRefuse)
        alert.addButton(withTitle: Strings.controlAllowOnce)
        NSApp.activate(ignoringOtherApps: true)
        let approved = alert.runModal() == .alertSecondButtonReturn
        previous?.activate()
        // Give focus time to return before anything is typed.
        try? await Task.sleep(nanoseconds: 300_000_000)
        return approved
    }

    /// A typed question, answered just like a spoken one.
    func ask(_ question: String) {
        tutorLookPending = false
        tutorSettleTask?.cancel()
        tutorAutomaticLooks = 0
        runTurn(userPrompt: question, thenSpeak: true)
    }

    func cancelCurrentTurn() {
        currentTask?.cancel()
        currentTask = nil
        pendingDispatch?.cancel()
        pendingDispatch = nil
        // Bump the generation so the cancelled task's defer/catch blocks
        // see they're no longer current and skip their state mutations.
        turnGeneration += 1
        endControlChain()
        textToSpeech.stop()
        dictationManager.cancelListening()
        overlayManager.reset()
        isRunningTurn = false
        streamingText = ""
        lastError = nil
        state = .idle
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
