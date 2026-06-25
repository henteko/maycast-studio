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

/// Plain Sendable model for the New Episode form. The Episode is created in the
/// Maycast library as `<name>.maycast` — no save panel.
struct NewEpisodeForm: Equatable, Sendable {
    /// User-entered Episode name. Becomes the bundle filename and Episode ID.
    var name: String = ""
    var attachedShowPath: String? = nil
    var attachedShowName: String? = nil
    /// Speakers to import as tracks after the Episode is created. Rows with
    /// blank `trackID` or no `audioPath` are skipped silently. Defaults to a
    /// host / guest scaffold to nudge two-mic interviews.
    var speakers: [SpeakerEntry] = [
        SpeakerEntry(trackID: "host"),
        SpeakerEntry(trackID: "guest"),
    ]

    /// Derived episode ID = the trimmed name (the bundle filename without the
    /// `.maycast` suffix).
    var derivedEpisodeID: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "untitled" : trimmed
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
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && speakerValidationError == nil
    }
}

/// A Show the user can attach without opening a file panel — discovered by
/// scanning the Maycast library folder. `id` is the bundle path so SwiftUI can
/// diff the list cheaply.
struct ShowChoice: Identifiable, Equatable, Sendable {
    var id: String { path }
    let name: String
    let path: String
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
    /// Shows discovered in the Maycast library, offered for one-click attach
    /// so the user rarely needs the (slow, sandboxed) file panel.
    var availableShows: [ShowChoice] = []

    var onPickShow: (() -> Void)? = nil
    var onClearShow: (() -> Void)? = nil
    /// Attach one of the library Shows (no file panel).
    var onSelectShow: ((ShowChoice) -> Void)? = nil
    /// Attach a `.maycastshow` dropped from Finder (sandbox grants access on drop).
    var onDropShowFile: ((URL) -> Void)? = nil
    var onPickSpeakerAudio: ((UUID) -> Void)? = nil
    /// Assign a speaker's audio from a file dropped on its row (no file panel).
    var onDropSpeakerAudio: ((UUID, URL) -> Void)? = nil
    var onCreate: ((NewEpisodeForm) -> Void)? = nil

    /// Highlight state for the Show drop zone while a drag hovers over it.
    @State private var isShowTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    MaycastIconTile(systemName: "plus.rectangle", tone: .mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New Episode")
                            .font(MaycastFont.display(19, weight: .bold))
                            .foregroundStyle(MaycastPalette.fg1)
                        Text("Creates a `.maycast` bundle in your Maycast library. Attaching a Show snapshots its intro / outro / BGM into the new Episode.")
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
                    nameSection
                    showSection
                    speakersSection
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
        .frame(minWidth: 640, minHeight: 720)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Episode name", icon: "rectangle.badge.plus")
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack").foregroundStyle(MaycastPalette.fg3)
                TextField("ep01", text: $form.name)
                    .textFieldStyle(.plain)
                    .font(MaycastFont.body(13))
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
            LibraryLocationHint(
                location: form.attachedShowName ?? "your library",
                filename: "\(form.derivedEpisodeID).maycast"
            )
        }
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

