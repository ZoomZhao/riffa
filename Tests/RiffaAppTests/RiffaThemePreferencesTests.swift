import AppKit
import Foundation
import SwiftUI
import Testing
@testable import RiffaApp

@Suite("Riffa appearance preferences")
struct RiffaThemePreferencesTests {
    @Test("Built-in palettes resolve distinct light and dark surfaces")
    func builtInLightAndDarkPalettesDiffer() throws {
        let light = RiffaThemePalette.preset(.midnight, colorScheme: .light)
        let dark = RiffaThemePalette.preset(.midnight, colorScheme: .dark)

        #expect(light.nsCanvas != dark.nsCanvas)
        #expect(light.nsInk != dark.nsInk)
        let lightCanvas = try #require(light.nsCanvas.usingColorSpace(.sRGB))
        let darkCanvas = try #require(dark.nsCanvas.usingColorSpace(.sRGB))
        #expect(abs(lightCanvas.redComponent - 0xF6 / 255) < 0.000_01)
        #expect(abs(lightCanvas.greenComponent - 0xF7 / 255) < 0.000_01)
        #expect(abs(lightCanvas.blueComponent - 0xF9 / 255) < 0.000_01)
        #expect(abs(darkCanvas.redComponent - 0x01 / 255) < 0.000_01)
        #expect(abs(darkCanvas.greenComponent - 0x01 / 255) < 0.000_01)
        #expect(abs(darkCanvas.blueComponent - 0x02 / 255) < 0.000_01)
    }

    @Test("Theme documents reject unknown fields and invalid colors")
    func strictThemeDocumentValidation() {
        let unknownField = Data(
            ##"{"schemaVersion":1,"id":"test","name":"Test","dark":{"accent":"#5E6AD2","typo":"#FFFFFF"}}"##.utf8
        )
        let invalidColor = Data(
            ##"{"schemaVersion":1,"id":"test","name":"Test","dark":{"accent":"lavender"}}"##.utf8
        )

        #expect(throws: RiffaThemeDocumentError.self) {
            _ = try RiffaThemeDocument.decode(unknownField)
        }
        #expect(throws: RiffaThemeDocumentError.self) {
            _ = try RiffaThemeDocument.decode(invalidColor)
        }
    }

    @Test("Theme documents are bounded before JSON decoding")
    func themeDocumentSizeLimit() {
        let oversized = Data(
            repeating: 0x20,
            count: RiffaThemeDocument.maximumEncodedSize + 1
        )

        #expect(throws: RiffaThemeDocumentError.self) {
            _ = try RiffaThemeDocument.decode(oversized)
        }
    }

    @Test("Validated themes import, reload, and delete atomically")
    func themeDocumentStoreRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = try RiffaThemePartialPalette(accent: "#3366CC")
        let document = try RiffaThemeDocument(
            id: "test-theme",
            name: "Test Theme",
            dark: partial
        )
        let store = try RiffaThemeDocumentStore(directoryURL: root)

        let imported = try store.importDocument(document.encoded())
        #expect(imported == document)
        #expect(try store.load(id: document.id) == document)
        #expect(try store.delete(id: document.id))
        #expect(try store.load(id: document.id) == nil)
    }

    @Test("Custom accents override a preset without changing semantic colors")
    func customAccentKeepsSemanticColors() throws {
        let baseline = RiffaThemePalette.preset(.ocean, colorScheme: .dark)
        let customized = try RiffaThemePalette.resolve(
            preset: .ocean,
            colorScheme: .dark,
            customAccentHex: "#FFD400"
        )

        #expect(customized.accent != baseline.accent)
        #expect(customized.success == baseline.success)
        #expect(customized.warning == baseline.warning)
        #expect(customized.danger == baseline.danger)
    }

    @Test("Language and appearance choices expose their intended environments")
    func languageAndAppearanceEnvironmentValues() {
        #expect(RiffaLanguage.system.locale == nil)
        #expect(RiffaLanguage.en.locale?.identifier == "en")
        #expect(RiffaLanguage.zhHans.locale?.identifier == "zh-Hans")
        #expect(RiffaAppearanceMode.system.preferredColorScheme == nil)
        #expect(RiffaAppearanceMode.light.preferredColorScheme == .light)
        #expect(RiffaAppearanceMode.dark.preferredColorScheme == .dark)
    }

    @Test("A missing imported variant falls back to the selected preset")
    func missingImportedVariantFallsBack() throws {
        let document = try RiffaThemeDocument(
            id: "dark-only",
            name: "Dark Only",
            dark: RiffaThemePartialPalette(accent: "#FFCC00")
        )
        let lightBaseline = RiffaThemePalette.preset(
            .graphite,
            colorScheme: .light
        )
        let lightResolved = try RiffaThemePalette.resolve(
            preset: .graphite,
            colorScheme: .light,
            themeDocument: document
        )
        let darkBaseline = RiffaThemePalette.preset(
            .graphite,
            colorScheme: .dark
        )
        let darkResolved = try RiffaThemePalette.resolve(
            preset: .graphite,
            colorScheme: .dark,
            themeDocument: document
        )

        #expect(lightResolved == lightBaseline)
        #expect(darkResolved.accent != darkBaseline.accent)
    }

    @Test("Theme storage refuses a symbolic-link destination")
    func themeStoreRejectsSymbolicLinkDestination() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }

        let store = try RiffaThemeDocumentStore(directoryURL: root)
        try Data("outside".utf8).write(to: outside)
        let destination = try store.documentURL(for: "linked-theme")
        try fileManager.createSymbolicLink(
            at: destination,
            withDestinationURL: outside
        )
        let document = try RiffaThemeDocument(
            id: "linked-theme",
            name: "Linked Theme",
            dark: RiffaThemePartialPalette(accent: "#3366CC")
        )

        #expect(throws: RiffaThemeDocumentStoreError.self) {
            _ = try store.importDocument(document.encoded())
        }
    }
}
