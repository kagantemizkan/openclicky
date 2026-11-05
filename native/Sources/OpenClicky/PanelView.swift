//
//  PanelView.swift
//  SwiftUI content for the menu-bar panel. Minimal surface for v0.1 —
//  install-CLI banner, a prompt input, a "Test Claude" button, and a
//  streaming response area.
//

import SwiftUI

struct PanelView: View {
    @ObservedObject var viewModel: OpenClickyViewModel
    let onDismiss: () -> Void

    @State private var prompt: String = "what's on my screen right now?"
    @State private var showingSettings: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08)).padding(.horizontal, 16)

            Group {
                if showingSettings {
                    SettingsView(viewModel: viewModel) { showingSettings = false }
                } else if !viewModel.isClaudeCLIAvailable {
                    installBanner
                } else if !viewModel.hasScreenRecordingPermission {
                    screenRecordingBanner
                } else if viewModel.requiresRelaunchForScreenRecording {
                    relaunchBanner
                } else if !viewModel.hasAccessibilityPermission {
                    accessibilityBanner
                } else if let problem = viewModel.dictationPermissionProblem {
                    dictationPermissionBanner(problem)
                } else {
                    readyBody
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            Spacer(minLength: 0)
            footer
        }
        .frame(width: 360, height: 420)
        .background(Color(red: 0.09, green: 0.09, blue: 0.09))
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isClaudeCLIAvailable ? Color.green : Color.yellow)
                    .frame(width: 8, height: 8)
                Text("OpenClicky")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            Spacer()
            Button { showingSettings.toggle() } label: {
                Image(systemName: showingSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(showingSettings ? .white : .white.opacity(0.6))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(showingSettings ? 0.15 : 0.08)))
            }
            .buttonStyle(.plain)
            .help("Settings")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var installBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text("Install Claude Code")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text("OpenClicky uses your Claude Code login to chat — no extra keys needed. Install the CLI, sign in once, then come back here.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                viewModel.openClaudeCodeInstallPage()
            } label: {
                Text("Open install page")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.4), lineWidth: 1))
        )
    }

    private var screenRecordingBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "camera.metering.unknown")
                    .foregroundColor(.orange)
                Text("Grant Screen Recording")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text("OpenClicky needs Screen Recording to capture your display before asking Claude. The banner clears automatically as soon as you grant — no restart needed.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    viewModel.requestScreenRecordingPermission()
                } label: {
                    Text("Ask macOS")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue))
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.openScreenRecordingSettings()
                } label: {
                    Text("Open settings")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4), lineWidth: 1))
        )
    }

    /// Shown when the mic or speech recognition TCC was denied mid-
    /// session. Appears only after the user has actually tried to
    /// push-to-talk — pre-flight isn't valuable here because macOS
    /// will show its own request dialog on first attempt.
    private func dictationPermissionBanner(_ problem: DictationPermissionProblem) -> some View {
        let (title, body, openSettings): (String, String, () -> Void) = {
            switch problem {
            case .microphoneAccessDenied:
                return (
                    "Microphone access needed",
                    "OpenClicky can't hear you without mic access. Open System Settings and enable OpenClicky under Privacy & Security → Microphone.",
                    viewModel.openMicrophoneSettings
                )
            case .speechRecognitionDenied:
                return (
                    "Speech recognition needed",
                    "OpenClicky uses Apple Speech to transcribe your voice locally. Open System Settings and enable OpenClicky under Privacy & Security → Speech Recognition.",
                    viewModel.openSpeechRecognitionSettings
                )
            }
        }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "mic.slash")
                    .foregroundColor(.orange)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text(body)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: viewModel.retryPermissions) {
                    Text("Retry")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue))
                }
                .buttonStyle(.plain)

                Button(action: openSettings) {
                    Text("Open settings")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4), lineWidth: 1))
        )
    }

    /// Shown when push-to-talk can't observe modifier keys because
    /// Accessibility isn't granted. Same grammar as the screen-
    /// recording banner — two buttons, system-keyed copy.
    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .foregroundColor(.orange)
                Text("Grant Accessibility")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text("OpenClicky needs Accessibility to listen for the push-to-talk hotkey (hold Control and Option together). The banner clears automatically as soon as you grant — no restart needed.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    viewModel.requestAccessibilityPermission()
                } label: {
                    Text("Ask macOS")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue))
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.openAccessibilitySettings()
                } label: {
                    Text("Open settings")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4), lineWidth: 1))
        )
    }

    /// Shown when Screen Recording is already granted in System Settings
    /// but this process was launched before the grant, so ScreenCaptureKit
    /// has cached a denial that can't be cleared without a restart.
    private var relaunchBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundColor(.blue)
                Text("Almost ready — relaunch OpenClicky")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text("Screen Recording is granted, but macOS only activates it for apps launched after the grant. Click Quit in the footer, then reopen OpenClicky.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.4), lineWidth: 1))
        )
    }

    private var readyBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            pushToTalkStateRow
            if viewModel.state == .listening {
                waveformBar
            }

            TextField("", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                .lineLimit(2...4)

            HStack(spacing: 8) {
                Button {
                    viewModel.runTestTurn(userPrompt: prompt)
                } label: {
                    Text(viewModel.isRunningTurn ? "Running…" : "Test Claude")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isRunningTurn || prompt.trimmingCharacters(in: .whitespaces).isEmpty)

                if viewModel.isRunningTurn {
                    Button {
                        viewModel.cancelCurrentTurn()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Cancel current turn (Esc)")
                }

                Spacer()

                Button(action: viewModel.clearConversation) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Clear conversation history")
            }

            if !viewModel.streamingText.isEmpty {
                ScrollView {
                    Text(viewModel.streamingText)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            }

            Toggle("Tutor mode: looks again after each click", isOn: Binding(
                get: { viewModel.isTutorMode },
                set: { viewModel.setTutorMode($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.8))

            if let error = viewModel.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// State row: text + pulsing dot that reflects idle / listening /
    /// thinking / speaking. Sits above the typed-prompt affordance so
    /// voice is the primary entry but typing is always available.
    private var pushToTalkStateRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stateDotColor)
                .frame(width: 8, height: 8)
                .shadow(color: stateDotColor.opacity(0.6), radius: 4)
            Text(stateLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            hotkeyHint
        }
    }

    /// Key capsules that spell out the chord by name rather than relying
    /// on the ⌃⌥ glyphs — those confuse users on non-Apple keyboards
    /// where Option is labeled "Alt" and Control has no standard symbol.
    private var hotkeyHint: some View {
        HStack(spacing: 3) {
            keyCap("Control")
            Text("+")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
            keyCap("Option")
        }
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.65))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            )
    }

    private var stateLabel: String {
        switch viewModel.state {
        case .idle:      return "Ready. Hold Control + Option to talk."
        case .listening: return viewModel.dictationManager.partialTranscript.isEmpty
            ? "Listening…"
            : viewModel.dictationManager.partialTranscript
        case .thinking:  return "Thinking…"
        case .speaking:  return "Speaking…"
        }
    }

    private var stateDotColor: Color {
        switch viewModel.state {
        case .idle:      return .green
        case .listening: return .red
        case .thinking:  return .blue
        case .speaking:  return .purple
        }
    }

    /// 12-bar horizontal waveform that tracks the dictation manager's
    /// smoothed audio level. Each bar uses the same level value with a
    /// slight phase offset so the row feels alive without needing an
    /// actual FFT.
    private var waveformBar: some View {
        let level = max(0.05, viewModel.currentAudioLevel)
        return HStack(spacing: 3) {
            ForEach(0..<12, id: \.self) { index in
                let phase = sin(Double(index) * 0.7 + Date().timeIntervalSince1970 * 4) * 0.3 + 0.7
                let height = max(4, level * 32 * CGFloat(phase))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 3, height: height)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 32)
        .animation(.easeOut(duration: 0.1), value: viewModel.currentAudioLevel)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let version = viewModel.claudeVersion {
                Text("claude \(version)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            } else {
                Text("claude CLI: probing…")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }
            modelPicker
            Spacer()
            if let sessionId = viewModel.lastSessionId {
                Text("session \(sessionId.prefix(8))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.25))
    }

    private var modelPicker: some View {
        Menu {
            ForEach(ClaudeModel.allCases) { model in
                Button {
                    viewModel.selectedModel = model
                } label: {
                    HStack {
                        Text(model.displayName)
                        if model == viewModel.selectedModel {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.selectedModel.displayName)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Select Claude model")
    }
}
