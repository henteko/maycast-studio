import SwiftUI

// MARK: - Form state

struct NewShowForm: Equatable, Sendable {
    var bundlePath: String = ""
    var displayName: String = ""
    var introPath: String? = nil
    var outroPath: String? = nil

    /// Default display name = last path component without `.maycastshow`.
    var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let url = URL(fileURLWithPath: bundlePath)
        return url.deletingPathExtension().lastPathComponent
    }

    var isValid: Bool {
        !bundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Sheet

/// Sheet for creating a new Show bundle. Intro / Outro / BGM are optional —
/// they can also be added later via `maycast show set-asset` or by editing
/// the Show bundle directly.
struct NewShowSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var form: NewShowForm
    var validationError: String? = nil
    var isCreating: Bool = false

    var onPickBundleLocation: (() -> Void)? = nil
    var onPickIntro: (() -> Void)? = nil
    var onPickOutro: (() -> Void)? = nil
    var onClearAsset: ((AssetKind) -> Void)? = nil
    /// Set an asset from a file dropped on its row (no file panel).
    var onDropAsset: ((AssetKind, URL) -> Void)? = nil
    var onCreate: ((NewShowForm) -> Void)? = nil

    enum AssetKind: String, Sendable { case intro, outro }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    MaycastIconTile(systemName: "shippingbox", tone: .sky)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New Show")
                            .font(MaycastFont.display(19, weight: .bold))
                            .foregroundStyle(MaycastPalette.fg1)
                        Text("A Show holds the per-program assets (intro / outro / BGM) and is referenced by Episodes via the `--show` flag. Each Episode snapshot-copies the assets at create time.")
                            .font(MaycastFont.body(12.5))
                            .foregroundStyle(MaycastPalette.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(MaycastPalette.border1).frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    bundlePathSection
                    assetsSection
                    statusSection
                }
                .padding(24)
            }

            Rectangle().fill(MaycastPalette.border1).frame(height: 0.5)
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(MaycastPalette.ink50)
        }
        .background(MaycastPalette.bg1)
        .frame(minWidth: 640, minHeight: 680)
    }

    @ViewBuilder
    private func sectionLabel(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).foregroundStyle(MaycastPalette.fg2) }
            Text(text)
                .font(MaycastFont.body(12.5, weight: .semibold))
                .foregroundStyle(MaycastPalette.fg1)
        }
    }

    private var bundlePathSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Bundle path", icon: "folder.badge.plus")
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(MaycastPalette.fg3)
                TextField("/path/to/my-podcast.maycastshow", text: $form.bundlePath)
                    .textFieldStyle(.plain)
                    .font(MaycastFont.mono(12))
                    .disabled(isCreating)
                Button("Choose…") { onPickBundleLocation?() }
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                    .disabled(isCreating)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MaycastPalette.bg1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MaycastPalette.border2, lineWidth: 0.5)
            )

            HStack(spacing: 8) {
                Text("Display name")
                    .font(MaycastFont.body(12.5, weight: .semibold))
                    .foregroundStyle(MaycastPalette.fg2)
                    .frame(width: 110, alignment: .leading)
                TextField(form.resolvedDisplayName, text: $form.displayName)
                    .textFieldStyle(.plain)
                    .font(MaycastFont.body(13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MaycastPalette.bg1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MaycastPalette.border2, lineWidth: 0.5)
                    )
                    .disabled(isCreating)
            }
        }
    }

    private var assetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Assets (optional)", icon: "music.note.list")
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
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MaycastPalette.bg2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
            )
            Text("Selected files are copied into the bundle (originals are not modified). You can replace them at any time via `maycast show set-asset`.")
                .font(MaycastFont.body(11))
                .foregroundStyle(MaycastPalette.fg4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let validationError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(validationError).font(.callout)
            }
        } else if isCreating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Creating…")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(MaycastSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)
            Button("Create") { onCreate?(form) }
                .buttonStyle(MaycastPrimaryButtonStyle(glow: form.isValid && !isCreating))
                .keyboardShortcut(.defaultAction)
                .disabled(!form.isValid || isCreating)
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
        .dropDestination(for: URL.self) { urls, _ in
            guard !isCreating, let url = maycastFirstAudioURL(in: urls) else { return false }
            onDrop(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// Stateless asset-row visuals — pure function of `targeted` so previews can
/// render the drag-hover look directly.
private struct AssetRowView: View {
    var label: String
    var path: String?
    var isCreating: Bool
    var targeted: Bool
    var onPick: () -> Void
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.system(size: 14))
            Text(label)
                .frame(width: 48, alignment: .leading)
                .font(MaycastFont.body(12.5, weight: .semibold))
                .foregroundStyle(MaycastPalette.fg1)
            Text(displayText)
                .font(MaycastFont.mono(11.5))
                .foregroundStyle(textColor)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(path == nil ? "Choose…" : "Change…", action: onPick)
                .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                .disabled(isCreating)
            if path != nil {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle").foregroundStyle(MaycastPalette.fg4)
                }
                .buttonStyle(.borderless)
                .disabled(isCreating)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(targeted ? MaycastPalette.mint50 : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    targeted ? MaycastPalette.mint400 : Color.clear,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .animation(.easeOut(duration: 0.12), value: targeted)
    }

    private var iconName: String {
        if targeted { return "tray.and.arrow.down" }
        return path != nil ? "checkmark.seal.fill" : "circle.dashed"
    }
    private var iconColor: Color {
        if targeted { return MaycastPalette.mint600 }
        return path != nil ? MaycastPalette.mint600 : MaycastPalette.fg3
    }
    private var displayText: String {
        if targeted { return "Drop audio here" }
        return path ?? "—"
    }
    private var textColor: Color {
        if targeted { return MaycastPalette.mint600 }
        return path != nil ? MaycastPalette.fg2 : MaycastPalette.fg4
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

#Preview("New Show — empty") {
    NewShowPreviewHost(form: NewShowForm())
}

#Preview("Asset row — states") {
    VStack(spacing: 8) {
        AssetRowView(label: "Intro", path: nil, isCreating: false,
                     targeted: false, onPick: {}, onClear: {})        // empty
        AssetRowView(label: "Outro", path: "assets/op.wav", isCreating: false,
                     targeted: false, onPick: {}, onClear: {})        // filled
        AssetRowView(label: "Intro", path: nil, isCreating: false,
                     targeted: true, onPick: {}, onClear: {})         // drag hovering
    }
    .padding()
    .frame(width: 480)
    .background(MaycastPalette.bg2)
}

#Preview("New Show — path + name only") {
    NewShowPreviewHost(form: NewShowForm(
        bundlePath: "/Users/henteko/Podcasts/my-podcast.maycastshow",
        displayName: "My Podcast"
    ))
}

#Preview("New Show — all assets") {
    NewShowPreviewHost(form: NewShowForm(
        bundlePath: "/Users/henteko/Podcasts/my-podcast.maycastshow",
        displayName: "My Podcast",
        introPath: "/Users/henteko/bgm/op.wav",
        outroPath: "/Users/henteko/bgm/ed.wav"
    ))
}

#Preview("New Show — bundle already exists") {
    NewShowPreviewHost(
        form: NewShowForm(
            bundlePath: "/Users/henteko/Podcasts/my-podcast.maycastshow"
        ),
        validationError: "A Show bundle already exists at this path."
    )
}

#Preview("New Show — creating") {
    NewShowPreviewHost(
        form: NewShowForm(
            bundlePath: "/Users/henteko/Podcasts/my-podcast.maycastshow",
            displayName: "My Podcast",
            introPath: "/Users/henteko/bgm/op.wav"
        ),
        isCreating: true
    )
}
#endif
