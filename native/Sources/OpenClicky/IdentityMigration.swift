//
//  IdentityMigration.swift
//  The app's bundle identifier changed. macOS keeps settings and Keychain items
//  under the identifier, so they move across once, the first time this runs.
//  The old settings stay where they were; the old Keychain item is removed only
//  after the new one reads back correctly.
//

import Foundation

enum IdentityMigration {
    static let oldIdentifier = "com.proyecto26.openclicky"
    static let newIdentifier = "com.kagantemizkan.openclicky"
    static let doneKey = "\(newIdentifier).movedFromOldIdentifier"

    static func run() {
        run(
            defaults: .standard,
            oldSettings: UserDefaults.standard.persistentDomain(forName: oldIdentifier),
            moveKeychain: {
                for account in [ElevenLabsConfig.keychainAPIKeyAccount, ElevenLabsConfig.keychainVoiceIdAccount] {
                    moveKeychainItem(
                        from: "\(oldIdentifier).elevenlabs",
                        to: ElevenLabsConfig.keychainService,
                        account: account
                    )
                }
            }
        )
    }

    static func run(defaults: UserDefaults, oldSettings: [String: Any]?, moveKeychain: () -> Void) {
        guard !defaults.bool(forKey: doneKey) else { return }
        if let oldSettings {
            moveSettings(oldSettings, into: defaults)
        }
        moveKeychain()
        defaults.set(true, forKey: doneKey)
    }

    /// Anything already set under the new identifier wins.
    static func moveSettings(_ old: [String: Any], into defaults: UserDefaults) {
        for (key, value) in old {
            let newKey = key.hasPrefix(oldIdentifier)
                ? newIdentifier + key.dropFirst(oldIdentifier.count)
                : key
            if defaults.object(forKey: newKey) == nil {
                defaults.set(value, forKey: newKey)
            }
        }
    }

    static func moveKeychainItem(from oldService: String, to newService: String, account: String) {
        guard KeychainStorage.read(service: newService, account: account) == nil,
              let value = KeychainStorage.read(service: oldService, account: account),
              KeychainStorage.write(service: newService, account: account, value: value),
              KeychainStorage.read(service: newService, account: account) == value else { return }
        KeychainStorage.delete(service: oldService, account: account)
    }
}
