import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct RiffaApp: App {
    @NSApplicationDelegateAdaptor(RiffaApplicationDelegate.self) private var appDelegate
    @AppStorage(RiffaUserDefaultsKey.language)
    private var languageRawValue = RiffaLanguage.defaultValue.rawValue
    @StateObject private var securityScopedAccessRegistry: SecurityScopedAccessRegistry
    @StateObject private var comparisonOpenBroker: ComparisonOpenBroker
    @StateObject private var workspaceCatalogCoordinator: WorkspaceCatalogCoordinator

    init() {
        let runtime = RiffaApplicationRuntime.shared
        let registry = runtime.securityScopedAccessRegistry
        _securityScopedAccessRegistry = StateObject(wrappedValue: registry)
        _comparisonOpenBroker = StateObject(
            wrappedValue: runtime.comparisonOpenBroker
        )
        _workspaceCatalogCoordinator = StateObject(
            wrappedValue: WorkspaceCatalogCoordinator()
        )
    }

    private var language: RiffaLanguage {
        RiffaLanguage(rawValue: languageRawValue) ?? .defaultValue
    }

    var body: some Scene {
        WindowGroup("Riffa", id: "comparison") {
            RiffaRootView()
                .environmentObject(comparisonOpenBroker)
                .environmentObject(securityScopedAccessRegistry)
                .frame(minWidth: 980, minHeight: 640)
                .riffaAppTheme()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            RiffaSessionCommands()
        }

        WindowGroup(
            Text(verbatim: sceneTitle("Session Library")),
            id: "session-library"
        ) {
            SessionLibraryView()
                .riffaOpensComparisonOnDrop()
                .environmentObject(comparisonOpenBroker)
                .environmentObject(securityScopedAccessRegistry)
                .environmentObject(workspaceCatalogCoordinator)
                .frame(minWidth: 860, minHeight: 560)
                .riffaAppTheme()
        }
        .defaultSize(width: 1040, height: 700)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            RiffaSessionCommands()
        }

        WindowGroup(
            Text(verbatim: sceneTitle("Workspace")),
            id: "workspace",
            for: UUID.self
        ) { $windowID in
            Group {
                if let windowID {
                    WorkspaceWindowView(windowID: windowID)
                } else {
                    ContentUnavailableView(
                        "Workspace Window Unavailable",
                        systemImage: "rectangle.on.rectangle.slash",
                        description: Text("Open a workspace window from the Session Library.")
                    )
                }
            }
            .riffaCoordinatesAndOpensComparisonOnDrop()
            .environmentObject(comparisonOpenBroker)
            .environmentObject(securityScopedAccessRegistry)
            .environmentObject(workspaceCatalogCoordinator)
            .riffaAppTheme()
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            RiffaSessionCommands()
        }

        WindowGroup(
            Text(verbatim: sceneTitle("Resource Tools")),
            id: "resource-tools"
        ) {
            ResourceToolsView()
                .riffaOpensComparisonOnDrop()
                .environmentObject(comparisonOpenBroker)
                .environmentObject(securityScopedAccessRegistry)
                .frame(minWidth: 900, minHeight: 580)
                .riffaAppTheme()
        }
        .defaultSize(width: 1120, height: 720)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            RiffaSessionCommands()
        }

        Settings {
            RiffaSettingsView()
                .riffaOpensComparisonOnDrop()
                .environmentObject(comparisonOpenBroker)
                .environmentObject(securityScopedAccessRegistry)
                .riffaAppTheme()
        }
    }

    private func sceneTitle(_ key: String) -> String {
        RiffaLocalization.string(key, language: language)
    }
}

