//
//  BlueCursorView.swift
//  Blue macOS-style pointer that appears on a display only while
//  Claude is pointing at something.
//
//  Behaviour:
//    - Hidden at rest: nothing follows the mouse. The status indicators
//      (waveform while listening, spinner while thinking, reply bubble)
//      still sit beside the real pointer at a +35, +25 offset.
//    - POINT flight: when OverlayManager publishes an activeTarget
//      for this screen, the blue arrow fades in at the real pointer,
//      flies along a quadratic Bézier arc so its tip lands on the
//      target, and shows a label chip for at least 3 s and until the
//      reply has been spoken, then fades out in place.
//    - Per-screen exclusivity: only the display whose frame contains
//      NSEvent.mouseLocation shows the buddy during follow mode; the
//      target display takes over during POINT flight.
//
//  One view per overlay window (one per NSScreen). `screenFrame` is
//  captured at construction and used to translate global AppKit
//  coordinates (bottom-left origin) into SwiftUI view-local coords
//  (top-left origin) without relying on GeometryReader.
//

import AppKit
import CoreImage
import SwiftUI
import os

/// Published to the overlay by OverlayManager. Each BlueCursorView
/// decides whether it's the right one for this target by comparing
/// screenFrames.
struct BlueCursorTarget: Equatable {
    /// Global AppKit coordinate. Caller converts to view-local.
    let globalLocation: CGPoint
    /// AppKit frame of the destination display.
    let displayFrame: CGRect
    /// 1-3 word label shown in the chip on arrival.
    let label: String?
}

/// Behavioural mode of the buddy. Drives whether the cursor-follow
/// timer controls position or the Bézier flight timer does.
enum BuddyMode: Equatable {
    case followingCursor
    case navigatingToTarget
    case pointingAtTarget
}

struct BlueCursorView: View {
    let screenFrame: CGRect
    @ObservedObject var manager: OverlayManager

    // Position is in SwiftUI view-local coords (top-left origin).
    // In followingCursor mode it's driven by the 60 Hz tracking timer;
    // in flight modes it's driven directly by the Bézier animation
    // timer so we get a clean 60 fps arc without SwiftUI implicit
    // animations stepping on the frame-by-frame updates.
    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool
    @State private var cursorOpacity: Double = 0
    @State private var trackingTimer: Timer?

    // Flight state (POINT animation).
    @State private var mode: BuddyMode = .followingCursor
    @State private var arrowOpacity: Double = 0
    /// Bumped whenever a flight starts or aborts, so the delayed fade-out
    /// of an older POINT can't cut a newer one short.
    @State private var pointingGeneration = 0
    @State private var chipText: String? = nil
    @State private var chipOpacity: Double = 0
    @State private var chipScale: CGFloat = 1
    @State private var flightTimer: Timer?

    private static let log = Logger(subsystem: "com.proyecto26.openclicky", category: "BlueCursorView")

    /// Offset applied to the mouse location so the buddy sits beside
    /// the cursor (lower-right) rather than directly on top of it.
    private static let cursorFollowOffset = CGPoint(x: 35, y: 25)

