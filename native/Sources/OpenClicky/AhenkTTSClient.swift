//
//  AhenkTTSClient.swift
//  Talks to the local Ahenk Cep process (scripts/ahenk_tts_server.py) over
//  stdin/stdout. The process is optional: installed by scripts/setup-ahenk,
//  and if it is missing or failing the caller falls back to the system voice.
//
//  It starts once and stays loaded, because the model's first synthesis takes
//  many seconds. A process that dies restarts on the next request.
//

import Foundation
import os

struct AhenkTTSError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class AhenkTTSClient: @unchecked Sendable {
    /// Includes warm-up, because the first request can arrive during it.
    static let defaultTimeoutSeconds: TimeInterval = 45

    private let pythonURL: URL
    private let serverScriptURL: URL
    private let modelDirectoryURL: URL
    private let logFileURL: URL
    private let timeoutSeconds: TimeInterval
    private let logger = Logger(subsystem: "com.kagantemizkan.openclicky", category: "AhenkTTSClient")

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextRequestId = 1

    init(
        pythonURL: URL,
        serverScriptURL: URL,
        modelDirectoryURL: URL,
        logFileURL: URL,
        timeoutSeconds: TimeInterval = AhenkTTSClient.defaultTimeoutSeconds
    ) {
        self.pythonURL = pythonURL
        self.serverScriptURL = serverScriptURL
        self.modelDirectoryURL = modelDirectoryURL
        self.logFileURL = logFileURL
        self.timeoutSeconds = timeoutSeconds
    }

    /// The client for the default install location, or nil when the voice
    /// isn't installed or the app bundle doesn't carry the server script.
    static func installed() -> AhenkTTSClient? {
        guard let script = Bundle.main.url(forResource: "ahenk_tts_server", withExtension: "py") else {
            return nil
        }
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky/ahenk", isDirectory: true)
        let python = root.appendingPathComponent("venv/bin/python")
        let model = root.appendingPathComponent("model", isDirectory: true)
        let weights = model.appendingPathComponent("student.pt")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: weights.path) else {
            return nil
        }
        return AhenkTTSClient(
            pythonURL: python,
            serverScriptURL: script,
            modelDirectoryURL: model,
            logFileURL: root.appendingPathComponent("server.log")
        )
    }

    /// Loads the model ahead of the first reply. Safe to call repeatedly.
    func warmUp() {
        lock.lock()
        defer { lock.unlock() }
        do {
            try startProcessIfNeeded()
        } catch {
            logger.error("Ahenk warm-up failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns WAV data. Throws if the process fails or misses the deadline.
    func synthesize(_ text: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            let requestId = nextRequestId
            nextRequestId += 1
            do {
                try startProcessIfNeeded()
                let request = try JSONSerialization.data(withJSONObject: ["id": requestId, "text": text])
                pending[requestId] = continuation
                try input?.write(contentsOf: request + Data([0x0A]))
                scheduleTimeout(for: requestId)
            } catch {
                pending[requestId] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func shutdown() {
        lock.lock()
        let running = process
        lock.unlock()
        running?.terminate()
    }

    // MARK: - Process (lock held)

    private func startProcessIfNeeded() throws {
        guard process == nil else { return }

        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = pythonURL
        child.arguments = ["-I", serverScriptURL.path, modelDirectoryURL.path]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = openLogFile()
        // The weights are already on disk: never reach for the network.
        child.environment = [
            "HF_HUB_OFFLINE": "1",
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
        ]
        outputBuffer = Data()

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        child.terminationHandler = { [weak self] finished in
            stdout.fileHandleForReading.readabilityHandler = nil
            self?.processDidExit(finished)
        }

        try child.run()
        // Our copy of the read end must close, or a write after the child
        // dies wouldn't fail.
        try? stdin.fileHandleForReading.close()
        process = child
        input = stdin.fileHandleForWriting
    }

    private func openLogFile() -> Any {
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        return (try? FileHandle(forWritingTo: logFileURL)) ?? FileHandle.nullDevice
    }

    // MARK: - Events

    private func scheduleTimeout(for requestId: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let timedOut = self.pending[requestId] != nil
            let running = self.process
            self.lock.unlock()
            if timedOut {
                // Fails every pending request through processDidExit.
                self.logger.error("Ahenk request timed out; restarting")
                running?.terminate()
            }
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        outputBuffer.append(data)
        var lines: [Data] = []
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            lines.append(outputBuffer[outputBuffer.startIndex..<newline])
            outputBuffer = Data(outputBuffer[outputBuffer.index(after: newline)...])
        }
        lock.unlock()
        lines.forEach(handleLine)
    }

    private func handleLine(_ line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let requestId = message["id"] as? Int else {
            return // The ready line, or an error that names no request.
        }
        lock.lock()
        let continuation = pending.removeValue(forKey: requestId)
        lock.unlock()

        if let encoded = message["wav"] as? String, let wav = Data(base64Encoded: encoded) {
            continuation?.resume(returning: wav)
        } else {
            let reason = message["error"] as? String ?? "invalid response"
            continuation?.resume(throwing: AhenkTTSError(message: reason))
        }
    }

    private func processDidExit(_ finished: Process) {
        lock.lock()
        // A newer process may already have replaced this one.
        guard process === finished else {
            lock.unlock()
            return
        }
        let failed = pending
        pending = [:]
        process = nil
        input = nil
        lock.unlock()

        logger.warning("Ahenk process exited with status \(finished.terminationStatus, privacy: .public)")
        let error = AhenkTTSError(message: "Ahenk process exited (\(finished.terminationStatus))")
        failed.values.forEach { $0.resume(throwing: error) }
    }
}
