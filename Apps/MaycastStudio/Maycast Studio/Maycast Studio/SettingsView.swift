import SwiftUI

// MARK: - Settings window (⌘,)
//
// One place for every credential the app needs. Each row shows the state of
// a key and opens the shared `ApiKeySettingsSheet` to change it — the same
// sheet the Polish / Chapters panes open from their "Configure…" buttons.

struct SettingsView: View {
    @State private var editing: ApiKeyServiceSelection?
    @State private var refreshToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                MaycastLogoMark(size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Maycast Studio")
                        .font(MaycastFont.display(19, weight: .bold))
                        .foregroundStyle(MaycastPalette.fg1)
                    Text("Keys are stored in your login Keychain and only sent to the service they belong to.")
                        .font(MaycastFont.body(12.5))
                        .foregroundStyle(MaycastPalette.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                MaycastSectionLabel("API keys")
                keyRow(.auphonic, purpose: "Polish")
                keyRow(.gemini, purpose: "Chapters")
            }
            .id(refreshToken)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 520, height: 300)
        .background(MaycastPalette.bg1)
        .tint(MaycastPalette.mint500)
        .sheet(item: $editing) { selection in
            ApiKeySettingsSheet(
                service: selection.service,
                hasExistingKey: ApiKeyKeychain(selection.service).loadKey() != nil
            ) { _ in
                refreshToken += 1
            }
        }
    }

    private func keyRow(_ service: ApiKeyService, purpose: String) -> some View {
        let key = ApiKeyKeychain(service).loadKey()
        return MaycastStatusBanner(
            tone: key == nil ? .warning : .success,
            icon: key == nil ? "key.slash" : "key.fill",
            title: "\(service.name) API key · used by \(purpose)",
            detail: key.map { ApiKeyKeychain.maskedLabel(for: $0) } ?? "Not set — \(service.helpURL)"
        ) {
            Button(key == nil ? "Configure…" : "Change…") {
                editing = ApiKeyServiceSelection(service: service)
            }
            .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
        }
    }
}

/// `sheet(item:)` needs Identifiable; the service name is unique.
private struct ApiKeyServiceSelection: Identifiable {
    let service: ApiKeyService
    var id: String { service.name }
}

#if DEBUG
#Preview("Settings") {
    SettingsView()
}
#endif
