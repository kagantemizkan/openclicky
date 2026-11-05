//
//  App.swift
//  Minimal menu-bar companion for testing the Claude CLI transport.
//
//  Structure:
//    - `OpenClickyApp` is the @main entry point — SwiftUI App with an empty
//      Settings scene (required for LSUIElement apps) and an AppDelegate
//      that owns the menu bar lifecycle.
//    - `AppDelegate` creates an NSStatusItem + non-activating NSPanel.
//    - `PanelView` is SwiftUI — shows the install-Claude banner when the
//      CLI is missing, otherwise a "Test Claude" button that captures
//      the screen and round-trips through ClaudeCLIRunner.
//
//  v0.1 scope: this is intentionally minimal. Push-to-talk, overlay
//  cursor, POINT animation, and TTS come in v0.2+.
//

import AppKit
import SwiftUI
import os

// MARK: - @main

@main
struct OpenClickyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate

// MARK: - Custom panel

/// NSPanel subclass that keeps the non-activating behaviour (clicking
/// OpenClicky's panel doesn't steal focus from the user's frontmost app)
/// but overrides `canBecomeKey` so SwiftUI text fields inside the panel
/// still receive keystrokes. Without this override, SecureField /
/// TextField visibly accept focus but keyboard input is silently
/// dropped — nonactivating panels never become the key window, and
/// AppKit's text-input subsystem requires key-window status to route
/// NSEvent.keyDown to the focused control.
///
/// `canBecomeMain` stays `false` so the app genuinely doesn't
/// activate — the panel is key, but the app-level main-window state
/// doesn't change (no dock-icon flash, no menu-bar takeover).
final class OpenClickyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.proyecto26.openclicky", category: "AppDelegate")
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var keyEventMonitor: Any?
    private var globalKeyEventMonitor: Any?
    private let viewModel = OpenClickyViewModel()
    private var sessionBridge: SessionBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // `--smoke-test` runs the headless self-check, prints a JSON
        // report to stdout, and exits. CI uses this to confirm the
        // built binary launches and can talk to the system without
        // bringing up the full menu-bar UI.
        if CommandLine.arguments.contains("--smoke-test") {
            Task { @MainActor in
                let code = await SmokeTest.run()
                exit(code)
            }
            return
        }

        installStatusItem()
        // Global Esc monitor lives for the whole app lifetime so a
        // turn can be cancelled even after the panel auto-dismissed
        // (common case: kicked off a turn, clicked out, OpenClicky still
        // thinking / speaking). Piggybacks on Accessibility, already
        // granted for the push-to-talk CGEvent tap.
        installGlobalEscapeMonitor()
        let overlayManager = viewModel.overlayManager
        let textToSpeech = viewModel.textToSpeech
        let bridge = SessionBridge(
            onTarget: { target in overlayManager.flyTo(target) },
            onSpeak: { text in Task { await textToSpeech.speak(text) } }
        )
        bridge.start()
        sessionBridge = bridge
        textToSpeech.warmUpLocalVoice()
        Task { await viewModel.refreshClaudeCLIStatus() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeOutsideClickMonitor()
        statusItem = nil
        panel?.close()
        panel = nil
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.makeStatusItemImage()
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        statusItem = item
    }

    /// Primary source: SF Symbol `cursorarrow.click.2` (macOS 14+).
    /// Fallback 1: `cursorarrow` (present on every macOS version we target).
    /// Fallback 2: a 14-pt "C" rendered into an NSImage so the menu bar
    /// never appears blank even on minimum-viable SF symbol sets.
    private static func makeStatusItemImage() -> NSImage {
        if let symbol = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "OpenClicky") {
            return symbol
        }
        if let fallback = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "OpenClicky") {
            return fallback
        }
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]
        let string = NSAttributedString(string: "C", attributes: attrs)
        string.draw(at: NSPoint(x: 3, y: 0))
        image.unlockFocus()
        image.accessibilityDescription = "OpenClicky"
        return image
    }

    @objc private func togglePanel(_ sender: Any?) {
        if let panel, panel.isVisible {
            dismissPanel()
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        positionPanelUnderStatusItem(panel)
        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
        installKeyEventMonitor()
        Task { await viewModel.refreshClaudeCLIStatus() }
    }

    /// Listens for any mouse-down outside the panel's frame or the status-bar
    /// button, and dismisses the panel — mirrors NSPopover's behaviour.
    private func installOutsideClickMonitor() {
        if outsideClickMonitor != nil { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissPanel()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Local Esc monitor — installed only while the panel is open.
    /// Catches Esc when the panel has key focus (user typing in the
    /// prompt field) and swallows the event so it doesn't leak to
    /// other windows. The *global* counterpart handles the more
    /// common case (panel closed, OpenClicky still processing).
    private func installKeyEventMonitor() {
        if keyEventMonitor != nil { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 53 else { return event }
            self.handleEscapePress()
            return nil
        }
    }

    private func removeKeyEventMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    /// Global Esc monitor — installed once at launch for the app
    /// lifetime. Fires regardless of which app is frontmost, which
    /// is essential because OpenClicky's non-activating panel never
    /// makes the app active. Piggybacks on the Accessibility grant
    /// already used by the push-to-talk CGEvent tap. Can't swallow
    /// events (by OS design), but Esc in other apps is harmless.
    private func installGlobalEscapeMonitor() {
        if globalKeyEventMonitor != nil { return }
        globalKeyEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.handleEscapePress()
            }
        }
    }

    private func handleEscapePress() {
        if viewModel.isRunningTurn || viewModel.state != .idle {
            logger.info("Esc pressed — cancelling turn")
            viewModel.cancelCurrentTurn()
        } else if panel?.isVisible == true {
            dismissPanel()
        }
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
        removeKeyEventMonitor()
    }

    private func makePanel() -> NSPanel {
        let contentView = PanelView(viewModel: viewModel) { [weak self] in
            self?.dismissPanel()
        }
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 420)

        let panel = OpenClickyPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1.0)
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }

    private func positionPanelUnderStatusItem(_ panel: NSPanel) {
        guard let button = statusItem?.button,
              let buttonWindow = button.window else {
            return
        }
        let buttonFrameInScreen = buttonWindow.convertToScreen(button.frame)
        let originX = buttonFrameInScreen.midX - panel.frame.width / 2
        let originY = buttonFrameInScreen.minY - panel.frame.height - 6
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}
