//
//  AccessibilityPermission.swift
//  Live watcher for macOS Accessibility TCC. The push-to-talk CGEvent
//  tap needs Accessibility; without it the tap silently never fires.
//
//  Same shape as ScreenRecordingPermission:
//    - `AXIsProcessTrusted()` is the canonical probe (no per-process
//      caching gotcha that CGPreflightScreenCaptureAccess has, but we
//      still re-probe on TCC change notifications so the banner clears
//      immediately after the user grants).
//    - Triggers on `com.apple.TCC.updated` (best-effort hint) +
//      `NSWorkspace.didActivateApplication` + a 2s poll while watching.
//
//  With the stable-identity Makefile, the grant persists across
//  rebuilds — same happy path as Screen Recording.
//

import AppKit
import ApplicationServices
import Combine
import Foundation
import os

@MainActor
final class AccessibilityPermission: ObservableObject {
    @Published private(set) var isGranted: Bool

    private let logger = Logger(subsystem: "com.kagantemizkan.openclicky", category: "AccessibilityPermission")
    private var pollingTimer: Timer?
    private var distributedTCCObserver: NSObjectProtocol?
    private var didActivateObserver: NSObjectProtocol?

    init() {
        self.isGranted = Self.probe()
    }

    deinit {
        // Nonisolated teardown — observers are thread-safe to remove.
        if let token = distributedTCCObserver {
            DistributedNotificationCenter.default().removeObserver(token)
        }
        if let token = didActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        pollingTimer?.invalidate()
    }

    /// Start live-watching. No-op if already watching.
    func startWatching() {
        guard pollingTimer == nil else { return }

        distributedTCCObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.TCC.updated"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        didActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        logger.debug("Accessibility permission watcher started.")
    }

    func stopWatching() {
        if let token = distributedTCCObserver {
            DistributedNotificationCenter.default().removeObserver(token)
            distributedTCCObserver = nil
        }
        if let token = didActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            didActivateObserver = nil
        }
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    /// Trigger the macOS Accessibility prompt. Unlike Screen Recording
    /// there's no synchronous "request" API — we pass
    /// `kAXTrustedCheckOptionPrompt` to AXIsProcessTrustedWithOptions,
    /// which shows the system sheet on the first call.
    @discardableResult
    func request() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options: NSDictionary = [key: true]
        let granted = AXIsProcessTrustedWithOptions(options)
        isGranted = granted
        if !granted {
            // User hasn't granted yet; keep watching so the banner
            // flips automatically once they do.
            startWatching()
        }
        return granted
    }

    /// Opens the Accessibility pane so users don't have to hunt for it.
    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private

    private func refresh() {
        let granted = Self.probe()
        if granted != isGranted {
            isGranted = granted
            logger.info("Accessibility permission changed → \(granted ? "granted" : "denied", privacy: .public)")
            if granted {
                stopWatching()
            }
        }
    }

    private static func probe() -> Bool {
        return AXIsProcessTrusted()
    }
}
