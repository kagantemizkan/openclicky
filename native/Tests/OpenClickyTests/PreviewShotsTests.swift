//
//  PreviewShotsTests.swift
//  Saves pictures of the panel and cursor for checking by eye. Runs only
//  when OPENCLICKY_PREVIEW_DIR is set. Views draw offscreen, so no permission
//  is needed and nothing from the desktop appears. The panel's material
//  doesn't render offscreen, so a flat colour stands in for it.
//

import AppKit
import SwiftUI
import XCTest
@testable import OpenClicky

@MainActor
final class PreviewShotsTests: XCTestCase {
    func testSavePreviewImages() async throws {
        let directory = ProcessInfo.processInfo.environment["OPENCLICKY_PREVIEW_DIR"] ?? ""
        try XCTSkipIf(directory.isEmpty, "set OPENCLICKY_PREVIEW_DIR to run")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let sessions = SessionStore(fileURL: file)
        sessions.recordTurn(
            claudeSessionId: "preview",
            usage: TokenUsage(input: 3_120, cacheWrite: 9_300, cacheRead: 48_000, output: 410),
            prompt: "vinyet efekti nasıl eklerim"
        )
        sessions.rename(sessions.activeId, to: "Affinity dersleri")
        let viewModel = OpenClickyViewModel(sessions: sessions)
        // Let the real permission checks report first; the test process lacks
        // them, and the panel under review is the one past those notices.
        try await Task.sleep(nanoseconds: 300_000_000)
        viewModel.hasScreenRecordingPermission = true
        viewModel.hasAccessibilityPermission = true
        viewModel.isClaudeCLIAvailable = true
        viewModel.claudeVersion = "2.1.312 (Claude Code)"

        for (name, appearanceName, panelColor, backdrop) in [
            ("light", NSAppearance.Name.aqua, Color(white: 0.96), Color(white: 0.93)),
            ("dark", NSAppearance.Name.darkAqua, Color(white: 0.17), Color(white: 0.12)),
        ] {
            let appearance = NSAppearance(named: appearanceName)
            let panel = PanelView(
                viewModel: viewModel,
                sessions: sessions,
                onDismiss: {},
                onOpenSettings: {},
                onHeightChange: { _ in }
            )
            .background(panelColor)
            try await save(panel, size: CGSize(width: PanelView.width, height: 400), appearance: appearance, to: "\(directory)/panel-\(name).png")

            let settings = SettingsView(
                viewModel: viewModel,
                overlay: viewModel.overlayManager,
                preferences: viewModel.preferences
            )
            .background(panelColor)
            try await save(settings, size: CGSize(width: 480, height: 420), appearance: appearance, to: "\(directory)/settings-\(name).png")

            let frame = CGRect(x: 0, y: 0, width: 640, height: 240)
            let overlay = OverlayManager()
            overlay.flyTo(BlueCursorTarget(globalLocation: CGPoint(x: 120, y: 190), displayFrame: frame, label: "Vinyet"))
            try await Task.sleep(nanoseconds: 1_600_000_000)

            func shot(_ state: String) async throws {
                let view = BlueCursorView(screenFrame: frame, manager: overlay).background(backdrop)
                try await save(view, size: frame.size, appearance: appearance, to: "\(directory)/cursor-\(state)-\(name).png")
            }

            try await shot("label")
            overlay.voiceState = .listening
            overlay.audioLevel = 0.2
            overlay.partialTranscript = "vinyet efekti nasıl eklerim"
            try await shot("listening")
            overlay.partialTranscript = ""
            overlay.voiceState = .thinking
            try await shot("thinking")
            overlay.voiceState = .speaking
            overlay.streamingResponseText = "vinyet eklemek iki adım sürüyor. önce sağ üstteki filtreler düğmesine tıkla, sonra listeden vinyeti seçeceğiz."
            try await shot("speaking")
            overlay.pointerLocation = { [weak overlay] in
                guard let frame = overlay?.captionFrame else { return .zero }
                return CGPoint(x: frame.midX, y: frame.midY)
            }
            let drawnFrame = overlay.captionFrame
            overlay.captionFrame = drawnFrame
            try await shot("hover")
        }

        try await save(
            Image(nsImage: StatusItemIcon.make(color: .blue)).padding(4).background(Color(white: 0.93)),
            size: CGSize(width: 26, height: 26),
            appearance: nil,
            to: "\(directory)/status-light.png",
            scale: 6
        )
        try await save(
            Image(nsImage: StatusItemIcon.make(color: .blue)).padding(4).background(Color(white: 0.15)),
            size: CGSize(width: 26, height: 26),
            appearance: nil,
            to: "\(directory)/status-dark.png",
            scale: 6
        )
    }

    private func save<V: View>(
        _ view: V, size: CGSize, appearance: NSAppearance?, to path: String, scale: CGFloat = 2
    ) async throws {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = appearance
        // A window keeps controls drawing as they would in the real panel.
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
