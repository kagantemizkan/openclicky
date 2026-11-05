//
//  SessionBridgeTests.swift
//  Pure-logic tests for decoding bridge commands and mapping them to the
//  display the session looked at.
//

import XCTest
@testable import OpenClicky

final class SessionBridgeTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

    private func command(x: Double = 0, y: Double = 0, width: Int = 1280, height: Int = 800, screen: Int? = nil) -> BridgePointCommand {
        BridgePointCommand(x: x, y: y, imageWidth: width, imageHeight: height, screen: screen, label: "Save")
    }

    func testDecodesWithOptionalFieldsMissing() throws {
        let json = #"{"x":10,"y":20,"imageWidth":1280,"imageHeight":800}"#
        let decoded = try JSONDecoder().decode(BridgePointCommand.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.x, 10)
        XCTAssertNil(decoded.screen)
        XCTAssertNil(decoded.label)
    }

    func testDefaultsToMainDisplayAndFlipsY() throws {
        let target = try XCTUnwrap(command(x: 640, y: 200).target(displayFrames: [main, external]))
        XCTAssertEqual(target.displayFrame, main)
        XCTAssertEqual(target.globalLocation.x, 756, accuracy: 0.001)
        XCTAssertEqual(target.globalLocation.y, 736.5, accuracy: 0.001)
        XCTAssertEqual(target.label, "Save")
    }

    func testScreenNumberSelectsDisplayAndAddsItsOrigin() throws {
        let target = try XCTUnwrap(command(x: 0, y: 800, screen: 2).target(displayFrames: [main, external]))
        XCTAssertEqual(target.displayFrame, external)
        XCTAssertEqual(target.globalLocation, CGPoint(x: 1512, y: 0))
    }

    func testRejectsUnknownDisplay() {
        XCTAssertNil(command(screen: 3).target(displayFrames: [main, external]))
    }

    func testRejectsInvalidImageSize() {
        XCTAssertNil(command(width: 0).target(displayFrames: [main]))
    }
}