    private var showSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Show (optional)", icon: "shippingbox")
            if let attached = form.attachedShowPath {
                attachedShowCard(path: attached)
            } else {
                showChooser
            }
            Text("Without a Show, the Episode starts with no intro / outro / BGM assets. You can still set them later from the Mix sheet.")
                .font(MaycastFont.body(11))
                .foregroundStyle(MaycastPalette.fg4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Card shown once a Show is attached. "Change…" returns to the chooser so
    /// the user can pick another without ever touching the file panel.
    private func attachedShowCard(path: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(MaycastPalette.mint600)
            VStack(alignment: .leading, spacing: 1) {
                Text(form.attachedShowName ?? "Show")
                    .font(MaycastFont.body(13, weight: .semibold))
                    .foregroundStyle(MaycastPalette.fg1)
                Text(path)
                    .font(MaycastFont.mono(11))
                    .foregroundStyle(MaycastPalette.fg3)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Change…") { onClearShow?() }
                .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                .disabled(isCreating)
            Button("Remove") { onClearShow?() }
                .buttonStyle(MaycastDestructiveButtonStyle(size: .small))
                .disabled(isCreating)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MaycastPalette.mint50)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MaycastPalette.mint200, lineWidth: 0.5)
        )
    }

    /// No-Show state: a one-click list of library Shows plus a drag-and-drop
    /// zone (with a panel fallback). All paths avoid the slow file panel except
    /// the explicit "Browse…" escape hatch.
    private var showChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !availableShows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("In your library")
                        .font(MaycastFont.body(11, weight: .semibold))
                        .foregroundStyle(MaycastPalette.fg3)
                    VStack(spacing: 6) {
                        ForEach(availableShows) { show in
                            showLibraryRow(show)
                        }
                    }
                }
            }
            ShowDropZone(targeted: isShowTargeted, hasLibraryShows: !availableShows.isEmpty) {
                onPickShow?()
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: {
                    $0.pathExtension.lowercased() == "maycastshow"
                }) else { return false }
                onDropShowFile?(url)
                return true
            } isTargeted: { isShowTargeted = $0 }
            .disabled(isCreating)
        }
    }

    private func showLibraryRow(_ show: ShowChoice) -> some View {
        Button { onSelectShow?(show) } label: {
            HStack(spacing: 10) {
                MaycastIconTile(systemName: "shippingbox", size: 30, iconSize: 14, tone: .mint, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(show.name)
                        .font(MaycastFont.body(12.5, weight: .semibold))
                        .foregroundStyle(MaycastPalette.fg1)
                    Text(show.path)
                        .font(MaycastFont.mono(10.5))
                        .foregroundStyle(MaycastPalette.fg4)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(MaycastPalette.fg3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MaycastPalette.bg2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isCreating)
    }

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Speakers (optional)", icon: "person.2.wave.2")
                Spacer()
                Button {
                    form.speakers.append(SpeakerEntry())
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10))
                        Text("Add")
                    }
                }
                .buttonStyle(MaycastGhostButtonStyle(size: .small))
                .disabled(isCreating)
            }

            VStack(spacing: 6) {
                ForEach($form.speakers) { $speaker in
                    SpeakerRow(
                        speaker: $speaker,
                        isCreating: isCreating,
                        onPick: { onPickSpeakerAudio?(speaker.id) },
                        onDelete: { form.speakers.removeAll { $0.id == speaker.id } },
                        onDropAudio: { url in onDropSpeakerAudio?(speaker.id, url) }
                    )
                }
                if form.speakers.isEmpty {
                    Text("No speakers — you can add them later via `maycast import`.")
                        .font(MaycastFont.body(11))
                        .foregroundStyle(MaycastPalette.fg4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MaycastPalette.bg2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
            )
            if let speakerError = form.speakerValidationError {
                Text(speakerError).font(MaycastFont.body(11)).foregroundStyle(MaycastPalette.danger)
            } else {
                Text("Drag an audio or video file onto a speaker row — or use Choose…. Each speaker becomes a track; the file is copied into `sources/<id>.<ext>` and its audio is decoded into the first generation. For a video, the picture is kept for the per-speaker mp4 export.")
                    .font(MaycastFont.body(11))
                    .foregroundStyle(MaycastPalette.fg4)
                    .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Show drop zone

/// Dashed drop target for a `.maycastshow` bundle. Pure function of `targeted`
/// so previews can render the hover state directly without faking a live drag.
private struct ShowDropZone: View {
    var targeted: Bool
    var hasLibraryShows: Bool
    var onBrowse: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 16))
                .foregroundStyle(targeted ? MaycastPalette.mint600 : MaycastPalette.fg3)
            VStack(alignment: .leading, spacing: 1) {
                Text(hasLibraryShows ? "Or drop a .maycastshow here" : "Drop a .maycastshow here")
                    .font(MaycastFont.body(12.5, weight: .semibold))
                    .foregroundStyle(targeted ? MaycastPalette.mint600 : MaycastPalette.fg2)
                Text("Drag a Show bundle from Finder — no file dialog needed.")
                    .font(MaycastFont.body(11))
                    .foregroundStyle(MaycastPalette.fg4)
            }
            Spacer(minLength: 8)
            Button("Browse…", action: onBrowse)
                .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(targeted ? MaycastPalette.mint50 : MaycastPalette.bg2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    targeted ? MaycastPalette.mint400 : MaycastPalette.border2,
                    style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: [5, 4])
                )
        )
        .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

// MARK: - Speaker row

/// One speaker row: track ID, the audio slot (also a drop target), and the
/// pick / delete buttons. Holds its own drag-hover state.
private struct SpeakerRow: View {
    @Binding var speaker: SpeakerEntry
    var isCreating: Bool
    var onPick: () -> Void
    var onDelete: () -> Void
    var onDropAudio: (URL) -> Void

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("trackID", text: $speaker.trackID)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .disabled(isCreating)

