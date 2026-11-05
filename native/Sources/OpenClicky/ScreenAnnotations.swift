//
//  ScreenAnnotations.swift
//  Circles, arrows and boxes Claude draws over the screen with tags in its
//  reply, such as [CIRCLE:640,120,40] or [ARROW:100,100,400,300:screen2]. All
//  values are screenshot pixels. They are only pictures: clicks pass through
//  them, and they are outlines, so they never hide what they point out.
//

import CoreGraphics
import Foundation
import SwiftUI

/// A drawing as Claude wrote it, in screenshot pixels.
struct DrawTag: Equatable {
    enum Shape: Equatable {
        case circle(x: Double, y: Double, radius: Double)
        case arrow(fromX: Double, fromY: Double, toX: Double, toY: Double)
        case box(x: Double, y: Double, width: Double, height: Double)
    }

    let shape: Shape
    let screen: Int?
}

enum DrawTagParser {
    /// More than this stops explaining anything and just covers the screen.
    static let maxTags = 4

    private static let pattern = try! NSRegularExpression(
        pattern: #"\s*\[(CIRCLE|ARROW|BOX):([\d.,\s-]+)(?::[^\]]*?)??(?::screen(\d+))?\]"#
    )

    /// Removes every drawing tag, valid or not, so none is ever read aloud.
    static func parse(_ text: String) -> (text: String, tags: [DrawTag]) {
        let range = NSRange(text.startIndex..., in: text)
        var tags: [DrawTag] = []
        for match in pattern.matches(in: text, range: range) {
            guard let kind = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                  let values = Range(match.range(at: 2), in: text).map({ String(text[$0]) }),
                  tags.count < maxTags else { continue }
            let numbers = values.split(separator: ",").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            let screen = Range(match.range(at: 3), in: text).flatMap { Int(text[$0]) }
            if let shape = shape(kind: kind, numbers: numbers) {
                tags.append(DrawTag(shape: shape, screen: screen))
            }
        }
        let stripped = pattern
            .stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, tags)
    }

    private static func shape(kind: String, numbers n: [Double]) -> DrawTag.Shape? {
        switch (kind, n.count) {
        case ("CIRCLE", 3) where n[2] > 0:
            return .circle(x: n[0], y: n[1], radius: n[2])
        case ("ARROW", 4) where n[0] != n[2] || n[1] != n[3]:
            return .arrow(fromX: n[0], fromY: n[1], toX: n[2], toY: n[3])
        case ("BOX", 4) where n[2] > 0 && n[3] > 0:
            return .box(x: n[0], y: n[1], width: n[2], height: n[3])
        default:
            return nil
        }
    }
}

/// A drawing placed on the screen, in global AppKit coordinates.
struct ScreenAnnotation: Equatable, Identifiable {
    enum Shape: Equatable {
        case circle(center: CGPoint, radius: CGFloat)
        case arrow(from: CGPoint, to: CGPoint)
        case box(CGRect)
    }

    let id = UUID()
    let shape: Shape

    /// Where the cursor can sit without covering the thing drawn.
    var cursorAnchor: CGPoint {
        switch shape {
        case .circle(let center, let radius):
            let offset = radius * 0.72
            return CGPoint(x: center.x + offset, y: center.y - offset)
        case .arrow(_, let to):
            return to
        case .box(let rect):
            return CGPoint(x: rect.maxX, y: rect.minY)
        }
    }

    /// Whether it starts on this display.
    func isOn(_ screen: CGRect) -> Bool {
        switch shape {
        case .circle(let center, _): return screen.contains(center)
        case .arrow(let from, _): return screen.contains(from)
        case .box(let rect): return screen.contains(CGPoint(x: rect.midX, y: rect.midY))
        }
    }
}

