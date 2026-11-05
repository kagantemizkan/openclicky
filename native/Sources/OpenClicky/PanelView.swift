//
//  PanelView.swift
//  The menu bar panel. Built from system controls and semantic colours so
//  it follows light and dark mode, the accent colour and accessibility
//  settings; the brand blue appears only in the cursor logo.
//

import SwiftUI

struct PanelView: View {
    @ObservedObject var viewModel: OpenClickyViewModel
    @ObservedObject var sessions: SessionStore
    @ObservedObject var preferences = AppPreferences.shared
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    /// Reports the content's height so the window can fit it.
    let onHeightChange: (CGFloat) -> Void

    @State private var prompt = ""

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                if let notice = permissionNotice {
                    notice.padding(14)
                } else {
                    ready
                }
            }
            Divider()
            footer
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: \.size.height, action: onHeightChange)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            CursorArrow(width: 14, color: preferences.cursorColor)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "OpenClicky")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(Strings.settings)
            .accessibilityLabel(Strings.settings)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusText: String {
        switch viewModel.state {
        case .idle:
            return Strings.ready
        case .listening:
            let transcript = viewModel.dictationManager.partialTranscript
            return transcript.isEmpty ? Strings.listeningStatus : transcript
        case .thinking:
            return Strings.thinkingStatus
        case .speaking:
            return Strings.speakingStatus
        }
    }

    // MARK: - Ready state

    private var ready: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            SessionSection(sessions: sessions)
                .padding(14)
            Divider()
            askField
                .padding(14)
            Divider()
            options
                .padding(14)
            if let error = viewModel.lastError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
        }
    }

    private var askField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(Strings.askPlaceholder, text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(send)

            if viewModel.isRunningTurn {
                Button(action: viewModel.cancelCurrentTurn) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(Strings.stop)
                .accessibilityLabel(Strings.stop)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(trimmedPrompt.isEmpty)
                .help(Strings.send)
                .accessibilityLabel(Strings.send)
            }
        }
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        guard !trimmedPrompt.isEmpty, !viewModel.isRunningTurn else { return }
        viewModel.ask(trimmedPrompt)
        prompt = ""
        // Out of the way, so the cursor is seen and the panel isn't covering
        // what the question is about.
        onDismiss()
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.isTutorMode {
                OptionRow(title: viewModel.lessonStatus, detail: nil) {
                    Button(Strings.endLesson) { viewModel.setTutorMode(false) }
                        .controlSize(.small)
                }
            } else {
                OptionRow(title: Strings.tutorMode, detail: Strings.tutorMenuDetail) {
                    Menu(Strings.startLesson) {
                        ForEach(viewModel.lessonChoices()) { choice in
                            Button(choice.menuTitle) {
                                viewModel.startLesson(choice)
                                onDismiss()
                            }
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            OptionRow(title: Strings.model, detail: nil) {
                Picker(Strings.model, selection: $viewModel.selectedModel) {
                    ForEach(ClaudeModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(verbatim: viewModel.claudeVersion.map { "Claude Code \($0.replacingOccurrences(of: " (Claude Code)", with: ""))" } ?? "Claude Code")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button(Strings.quit) { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Permissions

    private var permissionNotice: PermissionNotice? {
        if !viewModel.isClaudeCLIAvailable {
            return PermissionNotice(
                symbol: "terminal", title: Strings.installTitle, message: Strings.installBody,
                primary: (Strings.installButton, viewModel.openClaudeCodeInstallPage)
            )
        }
        if !viewModel.hasScreenRecordingPermission {
            return PermissionNotice(
                symbol: "rectangle.dashed", title: Strings.screenTitle, message: Strings.screenBody,
                primary: (Strings.askMacOS, viewModel.requestScreenRecordingPermission),
                secondary: (Strings.openSettings, viewModel.openScreenRecordingSettings)
            )
        }
        if viewModel.requiresRelaunchForScreenRecording {
            return PermissionNotice(
                symbol: "arrow.clockwise", title: Strings.relaunchTitle, message: Strings.relaunchBody,
                primary: (Strings.quit, { NSApp.terminate(nil) })
            )
        }
        if !viewModel.hasAccessibilityPermission {
            return PermissionNotice(
                symbol: "keyboard", title: Strings.accessibilityTitle, message: Strings.accessibilityBody,
                primary: (Strings.askMacOS, viewModel.requestAccessibilityPermission),
                secondary: (Strings.openSettings, viewModel.openAccessibilitySettings)
            )
        }
        switch viewModel.dictationPermissionProblem {
        case .microphoneAccessDenied:
            return PermissionNotice(
                symbol: "mic.slash", title: Strings.micTitle, message: Strings.micBody,
                primary: (Strings.openSettings, viewModel.openMicrophoneSettings),
                secondary: (Strings.retry, viewModel.retryPermissions)
            )
        case .speechRecognitionDenied:
            return PermissionNotice(
                symbol: "waveform.slash", title: Strings.speechTitle, message: Strings.speechBody,
                primary: (Strings.openSettings, viewModel.openSpeechRecognitionSettings),
                secondary: (Strings.retry, viewModel.retryPermissions)
            )
        case nil:
            return nil
        }
    }
}

// MARK: - Sessions

private struct SessionSection: View {
    @ObservedObject var sessions: SessionStore

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isConfirmingDelete = false
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if isRenaming {
                    nameField
                } else {
                    picker
                }
                Button(action: startNew) {
                    Image(systemName: "plus")
                }
                .help(Strings.newSession)
                .accessibilityLabel(Strings.newSession)
                .disabled(isRenaming)
            }

            if isConfirmingDelete {
                deleteConfirmation
            } else {
                Text(usageLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(usageDetail)
            }
        }
    }

    private var picker: some View {
        Menu {
            ForEach(sessions.ordered) { session in
                Toggle(isOn: Binding(
                    get: { session.id == sessions.activeId },
                    set: { if $0 { sessions.activate(session.id) } }
                )) {
                    Text(session.name)
                    Text(Strings.usageLine(tokens: Strings.compact(session.usage.total), turns: session.turns))
                }
            }
            Divider()
            Button(Strings.newSession, action: startNew)
            Button(Strings.renameSession, action: startRenaming)
            Button(Strings.deleteSession, role: .destructive) { isConfirmingDelete = true }
        } label: {
            Text(sessions.active.name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Strings.session)
    }

    private var nameField: some View {
        TextField(Strings.sessionNamePlaceholder, text: $draftName)
            .textFieldStyle(.roundedBorder)
            .focused($nameFieldFocused)
            .onSubmit(finishRenaming)
            .onChange(of: nameFieldFocused) { _, focused in
                if !focused { finishRenaming() }
            }
    }

    private var deleteConfirmation: some View {
        HStack(spacing: 8) {
            Text(Strings.deleteQuestion)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(Strings.cancel) { isConfirmingDelete = false }
                .controlSize(.small)
            Button(Strings.delete, role: .destructive) {
                sessions.delete(sessions.activeId)
                isConfirmingDelete = false
            }
            .controlSize(.small)
        }
    }

    private var usageLine: String {
        let session = sessions.active
        guard session.turns > 0 else { return Strings.noTokensYet }
        return Strings.usageLine(tokens: Strings.compact(session.usage.total), turns: session.turns)
    }

    private var usageDetail: String {
        let session = sessions.active
        return Strings.usageDetail(
            input: Strings.compact(session.usage.input),
            cacheWrite: Strings.compact(session.usage.cacheWrite),
            cacheRead: Strings.compact(session.usage.cacheRead),
            output: Strings.compact(session.usage.output),
            context: Strings.compact(session.lastContextTokens)
        )
    }

    /// A new session asks for a name straight away. Leaving it blank is fine:
    /// it then takes its name from the first question.
    private func startNew() {
        isConfirmingDelete = false
        sessions.startNew()
        draftName = ""
        beginEditing()
    }

    private func startRenaming() {
        isConfirmingDelete = false
        draftName = sessions.active.name
        beginEditing()
    }

    private func beginEditing() {
        isRenaming = true
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func finishRenaming() {
        guard isRenaming else { return }
        sessions.rename(sessions.activeId, to: draftName)
        isRenaming = false
    }
}

// MARK: - Components

private struct OptionRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control()
        }
    }
}

private struct PermissionNotice: View {
    let symbol: String
    let title: String
    let message: String
    let primary: (String, () -> Void)
    var secondary: (String, () -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(primary.0, action: primary.1)
                    .buttonStyle(.borderedProminent)
                if let secondary {
                    Button(secondary.0, action: secondary.1)
                }
            }
        }
    }
}