private struct RiffaSettingsView: View {
    @Environment(\.riffaTheme) private var theme
    @AppStorage(RiffaUserDefaultsKey.language)
    private var languageRawValue = RiffaLanguage.defaultValue.rawValue
    @AppStorage(RiffaUserDefaultsKey.appearanceMode)
    private var appearanceRawValue = RiffaAppearanceMode.defaultValue.rawValue
    @AppStorage(RiffaUserDefaultsKey.themePreset)
    private var themePresetRawValue = RiffaThemePreset.defaultValue.rawValue
    @AppStorage(RiffaUserDefaultsKey.themeCustomAccent)
    private var customAccentHex = ""
    @AppStorage(RiffaUserDefaultsKey.themeDocumentID)
    private var themeDocumentID = ""
    @AppStorage(RiffaUserDefaultsKey.themeDocumentFilename)
    private var themeDocumentFilename = ""
    @AppStorage(RiffaUserDefaultsKey.themeDocumentRevision)
    private var themeDocumentRevision = 0
    @State private var themeImportError: String?

    private var appearance: RiffaAppearanceMode {
        get { RiffaAppearanceMode(rawValue: appearanceRawValue) ?? .defaultValue }
        nonmutating set { appearanceRawValue = newValue.rawValue }
    }

    private var language: RiffaLanguage {
        get { RiffaLanguage(rawValue: languageRawValue) ?? .defaultValue }
        nonmutating set { languageRawValue = newValue.rawValue }
    }

