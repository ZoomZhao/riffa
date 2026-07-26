import AppKit
import SwiftUI

// MARK: - Foundations

enum RiffaSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

enum RiffaRadius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
}

enum RiffaTextRole: Sendable {
    case displayExtraLarge
    case displayLarge
    case displayMedium
    case headline
    case cardTitle
    case subhead
    case bodyLarge
    case body
    case bodySmall
    case caption
    case button
    case eyebrow
    case mono

    fileprivate var size: CGFloat {
        switch self {
        case .displayExtraLarge: 80
        case .displayLarge: 56
        case .displayMedium: 40
        case .headline: 28
        case .cardTitle: 22
        case .subhead: 20
        case .bodyLarge: 18
        case .body, .bodySmall, .button: 14
        case .caption: 12
        case .eyebrow, .mono: 13
        }
    }

    fileprivate var weight: Font.Weight {
        switch self {
        case .displayExtraLarge, .displayLarge, .displayMedium, .headline:
            .semibold
        case .cardTitle, .button, .eyebrow:
            .medium
        default:
            .regular
        }
    }

    fileprivate var design: Font.Design {
        self == .mono ? .monospaced : .default
    }

    fileprivate var tracking: CGFloat {
        switch self {
        case .displayExtraLarge: -3
        case .displayLarge: -1.8
        case .displayMedium: -1
        case .headline: -0.6
        case .cardTitle: -0.4
        case .subhead: -0.2
        case .bodyLarge: -0.1
        case .body: -0.05
        case .eyebrow: 0.4
        default: 0
        }
    }

    fileprivate var lineHeightMultiplier: CGFloat {
        switch self {
        case .displayExtraLarge: 1.05
        case .displayLarge: 1.10
        case .displayMedium: 1.15
        case .headline: 1.20
        case .cardTitle: 1.25
        case .subhead: 1.40
        case .bodyLarge, .body, .bodySmall, .mono: 1.50
        case .caption: 1.40
        case .button: 1.20
        case .eyebrow: 1.30
        }
    }

    fileprivate var relativeStyle: Font.TextStyle {
        switch self {
        case .displayExtraLarge, .displayLarge:
            .largeTitle
        case .displayMedium:
            .title
        case .headline:
            .title2
        case .cardTitle:
            .title3
        case .subhead, .bodyLarge:
            .headline
        case .body, .mono:
            .body
        case .bodySmall, .button, .eyebrow:
            .callout
        case .caption:
            .caption
        }
    }
}

/// Unscaled font tokens for controls that cannot accept a view modifier.
/// Prefer ``View/riffaText(_:)`` for text because that variant scales with the
/// user's accessibility text-size preference.
enum RiffaTypography {
    static let displayExtraLarge = font(for: .displayExtraLarge)
    static let displayLarge = font(for: .displayLarge)
    static let displayMedium = font(for: .displayMedium)
    static let headline = font(for: .headline)
    static let cardTitle = font(for: .cardTitle)
    static let subhead = font(for: .subhead)
    static let bodyLarge = font(for: .bodyLarge)
    static let body = font(for: .body)
    static let bodySmall = font(for: .bodySmall)
    static let caption = font(for: .caption)
    static let button = font(for: .button)
    static let eyebrow = font(for: .eyebrow)
    static let mono = font(for: .mono)

    private static func font(for role: RiffaTextRole) -> Font {
        .system(size: role.size, weight: role.weight, design: role.design)
    }
}

private struct RiffaTextModifier: ViewModifier {
    let role: RiffaTextRole
    @ScaledMetric private var scaledSize: CGFloat

    init(role: RiffaTextRole) {
        self.role = role
        _scaledSize = ScaledMetric(
            wrappedValue: role.size,
            relativeTo: role.relativeStyle
        )
    }

    func body(content: Content) -> some View {
        let scale = scaledSize / role.size
        content
            .font(.system(size: scaledSize, weight: role.weight, design: role.design))
            .tracking(role.tracking * scale)
            .lineSpacing(max(0, scaledSize * (role.lineHeightMultiplier - 1)))
    }
}

extension View {
    func riffaText(_ role: RiffaTextRole) -> some View {
        modifier(RiffaTextModifier(role: role))
    }
}

