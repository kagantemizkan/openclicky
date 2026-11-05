//
//  OverlayWindow.swift
//  One transparent full-screen window per connected display, hosting the
//  SwiftUI BlueCursorView. It lets clicks through except while the mouse is
//  over the caption or a movable cursor, which OverlayManager decides.
//
//  A non-activating panel, so grabbing the caption leaves the user's app in
//  front. The .screenSaver level sits above most macOS UI, including submenus
//  and tooltips, which a "point at this thing" overlay needs.
//

import AppKit
import SwiftUI

final class OverlayWindow: NSPanel {
    init(screen: NSScreen, rootView: AnyView, manager: OverlayManager) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = false
        hidesOnDeactivate = false

        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        let container = NSView(frame: bounds)

        let hostingView = NSHostingView(rootView: rootView)
        // Disable NSHostingView's default "size to fit content" behaviour.
        // The overlay's SwiftUI content is zero-sized whenever the cursor
        // is hidden (opacity=0), which otherwise collapses the window to
        // 0×0 and silently drops every animation.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = bounds
        container.addSubview(hostingView)

        let interaction = OverlayInteractionView(manager: manager)
        interaction.autoresizingMask = [.width, .height]
        interaction.frame = bounds
        container.addSubview(interaction)

        contentView = container

        setFrame(screen.frame, display: true)
        setFrameOrigin(screen.frame.origin)
    }

    // Overlay never accepts focus; keep the frontmost app key.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Passes presses to OverlayManager, which knows what is under them.
private final class OverlayInteractionView: NSView {
    private weak var manager: OverlayManager?

    init(manager: OverlayManager) {
        self.manager = manager
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// The first click has to work without the app being active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { manager?.press(at: NSEvent.mouseLocation) }
    }

    override func mouseDragged(with event: NSEvent) {
        MainActor.assumeIsolated { manager?.drag(to: NSEvent.mouseLocation) }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated { manager?.release(at: NSEvent.mouseLocation) }
    }
}
