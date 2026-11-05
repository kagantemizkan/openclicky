//
//  OverlayManager.swift
//  Owns OpenClicky's own cursor and the per-display overlay windows that
//  draw it. The cursor never reads or follows the user's mouse. It waits at
//  its home below the menu bar icon, shows listening and thinking where it
//  stands, flies to whatever Claude points at, and later flies back home.
//  The user can drag it to a new home or close its message. Mouse moves are
//  only compared with the cursor's own frames, to know when to stop letting
//  clicks through, and are not kept.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import os

/// A place for the cursor to fly to, from a POINT tag or the session bridge.
struct BlueCursorTarget: Equatable {
    /// Global AppKit coordinate.
    let globalLocation: CGPoint
    /// AppKit frame of the destination display.
    let displayFrame: CGRect
    /// 1-3 word label shown under the cursor on arrival.
    let label: String?
}

/// What the caption under the cursor shows.
enum CursorCaption: Equatable {
    case none
    case listening(transcript: String)
    /// `detail` replaces the plain wording, e.g. while reading an app.
    case thinking(detail: String?)
    case text(String)

    static func resolve(
        state: CompanionState,
        reply: String,
        label: String?,
        transcript: String,
        thinkingDetail: String? = nil
    ) -> CursorCaption {
        switch state {
        case .listening:
            return .listening(transcript: transcript)
        case .thinking where reply.isEmpty:
            return .thinking(detail: thinkingDetail)
        default:
            if !reply.isEmpty { return .text(reply) }
            if let label, !label.isEmpty { return .text(label) }
            return .none
        }
    }
}

/// The arc a flight follows, in AppKit coordinates (y grows upwards).
enum CursorFlight {
    static func duration(from a: CGPoint, to b: CGPoint) -> TimeInterval {
        min(max(TimeInterval(hypot(b.x - a.x, b.y - a.y) / 800), 0.6), 1.4)
    }

    static func position(at rawT: Double, from start: CGPoint, to end: CGPoint) -> CGPoint {
        let clamped = min(max(rawT, 0), 1)
        let t = clamped * clamped * (3 - 2 * clamped)
        let arc = min(hypot(end.x - start.x, end.y - start.y) * 0.2, 80)
        let control = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + arc)
        let u = 1 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
    }
}

@MainActor
final class OverlayManager: ObservableObject {
    /// Global AppKit coordinate of the cursor's tip.
    @Published private(set) var cursorLocation: CGPoint = .zero { didSet { updatePointerRegion() } }
    @Published private(set) var isCursorVisible = false { didSet { updatePointerRegion() } }
    @Published private(set) var pointLabel: String? { didSet { updatePointerRegion() } }
    /// What Claude drew for the current reply or lesson step.
    @Published private(set) var annotations: [ScreenAnnotation] = []
    /// While a drag is shown, the message holds still here, clear of its path.
    @Published private(set) var captionPin: CGPoint?
    @Published private(set) var dragKeepClear: [CGRect] = []
    /// The part of the cursor the mouse is over.
    @Published private(set) var hoveredRegion: CursorHit?

    @Published var voiceState: CompanionState = .idle { didSet { stateDidChange() } }
    /// 0…1 normalised mic power.
    @Published var audioLevel: CGFloat = 0
    @Published var partialTranscript = ""
    @Published var thinkingDetail: String?
    /// The reply so far. The view model clears it a few seconds after a turn.
    @Published var streamingResponseText = "" { didSet { stateDidChange() } }
    /// During a lesson the cursor stays on the current step between turns.
    @Published var isLessonActive = false { didSet { stateDidChange() } }
    @Published var showsCursorAtRest: Bool {
        didSet {
            defaults.set(showsCursorAtRest, forKey: Self.showsAtRestKey)
            stateDidChange()
        }
    }

    /// Where the cursor waits, set by the app once its menu bar icon exists.
    var homeProvider: () -> CGPoint? = { nil } {
        didSet { goHome(animated: false) }
    }
    /// The close button was pressed.
    var onDismissMessage: () -> Void = {}
    /// Replaced by tests.
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    var screenFrames: () -> [CGRect] = { NSScreen.screens.map(\.frame) }

    /// Where the view drew the caption, in global AppKit coordinates.
    var captionFrame: CGRect? { didSet { updatePointerRegion() } }

    /// While Claude acts, clicks go through its cursor to the apps below.
    var isControlling = false { didSet { updatePointerRegion() } }

    /// Whether the user has moved the cursor's resting place.
    var hasCustomHome: Bool { customHome != nil }

    /// Only a written reply can be closed.
    var isCaptionClosable: Bool {
        if case .text = caption { return true }
        return false
    }