// MARK: - Adaptive theme

enum RiffaSurfaceLevel: Sendable {
    case canvas
    case one
    case two
    case three
    case four
}

struct RiffaTheme: Sendable {
    let palette: RiffaThemePalette
    let colorScheme: ColorScheme
    let usesIncreasedContrast: Bool
    let reducesTransparency: Bool

    static let standard = RiffaTheme(
        palette: .preset(.midnight, colorScheme: .dark),
        colorScheme: .dark,
        usesIncreasedContrast: false,
        reducesTransparency: false
    )

    var canvas: Color { palette.canvas }
    var ink: Color { palette.ink }
    var inkMuted: Color { palette.inkMuted }
    var inkSubtle: Color {
        usesIncreasedContrast ? palette.inkMuted : palette.inkSubtle
    }
    var inkTertiary: Color {
        usesIncreasedContrast ? palette.inkSubtle : palette.inkTertiary
    }
    var accent: Color { palette.accent }
    var accentHover: Color { palette.accentHover }
    var accentFocus: Color { palette.accentFocus }
    var success: Color { palette.success }
    var warning: Color { palette.warning }
    var danger: Color { palette.danger }
    var secure: Color { palette.secure }

    var onAccent: Color { palette.onAccent }

    var hairline: Color {
        usesIncreasedContrast ? palette.hairlineTertiary : palette.hairline
    }
    var hairlineStrong: Color {
        usesIncreasedContrast ? palette.inkSubtle : palette.hairlineStrong
    }
    var focusRing: Color {
        accentFocus.opacity(
            usesIncreasedContrast || reducesTransparency ? 1 : 0.5
        )
    }
    var focusRingWidth: CGFloat { usesIncreasedContrast ? 3 : 2 }

    var nsCanvas: NSColor { palette.nsCanvas }
    var nsSurface1: NSColor { palette.nsSurface1 }
    var nsInk: NSColor { palette.nsInk }

    func surface(_ level: RiffaSurfaceLevel) -> Color {
        switch level {
        case .canvas: palette.canvas
        case .one: palette.surface1
        case .two: palette.surface2
        case .three: palette.surface3
        case .four: palette.surface4
        }
    }
}

private struct RiffaThemeKey: EnvironmentKey {
    static let defaultValue = RiffaTheme.standard
}

extension EnvironmentValues {
    var riffaTheme: RiffaTheme {
        get { self[RiffaThemeKey.self] }
        set { self[RiffaThemeKey.self] = newValue }
    }
}

private struct RiffaAppThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(RiffaUserDefaultsKey.appearanceMode)
    private var appearanceRawValue = RiffaAppearanceMode.defaultValue.rawValue
    @AppStorage(RiffaUserDefaultsKey.language)
    private var languageRawValue = RiffaLanguage.defaultValue.rawValue
    @AppStorage(RiffaUserDefaultsKey.themePreset)
    private var presetRawValue = RiffaThemePreset.defaultValue.rawValue
    @AppStorage(RiffaUserDefaultsKey.themeCustomAccent)
    private var customAccentHex = ""
    @AppStorage(RiffaUserDefaultsKey.themeDocumentID)
    private var themeDocumentID = ""
    @AppStorage(RiffaUserDefaultsKey.themeDocumentRevision)
    private var themeDocumentRevision = 0

    private var appearance: RiffaAppearanceMode {
        RiffaAppearanceMode(rawValue: appearanceRawValue) ?? .defaultValue
    }

    private var language: RiffaLanguage {
        RiffaLanguage(rawValue: languageRawValue) ?? .defaultValue
    }

    private var preset: RiffaThemePreset {
        RiffaThemePreset(rawValue: presetRawValue) ?? .defaultValue
    }

    private var resolvedColorScheme: ColorScheme {
        appearance.preferredColorScheme ?? systemColorScheme
    }

    private var theme: RiffaTheme {
        _ = themeDocumentRevision
        let document: RiffaThemeDocument? = if themeDocumentID.isEmpty {
            nil
        } else {
            try? RiffaThemeDocumentStore().load(id: themeDocumentID)
        }
        let palette = (try? RiffaThemePalette.resolve(
            preset: preset,
            colorScheme: resolvedColorScheme,
            customAccentHex: customAccentHex.isEmpty ? nil : customAccentHex,
            themeDocument: document
        )) ?? .preset(preset, colorScheme: resolvedColorScheme)

        return RiffaTheme(
            palette: palette,
            colorScheme: resolvedColorScheme,
            usesIncreasedContrast: contrast == .increased,
            reducesTransparency: reduceTransparency
        )
    }

    func body(content: Content) -> some View {
        content
            .environment(\.riffaTheme, theme)
            .tint(theme.accent)
            .foregroundStyle(theme.ink)
            .background {
                theme.canvas.ignoresSafeArea()
            }
            .environment(\.locale, language.locale ?? .autoupdatingCurrent)
            .preferredColorScheme(appearance.preferredColorScheme)
    }
}

