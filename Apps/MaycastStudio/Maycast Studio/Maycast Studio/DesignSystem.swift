import SwiftUI

// MARK: - Color tokens
//
// Mirrors the CSS custom properties in docs/design/design-system/colors_and_type.css.
// The palette is calm-but-lively: mint primary, sky secondary, soft warm neutrals.

enum MaycastPalette {
    // Mint (primary brand)
    static let mint50  = Color(hex: 0xECFBF5)
    static let mint100 = Color(hex: 0xD1F5E6)
    static let mint200 = Color(hex: 0xA6ECD0)
    static let mint300 = Color(hex: 0x6FDCB4)
    static let mint400 = Color(hex: 0x3DD9B0)
    static let mint500 = Color(hex: 0x1FC298)
    static let mint600 = Color(hex: 0x14A07C)
    static let mint700 = Color(hex: 0x117E64)
    static let mint800 = Color(hex: 0x0F604E)
    static let mint900 = Color(hex: 0x0C4A3D)

    // Sky (secondary accent)
    static let sky50  = Color(hex: 0xEEF9FF)
    static let sky100 = Color(hex: 0xD8F1FF)
    static let sky200 = Color(hex: 0xB4E5FF)
    static let sky300 = Color(hex: 0x80D4FF)
    static let sky400 = Color(hex: 0x4DBCFF)
    static let sky500 = Color(hex: 0x2AA3F5)
    static let sky600 = Color(hex: 0x1C84D4)
    static let sky700 = Color(hex: 0x1968A8)
    static let sky800 = Color(hex: 0x1B5384)
    static let sky900 = Color(hex: 0x1A4470)

    // Sun (tertiary highlight, use sparingly)
    static let sun100 = Color(hex: 0xFFF7D6)
    static let sun300 = Color(hex: 0xFFE066)
    static let sun500 = Color(hex: 0xF5C518)
    static let sun700 = Color(hex: 0xB8860B)

    // Ink (neutrals — slightly warm green-black)
    static let ink900 = Color(hex: 0x0E1F1A)
    static let ink800 = Color(hex: 0x1A2F29)
    static let ink700 = Color(hex: 0x334842)
    static let ink600 = Color(hex: 0x506862)
    static let ink500 = Color(hex: 0x6F8983)
    static let ink400 = Color(hex: 0x9AAFA9)
    static let ink300 = Color(hex: 0xC5D3CF)
    static let ink200 = Color(hex: 0xE2EAE7)
    static let ink100 = Color(hex: 0xEEF3F1)
    static let ink50  = Color(hex: 0xF6F9F8)

    // Semantic
    static let danger  = Color(hex: 0xEF4444)
    static let warning = Color(hex: 0xF59E0B)

    // Aliases — match the CSS --fg-* / --bg-* tokens
    static let fg1 = ink900
    static let fg2 = ink700
    static let fg3 = ink500
    static let fg4 = ink400

    static let bg1 = Color.white
    static let bg2 = ink50
    static let bg3 = ink100

    static let border1 = ink200
    static let border2 = ink300
    static let borderFocus = mint400
}

// Hex initializer for Color so the palette reads like the CSS tokens.
extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >>  8) & 0xFF) / 255
        let b = Double( hex        & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Shadows

/// Soft shadows from the design tokens. Kept airy — Maycast never uses heavy
/// drop shadows; the deepest is the mint glow for the primary CTA.
struct MaycastShadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    static let xs   = MaycastShadow(color: Color(.sRGB, red: 15/255, green: 96/255, blue: 78/255, opacity: 0.06), radius: 2, x: 0, y: 1)
    static let sm   = MaycastShadow(color: Color(.sRGB, red: 15/255, green: 96/255, blue: 78/255, opacity: 0.07), radius: 6, x: 0, y: 2)
    static let md   = MaycastShadow(color: Color(.sRGB, red: 15/255, green: 96/255, blue: 78/255, opacity: 0.08), radius: 24, x: 0, y: 8)
    static let lg   = MaycastShadow(color: Color(.sRGB, red: 15/255, green: 96/255, blue: 78/255, opacity: 0.10), radius: 48, x: 0, y: 16)
    static let mint = MaycastShadow(color: Color(.sRGB, red: 31/255, green: 194/255, blue: 152/255, opacity: 0.28), radius: 32, x: 0, y: 12)
}

