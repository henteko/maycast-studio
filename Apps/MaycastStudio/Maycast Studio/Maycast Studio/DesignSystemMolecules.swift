import SwiftUI

// MARK: - Design-system "molecules"
//
// `DesignSystem.swift` holds the atoms (palette, type, buttons, card, chip,
// tile). This file holds the layout-level pieces every feature screen used
// to hand-roll on its own: section labels, status banners, progress rows,
// track rows, setting rows, empty states, and the operation-pane shell.
//
// Rule of thumb: if two screens need the same *shape*, it lives here.

// MARK: - Radius tokens

/// The only three corner radii a screen should use.
enum MaycastRadius {
    /// Cards, containers, empty-state boxes.
    static let card: CGFloat = 12
    /// Buttons, text fields, banners, pills.
    static let control: CGFloat = 9
    /// Rows and tiles nested *inside* a card.
    static let inner: CGFloat = 6
}

// MARK: - Hairline

/// 0.5pt rule in `border1`. Replaces `Divider()` so every separator in the
/// app has the same weight and colour.
struct MaycastHairline: View {
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal
    /// Vertical hairlines need an explicit height (they sit inside HStacks).
    var length: CGFloat = 24

    var body: some View {
        switch axis {
        case .horizontal:
            Rectangle().fill(MaycastPalette.border1).frame(height: 0.5)
        case .vertical:
            Rectangle().fill(MaycastPalette.border1).frame(width: 1, height: length)
        }
    }
}

// MARK: - Section label

/// Uppercase, tracked section heading — the single heading style for
/// grouped content ("TRACKS", "EFFECTS", "OUTPUT PATH").
struct MaycastSectionLabel: View {
    let text: String
    var trailing: String? = nil

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(MaycastFont.body(10.5, weight: .bold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(MaycastPalette.fg3)
            if let trailing {
                Text(trailing)
                    .font(MaycastFont.body(11))
                    .foregroundStyle(MaycastPalette.fg4)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Status tone

/// Shared tone vocabulary for banners and progress. Mirrors `StatusRow` in
/// the React mock (`docs/design/sheets-polish.jsx`).
enum MaycastStatusTone {
    case idle, info, progress, success, warning, danger

    var background: Color {
        switch self {
        case .idle:     return MaycastPalette.bg2
        case .info:     return MaycastPalette.sky50
        case .progress: return MaycastPalette.mint50
        case .success:  return MaycastPalette.mint50
        case .warning:  return MaycastPalette.warning.opacity(0.13)
        case .danger:   return MaycastPalette.danger.opacity(0.10)
        }
    }

    var foreground: Color {
        switch self {
        case .idle:     return MaycastPalette.fg2
        case .info:     return MaycastPalette.sky700
        case .progress: return MaycastPalette.mint700
        case .success:  return MaycastPalette.mint700
        case .warning:  return Color(hex: 0xC4760A)
        case .danger:   return MaycastPalette.danger
        }
    }

    var border: Color {
        switch self {
        case .idle:     return MaycastPalette.border1
        case .info:     return MaycastPalette.sky200
        case .progress, .success: return MaycastPalette.mint200
        case .warning:  return MaycastPalette.warning.opacity(0.3)
        case .danger:   return MaycastPalette.danger.opacity(0.25)
        }
    }

    /// Fill colour for progress bars in this tone.
    var accent: Color {
        switch self {
        case .info:     return MaycastPalette.sky500
        case .warning:  return MaycastPalette.warning
        case .danger:   return MaycastPalette.danger
        default:        return MaycastPalette.mint500
        }
    }
}

// MARK: - Status banner

/// One-line (optionally two-line) tinted banner. Every "Ready / Working /
/// Done / Failed" message in the app renders through this so the states
/// look the same in Polish, Mix, Render, Chapters and the create sheets.
struct MaycastStatusBanner<Trailing: View>: View {
    let tone: MaycastStatusTone
    var icon: String? = nil
    let title: String
    /// Secondary line, rendered in mono (paths, API status strings, errors).
    var detail: String? = nil
    /// Replace the icon with a spinner.
    var spinning: Bool = false
    let trailing: Trailing

    init(
        tone: MaycastStatusTone,
        icon: String? = nil,
        title: String,
        detail: String? = nil,
        spinning: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.tone = tone
        self.icon = icon
        self.title = title
        self.detail = detail
        self.spinning = spinning
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if spinning {
                ProgressView()
                    .controlSize(.small)
                    .tint(tone.foreground)
                    .frame(width: 18)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tone.foreground)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MaycastFont.body(12.5, weight: .semibold))
                    .foregroundStyle(tone.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(MaycastFont.mono(11))
                        .foregroundStyle(MaycastPalette.fg3)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: MaycastRadius.control, style: .continuous)
                .fill(tone.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MaycastRadius.control, style: .continuous)
                .strokeBorder(tone.border, lineWidth: 0.5)
        )
    }
}

extension MaycastStatusBanner where Trailing == EmptyView {
    init(
        tone: MaycastStatusTone,
        icon: String? = nil,
        title: String,
        detail: String? = nil,
        spinning: Bool = false
    ) {
        self.init(tone: tone, icon: icon, title: title, detail: detail, spinning: spinning) { EmptyView() }
    }
}

// MARK: - Progress

/// 6pt capsule bar. `value` is 0…1.
struct MaycastProgressBar: View {
    var value: Double
    var tone: MaycastStatusTone = .progress

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(MaycastPalette.ink100)
                Capsule().fill(tone.accent)
                    .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

struct MaycastProgressRow: Identifiable {
    let id: String
    let value: Double
}

/// Stack of labelled progress bars (one per track / speaker / file).
struct MaycastProgressRows: View {
    let rows: [MaycastProgressRow]
    var tone: MaycastStatusTone = .progress

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(row.id)
                        .font(MaycastFont.mono(11.5, weight: .semibold))
                        .foregroundStyle(MaycastPalette.fg1)
                        .frame(width: 80, alignment: .leading)
                    MaycastProgressBar(value: row.value, tone: tone)
                    Text("\(Int(row.value * 100))%")
                        .font(MaycastFont.mono(10.5, weight: .semibold))
                        .foregroundStyle(MaycastPalette.fg3)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: MaycastRadius.control, style: .continuous)
                .fill(MaycastPalette.bg2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MaycastRadius.control, style: .continuous)
                .strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
        )
    }
}

