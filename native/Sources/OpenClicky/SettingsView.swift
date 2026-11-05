//
//  SettingsView.swift
//  Optional ElevenLabs voice. Renders inside the menu bar panel.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: OpenClickyViewModel
    let onClose: () -> Void

    @State private var apiKey = ""
    @State private var voiceId = ""
    @State private var saveStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help(Strings.back)
                .accessibilityLabel(Strings.back)
                Text(Strings.voiceSettings)
                    .font(.headline)
            }

            Text(Strings.voiceBody)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.apiKey).font(.caption).foregroundStyle(.secondary)
                SecureField("sk-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.voiceId).font(.caption).foregroundStyle(.secondary)
                TextField(ElevenLabsConfig.defaultVoiceId, text: $voiceId)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button(Strings.save, action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(Strings.clear, action: clear)
                Spacer()
                if let saveStatus {
                    Text(saveStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // The raw error stays actionable: 401 means a wrong key, and
            // voice_not_found a wrong voice id.
            if let error = viewModel.textToSpeech.lastBackendError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
