import AppKit
import Foundation
import SwiftUI

// MARK: - Persisted appearance choices

enum RiffaAppearanceMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let defaultValue: Self = .system

    var id: String { rawValue }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum RiffaLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case en
    case zhHans = "zh-Hans"

    static let defaultValue: Self = .system

    var id: String { rawValue }

    /// `nil` means that SwiftUI should continue using the system locale.
    var locale: Locale? {
        switch self {
        case .system: nil
        case .en: Locale(identifier: "en")
        case .zhHans: Locale(identifier: "zh-Hans")
        }
    }
}

enum RiffaThemePreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case midnight
    case graphite
    case ocean
    case forest

    static let defaultValue: Self = .midnight

    var id: String { rawValue }
}

/// The only place where persistent preference keys should be declared.
///
/// Custom theme JSON is intentionally stored as a file in Application Support;
/// UserDefaults stores only the selected document identity and filename.
enum RiffaUserDefaultsKey {
    static let appearanceMode = "riffa.appearance.mode"
    static let language = "riffa.language"
    static let themePreset = "riffa.theme.preset"
    static let themeCustomAccent = "riffa.theme.customAccent"
    static let themeDocumentID = "riffa.theme.documentID"
    static let themeDocumentFilename = "riffa.theme.documentFilename"
    static let themeDocumentRevision = "riffa.theme.documentRevision"
}

// MARK: - Imported theme document

enum RiffaThemeDocumentError: Error, Equatable, LocalizedError, Sendable {
    case emptyDocument
    case documentTooLarge(actualBytes: Int, maximumBytes: Int)
    case malformedJSON(String)
    case unknownField(String)
    case unsupportedSchemaVersion(Int)
    case invalidIdentifier
    case invalidName
    case missingColorVariants
    case emptyColorVariant(String)
    case invalidHexColor(field: String, value: String)

