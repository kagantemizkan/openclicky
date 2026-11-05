//
//  ElevenLabsConfig.swift
//  Locates the user's ElevenLabs API key + voice ID, if they've set one.
//
//  Three sources in priority order:
//    1. Environment variables CLICKY_ELEVENLABS_API_KEY +
//       CLICKY_ELEVENLABS_VOICE_ID. Explicit override for power users
//       and CI.
//    2. macOS Keychain, written via the in-panel Settings sheet. This
//       is the default UX path — users paste once, the key persists.
//    3. JSON file at ~/Library/Application Support/OpenClicky/elevenlabs.json.
//       Left in place for users who prefer plaintext / git-synced dotfiles.
//

import Foundation
import os

struct ElevenLabsConfig {
    /// Pretty default voice — "Rachel" on ElevenLabs' free tier.
    static let defaultVoiceId = "kPzsL2i3teMYv0FxEYQ6"

    /// Keychain coordinates. Exposed so the Settings sheet can reuse them.
    static let keychainService = "com.kagantemizkan.openclicky.elevenlabs"
    static let keychainAPIKeyAccount = "apiKey"
    static let keychainVoiceIdAccount = "voiceId"

    let apiKey: String
    let voiceId: String

    /// Returns nil when no source yielded a key.
    static func load() -> ElevenLabsConfig? {
        let logger = Logger(subsystem: "com.kagantemizkan.openclicky", category: "ElevenLabsConfig")

        if let env = loadFromEnvironment() {
            logger.info("ElevenLabs config loaded from environment")
            return env
        }
        if let keychain = loadFromKeychain() {
            logger.info("ElevenLabs config loaded from Keychain")
            return keychain
        }
        if let file = loadFromFile() {
            logger.info("ElevenLabs config loaded from \(fileURL.path, privacy: .public)")
            return file
        }
        return nil
    }

    /// Writes a new config to Keychain and returns the saved value.
    /// An empty `apiKey` deletes the stored key; voice ID is optional.
    @discardableResult
    static func saveToKeychain(apiKey: String, voiceId: String?) -> ElevenLabsConfig? {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVoice = voiceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        _ = KeychainStorage.write(service: keychainService, account: keychainAPIKeyAccount, value: trimmedKey)
        _ = KeychainStorage.write(service: keychainService, account: keychainVoiceIdAccount, value: trimmedVoice)

        guard !trimmedKey.isEmpty else { return nil }
        return ElevenLabsConfig(
            apiKey: trimmedKey,
            voiceId: trimmedVoice.isEmpty ? defaultVoiceId : trimmedVoice
        )
    }

    /// Clears Keychain-stored credentials. Env var / JSON file sources
    /// are untouched so power-user workflows keep working.
    static func clearKeychain() {
        KeychainStorage.delete(service: keychainService, account: keychainAPIKeyAccount)
        KeychainStorage.delete(service: keychainService, account: keychainVoiceIdAccount)
    }

    // MARK: - Sources

    private static func loadFromEnvironment() -> ElevenLabsConfig? {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["CLICKY_ELEVENLABS_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        let voice = env["CLICKY_ELEVENLABS_VOICE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ElevenLabsConfig(apiKey: key, voiceId: voice?.isEmpty == false ? voice! : defaultVoiceId)
    }

    private static func loadFromKeychain() -> ElevenLabsConfig? {
        guard let key = KeychainStorage.read(service: keychainService, account: keychainAPIKeyAccount),
              !key.isEmpty else {
            return nil
        }
        let voice = KeychainStorage.read(service: keychainService, account: keychainVoiceIdAccount)
        return ElevenLabsConfig(
            apiKey: key,
            voiceId: (voice?.isEmpty == false) ? voice! : defaultVoiceId
        )
    }

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("elevenlabs.json", isDirectory: false)
    }

    private static func loadFromFile() -> ElevenLabsConfig? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            guard let key = (obj["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else {
                return nil
            }
            let voice = (obj["voiceId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ElevenLabsConfig(apiKey: key, voiceId: voice?.isEmpty == false ? voice! : defaultVoiceId)
        } catch {
            return nil
        }
    }
}
