import Foundation
import Testing
@testable import RiffaCore

@Test("Three-tree analysis classifies independent edits, additions, and deletions")
func folderMergeClassifiesCoreStates() async throws {
    let sandbox = try FolderMergeSandbox()
    defer { sandbox.remove() }

    try sandbox.write("same", to: "unchanged.txt", on: .all)
    try sandbox.write("base", to: "left-changed.txt", on: [.base, .right])
    try sandbox.write("LEFT", to: "left-changed.txt", on: [.left])
    try sandbox.write("base", to: "right-changed.txt", on: [.base, .left])
    try sandbox.write("RIGHT", to: "right-changed.txt", on: [.right])
    try sandbox.write("base", to: "both-same.txt", on: [.base])
    try sandbox.write("merged", to: "both-same.txt", on: [.left, .right])
    try sandbox.write("base", to: "conflict.txt", on: [.base])
    try sandbox.write("LEFT", to: "conflict.txt", on: [.left])
    try sandbox.write("RIGHT", to: "conflict.txt", on: [.right])
    try sandbox.write("deleted", to: "left-deleted.txt", on: [.base, .right])
    try sandbox.write("deleted", to: "right-deleted.txt", on: [.base, .left])
    try sandbox.write("deleted", to: "both-deleted.txt", on: [.base])
    try sandbox.write("base", to: "delete-vs-change.txt", on: [.base])
    try sandbox.write("changed", to: "delete-vs-change.txt", on: [.right])
    try sandbox.write("left addition", to: "left-added.txt", on: [.left])
    try sandbox.write("right addition", to: "right-added.txt", on: [.right])
    try sandbox.write("same addition", to: "both-added-same.txt", on: [.left, .right])
    try sandbox.write("L", to: "both-added-different.txt", on: [.left])
    try sandbox.write("R", to: "both-added-different.txt", on: [.right])

    let result = await sandbox.analyze(chunkSize: 3)
    let rows = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.relativePath, $0) })
    let actions = Dictionary(uniqueKeysWithValues: result.plan.actions.map { ($0.outputRelativePath, $0) })

    #expect(rows["unchanged.txt"]?.status == .unchanged)
    #expect(rows["left-changed.txt"]?.status == .leftChanged)
    #expect(rows["right-changed.txt"]?.status == .rightChanged)
    #expect(rows["both-same.txt"]?.status == .bothChangedSame)
    #expect(rows["conflict.txt"]?.status == .conflict)
    #expect(rows["left-deleted.txt"]?.status == .leftDeleted)
    #expect(rows["right-deleted.txt"]?.status == .rightDeleted)
    #expect(rows["both-deleted.txt"]?.status == .bothDeleted)
    #expect(rows["delete-vs-change.txt"]?.status == .conflict)
    #expect(rows["left-added.txt"]?.status == .leftChanged)
    #expect(rows["right-added.txt"]?.status == .rightChanged)
    #expect(rows["both-added-same.txt"]?.status == .bothChangedSame)
    #expect(rows["both-added-different.txt"]?.status == .conflict)

    #expect(actions["unchanged.txt"]?.kind == .copyFromBase)
    #expect(actions["left-changed.txt"]?.kind == .copyFromLeft)
    #expect(actions["right-changed.txt"]?.kind == .copyFromRight)
    #expect(actions["both-same.txt"]?.kind == .copyFromLeft)
    #expect(actions["left-deleted.txt"]?.kind == .omit)
    #expect(actions["delete-vs-change.txt"]?.kind == .conflict)
    #expect(result.summary.conflictCount == 3)
    #expect(result.plan.hasConflicts)
}

@Test("File equality is byte-based even when size and modification dates match")
func folderMergeUsesChunkedFileContent() async throws {
    let sandbox = try FolderMergeSandbox()
    defer { sandbox.remove() }
    try sandbox.write("AAAA1111", to: "same-metadata.bin", on: [.base, .right])
    try sandbox.write("BBBB1111", to: "same-metadata.bin", on: [.left])
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    try sandbox.setModificationDate(date, for: "same-metadata.bin", on: .all)

    let result = await sandbox.analyze(chunkSize: 2)

    #expect(result.nodes.count == 1)
    #expect(result.nodes.first?.status == .leftChanged)
    #expect(result.plan.actions.first?.kind == .copyFromLeft)
}

@Test("Resource kind changes are explicit type conflicts")
func folderMergeReportsTypeConflicts() async throws {
    let sandbox = try FolderMergeSandbox()
    defer { sandbox.remove() }
    try sandbox.write("file", to: "item", on: [.base, .right])
    try sandbox.createDirectory("item", on: [.left])

    let result = await sandbox.analyze()
    let node = result.nodes.first { $0.relativePath == "item" }

    #expect(node?.status == .typeConflict)
    #expect(node?.kind == .mixed)
    #expect(result.plan.actions.first { $0.outputRelativePath == "item" }?.kind == .conflict)
}

