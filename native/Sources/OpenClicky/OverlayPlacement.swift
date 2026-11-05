//
//  OverlayPlacement.swift
//  Keeps the reply bubble and label chip on screen when the pointer is
//  near an edge. Pure geometry in top-left-origin view coordinates.
//

import CoreGraphics

enum OverlayPlacement {
    static let margin: CGFloat = 12

    /// Top-left corner for a box beside `anchor`. Sits below and to the
    /// right by default, flips to the opposite side when it wouldn't fit,
    /// and is finally clamped so it stays visible even if neither side fits.
    static func boxOrigin(anchor: CGPoint, size: CGSize, screen: CGSize, gap: CGSize) -> CGPoint {
        CGPoint(
            x: placed(anchor: anchor.x, length: size.width, available: screen.width, gap: gap.width),
            y: placed(anchor: anchor.y, length: size.height, available: screen.height, gap: gap.height)
        )
    }

    /// Centre for a chip whose preferred centre is `preferred`.
    static func chipCenter(preferred: CGPoint, size: CGSize, screen: CGSize) -> CGPoint {
        CGPoint(
            x: clamp(preferred.x, length: size.width, available: screen.width),
            y: clamp(preferred.y, length: size.height, available: screen.height)
        )
    }

    private static func placed(anchor: CGFloat, length: CGFloat, available: CGFloat, gap: CGFloat) -> CGFloat {
        var start = anchor + gap
        if start + length > available - margin {
            start = anchor - gap - length
        }
        return max(margin, min(start, available - margin - length))
    }

    private static func clamp(_ center: CGFloat, length: CGFloat, available: CGFloat) -> CGFloat {
        let half = length / 2
        return max(margin + half, min(center, available - margin - half))
    }
}
