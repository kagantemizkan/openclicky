//
//  SettingsView.swift
//  The Settings window: general behaviour, the cursor's look, voice, and
//  read-only connections to other apps.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: OpenClickyViewModel
    @ObservedObject var overlay: OverlayManager
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        TabView {
            general
                .tabItem { Label(Strings.tabGeneral, systemImage: "gearshape") }
            appearance
                .tabItem { Label(Strings.tabAppearance, systemImage: "paintpalette") }
            ConnectionsSettings(preferences: preferences)
                .tabItem { Label(Strings.tabConnections, systemImage: "link") }
            VoiceSettings(viewModel: viewModel, preferences: preferences)
                .tabItem { Label(Strings.tabVoice, systemImage: "speaker.wave.2") }
        }
        .frame(width: 480, height: 420)
    }

    private var general: some View {
        Form {
            Picker(Strings.model, selection: $viewModel.selectedModel) {
                ForEach(ClaudeModel.allCases) { Text($0.displayName).tag($0) }
            }
            Picker(Strings.replyLength, selection: $preferences.replyLength) {
                ForEach(ReplyLength.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle(isOn: $overlay.showsCursorAtRest) {
                Text(Strings.cursorAtRest)
                Text(Strings.cursorAtRestDetail)
            }
            LabeledContent(Strings.talkShortcut) {
                Text(verbatim: "Control + Option")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var appearance: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    CursorArrow(width: preferences.cursorSize.arrowWidth, color: preferences.cursorColor)
                    CursorCaptionView(
                        content: .text(Strings.previewCaption),
                        audioLevel: 0,
                        color: preferences.cursorColor,
                        textSize: preferences.captionSize.points
                    )
                    .padding(.top, preferences.cursorSize.arrowWidth)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                .padding(.vertical, 6)
            }
            Section {
                LabeledContent(Strings.color) {
                    HStack(spacing: 10) {
                        ForEach(CursorColor.allCases) { color in
                            ColorSwatch(color: color, isSelected: preferences.cursorColor == color) {
                                preferences.cursorColor = color
                            }
                        }
                    }
                }
                Picker(Strings.cursorSize, selection: $preferences.cursorSize) {
                    ForEach(CursorSize.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(Strings.captionSize, selection: $preferences.captionSize) {
                    ForEach(CaptionSize.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ColorSwatch: View {
    let color: CursorColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.color)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                .padding(3)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help(color.displayName)
        .accessibilityLabel(color.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Connections

private struct ConnectionsSettings: View {
    @ObservedObject var preferences: AppPreferences

    @State private var definedServers: Set<String> = []

    var body: some View {
        Form {
            Section {
                ForEach(MCPConnection.all) { connection in
                    row(connection)
                }
            } footer: {
                Text(Strings.connectionsFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { definedServers = MCPConnections.definedServerNames() }
    }

    private func row(_ connection: MCPConnection) -> some View {
        let isDefined = definedServers.contains(connection.id)
        return Toggle(isOn: Binding(
            get: { isDefined && preferences.enabledConnections.contains(connection.id) },
            set: { preferences.setConnection(connection.id, enabled: $0) }
        )) {
            HStack(spacing: 10) {
                appIcon(connection)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: connection.displayName)
                    Text(isDefined ? Strings.readOnlyTools(connection.readTools.count) : Strings.connectionMissing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!isDefined)
    }

    @ViewBuilder
    private func appIcon(_ connection: MCPConnection) -> some View {
        if let url = connection.appURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "app.dashed")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }
}

// MARK: - Voice

private struct VoiceSettings: View {
    @ObservedObject var viewModel: OpenClickyViewModel
    @ObservedObject var preferences: AppPreferences

    @State private var apiKey = ""
    @State private var voiceId = ""
    @State private var saveStatus: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.speaksReplies) {
                    Text(Strings.speakReplies)
                    Text(Strings.speakRepliesDetail)
                }
            }
            Section {
                SecureField(Strings.apiKey, text: $apiKey, prompt: Text(verbatim: "sk-…"))
                TextField(Strings.voiceId, text: $voiceId, prompt: Text(ElevenLabsConfig.defaultVoiceId))
                HStack {
                    if let saveStatus {
                        Text(saveStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(Strings.clear, action: clear)
                    Button(Strings.save, action: save)
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                // The raw error stays actionable: 401 means a wrong key, and
                // voice_not_found a wrong voice id.
                if let error = viewModel.textToSpeech.lastBackendError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(Strings.voiceSettings)
            } footer: {
                Text(Strings.voiceBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadCurrentValues)
    }

    private func loadCurrentValues() {
        let existing = viewModel.textToSpeech.elevenLabsConfig
        apiKey = existing?.apiKey ?? ""
        voiceId = existing?.voiceId == ElevenLabsConfig.defaultVoiceId ? "" : (existing?.voiceId ?? "")
    }

    private func save() {
        viewModel.saveElevenLabsSettings(
            apiKey: apiKey,
            voiceId: voiceId.trimmingCharacters(in: .whitespaces).isEmpty ? nil : voiceId
        )
        saveStatus = Strings.saved
    }

    private func clear() {
        viewModel.clearElevenLabsSettings()
        apiKey = ""
        voiceId = ""
        saveStatus = Strings.cleared
    }
}
