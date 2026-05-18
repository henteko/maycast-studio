import SwiftUI

// MARK: - Form state

/// One speaker (audio source) to import into the new Episode.
struct SpeakerEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var trackID: String
    var audioPath: String?

    init(id: UUID = UUID(), trackID: String = "", audioPath: String? = nil) {
        self.id = id
        self.trackID = trackID
        self.audioPath = audioPath
    }
}

/// Plain Sendable model for the New Episode form. The eventual wiring will
/// validate the bundle path doesn't exist, then call `EpisodeBundle.create`.
struct NewEpisodeForm: Equatable, Sendable {
    var bundlePath: String = ""
    var attachedShowPath: String? = nil
    var attachedShowName: String? = nil
    /// Speakers to import as tracks after the Episode is created. Rows with
    /// blank `trackID` or no `audioPath` are skipped silently. Defaults to a
    /// host / guest scaffold to nudge two-mic interviews.
    var speakers: [SpeakerEntry] = [
        SpeakerEntry(trackID: "host"),
        SpeakerEntry(trackID: "guest"),
    ]

    /// Derived episode ID = last path component without the `.maycast` suffix.
    var derivedEpisodeID: String {
        let url = URL(fileURLWithPath: bundlePath)
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "untitled" : name
    }

    /// Speakers that will actually trigger an import (have both a track ID
    /// and an audio file). Used for validation and creation flow.
    var importableSpeakers: [SpeakerEntry] {
        speakers.filter {
            !$0.trackID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ($0.audioPath?.isEmpty == false)
        }
    }

    /// Validation hook for duplicate / illegal IDs. Returns a human-readable
    /// error if any importable row has a problem, nil otherwise.
    var speakerValidationError: String? {
        let importable = importableSpeakers
        var seen: Set<String> = []
        for sp in importable {
            let id = sp.trackID.trimmingCharacters(in: .whitespacesAndNewlines)
            // Match the CLI / IPC validation: ASCII alnum + `_-`.
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
            if id.rangeOfCharacter(from: allowed.inverted) != nil {
                return "Track ID '\(id)' must be alphanumeric (with `_` or `-`)."
            }
            if !seen.insert(id).inserted {
                return "Duplicate track ID '\(id)'."
            }
        }
        return nil
    }

    var isValid: Bool {
        !bundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && speakerValidationError == nil
    }
}

// MARK: - Sheet

