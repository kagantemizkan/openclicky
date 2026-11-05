//
//  OverlayPlacementTests.swift
//  The reply bubble and chip must stay fully on screen near every edge.
//

import XCTest
@testable import OpenClicky

final class OverlayPlacementTests: XCTestCase {
    private let screen = CGSize(width: 1000, height: 800)
    private let box = CGSize(width: 300, height: 200)
    private let gap = CGSize(width: 28, height: 20)

    func testStaysBelowAndRightWhenThereIsRoom() {
        let origin = OverlayPlacement.boxOrigin(anchor: CGPoint(x: 100, y: 100), size: box, screen: screen, gap: gap)
        XCTAssertEqual(origin, CGPoint(x: 128, y: 120))
    }

    func testFlipsLeftNearRightEdge() {
        let origin = OverlayPlacement.boxOrigin(anchor: CGPoint(x: 950, y: 100), size: box, screen: screen, gap: gap)
        XCTAssertEqual(origin.x, 622)
        XCTAssertLessThanOrEqual(origin.x + box.width, screen.width)
    }

    func testFlipsUpNearBottomEdge() {
        let origin = OverlayPlacement.boxOrigin(anchor: CGPoint(x: 100, y: 780), size: box, screen: screen, gap: gap)
        XCTAssertEqual(origin.y, 560)
    }

    func testBoxLargerThanEitherSideStaysVisible() {
        let tall = CGSize(width: 300, height: 700)
        let origin = OverlayPlacement.boxOrigin(anchor: CGPoint(x: 100, y: 400), size: tall, screen: screen, gap: gap)
        XCTAssertEqual(origin.y, OverlayPlacement.margin)
    }

    func testChipIsClampedAtEdges() {
        let size = CGSize(width: 100, height: 30)
        let right = OverlayPlacement.chipCenter(preferred: CGPoint(x: 990, y: 400), size: size, screen: screen)
        XCTAssertEqual(right.x, 938)
        let top = OverlayPlacement.chipCenter(preferred: CGPoint(x: 400, y: 2), size: size, screen: screen)
        XCTAssertEqual(top.y, 27)
    }
}