            SpeakerAudioField(filename: filename, isVideo: isVideo, targeted: isTargeted)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(speaker.audioPath == nil ? "Choose…" : "Change…", action: onPick)
                .disabled(isCreating)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .disabled(isCreating)
        }
        // Make the whole row a drop target, not just the opaque controls.
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard !isCreating, let url = maycastFirstMediaURL(in: urls) else { return false }
            onDropAudio(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var filename: String? {
        guard let path = speaker.audioPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var isVideo: Bool {
        guard let path = speaker.audioPath, !path.isEmpty else { return false }
        return maycastIsVideoURL(URL(fileURLWithPath: path))
    }
}

/// Stateless audio slot — pure function of `filename` + `targeted` so previews
/// can render the drag-hover look directly.
private struct SpeakerAudioField: View {
    var filename: String?
    var isVideo: Bool = false
    var targeted: Bool

    var body: some View {
        HStack(spacing: 4) {
            if targeted {
                Image(systemName: "tray.and.arrow.down").foregroundStyle(MaycastPalette.mint600)
                Text("Drop audio or video here")
                    .font(.caption.monospaced())
                    .foregroundStyle(MaycastPalette.mint600)
            } else if let filename {
                Image(systemName: isVideo ? "film" : "waveform").foregroundStyle(.tint)
                Text(filename)
                    .font(.caption.monospaced())
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text("No media — drop an audio / video file or Choose…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(targeted ? MaycastPalette.mint50 : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    targeted ? MaycastPalette.mint400 : Color.clear,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

// MARK: - Previews

#if DEBUG
private struct NewEpisodePreviewHost: View {
    @State var form: NewEpisodeForm
    var validationError: String? = nil
    var isCreating: Bool = false
    var availableShows: [ShowChoice] = []

    var body: some View {
        NewEpisodeSheet(
            form: $form,
            validationError: validationError,
            isCreating: isCreating,
            availableShows: availableShows
        )
    }
}

private let sampleLibraryShows: [ShowChoice] = [
    ShowChoice(name: "code & coffee",
               path: "~/Library/Containers/.../Maycast/code & coffee.maycastshow"),
    ShowChoice(name: "the night shift",
               path: "~/Library/Containers/.../Maycast/the night shift.maycastshow"),
    ShowChoice(name: "looseleaf",
               path: "~/Library/Containers/.../Maycast/looseleaf.maycastshow"),
]

#Preview("New Episode — empty library (drop only)") {
    NewEpisodePreviewHost(form: NewEpisodeForm())
}

#Preview("New Episode — library shows listed") {
    NewEpisodePreviewHost(
        form: NewEpisodeForm(name: "ep02"),
        availableShows: sampleLibraryShows
    )
}

#Preview("New Episode — name entered") {
    NewEpisodePreviewHost(form: NewEpisodeForm(name: "ep02"))
}

#Preview("New Episode — with Show attached") {
    NewEpisodePreviewHost(form: NewEpisodeForm(
        name: "ep02",
        attachedShowPath: "/Users/henteko/Podcasts/my-podcast.maycastshow",
        attachedShowName: "my-podcast"
    ))
}

#Preview("New Episode — name already exists") {
    NewEpisodePreviewHost(
        form: NewEpisodeForm(name: "ep01"),
        validationError: "An Episode named “ep01” already exists in your library. Choose a different name."
    )
}

#Preview("New Episode — creating") {
    NewEpisodePreviewHost(
        form: NewEpisodeForm(
            name: "ep02",
            attachedShowPath: "/Users/henteko/Podcasts/my-podcast.maycastshow",
            attachedShowName: "my-podcast"
        ),
        isCreating: true
    )
}

#Preview("New Episode — speakers ready") {
    NewEpisodePreviewHost(form: NewEpisodeForm(
        name: "ep02",
        attachedShowPath: "/Users/henteko/Podcasts/my-podcast.maycastshow",
        attachedShowName: "my-podcast",
        speakers: [
            SpeakerEntry(trackID: "host",  audioPath: "/Users/henteko/raw/host.wav"),
            SpeakerEntry(trackID: "guest", audioPath: "/Users/henteko/raw/guest.wav"),
        ]
    ))
}

#Preview("Speaker audio field — states") {
    VStack(spacing: 10) {
        SpeakerAudioField(filename: nil, targeted: false)                          // empty
        SpeakerAudioField(filename: "host-raw.wav", targeted: false)               // audio filled
        SpeakerAudioField(filename: "host-cam.mp4", isVideo: true, targeted: false) // video filled
        SpeakerAudioField(filename: nil, targeted: true)                           // drag hovering
    }
    .padding()
    .frame(width: 460)
    .background(MaycastPalette.bg1)
}

#Preview("New Episode — video speakers") {
    NewEpisodePreviewHost(form: NewEpisodeForm(
        name: "ep02",
        speakers: [
            SpeakerEntry(trackID: "host",  audioPath: "/Users/henteko/raw/host-cam.mp4"),
            SpeakerEntry(trackID: "guest", audioPath: "/Users/henteko/raw/guest-cam.mov"),
        ]
    ))
}

#Preview("Show drop zone — idle") {
    ShowDropZone(targeted: false, hasLibraryShows: true, onBrowse: {})
        .padding()
        .frame(width: 520)
        .background(MaycastPalette.bg1)
}

#Preview("Show drop zone — drag hovering") {
    ShowDropZone(targeted: true, hasLibraryShows: true, onBrowse: {})
        .padding()
        .frame(width: 520)
        .background(MaycastPalette.bg1)
}
#endif
