//
//  ClaudeCLIRunner.swift
//  Spawns the user's `claude` CLI as a subprocess and streams stream-json
//  events back. The app has no Anthropic API key — auth comes from the
//  user's Claude Code subscription via the CLI (Pencil pattern).
//
//  Flag combo validated via live experiments:
//    - NO --bare (it forbids OAuth/keychain reads → would force an API key).
//    - --verbose is required alongside --output-format stream-json + --print.
//    - --include-partial-messages delivers token-level text_delta events.
//    - Isolation flags strip CLAUDE.md, skills, MCP, hooks → 2 s spawn,
//      ~2 k input tokens.
//    - No --no-session-persistence: it is incompatible with --resume.
//

import Foundation
import os

// MARK: - Public error surface

enum ClaudeCLIError: Error, CustomStringConvertible {
    case binaryNotFound
    case notLoggedIn(stderr: String)
    case cliExitedNonZero(code: Int32, stderr: String)
    case cancelled

    var description: String {
        switch self {
        case .binaryNotFound:
            return "Could not find the `claude` CLI. Install Claude Code from https://claude.com/claude-code."
        case .notLoggedIn(let stderr):
            return "Claude CLI is not logged in. Run `claude` once in Terminal to sign in. (\(stderr))"
        case .cliExitedNonZero(let code, let stderr):
            return "claude CLI exited \(code): \(stderr)"
        case .cancelled:
            return "Claude turn was cancelled."
        }
    }
}

// MARK: - Public value types

struct ClaudeCLIMessage {
    enum Role: String { case user, assistant }

    struct Image {
        let mediaType: String   // "image/jpeg" or "image/png"
        let base64: String
    }

    let role: Role
    let text: String
    let images: [Image]

    init(role: Role, text: String, images: [Image] = []) {
        self.role = role
        self.text = text
        self.images = images
    }
}

struct ClaudeCLIStreamChunk {
    /// Accumulated assistant text so far, not just the latest delta.
    let accumulatedText: String
    let isFinal: Bool
    let totalCostUSD: Double?
}

struct ClaudeCLIRunResult {
    let text: String
    let sessionId: String?
    let totalCostUSD: Double?
    let durationMs: Int?
    var usage: TokenUsage? = nil
}

// MARK: - Runner

final class ClaudeCLIRunner {
    private let binaryURL: URL
    private let logger = Logger(subsystem: "com.proyecto26.openclicky", category: "ClaudeCLIRunner")

    init(binaryURL: URL) {
        self.binaryURL = binaryURL
    }

    /// Locates the `claude` binary. Search order:
    ///   1. `CLICKY_CLAUDE_BIN` env override
    ///   2. `/opt/homebrew/bin/claude`
    ///   3. `/usr/local/bin/claude`
    ///   4. `~/.claude/local/claude`
    ///   5. `~/.local/bin/claude`
    ///   6. `which claude` fallback
    static func locate() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()

        let candidates: [String] = [
            env["CLICKY_CLAUDE_BIN"],
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
        ].compactMap { $0 }

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let whichResult = runWhichClaude(),
           !whichResult.isEmpty,
           FileManager.default.isExecutableFile(atPath: whichResult) {
            return URL(fileURLWithPath: whichResult)
        }

