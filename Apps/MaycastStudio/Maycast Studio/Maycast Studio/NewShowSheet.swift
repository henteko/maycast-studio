import SwiftUI

// MARK: - Form state

struct NewShowForm: Equatable, Sendable {
    /// Show display name → becomes the bundle filename (`<name>.maycastshow`)
    /// in the library and the show's `name`.
    var displayName: String = ""
    var introPath: String? = nil
    var outroPath: String? = nil

    /// Trimmed display name, falling back to "untitled" when blank.
    var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "untitled" : trimmed
    }

    var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Sheet

/// Sheet for creating a new Show bundle. Intro / Outro / BGM are optional —
/// they can also be added later via `maycast show set-asset` or by editing
/// the Show bundle directly. Renders inside `MaycastSheetShell`.
struct NewShowSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var form: NewShowForm
    var validationError: String? = nil
    var isCreating: Bool = false

    var onPickIntro: (() -> Void)? = nil
    var onPickOutro: (() -> Void)? = nil
    var onClearAsset: ((AssetKind) -> Void)? = nil
    /// Set an asset from a file dropped on its row (no file panel).
    var onDropAsset: ((AssetKind, URL) -> Void)? = nil
    var onCreate: ((NewShowForm) -> Void)? = nil

    enum AssetKind: String, Sendable { case intro, outro }

    var body: some View {
        MaycastSheetShell(
            icon: "shippingbox",
            tone: .mint,
            title: "New Show",
            subtitle: "A Show holds the per-program assets (intro / outro / BGM). Each Episode snapshot-copies those assets when it is created.",
            width: 640,
            height: 600,
            content: {
                VStack(alignment: .leading, spacing: 22) {
                    nameSection
                    assetsSection
                    statusSection
                }
            },
            trailing: {
                Button("Cancel") { dismiss() }
                    .buttonStyle(MaycastSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button("Create") { onCreate?(form) }
                    .buttonStyle(MaycastPrimaryButtonStyle(glow: form.isValid && !isCreating))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.isValid || isCreating)
            }
        )
    }

    // MARK: name

    private var nameSection: some View {
        MaycastFormField("Show name") {
            MaycastTextFieldBox(icon: "shippingbox") {
                TextField("My Podcast", text: $form.displayName)
                    .disabled(isCreating)
            }
            LibraryLocationHint(filename: "\(form.resolvedDisplayName).maycastshow")
        }
    }

    // MARK: assets

    private var assetsSection: some View {
        MaycastFormField(
            "Assets (optional)",
            hint: "Drag an audio file onto Intro or Outro, or use Choose…. Files are copied into the bundle (originals are not modified) and can be replaced anytime via `maycast show set-asset`."
        ) {
            VStack(spacing: 8) {
                AssetRow(
                    label: "Intro", path: form.introPath, isCreating: isCreating,
                    onPick: { onPickIntro?() },
                    onClear: { onClearAsset?(.intro) },
                    onDrop: { url in onDropAsset?(.intro, url) }
                )
                AssetRow(
                    label: "Outro", path: form.outroPath, isCreating: isCreating,
                    onPick: { onPickOutro?() },
                    onClear: { onClearAsset?(.outro) },
                    onDrop: { url in onDropAsset?(.outro, url) }
                )
            }
        }
    }

    // MARK: status

    @ViewBuilder
    private var statusSection: some View {
        if let validationError {
            MaycastStatusBanner(
                tone: .danger, icon: "exclamationmark.triangle.fill",
                title: "Can't create this Show",
                detail: validationError
            )
        } else if isCreating {
            MaycastStatusBanner(tone: .progress, title: "Creating…", spinning: true)
        }
    }
}

// MARK: - Asset row

/// Intro / Outro asset row. Owns its drag-hover state and accepts an audio
/// file dropped on the row (with a "Choose…" panel fallback).
private struct AssetRow: View {
    var label: String
    var path: String?
    var isCreating: Bool
    var onPick: () -> Void
    var onClear: () -> Void
    var onDrop: (URL) -> Void

    @State private var isTargeted = false

