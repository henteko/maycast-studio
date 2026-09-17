import SwiftUI
import Security
import Foundation

// MARK: - Service descriptor

/// Describes one third-party service whose API key we keep in the Keychain.
/// `AuphonicSettings.swift` / `GeminiSettings.swift` each declare one and
/// expose thin facades over the shared sheet + keychain below.
struct ApiKeyService: Sendable, Equatable {
    /// Display name, e.g. "Auphonic".
    let name: String
    /// SF Symbol for the sheet header tile.
    var icon: String = "key.fill"
    /// Where the user issues a key.
    let helpURL: String
    /// Keychain `kSecAttrService` value.
    let keychainService: String
    /// What the key unlocks, shown in the sheet subtitle.
    let purpose: String
    /// Billing / privacy footnote.
    let note: String

    static let auphonic = ApiKeyService(
        name: "Auphonic",
        helpURL: "https://auphonic.com/engine/account/",
        keychainService: "com.maycast.studio.auphonic",
        purpose: "Polish sends your tracks to the Auphonic Multitrack API.",
        note: "Auphonic is a paid SaaS — running Polish uses your account's processing time. The key is only sent to auphonic.com."
    )

    static let gemini = ApiKeyService(
        name: "Gemini",
        helpURL: "https://aistudio.google.com/",
        keychainService: "com.maycast.studio.gemini",
        purpose: "Chapters are generated from the transcript with Google's Gemini API.",
        note: "Gemini usage is billed to your Google account. Only the transcript text is sent."
    )
}

// MARK: - Keychain storage

/// Wrapper around `Security.framework`'s generic-password Keychain API. One
/// service+account pair per `ApiKeyService`, so secrets persist across
/// launches and survive app upgrades.
struct ApiKeyKeychain: Sendable {
    let service: String
    private let account = "api-key"

    init(service: String) { self.service = service }
    init(_ svc: ApiKeyService) { self.service = svc.keychainService }

    func loadKey() -> String? {
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
    func saveKey(_ key: String) -> Bool {
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
    func deleteKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Last four characters, e.g. "2f1a" — never the whole secret.
    static func suffix(of key: String) -> String {
        key.count >= 4 ? String(key.suffix(4)) : key
    }

    /// Human-readable masked label, e.g. "configured (••••2f1a)".
    static func maskedLabel(for key: String) -> String {
        "configured (••••\(suffix(of: key)))"
    }
}

// MARK: - Settings sheet

/// Sheet to enter / replace / remove one service's API key. The current
/// value is **never** loaded into the editor so the secret is not shown on
/// screen; only its last four characters appear in the status banner.
struct ApiKeySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let service: ApiKeyService
    let onChange: (String?) -> Void

    /// Persistence hooks — default to the Keychain, overridable in previews.
    private let save: (String) -> Bool
    private let delete: () -> Bool
    private let load: () -> String?

    @State private var draft: String = ""
    @State private var hasExistingKey: Bool
    @State private var maskedSuffix: String?
    @State private var saveError: String?
    @State private var confirmingRemove = false
    @FocusState private var fieldFocused: Bool

    init(
        service: ApiKeyService,
        hasExistingKey: Bool,
        onChange: @escaping (String?) -> Void
    ) {
        let keychain = ApiKeyKeychain(service)
        self.init(
            service: service,
            hasExistingKey: hasExistingKey,
            maskedSuffix: nil,
            save: { keychain.saveKey($0) },
            delete: { keychain.deleteKey() },
            load: { keychain.loadKey() },
            onChange: onChange
        )
    }

    /// Full initialiser used by previews / tests to bypass the Keychain.
    init(
        service: ApiKeyService,
        hasExistingKey: Bool,
        maskedSuffix: String?,
        initialError: String? = nil,
        save: @escaping (String) -> Bool,
        delete: @escaping () -> Bool,
        load: @escaping () -> String?,
        onChange: @escaping (String?) -> Void
    ) {
        self.service = service
        self._hasExistingKey = State(initialValue: hasExistingKey)
        self._maskedSuffix = State(initialValue: maskedSuffix)
        self._saveError = State(initialValue: initialError)
        self.save = save
        self.delete = delete
        self.load = load
        self.onChange = onChange
    }

    var body: some View {
        MaycastSheetShell(
            icon: service.icon,
            tone: .mint,
            title: "\(service.name) API key",
            subtitle: "\(service.purpose) The key is stored in your login Keychain.",
            width: 560,
            height: 420,
            content: { content },
            leading: { removeButton },
            trailing: { trailingButtons }
        )
        .task {
            if hasExistingKey, maskedSuffix == nil, let key = load() {
                maskedSuffix = ApiKeyKeychain.suffix(of: key)
            }
        }
        .confirmationDialog(
            "Remove the \(service.name) API key?",
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove key", role: .destructive, action: performRemove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The key is deleted from your Keychain. You can paste a new one at any time.")
        }
    }