@Test("Directory comparison propagates nested edits and deletion-versus-modification conflicts")
func folderMergeComparesDirectorySubtrees() async throws {
    let sandbox = try FolderMergeSandbox()
    defer { sandbox.remove() }
    try sandbox.write("base", to: "edited/child.txt", on: [.base, .right])
    try sandbox.write("left", to: "edited/child.txt", on: [.left])
    try sandbox.write("base", to: "removed/child.txt", on: [.base])
    try sandbox.write("right changed", to: "removed/child.txt", on: [.right])

    let result = await sandbox.analyze()
    let rows = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.relativePath, $0) })
    let actionKinds = result.plan.actions.map(\.kind)

    #expect(rows["edited"]?.status == .leftChanged)
    #expect(rows["edited/child.txt"]?.status == .leftChanged)
    #expect(rows["removed"]?.status == .conflict)
    #expect(rows["removed/child.txt"]?.status == .conflict)
    #expect(actionKinds.first == .createDirectory)
    let directoryIndex = try #require(result.plan.actions.firstIndex { $0.outputRelativePath == "edited" })
    let childIndex = try #require(result.plan.actions.firstIndex { $0.outputRelativePath == "edited/child.txt" })
    #expect(directoryIndex < childIndex)
}

@Test("Symbolic links are compared as links and are never traversed")
func folderMergeDoesNotFollowSymbolicLinks() async throws {
    let sandbox = try FolderMergeSandbox()
    defer { sandbox.remove() }
    try sandbox.createSymbolicLink("loop", destination: ".", on: .all)
    try sandbox.createSymbolicLink("target", destination: "one", on: [.base, .right])
    try sandbox.createSymbolicLink("target", destination: "two", on: [.left])

    let result = await sandbox.analyze()
    let rows = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.relativePath, $0) })

    #expect(rows["loop"]?.kind == .symbolicLink)
    #expect(rows["loop"]?.status == .unchanged)
    #expect(rows["target"]?.status == .leftChanged)
    #expect(!result.nodes.contains { $0.relativePath.hasPrefix("loop/") })
    #expect(result.nodes.count == 2)
}

@Test("Node and plan ordering are deterministic")
func folderMergeOrderingIsDeterministic() async throws {
    let sandbox = try FolderMergeSandbox()
    defer { sandbox.remove() }
    try sandbox.write("z", to: "z/file.txt", on: .all)
    try sandbox.write("a", to: "a/file.txt", on: .all)
    try sandbox.write("m", to: "m.txt", on: .all)

    let first = await sandbox.analyze()
    let second = await sandbox.analyze()

    #expect(first == second)
    #expect(first.nodes.map(\.relativePath) == first.nodes.map(\.relativePath).sorted())
    #expect(first.plan.actions.map(\.kind).prefix(2).allSatisfy { $0 == .createDirectory })
    #expect(first.plan.actions.map(\.outputRelativePath) == ["a", "z", "a/file.txt", "m.txt", "z/file.txt"])
}

@Test("An invalid root produces an error node and a non-executable conflict action")
func folderMergeRepresentsRootErrors() async throws {
    let sandbox = try FolderMergeSandbox()
    defer { sandbox.remove() }
    let invalidBase = sandbox.root.appending(path: "not-a-directory")
    try Data("file".utf8).write(to: invalidBase)

    let result = await FolderMerge().analyze(
        baseURL: invalidBase,
        leftURL: sandbox.left,
        rightURL: sandbox.right
    )

    #expect(result.nodes.count == 1)
    #expect(result.nodes.first?.relativePath == ".")
    #expect(result.nodes.first?.status == .error)
    #expect(result.nodes.first?.issues.isEmpty == false)
    #expect(result.plan.actions.first?.kind == .conflict)
    #expect(result.summary.errorCount == 1)
}

private struct FolderMergeSandbox {
    enum Side: CaseIterable, Hashable {
        case base
        case left
        case right
    }

    let root: URL
    let base: URL
    let left: URL
    let right: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "RiffaFolderMergeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        base = root.appending(path: "base", directoryHint: .isDirectory)
        left = root.appending(path: "left", directoryHint: .isDirectory)
        right = root.appending(path: "right", directoryHint: .isDirectory)
        for url in [base, left, right] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func analyze(chunkSize: Int = 4) async -> FolderMergeResult {
        await FolderMerge().analyze(
            baseURL: base,
            leftURL: left,
            rightURL: right,
            options: FolderMergeOptions(contentReadChunkSize: chunkSize)
        )
    }

    func write(_ contents: String, to path: String, on sides: Set<Side>) throws {
        for side in sides {
            let url = url(for: side).appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
    }

    func createDirectory(_ path: String, on sides: Set<Side>) throws {
        for side in sides {
            try FileManager.default.createDirectory(
                at: url(for: side).appending(path: path, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
    }

    func createSymbolicLink(_ path: String, destination: String, on sides: Set<Side>) throws {
        for side in sides {
            try FileManager.default.createSymbolicLink(
                atPath: url(for: side).appending(path: path).path,
                withDestinationPath: destination
            )
        }
    }

    func setModificationDate(_ date: Date, for path: String, on sides: Set<Side>) throws {
        for side in sides {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: url(for: side).appending(path: path).path
            )
        }
    }

    private func url(for side: Side) -> URL {
        switch side {
        case .base:
            base
        case .left:
            left
        case .right:
            right
        }
    }
}

private extension Set<FolderMergeSandbox.Side> {
    static var all: Self { Set(FolderMergeSandbox.Side.allCases) }
}