    var caption: CursorCaption {
        CursorCaption.resolve(
            state: voiceState,
            reply: streamingResponseText,
            label: pointLabel,
            transcript: partialTranscript,
            thinkingDetail: thinkingDetail
        )
    }

    /// How long the cursor lingers where it pointed before heading home.
    private static let lingerSeconds: TimeInterval = 4
    private static let showsAtRestKey = "com.proyecto26.openclicky.showsCursorAtRest"
    private static let homeXKey = "com.proyecto26.openclicky.cursorHomeX"
    private static let homeYKey = "com.proyecto26.openclicky.cursorHomeY"
    /// Movement below this is a click rather than a drag.
    private static let dragThreshold: CGFloat = 3

    private let logger = Logger(subsystem: "com.proyecto26.openclicky", category: "OverlayManager")
    private let defaults: UserDefaults
    private var windows: [OverlayWindow] = []
    private var screenParameterObserver: NSObjectProtocol?
    private var pointerMonitors: [Any] = []
    private var flightTask: Task<Void, Never>?
    private var goHomeTask: Task<Void, Never>?
    private var customHome: CGPoint?
    /// While the tip is on what Claude pointed at, the arrow stays
    /// click-through, or it would swallow the click the user was told to make.
    private var isOnTarget = false
    private var press: PointerPress?

    private enum PointerPress {
        case close
        /// `grab` is the tip's offset from the mouse.
        case drag(grab: CGVector, start: CGPoint, moved: Bool)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsCursorAtRest = defaults.object(forKey: Self.showsAtRestKey) as? Bool ?? true
        if defaults.object(forKey: Self.homeXKey) != nil {
            customHome = CGPoint(x: defaults.double(forKey: Self.homeXKey), y: defaults.double(forKey: Self.homeYKey))
        }
        installScreenParameterObserver()
        installPointerMonitors()
        rebuildWindowsForCurrentScreens()
    }

    deinit {
        if let observer = screenParameterObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        pointerMonitors.forEach(NSEvent.removeMonitor)
    }

    /// Flies the cursor to `target`, replacing any flight under way.
    func flyTo(_ target: BlueCursorTarget) {
        logger.info("flyTo \(String(describing: target.globalLocation), privacy: .public) label=\(target.label ?? "nil", privacy: .public)")
        goHomeTask?.cancel()
        press = nil
        isOnTarget = true
        pointLabel = nil
        captionPin = nil
        dragKeepClear = []
        isCursorVisible = true
        fly(to: target.globalLocation) { [weak self] in
            self?.pointLabel = target.label
            self?.stateDidChange()
        }
    }

