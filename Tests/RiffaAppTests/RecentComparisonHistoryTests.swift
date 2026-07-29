import Foundation
import RiffaCore
import Testing
@testable import RiffaApp

@Suite("Recent comparison history")
struct RecentComparisonHistoryTests {
    @Test("History deduplicates exact inputs and remains bounded")
    func deduplicatesAndBounds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("recent.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RecentComparisonHistoryStore(
            fileURL: fileURL,
            maximumSessionCount: 2
        )
        let firstResources = resources("left.txt", "right.txt")
        let secondResources = resources("old.csv", "new.csv")
        let thirdResources = resources("before.pdf", "after.pdf")
        let start = Date(timeIntervalSince1970: 100)

        _ = try await store.record(
            kind: .textComparison,
            name: "left.txt ↔ right.txt",
            resources: firstResources,
            options: ["ignoreCase": .boolean(false)],
            openedAt: start
        )
        _ = try await store.record(
            kind: .tableComparison,
            name: "old.csv ↔ new.csv",
            resources: secondResources,
            options: [:],
            openedAt: start.addingTimeInterval(1)
        )
        let refreshed = try await store.record(
            kind: .textComparison,
            name: "left.txt ↔ right.txt",
            resources: firstResources,
            options: ["ignoreCase": .boolean(true)],
            openedAt: start.addingTimeInterval(2)
        )

        #expect(refreshed.count == 2)
        #expect(refreshed[0].kind == .textComparison)
        #expect(refreshed[0].options["ignoreCase"] == .boolean(true))

        _ = try await store.record(
            kind: .pdfComparison,
            name: "before.pdf ↔ after.pdf",
            resources: thirdResources,
            options: [:],
            openedAt: start.addingTimeInterval(3)
        )
        let reloaded = try await RecentComparisonHistoryStore(
            fileURL: fileURL,
            maximumSessionCount: 2
        ).load()

        #expect(reloaded.map(\.kind) == [.pdfComparison, .textComparison])
    }

    @Test("A corrupted history file is never overwritten")
    func corruptedFileProtection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("recent.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let corrupted = Data("{ not-json".utf8)
        try corrupted.write(to: fileURL)
        let store = RecentComparisonHistoryStore(fileURL: fileURL)

        await #expect(throws: RecentComparisonHistoryError.self) {
            _ = try await store.record(
                kind: .textComparison,
                name: "left.txt ↔ right.txt",
                resources: resources("left.txt", "right.txt"),
                options: [:]
            )
        }
        #expect(try Data(contentsOf: fileURL) == corrupted)
    }

    private func resources(
        _ names: String...
    ) -> [SessionResourceReference] {
        names.map {
            SessionResourceReference(
                providerID: "local",
                path: "/tmp/\($0)",
                bookmarkData: Data([0x01])
            )
        }
    }
}

@Suite("Comparison side switching")
struct ComparisonSideSwitchingTests {
    @Test("Text comparison swaps all paired state and can switch back")
    @MainActor
    func textComparisonRoundTrip() {
        let model = TextCompareModel()
        model.loadDemo()
        let originalLeftURL = model.leftURL
        let originalRightURL = model.rightURL
        let originalLeftText = model.leftDocument?.text
        let originalRightText = model.rightDocument?.text

        model.swapSides()

        #expect(model.leftURL == originalRightURL)
        #expect(model.rightURL == originalLeftURL)
        #expect(model.leftDocument?.text == originalRightText)
        #expect(model.rightDocument?.text == originalLeftText)

        model.swapSides()

        #expect(model.leftURL == originalLeftURL)
        #expect(model.rightURL == originalRightURL)
        #expect(model.leftDocument?.text == originalLeftText)
        #expect(model.rightDocument?.text == originalRightText)
    }
}
