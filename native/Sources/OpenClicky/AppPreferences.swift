//
//  AppPreferences.swift
//  The user's choices from the Settings window.
//

import AppKit
import Combine
import SwiftUI

/// A colour the user picked, from the presets or anywhere else.
struct ThemeColor: Hashable, Identifiable {
    /// 0…255, sRGB.
    let red: Double
    let green: Double
    let blue: Double

    static let blue = ThemeColor(red: 160, green: 218, blue: 250)
    static let green = ThemeColor(red: 116, green: 196, blue: 130)
    static let pink = ThemeColor(red: 214, green: 72, blue: 150)
    static let orange = ThemeColor(red: 226, green: 124, blue: 56)
    static let slate = ThemeColor(red: 74, green: 85, blue: 115)
    static let allCases: [ThemeColor] = [.blue, .green, .pink, .orange, .slate]

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF),
            green: Double((value >> 8) & 0xFF),
            blue: Double(value & 0xFF)
        )
    }

    /// As saved: a hex value, or a preset's name from older settings.
    init?(stored: String) {
        let older: [String: ThemeColor] = ["blue": .blue, "green": .green, "pink": .pink, "orange": .orange, "slate": .slate]
        if let preset = older[stored] {
            self = preset
        } else {
            self.init(hex: stored)
        }
    }

    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: (srgb.redComponent * 255).rounded(),
            green: (srgb.greenComponent * 255).rounded(),
            blue: (srgb.blueComponent * 255).rounded()
        )
    }

    var id: String { hex }

    var hex: String {
        String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Whichever of black or white reads best on this colour.
    var usesDarkText: Bool {
        func linear(_ value: Double) -> Double {
            let v = value / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
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
        default: return hex
        }
    }
}

enum CaptionFont: String, CaseIterable, Identifiable {
    case system, rounded, serif, mono

    var id: String { rawValue }
    var design: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
    var displayName: String {
        switch self {
        case .system: return Strings.fontSystem
        case .rounded: return Strings.fontRounded
        case .serif: return Strings.fontSerif
        case .mono: return Strings.fontMono
        }
    }
}

enum LineStyle: String, CaseIterable, Identifiable {
    case solid, dashed, dotted

    var id: String { rawValue }
    func dash(lineWidth: CGFloat) -> [CGFloat] {
        switch self {
        case .solid: return []
        case .dashed: return [lineWidth * 3.5, lineWidth * 2.5]
        // With round caps, a zero-length dash draws a dot.
        case .dotted: return [0, lineWidth * 2.2]
        }
    }
    var displayName: String {
        switch self {
        case .solid: return Strings.lineSolid
        case .dashed: return Strings.lineDashed
        case .dotted: return Strings.lineDotted
        }
    }
}

enum DrawingLook: String, CaseIterable, Identifiable {
    case handDrawn, clean

    var id: String { rawValue }
    var displayName: String {
        self == .handDrawn ? Strings.lookHandDrawn : Strings.lookClean
    }
}

/// How the chat box under the cursor looks.
struct CaptionStyle: Equatable {
    var background: ThemeColor = .blue
    /// Nil picks black or white, whichever reads best on the background.
    var text: ThemeColor?
    var opacity: Double = 1
    var cornerRadius: CGFloat = 10
    var textSize: CGFloat = 13
    var font: CaptionFont = .system

    var textColor: Color { text?.color ?? background.textColor }
}

/// How circles, arrows and boxes look.
struct DrawingStyle: Equatable {
    var color: ThemeColor = .blue
    var lineWidth: CGFloat = 3
    var line: LineStyle = .solid
    var look: DrawingLook = .handDrawn
    var hasEdge = true
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

    @Published var cursorColor: ThemeColor { didSet { defaults.set(cursorColor.hex, forKey: Key.color) } }
    /// Nil follows the cursor's colour.
    @Published var captionColor: ThemeColor? { didSet { save(captionColor, forKey: Key.captionColor) } }
    /// Nil picks black or white, whichever reads best.
    @Published var captionTextColor: ThemeColor? { didSet { save(captionTextColor, forKey: Key.captionTextColor) } }
    @Published var captionOpacity: Double { didSet { defaults.set(captionOpacity, forKey: Key.captionOpacity) } }
    @Published var captionCornerRadius: Double { didSet { defaults.set(captionCornerRadius, forKey: Key.captionCornerRadius) } }
    @Published var captionFont: CaptionFont { didSet { defaults.set(captionFont.rawValue, forKey: Key.captionFont) } }
    /// Nil follows the cursor's colour.
    @Published var drawingColor: ThemeColor? { didSet { save(drawingColor, forKey: Key.drawingColor) } }
    @Published var drawingLineWidth: Double { didSet { defaults.set(drawingLineWidth, forKey: Key.drawingLineWidth) } }
    @Published var drawingLine: LineStyle { didSet { defaults.set(drawingLine.rawValue, forKey: Key.drawingLine) } }
    @Published var drawingLook: DrawingLook { didSet { defaults.set(drawingLook.rawValue, forKey: Key.drawingLook) } }
    @Published var drawingHasEdge: Bool { didSet { defaults.set(drawingHasEdge, forKey: Key.drawingHasEdge) } }
    @Published var cursorSize: CursorSize { didSet { defaults.set(cursorSize.rawValue, forKey: Key.size) } }
    @Published var captionSize: CaptionSize { didSet { defaults.set(captionSize.rawValue, forKey: Key.caption) } }
    @Published var replyLength: ReplyLength { didSet { defaults.set(replyLength.rawValue, forKey: Key.length) } }
    @Published var speaksReplies: Bool { didSet { defaults.set(speaksReplies, forKey: Key.speaks) } }
    /// Off until the user asks for it. Claude can't use the mouse and keyboard before then.
    @Published var controlEnabled: Bool { didSet { defaults.set(controlEnabled, forKey: Key.controlEnabled) } }
    @Published var controlInBrowsers: Bool { didSet { defaults.set(controlInBrowsers, forKey: Key.controlInBrowsers) } }
    @Published var enabledConnections: Set<String> {
        didSet { defaults.set(Array(enabledConnections), forKey: Key.connections) }
    }

