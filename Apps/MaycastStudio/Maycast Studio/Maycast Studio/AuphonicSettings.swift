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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    MaycastIconTile(systemName: "key.fill", tone: .mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auphonic API key")
                            .font(MaycastFont.display(19, weight: .bold))
                            .foregroundStyle(MaycastPalette.fg1)
                        Text("Issue an API key from auphonic.com. It is stored in the macOS Keychain and never transmitted except to auphonic.com.")
                            .font(MaycastFont.body(12.5))
                            .foregroundStyle(MaycastPalette.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Rectangle().fill(MaycastPalette.border1).frame(height: 0.5)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: hasExistingKey ? "key.fill" : "key.slash")
                        .foregroundStyle(hasExistingKey ? MaycastPalette.mint600 : MaycastPalette.danger)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hasExistingKey ? "An API key is currently set." : "No API key set.")
                            .font(MaycastFont.body(13, weight: .semibold))
                            .foregroundStyle(hasExistingKey ? MaycastPalette.mint800 : MaycastPalette.fg1)
                        Text(hasExistingKey
                             ? "Stored in the macOS Keychain. Replace or remove below."
                             : "Paste a key below to enable Polish.")
                            .font(MaycastFont.body(11.5))
                            .foregroundStyle(MaycastPalette.fg3)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hasExistingKey ? MaycastPalette.mint50 : MaycastPalette.bg2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(hasExistingKey ? MaycastPalette.mint200 : MaycastPalette.border1, lineWidth: 0.5)
                )

                SecureField("Paste API key", text: $draft)
                    .textFieldStyle(.plain)
                    .font(MaycastFont.mono(13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MaycastPalette.bg1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MaycastPalette.border2, lineWidth: 0.5)
                    )

                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(MaycastPalette.fg3)
                    Text("Auphonic is a paid SaaS. Running Polish uses your account credits.")
                        .font(MaycastFont.body(11.5))
                        .foregroundStyle(MaycastPalette.fg2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MaycastPalette.bg2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
                )
            }
            .padding(24)

            Spacer(minLength: 0)
            Rectangle().fill(MaycastPalette.border1).frame(height: 0.5)
            HStack(spacing: 8) {
                if hasExistingKey {
                    Button {
                        AuphonicKeychain.deleteKey()
                        hasExistingKey = false
                        onChange(nil)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash").font(.system(size: 12))
                            Text("Remove")
                        }
                    }
                    .buttonStyle(MaycastDestructiveButtonStyle())
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(MaycastSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                let trimmedValid = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(hasExistingKey ? "Replace" : "Save") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if AuphonicKeychain.saveKey(trimmed) {
                        hasExistingKey = true
                        onChange(trimmed)
                        dismiss()
                    }
                }
                .buttonStyle(MaycastPrimaryButtonStyle(glow: trimmedValid))
                .keyboardShortcut(.defaultAction)
                .disabled(!trimmedValid)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(MaycastPalette.ink50)
        }
        .background(MaycastPalette.bg1)
        .frame(minWidth: 560, minHeight: 460)
    }
}

// MARK: - Previews

#Preview("Auphonic — key set") {
    AuphonicSettingsSheet(hasExistingKey: true) { _ in }
}

#Preview("Auphonic — key missing") {
    AuphonicSettingsSheet(hasExistingKey: false) { _ in }
}