    // MARK: content

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusBanner

            MaycastFormField(
                "API key",
                hint: "Stored in your login Keychain. Get one at \(service.helpURL)"
            ) {
                MaycastTextFieldBox(icon: "key", focused: fieldFocused) {
                    SecureField(hasExistingKey ? "Paste a new key to replace the current one" : "Paste API key", text: $draft)
                        .focused($fieldFocused)
                        .font(MaycastFont.mono(13))
                        .onSubmit(performSave)
                }
            }

            if let saveError {
                MaycastStatusBanner(
                    tone: .danger,
                    icon: "exclamationmark.triangle.fill",
                    title: "Could not save the key",
                    detail: saveError
                )
            }

            MaycastStatusBanner(tone: .idle, icon: "info.circle", title: service.note)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if hasExistingKey {
            MaycastStatusBanner(
                tone: .success,
                icon: "key.fill",
                title: "Key configured" + (maskedSuffix.map { " · ••••\($0)" } ?? ""),
                detail: "Replace it below, or remove it with the button at the bottom left."
            )
        } else {
            MaycastStatusBanner(
                tone: .warning,
                icon: "key.slash",
                title: "No key stored",
                detail: "Paste a key below to enable \(service.name)."
            )
        }
    }

    // MARK: footer

    @ViewBuilder
    private var removeButton: some View {
        if hasExistingKey {
            Button {
                confirmingRemove = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 12))
                    Text("Remove")
                }
            }
            .buttonStyle(MaycastDestructiveButtonStyle())
        }
    }

    @ViewBuilder
    private var trailingButtons: some View {
        Button("Cancel") { dismiss() }
            .buttonStyle(MaycastSecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
        Button(hasExistingKey ? "Replace" : "Save", action: performSave)
            .buttonStyle(MaycastPrimaryButtonStyle(glow: draftIsValid))
            .keyboardShortcut(.defaultAction)
            .disabled(!draftIsValid)
    }

    // MARK: actions

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var draftIsValid: Bool { !trimmedDraft.isEmpty }

    private func performSave() {
        let key = trimmedDraft
        guard !key.isEmpty else { return }
        if save(key) {
            saveError = nil
            hasExistingKey = true
            maskedSuffix = ApiKeyKeychain.suffix(of: key)
            onChange(key)
            dismiss()
        } else {
            saveError = "Keychain refused the write for service \"\(service.keychainService)\". Check Keychain Access for a locked or conflicting item, then try again."
        }
    }

    private func performRemove() {
        if delete() {
            hasExistingKey = false
            maskedSuffix = nil
            saveError = nil
            onChange(nil)
            dismiss()
        } else {
            saveError = "Keychain refused to delete the item for service \"\(service.keychainService)\"."
        }
    }
}

// MARK: - Previews

#if DEBUG
private func previewSheet(
    service: ApiKeyService = .auphonic,
    hasKey: Bool,
    saveSucceeds: Bool = true,
    initialError: String? = nil
) -> some View {
    ApiKeySettingsSheet(
        service: service,
        hasExistingKey: hasKey,
        maskedSuffix: hasKey ? "2f1a" : nil,
        initialError: initialError,
        save: { _ in saveSucceeds },
        delete: { true },
        load: { hasKey ? "preview-key-2f1a" : nil },
        onChange: { _ in }
    )
}

#Preview("API key — no key") {
    previewSheet(hasKey: false)
}

#Preview("API key — configured") {
    previewSheet(hasKey: true)
}

#Preview("API key — save failed") {
    previewSheet(
        service: .gemini, hasKey: false, saveSucceeds: false,
        initialError: "Keychain refused the write for service \"com.maycast.studio.gemini\" (errSecInteractionNotAllowed)."
    )
}
#endif