    var errorDescription: String? {
        return switch self {
        case .emptyDocument:
            RiffaLocalization.string("The theme document is empty.")
        case let .documentTooLarge(actualBytes, maximumBytes):
            String(
                localized: "The theme document is \(actualBytes) bytes; the maximum is \(maximumBytes) bytes.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .malformedJSON(message):
            String(
                localized: "The theme document is not valid JSON: \(message)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .unknownField(field):
            String(
                localized: "The theme document contains an unknown field: \(field).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .unsupportedSchemaVersion(version):
            String(
                localized: "Theme schema version \(version) is not supported.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .invalidIdentifier:
            RiffaLocalization.string(
                "The theme identifier must be 1–64 ASCII letters, numbers, periods, underscores, or hyphens."
            )
        case .invalidName:
            RiffaLocalization.string(
                "The theme name must contain 1–80 visible characters."
            )
        case .missingColorVariants:
            RiffaLocalization.string(
                "The theme must define at least one light or dark color variant."
            )
        case let .emptyColorVariant(variant):
            String(
                localized: "The \(RiffaLocalization.string(variant.capitalized)) color variant does not override any colors.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .invalidHexColor(field, value):
            String(
                localized: "\(field) has an invalid color value “\(value)”. Use #RRGGBB or #RRGGBBAA.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }
}

/// A partial semantic-color override.
///
/// Values use web-style `#RRGGBB` or `#RRGGBBAA` ordering. Missing values
/// inherit from the selected built-in preset. Decoding rejects unknown keys so
/// misspelled tokens cannot silently produce a partly applied theme.
struct RiffaThemePartialPalette: Codable, Equatable, Sendable {
    let canvas: String?
    let surface1: String?
    let surface2: String?
    let surface3: String?
    let surface4: String?

    let ink: String?
    let inkMuted: String?
    let inkSubtle: String?
    let inkTertiary: String?

    let hairline: String?
    let hairlineStrong: String?
    let hairlineTertiary: String?

    let accent: String?
    let accentHover: String?
    let accentFocus: String?
    let onAccent: String?

    let secure: String?
    let success: String?
    let warning: String?
    let danger: String?

    init(
        canvas: String? = nil,
        surface1: String? = nil,
        surface2: String? = nil,
        surface3: String? = nil,
        surface4: String? = nil,
        ink: String? = nil,
        inkMuted: String? = nil,
        inkSubtle: String? = nil,
        inkTertiary: String? = nil,
        hairline: String? = nil,
        hairlineStrong: String? = nil,
        hairlineTertiary: String? = nil,
        accent: String? = nil,
        accentHover: String? = nil,
        accentFocus: String? = nil,
        onAccent: String? = nil,
        secure: String? = nil,
        success: String? = nil,
        warning: String? = nil,
        danger: String? = nil
    ) throws {
        self.canvas = canvas
        self.surface1 = surface1
        self.surface2 = surface2
        self.surface3 = surface3
        self.surface4 = surface4
        self.ink = ink
        self.inkMuted = inkMuted
        self.inkSubtle = inkSubtle
        self.inkTertiary = inkTertiary
        self.hairline = hairline
        self.hairlineStrong = hairlineStrong
        self.hairlineTertiary = hairlineTertiary
        self.accent = accent
        self.accentHover = accentHover
        self.accentFocus = accentFocus
        self.onAccent = onAccent
        self.secure = secure
        self.success = success
        self.warning = warning
        self.danger = danger
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case canvas
        case surface1
        case surface2
        case surface3
        case surface4
        case ink
        case inkMuted
        case inkSubtle
        case inkTertiary
        case hairline
        case hairlineStrong
        case hairlineTertiary
        case accent
        case accentHover
        case accentFocus
        case onAccent
        case secure
        case success
        case warning
        case danger
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(
            from: decoder,
            allowed: Set(CodingKeys.allCases.map(\.stringValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            canvas: container.decodeIfPresent(String.self, forKey: .canvas),
            surface1: container.decodeIfPresent(String.self, forKey: .surface1),
            surface2: container.decodeIfPresent(String.self, forKey: .surface2),
            surface3: container.decodeIfPresent(String.self, forKey: .surface3),
            surface4: container.decodeIfPresent(String.self, forKey: .surface4),
            ink: container.decodeIfPresent(String.self, forKey: .ink),
            inkMuted: container.decodeIfPresent(String.self, forKey: .inkMuted),
            inkSubtle: container.decodeIfPresent(String.self, forKey: .inkSubtle),
            inkTertiary: container.decodeIfPresent(String.self, forKey: .inkTertiary),
            hairline: container.decodeIfPresent(String.self, forKey: .hairline),
            hairlineStrong: container.decodeIfPresent(String.self, forKey: .hairlineStrong),
            hairlineTertiary: container.decodeIfPresent(String.self, forKey: .hairlineTertiary),
            accent: container.decodeIfPresent(String.self, forKey: .accent),
            accentHover: container.decodeIfPresent(String.self, forKey: .accentHover),
            accentFocus: container.decodeIfPresent(String.self, forKey: .accentFocus),
            onAccent: container.decodeIfPresent(String.self, forKey: .onAccent),
            secure: container.decodeIfPresent(String.self, forKey: .secure),
            success: container.decodeIfPresent(String.self, forKey: .success),
            warning: container.decodeIfPresent(String.self, forKey: .warning),
            danger: container.decodeIfPresent(String.self, forKey: .danger)
        )
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(canvas, forKey: .canvas)
        try container.encodeIfPresent(surface1, forKey: .surface1)
        try container.encodeIfPresent(surface2, forKey: .surface2)
        try container.encodeIfPresent(surface3, forKey: .surface3)
        try container.encodeIfPresent(surface4, forKey: .surface4)
        try container.encodeIfPresent(ink, forKey: .ink)
        try container.encodeIfPresent(inkMuted, forKey: .inkMuted)
        try container.encodeIfPresent(inkSubtle, forKey: .inkSubtle)
        try container.encodeIfPresent(inkTertiary, forKey: .inkTertiary)
        try container.encodeIfPresent(hairline, forKey: .hairline)
        try container.encodeIfPresent(hairlineStrong, forKey: .hairlineStrong)
        try container.encodeIfPresent(hairlineTertiary, forKey: .hairlineTertiary)
        try container.encodeIfPresent(accent, forKey: .accent)
        try container.encodeIfPresent(accentHover, forKey: .accentHover)
        try container.encodeIfPresent(accentFocus, forKey: .accentFocus)
        try container.encodeIfPresent(onAccent, forKey: .onAccent)
        try container.encodeIfPresent(secure, forKey: .secure)
        try container.encodeIfPresent(success, forKey: .success)
        try container.encodeIfPresent(warning, forKey: .warning)
        try container.encodeIfPresent(danger, forKey: .danger)
    }

    var isEmpty: Bool {
        colorFields.allSatisfy { $0.value == nil }
    }

    fileprivate func validate() throws {
        for field in colorFields {
            guard let value = field.value else { continue }
            _ = try RiffaRGBA(hex: value, field: field.name)
        }
    }

    private var colorFields: [(name: String, value: String?)] {
        [
            ("canvas", canvas),
            ("surface1", surface1),
            ("surface2", surface2),
            ("surface3", surface3),
            ("surface4", surface4),
            ("ink", ink),
            ("inkMuted", inkMuted),
            ("inkSubtle", inkSubtle),
            ("inkTertiary", inkTertiary),
            ("hairline", hairline),
            ("hairlineStrong", hairlineStrong),
            ("hairlineTertiary", hairlineTertiary),
            ("accent", accent),
            ("accentHover", accentHover),
            ("accentFocus", accentFocus),
            ("onAccent", onAccent),
            ("secure", secure),
            ("success", success),
            ("warning", warning),
            ("danger", danger),
        ]
    }
}

/// Versioned, importable Riffa theme file.
///
/// Use ``decode(_:)`` rather than calling `JSONDecoder` directly so the 64 KiB
/// resource limit is enforced before parsing.
struct RiffaThemeDocument: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1
    static let maximumEncodedSize = 64 * 1024

    let schemaVersion: Int
    let id: String
    let name: String
    let light: RiffaThemePartialPalette?
    let dark: RiffaThemePartialPalette?

    init(
        schemaVersion: Int = supportedSchemaVersion,
        id: String,
        name: String,
        light: RiffaThemePartialPalette? = nil,
        dark: RiffaThemePartialPalette? = nil
    ) throws {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case id
        case name
        case light
        case dark
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(
            from: decoder,
            allowed: Set(CodingKeys.allCases.map(\.stringValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            id: container.decode(String.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            light: container.decodeIfPresent(RiffaThemePartialPalette.self, forKey: .light),
            dark: container.decodeIfPresent(RiffaThemePartialPalette.self, forKey: .dark)
        )
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(light, forKey: .light)
        try container.encodeIfPresent(dark, forKey: .dark)
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty else {
            throw RiffaThemeDocumentError.emptyDocument
        }
        guard data.count <= maximumEncodedSize else {
            throw RiffaThemeDocumentError.documentTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumEncodedSize
            )
        }

        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch let error as RiffaThemeDocumentError {
            throw error
        } catch {
            throw RiffaThemeDocumentError.malformedJSON(error.localizedDescription)
        }
    }

    func encoded(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }

        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedSize else {
            throw RiffaThemeDocumentError.documentTooLarge(
                actualBytes: data.count,
                maximumBytes: Self.maximumEncodedSize
            )
        }
        return data
    }

    func colors(for colorScheme: ColorScheme) -> RiffaThemePartialPalette? {
        switch colorScheme {
        case .light: light
        case .dark: dark
        @unknown default: dark
        }
    }

    private func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw RiffaThemeDocumentError.unsupportedSchemaVersion(schemaVersion)
        }

        guard Self.isValidIdentifier(id) else {
            throw RiffaThemeDocumentError.invalidIdentifier
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let containsControlCharacter = trimmedName.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
        guard !trimmedName.isEmpty,
              trimmedName.count <= 80,
              !containsControlCharacter
        else {
            throw RiffaThemeDocumentError.invalidName
        }

        guard light != nil || dark != nil else {
            throw RiffaThemeDocumentError.missingColorVariants
        }
        if let light, light.isEmpty {
            throw RiffaThemeDocumentError.emptyColorVariant("light")
        }
        if let dark, dark.isEmpty {
            throw RiffaThemeDocumentError.emptyColorVariant("dark")
        }
    }

    fileprivate static func isValidIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,63})$"#,
            options: .regularExpression
        ) != nil
    }
}

// MARK: - Imported theme storage

enum RiffaThemeDocumentStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsafePath
    case symbolicLinkNotAllowed

    var errorDescription: String? {
        return switch self {
        case .unsafePath:
            RiffaLocalization.string(
                "The theme document path is outside Riffa’s theme directory."
            )
        case .symbolicLinkNotAllowed:
            RiffaLocalization.string(
                "Symbolic links are not allowed in Riffa’s theme directory."
            )
        }
    }
}

/// Stores validated theme documents inside the app container.
///
/// On a sandboxed macOS build this resolves to:
/// `Application Support/Riffa/Themes/<document-id>.json`.
struct RiffaThemeDocumentStore: Sendable {
    let directoryURL: URL

    init(fileManager: FileManager = .default) throws {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try self.init(
            directoryURL: applicationSupport
                .appendingPathComponent("Riffa", isDirectory: true)
                .appendingPathComponent("Themes", isDirectory: true),
            fileManager: fileManager
        )
    }

    /// Injectable root for tests and previews.
    init(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let root = directoryURL.standardizedFileURL
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw RiffaThemeDocumentStoreError.symbolicLinkNotAllowed
        }
        self.directoryURL = root
    }

    /// Validates before writing and stores canonical, sorted JSON atomically.
    @discardableResult
    func importDocument(
        _ data: Data,
        fileManager: FileManager = .default
    ) throws -> RiffaThemeDocument {
        let document = try RiffaThemeDocument.decode(data)
        let destination = try documentURL(for: document.id)
        try rejectSymbolicLinkIfPresent(at: destination, fileManager: fileManager)
        try document.encoded().write(to: destination, options: .atomic)
        return document
    }

    func load(
        id: String,
        fileManager: FileManager = .default
    ) throws -> RiffaThemeDocument? {
        let source = try documentURL(for: id)
        guard fileManager.fileExists(atPath: source.path) else {
            return nil
        }
        try rejectSymbolicLinkIfPresent(at: source, fileManager: fileManager)
        return try RiffaThemeDocument.decode(Data(contentsOf: source))
    }

    /// Returns `true` only when an existing regular theme file was deleted.
    @discardableResult
    func delete(
        id: String,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let target = try documentURL(for: id)
        guard fileManager.fileExists(atPath: target.path) else {
            return false
        }
        try rejectSymbolicLinkIfPresent(at: target, fileManager: fileManager)
        try fileManager.removeItem(at: target)
        return true
    }

    func documentURL(for id: String) throws -> URL {
        guard RiffaThemeDocument.isValidIdentifier(id) else {
            throw RiffaThemeDocumentError.invalidIdentifier
        }

        let root = directoryURL.standardizedFileURL
        let candidate = root
            .appendingPathComponent(id, isDirectory: false)
            .appendingPathExtension("json")
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == root else {
            throw RiffaThemeDocumentStoreError.unsafePath
        }
        return candidate
    }

    private func rejectSymbolicLinkIfPresent(
        at url: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw RiffaThemeDocumentStoreError.symbolicLinkNotAllowed
        }
    }
}

// MARK: - Resolved palette

/// A complete, immutable palette ready to install in SwiftUI's environment.
struct RiffaThemePalette: Equatable, Sendable {
    let canvas: Color
    let surface1: Color
    let surface2: Color
    let surface3: Color
    let surface4: Color

    let ink: Color
    let inkMuted: Color
    let inkSubtle: Color
    let inkTertiary: Color

    let hairline: Color
    let hairlineStrong: Color
    let hairlineTertiary: Color

    let accent: Color
    let accentHover: Color
    let accentFocus: Color
    let onAccent: Color

    let secure: Color
    let success: Color
    let warning: Color
    let danger: Color

    var nsCanvas: NSColor { NSColor(canvas) }
    var nsSurface1: NSColor { NSColor(surface1) }
    var nsInk: NSColor { NSColor(ink) }

    static func preset(
        _ preset: RiffaThemePreset,
        colorScheme: ColorScheme
    ) -> Self {
        RiffaRawPalette.preset(preset, colorScheme: colorScheme).resolved
    }

    /// Resolves a palette using this precedence:
    ///
    /// built-in preset → matching imported variant → custom accent.
    ///
    /// A custom accent also derives hover, focus, and readable foreground
    /// colors so a single preference cannot leave the primary button states
    /// visually inconsistent.
    static func resolve(
        preset: RiffaThemePreset,
        colorScheme: ColorScheme,
        customAccentHex: String? = nil,
        themeDocument: RiffaThemeDocument? = nil
    ) throws -> Self {
        var raw = RiffaRawPalette.preset(preset, colorScheme: colorScheme)
        if let partial = themeDocument?.colors(for: colorScheme) {
            try raw.apply(partial, colorScheme: colorScheme)
        }
        if let customAccentHex {
            try raw.applyCustomAccent(customAccentHex, colorScheme: colorScheme)
        }
        return raw.resolved
    }

    /// Convenience entry point for untrusted imported JSON. The document size
    /// and schema are validated before any color is applied.
    static func resolve(
        preset: RiffaThemePreset,
        colorScheme: ColorScheme,
        customAccentHex: String? = nil,
        themeDocumentData: Data?
    ) throws -> Self {
        let document = try themeDocumentData.map(RiffaThemeDocument.decode)
        return try resolve(
            preset: preset,
            colorScheme: colorScheme,
            customAccentHex: customAccentHex,
            themeDocument: document
        )
    }

    static func validateAccentHex(_ value: String) throws {
        _ = try RiffaRGBA(hex: value, field: "customAccent")
    }
}

// MARK: - Private color machinery

private struct RiffaRGBA: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(rgb: UInt32, alpha: Double = 1) {
        red = Double((rgb >> 16) & 0xFF) / 255
        green = Double((rgb >> 8) & 0xFF) / 255
        blue = Double(rgb & 0xFF) / 255
        self.alpha = alpha
    }

    init(hex: String, field: String) throws {
        let scalars = Array(hex.unicodeScalars)
        guard scalars.count == 7 || scalars.count == 9,
              scalars.first?.value == 0x23,
              scalars.dropFirst().allSatisfy(Self.isASCIIHexDigit)
        else {
            throw RiffaThemeDocumentError.invalidHexColor(field: field, value: hex)
        }

        let digits = String(hex.dropFirst())
        guard let value = UInt32(digits, radix: 16) else {
            throw RiffaThemeDocumentError.invalidHexColor(field: field, value: hex)
        }

        if scalars.count == 7 {
            self.init(rgb: value)
        } else {
            self.init(
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                alpha: Double(value & 0xFF) / 255
            )
        }
    }

    var color: Color {
        Color(
            .sRGB,
            red: red,
            green: green,
            blue: blue,
            opacity: alpha
        )
    }

    func mixed(with other: Self, amount: Double) -> Self {
        let fraction = min(max(amount, 0), 1)
        return Self(
            red: red + (other.red - red) * fraction,
            green: green + (other.green - green) * fraction,
            blue: blue + (other.blue - blue) * fraction,
            alpha: alpha + (other.alpha - alpha) * fraction
        )
    }

    func hoverColor(for colorScheme: ColorScheme) -> Self {
        switch colorScheme {
        case .light: mixed(with: .black, amount: 0.14)
        case .dark: mixed(with: .white, amount: 0.22)
        @unknown default: mixed(with: .white, amount: 0.22)
        }
    }

    func focusColor(for colorScheme: ColorScheme) -> Self {
        switch colorScheme {
        case .light: mixed(with: .black, amount: 0.06)
        case .dark: mixed(with: .white, amount: 0.08)
        @unknown default: mixed(with: .white, amount: 0.08)
        }
    }

    var readableForeground: Self {
        let whiteContrast = Self.contrastRatio(relativeLuminance, Self.white.relativeLuminance)
        let blackContrast = Self.contrastRatio(relativeLuminance, Self.black.relativeLuminance)
        return whiteContrast >= blackContrast ? .white : .black
    }

    private init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    private var relativeLuminance: Double {
        func linearize(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearize(red)
            + 0.7152 * linearize(green)
            + 0.0722 * linearize(blue)
    }

    private static func contrastRatio(_ lhs: Double, _ rhs: Double) -> Double {
        let lighter = max(lhs, rhs)
        let darker = min(lhs, rhs)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func isASCIIHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66: true
        default: false
        }
    }

    static let black = Self(rgb: 0x000000)
    static let white = Self(rgb: 0xFFFFFF)
}

private struct RiffaRawPalette: Sendable {
    var canvas: RiffaRGBA
    var surface1: RiffaRGBA
    var surface2: RiffaRGBA
    var surface3: RiffaRGBA
    var surface4: RiffaRGBA