// MARK: - Duration formatting

enum MaycastDuration {
    /// `12.50s` under a minute, otherwise `m:ss.00` (`30:20.50`). The single
    /// format every track row uses, so the same file never reads differently
    /// in two screens.
    static func format(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.2fs", seconds) }
        let minutes = Int(seconds) / 60
        let rest = seconds - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, rest)
    }
}

// MARK: - Track row

/// `[tile] id  path……………  duration` — the canonical one-line track row used
/// in Polish / Mix / Render / History lists.
struct MaycastTrackRow: View {
    let id: String
    let path: String
    var duration: TimeInterval? = nil
    var tone: MaycastChip<EmptyView>.Tone = .mint
    var icon: String = "waveform"

    var body: some View {
        HStack(spacing: 10) {
            MaycastIconTile(systemName: icon, size: 28, iconSize: 13, tone: tone, cornerRadius: MaycastRadius.inner)
            Text(id)
                .font(MaycastFont.mono(12.5, weight: .semibold))
                .foregroundStyle(MaycastPalette.fg1)
                .frame(width: 80, alignment: .leading)
            Text(path)
                .font(MaycastFont.mono(11))
                .foregroundStyle(MaycastPalette.fg3)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let duration {
                Text(MaycastDuration.format(duration))
                    .font(MaycastFont.mono(11.5))
                    .foregroundStyle(MaycastPalette.fg2)
            }
        }
    }
}

// MARK: - Setting row

/// A labelled control row for settings cards. `inline` puts the control at
/// the trailing edge (toggles, pickers); `stacked` puts it on its own line
/// under the label (sliders).
struct MaycastSettingRow<Control: View>: View {
    enum Layout { case inline, stacked }

    var icon: String? = nil
    let label: String
    var hint: String? = nil
    var layout: Layout = .inline
    var enabled: Bool = true
    let control: Control

    init(
        icon: String? = nil,
        _ label: String,
        hint: String? = nil,
        layout: Layout = .inline,
        enabled: Bool = true,
        @ViewBuilder control: () -> Control
    ) {
        self.icon = icon
        self.label = label
        self.hint = hint
        self.layout = layout
        self.enabled = enabled
        self.control = control()
    }

    var body: some View {
        Group {
            switch layout {
            case .inline:
                HStack(alignment: .center, spacing: 10) {
                    labelBlock
                    Spacer(minLength: 12)
                    control
                }
            case .stacked:
                VStack(alignment: .leading, spacing: 8) {
                    labelBlock
                    control
                }
            }
        }
        .frame(minHeight: 30)
        .padding(.vertical, 6)
        .opacity(enabled ? 1 : 0.5)
        .disabled(!enabled)
    }