    init(screenFrame: CGRect, manager: OverlayManager) {
        self.screenFrame = screenFrame
        self.manager = manager

        // Seed position from the live mouse so the buddy never flashes
        // at (0,0) between init and the first timer tick.
        let mouse = NSEvent.mouseLocation
        let localX = mouse.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouse.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(
            x: localX + Self.cursorFollowOffset.x,
            y: localY + Self.cursorFollowOffset.y
        ))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouse))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Nearly-transparent backing so the window always has drawable
            // content (belt-and-suspenders against NSHostingView shrinking
            // to zero when the cursor is off-screen).
            Color.black.opacity(0.001)

            // Blue system arrow — only while flying to / parked at a
            // POINT target. Offset by the hot spot so the arrow's tip,
            // not the image centre, sits on cursorPosition.
            Image(nsImage: BlueArrowCursor.image)
                .opacity(mode == .followingCursor ? 0 : arrowOpacity)
                .position(
                    x: cursorPosition.x + BlueArrowCursor.image.size.width / 2 - BlueArrowCursor.hotSpot.x,
                    y: cursorPosition.y + BlueArrowCursor.image.size.height / 2 - BlueArrowCursor.hotSpot.y
                )

            // Waveform — shown only while the user is holding the
            // push-to-talk shortcut (voiceState == .listening).
            // Mounted only while shown: its TimelineView would otherwise
            // keep redrawing at 36 Hz with opacity 0.
            if buddyVisibleOnThisScreen && manager.voiceState == .listening {
                BlueCursorWaveformView(audioLevel: manager.audioLevel)
                    .opacity(cursorOpacity)
                    .position(cursorPosition)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
            }

            // Spinner — shown while Claude is thinking (screenshot +
            // CLI roundtrip). Mounted only while shown, as above.
            if buddyVisibleOnThisScreen && manager.voiceState == .thinking {
                BlueCursorSpinnerView()
                    .opacity(cursorOpacity)
                    .position(cursorPosition)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
            }

            // Streaming response bubble — follows the buddy. Visible
            // whenever Claude has produced any reply text AND we're not
            // actively listening (waveform owns the cursor during
            // push-to-talk). OpenClickyViewModel auto-clears the text ~6 s
            // after the turn finishes so stale replies don't linger.
            if buddyVisibleOnThisScreen
                && manager.voiceState != .listening
                && !manager.streamingResponseText.isEmpty {
                responseBubble(manager.streamingResponseText)
                    .offset(x: cursorPosition.x + 28, y: cursorPosition.y + 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Label chip — only visible while the buddy is parked at a
            // POINT target. Fades/scales in, holds, then fades out.
            if mode == .pointingAtTarget, let chipText {
                labelChip(chipText)
                    .scaleEffect(chipScale)
                    .opacity(chipOpacity)
                    .position(
                        x: cursorPosition.x + 10 + 40,
                        y: max(20, cursorPosition.y - 16)
                    )
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: chipScale)
                    .animation(.easeOut(duration: 0.3), value: chipOpacity)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .onAppear {
            Self.log.info("onAppear screenFrame=\(String(describing: self.screenFrame), privacy: .public)")
            startTrackingCursor()
            withAnimation(.easeIn(duration: 1.5)) {
                cursorOpacity = 1
            }
        }
        .onDisappear {
            trackingTimer?.invalidate()
            trackingTimer = nil
            flightTimer?.invalidate()
            flightTimer = nil
        }
        .onReceive(manager.$activeTarget) { target in
            handleTargetChange(target)
        }
    }

    // MARK: - Visibility

    /// True when this screen should render the buddy right now.
    /// - During cursor follow: only the screen containing the mouse,
    ///   AND only if no other screen is busy with a POINT flight
    ///   (prevents two buddies on screen at once).
    /// - During flight / pointing: always show (this view is the one
    ///   that owns the target).
    private var buddyVisibleOnThisScreen: Bool {
        switch mode {
        case .followingCursor:
            if let target = manager.activeTarget,
               !matchesThisScreen(target.displayFrame) {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor tracking

    private func startTrackingCursor() {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            let mouse = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouse)

            // Flight timer owns the position while we're navigating or
            // pointing; don't stomp on it.
            guard mode == .followingCursor else { return }

            let local = convertGlobalToView(mouse)
            cursorPosition = CGPoint(
                x: local.x + Self.cursorFollowOffset.x,
                y: local.y + Self.cursorFollowOffset.y
            )
        }
    }

    // MARK: - POINT flight

    private func handleTargetChange(_ target: BlueCursorTarget?) {
        guard let target else {
            Self.log.info("handleTargetChange: nil (clear) on screenFrame=\(String(describing: self.screenFrame), privacy: .public)")
            abortPointing()
            return
        }
        let matches = matchesThisScreen(target.displayFrame)
        Self.log.info("handleTargetChange: target.displayFrame=\(String(describing: target.displayFrame), privacy: .public) screenFrame=\(String(describing: self.screenFrame), privacy: .public) matches=\(matches, privacy: .public)")
        guard matches else {
            // The new target belongs to another display: never leave a
            // second arrow parked here.
            abortPointing()
            return
        }

        // Start from the real pointer so the arrow appears to peel off it.
        let startView = convertGlobalToView(NSEvent.mouseLocation)
        let endView = convertGlobalToView(target.globalLocation)

        pointingGeneration += 1
        let generation = pointingGeneration
        cursorPosition = startView
        mode = .navigatingToTarget
        chipText = nil
        chipOpacity = 0
        chipScale = 0.5
        withAnimation(.easeIn(duration: 0.15)) {
            arrowOpacity = 1
        }

        animateBezier(from: startView, to: endView, duration: flightDuration(from: startView, to: endView)) {
            enterPointingAt(target, generation: generation)
        }
    }

    private func enterPointingAt(_ target: BlueCursorTarget, generation: Int) {
        mode = .pointingAtTarget
        chipText = target.label ?? "here"
        chipScale = 1
        chipOpacity = 1

        fadeOutWhenDone(generation: generation, after: 3.0)
    }

    /// Holds for at least `delay` and for as long as the reply is being
    /// spoken, then fades out in place.
    private func fadeOutWhenDone(generation: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard generation == pointingGeneration, mode == .pointingAtTarget else { return }
            if manager.voiceState == .speaking {
                fadeOutWhenDone(generation: generation, after: 0.25)
                return
            }
            chipOpacity = 0
            withAnimation(.easeOut(duration: 0.3)) {
                arrowOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard generation == pointingGeneration, mode == .pointingAtTarget else { return }
                mode = .followingCursor
                manager.clearTargetIfMatches(target: screenFrame)
            }
        }
    }

    /// Drops any flight or parked arrow on this display immediately.
    private func abortPointing() {
        guard mode != .followingCursor else { return }
        pointingGeneration += 1
        flightTimer?.invalidate()
        flightTimer = nil
        arrowOpacity = 0
        chipText = nil
        chipOpacity = 0
        mode = .followingCursor
    }

    private func animateBezier(
        from start: CGPoint,
        to end: CGPoint,
        duration: TimeInterval,
        onComplete: @escaping () -> Void
    ) {
        flightTimer?.invalidate()

        let distance = hypot(end.x - start.x, end.y - start.y)
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let arcHeight = min(distance * 0.2, 80)
        let control = CGPoint(x: midpoint.x, y: midpoint.y - arcHeight)

        let startDate = Date()
        flightTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            let rawT = min(1.0, Date().timeIntervalSince(startDate) / duration)
            let t = smoothstep(rawT)

            cursorPosition = quadraticBezier(t: t, start: start, control: control, end: end)

            if rawT >= 1.0 {
                timer.invalidate()
                flightTimer = nil
                cursorPosition = end
                onComplete()
            }
        }
    }

    // MARK: - Subviews

    /// Floating streaming-response bubble. Rendered inside the existing
    /// per-display overlay window (no extra NSPanel needed) so it shares
    /// the buddy's cursor-tracking timer + window frame.
    private func responseBubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 300, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 16, y: 8)
            )
    }

    private func labelChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.blue.opacity(0.92))
                    .shadow(color: .blue.opacity(0.45), radius: 8, y: 2)
            )
            .fixedSize()
    }

    // MARK: - Math helpers

    private func matchesThisScreen(_ frame: CGRect) -> Bool {
        frame.origin == screenFrame.origin && frame.size == screenFrame.size
    }

    private func flightDuration(from a: CGPoint, to b: CGPoint) -> TimeInterval {
        let d = hypot(b.x - a.x, b.y - a.y)
        return min(max(TimeInterval(d / 800), 0.6), 1.4)
    }

    private func smoothstep(_ t: Double) -> Double {
        t * t * (3 - 2 * t)
    }

    private func quadraticBezier(t: Double, start: CGPoint, control: CGPoint, end: CGPoint) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u*u*start.x + 2*u*t*control.x + t*t*end.x,
            y: u*u*start.y + 2*u*t*control.y + t*t*end.y
        )
    }

    /// AppKit global (bottom-left origin) → SwiftUI view-local (top-left).
    private func convertGlobalToView(_ globalPoint: CGPoint) -> CGPoint {
        let localX = globalPoint.x - screenFrame.origin.x
        let localY = screenFrame.height - (globalPoint.y - screenFrame.origin.y)
        return CGPoint(x: localX, y: localY)
    }
}

