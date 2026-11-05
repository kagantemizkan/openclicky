//
//  BlueCursorView.swift
//  Draws OpenClicky's own cursor, and the caption under it, on one display.
//  OverlayManager owns where it is; this view only renders it, and only on
//  the display that contains it. The cursor itself shows what it's doing:
//  it pulses with your voice while listening and rocks while thinking.
//

import AppKit
import SwiftUI

// MARK: - Brand

enum Brand {
    /// #A0DAFA, always with black text on top.
    static let blue = Color(red: 160 / 255, green: 218 / 255, blue: 250 / 255)
    static let nsBlue = NSColor(srgbRed: 160 / 255, green: 218 / 255, blue: 250 / 255, alpha: 1)
}

// MARK: - Shape

/// The cursor's silhouette: a soft arrowhead with its tip at the top left.
/// Shared by the overlay, the menu bar icon and the app icon.
enum CursorGeometry {
    /// Height relative to the width of the arrow.
    static let aspect: CGFloat = 1.12

    /// The path in a rect with y growing downwards.
    static func path(width: CGFloat, origin: CGPoint = .zero, flipped: Bool = false) -> CGPath {
        let corners: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 0.09),
            (1, 0.56, 0.09),
            (0.46, 0.68, 0.12),
            (0.22, aspect, 0.09),
        ]
        let points = corners.map { corner -> CGPoint in
            let y = corner.1 * width
            return CGPoint(
                x: origin.x + corner.0 * width,
                y: flipped ? origin.y + aspect * width - y : origin.y + y
            )
        }
        let path = CGMutablePath()
        let last = points[points.count - 1]
        path.move(to: CGPoint(x: (last.x + points[0].x) / 2, y: (last.y + points[0].y) / 2))
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            path.addArc(tangent1End: points[index], tangent2End: next, radius: corners[index].2 * width)
        }
        path.closeSubpath()
        return path
    }
}

/// The cursor itself, in colour. A hairline keeps its pale blue visible on a
/// light menu bar as well as a dark one.
enum StatusItemIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let width: CGFloat = 12
            let path = CursorGeometry.path(
                width: width,
                origin: CGPoint(x: 3.5, y: (18 - width * CursorGeometry.aspect) / 2),
                flipped: true
            )
            context.addPath(path)
            context.setFillColor(Brand.nsBlue.cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(0.75)
            context.setLineJoin(.round)
            context.strokePath()
            return true
        }
        image.accessibilityDescription = "OpenClicky"
        return image
    }
}

private struct CursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CursorGeometry.path(width: rect.width, origin: rect.origin))
    }
}

/// The arrow alone: blue fill, white edge, soft shadow.
struct CursorArrow: View {
    var width: CGFloat = 20

    var body: some View {
        ZStack {
            CursorShape().stroke(Color.white, style: StrokeStyle(lineWidth: width * 0.22, lineJoin: .round))
            CursorShape().fill(Brand.blue)
        }
        .frame(width: width, height: width * CursorGeometry.aspect)
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: width * 0.18, x: 0, y: width * 0.08)
    }
}

// MARK: - Overlay

struct BlueCursorView: View {
    let screenFrame: CGRect
    @ObservedObject var manager: OverlayManager

    @State private var captionSize: CGSize = .zero

