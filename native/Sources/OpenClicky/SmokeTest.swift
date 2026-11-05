//
//  SmokeTest.swift
//  Headless self-check used by `OpenClicky --smoke-test`. Probes the
//  pieces that have to be wired up correctly for a working app —
//  Claude CLI presence, TCC permissions, display capture, ElevenLabs
//  configuration — and prints a structured JSON report to stdout.
//
//  Always exits 0 unless the runtime itself crashed: the report's
//  individual fields are how callers (humans or CI) decide pass/fail.
//  Treating "permission missing" as a non-zero exit would make the
//  binary unusable on a vanilla macOS CI runner where TCC is empty
//  by design.
//

import AVFoundation
import Foundation
import os

@MainActor
enum SmokeTest {
    struct Report: Codable {
        let macosVersion: String
        let claudeCLI: ClaudeCLIStatus
        let permissions: Permissions
        let displays: DisplaysStatus
        let elevenLabs: ElevenLabsStatus
        /// Convenience flag: every probe came back healthy. Callers can
        /// either trust this or read individual fields themselves.
        let passed: Bool
    }

    struct ClaudeCLIStatus: Codable {
        let installed: Bool
        let path: String?
        let version: String?
    }

    struct Permissions: Codable {
        let screenRecording: Bool
        let accessibility: Bool
        let microphone: String  // "granted" / "denied" / "notDetermined" / "restricted"
    }

    struct DisplaysStatus: Codable {
        let count: Int
        let captureSucceeded: Bool
        let captureError: String?
    }

    struct ElevenLabsStatus: Codable {
        let configured: Bool
        let voiceIdPrefix: String?
    }

    /// Runs every probe sequentially. Each step is wrapped so a single
    /// failure (e.g. capture denied) doesn't abort the others.
    static func run() async -> Int32 {
        let logger = Logger(subsystem: "com.kagantemizkan.openclicky", category: "SmokeTest")
        logger.info("smoke test starting")

        let claude: ClaudeCLIStatus
        do {
            let url = try ClaudeCLIRunner.locate()
            let version = await ClaudeCLIRunner.probeVersion(at: url)
            claude = ClaudeCLIStatus(installed: true, path: url.path, version: version)
        } catch {
            claude = ClaudeCLIStatus(installed: false, path: nil, version: nil)
        }

        let screenRec = ScreenRecordingPermission().isGranted
        let accessibility = AccessibilityPermission().isGranted
        let micStatus: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micStatus = "granted"
        case .denied: micStatus = "denied"
        case .restricted: micStatus = "restricted"
        case .notDetermined: micStatus = "notDetermined"
        @unknown default: micStatus = "unknown"
        }

        let displays: DisplaysStatus
        do {
            // 200 px is enough to confirm the SCK pipeline works without
            // burning JPEG-encoding cycles in a check that just needs
            // "did this raise?".
            let manifest = try await ScreenCapture.captureAllDisplays(maxWidth: 200)
            displays = DisplaysStatus(count: manifest.screens.count, captureSucceeded: true, captureError: nil)
        } catch {
            displays = DisplaysStatus(count: 0, captureSucceeded: false, captureError: String(describing: error))
        }

        let elConfig = ElevenLabsConfig.load()
        let elevenLabs = ElevenLabsStatus(
            configured: elConfig != nil,
            voiceIdPrefix: elConfig.map { String($0.voiceId.prefix(8)) }
        )

        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)"

        let report = Report(
            macosVersion: osString,
            claudeCLI: claude,
            permissions: Permissions(
                screenRecording: screenRec,
                accessibility: accessibility,
                microphone: micStatus
            ),
            displays: displays,
            elevenLabs: elevenLabs,
            passed: claude.installed
                && screenRec
                && accessibility
                && displays.captureSucceeded
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report),
           let text = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write(Data((text + "\n").utf8))
        }

        logger.info("smoke test finished passed=\(report.passed, privacy: .public)")
        return 0
    }
}
