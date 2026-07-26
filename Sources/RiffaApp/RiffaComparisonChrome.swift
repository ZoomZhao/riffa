import SwiftUI

/// Shared product chrome for comparison views.
///
/// The content views retain their semantic difference colors; this chrome
/// deliberately uses only the DESIGN.md neutral ladder and lavender accent.
struct RiffaComparisonHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: () -> Actions

    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(spacing: RiffaSpacing.md) {
            RiffaMark()
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .riffaText(.body)
                    .foregroundStyle(theme.ink)
                Text(LocalizedStringKey(subtitle))
                    .riffaText(.caption)
                    .foregroundStyle(theme.inkSubtle)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: RiffaSpacing.sm)

            ScrollView(.horizontal) {
                HStack(spacing: RiffaSpacing.xs) {
                    actions()
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.automatic)
        }
        .padding(.horizontal, RiffaSpacing.md)
        .padding(.vertical, RiffaSpacing.xs)
        .background(theme.surface(.one))
        .overlay(alignment: .bottom) {
            RiffaHairline()
        }
    }
}

struct RiffaComparisonPathBar<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(spacing: RiffaSpacing.xs) {
            content()
        }
        .padding(RiffaSpacing.xs)
        .background(theme.surface(.two))
        .overlay(alignment: .bottom) {
            RiffaHairline()
        }
    }
}

struct RiffaComparisonControlBar<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: RiffaSpacing.sm) {
                content()
            }
            .padding(.horizontal, RiffaSpacing.md)
            .padding(.vertical, RiffaSpacing.xs)
        }
        .scrollIndicators(.automatic)
        .background(theme.surface(.one))
        .overlay(alignment: .bottom) {
            RiffaHairline()
        }
    }
}

struct RiffaResourcePathButton: View {
    let title: String
    let url: URL?
    let emptyTitle: String
    let systemImage: String
    let accessibilityHint: String
    let action: () -> Void

    @Environment(\.riffaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    init(
        title: String,
        url: URL?,
        emptyTitle: String,
        systemImage: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.url = url
        self.emptyTitle = emptyTitle
        self.systemImage = systemImage
        self.accessibilityHint = accessibilityHint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: RiffaSpacing.xs) {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(theme.accentHover)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(title))
                        .riffaText(.caption)
                        .foregroundStyle(theme.inkSubtle)
                    if let url {
                        Text(verbatim: url.path(percentEncoded: false))
                            .riffaText(.mono)
                            .foregroundStyle(theme.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(LocalizedStringKey(emptyTitle))
                            .riffaText(.mono)
                            .foregroundStyle(theme.inkSubtle)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: RiffaSpacing.xs)

                Image(systemName: "ellipsis")
                    .imageScale(.small)
                    .foregroundStyle(theme.inkTertiary)
            }
            .padding(.horizontal, RiffaSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(
                RoundedRectangle(cornerRadius: RiffaRadius.md)
            )
        }
        .buttonStyle(
            RiffaResourcePathButtonStyle(
                isHovering: isHovering,
                isFocused: isFocused
            )
        )
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: isHovering
        )
        .accessibilityLabel(
            String(
                localized: "\(RiffaLocalization.string(title)), \(url?.path(percentEncoded: false) ?? RiffaLocalization.string("no resource selected"))",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        )
        .accessibilityHint(RiffaLocalization.string(accessibilityHint))
    }
}

private struct RiffaResourcePathButtonStyle: ButtonStyle {
    let isHovering: Bool
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        RiffaResourcePathButtonStyleBody(
            configuration: configuration,
            isHovering: isHovering,
            isFocused: isFocused
        )
    }
}

private struct RiffaResourcePathButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let isHovering: Bool
    let isFocused: Bool
    @Environment(\.riffaTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    private var surface: Color {
        guard isEnabled else { return theme.surface(.one) }
        if configuration.isPressed { return theme.surface(.three) }
        return isHovering ? theme.surface(.three) : theme.surface(.one)
    }

    var body: some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.55)
            .background(
                surface,
                in: RoundedRectangle(cornerRadius: RiffaRadius.md)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RiffaRadius.md)
                    .strokeBorder(
                        isFocused
                            ? theme.focusRing
                            : (isHovering ? theme.hairlineStrong : theme.hairline),
                        lineWidth: isFocused ? theme.focusRingWidth : 1
                    )
            }
    }
}
