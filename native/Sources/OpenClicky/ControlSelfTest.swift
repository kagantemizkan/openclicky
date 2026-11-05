//
//  ControlSelfTest.swift
//  `OpenClicky --control-test <report path>` checks the real mouse, keyboard and
//  accessibility path against a small window of its own, then exits. It needs
//  the app's own Accessibility permission, which a unit test run doesn't have.
//

import AppKit
import Foundation

@MainActor
enum ControlSelfTest {
    private final class Clicks: NSObject {
        var count = 0
        @objc func clicked() { count += 1 }
    }

    static func run(reportPath: String) async -> Int32 {
        var results: [String: String] = ["accessibility": AXIsProcessTrusted() ? "granted" : "missing"]
        func finish(_ code: Int32) -> Int32 {
            let data = (try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            try? data.write(to: URL(fileURLWithPath: reportPath))
            return code
        }
        guard AXIsProcessTrusted(), let screen = NSScreen.screens.first else { return finish(1) }

        let size = NSSize(width: 460, height: 300)
        let window = NSWindow(
            contentRect: NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenClicky self-test"
        window.level = .floating
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content

        let clicks = Clicks()
        let plain = NSButton(title: "Filtreler", target: clicks, action: #selector(Clicks.clicked))
        plain.frame = NSRect(x: 20, y: 250, width: 120, height: 32)
        let buy = NSButton(title: "Satın Al", target: nil, action: nil)
        buy.frame = NSRect(x: 160, y: 250, width: 120, height: 32)
        let delete = NSButton(title: "Delete", target: nil, action: nil)
        delete.frame = NSRect(x: 300, y: 250, width: 120, height: 32)
        let field = NSTextField(frame: NSRect(x: 20, y: 200, width: 400, height: 26))
        let secure = NSSecureTextField(frame: NSRect(x: 20, y: 160, width: 400, height: 26))
        let slider = NSSlider(frame: NSRect(x: 20, y: 110, width: 400, height: 26))
        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = 10
        [plain, buy, delete, field, secure, slider].forEach(content.addSubview)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 800_000_000)

        let poster = SystemControlPoster()
        let inspector = SystemControlInspector()
        let height = screen.frame.height
        let original = poster.mouseLocation
        func center(_ view: NSView, atFraction fraction: CGFloat = 0.5) -> CGPoint {
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            return ControlExecutor.displayPoint(
                fromAppKit: CGPoint(x: frame.minX + frame.width * fraction, y: frame.midY),
                primaryHeight: height
            )
        }
        func settle() async { try? await Task.sleep(nanoseconds: 350_000_000) }

        await poster.click(at: center(plain), button: .left, count: 1)
        await settle()
        results["click"] = clicks.count == 1 ? "pass" : "fail: \(clicks.count) clicks"

        await poster.click(at: center(field), button: .left, count: 1)
        await settle()
        await poster.type("Merhaba ğüşiöç")
        await settle()
        results["type"] = field.stringValue == "Merhaba ğüşiöç" ? "pass" : "fail: \(field.stringValue)"

        await poster.press(ControlKeys.press(named: "cmd+a")!)
        await poster.press(ControlKeys.press(named: "delete")!)
        await settle()
        results["keys"] = field.stringValue.isEmpty ? "pass" : "fail: \(field.stringValue)"

        await poster.drag(from: center(slider, atFraction: 0.1), to: center(slider, atFraction: 0.8))
        await settle()
        results["drag"] = slider.doubleValue > 60 ? "pass" : "fail: \(slider.doubleValue)"

        // The rules against what accessibility really reports, with this app's
        // own block lifted so the words and field types are what's judged.
        func verdict(_ action: ControlAction, _ target: ControlTarget) -> String {
            var target = target
            target.bundleId = "com.example.other"
            return "\(ControlPolicy.evaluate(action, target: target, allowsBrowsers: false))"
        }
        let anyClick = ControlAction.click(x: 0, y: 0, button: .left, count: 1, screen: nil)
        let plainTarget = inspector.target(at: center(plain))
        results["inspect.plain"] = "\(plainTarget.role ?? "?") · \(plainTarget.label) · \(plainTarget.bundleId ?? "?")"
        results["policy.plain"] = verdict(anyClick, plainTarget)
        results["policy.buy"] = verdict(anyClick, inspector.target(at: center(buy)))
        results["policy.delete"] = verdict(anyClick, inspector.target(at: center(delete)))
        await poster.click(at: center(secure), button: .left, count: 1)
        await settle()
        let focused = inspector.focusedTarget()
        results["inspect.secure"] = "\(focused.role ?? "?") · \(focused.subrole ?? "?")"
        results["policy.secure"] = verdict(.type("x"), focused)
        results["policy.ownAppIsBanned"] = "\(ControlPolicy.evaluate(anyClick, target: plainTarget, allowsBrowsers: false))"

        window.orderOut(nil)
        // Put the pointer back where it was.
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: original, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        return finish(0)
    }
}