extension View {
    /// Installs the DESIGN.md palette and accessibility-aware theme at a
    /// window's root. Apply once per scene rather than to individual controls.
    func riffaAppTheme() -> some View {
        modifier(RiffaAppThemeModifier())
    }
}

// MARK: - Buttons

enum RiffaButtonKind: Sendable {
    case primary
    case secondary
    case tertiary
}

struct RiffaButtonStyle: ButtonStyle {
    let kind: RiffaButtonKind

    init(_ kind: RiffaButtonKind) {
        self.kind = kind
    }

    func makeBody(configuration: Configuration) -> some View {
        RiffaButtonStyleBody(kind: kind, configuration: configuration)
    }
}

private struct RiffaButtonStyleBody: View {
    let kind: RiffaButtonKind
    let configuration: ButtonStyle.Configuration

    @Environment(\.riffaTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var background: Color {
        guard isEnabled else { return theme.surface(.two) }

        switch kind {
        case .primary:
            if configuration.isPressed {
                return theme.accentFocus
            }
            return isHovering ? theme.accentHover : theme.accent
        case .secondary:
            return isHovering || configuration.isPressed
                ? theme.surface(.two)
                : theme.surface(.one)
        case .tertiary:
            return isHovering || configuration.isPressed
                ? theme.surface(.one)
                : theme.canvas
        }
    }

    private var foreground: Color {
        guard isEnabled else { return theme.inkTertiary }
        guard kind == .primary else { return theme.ink }

        // DESIGN.md's lighter lavender is retained for hover, but its readable
        // foreground is the near-black canvas rather than a fixed white value.
        return isHovering && !configuration.isPressed
            ? theme.canvas
            : theme.onAccent
    }

    private var border: Color {
        switch kind {
        case .primary:
            isFocused ? theme.focusRing : .clear
        case .secondary, .tertiary:
            isFocused ? theme.focusRing : theme.hairline
        }
    }

    var body: some View {
        configuration.label
            .riffaText(.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(background, in: RoundedRectangle(cornerRadius: RiffaRadius.md))
            .overlay {
                RoundedRectangle(cornerRadius: RiffaRadius.md)
                    .strokeBorder(
                        border,
                        lineWidth: isFocused ? theme.focusRingWidth : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: RiffaRadius.md))
            .onHover { isHovering = isEnabled && $0 }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovering
            )
    }
}

extension ButtonStyle where Self == RiffaButtonStyle {
    static var riffaPrimary: RiffaButtonStyle { RiffaButtonStyle(.primary) }
    static var riffaSecondary: RiffaButtonStyle { RiffaButtonStyle(.secondary) }
    static var riffaTertiary: RiffaButtonStyle { RiffaButtonStyle(.tertiary) }
}

// MARK: - Panels and cards

struct RiffaPanel<Content: View>: View {
    let level: RiffaSurfaceLevel
    let cornerRadius: CGFloat
    let padding: CGFloat
    let isInteractive: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.riffaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    init(
        level: RiffaSurfaceLevel = .one,
        cornerRadius: CGFloat = RiffaRadius.lg,
        padding: CGFloat = RiffaSpacing.lg,
        isInteractive: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.level = level
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.isInteractive = isInteractive
        self.content = content
    }

    private var activeLevel: RiffaSurfaceLevel {
        isInteractive && isHovering ? .two : level
    }

