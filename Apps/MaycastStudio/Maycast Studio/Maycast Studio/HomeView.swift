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

// MARK: - Greetings
//
// Calm, declarative, on-brand greetings. Picked once per mount. Mirrors the
// `GREETINGS` array in docs/design/home.jsx 1:1 so the welcome line in the
// SwiftUI build stays in sync with the design mock.
private let maycastGreetings: [String] = [
    "Welcome back.",
    "Ready when you are.",
    "Studio's open.",
    "Pick up where you left off.",
    "Today's tape is waiting.",
    "Where were we?",
    "Hello again.",
    "All ears.",
    "Tape rolls when you do.",
    "Press record when you're ready.",
    "Take your time.",
    "Coffee's on. Faders up.",
    "Quiet the noise. Keep the voice.",
    "One more for the feed.",
    "Make today's episode lighter.",
    "Less knobs. More conversation.",
    "Sounds like a good day to publish.",
    "A quieter way to ship.",
    "Today, something worth listening to.",
    "Cleared and ready.",
]

// MARK: - HomeView

/// Welcome screen — mint/sky soft gradient with decorative clouds, a single
/// top band (logo + rotating greeting + action buttons), and a grid of recent
/// episodes. Mirrors the "Home · warm welcome" layout in docs/design/home.jsx.
struct HomeView: View {
    let recents: [RecentEpisode]

    var onNewEpisode: () -> Void
    var onNewShow: () -> Void
    var onOpen: () -> Void
    var onSelectRecent: (RecentEpisode) -> Void
    var onForgetRecent: ((RecentEpisode) -> Void)? = nil

    /// Greeting selected once when the view first appears. Injectable so
    /// previews can pin a specific phrase.
    @State private var greeting: String

    init(
        recents: [RecentEpisode],
        onNewEpisode: @escaping () -> Void,
        onNewShow: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onSelectRecent: @escaping (RecentEpisode) -> Void,
        onForgetRecent: ((RecentEpisode) -> Void)? = nil,
        greeting: String? = nil
    ) {
        self.recents = recents
        self.onNewEpisode = onNewEpisode
        self.onNewShow = onNewShow
        self.onOpen = onOpen
        self.onSelectRecent = onSelectRecent
        self.onForgetRecent = onForgetRecent
        self._greeting = State(initialValue: greeting ?? (maycastGreetings.randomElement() ?? "Welcome back."))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBand
                    .padding(.horizontal, 80)
                    .padding(.top, 56)
                    .padding(.bottom, 32)
                recentSection
                    .padding(.horizontal, 80)
                    .padding(.top, 8)
                    .padding(.bottom, 56)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(heroBackground)
    }

    // MARK: - Top band

    private var topBand: some View {
        HStack(alignment: .center, spacing: 32) {
            MaycastLogoMark(size: 48)

            Text(greeting)
                .font(MaycastFont.display(32, weight: .bold))
                .foregroundStyle(MaycastPalette.ink900)
                .tracking(-0.32)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button(action: onNewEpisode) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.rectangle")
                        Text("New Episode")
                        MaycastKeyHint(modifiers: ["⌘"], key: "N")
                    }
                }
                .buttonStyle(MaycastPrimaryButtonStyle(glow: true, size: .large))
                .keyboardShortcut("n", modifiers: [.command])