extension View {
    func maycastShadow(_ s: MaycastShadow) -> some View {
        self.shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
}

// MARK: - Typography

enum MaycastFont {
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Chip

/// Inline pill-shaped tag. Tone drives the background / foreground / border
/// trio and matches the React mock 1:1.
struct MaycastChip<Leading: View>: View {
    enum Tone { case neutral, mint, sky, sun, success, danger, warning }

    let text: String
    let tone: Tone
    let leading: Leading

    init(_ text: String, tone: Tone = .neutral, @ViewBuilder leading: () -> Leading = { EmptyView() }) {
        self.text = text
        self.tone = tone
        self.leading = leading()
    }

    var body: some View {
        HStack(spacing: 4) {
            leading
            Text(text)
                .font(MaycastFont.body(11.5, weight: .semibold))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(bg)
        )
        .overlay(
            Capsule().strokeBorder(border, lineWidth: 0.5)
        )
    }

    private var bg: Color {
        switch tone {
        case .neutral: return MaycastPalette.ink100
        case .mint:    return MaycastPalette.mint50
        case .sky:     return MaycastPalette.sky50
        case .sun:     return MaycastPalette.sun100
        case .success: return MaycastPalette.mint50
        case .danger:  return MaycastPalette.danger.opacity(0.10)
        case .warning: return MaycastPalette.warning.opacity(0.13)
        }
    }
    private var fg: Color {
        switch tone {
        case .neutral: return MaycastPalette.fg2
        case .mint:    return MaycastPalette.mint700
        case .sky:     return MaycastPalette.sky700
        case .sun:     return MaycastPalette.sun700
        case .success: return MaycastPalette.mint700
        case .danger:  return MaycastPalette.danger
        case .warning: return Color(hex: 0xC4760A)
        }
    }
    private var border: Color {
        switch tone {
        case .neutral: return .clear
        case .mint, .success: return MaycastPalette.mint200
        case .sky:     return MaycastPalette.sky200
        case .sun:     return MaycastPalette.sun500.opacity(0.35)
        case .danger:  return MaycastPalette.danger.opacity(0.25)
        case .warning: return MaycastPalette.warning.opacity(0.3)
        }
    }
}

// MARK: - Primary button style
//
// Mint gradient with a hairline border and an inner top highlight. The
// optional glow toggles the brand drop shadow used on the marquee CTAs.

struct MaycastPrimaryButtonStyle: ButtonStyle {
    var glow: Bool = false
    var size: ControlSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        let metrics = SizeMetrics(size)
        configuration.label
            .font(MaycastFont.body(metrics.fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, metrics.padH)
            .frame(minHeight: metrics.height)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(
                            colors: [MaycastPalette.mint400, MaycastPalette.mint500],
                            startPoint: .top, endPoint: .bottom
                        ))
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(MaycastPalette.mint600, lineWidth: 0.5)
                }
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.clear],
                        startPoint: .top, endPoint: .center
                    ))
                    .frame(height: metrics.height / 2)
                    .allowsHitTesting(false)
            }
            .compositingGroup()
            .maycastShadow(glow ? .mint : .xs)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct MaycastSecondaryButtonStyle: ButtonStyle {
    var size: ControlSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        let metrics = SizeMetrics(size)
        configuration.label
            .font(MaycastFont.body(metrics.fontSize, weight: .semibold))
            .foregroundStyle(MaycastPalette.fg1)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, metrics.padH)
            .frame(minHeight: metrics.height)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.white, Color(hex: 0xFAFCFB)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(MaycastPalette.border2, lineWidth: 0.5)
                }
            )
            .maycastShadow(.xs)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct MaycastGhostButtonStyle: ButtonStyle {
    var size: ControlSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        let metrics = SizeMetrics(size)
        configuration.label
            .font(MaycastFont.body(metrics.fontSize, weight: .semibold))
            .foregroundStyle(MaycastPalette.fg2)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, metrics.padH)
            .frame(minHeight: metrics.height)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(configuration.isPressed ? MaycastPalette.ink100 : Color.clear)
            )
    }
}