    var ink: RiffaRGBA
    var inkMuted: RiffaRGBA
    var inkSubtle: RiffaRGBA
    var inkTertiary: RiffaRGBA

    var hairline: RiffaRGBA
    var hairlineStrong: RiffaRGBA
    var hairlineTertiary: RiffaRGBA

    var accent: RiffaRGBA
    var accentHover: RiffaRGBA
    var accentFocus: RiffaRGBA
    var onAccent: RiffaRGBA

    var secure: RiffaRGBA
    var success: RiffaRGBA
    var warning: RiffaRGBA
    var danger: RiffaRGBA

    var resolved: RiffaThemePalette {
        RiffaThemePalette(
            canvas: canvas.color,
            surface1: surface1.color,
            surface2: surface2.color,
            surface3: surface3.color,
            surface4: surface4.color,
            ink: ink.color,
            inkMuted: inkMuted.color,
            inkSubtle: inkSubtle.color,
            inkTertiary: inkTertiary.color,
            hairline: hairline.color,
            hairlineStrong: hairlineStrong.color,
            hairlineTertiary: hairlineTertiary.color,
            accent: accent.color,
            accentHover: accentHover.color,
            accentFocus: accentFocus.color,
            onAccent: onAccent.color,
            secure: secure.color,
            success: success.color,
            warning: warning.color,
            danger: danger.color
        )
    }

