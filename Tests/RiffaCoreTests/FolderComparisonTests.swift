import Foundation
import Testing
@testable import RiffaCore

@Test("Folder comparison recursively merges paths and compares file content")
func recursivelyMergesFolderTrees() async throws {
    let sandbox = try FolderTestSandbox()
    defer { sandbox.remove() }

    try sandbox.createDirectory("nested", on: .both)
    try sandbox.write("matching", to: "same.txt", on: .both)
    try sandbox.write("LEFT", to: "nested/changed.txt", on: .left)
    try sandbox.write("RGHT", to: "nested/changed.txt", on: .right)
    try sandbox.write("left", to: "left-only.txt", on: .left)
    try sandbox.write("right", to: "right-only.txt", on: .right)
    try sandbox.setCommonModificationDate(for: ["same.txt", "nested/changed.txt"])

    let result = await FolderComparison().compare(
        leftURL: sandbox.left,
        rightURL: sandbox.right,
        options: FolderComparisonOptions(
            modificationDateTolerance: 0,
            compareFileContents: true
        )
    )
    let rows = Dictionary(uniqueKeysWithValues: result.map { ($0.relativePath, $0) })

    #expect(rows["same.txt"]?.status == .same)
    #expect(rows["nested"]?.status == .same)
    #expect(rows["nested/changed.txt"]?.status == .different)
    #expect(rows["left-only.txt"]?.status == .leftOnly)
    #expect(rows["right-only.txt"]?.status == .rightOnly)
    #expect(result.map(\.relativePath) == result.map(\.relativePath).sorted())
}

@Test("Quick comparison uses modification dates and content comparison is optional")
func quickAndContentComparisonModes() async throws {
    let sandbox = try FolderTestSandbox()
    defer { sandbox.remove() }

    try sandbox.write("same bytes", to: "mtime.txt", on: .both)
    try sandbox.setModificationDate(Date(timeIntervalSince1970: 1_700_000_000), for: "mtime.txt", on: .left)
    try sandbox.setModificationDate(Date(timeIntervalSince1970: 1_700_000_100), for: "mtime.txt", on: .right)

    let quickResult = await FolderComparison().compare(
        leftURL: sandbox.left,
        rightURL: sandbox.right,
        options: FolderComparisonOptions(modificationDateTolerance: 0)
    )
    #expect(quickResult.first?.status == .different)

    let contentResult = await FolderComparison().compare(
        leftURL: sandbox.left,
        rightURL: sandbox.right,
        options: FolderComparisonOptions(
            compareModificationDates: false,
            compareFileContents: true
        )
    )
    #expect(contentResult.first?.status == .same)
}

@Test("A file aligned with a directory is a type mismatch")
func reportsTypeMismatch() async throws {
    let sandbox = try FolderTestSandbox()
    defer { sandbox.remove() }

    try sandbox.write("file", to: "item", on: .left)
    try sandbox.createDirectory("item", on: .right)

    let result = await FolderComparison().compare(leftURL: sandbox.left, rightURL: sandbox.right)

    #expect(result.count == 1)
    #expect(result.first?.relativePath == "item")
    #expect(result.first?.status == .typeMismatch)
}

@Test("Symbolic links are not followed by default and cycles are bounded")
func handlesSymbolicLinksWithoutLoops() async throws {
    let sandbox = try FolderTestSandbox()
    defer { sandbox.remove() }

    try sandbox.createDirectory("target", on: .both)
    try sandbox.write("inside", to: "target/inside.txt", on: .both)
    try sandbox.createSymbolicLink("alias", destination: "target", on: .both)
    try sandbox.createSymbolicLink("cycle", destination: ".", on: .both)
    try sandbox.setCommonModificationDate(for: ["target/inside.txt"])

    let defaultResult = await FolderComparison().compare(
        leftURL: sandbox.left,
        rightURL: sandbox.right,
        options: FolderComparisonOptions(compareModificationDates: false, compareFileContents: true)
    )
    #expect(defaultResult.contains { $0.relativePath == "alias" && $0.left?.kind == .symbolicLink })
    #expect(!defaultResult.contains { $0.relativePath.hasPrefix("alias/") })
    #expect(!defaultResult.contains { $0.relativePath.hasPrefix("cycle/") })

    let followedResult = await FolderComparison().compare(
        leftURL: sandbox.left,
        rightURL: sandbox.right,
        options: FolderComparisonOptions(
            compareModificationDates: false,
            compareFileContents: true,
            followSymbolicLinks: true
        )
    )
    let followedPaths = followedResult.map(\.relativePath)
    #expect(followedPaths.contains("alias/inside.txt"))
    #expect(!followedPaths.contains { $0.hasPrefix("cycle/") })
    #expect(followedResult.count < 10)
}

@Test("An invalid root is represented by an error row")
func representsRootErrors() async throws {
    let sandbox = try FolderTestSandbox()
    defer { sandbox.remove() }

    let notADirectory = sandbox.root.appending(path: "not-a-directory")
    try Data("file".utf8).write(to: notADirectory)

    let result = await FolderComparison().compare(leftURL: notADirectory, rightURL: sandbox.right)

    #expect(result.count == 1)
    #expect(result.first?.relativePath == ".")
    #expect(result.first?.status == .error)
    #expect(result.first?.issues.isEmpty == false)
}

private struct FolderTestSandbox {
    enum Side {
        case left
        case right
        case both
    }

    let root: URL
    let left: URL
    let right: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "RiffaFolderComparisonTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        left = root.appending(path: "left", directoryHint: .isDirectory)
        right = root.appending(path: "right", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func createDirectory(_ path: String, on side: Side) throws {
        for root in roots(for: side) {
            try FileManager.default.createDirectory(
                at: root.appending(path: path, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
    }

    func write(_ string: String, to path: String, on side: Side) throws {
        for root in roots(for: side) {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(string.utf8).write(to: url)
        }
    }

    func createSymbolicLink(_ path: String, destination: String, on side: Side) throws {
        for root in roots(for: side) {
            try FileManager.default.createSymbolicLink(
                atPath: root.appending(path: path).path,
                withDestinationPath: destination
            )
        }
    }

    func setCommonModificationDate(for paths: [String]) throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for path in paths {
            try setModificationDate(date, for: path, on: .both)
        }
    }

    func setModificationDate(_ date: Date, for path: String, on side: Side) throws {
        for root in roots(for: side) {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: root.appending(path: path).path
            )
        }
    }

    private func roots(for side: Side) -> [URL] {
        switch side {
        case .left:
            [left]
        case .right:
            [right]
        case .both:
            [left, right]
        }
    }
}