struct MaycastDestructiveButtonStyle: ButtonStyle {
    var size: ControlSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        let metrics = SizeMetrics(size)
        configuration.label
            .font(MaycastFont.body(metrics.fontSize, weight: .semibold))
            .foregroundStyle(MaycastPalette.danger)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, metrics.padH)
            .frame(minHeight: metrics.height)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.white, Color(hex: 0xFFF5F5)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(hex: 0xF3C2C2), lineWidth: 0.5)
                }
            )
            .maycastShadow(.xs)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct SizeMetrics {
    let height: CGFloat
    let padH: CGFloat
    let fontSize: CGFloat

    init(_ size: ControlSize) {
        switch size {
        case .mini, .small:
            self.height = 24; self.padH = 10; self.fontSize = 12
        case .large, .extraLarge:
            self.height = 38; self.padH = 18; self.fontSize = 14
        case .regular:
            fallthrough
        @unknown default:
            self.height = 30; self.padH = 12; self.fontSize = 13
        }
    }
}

// MARK: - Surface / Card / Section

/// Soft white card with hairline border + xs shadow. The canonical container
/// for grouped content (recent episodes, tracks, sheet sections, etc).
struct MaycastCard<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
    var cornerRadius: CGFloat = 12
    var fill: Color = MaycastPalette.bg1
    var borderColor: Color = MaycastPalette.border1
    let content: () -> Content

    init(
        padding: EdgeInsets = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16),
        cornerRadius: CGFloat = 12,
        fill: Color = MaycastPalette.bg1,
        borderColor: Color = MaycastPalette.border1,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.fill = fill
        self.borderColor = borderColor
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .maycastShadow(.xs)
    }
}

/// Small square "icon tile" used as the leading visual in cards, list rows,
/// and headers. Tone gradient is keyed off the same palette as the chip.
struct MaycastIconTile: View {
    let systemName: String
    var size: CGFloat = 38
    var iconSize: CGFloat = 18
    var tone: MaycastChip<EmptyView>.Tone = .mint
    var cornerRadius: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: gradientStops, startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(iconColor)
            )
    }

    private var gradientStops: [Color] {
        switch tone {
        case .mint, .success: return [MaycastPalette.mint100, MaycastPalette.mint200]
        case .sky:            return [MaycastPalette.sky100,  MaycastPalette.sky200]
        case .sun:            return [MaycastPalette.sun100,  Color(hex: 0xFFD994)]
        case .danger:         return [Color(hex: 0xFFE0E0), Color(hex: 0xFCC2C2)]
        case .warning:        return [Color(hex: 0xFFF0D0), Color(hex: 0xFFD994)]
        case .neutral:        return [MaycastPalette.ink100, MaycastPalette.ink200]
        }
    }
    private var border: Color {
        switch tone {
        case .mint, .success: return MaycastPalette.mint200
        case .sky:            return MaycastPalette.sky200
        case .sun:            return MaycastPalette.sun500.opacity(0.35)
        case .danger:         return MaycastPalette.danger.opacity(0.25)
        case .warning:        return MaycastPalette.warning.opacity(0.3)
        case .neutral:        return MaycastPalette.border1
        }
    }
    private var iconColor: Color {
        switch tone {
        case .mint, .success: return MaycastPalette.mint700
        case .sky:            return MaycastPalette.sky700
        case .sun:            return Color(hex: 0xA17220)
        case .danger:         return MaycastPalette.danger
        case .warning:        return Color(hex: 0xC4760A)
        case .neutral:        return MaycastPalette.fg2
        }
    }
}

