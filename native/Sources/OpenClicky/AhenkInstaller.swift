//
//  AhenkInstaller.swift
//  Runs scripts/setup-ahenk, which the app bundle carries, so the local Turkish
//  voice can be installed from Settings. It downloads only when asked, and a
//  cancelled or failed run doesn't count as installed.
//

import Foundation

@MainActor
final class AhenkInstaller: ObservableObject {
    enum Step: String, Equatable {
        case tools, packages, model
    }

    enum State: Equatable {
        case idle
        case running(Step)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let scriptURL: URL?
    private let arguments: [String]
    private var process: Process?
    private var wasCancelled = false
    /// The end of the script's output, to explain a failure.
    private var recentLines: [String] = []
    private var pendingOutput = Data()
    private var onInstalled: (() -> Void)?

    init(
        scriptURL: URL? = Bundle.main.url(forResource: "setup-ahenk", withExtension: nil),
        arguments: [String] = []
    ) {
        self.scriptURL = scriptURL
        self.arguments = arguments
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func install(onInstalled: @escaping () -> Void) {
        guard !isRunning else { return }
        guard let scriptURL else {
            state = .failed(Strings.ahenkInstallMissingScript)
            return
        }
        self.onInstalled = onInstalled
        wasCancelled = false
        recentLines = []
        pendingOutput = Data()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + arguments
        // Only what it needs: this script downloads and installs.
        process.environment = [
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in self?.received(data) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in self?.finished(status: status) }
        }

        do {
            state = .running(.tools)
            try process.run()
            self.process = process
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        wasCancelled = true
        process.terminate()
    }

    private func received(_ data: Data) {
        pendingOutput.append(data)
        while let newline = pendingOutput.firstIndex(of: 0x0A) {
            let line = String(decoding: pendingOutput[pendingOutput.startIndex..<newline], as: UTF8.self)
            pendingOutput.removeSubrange(pendingOutput.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("step:") {
            if isRunning, let step = Step(rawValue: String(line.dropFirst(5))) {
                state = .running(step)
            }
            return
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        recentLines.append(trimmed)
        if recentLines.count > 4 { recentLines.removeFirst() }
    }

    private func finished(status: Int32) {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        if wasCancelled {
            state = .idle
        } else if status == 0 {
            state = .idle
            onInstalled?()
        } else {
            let detail = recentLines.joined(separator: "\n")
            state = .failed(detail.isEmpty ? Strings.ahenkInstallFailed : detail)
        }
        onInstalled = nil
    }
}
