import SwiftUI
import Security
import Foundation

// MARK: - Keychain storage

/// Tiny wrapper around `Security.framework`'s generic-password Keychain API
/// for the Auphonic API key. We use a single service+account pair so the
/// secret persists across launches and survives app upgrades.
enum AuphonicKeychain {
    private static let service = "com.maycast.studio.auphonic"
    private static let account = "api-key"

    static func loadKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Try update first; fall back to add.
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(base as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func deleteKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Human-readable masked label, e.g. "configured (••••2f1a)".
    static func maskedLabel(for key: String) -> String {
        let suffix = key.count >= 4 ? String(key.suffix(4)) : key
        return "configured (••••\(suffix))"
    }
}

// MARK: - Settings sheet

/// Sheet to enter / replace / clear the Auphonic API key. The current value
/// is **not** loaded into the editor on appear so the user is never shown
/// the secret on screen.
struct AuphonicSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onChange: (String?) -> Void

    @State private var draft: String = ""
    @State private var hasExistingKey: Bool

    init(hasExistingKey: Bool, onChange: @escaping (String?) -> Void) {
        self._hasExistingKey = State(initialValue: hasExistingKey)
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Auphonic API key").font(.title2.bold())
                Spacer()
            }
            Text("Issue an API key from https://auphonic.com/engine/account/. It is stored in the macOS Keychain and never transmitted except to auphonic.com.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: hasExistingKey ? "key.fill" : "key.slash")
                    .foregroundStyle(hasExistingKey ? .green : .red)
                Text(hasExistingKey ? "An API key is currently set in the Keychain." : "No API key set.")
                    .font(.callout)
            }

            SecureField("Paste API key", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 360)

            Spacer(minLength: 0)

            HStack {
                if hasExistingKey {
                    Button(role: .destructive) {
                        AuphonicKeychain.deleteKey()
                        hasExistingKey = false
                        onChange(nil)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(hasExistingKey ? "Replace" : "Save") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if AuphonicKeychain.saveKey(trimmed) {
                        hasExistingKey = true
                        onChange(trimmed)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 280)
    }
}