    private var labelBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MaycastPalette.fg3)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(MaycastFont.body(13, weight: .medium))
                    .foregroundStyle(MaycastPalette.fg1)
                if let hint {
                    Text(hint)
                        .font(MaycastFont.body(11))
                        .foregroundStyle(MaycastPalette.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Right-aligned value readout next to a slider, mono digits.
struct MaycastValueLabel: View {
    let text: String
    var width: CGFloat = 80

    init(_ text: String, width: CGFloat = 80) {
        self.text = text
        self.width = width
    }

    var body: some View {
        Text(text)
            .font(MaycastFont.mono(12, weight: .semibold))
            .foregroundStyle(MaycastPalette.fg1)
            .frame(width: width, alignment: .trailing)
    }
}

// MARK: - Empty state

/// Centred tile + title + message (+ optional action) in a soft container.
/// One size for every empty list in the app.
struct MaycastEmptyState<Action: View>: View {
    var icon: String
    var tone: MaycastChip<EmptyView>.Tone = .neutral
    let title: String
    var message: String? = nil
    let action: Action

    init(
        icon: String,
        tone: MaycastChip<EmptyView>.Tone = .neutral,
        title: String,
        message: String? = nil,
        @ViewBuilder action: () -> Action
    ) {
        self.icon = icon
        self.tone = tone
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 10) {
            MaycastIconTile(systemName: icon, size: 48, iconSize: 22, tone: tone)
            Text(title)
                .font(MaycastFont.display(16, weight: .bold))
                .foregroundStyle(MaycastPalette.fg1)
            if let message {
                Text(message)
                    .font(MaycastFont.body(12.5))
                    .foregroundStyle(MaycastPalette.fg2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action.padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: MaycastRadius.card, style: .continuous)
                .fill(MaycastPalette.bg2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MaycastRadius.card, style: .continuous)
                .strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
        )
    }
}

extension MaycastEmptyState where Action == EmptyView {
    init(icon: String, tone: MaycastChip<EmptyView>.Tone = .neutral, title: String, message: String? = nil) {
        self.init(icon: icon, tone: tone, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Operation shell
//
// The one skeleton every operation pane (Slice / Polish / Chapters / Mix /
// Render) renders inside:
//
//   ┌ ‹ ep01 │ [tile] Title  subtitle              [chips] ┐  header
//   │                                                      │
//   │                    content                           │  fills the window
//   │                                                      │
//   ├──────────────────────────────────────────────────────┤
//   │ [status banner]                                      │  footer
//   │ [leading actions]              [Cancel] [Primary]    │
//   └──────────────────────────────────────────────────────┘
//
// The header's back button is the *only* exit; panes don't add Close/✕.
// The footer's trailing slot holds exactly one primary button.

struct MaycastOperationShell<Accessory: View, Content: View, Status: View, Leading: View, Trailing: View>: View {
    let episodeID: String
    let icon: String
    var tone: MaycastChip<EmptyView>.Tone = .mint
    let title: String
    var subtitle: String? = nil
    let onBack: () -> Void
    let accessory: Accessory
    let content: Content
    let status: Status
    let leading: Leading
    let trailing: Trailing

    init(
        episodeID: String,
        icon: String,
        tone: MaycastChip<EmptyView>.Tone = .mint,
        title: String,
        subtitle: String? = nil,
        onBack: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content,
        @ViewBuilder status: () -> Status,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.episodeID = episodeID
        self.icon = icon
        self.tone = tone
        self.title = title
        self.subtitle = subtitle
        self.onBack = onBack
        self.accessory = accessory()
        self.content = content()
        self.status = status()
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MaycastPalette.bg1)
        // Native Slider / Toggle / Picker inside a pane pick up the brand
        // colour instead of macOS blue.
        .tint(MaycastPalette.mint500)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text(episodeID)
                }
            }
            .buttonStyle(MaycastSecondaryButtonStyle())
            .keyboardShortcut("w", modifiers: .command)
            .help("Back to \(episodeID)")

            MaycastHairline(axis: .vertical, length: 24)

            MaycastIconTile(systemName: icon, size: 30, iconSize: 14, tone: tone, cornerRadius: 8)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(MaycastFont.display(19, weight: .bold))
                    .foregroundStyle(MaycastPalette.fg1)
                if let subtitle {
                    Text(subtitle)
                        .font(MaycastFont.body(12))
                        .foregroundStyle(MaycastPalette.fg3)
                        .lineLimit(1)
                }
            }
            Spacer()
            accessory
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [MaycastPalette.mint50, Color.white],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) { MaycastHairline() }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            status
            HStack(spacing: 10) {
                leading
                Spacer()
                trailing
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(MaycastPalette.ink50)
        .overlay(alignment: .top) { MaycastHairline() }
    }
}

extension MaycastOperationShell
where Accessory == EmptyView, Status == EmptyView, Leading == EmptyView, Trailing == EmptyView {
    /// Header + content only. Used for the loading / load-failed states of a
    /// pane so the back button is there before the real content is.
    init(
        episodeID: String,
        icon: String,
        tone: MaycastChip<EmptyView>.Tone = .mint,
        title: String,
        subtitle: String? = nil,
        onBack: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            episodeID: episodeID, icon: icon, tone: tone, title: title, subtitle: subtitle, onBack: onBack,
            accessory: { EmptyView() },
            content: content,
            status: { EmptyView() },
            leading: { EmptyView() },
            trailing: { EmptyView() }
        )
    }
}