    static func preset(
        _ preset: RiffaThemePreset,
        colorScheme: ColorScheme
    ) -> Self {
        let isLight: Bool
        switch colorScheme {
        case .light: isLight = true
        case .dark: isLight = false
        @unknown default: isLight = false
        }

        return switch (preset, isLight) {
        case (.midnight, false):
            midnightDark
        case (.midnight, true):
            midnightLight
        case (.graphite, false):
            graphiteDark
        case (.graphite, true):
            graphiteLight
        case (.ocean, false):
            oceanDark
        case (.ocean, true):
            oceanLight
        case (.forest, false):
            forestDark
        case (.forest, true):
            forestLight
        }
    }

    mutating func apply(
        _ partial: RiffaThemePartialPalette,
        colorScheme: ColorScheme
    ) throws {
        try partial.validate()

        // If only the main accent is supplied, keep all dependent interaction
        // colors coherent. Explicit imported values below still take priority.
        if let value = partial.accent {
            let importedAccent = try RiffaRGBA(hex: value, field: "accent")
            accent = importedAccent
            accentHover = importedAccent.hoverColor(for: colorScheme)
            accentFocus = importedAccent.focusColor(for: colorScheme)
            onAccent = importedAccent.readableForeground
        }

        try set(partial.canvas, at: \.canvas, field: "canvas")
        try set(partial.surface1, at: \.surface1, field: "surface1")
        try set(partial.surface2, at: \.surface2, field: "surface2")
        try set(partial.surface3, at: \.surface3, field: "surface3")
        try set(partial.surface4, at: \.surface4, field: "surface4")
        try set(partial.ink, at: \.ink, field: "ink")
        try set(partial.inkMuted, at: \.inkMuted, field: "inkMuted")
        try set(partial.inkSubtle, at: \.inkSubtle, field: "inkSubtle")
        try set(partial.inkTertiary, at: \.inkTertiary, field: "inkTertiary")
        try set(partial.hairline, at: \.hairline, field: "hairline")
        try set(partial.hairlineStrong, at: \.hairlineStrong, field: "hairlineStrong")
        try set(partial.hairlineTertiary, at: \.hairlineTertiary, field: "hairlineTertiary")
        try set(partial.accentHover, at: \.accentHover, field: "accentHover")
        try set(partial.accentFocus, at: \.accentFocus, field: "accentFocus")
        try set(partial.onAccent, at: \.onAccent, field: "onAccent")
        try set(partial.secure, at: \.secure, field: "secure")
        try set(partial.success, at: \.success, field: "success")
        try set(partial.warning, at: \.warning, field: "warning")
        try set(partial.danger, at: \.danger, field: "danger")
    }