    private var themePreset: RiffaThemePreset {
        get { RiffaThemePreset(rawValue: themePresetRawValue) ?? .defaultValue }
        nonmutating set {
            themePresetRawValue = newValue.rawValue
            customAccentHex = ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: RiffaSpacing.lg) {
                    VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                        Text("Settings")
                            .riffaText(.headline)
                            .foregroundStyle(theme.ink)
                        Text("Personalize language and appearance across every Riffa window.")
                            .riffaText(.bodySmall)
                            .foregroundStyle(theme.inkSubtle)
                    }

                    languagePanel
                    appearancePanel
                    settingsPanel
                    privacyPanel
                }
                .padding(RiffaSpacing.lg)
            }

            RiffaStatusBar {
                Text("Riffa 0.1")
                Spacer()
                Label("Apple Silicon", systemImage: "cpu")
                    .accessibilityElement(children: .combine)
            }
        }
        .frame(width: 680, height: 760)
        .background(theme.canvas)
    }

    private var languagePanel: some View {
        RiffaPanel(
            level: .one,
            cornerRadius: RiffaRadius.lg,
            padding: 0
        ) {
            VStack(spacing: 0) {
                panelHeading(
                    eyebrow: "LANGUAGE",
                    title: "App Language",
                    description: "Switch Riffa’s interface language without restarting.",
                    systemImage: "character.bubble"
                )

                VStack(alignment: .leading, spacing: RiffaSpacing.xs) {
                    Picker(
                        "Language",
                        selection: Binding(
                            get: { language },
                            set: { language = $0 }
                        )
                    ) {
                        ForEach(RiffaLanguage.allCases) { option in
                            Text(languageTitle(option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("Changes the interface language in every Riffa window")

                    Text("System follows the preferred language configured in macOS.")
                        .riffaText(.caption)
                        .foregroundStyle(theme.inkSubtle)
                }
                .padding(RiffaSpacing.md)
                .overlay(alignment: .top) {
                    RiffaHairline()
                }
            }
        }
    }

    private var appearancePanel: some View {
        RiffaPanel(
            level: .one,
            cornerRadius: RiffaRadius.lg,
            padding: 0
        ) {
            VStack(spacing: 0) {
                panelHeading(
                    eyebrow: "APPEARANCE",
                    title: "Theme",
                    description: "Choose a built-in palette, custom accent, or validated theme document.",
                    systemImage: "paintpalette"
                )

                VStack(alignment: .leading, spacing: RiffaSpacing.md) {
                    Picker(
                        "Appearance",
                        selection: Binding(
                            get: { appearance },
                            set: { appearance = $0 }
                        )
                    ) {
                        ForEach(RiffaAppearanceMode.allCases) { option in
                            Text(appearanceTitle(option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("Follows macOS or forces Riffa to use a light or dark palette")

                    VStack(alignment: .leading, spacing: RiffaSpacing.xs) {
                        Text("Theme Preset")
                            .riffaText(.eyebrow)
                            .foregroundStyle(theme.inkTertiary)

                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: RiffaSpacing.xs),
                                count: 4
                            ),
                            spacing: RiffaSpacing.xs
                        ) {
                            ForEach(RiffaThemePreset.allCases) { preset in
                                themePresetButton(preset)
                            }
                        }
                    }

                    HStack(spacing: RiffaSpacing.sm) {
                        ColorPicker(
                            "Custom Accent",
                            selection: customAccentBinding,
                            supportsOpacity: false
                        )
                        .accessibilityHint(
                            "Overrides only brand, focus, selection, and primary action colors"
                        )

                        if !customAccentHex.isEmpty {
                            Text(customAccentHex.uppercased())
                                .riffaText(.mono)
                                .foregroundStyle(theme.inkSubtle)
                            Button("Use Preset Accent") {
                                customAccentHex = ""
                            }
                            .buttonStyle(.riffaTertiary)
                        }
                    }

                    themeDocumentRow
                    themePreview

                    if let themeImportError {
                        Label(themeImportError, systemImage: "exclamationmark.triangle")
                            .riffaText(.caption)
                            .foregroundStyle(theme.danger)
                            .accessibilityElement(children: .combine)
                    }
                }
                .padding(RiffaSpacing.md)
                .overlay(alignment: .top) {
                    RiffaHairline()
                }
            }
        }
    }

    private func themePresetButton(_ preset: RiffaThemePreset) -> some View {
        let isSelected = preset == themePreset && customAccentHex.isEmpty
        let palette = RiffaThemePalette.preset(
            preset,
            colorScheme: theme.colorScheme
        )

        return Button {
            themePreset = preset
            themeImportError = nil
        } label: {
            VStack(alignment: .leading, spacing: RiffaSpacing.xs) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(palette.canvas)
                        .overlay {
                            Circle().strokeBorder(palette.hairlineStrong, lineWidth: 1)
                        }
                    Circle().fill(palette.surface2)
                    Circle().fill(palette.accent)
                }
                .frame(height: 18)
                .accessibilityHidden(true)

                HStack(spacing: RiffaSpacing.xxs) {
                    Text(themePresetTitle(preset))
                        .riffaText(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.accent)
                            .accessibilityHidden(true)
                    }
                }
            }
            .foregroundStyle(theme.ink)
            .padding(RiffaSpacing.xs)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(
                isSelected ? theme.surface(.three) : theme.surface(.two),
                in: RoundedRectangle(cornerRadius: RiffaRadius.md)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RiffaRadius.md)
                    .strokeBorder(
                        isSelected ? theme.accent : theme.hairline,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(themePresetTitle(preset))
        .accessibilityValue(
            Text(
                verbatim: RiffaLocalization.string(
                    isSelected ? "Selected" : "Not selected"
                )
            )
        )
    }

    private var themeDocumentRow: some View {
        HStack(spacing: RiffaSpacing.sm) {
            Image(systemName: "doc.badge.gearshape")
                .foregroundStyle(theme.inkSubtle)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                if themeDocumentID.isEmpty {
                    Text("No Imported Theme")
                        .riffaText(.bodySmall)
                        .foregroundStyle(theme.ink)
                    Text("JSON themes can override separate Light and Dark semantic tokens.")
                        .riffaText(.caption)
                        .foregroundStyle(theme.inkSubtle)
                        .lineLimit(1)
                } else {
                    Text("Imported Theme")
                        .riffaText(.bodySmall)
                        .foregroundStyle(theme.ink)
                    Text(verbatim: themeDocumentFilename)
                        .riffaText(.caption)
                        .foregroundStyle(theme.inkSubtle)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: RiffaSpacing.sm)
            Button("Import Theme…") {
                importThemeDocument()
            }
            .buttonStyle(.riffaSecondary)

            if !themeDocumentID.isEmpty {
                Button("Remove") {
                    removeImportedTheme()
                }
                .buttonStyle(.riffaTertiary)
            }

            Button("Reset Theme") {
                resetTheme()
            }
            .buttonStyle(.riffaTertiary)
        }
    }

    private var themePreview: some View {
        HStack(spacing: RiffaSpacing.md) {
            VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                Text("Live Preview")
                    .riffaText(.bodySmall)
                    .foregroundStyle(theme.ink)
                Text("Surfaces, focus, and semantic colors update immediately.")
                    .riffaText(.caption)
                    .foregroundStyle(theme.inkSubtle)
            }

            Spacer(minLength: RiffaSpacing.sm)
            RiffaStatusBadge("Same", systemImage: "equal.circle", tone: .neutral)
            RiffaStatusBadge("Changed", systemImage: "triangle", tone: .warning)
            Button("Primary Action") {}
                .buttonStyle(.riffaPrimary)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(RiffaSpacing.sm)
        .background(
            theme.surface(.two),
            in: RoundedRectangle(cornerRadius: RiffaRadius.md)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RiffaRadius.md)
                .strokeBorder(theme.hairline, lineWidth: 1)
        }
    }

    private var settingsPanel: some View {
        RiffaPanel(
            level: .one,
            cornerRadius: RiffaRadius.lg,
            padding: 0
        ) {
            VStack(spacing: 0) {
                panelHeading(
                    eyebrow: "ACCESSIBILITY",
                    title: "System accessibility",
                    description: "Riffa follows macOS settings for contrast, motion, transparency, and color.",
                    systemImage: "accessibility"
                )

                preferenceRow(
                    title: "Increase Contrast",
                    description: "Boosts contrast for text and interface elements.",
                    systemImage: "circle.lefthalf.filled"
                )
                preferenceRow(
                    title: "Reduce Transparency",
                    description: "Keeps every workspace surface fully opaque.",
                    systemImage: "circle.dotted"
                )
                preferenceRow(
                    title: "Reduce Motion",
                    description: "Minimizes hover and state-change animations.",
                    systemImage: "figure.walk.motion"
                )
                preferenceRow(
                    title: "Differentiate Without Color",
                    description: "Adds symbols and labels to every comparison state.",
                    systemImage: "paintpalette"
                )
            }
        }
    }

    private var privacyPanel: some View {
        RiffaPanel(
            level: .one,
            cornerRadius: RiffaRadius.lg,
            padding: 0
        ) {
            VStack(spacing: 0) {
                panelHeading(
                    eyebrow: "PRIVACY",
                    title: "Local by default",
                    description: "Riffa does not upload compared files.",
                    systemImage: "lock.shield.fill"
                )

                privacyRow("Compared files stay on this Mac")
                privacyRow("Reports are saved only when requested")
                privacyRow("Remote credentials require explicit Keychain save")
            }
        }
    }

    private func panelHeading(
        eyebrow: String,
        title: String,
        description: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: RiffaSpacing.md) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(
                    systemImage == "lock.shield.fill"
                        ? theme.secure
                        : theme.accentHover
                )
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                Text(LocalizedStringKey(eyebrow))
                    .riffaText(.eyebrow)
                    .foregroundStyle(theme.inkTertiary)
                Text(LocalizedStringKey(title))
                    .riffaText(.body)
                    .foregroundStyle(theme.ink)
                Text(LocalizedStringKey(description))
                    .riffaText(.bodySmall)
                    .foregroundStyle(theme.inkSubtle)
            }
        }
        .padding(RiffaSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func preferenceRow(
        title: String,
        description: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: RiffaSpacing.sm) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(theme.inkMuted)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title))
                    .riffaText(.bodySmall)
                    .foregroundStyle(theme.ink)
                Text(LocalizedStringKey(description))
                    .riffaText(.caption)
                    .foregroundStyle(theme.inkSubtle)
            }

            Spacer(minLength: RiffaSpacing.sm)
            RiffaStatusBadge("Follow System", tone: .neutral)
        }
        .padding(.horizontal, RiffaSpacing.md)
        .frame(minHeight: 64)
        .overlay(alignment: .top) {
            RiffaHairline()
        }
        .accessibilityElement(children: .combine)
    }

    private func privacyRow(_ title: String) -> some View {
        HStack(spacing: RiffaSpacing.sm) {
            Image(systemName: "checkmark.shield")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(theme.secure)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
                .riffaText(.bodySmall)
                .foregroundStyle(theme.inkMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RiffaSpacing.md)
        .frame(minHeight: 56)
        .overlay(alignment: .top) {
            RiffaHairline()
        }
        .accessibilityElement(children: .combine)
    }

    private var customAccentBinding: Binding<Color> {
        Binding(
            get: {
                color(fromHex: customAccentHex) ?? theme.accent
            },
            set: { color in
                customAccentHex = hexString(from: color)
                themeImportError = nil
            }
        )
    }

    private func languageTitle(_ value: RiffaLanguage) -> LocalizedStringKey {
        switch value {
        case .system: "System"
        case .en: "English"
        case .zhHans: "Simplified Chinese"
        }
    }

    private func appearanceTitle(
        _ value: RiffaAppearanceMode
    ) -> LocalizedStringKey {
        switch value {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private func themePresetTitle(
        _ value: RiffaThemePreset
    ) -> LocalizedStringKey {
        switch value {
        case .midnight: "Midnight"
        case .graphite: "Graphite"
        case .ocean: "Ocean"
        case .forest: "Forest"
        }
    }

    private func importThemeDocument() {
        let panel = NSOpenPanel()
        panel.title = RiffaLocalization.string("Import Riffa Theme")
        panel.message = RiffaLocalization.string(
            "Choose a Riffa theme JSON document. It will be validated before use."
        )
        panel.prompt = RiffaLocalization.string("Import")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard byteCount <= RiffaThemeDocument.maximumEncodedSize else {
                throw RiffaThemeDocumentError.documentTooLarge(
                    actualBytes: byteCount,
                    maximumBytes: RiffaThemeDocument.maximumEncodedSize
                )
            }

            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let store = try RiffaThemeDocumentStore()
            let document = try store.importDocument(data)
            if !themeDocumentID.isEmpty, themeDocumentID != document.id {
                _ = try? store.delete(id: themeDocumentID)
            }
            themeDocumentID = document.id
            themeDocumentFilename = document.name
            themeDocumentRevision += 1
            themeImportError = nil
        } catch {
            themeImportError = error.localizedDescription
        }
    }

    private func removeImportedTheme() {
        guard !themeDocumentID.isEmpty else { return }
        do {
            let store = try RiffaThemeDocumentStore()
            _ = try store.delete(id: themeDocumentID)
            themeDocumentID = ""
            themeDocumentFilename = ""
            themeDocumentRevision += 1
            themeImportError = nil
        } catch {
            themeImportError = error.localizedDescription
        }
    }

    private func resetTheme() {
        if !themeDocumentID.isEmpty {
            _ = try? RiffaThemeDocumentStore().delete(id: themeDocumentID)
        }
        appearance = .system
        themePreset = .midnight
        customAccentHex = ""
        themeDocumentID = ""
        themeDocumentFilename = ""
        themeDocumentRevision += 1
        themeImportError = nil
    }

    private func color(fromHex value: String) -> Color? {
        guard value.count == 7,
              value.first == "#",
              let rgb = UInt32(value.dropFirst(), radix: 16)
        else {
            return nil
        }
        return Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }

    private func hexString(from color: Color) -> String {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            return ""
        }
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        return String(
            format: "#%02X%02X%02X",
            locale: Locale(identifier: "en_US_POSIX"),
            red,
            green,
            blue
        )
    }
}