        throw ClaudeCLIError.binaryNotFound
    }

    private static func runWhichClaude() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Probes `claude --version`. Returns nil on failure.
    static func probeVersion(at binary: URL) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    /// Streams a single turn through the CLI.
    /// Returns `(text, session_id, cost, duration)` on success; throws on error.
    /// When `resumeSessionId` is non-nil, the turn continues a prior session via `--resume`.
    func ask(
        messages: [ClaudeCLIMessage],
        systemPrompt: String,
        model: String,
        resumeSessionId: String? = nil,
        onChunk: @escaping @Sendable (ClaudeCLIStreamChunk) -> Void
    ) async throws -> ClaudeCLIRunResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = buildArgs(
            systemPrompt: systemPrompt,
            model: model,
            resumeSessionId: resumeSessionId
        )

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain stderr into a buffer concurrently — otherwise the kernel
        // pipe buffer fills and the CLI blocks on write.
        let stderrBuffer = StderrCollector()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrBuffer.append(chunk)
        }

        let payload = try buildStreamJsonPayload(for: messages)

        do {
            try process.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ClaudeCLIError.cliExitedNonZero(code: -1, stderr: error.localizedDescription)
        }

        stdinPipe.fileHandleForWriting.write(payload)
        try? stdinPipe.fileHandleForWriting.close()

        var accumulatedText = ""
        var sessionId: String? = nil
        var finalCostUSD: Double? = nil
        var finalDurationMs: Int? = nil
        var usage: TokenUsage? = nil

        var replyComplete = false
        let startedAt = Date()

        let lineStream = Self.makeLineStream(reading: stdoutPipe.fileHandleForReading)

        do {
            readLoop: for try await line in lineStream {
                try Task.checkCancellation()
                guard let event = parseJSON(line) else { continue }
                if let latest = event.usage { usage = latest }

                switch event.type {
                case "system" where event.subtype == "init":
                    if let sid = event.sessionId { sessionId = sid }
                    if let source = event.apiKeySource {
                        logger.debug("claude CLI init: apiKeySource=\(source, privacy: .public) session=\(sessionId ?? "<none>", privacy: .public)")
                    }

                case "stream_event":
                    if let delta = event.textDelta {
                        accumulatedText += delta
                        onChunk(ClaudeCLIStreamChunk(accumulatedText: accumulatedText, isFinal: false, totalCostUSD: nil))
                    }
                    // With no tools there is exactly one message, so the reply
                    // is complete here. The CLI then spends ~3 s on a post-turn
                    // summary before its result event; the session is already
                    // saved and resumes fine, so don't keep the user waiting.
                    if event.isMessageStop, !accumulatedText.isEmpty {
                        replyComplete = true
                        break readLoop
                    }

                case "result":
                    finalCostUSD = event.totalCostUSD
                    finalDurationMs = event.durationMs
                    if event.sessionId != nil {
                        sessionId = event.sessionId
                    }

                default:
                    break
                }
            }
        } catch is CancellationError {
            process.terminate()
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ClaudeCLIError.cancelled
        }

        if replyComplete {
            process.terminate()
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            logger.info("Claude reply complete after \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 1), privacy: .public)s")
            onChunk(ClaudeCLIStreamChunk(accumulatedText: accumulatedText, isFinal: true, totalCostUSD: nil))
            return ClaudeCLIRunResult(
                text: accumulatedText,
                sessionId: sessionId,
                totalCostUSD: nil,
                durationMs: nil,
                usage: usage
            )
        }

        process.waitUntilExit()
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let stderrText = stderrBuffer.snapshot()

        if process.terminationStatus != 0 {
            if stderrText.localizedCaseInsensitiveContains("not logged in") ||
                stderrText.localizedCaseInsensitiveContains("/login") ||
                stderrText.localizedCaseInsensitiveContains("unauthenticated") {
                throw ClaudeCLIError.notLoggedIn(stderr: stderrText)
            }
            throw ClaudeCLIError.cliExitedNonZero(code: process.terminationStatus, stderr: stderrText)
        }

        onChunk(ClaudeCLIStreamChunk(accumulatedText: accumulatedText, isFinal: true, totalCostUSD: finalCostUSD))
        return ClaudeCLIRunResult(
            text: accumulatedText,
            sessionId: sessionId,
            totalCostUSD: finalCostUSD,
            durationMs: finalDurationMs,
            usage: usage
        )
    }

    // MARK: - Private helpers

    /// Exposed `internal` (not `private`) so the XCTest suite can verify the
    /// flag combo stays in sync with the validated experiments. Do not call
    /// from non-test code — use `ask(...)` as the public entry point.
    func buildArgs(
        systemPrompt: String,
        model: String,
        resumeSessionId: String?
    ) -> [String] {
        var args: [String] = [
            "--print",
            "--verbose",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--model", model,
            "--system-prompt", systemPrompt,
            // By default a resumed conversation keeps the prompt from its
            // first request and ignores this one, which would hide the
            // tutor rules from a conversation already under way.
            "--system-prompt-snapshot", "off",
            "--setting-sources", "",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config", "{\"mcpServers\":{}}",
            "--exclude-dynamic-system-prompt-sections",
            // An empty allowlist, not a denylist: a tool added by a future
            // CLI release can't become available to this process.
            "--tools", "",
        ]
        if let resume = resumeSessionId {
            args.append(contentsOf: ["--resume", resume])
        }
        return args
    }

    private func buildStreamJsonPayload(for messages: [ClaudeCLIMessage]) throws -> Data {
        guard let currentTurn = messages.last(where: { $0.role == .user }) else {
            throw ClaudeCLIError.cliExitedNonZero(code: -1, stderr: "no user message to send")
        }

        var contentBlocks: [[String: Any]] = []
        for image in currentTurn.images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mediaType,
                    "data": image.base64,
                ],
            ])
        }
        if !currentTurn.text.isEmpty {
            contentBlocks.append([
                "type": "text",
                "text": currentTurn.text,
            ])
        }

        let envelope: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": contentBlocks,
            ],
            "session_id": "",
            "parent_tool_use_id": NSNull(),
        ]

        var data = try JSONSerialization.data(withJSONObject: envelope, options: [])
        data.append(0x0A) // newline terminator
        return data
    }

    private func parseJSON(_ line: String) -> ParsedEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return nil
        }
        return ParsedEvent(
            type: type,
            subtype: obj["subtype"] as? String,
            sessionId: obj["session_id"] as? String,
            apiKeySource: obj["apiKeySource"] as? String,
            textDelta: extractTextDelta(from: obj),
            isMessageStop: (obj["event"] as? [String: Any])?["type"] as? String == "message_stop",
            totalCostUSD: obj["total_cost_usd"] as? Double,
            durationMs: obj["duration_ms"] as? Int,
            usage: TokenUsage(streamLine: obj)
        )
    }

    private func extractTextDelta(from obj: [String: Any]) -> String? {
        guard let event = obj["event"] as? [String: Any],
              (event["type"] as? String) == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              (delta["type"] as? String) == "text_delta",
              let text = delta["text"] as? String else {
            return nil
        }
        return text
    }

    private static func makeLineStream(reading handle: FileHandle) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            var buffer = Data()
            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    if !buffer.isEmpty, let last = String(data: buffer, encoding: .utf8), !last.isEmpty {
                        continuation.yield(last)
                    }
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        continuation.yield(line)
                    }
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }
}

// MARK: - Internal types

private struct ParsedEvent {
    let type: String
    let subtype: String?
    let sessionId: String?
    let apiKeySource: String?
    let textDelta: String?
    let isMessageStop: Bool
    let totalCostUSD: Double?
    let durationMs: Int?
    let usage: TokenUsage?
}

private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        let copy = data
        lock.unlock()
        return String(data: copy, encoding: .utf8) ?? ""
    }
}