                Button(action: onNewShow) {
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox")
                        Text("New Show")
                        MaycastKeyHint(modifiers: ["⇧", "⌘"], key: "N")
                    }
                }
                .buttonStyle(MaycastSecondaryButtonStyle(size: .large))
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text("Open")
                        MaycastKeyHint(modifiers: ["⌘"], key: "O")
                    }
                }
                .buttonStyle(MaycastSecondaryButtonStyle(size: .large))
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }

    // MARK: - Recents

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "clock").foregroundStyle(MaycastPalette.fg2)
                Text("Recent episodes")
                    .font(MaycastFont.display(20, weight: .bold))
                if !recents.isEmpty {
                    Text("(\(recents.count) total)")
                        .font(MaycastFont.body(12))
                        .foregroundStyle(MaycastPalette.fg3)
                }
                Spacer()
            }
            if recents.isEmpty {
                emptyRecentState
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14),
                ], spacing: 14) {
                    ForEach(recents) { item in
                        RecentEpisodeCard(
                            episode: item,
                            onOpen: { onSelectRecent(item) },
                            onForget: onForgetRecent.map { fn in { fn(item) } }
                        )
                    }
                }
            }
        }
    }

    private var emptyRecentState: some View {
        VStack(spacing: 8) {
            MaycastIconTile(systemName: "tray", size: 44, iconSize: 20, tone: .neutral)
            Text("No recent episodes")
                .font(MaycastFont.body(14, weight: .semibold))
                .foregroundStyle(MaycastPalette.fg2)
            Text("Episodes you create or open will appear here.")
                .font(MaycastFont.body(12))
                .foregroundStyle(MaycastPalette.fg3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
        )
    }

    // MARK: - Background

    private var heroBackground: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0xEAF9F3), location: 0),
                    .init(color: Color(hex: 0xE8F4FA), location: 0.55),
                    .init(color: Color.white, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            // Decorative clouds — purely visual, anchored to the top-left so
            // their positions read like the absolute coordinates in
            // docs/design/home.jsx (which uses left/right/top in pixels).
            cloud(width: 220, opacity: 0.55, x: 80, y: 60)
            cloud(width: 180, opacity: 0.45, fromRight: 120, y: 130)
            cloud(width: 140, opacity: 0.35, x: 320, y: 280)
        }
        .ignoresSafeArea()
    }

    /// Position a cloud at an explicit top-left coordinate (or right edge).
    /// `MaycastCloud` returns a centered shape inside its declared frame, so
    /// we wrap it in `frame(maxWidth/Height: .infinity, alignment: .topLeading)`
    /// and shift it via `.padding` rather than `.offset` — that way the
    /// coordinate semantics match the JSX mock and survive window resizing.
    @ViewBuilder
    private func cloud(width: CGFloat, opacity: Double, x: CGFloat? = nil, fromRight: CGFloat? = nil, y: CGFloat) -> some View {
        let alignment: Alignment = (fromRight != nil) ? .topTrailing : .topLeading
        MaycastCloud(width: width, opacity: opacity)
            .padding(.leading, x ?? 0)
            .padding(.trailing, fromRight ?? 0)
            .padding(.top, y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

// MARK: - Recent card

private struct RecentEpisodeCard: View {
    let episode: RecentEpisode
    var onOpen: () -> Void
    var onForget: (() -> Void)?

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                MaycastIconTile(systemName: "rectangle.stack.fill", size: 38, iconSize: 18, tone: .mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.displayName)
                        .font(MaycastFont.body(13.5, weight: .bold))
                        .foregroundStyle(MaycastPalette.fg1)
                        .lineLimit(1)
                    if let show = episode.showName {
                        Text("· \(show)")
                            .font(MaycastFont.body(11.5))
                            .foregroundStyle(MaycastPalette.fg3)
                    }
                    Text(episode.absolutePath)
                        .font(MaycastFont.mono(10.5))
                        .foregroundStyle(MaycastPalette.fg4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 4)
                    HStack {
                        Text(episode.lastOpened, style: .relative)
                            .font(MaycastFont.body(11))
                            .foregroundStyle(MaycastPalette.fg3)
                        Spacer(minLength: 4)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
            )
            .maycastShadow(.xs)
        }
        .buttonStyle(.plain)
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
        displayName: "ep12-rust-rewrite",
        absolutePath: "~/Podcasts/Code & Coffee/ep12-rust-rewrite.maycast",
        lastOpened: Date().addingTimeInterval(-60 * 2),
        showName: "code & coffee"
    ),
    RecentEpisode(
        displayName: "ep11-team-rituals",
        absolutePath: "~/Podcasts/Code & Coffee/ep11-team-rituals.maycast",
        lastOpened: Date().addingTimeInterval(-60 * 60 * 24),
        showName: "code & coffee"
    ),
    RecentEpisode(
        displayName: "ep10-postmortem",
        absolutePath: "~/Podcasts/Code & Coffee/ep10-postmortem.maycast",
        lastOpened: Date().addingTimeInterval(-60 * 60 * 24 * 3),
        showName: "code & coffee"
    ),
    RecentEpisode(
        displayName: "tn04-shipping",
        absolutePath: "~/Podcasts/Night Shift/tn04-shipping.maycast",
        lastOpened: Date().addingTimeInterval(-60 * 60 * 24 * 7),
        showName: "the night shift"
    ),
    RecentEpisode(
        displayName: "tn03-ramen-talk",
        absolutePath: "~/Podcasts/Night Shift/tn03-ramen-talk.maycast",
        lastOpened: Date().addingTimeInterval(-60 * 60 * 24 * 14),
        showName: "the night shift"
    ),
    RecentEpisode(
        displayName: "lo02-q1-recap",
        absolutePath: "~/Podcasts/Looseleaf/lo02-q1-recap.maycast",
        lastOpened: Date().addingTimeInterval(-60 * 60 * 24 * 30),
        showName: "looseleaf"
    ),
]

#Preview("Home — with recents") {
    HomeView(
        recents: sampleRecents,
        onNewEpisode: {},
        onNewShow: {},
        onOpen: {},
        onSelectRecent: { _ in },
        onForgetRecent: { _ in },
        greeting: "Welcome back."
    )
    .frame(width: 1280, height: 820)
}

#Preview("Home — empty") {
    HomeView(
        recents: [],
        onNewEpisode: {},
        onNewShow: {},
        onOpen: {},
        onSelectRecent: { _ in },
        greeting: "Studio's open."
    )
    .frame(width: 1280, height: 820)
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
        onForgetRecent: { _ in },
        greeting: "Pick up where you left off."
    )
    .frame(width: 1280, height: 820)
}
#endif