    mutating func applyCustomAccent(
        _ hex: String,
        colorScheme: ColorScheme
    ) throws {
        let custom = try RiffaRGBA(hex: hex, field: "customAccent")
        accent = custom
        accentHover = custom.hoverColor(for: colorScheme)
        accentFocus = custom.focusColor(for: colorScheme)
        onAccent = custom.readableForeground
    }

    private mutating func set(
        _ value: String?,
        at keyPath: WritableKeyPath<Self, RiffaRGBA>,
        field: String
    ) throws {
        guard let value else { return }
        self[keyPath: keyPath] = try RiffaRGBA(hex: value, field: field)
    }

    private func replacing(
        canvas: RiffaRGBA? = nil,
        surface1: RiffaRGBA? = nil,
        surface2: RiffaRGBA? = nil,
        surface3: RiffaRGBA? = nil,
        surface4: RiffaRGBA? = nil,
        ink: RiffaRGBA? = nil,
        inkMuted: RiffaRGBA? = nil,
        inkSubtle: RiffaRGBA? = nil,
        inkTertiary: RiffaRGBA? = nil,
        hairline: RiffaRGBA? = nil,
        hairlineStrong: RiffaRGBA? = nil,
        hairlineTertiary: RiffaRGBA? = nil,
        accent: RiffaRGBA? = nil,
        accentHover: RiffaRGBA? = nil,
        accentFocus: RiffaRGBA? = nil,
        onAccent: RiffaRGBA? = nil,
        secure: RiffaRGBA? = nil,
        success: RiffaRGBA? = nil,
        warning: RiffaRGBA? = nil,
        danger: RiffaRGBA? = nil
    ) -> Self {
        Self(
            canvas: canvas ?? self.canvas,
            surface1: surface1 ?? self.surface1,
            surface2: surface2 ?? self.surface2,
            surface3: surface3 ?? self.surface3,
            surface4: surface4 ?? self.surface4,
            ink: ink ?? self.ink,
            inkMuted: inkMuted ?? self.inkMuted,
            inkSubtle: inkSubtle ?? self.inkSubtle,
            inkTertiary: inkTertiary ?? self.inkTertiary,
            hairline: hairline ?? self.hairline,
            hairlineStrong: hairlineStrong ?? self.hairlineStrong,
            hairlineTertiary: hairlineTertiary ?? self.hairlineTertiary,
            accent: accent ?? self.accent,
            accentHover: accentHover ?? self.accentHover,
            accentFocus: accentFocus ?? self.accentFocus,
            onAccent: onAccent ?? self.onAccent,
            secure: secure ?? self.secure,
            success: success ?? self.success,
            warning: warning ?? self.warning,
            danger: danger ?? self.danger
        )
    }

