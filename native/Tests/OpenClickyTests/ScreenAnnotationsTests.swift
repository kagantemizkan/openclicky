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
                    style: DrawingStyle()
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

    func testColorsSurviveSavingAndOlderSettingsStillLoad() {
        XCTAssertEqual(ThemeColor(hex: "#112233")?.hex, "#112233")
        XCTAssertEqual(ThemeColor(stored: "pink"), .pink)
        XCTAssertEqual(ThemeColor(stored: "#D64896"), .pink)
        XCTAssertNil(ThemeColor(hex: "nope"))
        XCTAssertEqual(ThemeColor(ThemeColor.orange.nsColor), .orange)
    }

    @MainActor
    func testAppearanceIsSavedFollowsTheCursorAndResets() {
        let defaults = UserDefaults(suiteName: "openclicky-look-\(UUID().uuidString)")!
        let first = AppPreferences(defaults: defaults)
        first.cursorColor = .pink
        XCTAssertEqual(first.captionStyle.background, .pink)
        XCTAssertEqual(first.drawingStyle.color, .pink)

        first.drawingColor = .green
        first.drawingLineWidth = 7
        first.drawingLine = .dotted
        first.drawingLook = .clean
        first.captionColor = .slate
        first.captionOpacity = 0.7
        first.captionFont = .mono

        let again = AppPreferences(defaults: defaults)
        XCTAssertEqual(again.drawingStyle, DrawingStyle(color: .green, lineWidth: 7, line: .dotted, look: .clean, hasEdge: true))
        XCTAssertEqual(again.captionStyle.background, .slate)
        XCTAssertEqual(again.captionStyle.opacity, 0.7)
        XCTAssertEqual(again.captionStyle.font, .mono)

        again.resetAppearance()
        XCTAssertEqual(again.drawingStyle, DrawingStyle())
        XCTAssertEqual(again.captionStyle, CaptionStyle())
    }

    @MainActor
    func testRenderCustomLooks() throws {
        let output = ProcessInfo.processInfo.environment["OPENCLICKY_PREVIEW_DIR"] ?? ""
        try XCTSkipIf(output.isEmpty, "set OPENCLICKY_PREVIEW_DIR to run")
        let defaults = UserDefaults(suiteName: "openclicky-render-\(UUID().uuidString)")!
        let preferences = AppPreferences(defaults: defaults)
        func save(_ name: String) throws {
            let host = NSHostingView(rootView: AppearanceSettings(preferences: preferences).frame(width: 480, height: 900))
            host.frame = CGRect(x: 0, y: 0, width: 480, height: 900)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(CGPoint(x: -4000, y: -4000))
            window.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.9))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(output)/look-\(name).png"))
            window.orderOut(nil)
        }
        try save("default")
        preferences.cursorColor = ThemeColor(hex: "#7A3CFF")!
        preferences.captionColor = ThemeColor(hex: "#101820")!
        preferences.captionTextColor = ThemeColor(hex: "#F2C14E")!
        preferences.captionCornerRadius = 0
        preferences.captionFont = .mono
        preferences.drawingColor = ThemeColor(hex: "#FF3B30")!
        preferences.drawingLineWidth = 6
        preferences.drawingLine = .dashed
        preferences.drawingLook = .clean
        preferences.drawingHasEdge = false
        try save("custom")
    }

    // MARK: Keeping drawings readable

    private let display = CGRect(x: 0, y: 0, width: 1280, height: 800)

    func testTheCursorWaitsBehindAnArrowsTail() {
        let arrow = ScreenAnnotation(shape: .arrow(from: CGPoint(x: 400, y: 400), to: CGPoint(x: 700, y: 400)))
        XCTAssertEqual(arrow.cursorAnchor(on: display), CGPoint(x: 370, y: 400))
    }

    func testTheCursorStaysOnTheDisplay() {
        let arrow = ScreenAnnotation(shape: .arrow(from: CGPoint(x: 0, y: 799), to: CGPoint(x: 300, y: 799)))
        let spot = arrow.cursorAnchor(on: display)
        XCTAssertTrue(display.contains(spot))
    }

    func testAPointOnADrawingGivesWayAndOneElsewhereStays() {
        let arrow = ScreenAnnotation(shape: .arrow(from: CGPoint(x: 400, y: 400), to: CGPoint(x: 700, y: 400)))
        XCTAssertEqual(
            ScreenAnnotation.cursorSpot(pointing: CGPoint(x: 700, y: 400), annotations: [arrow], display: display),
            CGPoint(x: 370, y: 400)
        )
        XCTAssertEqual(
            ScreenAnnotation.cursorSpot(pointing: CGPoint(x: 100, y: 100), annotations: [arrow], display: display),
            CGPoint(x: 100, y: 100)
        )
        XCTAssertNil(ScreenAnnotation.cursorSpot(pointing: nil, annotations: [], display: display))
    }

    func testADiagonalArrowOnlyKeepsItsOwnPathClear() {
        let arrow = ScreenAnnotation(shape: .arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 700, y: 700)))
        let rects = arrow.keepClear
        XCTAssertTrue(rects.contains { $0.contains(CGPoint(x: 400, y: 400)) })
        XCTAssertFalse(rects.contains { $0.contains(CGPoint(x: 650, y: 150)) })
    }

    func testTheMessageStaysPutUnlessItWouldCoverSomething() {
        let size = CGSize(width: 200, height: 80)
        let screen = CGSize(width: 1280, height: 800)
        let gap = CGSize(width: 14, height: 27)
        let anchor = CGPoint(x: 300, y: 300)
        let usual = OverlayPlacement.boxOrigin(anchor: anchor, size: size, screen: screen, gap: gap)
        XCTAssertEqual(usual, CGPoint(x: 314, y: 327))
        XCTAssertEqual(
            OverlayPlacement.boxOrigin(anchor: anchor, size: size, screen: screen, gap: gap, avoiding: [CGRect(x: 900, y: 600, width: 50, height: 50)]),
            usual
        )

        let inTheWay = CGRect(x: 320, y: 330, width: 300, height: 200)
        let moved = OverlayPlacement.boxOrigin(anchor: anchor, size: size, screen: screen, gap: gap, avoiding: [inTheWay])
        XCTAssertFalse(CGRect(origin: moved, size: size).intersects(inTheWay))
        XCTAssertTrue(CGRect(x: 12, y: 12, width: 1256, height: 776).contains(CGRect(origin: moved, size: size)))
    }

    func testWithNowhereFreeTheMessageCoversTheLeast() {
        let size = CGSize(width: 200, height: 80)
        let screen = CGSize(width: 400, height: 200)
        let large = CGRect(x: 0, y: 0, width: 400, height: 130)
        let moved = OverlayPlacement.boxOrigin(anchor: CGPoint(x: 100, y: 60), size: size, screen: screen, gap: CGSize(width: 14, height: 27), avoiding: [large])
        // The free strip at the bottom is 70 tall, so only 22 rows overlap.
        XCTAssertEqual(moved.y, 108)
    }

    @MainActor
    func testADragKeepsTheMessageStillAndClearOfItsPath() async throws {
        let overlay = OverlayManager(defaults: UserDefaults(suiteName: "openclicky-pin-\(UUID().uuidString)")!)
        overlay.flyTo(BlueCursorTarget(globalLocation: CGPoint(x: 100, y: 100), displayFrame: display, label: nil))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        overlay.glide(to: CGPoint(x: 300, y: 300), duration: 0.05)
        XCTAssertNotNil(overlay.captionPin)
        XCTAssertEqual(overlay.dragKeepClear.count, 1)
        XCTAssertTrue(overlay.dragKeepClear[0].contains(CGPoint(x: 200, y: 200)))

        overlay.flyTo(BlueCursorTarget(globalLocation: CGPoint(x: 50, y: 50), displayFrame: display, label: nil))
        XCTAssertNil(overlay.captionPin)
        XCTAssertTrue(overlay.dragKeepClear.isEmpty)
    }

    /// Reply, cursor and drawings together, as the overlay draws them.
    @MainActor
    func testRenderRepliesWithDrawings() async throws {
        let output = ProcessInfo.processInfo.environment["OPENCLICKY_PREVIEW_DIR"] ?? ""
        try XCTSkipIf(output.isEmpty, "set OPENCLICKY_PREVIEW_DIR to run")
        let text = "miktar kaydırıcısını sağa doğru sürükle, vinyet o kadar güçlenir ve fark hemen görünür."
        let cases: [(String, [ScreenAnnotation], CGPoint?)] = [
            ("arrow-down-right", [ScreenAnnotation(shape: .arrow(from: CGPoint(x: 400, y: 600), to: CGPoint(x: 700, y: 300)))], nil),
            ("arrow-up-left", [ScreenAnnotation(shape: .arrow(from: CGPoint(x: 800, y: 200), to: CGPoint(x: 500, y: 500)))], nil),
            ("point-on-arrow-tip", [ScreenAnnotation(shape: .arrow(from: CGPoint(x: 300, y: 400), to: CGPoint(x: 700, y: 400)))], CGPoint(x: 700, y: 400)),
            ("box-bottom-right", [ScreenAnnotation(shape: .box(CGRect(x: 850, y: 60, width: 380, height: 240)))], nil),
            ("circle", [ScreenAnnotation(shape: .circle(center: CGPoint(x: 600, y: 420), radius: 50))], nil),
        ]
        for (name, annotations, point) in cases {
            let overlay = OverlayManager(defaults: UserDefaults(suiteName: "openclicky-reply-\(UUID().uuidString)")!)
            overlay.screenFrames = { [self.display] }
            let spot = try XCTUnwrap(ScreenAnnotation.cursorSpot(pointing: point, annotations: annotations, display: display))
            overlay.flyTo(BlueCursorTarget(globalLocation: spot, displayFrame: display, label: nil))
            overlay.show(annotations)
            overlay.streamingResponseText = text
            try await Task.sleep(nanoseconds: 1_500_000_000)

            let view = BlueCursorView(screenFrame: display, manager: overlay).background(Color(white: 0.2))
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            host.frame = display
            let window = NSWindow(contentRect: display, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(CGPoint(x: -4000, y: -4000))
            window.orderFrontRegardless()
            try await Task.sleep(nanoseconds: 900_000_000)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(output)/reply-\(name).png"))
            window.orderOut(nil)
        }
    }
}