// MARK: - Blue system arrow

/// The real macOS arrow cursor recoloured blue: black fill → blue, white
/// outline stays white. Using `NSCursor.arrow` keeps the shape identical
/// to the system pointer instead of approximating it with a hand-drawn path.
enum BlueArrowCursor {
    static let hotSpot = NSCursor.arrow.hotSpot
    static let image = makeImage()

    private static func makeImage() -> NSImage {
        let source = NSCursor.arrow.image
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filter = CIFilter(name: "CIFalseColor") else {
            return source
        }
        filter.setValue(CIImage(cgImage: cgImage), forKey: kCIInputImageKey)
        filter.setValue(CIColor(red: 0, green: 0.48, blue: 1), forKey: "inputColor0")
        filter.setValue(CIColor(red: 1, green: 1, blue: 1), forKey: "inputColor1")
        guard let output = filter.outputImage,
              let tinted = CIContext().createCGImage(output, from: output.extent) else {
            return source
        }
        return NSImage(cgImage: tinted, size: source.size)
    }
}

// MARK: - Waveform (listening)

/// Five-bar waveform that reacts to mic power while push-to-talk is
/// held. Combines an idle sine pulse with a reactive component so it
/// looks alive even during silence.
private struct BlueCursorWaveformView: View {
    let audioLevel: CGFloat

    private let barCount = 5
    private let barProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { context in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.blue)
                        .frame(width: 2, height: barHeight(for: i, at: context.date))
                }
            }
            .shadow(color: .blue.opacity(0.6), radius: 6)
            .animation(.linear(duration: 0.08), value: audioLevel)
        }
    }

    private func barHeight(for i: Int, at date: Date) -> CGFloat {
        let phase = CGFloat(date.timeIntervalSinceReferenceDate * 3.6) + CGFloat(i) * 0.35
        let normalized = max(audioLevel - 0.008, 0)
        let eased = pow(min(normalized * 2.85, 1), 0.76)
        let reactive = eased * 10 * barProfile[i]
        let idlePulse = (sin(phase) + 1) / 2 * 1.5
        return 3 + reactive + idlePulse
    }
}

// MARK: - Spinner (thinking)

/// Circular "thinking" spinner that replaces the triangle while the
/// screenshot + Claude roundtrip is in flight.
private struct BlueCursorSpinnerView: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [Color.blue.opacity(0), Color.blue],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .shadow(color: .blue.opacity(0.6), radius: 6)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}
