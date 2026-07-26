import Foundation
import Testing
@testable import RiffaApp

@Suite("Riffa runtime localization")
struct RiffaLocalizationTests {
    @Test("Session kinds retain SwiftUI keys and resolve concrete text explicitly")
    func sessionKindLocalizationSurfaces() throws {
        let fixture = try makeLocalizationBundle()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        #expect(
            Set(SessionKind.allCases.map(\.titleLocalizationKey)).count
                == SessionKind.allCases.count
        )
        #expect(SessionKind.folderCompare.titleLocalizationKey == "Folder Compare")
        #expect(
            SessionKind.folderCompare.subtitleLocalizationKey
                == "Inspect two directory trees"
        )

        _ = SessionKind.folderCompare.titleKey
        _ = SessionKind.folderCompare.subtitleKey

        #expect(
            SessionKind.folderCompare.localizedTitle(
                language: .en,
                bundle: fixture.bundle
            ) == "Folder Compare"
        )
        #expect(
            SessionKind.folderCompare.localizedTitle(
                language: .zhHans,
                bundle: fixture.bundle
            ) == "文件夹比较"
        )
        #expect(
            SessionKind.folderCompare.localizedSubtitle(
                language: .zhHans,
                bundle: fixture.bundle
            ) == "检查两个目录树"
        )
    }

    @Test("Explicit languages select their own locale and bundle localization")
    func explicitLanguageResolution() throws {
        let fixture = try makeLocalizationBundle()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        #expect(RiffaLocalization.locale(for: .en).identifier == "en")
        #expect(RiffaLocalization.locale(for: .zhHans).identifier == "zh-Hans")
        #expect(
            RiffaLocalization.string(
                "Session",
                language: .en,
                bundle: fixture.bundle
            ) == "Session"
        )
        #expect(
            RiffaLocalization.string(
                "Session",
                language: .zhHans,
                bundle: fixture.bundle
            ) == "会话"
        )
        let chineseBundle = RiffaLocalization.bundle(
            for: .zhHans,
            in: fixture.bundle
        )
        #expect(
            String(
                localized: "Session",
                bundle: chineseBundle,
                locale: RiffaLocalization.locale(for: .zhHans)
            ) == "会话"
        )
    }

    private func makeLocalizationBundle() throws -> (
        bundle: Bundle,
        url: URL
    ) {
        let fileManager = FileManager.default
        let bundleURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathExtension("bundle")
        let contentsURL = bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let resourcesURL = contentsURL.appendingPathComponent(
            "Resources",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )

        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleIdentifier": "dev.riffa.tests.\(UUID().uuidString)",
            "CFBundleLocalizations": ["en", "zh-Hans"],
            "CFBundleName": "RiffaLocalizationFixture"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        try writeStrings(
            """
            "Folder Compare" = "Folder Compare";
            "Inspect two directory trees" = "Inspect two directory trees";
            "Session" = "Session";
            """,
            locale: "en",
            resourcesURL: resourcesURL
        )
        try writeStrings(
            """
            "Folder Compare" = "文件夹比较";
            "Inspect two directory trees" = "检查两个目录树";
            "Session" = "会话";
            """,
            locale: "zh-Hans",
            resourcesURL: resourcesURL
        )

        guard let bundle = Bundle(url: bundleURL) else {
            throw LocalizationFixtureError.couldNotCreateBundle
        }
        return (bundle, bundleURL)
    }

    private func writeStrings(
        _ contents: String,
        locale: String,
        resourcesURL: URL
    ) throws {
        let directory = resourcesURL.appendingPathComponent(
            "\(locale).lproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try contents.write(
            to: directory.appendingPathComponent("Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private enum LocalizationFixtureError: Error {
    case couldNotCreateBundle
}