    // These values exactly mirror the dark palette in DESIGN.md and the
    // pre-customization RiffaPalette implementation.
    private static let midnightDark = Self(
        canvas: .init(rgb: 0x010102),
        surface1: .init(rgb: 0x0F1011),
        surface2: .init(rgb: 0x141516),
        surface3: .init(rgb: 0x18191A),
        surface4: .init(rgb: 0x191A1B),
        ink: .init(rgb: 0xF7F8F8),
        inkMuted: .init(rgb: 0xD0D6E0),
        inkSubtle: .init(rgb: 0x8A8F98),
        inkTertiary: .init(rgb: 0x62666D),
        hairline: .init(rgb: 0x23252A),
        hairlineStrong: .init(rgb: 0x34343A),
        hairlineTertiary: .init(rgb: 0x3E3E44),
        accent: .init(rgb: 0x5E6AD2),
        accentHover: .init(rgb: 0x828FFF),
        accentFocus: .init(rgb: 0x5E69D1),
        onAccent: .init(rgb: 0xFFFFFF),
        secure: .init(rgb: 0x7A7FAD),
        success: .init(rgb: 0x27A644),
        warning: .init(rgb: 0xD29922),
        danger: .init(rgb: 0xF85149)
    )

    // Quiet neutral surfaces retain Riffa's dense hierarchy without turning
    // the light appearance into a bright, high-chroma dashboard.
    private static let midnightLight = Self(
        canvas: .init(rgb: 0xF6F7F9),
        surface1: .init(rgb: 0xFFFFFF),
        surface2: .init(rgb: 0xF0F2F5),
        surface3: .init(rgb: 0xE9ECF0),
        surface4: .init(rgb: 0xE2E6EB),
        ink: .init(rgb: 0x17191C),
        inkMuted: .init(rgb: 0x373B42),
        inkSubtle: .init(rgb: 0x656B75),
        inkTertiary: .init(rgb: 0x858C97),
        hairline: .init(rgb: 0xD9DDE3),
        hairlineStrong: .init(rgb: 0xC2C8D0),
        hairlineTertiary: .init(rgb: 0xABB3BE),
        accent: .init(rgb: 0x4F5CC7),
        accentHover: .init(rgb: 0x3F4DB7),
        accentFocus: .init(rgb: 0x5866D2),
        onAccent: .init(rgb: 0xFFFFFF),
        secure: .init(rgb: 0x61699A),
        success: .init(rgb: 0x238636),
        warning: .init(rgb: 0x9A6700),
        danger: .init(rgb: 0xCF222E)
    )

