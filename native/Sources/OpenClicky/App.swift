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
import Combine
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

/// A menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func run() {
        handler()
    }
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
    private var settingsWindow: NSWindow?
    private var observations: Set<AnyCancellable> = []

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
        // The cursor waits just below its menu bar icon.
        viewModel.overlayManager.homeProvider = { [weak self] in
            guard let button = self?.statusItem?.button, let window = button.window else { return nil }
            let frame = window.convertToScreen(button.frame)
            return CGPoint(x: frame.midX - 4, y: frame.minY - 6)
        }
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
        item.button?.setAccessibilityLabel("OpenClicky")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        viewModel.preferences.$cursorColor
            .sink { [weak item] color in item?.button?.image = StatusItemIcon.make(color: color) }
            .store(in: &observations)
    }

    /// Left click opens the panel. Right or Control click opens the menu.
    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return togglePanel(sender) }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showStatusMenu()
        } else {
            togglePanel(sender)
        }
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        dismissPanel()
        let menu = NSMenu()
        if viewModel.isTutorMode {
            menu.addItem(ActionMenuItem(Strings.endLesson) { [weak self] in self?.viewModel.setTutorMode(false) })
        } else {
            let lessons = NSMenu()
            for choice in viewModel.lessonChoices() {
                lessons.addItem(ActionMenuItem(choice.menuTitle) { [weak self] in self?.viewModel.startLesson(choice) })
            }
            let lessonsItem = NSMenuItem(title: Strings.startLesson, action: nil, keyEquivalent: "")
            lessonsItem.submenu = lessons
            lessonsItem.isEnabled = !lessons.items.isEmpty
            menu.addItem(lessonsItem)
        }
        menu.addItem(ActionMenuItem(Strings.newSession) { [weak self] in self?.viewModel.sessions.startNew() })
        if viewModel.overlayManager.hasCustomHome {
            menu.addItem(ActionMenuItem(Strings.resetCursorPosition) { [weak self] in
                self?.viewModel.overlayManager.forgetCustomHome()
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(Strings.settingsMenu) { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(Strings.quitApp) { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
    }

    private func openSettings() {
        dismissPanel()
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make(viewModel: viewModel)
        }
        // A menu bar app has to activate itself for its window to take focus.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
        if viewModel.isRunningTurn || viewModel.state != .idle || viewModel.isTutorMode {
            logger.info("Esc pressed — cancelling turn")
            viewModel.cancelCurrentTurn()
            viewModel.setTutorMode(false)
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
        let contentRect = NSRect(x: 0, y: 0, width: PanelView.width, height: 360)
        let panel = OpenClickyPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let hostingView = NSHostingView(rootView: PanelView(
            viewModel: viewModel,
            sessions: viewModel.sessions,
            onDismiss: { [weak self] in self?.dismissPanel() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onHeightChange: { [weak panel] height in
                guard let panel, height > 0 else { return }
                // Grow downwards: the top stays under the menu bar.
                var frame = panel.frame
                frame.origin.y = frame.maxY - height
                frame.size.height = height
                panel.setFrame(frame, display: true)
            }
        ))
        hostingView.sizingOptions = []
        hostingView.frame = contentRect
        hostingView.autoresizingMask = [.width, .height]

        // The same material as a system menu bar popover.
        let background = NSVisualEffectView(frame: contentRect)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.addSubview(hostingView)

        panel.contentView = background
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func positionPanelUnderStatusItem(_ panel: NSPanel) {
        guard let button = statusItem?.button,
              let buttonWindow = button.window else {
            return
        }
        let buttonFrameInScreen = buttonWindow.convertToScreen(button.frame)
        var originX = buttonFrameInScreen.midX - panel.frame.width / 2
        if let visible = buttonWindow.screen?.visibleFrame {
            originX = min(max(originX, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        }
        let originY = buttonFrameInScreen.minY - panel.frame.height - 6
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}