// MARK: - Icon button style

/// 28×28 icon-only button for tool strips (transport, zoom, split, close
/// panel, per-row play/delete). Replaces the mix of `.bordered`,
/// `.borderless` and `.plain` icon buttons. `active` renders the pressed-in
/// mint look for toggles (e.g. "show transcript").
struct MaycastIconButtonStyle: ButtonStyle {
    var active: Bool = false
    var size: CGFloat = 28
    var destructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: MaycastRadius.control, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MaycastRadius.control, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            )
            .maycastShadow(active ? .xs : .xs)
            .contentShape(RoundedRectangle(cornerRadius: MaycastRadius.control, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        if destructive { return MaycastPalette.danger }
        return active ? MaycastPalette.mint700 : MaycastPalette.fg1
    }
    private func background(pressed: Bool) -> Color {
        if active { return MaycastPalette.mint50 }
        return pressed ? MaycastPalette.ink100 : MaycastPalette.bg1
    }
    private var border: Color {
        active ? MaycastPalette.mint200 : MaycastPalette.border2
    }
}

/// Grouped strip of icon buttons with a soft `bg2` background — the visual
/// unit of a tool bar (transport group, edit group, zoom group).
struct MaycastToolGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 4) { content }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: MaycastRadius.control + 3, style: .continuous)
                    .fill(MaycastPalette.bg2)
            )
    }
}

// MARK: - Sheet shell
//
// The one skeleton every true modal sheet (New Episode / New Show / API key
// settings / History) renders inside:
//
//   ┌ [tile] Title                                        ┐  header
//   │        subtitle (wraps)                             │
//   ├─────────────────────────────────────────────────────┤
//   │ content (scrolls)                                   │
//   ├─────────────────────────────────────────────────────┤
//   │ [destructive]                    [Cancel] [Primary] │  footer
//   └─────────────────────────────────────────────────────┘
//
// Footer order is fixed: destructive at the leading edge, Cancel then the
// single primary at the trailing edge. Esc = Cancel, ⌘↩ = Primary.

struct MaycastSheetShell<Content: View, Leading: View, Trailing: View>: View {
    let icon: String
    var tone: MaycastChip<EmptyView>.Tone = .mint
    let title: String
    var subtitle: String? = nil
    var width: CGFloat = 640
    var height: CGFloat = 640
    let content: Content
    let leading: Leading
    let trailing: Trailing