    /// Moves in a straight line at an even speed, the way a drag does.
    func glide(to end: CGPoint, duration: TimeInterval) {
        goHomeTask?.cancel()
        flightTask?.cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, duration > 0 else {
            cursorLocation = end
            return
        }
        let start = cursorLocation
        captionPin = start
        let path = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        dragKeepClear = [path.insetBy(dx: -16, dy: -16)]
        flightTask = Task { @MainActor [weak self] in
            let began = Date()
            while !Task.isCancelled {
                let t = min(Date().timeIntervalSince(began) / duration, 1)
                self?.cursorLocation = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                if t >= 1 { return }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    /// Drops the reply and label so an interrupted turn leaves no residue.
    func reset() {
        flightTask?.cancel()
        pointLabel = nil
        annotations = []
        captionPin = nil
        dragKeepClear = []
        streamingResponseText = ""
    }

    /// The user clicked during a lesson: uncover what the click may open.
    func clearLabel() {
        pointLabel = nil
        annotations = []
    }

    func show(_ annotations: [ScreenAnnotation]) {
        self.annotations = annotations
        if !annotations.isEmpty { isCursorVisible = true }
    }

    // MARK: - Resting

    /// Sends the cursor back under the menu bar icon.
    func forgetCustomHome() {
        customHome = nil
        defaults.removeObject(forKey: Self.homeXKey)
        defaults.removeObject(forKey: Self.homeYKey)
        goHome(animated: true)
    }

    private func stateDidChange() {
        updatePointerRegion()
        goHomeTask?.cancel()
        if voiceState != .idle {
            isCursorVisible = true
            return
        }
        guard !isLessonActive, streamingResponseText.isEmpty else { return }
        goHomeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lingerSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.goHome(animated: true)
        }
    }

    private func goHome(animated: Bool) {
        guard press == nil else { return }
        isOnTarget = false
        pointLabel = nil
        annotations = []
        captionPin = nil
        dragKeepClear = []
        // A home on a display that has since gone is ignored, not forgotten.
        let usableHome = customHome.flatMap { home in isOnAScreen(home) ? home : nil }
        let home = usableHome ?? homeProvider() ?? fallbackHome
        let settle = { [weak self] in
            guard let self else { return }
            self.isCursorVisible = self.showsCursorAtRest || self.voiceState != .idle
        }
        if animated, isCursorVisible {
            fly(to: home, completion: settle)
        } else {
            flightTask?.cancel()
            cursorLocation = home
            settle()
        }
    }

    private var fallbackHome: CGPoint {
        guard let frame = NSScreen.screens.first?.frame else { return .zero }
        return CGPoint(x: frame.maxX - 160, y: frame.maxY - 48)
    }

    // MARK: - Mouse

    private func isOnAScreen(_ point: CGPoint) -> Bool {
        screenFrames().contains { $0.contains(point) }
    }

    private func region(at point: CGPoint) -> CursorHit? {
        guard isCursorVisible, !isControlling else { return nil }
        let width = AppPreferences.shared.cursorSize.arrowWidth
        let height = width * CursorGeometry.aspect
        return CursorHitTest.hit(
            point: point,
            captionFrame: caption == .none ? nil : captionFrame,
            closable: isCaptionClosable,
            arrowFrame: isOnTarget
                ? nil
                : CGRect(x: cursorLocation.x, y: cursorLocation.y - height, width: width, height: height)
        )
    }

    private func installPointerMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointerRegion() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointerRegion() }
            return event
        }
        pointerMonitors = [global, local].compactMap { $0 }
    }

    /// Catches clicks only over the cursor, and lets all others through. Also
    /// runs when the cursor changes, or a closed caption would keep catching
    /// clicks at the spot where it was.
    private func updatePointerRegion() {
        guard press == nil else { return }
        let region = region(at: pointerLocation())
        for window in windows where window.ignoresMouseEvents != (region == nil) {
            window.ignoresMouseEvents = region == nil
        }
        guard region != hoveredRegion else { return }
        hoveredRegion = region
        switch region {
        case .caption, .arrow:
            NSCursor.openHand.set()
        case .close, nil:
            NSCursor.arrow.set()
        }
    }

    func press(at point: CGPoint) {
        switch region(at: point) {
        case .close:
            press = .close
        case .caption, .arrow:
            goHomeTask?.cancel()
            flightTask?.cancel()
            press = .drag(
                grab: CGVector(dx: cursorLocation.x - point.x, dy: cursorLocation.y - point.y),
                start: point,
                moved: false
            )
        case nil:
            updatePointerRegion()
        }
    }

    func drag(to point: CGPoint) {
        guard case .drag(let grab, let start, var moved) = press else { return }
        moved = moved || hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold
        press = .drag(grab: grab, start: start, moved: moved)
        guard moved else { return }
        NSCursor.closedHand.set()
        isOnTarget = false
        let tip = CGPoint(x: point.x + grab.dx, y: point.y + grab.dy)
        if isOnAScreen(tip) {
            cursorLocation = tip
        }
    }

    func release(at point: CGPoint) {
        let finished = press
        press = nil
        switch finished {
        case .close:
            if region(at: point) == .close {
                onDismissMessage()
            }
        case .drag(_, _, let moved):
            if moved {
                customHome = cursorLocation
                defaults.set(Double(cursorLocation.x), forKey: Self.homeXKey)
                defaults.set(Double(cursorLocation.y), forKey: Self.homeYKey)
            }
            hoveredRegion = nil
            stateDidChange()
        case nil:
            break
        }
        updatePointerRegion()
    }

    // MARK: - Flight

    private func fly(to end: CGPoint, completion: @escaping () -> Void) {
        flightTask?.cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            cursorLocation = end
            completion()
            return
        }
        let start = cursorLocation
        let duration = CursorFlight.duration(from: start, to: end)
        flightTask = Task { @MainActor [weak self] in
            let began = Date()
            while !Task.isCancelled {
                let rawT = Date().timeIntervalSince(began) / duration
                self?.cursorLocation = CursorFlight.position(at: rawT, from: start, to: end)
                if rawT >= 1 {
                    completion()
                    return
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    // MARK: - Windows

    private func installScreenParameterObserver() {
        screenParameterObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.rebuildWindowsForCurrentScreens()
                // Its display may have gone, or the menu bar icon moved.
                if self.voiceState == .idle, !self.isLessonActive {
                    self.goHome(animated: false)
                }
            }
        }
    }

    private func rebuildWindowsForCurrentScreens() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = NSScreen.screens.map { screen in
            let view = BlueCursorView(screenFrame: screen.frame, manager: self)
            let window = OverlayWindow(screen: screen, rootView: AnyView(view), manager: self)
            window.orderFrontRegardless()
            return window
        }
        logger.info("Rebuilt \(self.windows.count, privacy: .public) overlay window(s)")
    }
}
