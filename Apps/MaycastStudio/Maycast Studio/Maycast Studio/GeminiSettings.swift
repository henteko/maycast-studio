import SwiftUI

// MARK: - Gemini API key
//
// Thin facades over the shared `ApiKeyKeychain` / `ApiKeySettingsSheet`
// (see `ApiKeySettings.swift`). Kept so existing call sites compile unchanged.

/// Keychain access for the Gemini API key.
enum GeminiKeychain {
    private static let keychain = ApiKeyKeychain(.gemini)

    static func loadKey() -> String? { keychain.loadKey() }

    @discardableResult
    static func saveKey(_ key: String) -> Bool { keychain.saveKey(key) }

    @discardableResult
    static func deleteKey() -> Bool { keychain.deleteKey() }

    /// Human-readable masked label, e.g. "configured (••••2f1a)".
    static func maskedLabel(for key: String) -> String { ApiKeyKeychain.maskedLabel(for: key) }
}

/// Sheet to enter / replace / remove the Gemini API key.
struct GeminiSettingsSheet: View {
    let hasExistingKey: Bool
    let onChange: (String?) -> Void

    init(hasExistingKey: Bool, onChange: @escaping (String?) -> Void) {
        self.hasExistingKey = hasExistingKey
        self.onChange = onChange
    }

    var body: some View {
        ApiKeySettingsSheet(service: .gemini, hasExistingKey: hasExistingKey, onChange: onChange)
    }
}

#if DEBUG
#Preview("Gemini — key set") {
    GeminiSettingsSheet(hasExistingKey: true) { _ in }
}

#Preview("Gemini — key missing") {
    GeminiSettingsSheet(hasExistingKey: false) { _ in }
}
#endif