    init(
        icon: String,
        tone: MaycastChip<EmptyView>.Tone = .mint,
        title: String,
        subtitle: String? = nil,
        width: CGFloat = 640,
        height: CGFloat = 640,
        @ViewBuilder content: () -> Content,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.tone = tone
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.height = height
        self.content = content()
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: width, height: height)
        .background(MaycastPalette.bg1)
        .tint(MaycastPalette.mint500)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            MaycastIconTile(systemName: icon, tone: tone)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(MaycastFont.display(19, weight: .bold))
                    .foregroundStyle(MaycastPalette.fg1)
                if let subtitle {
                    Text(subtitle)
                        .font(MaycastFont.body(12.5))
                        .foregroundStyle(MaycastPalette.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { MaycastHairline() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            leading
            Spacer()
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(MaycastPalette.ink50)
        .overlay(alignment: .top) { MaycastHairline() }
    }
}

extension MaycastSheetShell where Leading == EmptyView {
    init(
        icon: String,
        tone: MaycastChip<EmptyView>.Tone = .mint,
        title: String,
        subtitle: String? = nil,
        width: CGFloat = 640,
        height: CGFloat = 640,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(icon: icon, tone: tone, title: title, subtitle: subtitle, width: width, height: height,
                  content: content, leading: { EmptyView() }, trailing: trailing)
    }
}

// MARK: - Form field

/// Section-labelled form group: label (+ optional hint) above the control.
struct MaycastFormField<Control: View>: View {
    let label: String
    var hint: String? = nil
    let control: Control

    init(_ label: String, hint: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.hint = hint
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MaycastSectionLabel(label)
            control
            if let hint {
                Text(hint)
                    .font(MaycastFont.body(11))
                    .foregroundStyle(MaycastPalette.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Bordered box for a plain `TextField` / `SecureField` with an optional
/// leading icon. Radius 9, `border2` hairline, focus ring in `borderFocus`.
struct MaycastTextFieldBox<Field: View>: View {
    var icon: String? = nil
    var focused: Bool = false
    let field: Field

    init(icon: String? = nil, focused: Bool = false, @ViewBuilder field: () -> Field) {
        self.icon = icon
        self.focused = focused
        self.field = field()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MaycastPalette.fg3)
            }
            field
                .textFieldStyle(.plain)
                .font(MaycastFont.body(13))
                .foregroundStyle(MaycastPalette.fg1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: MaycastRadius.control, style: .continuous)
                .fill(MaycastPalette.bg1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MaycastRadius.control, style: .continuous)
                .strokeBorder(focused ? MaycastPalette.borderFocus : MaycastPalette.border2, lineWidth: focused ? 1 : 0.5)
        )
    }
}

/// Dashed drop target. `filled` switches to the solid "attached" look so a
/// picker row reads the same whether empty or populated.
struct MaycastDropSlot<Content: View>: View {
    var filled: Bool = false
    var highlighted: Bool = false
    let content: Content

    init(filled: Bool = false, highlighted: Bool = false, @ViewBuilder content: () -> Content) {
        self.filled = filled
        self.highlighted = highlighted
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MaycastRadius.control, style: .continuous)
                    .fill(highlighted ? MaycastPalette.mint50 : (filled ? MaycastPalette.bg1 : MaycastPalette.bg2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MaycastRadius.control, style: .continuous)
                    .strokeBorder(
                        highlighted ? MaycastPalette.mint400 : (filled ? MaycastPalette.border1 : MaycastPalette.border2),
                        style: StrokeStyle(lineWidth: filled ? 0.5 : 1, dash: filled ? [] : [5, 4])
                    )
            )
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Molecules gallery") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            MaycastSectionLabel("Status banners", trailing: "six tones")
            MaycastStatusBanner(tone: .idle, icon: "circle.dashed", title: "Ready")
            MaycastStatusBanner(tone: .info, title: "Uploading to Auphonic…", spinning: true)
            MaycastStatusBanner(tone: .progress, title: "Auphonic processing", detail: "Audio Algorithms", spinning: true)
            MaycastStatusBanner(tone: .success, icon: "checkmark.seal.fill", title: "Polish complete (2 tracks)")
            MaycastStatusBanner(tone: .warning, icon: "key.slash", title: "Auphonic API key not set") {
                Button("Configure…") {}.buttonStyle(MaycastSecondaryButtonStyle(size: .small))
            }
            MaycastStatusBanner(tone: .danger, icon: "exclamationmark.triangle.fill", title: "Polish failed", detail: "Auphonic API: HTTP 401 — invalid API key")

            MaycastSectionLabel("Progress rows")
            MaycastProgressRows(rows: [.init(id: "host", value: 0.72), .init(id: "guest", value: 0.31)])

            MaycastSectionLabel("Track rows")
            MaycastCard {
                VStack(spacing: 8) {
                    MaycastTrackRow(id: "host", path: "intermediate/host/003_polish.wav", duration: 1820.5)
                    MaycastTrackRow(id: "guest", path: "intermediate/guest/001_import.wav", duration: 42.25)
                }
            }

            MaycastSectionLabel("Setting rows")
            MaycastCard {
                VStack(spacing: 0) {
                    MaycastSettingRow(icon: "speaker.wave.2", "Loudness target", layout: .stacked) {
                        HStack(spacing: 12) {
                            Slider(value: .constant(-16), in: -23 ... -14, step: 0.5)
                            MaycastValueLabel("-16.0 LUFS")
                        }
                    }
                    MaycastHairline()
                    MaycastSettingRow(icon: "slider.horizontal.3", "Adaptive Leveler", hint: "Balances loudness across speakers") {
                        Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    MaycastHairline()
                    MaycastSettingRow(icon: "list.bullet", "Method", enabled: false) {
                        Picker("", selection: .constant(0)) { Text("Dynamic").tag(0) }.labelsHidden().pickerStyle(.menu).frame(width: 160)
                    }
                }
            }

            MaycastSectionLabel("Icon buttons & tool groups")
            HStack(spacing: 12) {
                MaycastToolGroup {
                    Button {} label: { Image(systemName: "play.fill") }.buttonStyle(MaycastIconButtonStyle())
                    Button {} label: { Image(systemName: "stop.fill") }.buttonStyle(MaycastIconButtonStyle())
                }
                MaycastToolGroup {
                    Button {} label: { Image(systemName: "scissors") }.buttonStyle(MaycastIconButtonStyle())
                    Button {} label: { Image(systemName: "trash") }.buttonStyle(MaycastIconButtonStyle(destructive: true))
                    Button {} label: { Image(systemName: "text.quote") }.buttonStyle(MaycastIconButtonStyle(active: true))
                }
                Button {} label: { Image(systemName: "xmark") }.buttonStyle(MaycastIconButtonStyle())
            }

            MaycastSectionLabel("Form fields")
            MaycastFormField("Episode name", hint: "Saved into your library as ep01.maycast") {
                MaycastTextFieldBox(icon: "rectangle.stack") { TextField("ep01", text: .constant("ep01")) }
            }
            MaycastDropSlot {
                HStack {
                    Image(systemName: "arrow.down.doc").foregroundStyle(MaycastPalette.fg3)
                    Text("Drop an audio file here").font(MaycastFont.body(12.5)).foregroundStyle(MaycastPalette.fg2)
                    Spacer()
                    Button("Browse…") {}.buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                }
            }
            MaycastDropSlot(filled: true) {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(MaycastPalette.mint600)
                    Text("host.wav").font(MaycastFont.mono(12, weight: .semibold)).foregroundStyle(MaycastPalette.fg1)
                    Spacer()
                    Button("Change…") {}.buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                    Button {} label: { Image(systemName: "xmark") }.buttonStyle(MaycastIconButtonStyle(size: 24))
                }
            }

            MaycastSectionLabel("Empty state")
            MaycastEmptyState(icon: "waveform", title: "No tracks yet", message: "Import a speaker recording to get started.") {
                Button("Import…") {}.buttonStyle(MaycastPrimaryButtonStyle())
            }
        }
        .padding(24)
    }
    .frame(width: 720, height: 1240)
    .background(MaycastPalette.bg1)
    .tint(MaycastPalette.mint500)
}

#Preview("Sheet shell — skeleton") {
    MaycastSheetShell(
        icon: "plus.rectangle", title: "New Episode",
        subtitle: "Creates a new .maycast bundle in your library and imports each speaker recording as a track.",
        height: 480,
        content: { Color.clear.overlay(Text("content").foregroundStyle(MaycastPalette.fg3)) },
        leading: { Button("Remove") {}.buttonStyle(MaycastDestructiveButtonStyle()) },
        trailing: {
            Button("Cancel") {}.buttonStyle(MaycastSecondaryButtonStyle())
            Button("Create") {}.buttonStyle(MaycastPrimaryButtonStyle(glow: true))
        }
    )
}

#Preview("Operation shell — skeleton") {
    MaycastOperationShell(
        episodeID: "ep01", icon: "wand.and.stars", tone: .mint,
        title: "Polish", subtitle: "Clean up every track via Auphonic",
        onBack: {},
        accessory: { MaycastChip("2 tracks", tone: .neutral) { Image(systemName: "rectangle.stack").font(.system(size: 10)) } },
        content: { Color.clear.overlay(Text("content").foregroundStyle(MaycastPalette.fg3)) },
        status: { MaycastStatusBanner(tone: .idle, icon: "circle.dashed", title: "Ready") },
        leading: { Button("Reset to defaults") {}.buttonStyle(MaycastGhostButtonStyle()) },
        trailing: { Button("Send to Auphonic") {}.buttonStyle(MaycastPrimaryButtonStyle(glow: true)) }
    )
    .frame(width: 900, height: 520)
}
#endif
