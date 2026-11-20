import SwiftUI
import UIKit
import ShoeboxCore

// MARK: - Colour

extension Color {
    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// The app's green. Deep enough in light mode to carry white text, lifted in dark mode to stay legible.
    static let brand = dynamic(light: UIColor(red: 0.04, green: 0.44, blue: 0.37, alpha: 1),
                               dark: UIColor(red: 0.33, green: 0.85, blue: 0.70, alpha: 1))
    /// A fixed green for filled controls that carry white text, the same in light and dark.
    static let brandFill = Color(red: 0.04, green: 0.44, blue: 0.37)
    static let brandSoft = dynamic(light: UIColor(red: 0.04, green: 0.44, blue: 0.37, alpha: 0.10),
                                   dark: UIColor(red: 0.33, green: 0.85, blue: 0.70, alpha: 0.16))
    static let attention = dynamic(light: UIColor(red: 0.78, green: 0.42, blue: 0.02, alpha: 1),
                                   dark: UIColor(red: 1.00, green: 0.70, blue: 0.25, alpha: 1))
    static let attentionSoft = dynamic(light: UIColor(red: 0.95, green: 0.60, blue: 0.10, alpha: 0.14),
                                       dark: UIColor(red: 1.00, green: 0.70, blue: 0.25, alpha: 0.18))
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let screenBackground = Color(uiColor: .systemGroupedBackground)
    static let hairline = Color(uiColor: .separator).opacity(0.6)

    /// Fixed hero colours: the balance card looks the same in light and dark.
    static let heroTop = Color(red: 0.03, green: 0.33, blue: 0.29)
    static let heroBottom = Color(red: 0.05, green: 0.52, blue: 0.42)
    static let heroGlow = Color(red: 0.45, green: 0.93, blue: 0.74)
}

// MARK: - Metrics

enum Metrics {
    static let cardRadius: CGFloat = 22
    static let cardPadding: CGFloat = 18
    static let screenPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 16
}

// MARK: - Formatting

enum Format {
    static func money(_ cents: Int) -> String {
        let value = Decimal(cents) / 100
        return value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    /// Whole dollars for tight spaces such as chart axes: `$1,250`.
    static func moneyWhole(_ cents: Int) -> String {
        let value = Decimal(cents) / 100
        return value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(0)))
    }

    static func day(_ day: DayDate) -> String {
        day.date().formatted(date: .abbreviated, time: .omitted)
    }

    static func dayLong(_ day: DayDate) -> String {
        day.date().formatted(date: .long, time: .omitted)
    }

    static func monthDay(_ day: DayDate) -> String {
        day.date().formatted(.dateTime.month(.abbreviated).day())
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Category presentation

extension ExpenseCategory {
    var symbol: String {
        switch self {
        case .medical: return "stethoscope"
        case .dental: return "mouth.fill"
        case .vision: return "eyeglasses"
        case .pharmacy: return "pills.fill"
        case .mentalHealth: return "brain.head.profile"
        case .labImaging: return "waveform.path.ecg"
        case .equipment: return "cross.case.fill"
        case .other: return "square.grid.2x2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .medical: return Color(red: 0.16, green: 0.50, blue: 0.86)
        case .dental: return Color(red: 0.10, green: 0.62, blue: 0.66)
        case .vision: return Color(red: 0.45, green: 0.40, blue: 0.85)
        case .pharmacy: return Color(red: 0.86, green: 0.36, blue: 0.42)
        case .mentalHealth: return Color(red: 0.72, green: 0.42, blue: 0.80)
        case .labImaging: return Color(red: 0.90, green: 0.52, blue: 0.16)
        case .equipment: return Color(red: 0.30, green: 0.62, blue: 0.36)
        case .other: return Color(red: 0.50, green: 0.53, blue: 0.58)
        }
    }
}

extension ExpenseStatus {
    var tint: Color {
        switch self {
        case .unreimbursed, .partiallyReimbursed: return .brand
        case .reimbursed, .paidFromHSA, .ineligible: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .unreimbursed: return "circle"
        case .partiallyReimbursed: return "circle.lefthalf.filled"
        case .reimbursed: return "checkmark.circle.fill"
        case .paidFromHSA: return "creditcard.fill"
        case .ineligible: return "slash.circle"
        }
    }
}

extension AttachmentKind {
    var symbol: String {
        switch self {
        case .receipt: return "receipt"
        case .eob: return "doc.text.magnifyingglass"
        case .other: return "doc"
        }
    }

    var longLabel: String {
        switch self {
        case .receipt: return "Receipt"
        case .eob: return "Explanation of Benefits"
        case .other: return "Other document"
        }
    }
}

// MARK: - Building blocks

/// The standard rounded container used on the Summary and detail screens.
struct Card<Content: View>: View {
    var padding: CGFloat = Metrics.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

struct SectionHeader: View {
    var title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(.horizontal, 4)
    }
}

struct StatusBadge: View {
    var status: ExpenseStatus

    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(status.tint)
            .background(status.tint.opacity(0.13), in: Capsule())
    }
}

struct IssueChip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(Color.attention)
            .background(Color.attentionSoft, in: Capsule())
    }
}

struct CategoryIcon: View {
    var category: ExpenseCategory
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(category.tint)
            .frame(width: size, height: size)
            .background(category.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A large amount with the cents set smaller, the way a bank statement headline reads.
struct HeroAmount: View {
    var cents: Int
    var size: CGFloat = 52

    var body: some View {
        let whole = Format.moneyWhole(cents - (cents % 100))
        let fraction = String(format: ".%02d", abs(cents) % 100)
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(whole)
                .font(.system(size: size, weight: .bold, design: .rounded))
            Text(fraction)
                .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                .opacity(0.75)
        }
        .monospacedDigit()
        .minimumScaleFactor(0.5)
        .lineLimit(1)
        .contentTransition(.numericText(value: Double(cents)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Format.money(cents))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .background(Color.brandFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A calm, centred empty state with one clear next step.
struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Color.brand)
                .frame(width: 92, height: 92)
                .background(Color.brandSoft, in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}

enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