    private static let arrowWidth: CGFloat = 20
    /// Puts the caption below the arrow and slightly to its right.
    private static let captionGap = CGSize(width: 14, height: 27)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if manager.isCursorVisible, screenFrame.contains(manager.cursorLocation) {
                let tip = viewPoint(manager.cursorLocation)
                arrow(tip: tip)
                caption(tip: tip)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: manager.isCursorVisible)
    }

    private func arrow(tip: CGPoint) -> some View {
        LivelyCursor(state: manager.voiceState, audioLevel: manager.audioLevel, width: Self.arrowWidth)
            .position(
                x: tip.x + Self.arrowWidth / 2,
                y: tip.y + Self.arrowWidth * CursorGeometry.aspect / 2
            )
            .transition(.opacity)
    }

    @ViewBuilder
    private func caption(tip: CGPoint) -> some View {
        let content = manager.caption
        if content != .none {
            let origin = OverlayPlacement.boxOrigin(
                anchor: tip,
                size: captionSize,
                screen: screenFrame.size,
                gap: Self.captionGap
            )
            CursorCaptionView(content: content, audioLevel: manager.audioLevel)
                .onGeometryChange(for: CGSize.self, of: \.size) { captionSize = $0 }
                .offset(x: origin.x, y: origin.y)
                .transition(.opacity)
        }
    }

    /// AppKit global (bottom-left origin) to view-local (top-left origin).
    private func viewPoint(_ global: CGPoint) -> CGPoint {
        CGPoint(
            x: global.x - screenFrame.origin.x,
            y: screenFrame.height - (global.y - screenFrame.origin.y)
        )
    }
}

// MARK: - State on the cursor

/// Pulses with the voice while listening, rocks on its tip while thinking,
/// and breathes while speaking. Still when idle, and for Reduce Motion.
private struct LivelyCursor: View {
    let state: CompanionState
    let audioLevel: CGFloat
    let width: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if state == .idle || reduceMotion {
            CursorArrow(width: width)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                CursorArrow(width: width)
                    .scaleEffect(scale(at: time), anchor: .topLeading)
                    .rotationEffect(.degrees(tilt(at: time)), anchor: .topLeading)
            }
        }
    }

    private func scale(at time: TimeInterval) -> CGFloat {
        switch state {
        case .listening:
            let level = pow(min(max(audioLevel - 0.008, 0) * 2.85, 1), 0.76)
            return 1.05 + level * 0.35
        case .speaking:
            return 1 + CGFloat(sin(time * 3)) * 0.05
        case .thinking, .idle:
            return 1
        }
    }

    private func tilt(at time: TimeInterval) -> Double {
        state == .thinking ? sin(time * 5) * 10 : 0
    }
}

// MARK: - Caption

private struct CursorCaptionView: View {
    let content: CursorCaption
    let audioLevel: CGFloat

    var body: some View {
        Group {
            switch content {
            case .none:
                EmptyView()
            case .listening(let transcript):
                HStack(spacing: 8) {
                    VoiceBars(audioLevel: audioLevel)
                    captionText(transcript.isEmpty ? Strings.listening : transcript)
                }
            case .thinking:
                HStack(spacing: 2) {
                    captionText(Strings.thinking)
                    ThinkingDots()
                }
            case .text(let text):
                captionText(text)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 3,
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 10,
                topTrailingRadius: 10,
                style: .continuous
            )
            .fill(Brand.blue)
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        )
    }

    private func captionText(_ text: String) -> some View {
        WrapAtWidth(maxWidth: 278) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.black)
                .lineSpacing(2)
        }
    }
}

/// Lets text wrap at `maxWidth` while the box still hugs a short line, which
/// `frame(maxWidth:)` can't do: it either fills the width or never wraps.
private struct WrapAtWidth: Layout {
    let maxWidth: CGFloat

    private func proposal(_ proposed: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposed.width ?? maxWidth, maxWidth), height: nil)
    }

    func sizeThatFits(proposal proposed: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal(proposed)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal proposed: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: proposal(proposed))
    }
}

private struct VoiceBars: View {
    let audioLevel: CGFloat

    private let profile: [CGFloat] = [0.5, 0.8, 1, 0.8, 0.5]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            HStack(spacing: 2) {
                ForEach(profile.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.black)
                        .frame(width: 2.5, height: height(index, at: context.date))
                }
            }
            .frame(height: 16)
        }
    }

    private func height(_ index: Int, at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate * 3.6 + Double(index) * 0.5
        let level = pow(min(max(audioLevel - 0.008, 0) * 2.85, 1), 0.76)
        return 4 + level * 12 * profile[index] + CGFloat((sin(phase) + 1) / 2) * 1.5
    }
}

private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.black.opacity(index == step ? 0.9 : 0.3))
                        .frame(width: 3.5, height: 3.5)
                }
            }
        }
        .padding(.top, 5)
    }
}
