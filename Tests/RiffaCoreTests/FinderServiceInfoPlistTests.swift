import Foundation
import Testing

@Suite("Finder Service bundle declarations")
struct FinderServiceInfoPlistTests {
    @Test("Info.plist declares four exact menus and matching Riffa selectors")
    func serviceDeclarations() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = repositoryRoot
            .appending(path: "Sources/RiffaApp/Resources/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let root = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        let services = try #require(root["NSServices"] as? [[String: Any]])

        #expect(services.count == 4)
        #expect(services.compactMap(menuTitle) == [
            "Select Left File for Compare",
            "Compare Files",
            "Select Left Folder for Compare",
            "Compare Folders",
        ])
        #expect(services.compactMap { $0["NSMessage"] as? String } == [
            "riffaSelectLeftFile",
            "riffaCompareFiles",
            "riffaSelectLeftFolder",
            "riffaCompareFolders",
        ])
        #expect(services.compactMap { $0["NSPortName"] as? String } == [
            "Riffa", "Riffa", "Riffa", "Riffa",
        ])
        #expect(services.compactMap { $0["NSSendFileTypes"] as? [String] } == [
            ["public.data"],
            ["public.data"],
            ["public.directory"],
            ["public.directory"],
        ])
        #expect(services.allSatisfy {
            guard let context = $0["NSRequiredContext"] as? [String: Any] else {
                return false
            }
            return context.isEmpty
        })
    }

    private func menuTitle(_ service: [String: Any]) -> String? {
        (service["NSMenuItem"] as? [String: String])?["default"]
    }
}
