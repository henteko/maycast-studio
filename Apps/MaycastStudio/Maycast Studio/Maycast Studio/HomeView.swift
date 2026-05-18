import SwiftUI
import Foundation

// MARK: - Recent episode model

/// One entry in the "Recent episodes" list shown on the welcome screen.
/// Persisted to `UserDefaults` as JSON via `RecentsStore`. The optional
/// `bookmark` is a sandbox-friendly security-scoped bookmark to the bundle
/// directory so the app can reopen it across launches even when the OS would
/// otherwise forget the user's prior consent.
struct RecentEpisode: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let displayName: String        // basename without `.maycast`
    let absolutePath: String        // for tooltip / display
    let lastOpened: Date
    let showName: String?           // attached Show, if any
    let bookmark: Data?             // security-scoped bookmark to the bundle URL

    init(
        id: UUID = UUID(),
        displayName: String,
        absolutePath: String,
        lastOpened: Date,
        showName: String? = nil,
        bookmark: Data? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.absolutePath = absolutePath
        self.lastOpened = lastOpened
        self.showName = showName
        self.bookmark = bookmark
    }
}

// MARK: - HomeView

/// Welcome screen shown when no Episode bundle is open. Lists recently-opened
/// episodes for one-click reopen, and offers entry points to create a fresh
/// Episode / Show or pick an existing bundle from disk.
struct HomeView: View {
    let recents: [RecentEpisode]

    var onNewEpisode: () -> Void
    var onNewShow: () -> Void
    var onOpen: () -> Void
    var onSelectRecent: (RecentEpisode) -> Void
    var onForgetRecent: ((RecentEpisode) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            actionRow
            Divider()
            recentSection
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Maycast Studio").font(.largeTitle.bold())
                Text("Open a recent episode, or start a fresh one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(action: onNewEpisode) {
                Label("New Episode…", systemImage: "plus.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: [.command])
            .controlSize(.large)

            Button(action: onNewShow) {
                Label("New Show…", systemImage: "shippingbox")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .controlSize(.large)

            Button(action: onOpen) {
                Label("Open…", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("o", modifiers: [.command])
            .controlSize(.large)
            Spacer()
        }
    }

    // MARK: Recent

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Recent episodes", systemImage: "clock")
                    .font(.headline)
                if !recents.isEmpty {
                    Text("(\(recents.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if recents.isEmpty {
                emptyRecentState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(recents) { item in
                            RecentEpisodeRow(
                                episode: item,
                                onOpen: { onSelectRecent(item) },
                                onForget: onForgetRecent.map { fn in { fn(item) } }
                            )
                        }
                    }
                }
            }
        }
    }

    private var emptyRecentState: some View {
        VStack(alignment: .center, spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("No recent episodes")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Episodes you create or open will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Row

private struct RecentEpisodeRow: View {
    let episode: RecentEpisode
    var onOpen: () -> Void
    var onForget: (() -> Void)?

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(episode.displayName).font(.body.weight(.semibold))
                        if let show = episode.showName {
                            Text("· \(show)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(episode.absolutePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(episode.lastOpened, style: .relative)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if let onForget {
                    Button(role: .destructive, action: onForget) {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from recents")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open") { onOpen() }
            if let onForget {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: episode.absolutePath)]
                    )
                }
                Divider()
                Button("Remove from Recents", role: .destructive, action: onForget)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
private let sampleRecents: [RecentEpisode] = [
    RecentEpisode(
        displayName: "ep01",
        absolutePath: "/Users/henteko/Podcasts/my-podcast/ep01.maycast",
        lastOpened: Date().addingTimeInterval(-60 * 30),
        showName: "my-podcast"
    ),
    RecentEpisode(
        displayName: "ep00-pilot",
        absolutePath: "/Users/henteko/Podcasts/my-podcast/ep00-pilot.maycast",
        lastOpened: Date().addingTimeInterval(-60 * 60 * 6),
        showName: "my-podcast"
    ),
    RecentEpisode(
        displayName: "test-recording",
        absolutePath: "/Users/henteko/Desktop/test-recording.maycast",
        lastOpened: Date().addingTimeInterval(-60 * 60 * 24 * 3),
        showName: nil
    ),
]
#endif

#Preview("Home — with recents") {
    HomeView(
        recents: sampleRecents,
        onNewEpisode: {},
        onNewShow: {},
        onOpen: {},
        onSelectRecent: { _ in },
        onForgetRecent: { _ in }
    )
    .frame(width: 760, height: 540)
}

#Preview("Home — empty") {
    HomeView(
        recents: [],
        onNewEpisode: {},
        onNewShow: {},
        onOpen: {},
        onSelectRecent: { _ in }
    )
    .frame(width: 760, height: 540)
}

#Preview("Home — single recent (no Show)") {
    HomeView(
        recents: [
            RecentEpisode(
                displayName: "untitled",
                absolutePath: "/Users/henteko/Desktop/untitled.maycast",
                lastOpened: Date(),
                showName: nil
            )
        ],
        onNewEpisode: {},
        onNewShow: {},
        onOpen: {},
        onSelectRecent: { _ in },
        onForgetRecent: { _ in }
    )
    .frame(width: 760, height: 540)
}
