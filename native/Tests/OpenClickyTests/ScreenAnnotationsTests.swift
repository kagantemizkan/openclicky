//
//  ScreenAnnotationsTests.swift
//  Drawing tags, placing them on screen, and how the real model uses them.
//

import AppKit
import SwiftUI
import XCTest
@testable import OpenClicky

final class ScreenAnnotationsTests: XCTestCase {
    private func manifest(frame: CGRect = CGRect(x: 0, y: 0, width: 1280, height: 832), pixels: (Int, Int) = (1280, 832)) -> CaptureManifest {
        CaptureManifest(
            screens: [CapturedScreen(
                screenNumber: 1,
                label: "screen1",
                jpegData: Data(),
                widthPx: pixels.0,
                heightPx: pixels.1,
                displayFrame: frame,
                isCursorScreen: true
            )],
            capturedAt: Date()
        )
    }

    func testParsesEachShapeAndLeavesTheWords() {
        let result = DrawTagParser.parse("şuraya bak. [CIRCLE:640,120,40] [ARROW:10,20,30,40:screen2] [BOX:1,2,3,4] [POINT:5,6:kaydet]")
        XCTAssertEqual(result.text, "şuraya bak. [POINT:5,6:kaydet]")
        XCTAssertEqual(result.tags, [
            DrawTag(shape: .circle(x: 640, y: 120, radius: 40), screen: nil),
            DrawTag(shape: .arrow(fromX: 10, fromY: 20, toX: 30, toY: 40), screen: 2),
            DrawTag(shape: .box(x: 1, y: 2, width: 3, height: 4), screen: nil),
        ])
        XCTAssertEqual(PointTagParser.parse(result.text).point?.label, "kaydet")
    }

    func testBadTagsDrawNothingAndAreNeverReadAloud() {
        let result = DrawTagParser.parse("tamam [CIRCLE:1,2] [BOX:1,2,0,5] [ARROW:5,5,5,5]")
        XCTAssertEqual(result.text, "tamam")
        XCTAssertEqual(result.tags, [])
    }

    func testOtherBracketsAreLeftAlone() {
        XCTAssertEqual(DrawTagParser.parse("dizi[0] ve [POINT:none]").text, "dizi[0] ve [POINT:none]")
    }

    func testLimitsHowMuchCanBeDrawn() {
        let many = Array(repeating: "[CIRCLE:10,10,5]", count: 9).joined(separator: " ")
        let result = DrawTagParser.parse("bak \(many)")
        XCTAssertEqual(result.tags.count, DrawTagParser.maxTags)
        XCTAssertEqual(result.text, "bak")
    }

    func testMapsFromScreenshotPixelsToTheDisplay() {
        // A 2x downscaled screenshot on a display to the right of the main one.
        let frame = CGRect(x: 1000, y: 0, width: 1280, height: 800)
        let tags = [
            DrawTag(shape: .circle(x: 100, y: 50, radius: 20), screen: nil),
            DrawTag(shape: .box(x: 0, y: 0, width: 320, height: 200), screen: nil),
            DrawTag(shape: .arrow(fromX: 0, fromY: 0, toX: 640, toY: 400), screen: nil),
        ]
        let shapes = PointCoordinateMapper.annotations(from: tags, manifest: manifest(frame: frame, pixels: (640, 400))).map(\.shape)
        XCTAssertEqual(shapes, [
            .circle(center: CGPoint(x: 1200, y: 700), radius: 40),
            .box(CGRect(x: 1000, y: 400, width: 640, height: 400)),
            .arrow(from: CGPoint(x: 1000, y: 800), to: CGPoint(x: 2280, y: 0)),
        ])
    }

    func testAScreenThatDoesntExistDrawsNothing() {
        let tags = [DrawTag(shape: .circle(x: 1, y: 1, radius: 5), screen: 3)]
        XCTAssertEqual(PointCoordinateMapper.annotations(from: tags, manifest: manifest()), [])
    }

