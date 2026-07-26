import SwiftUI

/// Compact square control used for navigation, swap, refresh, and overflow
/// actions throughout comparison workspaces.
struct RiffaIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RiffaIconButtonStyleBody(configuration: configuration)
    }
}

private struct RiffaIconButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration

    @Environment(\.riffaTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var surface: Color {
        guard isEnabled else { return theme.surface(.one) }
        if configuration.isPressed { return theme.surface(.three) }
        return isHovering ? theme.surface(.two) : theme.surface(.one)
    }

    var body: some View {
        configuration.label
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(isEnabled ? theme.ink : theme.inkTertiary)
            .frame(width: 40, height: 40)
            .background(
                surface,
                in: RoundedRectangle(cornerRadius: RiffaRadius.md)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RiffaRadius.md)
                    .strokeBorder(
                        isFocused ? theme.focusRing : theme.hairline,
                        lineWidth: isFocused ? theme.focusRingWidth : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: RiffaRadius.md))
            .opacity(isEnabled ? 1 : 0.58)
            .onHover { isHovering = isEnabled && $0 }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovering
            )
    }
}

extension ButtonStyle where Self == RiffaIconButtonStyle {
    static var riffaIcon: RiffaIconButtonStyle { RiffaIconButtonStyle() }
}

/// Search field from the ImageGen workspace references. It keeps a visible
/// keyboard focus ring and exposes the clear action independently to VoiceOver.
struct RiffaSearchField: View {
    let placeholder: LocalizedStringKey
    let accessibilityName: LocalizedStringKey
    @Binding var text: String

    @Environment(\.riffaTheme) private var theme
    @FocusState private var isFocused: Bool

    init(
        _ placeholder: String,
        text: Binding<String>,
        accessibilityName: String
    ) {
        self.placeholder = LocalizedStringKey(placeholder)
        self._text = text
        self.accessibilityName = LocalizedStringKey(accessibilityName)
    }

    var body: some View {
        HStack(spacing: RiffaSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.inkTertiary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .riffaText(.bodySmall)
                .foregroundStyle(theme.ink)
                .focused($isFocused)
                .accessibilityLabel(Text(accessibilityName))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.inkTertiary)
                .accessibilityLabel(Text("Clear \(Text(accessibilityName))"))
            }
        }
        .padding(.horizontal, RiffaSpacing.sm)
        .frame(minWidth: 160, idealWidth: 220, maxWidth: 320, minHeight: 40)
        .background(
            theme.surface(.two),
            in: RoundedRectangle(cornerRadius: RiffaRadius.md)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RiffaRadius.md)
                .strokeBorder(
                    isFocused ? theme.focusRing : theme.hairline,
                    lineWidth: isFocused ? theme.focusRingWidth : 1
                )
        }
    }
}

private struct RiffaInputSurfaceModifier: ViewModifier {
    let minHeight: CGFloat

    @Environment(\.riffaTheme) private var theme
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .riffaText(.bodySmall)
            .foregroundStyle(theme.ink)
            .padding(.horizontal, RiffaSpacing.sm)
            .frame(minHeight: minHeight)
            .background(
                theme.surface(.two),
                in: RoundedRectangle(cornerRadius: RiffaRadius.md)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RiffaRadius.md)
                    .strokeBorder(
                        isFocused ? theme.focusRing : theme.hairline,
                        lineWidth: isFocused ? theme.focusRingWidth : 1
                    )
            }
    }
}

extension View {
    /// Applies the shared solid input surface to TextField and SecureField.
    func riffaInputSurface(minHeight: CGFloat = 40) -> some View {
        modifier(RiffaInputSurfaceModifier(minHeight: minHeight))
    }
}

struct RiffaEmptyState<Actions: View>: View {
    let title: String
    let description: String
    let systemImage: String
    @ViewBuilder let actions: () -> Actions

    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack {
            Spacer(minLength: RiffaSpacing.lg)

            RiffaPanel(
                level: .one,
                cornerRadius: RiffaRadius.xl,
                padding: RiffaSpacing.lg
            ) {
                VStack(spacing: RiffaSpacing.md) {
                    Image(systemName: systemImage)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(theme.accentHover)
                        .accessibilityHidden(true)

                    VStack(spacing: RiffaSpacing.xs) {
                        Text(LocalizedStringKey(title))
                            .riffaText(.cardTitle)
                            .foregroundStyle(theme.ink)
                        Text(LocalizedStringKey(description))
                            .riffaText(.bodySmall)
                            .foregroundStyle(theme.inkSubtle)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                    }

                    actions()
                }
            }
            .frame(maxWidth: 560)

            Spacer(minLength: RiffaSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(RiffaSpacing.lg)
        .background(theme.canvas)
        .accessibilityElement(children: .contain)
    }
}

struct RiffaStatusBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(spacing: RiffaSpacing.sm) {
            content()
        }
        .riffaText(.caption)
        .foregroundStyle(theme.inkSubtle)
        .padding(.horizontal, RiffaSpacing.sm)
        .frame(minHeight: 34)
        .background(theme.surface(.one))
        .overlay(alignment: .top) {
            RiffaHairline()
        }
    }
}

struct RiffaPaneHeader<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    @ViewBuilder let accessory: () -> Accessory

    @Environment(\.riffaTheme) private var theme

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: RiffaSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(theme.inkSubtle)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title))
                    .riffaText(.bodySmall)
                    .foregroundStyle(theme.ink)
                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .riffaText(.caption)
                        .foregroundStyle(theme.inkSubtle)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: RiffaSpacing.xs)
            accessory()
        }
        .padding(.horizontal, RiffaSpacing.sm)
        .frame(minHeight: 40)
        .background(theme.surface(.one))
        .overlay(alignment: .bottom) {
            RiffaHairline()
        }
    }
}

extension RiffaPaneHeader where Accessory == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil
    ) {
        self.init(
            title,
            subtitle: subtitle,
            systemImage: systemImage
        ) {
            EmptyView()
        }
    }
}
