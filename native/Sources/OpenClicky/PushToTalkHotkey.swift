//
//  PushToTalkHotkey.swift
//  Global push-to-talk hotkey: listens for Control + Option (modifier-
//  only chord) anywhere in the system, publishes pressed/released
//  transitions so the dictation manager can start and stop the mic in
//  real time.
//
//  Implementation notes
//  - Uses a listen-only CGEvent tap so the chord still reaches the
//    frontmost app (no intercept). Requires Accessibility permission
//    on OpenClicky.app — macOS will prompt on first activation.
//  - Fires from `CFRunLoopGetMain()`, so the callback is effectively
//    main-thread. The @Published `isPressed` matches the main-actor
//    expectations of SwiftUI observers.
//  - Hardcoded to Control + Option (modifier-only). Future expansion
//    points are isolated in `PushToTalkShortcut` so adding space-bar or
//    other chords is a one-file change.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import os

// MARK: - Shortcut definition (pure logic, unit-testable)

enum PushToTalkShortcut {
    enum Transition {
        case none
        case pressed
        case released
    }

    /// Modifier flags that define the chord. Keep `.deviceIndependentFlagsMask`
    /// so numeric-key / caps-lock bits don't confuse the comparison.
    static let requiredModifierFlags: NSEvent.ModifierFlags = [.control, .option]

    /// Human-readable caps-style labels for the panel copy.
    static let capsuleLabels: [String] = ["⌃", "⌥"]

    /// Pure state-machine step — given an event type, its modifier flags, and
    /// the previous held state, return whether the chord just became pressed,
    /// just released, or stayed the same.
    ///
    /// Isolated as a pure function so the XCTest suite can exercise it
    /// without needing a real CGEvent tap.
    static func transition(
        eventType: CGEventType,
        modifierFlagsRawValue: UInt64,
        wasPreviouslyPressed: Bool
    ) -> Transition {
        // Modifier-only chord → only `.flagsChanged` events matter.
        guard eventType == .flagsChanged else { return .none }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        let isPressed = modifierFlags.contains(requiredModifierFlags)

        if isPressed && !wasPreviouslyPressed { return .pressed }
        if !isPressed && wasPreviouslyPressed { return .released }
        return .none
    }
}

// MARK: - System-wide monitor

@MainActor
final class PushToTalkMonitor: ObservableObject {
    /// Public event stream: downstream subscribers react to pressed / released.
    let transitions = PassthroughSubject<PushToTalkShortcut.Transition, Never>()

    /// Mirrored state. Exposed as @Published so SwiftUI views can reflect
    /// "listening" feedback (waveform visibility) without subscribing to
    /// the Combine subject manually.
    @Published private(set) var isPressed: Bool = false

    private let logger = Logger(subsystem: "com.kagantemizkan.openclicky", category: "PushToTalkMonitor")
    // nonisolated(unsafe) so deinit (which runs off the main actor in
    // Swift 6) can tear these CF handles down without re-entering the
    // main actor. Both CFMachPort and CFRunLoopSource are thread-safe
    // for the invalidate/remove operations we do here.
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?

    deinit {
        // deinit must stay nonisolated in Swift 6. We only touch the CF
        // handles (which are thread-safe for this use) — the @Published
        // `isPressed` cleanup lives in the @MainActor `stop()`, which
        // callers should invoke explicitly when they want observers to
        // see a final `.released` transition.
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
    }

    /// Install the CGEvent tap. Safe to call repeatedly — no-ops if already
    /// running. Returns true when the tap is live, false if macOS refused
    /// (almost always Accessibility permission not granted).
    @discardableResult
    func start() -> Bool {
        if eventTap != nil { return true }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }

        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<PushToTalkMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(eventType: eventType, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.warning("Could not create CGEvent tap — Accessibility permission missing?")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            logger.warning("Could not create CGEvent run loop source")
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("Push-to-talk monitor active")
        return true
    }

    /// Remove the tap and forget any pressed state. Called from deinit and
    /// when the user explicitly disables push-to-talk.
    func stop() {
        if isPressed {
            isPressed = false
            transitions.send(.released)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    // MARK: - CGEvent callback bridge

    private func handle(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Auto-recover from the system disabling the tap (happens on long
        // periods of inactivity or user-input bursts).
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                logger.debug("CGEvent tap re-enabled after \(eventType == .tapDisabledByTimeout ? "timeout" : "user-input burst", privacy: .public)")
            }
            return Unmanaged.passUnretained(event)
        }

        let transition = PushToTalkShortcut.transition(
            eventType: eventType,
            modifierFlagsRawValue: event.flags.rawValue,
            wasPreviouslyPressed: isPressed
        )

        switch transition {
        case .none:
            break
        case .pressed:
            isPressed = true
            transitions.send(.pressed)
        case .released:
            isPressed = false
            transitions.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }
}
