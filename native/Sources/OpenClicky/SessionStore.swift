//
//  SessionStore.swift
//  The user's named conversations and the tokens each has used.
//
//  File: ~/Library/Application Support/OpenClicky/sessions.json
//
//  A session has its own id because the Claude CLI's session id can change
//  when a conversation is resumed; the latest one is kept alongside.
//

import Combine
import Foundation
import os

struct TokenUsage: Codable, Equatable {
    var input = 0
    var cacheWrite = 0
    var cacheRead = 0
    var output = 0

    /// Tokens processed afresh. Cache reads are left out: each turn re-reads
    /// the whole conversation, so adding them up would count it many times.
    var total: Int { input + cacheWrite + output }

    /// How much conversation a turn carried. Grows with each screenshot.
    var contextSize: Int { input + cacheWrite + cacheRead }

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: a.input + b.input,
            cacheWrite: a.cacheWrite + b.cacheWrite,
            cacheRead: a.cacheRead + b.cacheRead,
            output: a.output + b.output
        )
    }
}

extension TokenUsage {
    /// Reads a Claude `usage` object.
    init?(json: [String: Any]?) {
        guard let json else { return nil }
        self.init(
            input: json["input_tokens"] as? Int ?? 0,
            cacheWrite: json["cache_creation_input_tokens"] as? Int ?? 0,
            cacheRead: json["cache_read_input_tokens"] as? Int ?? 0,
            output: json["output_tokens"] as? Int ?? 0
        )
    }

    /// Reads usage from a stream-json line, if it carries any. The final
    /// `message_delta` repeats the input counts with the finished output count.
    init?(streamLine obj: [String: Any]) {
        if let event = obj["event"] as? [String: Any] {
            switch event["type"] as? String {
            case "message_start":
                self.init(json: (event["message"] as? [String: Any])?["usage"] as? [String: Any])
            case "message_delta":
                self.init(json: event["usage"] as? [String: Any])
            default:
                return nil
            }
        } else if obj["type"] as? String == "result" {
            self.init(json: obj["usage"] as? [String: Any])
        } else {
            return nil
        }
    }
}

struct ChatSession: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var isNamedByUser = false
    var claudeSessionId: String?
    var createdAt: Date
    var updatedAt: Date
    var turns = 0
    var usage = TokenUsage()
    var lastContextTokens = 0

    var isEmpty: Bool { turns == 0 && claudeSessionId == nil }
}

@MainActor
final class SessionStore: ObservableObject {
    /// An unnamed conversation resumes only within this window. Every turn
    /// keeps its screenshots, so an endless one grows slower and uses more of
    /// the user's plan. A session the user named stays until they leave it.
    static let maxIdleSeconds: TimeInterval = 30 * 60
    private static let maxAutoNameLength = 40
    private static let maxUnnamedKept = 30

    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var activeId: UUID

    private struct Stored: Codable {
        var activeId: UUID
        var sessions: [ChatSession]
    }

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.proyecto26.openclicky", category: "SessionStore")

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    init(fileURL: URL = SessionStore.defaultFileURL) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? decoder.decode(Stored.self, from: data),
           stored.sessions.contains(where: { $0.id == stored.activeId }) {
            sessions = stored.sessions
            activeId = stored.activeId
        } else {
            let first = Self.makeSession(name: nil, now: Date())
            sessions = [first]
            activeId = first.id
        }
    }

    var active: ChatSession {
        sessions.first { $0.id == activeId } ?? sessions[0]
    }

    /// Most recently used first.
    var ordered: [ChatSession] {
        sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The Claude session to resume for the next turn. Starts a new session
    /// first if the active one has gone stale.
    func resumeIdForNextTurn(now: Date = Date()) -> String? {
        let current = active
        if !current.isNamedByUser, !current.isEmpty,
           now.timeIntervalSince(current.updatedAt) > Self.maxIdleSeconds {
            logger.info("Active session is stale; starting a new one")
            startNew(now: now)
            return nil
        }
        return current.claudeSessionId
    }

    /// Saves a finished turn. `prompt` names a still-unnamed session; pass nil
    /// for turns the user didn't ask for.
    func recordTurn(claudeSessionId: String?, usage: TokenUsage?, prompt: String?, now: Date = Date()) {
        mutateActive { session in
            if let claudeSessionId { session.claudeSessionId = claudeSessionId }
            if session.turns == 0, !session.isNamedByUser, let prompt {
                session.name = Self.autoName(from: prompt)
            }
            session.turns += 1
            session.updatedAt = now
            if let usage {
                session.usage = session.usage + usage
                session.lastContextTokens = usage.contextSize
            }
        }
    }

    /// Makes a new session active. An empty active session is reused rather
    /// than leaving a pile of blank entries in the list.
    @discardableResult
    func startNew(name: String? = nil, now: Date = Date()) -> ChatSession {
        if active.isEmpty {
            if let name { rename(active.id, to: name) }
            return active
        }
        let session = Self.makeSession(name: name, now: now)
        sessions.append(session)
        activeId = session.id
        pruneUnnamed()
        save()
        return session
    }

    func activate(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }), id != activeId else { return }
        activeId = id
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].name = trimmed
        sessions[index].isNamedByUser = true
        save()
    }

    /// Removes the session from this list. Claude's own transcript stays on
    /// disk, governed by the CLI's retention settings.
    func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if sessions.isEmpty {
            sessions = [Self.makeSession(name: nil, now: Date())]
        }
        if !sessions.contains(where: { $0.id == activeId }) {
            activeId = ordered[0].id
        }
        save()
    }

    /// Claude no longer has this conversation, so the next turn starts over.
    func forgetClaudeSession() {
        mutateActive { $0.claudeSessionId = nil }
    }

    // MARK: - Private

    private static func makeSession(name: String?, now: Date) -> ChatSession {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ChatSession(
            id: UUID(),
            name: trimmed.isEmpty ? Strings.newSessionName : trimmed,
            isNamedByUser: !trimmed.isEmpty,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func autoName(from prompt: String) -> String {
        let flat = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > maxAutoNameLength else { return flat }
        return String(flat.prefix(maxAutoNameLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func pruneUnnamed() {
        let unnamed = ordered.filter { !$0.isNamedByUser && $0.id != activeId }
        for session in unnamed.dropFirst(Self.maxUnnamedKept) {
            sessions.removeAll { $0.id == session.id }
        }
    }

    private func mutateActive(_ change: (inout ChatSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == activeId }) else { return }
        change(&sessions[index])
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(Stored(activeId: activeId, sessions: sessions))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save sessions: \(error.localizedDescription, privacy: .public)")
        }
    }
}