    private static let graphiteDark = midnightDark.replacing(
        canvas: .init(rgb: 0x0B0C0E),
        surface1: .init(rgb: 0x121417),
        surface2: .init(rgb: 0x181B1F),
        surface3: .init(rgb: 0x1E2227),
        surface4: .init(rgb: 0x24282E),
        inkMuted: .init(rgb: 0xC7CDD6),
        inkSubtle: .init(rgb: 0x9198A3),
        inkTertiary: .init(rgb: 0x6C737E),
        hairline: .init(rgb: 0x2C3036),
        hairlineStrong: .init(rgb: 0x3B4149),
        hairlineTertiary: .init(rgb: 0x4A515B),
        accent: .init(rgb: 0x9099A8),
        accentHover: .init(rgb: 0xADB5C1),
        accentFocus: .init(rgb: 0x9AA4B3),
        onAccent: .init(rgb: 0x101114),
        secure: .init(rgb: 0x8792A8)
    )

    private static let graphiteLight = midnightLight.replacing(
        canvas: .init(rgb: 0xF4F5F6),
        surface2: .init(rgb: 0xECEEF0),
        surface3: .init(rgb: 0xE5E7EA),
        surface4: .init(rgb: 0xDDE0E4),
        accent: .init(rgb: 0x596273),
        accentHover: .init(rgb: 0x485161),
        accentFocus: .init(rgb: 0x647083),
        secure: .init(rgb: 0x667086)
    )

