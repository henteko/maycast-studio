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

/// Welcome screen — mint/sky soft gradient hero, decorative clouds, hero
/// waveform card and a grid of recent episodes. Mirrors the "Home / warm"
/// layout in docs/design/home.jsx.
struct HomeView: View {
    let recents: [RecentEpisode]

    var onNewEpisode: () -> Void
    var onNewShow: () -> Void
    var onOpen: () -> Void
    var onSelectRecent: (RecentEpisode) -> Void
    var onForgetRecent: ((RecentEpisode) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                hero
                recentSection
            }
            .padding(.horizontal, 56)
            .padding(.top, 56)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(heroBackground)
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 40) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    MaycastLogoMark(size: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MAYCAST STUDIO")
                            .font(MaycastFont.body(12, weight: .bold))
                            .tracking(2)
                            .foregroundStyle(MaycastPalette.mint700)
                        Text("v1.0 · OSS")
                            .font(MaycastFont.mono(10.5))
                            .foregroundStyle(MaycastPalette.fg3)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("The minimum amount").font(MaycastFont.display(40, weight: .heavy))
                        .foregroundStyle(MaycastPalette.ink900)
                    HStack(spacing: 0) {
                        Text("of editing, ").font(MaycastFont.display(40, weight: .heavy))
                            .foregroundStyle(MaycastPalette.ink900)
                        Text("finished.")
                            .font(MaycastFont.display(40, weight: .heavy))
                            .foregroundStyle(MaycastPalette.mint600)
                    }
                }
                Text("Open a recent episode, or start a fresh one. Slice the silence, polish the audio, mix the intro — and you're published.")
                    .font(MaycastFont.body(15))
                    .foregroundStyle(MaycastPalette.fg2)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460, alignment: .leading)
                HStack(spacing: 10) {
                    Button(action: onNewEpisode) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.rectangle")
                            Text("New Episode…")
                            MaycastKeyHint(modifiers: ["⌘"], key: "N")
                        }
                    }
                    .buttonStyle(MaycastPrimaryButtonStyle(glow: true, size: .large))
                    .keyboardShortcut("n", modifiers: [.command])

                    Button(action: onNewShow) {
                        HStack(spacing: 6) {
                            Image(systemName: "shippingbox")
                            Text("New Show…")
                        }
                    }
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .large))
                    .keyboardShortcut("n", modifiers: [.command, .shift])

                    Button(action: onOpen) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text("Open…")
                        }
                    }
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .large))
                    .keyboardShortcut("o", modifiers: [.command])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            heroCard
                .frame(width: 360)
        }
    }

    private var heroCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.white, Color(hex: 0xF0FDF7)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(MaycastPalette.mint200, lineWidth: 0.5)
                )
                .maycastShadow(.md)

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    MaycastChip("now playing · ep12", tone: .mint) {
                        Image(systemName: "waveform").font(.system(size: 10))
                    }
                    Spacer()
                    Text("00:42 / 38:51")
                        .font(MaycastFont.mono(11))
                        .foregroundStyle(MaycastPalette.fg3)
                }
                MaycastDecorativeWaveform(seed: 9, color: MaycastPalette.mint500, style: .gradientBars, intensity: 0.95)
                    .frame(height: 110)
                HStack(spacing: 10) {
                    Circle()
                        .fill(LinearGradient(colors: [MaycastPalette.mint400, MaycastPalette.mint500], startPoint: .top, endPoint: .bottom))
                        .overlay(Image(systemName: "play.fill").foregroundStyle(.white).font(.system(size: 13)))
                        .frame(width: 36, height: 36)
                        .maycastShadow(.mint)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(MaycastPalette.ink100)
                            Capsule().fill(MaycastPalette.mint500)
                                .frame(width: geo.size.width * 0.18)
                        }
                    }
                    .frame(height: 4)
                    Text("1.0×")
                        .font(MaycastFont.mono(11))
                        .foregroundStyle(MaycastPalette.fg3)
                }
            }
            .padding(20)
        }
        .frame(height: 240)
        .overlay(alignment: .topTrailing) {
            floatingBadge(icon: "wand.and.stars", text: "3 tracks polished", color: MaycastPalette.mint600)
                .offset(x: 14, y: -14)
        }
        .overlay(alignment: .bottomLeading) {
            floatingBadge(icon: "scissors", text: "14 silences removed", color: MaycastPalette.sky600)
                .offset(x: 24, y: 18)
        }
    }

    private func floatingBadge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(MaycastFont.body(12, weight: .semibold))
                .foregroundStyle(MaycastPalette.fg1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
        )
        .maycastShadow(.md)
    }

    // MARK: - Recents

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
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
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0xEAF9F3), location: 0),
                    .init(color: Color(hex: 0xE8F4FA), location: 0.55),
                    .init(color: Color.white, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            // Decorative clouds — purely visual, fixed positions.
            MaycastCloud(width: 220, opacity: 0.55)
                .offset(x: -440, y: -260)
            MaycastCloud(width: 180, opacity: 0.45)
                .offset(x: 380, y: -220)
            MaycastCloud(width: 140, opacity: 0.35)
                .offset(x: -120, y: -100)
        }
        .ignoresSafeArea()
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
    .frame(width: 1280, height: 820)
}

#Preview("Home — empty") {
    HomeView(
        recents: [],
        onNewEpisode: {},
        onNewShow: {},
        onOpen: {},
        onSelectRecent: { _ in }
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
        onForgetRecent: { _ in }
    )
    .frame(width: 1280, height: 820)
}
