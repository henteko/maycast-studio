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
    var onCreate: ((NewShowForm) -> Void)? = nil

    enum AssetKind: String, Sendable { case intro, outro }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("New Show").font(.title2.bold())
                Spacer()
            }
            Text("A Show holds the per-program assets (intro / outro / BGM) and is referenced by Episodes via the `--show` flag. Each Episode snapshot-copies the assets at create time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            bundlePathSection
            Divider()
            assetsSection
            Divider()
            statusSection
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(minWidth: 540, minHeight: 540)
    }

    private var bundlePathSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Bundle path", systemImage: "folder.badge.plus")
                    .font(.headline)
                Spacer()
            }
            HStack(spacing: 6) {
                TextField("/path/to/my-podcast.maycastshow", text: $form.bundlePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .disabled(isCreating)
                Button("Choose…") { onPickBundleLocation?() }
                    .disabled(isCreating)
            }

            HStack(spacing: 6) {
                Text("Display name").frame(width: 110, alignment: .leading)
                TextField(form.resolvedDisplayName, text: $form.displayName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCreating)
            }
        }
    }

    private var assetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Assets (optional)", systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
            }
            assetRow(label: "Intro", path: form.introPath, onPick: { onPickIntro?() }, kind: .intro)
            assetRow(label: "Outro", path: form.outroPath, onPick: { onPickOutro?() }, kind: .outro)
            Text("Selected files are copied into the bundle (originals are not modified). You can replace them at any time via `maycast show set-asset`.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func assetRow(label: String, path: String?, onPick: @escaping () -> Void, kind: AssetKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: path != nil ? "checkmark.seal.fill" : "circle.dashed")
                .foregroundStyle(path != nil ? .green : .secondary)
            Text(label)
                .frame(width: 60, alignment: .leading)
                .font(.callout.weight(.medium))
            Text(path ?? "—")
                .font(.caption.monospaced())
                .foregroundStyle(path != nil ? .secondary : .tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(path == nil ? "Choose…" : "Change…", action: onPick)
                .disabled(isCreating)
            if path != nil {
                Button(role: .destructive) { onClearAsset?(kind) } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .disabled(isCreating)
            }
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
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)
            Button("Create") { onCreate?(form) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!form.isValid || isCreating)
        }
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
#endif

#Preview("New Show — empty") {
    NewShowPreviewHost(form: NewShowForm())
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
