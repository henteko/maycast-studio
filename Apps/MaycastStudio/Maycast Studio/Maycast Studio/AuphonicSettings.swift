import SwiftUI

// MARK: - Auphonic API key
//
// Thin facades over the shared `ApiKeyKeychain` / `ApiKeySettingsSheet`
// (see `ApiKeySettings.swift`). Kept so existing call sites compile unchanged.

/// Keychain access for the Auphonic API key.
enum AuphonicKeychain {
    private static let keychain = ApiKeyKeychain(.auphonic)

    static func loadKey() -> String? { keychain.loadKey() }

    @discardableResult
    static func saveKey(_ key: String) -> Bool { keychain.saveKey(key) }

    @discardableResult
    static func deleteKey() -> Bool { keychain.deleteKey() }

    /// Human-readable masked label, e.g. "configured (••••2f1a)".
    static func maskedLabel(for key: String) -> String { ApiKeyKeychain.maskedLabel(for: key) }
}

/// Sheet to enter / replace / remove the Auphonic API key.
struct AuphonicSettingsSheet: View {
    let hasExistingKey: Bool
    let onChange: (String?) -> Void

    init(hasExistingKey: Bool, onChange: @escaping (String?) -> Void) {
        self.hasExistingKey = hasExistingKey
        self.onChange = onChange
    }

    var body: some View {
        ApiKeySettingsSheet(service: .auphonic, hasExistingKey: hasExistingKey, onChange: onChange)
    }
}

#if DEBUG
#Preview("Auphonic — key set") {
    AuphonicSettingsSheet(hasExistingKey: true) { _ in }
}

#Preview("Auphonic — key missing") {
    AuphonicSettingsSheet(hasExistingKey: false) { _ in }
}
#endif