    private static let oceanDark = midnightDark.replacing(
        canvas: .init(rgb: 0x020B12),
        surface1: .init(rgb: 0x07131D),
        surface2: .init(rgb: 0x0B1924),
        surface3: .init(rgb: 0x10202B),
        surface4: .init(rgb: 0x142530),
        inkMuted: .init(rgb: 0xC8D9E4),
        inkSubtle: .init(rgb: 0x8499A7),
        inkTertiary: .init(rgb: 0x5E7482),
        hairline: .init(rgb: 0x1F3441),
        hairlineStrong: .init(rgb: 0x2D4858),
        hairlineTertiary: .init(rgb: 0x3C5B6D),
        accent: .init(rgb: 0x229ED9),
        accentHover: .init(rgb: 0x56BFF0),
        accentFocus: .init(rgb: 0x2BA8E2),
        onAccent: .init(rgb: 0x001018),
        secure: .init(rgb: 0x6697B6),
        success: .init(rgb: 0x35A866)
    )

    private static let oceanLight = midnightLight.replacing(
        canvas: .init(rgb: 0xF3F8FA),
        surface2: .init(rgb: 0xEAF2F5),
        surface3: .init(rgb: 0xE1EBEF),
        surface4: .init(rgb: 0xD8E5EA),
        hairline: .init(rgb: 0xCDDCE2),
        hairlineStrong: .init(rgb: 0xB8CDD5),
        hairlineTertiary: .init(rgb: 0xA4BEC8),
        accent: .init(rgb: 0x087EA4),
        accentHover: .init(rgb: 0x066B8D),
        accentFocus: .init(rgb: 0x0A8CB5),
        secure: .init(rgb: 0x4F718B)
    )

    private static let forestDark = midnightDark.replacing(
        canvas: .init(rgb: 0x050B08),
        surface1: .init(rgb: 0x0B1410),
        surface2: .init(rgb: 0x101B16),
        surface3: .init(rgb: 0x15221B),
        surface4: .init(rgb: 0x19271F),
        inkMuted: .init(rgb: 0xCADACF),
        inkSubtle: .init(rgb: 0x87998E),
        inkTertiary: .init(rgb: 0x607469),
        hairline: .init(rgb: 0x22372B),
        hairlineStrong: .init(rgb: 0x314B3B),
        hairlineTertiary: .init(rgb: 0x41604C),
        accent: .init(rgb: 0x4EAD72),
        accentHover: .init(rgb: 0x74C58F),
        accentFocus: .init(rgb: 0x55B779),
        onAccent: .init(rgb: 0x041008),
        secure: .init(rgb: 0x6E987F),
        success: .init(rgb: 0x36A269)
    )

    private static let forestLight = midnightLight.replacing(
        canvas: .init(rgb: 0xF4F8F5),
        surface2: .init(rgb: 0xEAF2EC),
        surface3: .init(rgb: 0xE1EBE4),
        surface4: .init(rgb: 0xD8E5DC),
        hairline: .init(rgb: 0xCEDCD2),
        hairlineStrong: .init(rgb: 0xB9CEBF),
        hairlineTertiary: .init(rgb: 0xA5BFAC),
        accent: .init(rgb: 0x267A4A),
        accentHover: .init(rgb: 0x1E683E),
        accentFocus: .init(rgb: 0x2D8754),
        secure: .init(rgb: 0x587A65)
    )
}

private struct RiffaArbitraryCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys(
    from decoder: any Decoder,
    allowed: Set<String>
) throws {
    let container = try decoder.container(keyedBy: RiffaArbitraryCodingKey.self)
    guard let unknown = container.allKeys
        .map(\.stringValue)
        .sorted()
        .first(where: { !allowed.contains($0) })
    else {
        return
    }

    let prefix = decoder.codingPath.map(\.stringValue).joined(separator: ".")
    let field = prefix.isEmpty ? unknown : "\(prefix).\(unknown)"
    throw RiffaThemeDocumentError.unknownField(field)
}