    /// Connections the user limited to reading. Editing is on by default.
    @Published var readOnlyConnections: Set<String> {
        didSet { defaults.set(Array(readOnlyConnections), forKey: Key.readOnlyConnections) }
    }

    @Published private(set) var voiceOrder: [VoiceEngine] {
        didSet { defaults.set(voiceOrder.map(\.rawValue), forKey: Key.voiceOrder) }
    }
    @Published private(set) var disabledVoices: Set<VoiceEngine> {
        didSet { defaults.set(disabledVoices.map(\.rawValue), forKey: Key.disabledVoices) }
    }

    var captionStyle: CaptionStyle {
        CaptionStyle(
            background: captionColor ?? cursorColor,
            text: captionTextColor,
            opacity: captionOpacity,
            cornerRadius: captionCornerRadius,
            textSize: captionSize.points,
            font: captionFont
        )
    }

    var drawingStyle: DrawingStyle {
        DrawingStyle(
            color: drawingColor ?? cursorColor,
            lineWidth: drawingLineWidth,
            line: drawingLine,
            look: drawingLook,
            hasEdge: drawingHasEdge
        )
    }

    /// Everything on the Appearance tab back to how the app shipped.
    func resetAppearance() {
        cursorColor = .blue
        cursorSize = .medium
        captionSize = .medium
        captionColor = nil
        captionTextColor = nil
        captionOpacity = CaptionStyle().opacity
        captionCornerRadius = Double(CaptionStyle().cornerRadius)
        captionFont = .system
        drawingColor = nil
        drawingLineWidth = Double(DrawingStyle().lineWidth)
        drawingLine = .solid
        drawingLook = .handDrawn
        drawingHasEdge = true
    }

    private func save(_ color: ThemeColor?, forKey key: String) {
        if let color {
            defaults.set(color.hex, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
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
        static let controlEnabled = "com.proyecto26.openclicky.controlEnabled"
        static let controlInBrowsers = "com.proyecto26.openclicky.controlInBrowsers"
        static let captionColor = "com.proyecto26.openclicky.captionColor"
        static let captionTextColor = "com.proyecto26.openclicky.captionTextColor"
        static let captionOpacity = "com.proyecto26.openclicky.captionOpacity"
        static let captionCornerRadius = "com.proyecto26.openclicky.captionCornerRadius"
        static let captionFont = "com.proyecto26.openclicky.captionFont"
        static let drawingColor = "com.proyecto26.openclicky.drawingColor"
        static let drawingLineWidth = "com.proyecto26.openclicky.drawingLineWidth"
        static let drawingLine = "com.proyecto26.openclicky.drawingLine"
        static let drawingLook = "com.proyecto26.openclicky.drawingLook"
        static let drawingHasEdge = "com.proyecto26.openclicky.drawingHasEdge"
        static let readOnlyConnections = "com.proyecto26.openclicky.readOnlyConnections"
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
        cursorColor = defaults.string(forKey: Key.color).flatMap(ThemeColor.init(stored:)) ?? .blue
        captionColor = defaults.string(forKey: Key.captionColor).flatMap(ThemeColor.init(stored:))
        captionTextColor = defaults.string(forKey: Key.captionTextColor).flatMap(ThemeColor.init(stored:))
        captionOpacity = defaults.object(forKey: Key.captionOpacity) as? Double ?? CaptionStyle().opacity
        captionCornerRadius = defaults.object(forKey: Key.captionCornerRadius) as? Double ?? Double(CaptionStyle().cornerRadius)
        captionFont = defaults.string(forKey: Key.captionFont).flatMap(CaptionFont.init) ?? .system
        drawingColor = defaults.string(forKey: Key.drawingColor).flatMap(ThemeColor.init(stored:))
        drawingLineWidth = defaults.object(forKey: Key.drawingLineWidth) as? Double ?? Double(DrawingStyle().lineWidth)
        drawingLine = defaults.string(forKey: Key.drawingLine).flatMap(LineStyle.init) ?? .solid
        drawingLook = defaults.string(forKey: Key.drawingLook).flatMap(DrawingLook.init) ?? .handDrawn
        drawingHasEdge = defaults.object(forKey: Key.drawingHasEdge) as? Bool ?? true
        cursorSize = defaults.string(forKey: Key.size).flatMap(CursorSize.init) ?? .medium
        captionSize = defaults.string(forKey: Key.caption).flatMap(CaptionSize.init) ?? .medium
        replyLength = defaults.string(forKey: Key.length).flatMap(ReplyLength.init) ?? .short
        speaksReplies = defaults.object(forKey: Key.speaks) as? Bool ?? true
        controlEnabled = defaults.object(forKey: Key.controlEnabled) as? Bool ?? false
        controlInBrowsers = defaults.object(forKey: Key.controlInBrowsers) as? Bool ?? false
        readOnlyConnections = Set(defaults.stringArray(forKey: Key.readOnlyConnections) ?? [])
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