/// Sheet for creating a new Episode bundle. Mockup phase: actions are
/// wired through closures so the parent can stub them out for #Preview.
struct NewEpisodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var form: NewEpisodeForm
    var validationError: String? = nil
    var isCreating: Bool = false
    /// Optional live status line describing the current create-pipeline stage.
    var creatingStage: String? = nil

    var onPickBundleLocation: (() -> Void)? = nil
    var onPickShow: (() -> Void)? = nil
    var onClearShow: (() -> Void)? = nil
    var onPickSpeakerAudio: ((UUID) -> Void)? = nil
    var onCreate: ((NewEpisodeForm) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("New Episode").font(.title2.bold())
                Spacer()
            }
            Text("Creates a `.maycast` bundle at the chosen location. Attaching a Show snapshots its intro / outro / BGM into the new Episode.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            bundlePathSection
            Divider()
            showSection
            Divider()
            speakersSection
            Divider()
            statusSection
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 600)
    }

    private var bundlePathSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Bundle path", systemImage: "folder.badge.plus")
                    .font(.headline)
                Spacer()
            }
            HStack(spacing: 6) {
                TextField("/path/to/ep01.maycast", text: $form.bundlePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .disabled(isCreating)
                Button("Choose…") { onPickBundleLocation?() }
                    .disabled(isCreating)
            }
            HStack(spacing: 6) {
                Text("Episode ID:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(form.derivedEpisodeID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                Spacer()
            }
        }
    }

    private var showSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Show (optional)", systemImage: "shippingbox")
                    .font(.headline)
                Spacer()
            }
            if let attached = form.attachedShowPath {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(form.attachedShowName ?? "Show").font(.callout.weight(.medium))
                        Text(attached)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change…") { onPickShow?() }.disabled(isCreating)
                    Button("Remove", role: .destructive) { onClearShow?() }.disabled(isCreating)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    Text("No Show attached").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Select Show…") { onPickShow?() }.disabled(isCreating)
                }
            }
            Text("Without a Show, the Episode starts with no intro / outro / BGM assets. You can still set them later from the Mix sheet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Speakers (optional)", systemImage: "person.2.wave.2")
                    .font(.headline)
                Spacer()
                Button {
                    form.speakers.append(SpeakerEntry())
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(isCreating)
            }

            VStack(spacing: 4) {
                ForEach($form.speakers) { $speaker in
                    speakerRow(speaker: $speaker)
                }
                if form.speakers.isEmpty {
                    Text("No speakers — you can add them later via `maycast import`.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let speakerError = form.speakerValidationError {
                Text(speakerError).font(.caption).foregroundStyle(.red)
            } else {
                Text("Each speaker becomes a track in the new Episode. Audio files are copied into `sources/<id>.<ext>` and decoded into the first generation.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func speakerRow(speaker: Binding<SpeakerEntry>) -> some View {
        HStack(spacing: 8) {
            TextField("trackID", text: speaker.trackID)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .disabled(isCreating)
            Group {
                if let path = speaker.wrappedValue.audioPath, !path.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform").foregroundStyle(.tint)
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                        Text("No audio selected")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(speaker.wrappedValue.audioPath == nil ? "Choose…" : "Change…") {
                onPickSpeakerAudio?(speaker.wrappedValue.id)
            }
            .disabled(isCreating)

            Button(role: .destructive) {
                form.speakers.removeAll { $0.id == speaker.wrappedValue.id }
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .disabled(isCreating)
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
            HStack(alignment: .center, spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Creating…").font(.callout.weight(.medium))
                    if let creatingStage {
                        Text(creatingStage)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
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
private struct NewEpisodePreviewHost: View {
    @State var form: NewEpisodeForm
    var validationError: String? = nil
    var isCreating: Bool = false

    var body: some View {
        NewEpisodeSheet(
            form: $form,
            validationError: validationError,
            isCreating: isCreating
        )
    }
}
#endif

#Preview("New Episode — empty") {
    NewEpisodePreviewHost(form: NewEpisodeForm())
}

#Preview("New Episode — path entered") {
    NewEpisodePreviewHost(form: NewEpisodeForm(
        bundlePath: "/Users/henteko/Podcasts/my-podcast/ep02.maycast"
    ))
}

#Preview("New Episode — with Show attached") {
    NewEpisodePreviewHost(form: NewEpisodeForm(
        bundlePath: "/Users/henteko/Podcasts/my-podcast/ep02.maycast",
        attachedShowPath: "/Users/henteko/Podcasts/my-podcast.maycastshow",
        attachedShowName: "my-podcast"
    ))
}

#Preview("New Episode — bundle already exists") {
    NewEpisodePreviewHost(
        form: NewEpisodeForm(bundlePath: "/Users/henteko/Podcasts/my-podcast/ep01.maycast"),
        validationError: "A bundle already exists at this path. Choose a different name."
    )
}

#Preview("New Episode — creating") {
    NewEpisodePreviewHost(
        form: NewEpisodeForm(
            bundlePath: "/Users/henteko/Podcasts/my-podcast/ep02.maycast",
            attachedShowPath: "/Users/henteko/Podcasts/my-podcast.maycastshow",
            attachedShowName: "my-podcast"
        ),
        isCreating: true
    )
}

#Preview("New Episode — speakers ready") {
    NewEpisodePreviewHost(form: NewEpisodeForm(
        bundlePath: "/Users/henteko/Podcasts/my-podcast/ep02.maycast",
        attachedShowPath: "/Users/henteko/Podcasts/my-podcast.maycastshow",
        attachedShowName: "my-podcast",
        speakers: [
            SpeakerEntry(trackID: "host",  audioPath: "/Users/henteko/raw/host.wav"),
            SpeakerEntry(trackID: "guest", audioPath: "/Users/henteko/raw/guest.wav"),
        ]
    ))
}
