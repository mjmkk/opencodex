import SwiftUI

/// Shared presentation values; business state stays in the existing features.
enum CodexAppearance {
    static let pageInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let canvas = Color(uiColor: .systemBackground)
    static let separator = Color(uiColor: .separator).opacity(0.35)
}

struct CodexPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(minHeight: 44)
            .padding(.horizontal, 18)
            .foregroundStyle(CodexAppearance.canvas)
            .background(Color.primary, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.35)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CodexIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(.primary)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear, in: Circle())
            .contentShape(Circle())
    }
}

struct CodexNotice: View {
    enum Tone { case neutral, warning, error }
    let title: String
    var detail: String? = nil
    var symbol: String = "info.circle"
    var tone: Tone = .neutral

    private var tint: Color {
        switch tone {
        case .neutral: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct CodexEmptyState: View {
    let title: String
    let detail: String
    var symbol: String = "bubble.left.and.text.bubble.right"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(detail).font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(CodexPrimaryButtonStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(28)
    }
}
