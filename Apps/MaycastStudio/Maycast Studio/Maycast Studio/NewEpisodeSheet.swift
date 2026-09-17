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

/// Sheet for creating a new Episode bundle. Renders inside `MaycastSheetShell`;
/// actions are wired through closures so the parent can stub them out for
/// #Preview.
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
    /// "Change…" on the attached-Show row re-opens the chooser without
    /// clearing the current Show; picking another one (or cancelling) closes it.
    @State private var isChoosingShow = false

    var body: some View {
        MaycastSheetShell(
            icon: "plus.rectangle",
            tone: .mint,
            title: "New Episode",
            subtitle: "Creates a `.maycast` bundle in your Maycast library. Attaching a Show snapshots its intro / outro / BGM into the new Episode.",
            width: 640,
            height: 720,
            content: {
                VStack(alignment: .leading, spacing: 22) {
                    nameSection
                    showSection
                    speakersSection
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
        .onChange(of: form.attachedShowPath) { _, _ in isChoosingShow = false }
    }

    // MARK: name

    private var nameSection: some View {
        MaycastFormField("Episode name") {
            MaycastTextFieldBox(icon: "rectangle.stack") {
                TextField("ep01", text: $form.name)
                    .disabled(isCreating)
            }
            LibraryLocationHint(
                location: form.attachedShowName ?? "your library",
                filename: "\(form.derivedEpisodeID).maycast"
            )
        }
    }

    // MARK: show

    private var showSection: some View {
        MaycastFormField(
            "Show (optional)",
            hint: "Without a Show, the Episode starts with no intro / outro / BGM assets. You can still set them later from Mix."
        ) {
            if let attached = form.attachedShowPath, !isChoosingShow {
                attachedShowRow(path: attached)
            } else {
                showChooser
            }
        }
    }

    /// Row shown once a Show is attached. "Change…" re-opens the chooser so
    /// the user can pick another without ever touching the file panel; the
    /// ✕ detaches the Show.
    private func attachedShowRow(path: String) -> some View {
        MaycastDropSlot(filled: true) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(MaycastPalette.mint600)
                VStack(alignment: .leading, spacing: 1) {
                    Text(form.attachedShowName ?? "Show")
                        .font(MaycastFont.body(13, weight: .semibold))
                        .foregroundStyle(MaycastPalette.fg1)
                    Text(path)
                        .font(MaycastFont.mono(11))
                        .foregroundStyle(MaycastPalette.fg3)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button("Change…") { isChoosingShow = true }
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                    .disabled(isCreating)
                Button { onClearShow?() } label: { Image(systemName: "xmark") }
                    .buttonStyle(MaycastIconButtonStyle(size: 24))
                    .help("Detach Show")
                    .disabled(isCreating)
            }
        }
    }

    /// No-Show state: a one-click list of library Shows plus a drag-and-drop
    /// slot (with a panel fallback). All paths avoid the slow file panel except
    /// the explicit "Browse…" escape hatch.
    private var showChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !availableShows.isEmpty {
                MaycastCard(padding: EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)) {
                    VStack(spacing: 2) {
                        ForEach(availableShows) { show in
                            showLibraryRow(show)
                        }
                    }
                }
            }
            ShowDropSlot(
                targeted: isShowTargeted,
                hasLibraryShows: !availableShows.isEmpty,
                canKeepCurrent: isChoosingShow,
                onBrowse: { onPickShow?() },
                onKeepCurrent: { isChoosingShow = false }
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard !isCreating, let url = maycastFirstShowBundleURL(in: urls) else { return false }
                onDropShowFile?(url)
                return true
            } isTargeted: { isShowTargeted = $0 }
            .disabled(isCreating)
        }
    }

    private func showLibraryRow(_ show: ShowChoice) -> some View {
        let isCurrent = show.path == form.attachedShowPath
        return Button { onSelectShow?(show) } label: {
            HStack(spacing: 10) {
                MaycastIconTile(systemName: "shippingbox", size: 28, iconSize: 13, tone: .mint, cornerRadius: MaycastRadius.inner)
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
                if isCurrent {
                    MaycastChip("current", tone: .mint)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MaycastPalette.fg3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: MaycastRadius.inner, style: .continuous)
                    .fill(isCurrent ? MaycastPalette.mint50 : MaycastPalette.bg2)
            )
            .contentShape(RoundedRectangle(cornerRadius: MaycastRadius.inner, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isCreating)
    }

    // MARK: speakers

    private var speakersSection: some View {
        MaycastFormField(
            "Speakers (optional)",
            hint: form.speakerValidationError == nil
                ? "Drag an audio or video file onto a speaker row, or use Choose…. Each speaker becomes a track; the file is copied into `sources/<id>.<ext>`. For a video, the picture is kept for the per-speaker mp4 export."
                : nil
        ) {
            VStack(alignment: .leading, spacing: 8) {
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
                }
                if let speakerError = form.speakerValidationError {
                    Text(speakerError)
                        .font(MaycastFont.body(11))
                        .foregroundStyle(MaycastPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    form.speakers.append(SpeakerEntry())
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        Text("Add speaker")
                    }
                }
                .buttonStyle(MaycastGhostButtonStyle(size: .small))
                .disabled(isCreating)
            }
        }
    }

    // MARK: status

    @ViewBuilder
    private var statusSection: some View {
        if let validationError {
            MaycastStatusBanner(
                tone: .danger, icon: "exclamationmark.triangle.fill",
                title: "Can't create this Episode",
                detail: validationError
            )
        } else if isCreating {
            MaycastStatusBanner(
                tone: .progress,
                title: "Creating…",
                detail: creatingStage,
                spinning: true
            )
        }
    }
}

