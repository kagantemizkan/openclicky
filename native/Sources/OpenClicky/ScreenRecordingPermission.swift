//
//  ScreenRecordingPermission.swift
//  Live watcher for macOS Screen Recording TCC permission.
//
//  Why not just `CGPreflightScreenCaptureAccess()`?
//  Apple DTS (forum 732726) confirms that function caches `false` for the
//  lifetime of the process — once denied at launch, it keeps returning
//  `false` even after the user grants access. Apple's ScreenCaptureKit
//  sample code acknowledges this by telling users to restart the app.
//
//  This watcher avoids the restart by combining:
//    1. `CGPreflightScreenCaptureAccess()` (fast, canonical, but cached).
//    2. A live `CGWindowListCopyWindowInfo` probe — not cached, reflects
//       the current TCC state immediately. Used by the popular
//       `mac-screen-capture-permissions` package, Electron, and most
//       Mac menu-bar apps.
//    3. Triggers on `com.apple.TCC.updated` (undocumented but stable
//       distributed notification), `NSWorkspace.didActivateApplication`
//       (user returns from System Settings), and a 2s timer while the
//       banner is showing.
//
//  The banner clears automatically the moment the user grants permission.
//

import AppKit
import CoreGraphics
import Foundation
import os

@MainActor
final class ScreenRecordingPermission: ObservableObject {
    /// Published so SwiftUI views update automatically when state changes.
    @Published private(set) var isGranted: Bool

    /// True once SCShareableContent has reported a TCC denial in this
    /// process. There is no recovery path without a relaunch — ScreenCaptureKit
    /// latches its TCC view at the first call, so live probes will keep
    /// reporting `granted` while SC itself keeps denying. This latch lets
    /// the UI show a distinct "relaunch required" banner without trusting
    /// the probe, for the lifetime of the process.
    @Published private(set) var requiresRelaunch: Bool = false

    private let logger = Logger(subsystem: "com.kagantemizkan.openclicky", category: "ScreenRecordingPermission")
    private var pollingTimer: Timer?
    private var distributedTCCObserver: NSObjectProtocol?
    private var didActivateObserver: NSObjectProtocol?

    init() {
        self.isGranted = Self.probe()
    }

    deinit {
        // Swift 6 concurrency lets us call non-isolated teardown here without
        // the usual @MainActor isolation hop.
        if let token = distributedTCCObserver {
            DistributedNotificationCenter.default().removeObserver(token)
        }
        if let token = didActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        pollingTimer?.invalidate()
    }

    /// Starts watching for TCC changes. Call when the banner becomes visible.
    /// Safe to call repeatedly — no-ops if already watching.
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
        logger.debug("Screen Recording permission watcher started.")
    }

    /// Stops watching. Called automatically once permission is granted
    /// (no reason to keep polling) and from deinit.
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

    /// Manually trigger the TCC prompt. The macOS first-run-only gesture.
    @discardableResult
    func request() -> Bool {
        let accepted = CGRequestScreenCaptureAccess()
        refresh()
        return accepted
    }

    /// Opens System Settings on the Screen Recording pane so users don't hunt.
    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Flags that ScreenCaptureKit reported a TCC denial in this process.
    /// Once this fires, `requiresRelaunch` is sticky for the process
    /// lifetime — live TCC probes can't recover SC's internal cache.
    /// Also stops the watcher (probing is pointless: it will keep lying).
    func handleRuntimeTCCDenial() {
        logger.info("SCShareableContent reported TCC denial; process-level relaunch required.")
        requiresRelaunch = true
        stopWatching()
    }

    // MARK: - Private

    private func refresh() {
        let granted = Self.probe()
        if granted != isGranted {
            isGranted = granted
            logger.info("Screen Recording permission changed → \(granted ? "granted" : "denied", privacy: .public)")
            if granted {
                // No need to keep polling — once granted, the user won't
                // typically revoke mid-session. If SCShareableContent still
                // fails, handleRuntimeTCCDenial will restart the watcher.
                stopWatching()
            }
        }
    }

    /// Canonical + live-probe combination. Returns true as soon as either
    /// signal reports access, which lets the banner clear without a restart.
    private static func probe() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return hasAccessViaWindowListProbe()
    }

    /// `CGWindowListCopyWindowInfo` is not cached across TCC changes —
    /// if Screen Recording is denied, window entries for other processes
    /// have no `kCGWindowName`. If at least one foreign window carries a
    /// non-empty name, permission is genuinely granted for this process.
    ///
    /// Gotcha: in full-screen contexts the window list can be sparse, so
    /// this is a positive signal only (never used to *reject* permission).
    private static func hasAccessViaWindowListProbe() -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in windowList {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            if let name = window[kCGWindowName as String] as? String, !name.isEmpty {
                return true
            }
        }
        return false
    }
}