    var body: some View {
        content()
            .padding(padding)
            .background(
                theme.surface(activeLevel),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        isHovering ? theme.hairlineStrong : theme.hairline,
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onHover {
                guard isInteractive else { return }
                isHovering = $0
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovering
            )
    }
}

struct RiffaCard<Content: View>: View {
    let isInteractive: Bool
    @ViewBuilder let content: () -> Content

    init(
        isInteractive: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isInteractive = isInteractive
        self.content = content
    }

    var body: some View {
        RiffaPanel(
            level: .one,
            cornerRadius: RiffaRadius.lg,
            padding: RiffaSpacing.lg,
            isInteractive: isInteractive,
            content: content
        )
    }
}

private struct RiffaPanelModifier: ViewModifier {
    let level: RiffaSurfaceLevel
    let cornerRadius: CGFloat
    let padding: CGFloat

    @Environment(\.riffaTheme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                theme.surface(level),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(theme.hairline, lineWidth: 1)
            }
    }
}

extension View {
    func riffaPanel(
        level: RiffaSurfaceLevel = .one,
        cornerRadius: CGFloat = RiffaRadius.lg,
        padding: CGFloat = RiffaSpacing.lg
    ) -> some View {
        modifier(
            RiffaPanelModifier(
                level: level,
                cornerRadius: cornerRadius,
                padding: padding
            )
        )
    }
}

// MARK: - Status and focus

enum RiffaStatusTone: Sendable {
    case neutral
    case success
    case secure
    case warning
    case danger
}

struct RiffaStatusBadge: View {
    let title: Text
    let systemImage: String?
    let tone: RiffaStatusTone

    @Environment(\.riffaTheme) private var theme
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        tone: RiffaStatusTone = .neutral
    ) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.tone = tone
    }

    init(
        verbatim title: String,
        systemImage: String? = nil,
        tone: RiffaStatusTone = .neutral
    ) {
        self.title = Text(verbatim: title)
        self.systemImage = systemImage
        self.tone = tone
    }

    private var foreground: Color {
        switch tone {
        case .neutral: theme.inkMuted
        case .success: theme.success
        case .secure: theme.secure
        case .warning: theme.warning
        case .danger: theme.danger
        }
    }

    private var background: Color {
        guard !theme.reducesTransparency else { return theme.surface(.two) }

        return switch tone {
        case .neutral: theme.surface(.two)
        case .success: theme.success.opacity(0.14)
        case .secure: theme.secure.opacity(0.16)
        case .warning: theme.warning.opacity(0.14)
        case .danger: theme.danger.opacity(0.14)
        }
    }

    private var effectiveSystemImage: String? {
        if let systemImage {
            return systemImage
        }
        guard differentiateWithoutColor else {
            return nil
        }

        return switch tone {
        case .neutral: nil
        case .success: "checkmark.circle"
        case .secure: "lock.shield"
        case .warning: "exclamationmark.triangle"
        case .danger: "xmark.octagon"
        }
    }

    var body: some View {
        HStack(spacing: RiffaSpacing.xxs) {
            if let systemImage = effectiveSystemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            title
        }
        .riffaText(.caption)
        .foregroundStyle(foreground)
        .padding(.horizontal, RiffaSpacing.xs)
        .padding(.vertical, 2)
        .background(background, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    theme.usesIncreasedContrast ? foreground : theme.hairline,
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RiffaFocusRingModifier: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat
    @Environment(\.riffaTheme) private var theme

    func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(theme.focusRing, lineWidth: theme.focusRingWidth)
            }
        }
    }
}

extension View {
    /// Applies the canonical lavender focus ring. Pass a FocusState binding's
    /// boolean value so the ring follows keyboard as well as pointer focus.
    func riffaFocusRing(
        _ isFocused: Bool,
        cornerRadius: CGFloat = RiffaRadius.md
    ) -> some View {
        modifier(
            RiffaFocusRingModifier(
                isFocused: isFocused,
                cornerRadius: cornerRadius
            )
        )
    }
}

struct RiffaHairline: View {
    let axis: Axis
    @Environment(\.riffaTheme) private var theme

    init(_ axis: Axis = .horizontal) {
        self.axis = axis
    }

    var body: some View {
        Rectangle()
            .fill(theme.hairline)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
            .accessibilityHidden(true)
    }
}