    var body: some View {
        AssetRowView(
            label: label, path: path, isCreating: isCreating,
            targeted: isTargeted, onPick: onPick, onClear: onClear
        )
        // Make the whole row (incl. the transparent gap) a drop target —
        // otherwise only the opaque icon/text would accept a dropped file.
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard !isCreating, let url = maycastFirstAudioURL(in: urls) else { return false }
            onDrop(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// Stateless asset-row visuals — pure function of `targeted` so previews can
/// render the drag-hover look directly. Same row shape as the speaker rows on
/// the New Episode sheet: state icon, label, file, Choose…/Change…, ✕.
private struct AssetRowView: View {
    var label: String
    var path: String?
    var isCreating: Bool
    var targeted: Bool
    var onPick: () -> Void
    var onClear: () -> Void

    var body: some View {
        MaycastDropSlot(filled: path != nil, highlighted: targeted) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
                Text(label)
                    .font(MaycastFont.body(12.5, weight: .semibold))
                    .foregroundStyle(MaycastPalette.fg1)
                    .frame(width: 48, alignment: .leading)
                Text(displayText)
                    .font(MaycastFont.mono(11.5))
                    .foregroundStyle(textColor)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button(path == nil ? "Choose…" : "Change…", action: onPick)
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                    .disabled(isCreating)
                if path != nil {
                    Button(action: onClear) { Image(systemName: "xmark") }
                        .buttonStyle(MaycastIconButtonStyle(size: 24))
                        .help("Remove \(label.lowercased())")
                        .disabled(isCreating)
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }

    private var iconName: String {
        if targeted { return "tray.and.arrow.down" }
        return path != nil ? "checkmark.seal.fill" : "circle.dashed"
    }
    private var iconColor: Color {
        if targeted || path != nil { return MaycastPalette.mint600 }
        return MaycastPalette.fg3
    }
    private var displayText: String {
        if targeted { return "Drop audio here" }
        return path ?? "Drop an audio file here, or Choose…"
    }
    private var textColor: Color {
        if targeted { return MaycastPalette.mint600 }
        return path != nil ? MaycastPalette.fg1 : MaycastPalette.fg4
    }
}

// MARK: - Previews

#if DEBUG
private struct NewShowPreviewHost: View {
    @State var form: NewShowForm
    var validationError: String? = nil
    var isCreating: Bool = false

    var body: some View {
        NewShowSheet(
            form: $form,
            validationError: validationError,
            isCreating: isCreating
        )
    }
}

#Preview("New Show — empty form") {
    NewShowPreviewHost(form: NewShowForm())
}

#Preview("New Show — valid (name + assets)") {
    NewShowPreviewHost(form: NewShowForm(
        displayName: "My Podcast",
        introPath: "/Users/henteko/bgm/op.wav",
        outroPath: "/Users/henteko/bgm/ed.wav"
    ))
}

#Preview("New Show — name only") {
    NewShowPreviewHost(form: NewShowForm(displayName: "My Podcast"))
}

#Preview("New Show — validation error (name exists)") {
    NewShowPreviewHost(
        form: NewShowForm(displayName: "My Podcast"),
        validationError: "A Show named “My Podcast” already exists in your library."
    )
}

#Preview("New Show — creating") {
    NewShowPreviewHost(
        form: NewShowForm(
            displayName: "My Podcast",
            introPath: "/Users/henteko/bgm/op.wav"
        ),
        isCreating: true
    )
}

#Preview("Asset row — states") {
    VStack(spacing: 8) {
        AssetRowView(label: "Intro", path: nil, isCreating: false,
                     targeted: false, onPick: {}, onClear: {})        // empty
        AssetRowView(label: "Outro", path: "/Users/henteko/bgm/ed.wav", isCreating: false,
                     targeted: false, onPick: {}, onClear: {})        // filled
        AssetRowView(label: "Intro", path: nil, isCreating: false,
                     targeted: true, onPick: {}, onClear: {})         // drag hovering
    }
    .padding()
    .frame(width: 592)
    .background(MaycastPalette.bg1)
}
#endif