extension PointCoordinateMapper {
    static func annotations(from tags: [DrawTag], manifest: CaptureManifest) -> [ScreenAnnotation] {
        tags.compactMap { tag in
            func global(_ x: Double, _ y: Double) -> MappedPointTarget? {
                map(x: x, y: y, screenNumber: tag.screen, label: nil, manifest: manifest)
            }
            switch tag.shape {
            case .circle(let x, let y, let radius):
                guard let center = global(x, y),
                      let screen = manifest.screens.first(where: { $0.screenNumber == center.screenNumber }),
                      screen.widthPx > 0 else { return nil }
                let scale = screen.displayFrame.width / CGFloat(screen.widthPx)
                return ScreenAnnotation(shape: .circle(center: center.globalLocation, radius: CGFloat(radius) * scale))
            case .arrow(let fromX, let fromY, let toX, let toY):
                guard let from = global(fromX, fromY), let to = global(toX, toY),
                      from.screenNumber == to.screenNumber else { return nil }
                return ScreenAnnotation(shape: .arrow(from: from.globalLocation, to: to.globalLocation))
            case .box(let x, let y, let width, let height):
                guard let corner = global(x, y), let opposite = global(x + width, y + height) else { return nil }
                let a = corner.globalLocation, b = opposite.globalLocation
                return ScreenAnnotation(shape: .box(CGRect(
                    x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)
                )))
            }
        }
    }
}

// MARK: - Drawing

enum AnnotationGeometry {
    /// `toView` converts global AppKit coordinates to the view's.
    static func path(for shape: ScreenAnnotation.Shape, toView: (CGPoint) -> CGPoint) -> Path {
        switch shape {
        case .circle(let center, let radius):
            return circle(center: toView(center), radius: radius)
        case .arrow(let from, let to):
            return arrow(from: toView(from), to: toView(to))
        case .box(let rect):
            let a = toView(CGPoint(x: rect.minX, y: rect.maxY))
            let box = CGRect(x: a.x, y: a.y, width: rect.width, height: rect.height).insetBy(dx: -4, dy: -4)
            return Path(roundedRect: box, cornerRadius: 8, style: .continuous)
        }
    }

    /// A hand-drawn loop: slightly uneven, and running a little past its start.
    private static func circle(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        let steps = 72
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let angle = -CGFloat.pi * 0.6 + t * 2.12 * .pi
            let r = radius * (1 + 0.035 * sin(t * 3 * .pi) + 0.05 * t)
            let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r * 0.96)
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    /// A gently bent shaft, then the head, so it draws in the natural order.
    private static func arrow(from: CGPoint, to: CGPoint) -> Path {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(hypot(dx, dy), 1)
        let bend = min(length * 0.12, 26)
        let control = CGPoint(x: (from.x + to.x) / 2 + dy / length * bend, y: (from.y + to.y) / 2 - dx / length * bend)
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(to: to, control: control)

        let angle = atan2(to.y - control.y, to.x - control.x)
        let head = min(length * 0.35, 15)
        for side in [CGFloat(-1), 1] {
            let wing = angle + .pi - side * 0.5
            path.move(to: to)
            path.addLine(to: CGPoint(x: to.x + cos(wing) * head, y: to.y + sin(wing) * head))
        }
        return path
    }
}

/// The drawings on one display.
struct ScreenAnnotationsLayer: View {
    let annotations: [ScreenAnnotation]
    let screenFrame: CGRect
    let color: CursorColor

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(annotations.filter { $0.isOn(screenFrame) }) { annotation in
                AnnotationStroke(
                    path: AnnotationGeometry.path(for: annotation.shape, toView: toView),
                    color: color
                )
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
    }

    private func toView(_ global: CGPoint) -> CGPoint {
        CGPoint(
            x: global.x - screenFrame.origin.x,
            y: screenFrame.height - (global.y - screenFrame.origin.y)
        )
    }
}

/// Draws itself in. A white edge and shadow keep the colour readable on any
/// background, the same way the cursor's do.
private struct AnnotationStroke: View {
    let path: Path
    let color: CursorColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            path.trim(from: 0, to: progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
            path.trim(from: 0, to: progress)
                .stroke(color.color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        .onAppear {
            if reduceMotion {
                progress = 1
            } else {
                withAnimation(.easeInOut(duration: 0.45)) { progress = 1 }
            }
        }
    }
}