// MARK: - Decorative cloud
//
// Used on the home hero background. Deliberately fluffy, low-opacity — the
// page gradient does the heavy lifting; clouds just add depth.

struct MaycastCloud: View {
    var width: CGFloat = 200
    var opacity: Double = 0.55

    var body: some View {
        // A cluster of overlapping circles approximates the playful cloud
        // shape in the SVG asset without needing to ship a raster.
        let h = width * 0.45
        ZStack {
            Circle().frame(width: h * 1.0, height: h * 1.0).offset(x: -width * 0.30, y: h * 0.05)
            Circle().frame(width: h * 1.20, height: h * 1.20).offset(x: -width * 0.10, y: -h * 0.05)
            Circle().frame(width: h * 1.10, height: h * 1.10).offset(x: width * 0.10, y: 0)
            Circle().frame(width: h * 0.90, height: h * 0.90).offset(x: width * 0.30, y: h * 0.05)
            // Soft base that ties the cluster into a single cloud shape.
            RoundedRectangle(cornerRadius: h * 0.5, style: .continuous)
                .frame(width: width * 0.85, height: h * 0.7)
                .offset(y: h * 0.10)
        }
        .foregroundStyle(Color.white.opacity(opacity))
        .frame(width: width, height: h * 1.4)
    }
}

// MARK: - Decorative waveform (mock data)
//
// Used wherever the React mock renders a hero / preview waveform. The peaks
// are deterministic from the seed so the same component renders the same
// shape in every preview / live screen.

struct MaycastDecorativeWaveform: View {
    enum Style { case lines, blocks, gradientBars }

    var seed: Int = 7
    var color: Color = MaycastPalette.mint500
    var style: Style = .gradientBars
    var intensity: CGFloat = 0.9
    var density: CGFloat = 1.2

    var body: some View {
        Canvas { ctx, size in
            let barCount = max(8, Int(size.width / 6 * density))
            let spacing: CGFloat = 1
            let totalSpacing = spacing * CGFloat(barCount - 1)
            let barWidth = max(1, (size.width - totalSpacing) / CGFloat(barCount))
            for i in 0..<barCount {
                let phase = Double(i) * 0.42 + Double(seed) * 0.31
                let envelope = 0.6 + 0.35 * sin(phase * 0.21 + Double(seed))
                let wiggle   = 0.55 + 0.45 * abs(sin(phase * 1.7 + cos(phase * 0.9)))
                let h = max(2, CGFloat(envelope * wiggle) * size.height * intensity)
                let x = CGFloat(i) * (barWidth + spacing)
                let y = (size.height - h) / 2
                let rect = CGRect(x: x, y: y, width: barWidth, height: h)
                switch style {
                case .lines:
                    let r = CGRect(x: x, y: size.height / 2 - 0.7, width: barWidth, height: 1.4)
                    ctx.fill(Path(r), with: .color(color.opacity(0.4)))
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(0.85)))
                case .blocks:
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(0.85)))
                case .gradientBars:
                    let gradient = Gradient(stops: [
                        .init(color: color.opacity(0.85), location: 0),
                        .init(color: color.opacity(0.35), location: 1),
                    ])
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: y), endPoint: CGPoint(x: 0, y: y + h))
                    )
                }
            }
        }
    }
}

// MARK: - Brand logo mark
//
// 5 mint bars + a sun dot — a stylised waveform. Recreated from the SVG so we
// don't need to embed the asset.

struct MaycastLogoMark: View {
    var size: CGFloat = 44