// MARK: - Show drop slot

/// Dashed drop target for a `.maycastshow` bundle. Pure function of `targeted`
/// so previews can render the hover state directly without faking a live drag.
private struct ShowDropSlot: View {
    var targeted: Bool
    var hasLibraryShows: Bool
    /// When re-choosing over an already attached Show, offer a way back.
    var canKeepCurrent: Bool = false
    var onBrowse: () -> Void
    var onKeepCurrent: () -> Void = {}

    var body: some View {
        MaycastDropSlot(filled: false, highlighted: targeted) {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 14))
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
                if canKeepCurrent {
                    Button("Keep current", action: onKeepCurrent)
                        .buttonStyle(MaycastGhostButtonStyle(size: .small))
                }
                Button("Browse…", action: onBrowse)
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
            }
        }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

// MARK: - Speaker row

/// One speaker row: track ID, the media slot (also a drop target), and the
/// pick / delete buttons. Holds its own drag-hover state.
private struct SpeakerRow: View {
    @Binding var speaker: SpeakerEntry
    var isCreating: Bool
    var onPick: () -> Void
    var onDelete: () -> Void
    var onDropAudio: (URL) -> Void

    @State private var isTargeted = false

    var body: some View {
        SpeakerRowView(
            trackID: $speaker.trackID,
            filename: filename,
            isVideo: isVideo,
            isCreating: isCreating,
            targeted: isTargeted,
            onPick: onPick,
            onDelete: onDelete
        )
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

/// Stateless speaker-row visuals — pure function of `filename` + `targeted` so
/// previews can render the drag-hover look directly. Shares its shape with
/// the Intro / Outro asset rows on the New Show sheet.
private struct SpeakerRowView: View {
    @Binding var trackID: String
    var filename: String?
    var isVideo: Bool = false
    var isCreating: Bool = false
    var targeted: Bool
    var onPick: () -> Void
    var onDelete: () -> Void

    var body: some View {
        MaycastDropSlot(filled: filename != nil, highlighted: targeted) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
                MaycastTextFieldBox {
                    TextField("trackID", text: $trackID)
                        .font(MaycastFont.mono(12, weight: .semibold))
                        .disabled(isCreating)
                }
                .frame(width: 120)
                Text(displayText)
                    .font(MaycastFont.mono(11.5))
                    .foregroundStyle(textColor)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button(filename == nil ? "Choose…" : "Change…", action: onPick)
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                    .disabled(isCreating)
                Button(action: onDelete) { Image(systemName: "xmark") }
                    .buttonStyle(MaycastIconButtonStyle(size: 24))
                    .help("Remove speaker")
                    .disabled(isCreating)
            }
        }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }

    private var iconName: String {
        if targeted { return "tray.and.arrow.down" }
        if filename != nil { return isVideo ? "film" : "checkmark.seal.fill" }
        return "circle.dashed"
    }
    private var iconColor: Color {
        if targeted || filename != nil { return MaycastPalette.mint600 }
        return MaycastPalette.fg3
    }
    private var displayText: String {
        if targeted { return "Drop audio or video here" }
        return filename ?? "Drop audio / video here, or Choose…"
    }
    private var textColor: Color {
        if targeted { return MaycastPalette.mint600 }
        return filename != nil ? MaycastPalette.fg1 : MaycastPalette.fg4
    }
}

// MARK: - Previews

#if DEBUG
private struct NewEpisodePreviewHost: View {
    @State var form: NewEpisodeForm
    var validationError: String? = nil
    var isCreating: Bool = false
    var creatingStage: String? = nil
    var availableShows: [ShowChoice] = []

    var body: some View {
        NewEpisodeSheet(
            form: $form,
            validationError: validationError,
            isCreating: isCreating,
            creatingStage: creatingStage,
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

#Preview("New Episode — empty form") {
    NewEpisodePreviewHost(form: NewEpisodeForm())
}

#Preview("New Episode — library has shows") {
    NewEpisodePreviewHost(
        form: NewEpisodeForm(name: "ep02"),
        availableShows: sampleLibraryShows
    )
}

#Preview("New Episode — valid (show + speakers)") {
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

#Preview("New Episode — show attached") {
    NewEpisodePreviewHost(
        form: NewEpisodeForm(
            name: "ep02",
            attachedShowPath: sampleLibraryShows[0].path,
            attachedShowName: sampleLibraryShows[0].name
        ),
        availableShows: sampleLibraryShows
    )
}

#Preview("New Episode — validation error (name exists)") {
    NewEpisodePreviewHost(
        form: NewEpisodeForm(name: "ep01"),
        validationError: "An Episode named “ep01” already exists in your library. Choose a different name."
    )
}

#Preview("New Episode — validation error (duplicate speaker)") {
    NewEpisodePreviewHost(form: NewEpisodeForm(
        name: "ep02",
        speakers: [
            SpeakerEntry(trackID: "host", audioPath: "/Users/henteko/raw/host.wav"),
            SpeakerEntry(trackID: "host", audioPath: "/Users/henteko/raw/guest.wav"),
        ]
    ))
}

#Preview("New Episode — creating") {
    NewEpisodePreviewHost(
        form: NewEpisodeForm(
            name: "ep02",
            attachedShowPath: "/Users/henteko/Podcasts/my-podcast.maycastshow",
            attachedShowName: "my-podcast",
            speakers: [
                SpeakerEntry(trackID: "host",  audioPath: "/Users/henteko/raw/host.wav"),
                SpeakerEntry(trackID: "guest", audioPath: "/Users/henteko/raw/guest.wav"),
            ]
        ),
        isCreating: true,
        creatingStage: "Importing speaker 1/2: host ← host.wav (45.0 MB)"
    )
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

#Preview("Speaker row — states") {
    VStack(spacing: 8) {
        SpeakerRowView(trackID: .constant("host"), filename: nil, targeted: false, onPick: {}, onDelete: {})
        SpeakerRowView(trackID: .constant("host"), filename: "host-raw.wav", targeted: false, onPick: {}, onDelete: {})
        SpeakerRowView(trackID: .constant("guest"), filename: "guest-cam.mp4", isVideo: true, targeted: false, onPick: {}, onDelete: {})
        SpeakerRowView(trackID: .constant("guest"), filename: nil, targeted: true, onPick: {}, onDelete: {})
    }
    .padding()
    .frame(width: 592)
    .background(MaycastPalette.bg1)
}

#Preview("Show drop slot — states") {
    VStack(spacing: 8) {
        ShowDropSlot(targeted: false, hasLibraryShows: true, onBrowse: {})
        ShowDropSlot(targeted: true, hasLibraryShows: true, onBrowse: {})
        ShowDropSlot(targeted: false, hasLibraryShows: false, canKeepCurrent: true, onBrowse: {})
    }
    .padding()
    .frame(width: 592)
    .background(MaycastPalette.bg1)
}
#endif