    func testEachDrawingAppearsOnlyOnItsDisplay() {
        let annotation = ScreenAnnotation(shape: .circle(center: CGPoint(x: 1500, y: 100), radius: 10))
        XCTAssertFalse(annotation.isOn(CGRect(x: 0, y: 0, width: 1000, height: 800)))
        XCTAssertTrue(annotation.isOn(CGRect(x: 1000, y: 0, width: 1000, height: 800)))
    }

    @MainActor
    func testDrawingsClearOnAClickAndAtTheNextTurn() {
        let overlay = OverlayManager(defaults: UserDefaults(suiteName: "openclicky-draw-\(UUID().uuidString)")!)
        overlay.show([ScreenAnnotation(shape: .box(CGRect(x: 0, y: 0, width: 10, height: 10)))])
        XCTAssertEqual(overlay.annotations.count, 1)
        overlay.clearLabel()
        XCTAssertTrue(overlay.annotations.isEmpty)

        overlay.show([ScreenAnnotation(shape: .box(CGRect(x: 0, y: 0, width: 10, height: 10)))])
        overlay.reset()
        XCTAssertTrue(overlay.annotations.isEmpty)
    }

    /// Asks the real model about mock screens, and saves its drawings over
    /// them to check by eye that they land on the right things. Uses the
    /// Claude plan, so it runs only when asked for.
    @MainActor
    func testLiveDrawings() async throws {
        let env = ProcessInfo.processInfo.environment
        let mocks = env["OPENCLICKY_LIVE_MOCK_DIR"] ?? ""
        let output = env["OPENCLICKY_PREVIEW_DIR"] ?? ""
        try XCTSkipIf(mocks.isEmpty || output.isEmpty, "set OPENCLICKY_LIVE_MOCK_DIR and OPENCLICKY_PREVIEW_DIR to run")
        let runner = ClaudeCLIRunner(binaryURL: try ClaudeCLIRunner.locate())

        let cases = [
            ("1-button", "sağ üstteki kontrolleri göster, hangileri var?"),
            ("2-menu", "bu menüde vinyet nerede? daire içine al."),
            ("3-settings", "vinyet paneli ayarlarının hepsi nerede? hepsini tek seferde göster."),
            ("3-settings", "daha güçlü vinyet için miktar kaydırıcısını nereye sürüklemeliyim? göster."),
        ]
        for (index, (screen, question)) in cases.enumerated() {
            let data = try Data(contentsOf: URL(fileURLWithPath: "\(mocks)/\(screen).jpg"))
            let image = try XCTUnwrap(NSImage(data: data))
            let pixels = try XCTUnwrap(NSBitmapImageRep(data: data))
            let manifest = manifest(
                frame: CGRect(x: 0, y: 0, width: pixels.pixelsWide, height: pixels.pixelsHigh),
                pixels: (pixels.pixelsWide, pixels.pixelsHigh)
            )
            let result = try await runner.ask(
                messages: [ClaudeCLIMessage(
                    role: .user,
                    text: "screen1 (\(pixels.pixelsWide)x\(pixels.pixelsHigh))\n\(question)",
                    images: [ClaudeCLIMessage.Image(mediaType: "image/jpeg", base64: data.base64EncodedString())]
                )],
                systemPrompt: TutorMode.systemPrompt(base: OpenClickyViewModel.systemPrompt, active: false),
                model: ClaudeModel.sonnet.rawValue
            ) { _ in }
            print("LIVE \(screen) -> \(result.text)")

            let parsed = DrawTagParser.parse(TutorMode.parse(result.text).text)
            let frame = try XCTUnwrap(manifest.screens.first).displayFrame
            let view = ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().frame(width: frame.width, height: frame.height)
                ScreenAnnotationsLayer(
                    annotations: PointCoordinateMapper.annotations(from: parsed.tags, manifest: manifest),
                    screenFrame: frame,
                    color: .blue
                )
            }
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            host.frame = frame
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(CGPoint(x: -4000, y: -4000))
            window.orderFrontRegardless()
            try await Task.sleep(nanoseconds: 900_000_000)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(output)/draw-\(index + 1)-\(screen).png"))
            window.orderOut(nil)
        }
    }
}