    var body: some View {
        let s = size
        let unit = s / 64
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.22, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.white, MaycastPalette.mint50],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: s * 0.22, style: .continuous)
                        .strokeBorder(MaycastPalette.mint200, lineWidth: 0.5)
                )
            HStack(alignment: .center, spacing: 3 * unit) {
                bar(height:  16, unit: unit)
                bar(height:  28, unit: unit)
                bar(height:  44, unit: unit)
                bar(height:  28, unit: unit)
                bar(height:  16, unit: unit)
            }
            Circle()
                .fill(MaycastPalette.sun500)
                .frame(width: 6 * unit, height: 6 * unit)
                .offset(x: 18 * unit, y: -16 * unit)
        }
        .frame(width: s, height: s)
    }

    private func bar(height: CGFloat, unit: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5 * unit, style: .continuous)
            .fill(LinearGradient(
                colors: [MaycastPalette.mint400, MaycastPalette.mint600],
                startPoint: .top, endPoint: .bottom
            ))
            .frame(width: 6 * unit, height: height * unit)
    }
}

// MARK: - Small helpers

/// "⌘N" style key cap — used on home hero buttons to hint at keyboard shortcuts.
struct MaycastKeyHint: View {
    var modifiers: [String] = []
    var key: String

    var body: some View {
        Text((modifiers + [key]).joined())
            .font(MaycastFont.mono(10.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.8))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.18))
            )
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Palette") {
    VStack(alignment: .leading, spacing: 8) {
        Text("Mint").font(.headline)
        swatch([MaycastPalette.mint50, MaycastPalette.mint100, MaycastPalette.mint300, MaycastPalette.mint500, MaycastPalette.mint700, MaycastPalette.mint900])
        Text("Sky").font(.headline)
        swatch([MaycastPalette.sky50, MaycastPalette.sky100, MaycastPalette.sky300, MaycastPalette.sky500, MaycastPalette.sky700, MaycastPalette.sky900])
        Text("Ink").font(.headline)
        swatch([MaycastPalette.ink50, MaycastPalette.ink100, MaycastPalette.ink300, MaycastPalette.ink500, MaycastPalette.ink700, MaycastPalette.ink900])
    }
    .padding(24)
    .frame(width: 520, height: 360)
    .background(MaycastPalette.bg2)
}

@ViewBuilder
private func swatch(_ colors: [Color]) -> some View {
    HStack(spacing: 6) {
        ForEach(Array(colors.enumerated()), id: \.offset) { _, c in
            RoundedRectangle(cornerRadius: 8).fill(c).frame(width: 56, height: 36)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MaycastPalette.border1, lineWidth: 0.5))
        }
    }
}

#Preview("Buttons & Chips") {
    VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 8) {
            Button("New Episode…") {}.buttonStyle(MaycastPrimaryButtonStyle(glow: true, size: .large))
            Button("New Show…")    {}.buttonStyle(MaycastSecondaryButtonStyle(size: .large))
            Button("Open…")        {}.buttonStyle(MaycastSecondaryButtonStyle(size: .large))
        }
        HStack(spacing: 8) {
            Button("Apply") {}.buttonStyle(MaycastPrimaryButtonStyle())
            Button("Cancel") {}.buttonStyle(MaycastSecondaryButtonStyle())
            Button("More") {}.buttonStyle(MaycastGhostButtonStyle())
            Button("Remove") {}.buttonStyle(MaycastDestructiveButtonStyle())
        }
        HStack(spacing: 6) {
            MaycastChip("neutral", tone: .neutral)
            MaycastChip("mint", tone: .mint) { Image(systemName: "waveform").font(.system(size: 10)) }
            MaycastChip("sky", tone: .sky)
            MaycastChip("sun", tone: .sun)
            MaycastChip("success", tone: .success)
            MaycastChip("warning", tone: .warning)
            MaycastChip("danger", tone: .danger)
        }
        HStack(spacing: 12) {
            MaycastIconTile(systemName: "waveform", tone: .mint)
            MaycastIconTile(systemName: "scissors", tone: .sky)
            MaycastIconTile(systemName: "rectangle.stack", tone: .sun)
            MaycastIconTile(systemName: "wand.and.stars", tone: .mint)
            MaycastLogoMark(size: 44)
        }
        MaycastDecorativeWaveform(seed: 9, color: MaycastPalette.mint500, style: .gradientBars)
            .frame(height: 80)
    }
    .padding(24)
    .frame(width: 720)
    .background(MaycastPalette.bg2)
}
#endif
