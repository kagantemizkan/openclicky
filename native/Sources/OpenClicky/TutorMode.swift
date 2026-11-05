//
//  TutorMode.swift
//  Prompts and reply parsing for step-by-step teaching. While tutor mode is
//  on, OpenClickyViewModel takes a fresh look after each mouse click, so the
//  user can follow along without pressing the push-to-talk key.
//

import Foundation

enum TutorMode {
    /// Waits for the UI to react, and coalesces double clicks and quick
    /// click sequences into one look.
    static let settleSeconds: TimeInterval = 1.0
    /// A safety stop for automatic looks, each of which uses the user's
    /// Claude plan. Speaking to it resets the count.
    static let maxAutomaticLooks = 40

    /// Sent in place of user speech when a click triggers a look.
    static let lookPrompt = "(automatic: the user just clicked and this is a fresh screenshot. they said nothing new.)"

    private static let startHint = """
     if the user asks you to teach them or walk them through something step by step, give \
    only the first step, point at it, and add the tag [TUTOR] to your reply. you will see \
    their clicks automatically, so don't ask them to tell you after clicking, and don't \
    mention later steps yet.
    """

    private static let activeRules = """
     you are now teaching step by step. give exactly one step at a time in one or two short \
    sentences, and point at the exact element whenever there is something to click. never do \
    the step for them. you get a fresh screenshot after each click, so never ask them to tell \
    you about a click. if the step is done, briefly confirm it and give the next one. if the \
    screen shows they went somewhere wrong, kindly say how to get back. if the screen looks \
    the same as before, or they are still in the middle of the step, they may just be clicking \
    around, so don't repeat the step or nudge them: reply with exactly [WAIT] and nothing \
    else, so you stay silent. do the same if you don't know yet what they want to learn. you \
    can't see typing or key presses \
    until the next click, so for those steps ask them to tell you when they're done. when the \
    task is finished or they ask to stop, give a short closing sentence and add the tag [DONE].
    """

    static func systemPrompt(base: String, active: Bool) -> String {
        base + (active ? activeRules : startHint)
    }

    struct Reply: Equatable {
        /// The reply with signal tags removed. Any POINT tag is kept.
        let text: String
        let shouldWait: Bool
        let shouldStart: Bool
        let isFinished: Bool
    }

    private static let signalPattern = try! NSRegularExpression(pattern: #"\s*\[(WAIT|TUTOR|DONE)\]"#)

    static func parse(_ response: String) -> Reply {
        let range = NSRange(response.startIndex..., in: response)
        let signals = signalPattern.matches(in: response, range: range).compactMap { match in
            Range(match.range(at: 1), in: response).map { String(response[$0]) }
        }
        let text = signalPattern
            .stringByReplacingMatches(in: response, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Reply(
            text: text,
            shouldWait: signals.contains("WAIT"),
            shouldStart: signals.contains("TUTOR"),
            isFinished: signals.contains("DONE")
        )
    }

    /// What to show while a reply streams: everything before the first tag,
    /// so a tag never flashes in the bubble, even half-received.
    static func displayText(_ partial: String) -> String {
        String(partial.prefix { $0 != "[" }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
