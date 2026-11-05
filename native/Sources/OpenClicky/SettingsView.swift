//
//  SettingsView.swift
//  The Settings window: general behaviour, the cursor's look, connections to
//  other apps, mouse and keyboard control, and voice.
//

import SwiftUI

enum SettingsWindow {
    /// Tabs in the toolbar, as macOS settings windows have them. The window
    /// takes each tab's height.
    @MainActor
    static func make(viewModel: OpenClickyViewModel) -> NSWindow {
        let preferences = viewModel.preferences
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = false

        func add<Content: View>(_ title: String, icon: String, height: CGFloat, _ content: Content) {
            let host = NSHostingController(rootView: content.frame(width: 480, height: height))
            host.sizingOptions = .preferredContentSize
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add(Strings.tabGeneral, icon: "gearshape", height: 290, GeneralSettings(
            viewModel: viewModel,
            overlay: viewModel.overlayManager,
            preferences: preferences
        ))
        add(Strings.tabAppearance, icon: "paintpalette", height: 640, AppearanceSettings(preferences: preferences))
        add(Strings.tabConnections, icon: "link", height: 420, ConnectionsSettings(preferences: preferences))
        add(Strings.tabControl, icon: "cursorarrow.click.2", height: 520, ControlSettings(
            viewModel: viewModel,
            preferences: preferences
        ))
        add(Strings.tabVoice, icon: "speaker.wave.2", height: 570, VoiceSettings(
            viewModel: viewModel,
            speech: viewModel.textToSpeech,
            preferences: preferences
        ))

        let window = NSWindow(contentViewController: tabs)
        window.title = Strings.settingsTitle
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

struct GeneralSettings: View {
    @ObservedObject var viewModel: OpenClickyViewModel
    @ObservedObject var overlay: OverlayManager
    @ObservedObject var preferences: AppPreferences

    var body: some View {
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
}

struct AppearanceSettings: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        VStack(spacing: 0) {
            // Stays in view while the settings below scroll.
            AppearancePreview(preferences: preferences)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            Divider()
            form
        }
    }

    private var form: some View {
        Form {
            Section(Strings.appearanceCursor) {
                ColorRow(title: Strings.color, selection: Binding(
                    get: { preferences.cursorColor },
                    set: { preferences.cursorColor = $0 ?? .blue }
                ))
                Picker(Strings.cursorSize, selection: $preferences.cursorSize) {
                    ForEach(CursorSize.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section(Strings.appearanceCaption) {
                ColorRow(
                    title: Strings.captionBackground,
                    selection: $preferences.captionColor,
                    followName: Strings.followCursor,
                    followColor: preferences.cursorColor
                )
                ColorRow(
                    title: Strings.captionText,
                    selection: $preferences.captionTextColor,
                    followName: Strings.autoColor,
                    followColor: preferences.captionStyle.background.usesDarkText
                        ? ThemeColor(red: 0, green: 0, blue: 0)
                        : ThemeColor(red: 255, green: 255, blue: 255)
                )
                Picker(Strings.captionSize, selection: $preferences.captionSize) {
                    ForEach(CaptionSize.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(Strings.captionFont, selection: $preferences.captionFont) {
                    ForEach(CaptionFont.allCases) { Text($0.displayName).tag($0) }
                }
                Slider(value: $preferences.captionOpacity, in: 0.5...1) {
                    Text(Strings.captionOpacity)
                }
                Slider(value: $preferences.captionCornerRadius, in: 0...20) {
                    Text(Strings.captionCorners)
                }
            }
            Section(Strings.appearanceDrawing) {
                ColorRow(
                    title: Strings.color,
                    selection: $preferences.drawingColor,
                    followName: Strings.followCursor,
                    followColor: preferences.cursorColor
                )
                Slider(value: $preferences.drawingLineWidth, in: 1...10) {
                    Text(Strings.lineWidth)
                }
                Picker(Strings.lineStyle, selection: $preferences.drawingLine) {
                    ForEach(LineStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(Strings.drawingLook, selection: $preferences.drawingLook) {
                    ForEach(DrawingLook.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(Strings.drawingEdge, isOn: $preferences.drawingHasEdge)
            }
            Section {
                HStack {
                    Spacer()
                    Button(Strings.resetAppearance, action: preferences.resetAppearance)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The cursor, chat box and a drawing, as they look with these settings.
struct AppearancePreview: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CursorArrow(width: preferences.cursorSize.arrowWidth, color: preferences.cursorColor)
            CursorCaptionView(
                content: .text(Strings.previewCaption),
                audioLevel: 0,
                style: preferences.captionStyle
            )
            .padding(.top, preferences.cursorSize.arrowWidth)
            Spacer(minLength: 0)
            ZStack {
                AnnotationStroke(path: AnnotationGeometry.path(
                    for: .circle(center: CGPoint(x: 34, y: 34), radius: 24),
                    look: preferences.drawingLook,
                    toView: { $0 }
                ), style: preferences.drawingStyle)
                AnnotationStroke(path: AnnotationGeometry.path(
                    for: .arrow(from: CGPoint(x: 66, y: 66), to: CGPoint(x: 122, y: 18)),
                    look: preferences.drawingLook,
                    toView: { $0 }
                ), style: preferences.drawingStyle)
            }
            .frame(width: 130, height: 76)
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .padding(.vertical, 6)
    }
}

/// The preset colours, an optional "follow" choice, and the system picker
/// for any other colour.
private struct ColorRow: View {
    let title: String
    @Binding var selection: ThemeColor?
    /// When set, nil is a choice, shown with this name and colour.
    var followName: String?
    var followColor: ThemeColor = .blue

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 5) {
                if let followName {
                    ColorSwatch(
                        color: followColor,
                        name: followName,
                        isSelected: selection == nil,
                        isFollow: true
                    ) { selection = nil }
                }
                ForEach(ThemeColor.allCases) { color in
                    ColorSwatch(
                        color: color,
                        name: color.displayName,
                        isSelected: selection == color
                    ) { selection = color }
                }
                ColorPicker(title, selection: Binding(
                    get: { (selection ?? followColor).color },
                    set: { selection = ThemeColor(NSColor($0)) }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        }
    }
}

private struct ColorSwatch: View {
    let color: ThemeColor
    let name: String
    let isSelected: Bool
    var isFollow = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.color)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                .overlay {
                    if isFollow {
                        Image(systemName: "link")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(color.textColor)
                    }
                }
                .padding(3)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Connections

struct ConnectionsSettings: View {
    @ObservedObject var preferences: AppPreferences

    @State private var definedServers: Set<String> = []

    var body: some View {
        Form {
            Section {
                ForEach(MCPConnection.all) { connection in
                    row(connection)
                    if definedServers.contains(connection.id), preferences.enabledConnections.contains(connection.id) {
                        Toggle(Strings.connectionCanEdit, isOn: Binding(
                            get: { !preferences.readOnlyConnections.contains(connection.id) },
                            set: { canEdit in
                                if canEdit {
                                    preferences.readOnlyConnections.remove(connection.id)
                                } else {
                                    preferences.readOnlyConnections.insert(connection.id)
                                }
                            }
                        ))
                        .padding(.leading, 34)
                        .controlSize(.small)
                    }
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
                    Text(isDefined ? Strings.connectionTools(connection.readTools.count + connection.writeTools.count) : Strings.connectionMissing)
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

// MARK: - Mouse and keyboard

struct ControlSettings: View {
    @ObservedObject var viewModel: OpenClickyViewModel
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.controlEnabled) {
                    Text(Strings.controlToggle)
                    Text(Strings.controlToggleDetail)
                }
                if preferences.controlEnabled, !viewModel.hasAccessibilityPermission {
                    HStack {
                        Label(Strings.controlNeedsPermission, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(Strings.controlOpenPermission, action: viewModel.openAccessibilitySettings)
                    }
                }
                Toggle(isOn: $preferences.controlInBrowsers) {
                    Text(Strings.controlBrowsers)
                    Text(Strings.controlBrowsersDetail)
                }
                .disabled(!preferences.controlEnabled)
            }
            Section(Strings.controlNeverTitle) {
                rule("xmark.octagon.fill", .red, Strings.controlNeverPayments)
                rule("xmark.octagon.fill", .red, Strings.controlNeverSecrets)
                rule("xmark.octagon.fill", .red, Strings.controlNeverApps)
            }
            Section(Strings.controlAsksTitle) {
                rule("questionmark.circle.fill", .orange, Strings.controlAsksRisky)
                rule("questionmark.circle.fill", .orange, Strings.controlAsksMessages)
            }
            Section {
                rule("stop.circle.fill", .secondary, Strings.controlStopHint)
            }
        }
        .formStyle(.grouped)
    }

    private func rule(_ icon: String, _ color: Color, _ text: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
    }
}

// MARK: - Voice

struct VoiceSettings: View {
    @ObservedObject var viewModel: OpenClickyViewModel
    @ObservedObject var speech: TextToSpeech
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
                ForEach(Array(preferences.voiceOrder.enumerated()), id: \.element) { index, engine in
                    voiceRow(engine, position: index)
                    if engine == .ahenk && !speech.isAhenkInstalled {
                        AhenkInstallRow(installer: speech.ahenkInstaller, speech: speech)
                    }
                }
                // The raw error stays actionable: 401 means a bad or used-up
                // key, and voice_not_found a wrong voice id.
                if let error = speech.lastBackendError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(Strings.voiceOrder)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Strings.voiceOrderFooter)
                    if let used = speech.lastUsedEngine {
                        Text(Strings.voiceLastUsed(used.displayName))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    /// What stops this voice from working now, if anything.
    private func problem(with engine: VoiceEngine) -> String? {
        switch engine {
        case .elevenLabs: return speech.elevenLabsConfig == nil ? Strings.voiceNeedsKey : nil
        case .ahenk: return speech.isAhenkInstalled ? nil : Strings.voiceNotInstalled
        case .system: return nil
        }
    }

    private func detail(of engine: VoiceEngine) -> String {
        switch engine {
        case .elevenLabs: return Strings.voiceElevenLabsDetail
        case .ahenk: return Strings.voiceAhenkDetail
        case .system: return Strings.voiceSystemDetail
        }
    }

    private func voiceRow(_ engine: VoiceEngine, position: Int) -> some View {
        let problem = problem(with: engine)
        let isOn = !preferences.disabledVoices.contains(engine)
        return HStack(spacing: 10) {
            VStack(spacing: 0) {
                Button { preferences.moveVoice(engine, by: -1) } label: {
                    Image(systemName: "chevron.up").frame(width: 18, height: 14)
                }
                .disabled(position == 0)
                .help(Strings.voiceMoveUp)
                .accessibilityLabel("\(engine.displayName), \(Strings.voiceMoveUp)")
                Button { preferences.moveVoice(engine, by: 1) } label: {
                    Image(systemName: "chevron.down").frame(width: 18, height: 14)
                }
                .disabled(position == preferences.voiceOrder.count - 1)
                .help(Strings.voiceMoveDown)
                .accessibilityLabel("\(engine.displayName), \(Strings.voiceMoveDown)")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .semibold))

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "\(position + 1). \(engine.displayName)")
                Text(problem ?? detail(of: engine))
                    .font(.caption)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
            }
            .opacity(isOn ? 1 : 0.5)

            Spacer(minLength: 8)

            Button {
                Task { await speech.preview(engine) }
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(problem != nil)
            .help(Strings.voiceTry)
            .accessibilityLabel("\(engine.displayName), \(Strings.voiceTry)")

            Toggle(engine.displayName, isOn: Binding(
                get: { isOn },
                set: { preferences.setVoice(engine, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(isOn && preferences.enabledVoices.count == 1)
        }
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

/// Installs the local Turkish voice, which downloads a lot, so only on request.
private struct AhenkInstallRow: View {
    @ObservedObject var installer: AhenkInstaller
    let speech: TextToSpeech

    var body: some View {
        HStack(spacing: 10) {
            switch installer.state {
            case .idle:
                Text(Strings.ahenkInstallDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(Strings.ahenkInstall, action: install)
                    .accessibilityLabel(Strings.ahenkInstallLabel)
            case .running(let step):
                ProgressView().controlSize(.small)
                Text(title(of: step))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(Strings.cancel, action: installer.cancel)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(Strings.ahenkInstallRetry, action: install)
            }
        }
    }

    private func install() {
        installer.install { speech.reloadLocalVoice() }
    }

    private func title(of step: AhenkInstaller.Step) -> String {
        switch step {
        case .tools: return Strings.ahenkStepTools
        case .packages: return Strings.ahenkStepPackages
        case .model: return Strings.ahenkStepModel
        }
    }
}
