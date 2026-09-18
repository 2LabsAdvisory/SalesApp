import SwiftUI

// The 2Labs design system, from the tokens in
// mockups/Sales_Mobile_Prototype.html: one warm neutral, one amber accent,
// 1px borders rather than shadows. The prototype defines no dark palette, so
// the app is light-only until one is designed.

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    static let ink = Color(hex: 0x1F242E)
    static let ink2 = Color(hex: 0x676F7E)
    static let ink3 = Color(hex: 0x9AA0AB)
    static let appBackground = Color(hex: 0xF9F7F5)
    static let surface = Color.white
    static let border = Color(hex: 0xE5E0DC)
    static let border2 = Color(hex: 0xEFEAE4)

    static let amber = Color(hex: 0xF59E0B)
    static let amber600 = Color(hex: 0xD9870A)
    static let amberTint = Color(hex: 0xFDF3E3)

    static let success = Color(hex: 0x2F8558)
    static let successBackground = Color(hex: 0xE7F3EC)
    static let warning = Color(hex: 0xB7791F)
    static let warningBackground = Color(hex: 0xFBF0DC)
    static let failure = Color(hex: 0xC2410C)
    static let failureBackground = Color(hex: 0xFBE8E0)
    static let violet = Color(hex: 0x6D5AE0)
    static let violetBackground = Color(hex: 0xEEEBFB)
    static let brandNavy = Color(hex: 0x05294F)
}

extension Font {
    /// Plus Jakarta Sans in the prototype; the system face until the font is bundled.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight)
    }

    /// JetBrains Mono in the prototype, used for section labels and timers.
    static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Pieces

/// "NEEDS A LOOK", "EARLIER": the mono, uppercase section label.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.mono(10.5))
            .tracking(1.05)
            .foregroundStyle(Color.ink3)
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// White, rounded, one hairline border. No shadow.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: 1))
    }
}

/// The small tinted square at the start of a list row.
struct RowIcon: View {
    enum Tone { case violet, amber, green, neutral, failure }

    let systemName: String
    let tone: Tone

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(foreground)
            .frame(width: 30, height: 30)
            .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }

    private var foreground: Color {
        switch tone {
        case .violet: .violet
        case .amber: .amber600
        case .green: .success
        case .neutral: .ink2
        case .failure: .failure
        }
    }

    private var background: Color {
        switch tone {
        case .violet: .violetBackground
        case .amber: .amberTint
        case .green: .successBackground
        case .neutral: .appBackground
        case .failure: .failureBackground
        }
    }
}

/// A row inside a Card: icon, a title, a quieter line beneath.
struct ListRow<Accessory: View>: View {
    let icon: RowIcon
    let title: String
    let subtitle: String
    var showsDivider = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.ink2)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            if showsDivider {
                Rectangle().fill(Color.border2).frame(height: 1)
            }
        }
    }
}

extension ListRow where Accessory == EmptyView {
    init(icon: RowIcon, title: String, subtitle: String, showsDivider: Bool = true) {
        self.init(icon: icon, title: title, subtitle: subtitle, showsDivider: showsDivider) { EmptyView() }
    }
}

/// The amber, one-per-screen action.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(Color.amber.opacity(configuration.isPressed ? 0.85 : 1),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// White with a hairline border.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(configuration.isPressed ? Color.appBackground : Color.surface,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.border, lineWidth: 1))
    }
}

/// The amber-on-cream, or warning, notice at the top of a list.
struct Notice: View {
    enum Tone { case warning, info }
    let systemName: String
    let text: Text
    var tone: Tone = .warning

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemName)
            text
        }
        .font(.system(size: 12.5))
        .foregroundStyle(tone == .warning ? Color.warning : Color.violet)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(tone == .warning ? Color.warningBackground : Color.violetBackground,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// The brand mark: three bars, the tallest amber.
struct BrandMark: View {
    var size: CGFloat = 30

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 64
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale),
                     cornerRadius: r * scale)
            }
            context.fill(rect(2, 2, 60, 60, 15), with: .color(.brandNavy))
            context.fill(rect(16, 38, 8, 14, 2.5), with: .color(.white))
            context.fill(rect(28, 28, 8, 24, 2.5), with: .color(.white))
            context.fill(rect(40, 15, 8, 37, 2.5), with: .color(.amber))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
