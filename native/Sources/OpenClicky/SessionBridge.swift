//
//  SessionBridge.swift
//  Lets an interactive Claude Code session drive the blue pointer and voice.
//
//  The session looks at a screenshot, then atomically moves a small file
//  into the bridge directory (see scripts/openclicky-bridge). A directory
//  watcher picks it up, deletes it, and flies the pointer or speaks.
//  The directory is 0700, so only this user's processes can drive it, and
//  it can only move the on-screen arrow or talk: it never clicks or types.
//

import AppKit
import Foundation
import os

/// One "point here" request. `x`/`y` are pixels in the screenshot the
/// session looked at, and `imageWidth`/`imageHeight` are that screenshot's
/// size. `screen` is the 1-based `screencapture -D` display number.
struct BridgePointCommand: Decodable, Equatable {
    let x: Double
    let y: Double
    let imageWidth: Int
    let imageHeight: Int
    let screen: Int?
    let label: String?

    /// Resolves against display frames in NSScreen order, where index 0 is
    /// the main display, as `screencapture -D 1` is. Nil for an unknown
    /// display or an invalid image size.
    func target(displayFrames: [CGRect]) -> BlueCursorTarget? {
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        let screens = displayFrames.enumerated().map { index, frame in
            CapturedScreen(
                screenNumber: index + 1,
                label: "",
                jpegData: Data(),
                widthPx: imageWidth,
                heightPx: imageHeight,
                displayFrame: frame,
                isCursorScreen: index == 0
            )
        }
        let manifest = CaptureManifest(screens: screens, capturedAt: Date())
        guard let mapped = PointCoordinateMapper.map(
            x: x, y: y, screenNumber: screen, label: label, manifest: manifest
        ) else { return nil }
        return BlueCursorTarget(
            globalLocation: mapped.globalLocation,
            displayFrame: mapped.displayFrame,
            label: mapped.label
        )
    }
}

@MainActor
final class SessionBridge {
    static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenClicky/bridge", isDirectory: true)

    private let logger = Logger(subsystem: "com.proyecto26.openclicky", category: "SessionBridge")
    private let onTarget: (BlueCursorTarget) -> Void
    private let onSpeak: (String) -> Void
    private var source: DispatchSourceFileSystemObject?

    init(onTarget: @escaping (BlueCursorTarget) -> Void, onSpeak: @escaping (String) -> Void) {
        self.onTarget = onTarget
        self.onSpeak = onSpeak
    }

    func start() {
        guard source == nil else { return }
        let path = Self.directory.path
        do {
            try FileManager.default.createDirectory(
                at: Self.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // createDirectory doesn't change the mode of an existing directory.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            logger.error("Could not prepare bridge directory: \(error.localizedDescription, privacy: .public)")
            return
        }

        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            logger.error("Could not watch bridge directory")
            return
        }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .main
        )
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.consumePendingCommands() }
        }
        watcher.setCancelHandler { close(descriptor) }
        watcher.resume()
        source = watcher
        consumePendingCommands()
    }

    private func consumePendingCommands() {
        if let data = takeFile(named: "point.json") {
            if let command = try? JSONDecoder().decode(BridgePointCommand.self, from: data),
               let target = command.target(displayFrames: NSScreen.screens.map(\.frame)) {
                onTarget(target)
            } else {
                logger.error("Ignoring invalid point command")
            }
        }
        if let data = takeFile(named: "speak.txt") {
            let text = String(decoding: data, as: UTF8.self)
            onSpeak(text)
        }
    }

    private func takeFile(named name: String) -> Data? {
        let file = Self.directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        return data
    }
}
