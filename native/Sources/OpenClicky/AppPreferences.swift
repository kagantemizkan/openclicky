//
//  AppPreferences.swift
//  The user's choices from the Settings window.
//

import AppKit
import Combine
import SwiftUI

enum CursorColor: String, CaseIterable, Identifiable {
    case blue, green, pink, orange, slate

    var id: String { rawValue }

    private var rgb: (Double, Double, Double) {
        switch self {
        case .blue: return (160, 218, 250)
        case .green: return (116, 196, 130)
        case .pink: return (214, 72, 150)
        case .orange: return (226, 124, 56)
        case .slate: return (74, 85, 115)
        }
    }

    var nsColor: NSColor {
        NSColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Whichever of black or white reads best on this colour.
    var usesDarkText: Bool {
        func linear(_ value: Double) -> Double {
            let v = value / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05)
    }

    var textColor: Color { usesDarkText ? .black : .white }

    var displayName: String {
        switch self {
        case .blue: return Strings.colorBlue
        case .green: return Strings.colorGreen
        case .pink: return Strings.colorPink
        case .orange: return Strings.colorOrange
        case .slate: return Strings.colorSlate
        }
    }
}

enum CursorSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var arrowWidth: CGFloat {
        switch self {
        case .small: return 15
        case .medium: return 20
        case .large: return 27
        }
    }
    var displayName: String {
        switch self {
        case .small: return Strings.sizeSmall
        case .medium: return Strings.sizeMedium
        case .large: return Strings.sizeLarge
        }
    }
}

enum CaptionSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var points: CGFloat {
        switch self {
        case .small: return 12
        case .medium: return 13
        case .large: return 16
        }
    }
    var displayName: String {
        switch self {
        case .small: return Strings.sizeSmall
        case .medium: return Strings.sizeMedium
        case .large: return Strings.sizeLarge
        }
    }
}

enum ReplyLength: String, CaseIterable, Identifiable {
    case short, detailed

    var id: String { rawValue }
    var displayName: String {
        self == .short ? Strings.replyShort : Strings.replyDetailed
    }
    /// Added to the system prompt. Short is the base prompt's own default.
    var promptNote: String {
        self == .short ? "" : " when more detail would help, you may use up to four sentences."
    }
}

/// The voices that can read a reply. The user orders them; the first that
/// can read a reply does, and each failure moves on to the next.
enum VoiceEngine: String, CaseIterable, Identifiable {
    case elevenLabs, ahenk, system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .ahenk: return "Ahenk Cep"
        case .system: return Strings.voiceSystem
        }
    }

    /// `saved` from older settings: unknown names dropped, new voices added.
    static func order(saved: [String]?) -> [VoiceEngine] {
        var order: [VoiceEngine] = []
        for engine in (saved ?? []).compactMap(VoiceEngine.init) where !order.contains(engine) {
            order.append(engine)
        }
        return order + allCases.filter { !order.contains($0) }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var cursorColor: CursorColor { didSet { defaults.set(cursorColor.rawValue, forKey: Key.color) } }
    @Published var cursorSize: CursorSize { didSet { defaults.set(cursorSize.rawValue, forKey: Key.size) } }
    @Published var captionSize: CaptionSize { didSet { defaults.set(captionSize.rawValue, forKey: Key.caption) } }
    @Published var replyLength: ReplyLength { didSet { defaults.set(replyLength.rawValue, forKey: Key.length) } }
    @Published var speaksReplies: Bool { didSet { defaults.set(speaksReplies, forKey: Key.speaks) } }
    @Published var enabledConnections: Set<String> {
        didSet { defaults.set(Array(enabledConnections), forKey: Key.connections) }
    }

    @Published private(set) var voiceOrder: [VoiceEngine] {
        didSet { defaults.set(voiceOrder.map(\.rawValue), forKey: Key.voiceOrder) }
    }
    @Published private(set) var disabledVoices: Set<VoiceEngine> {
        didSet { defaults.set(disabledVoices.map(\.rawValue), forKey: Key.disabledVoices) }
    }

    var enabledVoices: [VoiceEngine] {
        voiceOrder.filter { !disabledVoices.contains($0) }
    }

    /// Moves a voice up (-1) or down (+1) the order.
    func moveVoice(_ engine: VoiceEngine, by offset: Int) {
        guard let index = voiceOrder.firstIndex(of: engine), voiceOrder.indices.contains(index + offset) else { return }
        voiceOrder.swapAt(index, index + offset)
    }

    /// At least one voice stays on. "Read replies aloud" is what silences them.
    func setVoice(_ engine: VoiceEngine, enabled: Bool) {
        if enabled {
            disabledVoices.remove(engine)
        } else if enabledVoices != [engine] {
            disabledVoices.insert(engine)
        }
    }

    private enum Key {
        static let voiceOrder = "com.proyecto26.openclicky.voiceOrder"
        static let disabledVoices = "com.proyecto26.openclicky.disabledVoices"
        static let color = "com.proyecto26.openclicky.cursorColor"
        static let size = "com.proyecto26.openclicky.cursorSize"
        static let caption = "com.proyecto26.openclicky.captionSize"
        static let length = "com.proyecto26.openclicky.replyLength"
        static let speaks = "com.proyecto26.openclicky.speaksReplies"
        static let connections = "com.proyecto26.openclicky.enabledConnections"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cursorColor = defaults.string(forKey: Key.color).flatMap(CursorColor.init) ?? .blue
        cursorSize = defaults.string(forKey: Key.size).flatMap(CursorSize.init) ?? .medium
        captionSize = defaults.string(forKey: Key.caption).flatMap(CaptionSize.init) ?? .medium
        replyLength = defaults.string(forKey: Key.length).flatMap(ReplyLength.init) ?? .short
        speaksReplies = defaults.object(forKey: Key.speaks) as? Bool ?? true
        voiceOrder = VoiceEngine.order(saved: defaults.stringArray(forKey: Key.voiceOrder))
        disabledVoices = Set((defaults.stringArray(forKey: Key.disabledVoices) ?? []).compactMap(VoiceEngine.init))
        enabledConnections = defaults.stringArray(forKey: Key.connections).map(Set.init)
            ?? Set(MCPConnection.all.map(\.id))
    }

    func setConnection(_ id: String, enabled: Bool) {
        if enabled {
            enabledConnections.insert(id)
        } else {
            enabledConnections.remove(id)
        }
    }
}
