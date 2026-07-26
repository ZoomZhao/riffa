import CryptoKit
import Darwin
import Foundation
import Testing
@testable import RiffaCore

@Test("Dry-run is the default and performs no writes")
func localSyncDefaultsToDryRun() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    try sandbox.write("source", to: "file.txt", on: .left)
    let plan = FolderSyncPlan(mode: .updateRight, actions: [
        executorCopy("file.txt", from: .left, to: .right)
    ])

    let log = await LocalFolderSyncExecutor().execute(
        plan: plan,
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        backupRoot: sandbox.backup
    )

    #expect(log.status == .dryRun)
    #expect(log.dryRun)
    #expect(log.itemResults.map(\.status) == [.planned])
    #expect(!sandbox.exists("file.txt", on: .right))
    #expect(!FileManager.default.fileExists(atPath: sandbox.backup.path))
}

@Test("Unsafe relative paths are rejected before any write")
func localSyncRejectsPathTraversal() async throws {
    let unsafePaths = ["", "/absolute.txt", "../escape.txt", "a/../escape.txt", "a//file.txt", "a/", "./file.txt"]

    for unsafePath in unsafePaths {
        let sandbox = try ExecutorSandbox()
        defer { sandbox.remove() }
        try sandbox.write("source", to: "source.txt", on: .left)
        let action = FolderSyncAction(
            kind: .copy,
            sourceSide: .left,
            targetSide: .right,
            sourceRelativePath: "source.txt",
            targetRelativePath: unsafePath,
            reason: .sourceOnly,
            risk: .low
        )

        let log = await LocalFolderSyncExecutor().execute(
            plan: FolderSyncPlan(mode: .updateRight, actions: [action]),
            leftRoot: sandbox.left,
            rightRoot: sandbox.right,
            backupRoot: sandbox.backup,
            options: .init(dryRun: false)
        )

        #expect(log.status == .refused)
        #expect(log.issues.contains { $0.code == .invalidRelativePath })
        #expect(!sandbox.exists("escape.txt", on: .right))
    }
}

@Test("Preflight checks every source before the first action writes")
func localSyncPreflightsTheWholePlan() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    try sandbox.write("valid", to: "valid.txt", on: .left)
    let actions = [
        executorCopy("valid.txt", from: .left, to: .right),
        executorCopy("missing.txt", from: .left, to: .right)
    ]

    let log = await LocalFolderSyncExecutor().execute(
        plan: FolderSyncPlan(mode: .updateRight, actions: actions),
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false)
    )

    #expect(log.status == .refused)
    #expect(log.issues.contains { $0.code == .missingSource && $0.actionIndex == 1 })
    #expect(!sandbox.exists("valid.txt", on: .right))
}

@Test("An intermediate symbolic link cannot escape a synchronization root")
func localSyncRejectsSymbolicLinkEscape() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    try sandbox.write("source", to: "source.txt", on: .left)
    try FileManager.default.createSymbolicLink(
        at: sandbox.right.appending(path: "linked"),
        withDestinationURL: sandbox.outside
    )
    let action = FolderSyncAction(
        kind: .copy,
        sourceSide: .left,
        targetSide: .right,
        sourceRelativePath: "source.txt",
        targetRelativePath: "linked/escaped.txt",
        reason: .sourceOnly,
        risk: .low
    )

    let log = await LocalFolderSyncExecutor().execute(
        plan: FolderSyncPlan(mode: .updateRight, actions: [action]),
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false)
    )

    #expect(log.status == .refused)
    #expect(log.issues.contains { $0.code == .symbolicLinkTraversal })
    #expect(!FileManager.default.fileExists(atPath: sandbox.outside.appending(path: "escaped.txt").path))
}

@Test("Conflicts are always refused and high-risk actions require an explicit gate")
func localSyncEnforcesConflictAndRiskGates() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    try sandbox.write("left", to: "item.txt", on: .left)
    try sandbox.write("right", to: "item.txt", on: .right)

    let conflict = FolderSyncAction(
        kind: .conflict,
        sourceSide: .left,
        targetSide: .right,
        sourceRelativePath: "item.txt",
        targetRelativePath: "item.txt",
        reason: .bothSidesDiffer,
        risk: .high
    )
    let conflictLog = await LocalFolderSyncExecutor().execute(
        plan: FolderSyncPlan(mode: .updateBoth, actions: [conflict]),
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false, allowHighRisk: true)
    )
    #expect(conflictLog.status == .refused)
    #expect(conflictLog.issues.contains { $0.code == .conflict })

    let deletion = executorDelete("item.txt", on: .right)
    let riskLog = await LocalFolderSyncExecutor().execute(
        plan: FolderSyncPlan(mode: .mirrorLeftToRight, actions: [deletion]),
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false)
    )
    #expect(riskLog.status == .refused)
    #expect(riskLog.issues.contains { $0.code == .highRiskNotAllowed })
    #expect(try sandbox.read("item.txt", on: .right) == "right")
}

@Test("Copy installs a regular file through a same-directory temporary file")
func localSyncCopiesFiles() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    try sandbox.write("copied bytes", to: "nested/source.txt", on: .left)
    try sandbox.createDirectory("nested", on: .right)
    let action = executorCopy("nested/source.txt", from: .left, to: .right)

    let log = await LocalFolderSyncExecutor().execute(
        plan: FolderSyncPlan(mode: .updateRight, actions: [action]),
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false)
    )

    #expect(log.status == .completed)
    #expect(log.itemResults.map(\.status) == [.completed])
    #expect(try sandbox.read("nested/source.txt", on: .right) == "copied bytes")
    let siblingNames = try FileManager.default.contentsOfDirectory(
        atPath: sandbox.right.appending(path: "nested").path
    )
    #expect(!siblingNames.contains { $0.hasPrefix(".riffa-") })
}

@Test("Replace and delete move old targets into side-preserving backups")
func localSyncBacksUpDestructiveChanges() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    try sandbox.write("new", to: "replace.txt", on: .left)
    try sandbox.write("old", to: "replace.txt", on: .right)
    try sandbox.write("obsolete", to: "obsolete.txt", on: .right)
    let actions = [
        executorReplace("replace.txt", from: .left, to: .right),
        executorDelete("obsolete.txt", on: .right)
    ]

    let log = await LocalFolderSyncExecutor().execute(
        plan: FolderSyncPlan(mode: .mirrorLeftToRight, actions: actions),
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false, allowHighRisk: true)
    )

    #expect(log.status == .completed)
    #expect(try sandbox.read("replace.txt", on: .right) == "new")
    #expect(!sandbox.exists("obsolete.txt", on: .right))
    #expect(try sandbox.readBackup("right/replace.txt") == "old")
    #expect(try sandbox.readBackup("right/obsolete.txt") == "obsolete")
}

@Test("Nested mirror deletions assemble child and parent backups without collisions")
func localSyncBacksUpDeletedTrees() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    try sandbox.write("nested", to: "obsolete/child.txt", on: .right)
    let actions = [
        executorDelete("obsolete/child.txt", on: .right),
        executorDelete("obsolete", on: .right)
    ]

    let log = await LocalFolderSyncExecutor().execute(
        plan: FolderSyncPlan(mode: .mirrorLeftToRight, actions: actions),
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false, allowHighRisk: true)
    )

    #expect(log.status == .completed)
    #expect(!sandbox.exists("obsolete", on: .right))
    #expect(try sandbox.readBackup("right/obsolete/child.txt") == "nested")
    #expect(!FileManager.default.fileExists(
        atPath: sandbox.backup.appending(path: ".riffa-transactions").path
    ))
}

@Test("One plan can copy unique files in both directions")
func localSyncExecutesBidirectionally() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    try sandbox.write("from left", to: "left.txt", on: .left)
    try sandbox.write("from right", to: "right.txt", on: .right)
    let actions = [
        executorCopy("left.txt", from: .left, to: .right),
        executorCopy("right.txt", from: .right, to: .left)
    ]

    let log = await LocalFolderSyncExecutor().execute(
        plan: FolderSyncPlan(mode: .updateBoth, actions: actions),
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false)
    )

    #expect(log.status == .completed)
    #expect(try sandbox.read("left.txt", on: .right) == "from left")
    #expect(try sandbox.read("right.txt", on: .left) == "from right")
}

@Test("A later failure rolls a completed replacement back from its backup")
func localSyncRollsBackAfterFailure() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    try sandbox.write("new", to: "replace.txt", on: .left)
    try sandbox.write("old", to: "replace.txt", on: .right)
    try sandbox.write("later", to: "later.txt", on: .left)
    let actions = [
        executorReplace("replace.txt", from: .left, to: .right),
        executorCopy("later.txt", from: .left, to: .right)
    ]

    let log = await LocalFolderSyncExecutor(testingFailureAtActionIndex: 1).execute(
        plan: FolderSyncPlan(mode: .updateRight, actions: actions),
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false)
    )

    #expect(log.status == .failedRolledBack)
    #expect(log.rollbackAttempted)
    #expect(log.rollbackSucceeded == true)
    #expect(log.itemResults[0].status == .rolledBack)
    #expect(log.itemResults[1].status == .failed)
    #expect(try sandbox.read("replace.txt", on: .right) == "old")
    #expect(!sandbox.exists("later.txt", on: .right))
    #expect(!FileManager.default.fileExists(atPath: sandbox.backup.appending(path: "right/replace.txt").path))
}

@Test("A proved mirror rename executes as a same-root no-clobber move")
func localSyncExecutesVerifiedMove() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    let contents = "verified rename"
    try sandbox.write(contents, to: "new/item.txt", on: .left)
    try sandbox.write(contents, to: "old/item.txt", on: .right)
    try sandbox.createDirectory("new", on: .right)
    let originalInode = try inode(at: sandbox.right.appending(path: "old/item.txt"))

    let log = await LocalFolderSyncExecutor().execute(
        plan: FolderSyncPlan(mode: .mirrorLeftToRight, actions: [
            executorMove(
                "old/item.txt",
                to: "new/item.txt",
                target: .right,
                reference: .left,
                contents: contents
            )
        ]),
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false, allowHighRisk: true)
    )

    #expect(log.status == .completed)
    #expect(log.itemResults.map(\.status) == [.completed])
    #expect(!sandbox.exists("old/item.txt", on: .right))
    #expect(try sandbox.read("new/item.txt", on: .right) == contents)
    #expect(try inode(at: sandbox.right.appending(path: "new/item.txt")) == originalInode)
}

@Test("Move proof verification is part of whole-plan preflight")
func localSyncPreflightsMoveProofBeforeAnyWrite() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    try sandbox.write("copy me", to: "copy.txt", on: .left)
    try sandbox.write("authoritative", to: "new/item.txt", on: .left)
    try sandbox.write("stale source", to: "old/item.txt", on: .right)
    try sandbox.createDirectory("new", on: .right)
    let actions = [
        executorCopy("copy.txt", from: .left, to: .right),
        executorMove(
            "old/item.txt",
            to: "new/item.txt",
            target: .right,
            reference: .left,
            contents: "authoritative"
        )
    ]

    let log = await LocalFolderSyncExecutor().execute(
        plan: FolderSyncPlan(mode: .mirrorLeftToRight, actions: actions),
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false, allowHighRisk: true)
    )

    #expect(log.status == .refused)
    #expect(log.issues.contains { $0.code == .moveVerificationFailed && $0.actionIndex == 1 })
    #expect(!sandbox.exists("copy.txt", on: .right))
    #expect(try sandbox.read("old/item.txt", on: .right) == "stale source")
    #expect(!sandbox.exists("new/item.txt", on: .right))
}

@Test("A later action failure reverses a completed verified move")
func localSyncRollsBackVerifiedMove() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    let contents = "move then restore"
    try sandbox.write(contents, to: "new/item.txt", on: .left)
    try sandbox.write(contents, to: "old/item.txt", on: .right)
    try sandbox.createDirectory("new", on: .right)
    try sandbox.write("later", to: "later.txt", on: .left)
    let actions = [
        executorMove(
            "old/item.txt",
            to: "new/item.txt",
            target: .right,
            reference: .left,
            contents: contents
        ),
        executorCopy("later.txt", from: .left, to: .right)
    ]

    let log = await LocalFolderSyncExecutor(testingFailureAtActionIndex: 1).execute(
        plan: FolderSyncPlan(mode: .mirrorLeftToRight, actions: actions),
        leftRoot: sandbox.left,
        rightRoot: sandbox.right,
        backupRoot: sandbox.backup,
        options: .init(dryRun: false, allowHighRisk: true)
    )

    #expect(log.status == .failedRolledBack)
    #expect(log.itemResults.map(\.status) == [.rolledBack, .failed])
    #expect(try sandbox.read("old/item.txt", on: .right) == contents)
    #expect(!sandbox.exists("new/item.txt", on: .right))
    #expect(!sandbox.exists("later.txt", on: .right))
}

@Test("Executor accepts only EXDEV for verified copy-delete fallback")
func localSyncExecutesForcedCrossDeviceMove() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    let contents = String(repeating: "x", count: 700_000)
    try sandbox.write(contents, to: "new/item.txt", on: .left)
    try sandbox.write(contents, to: "old/item.txt", on: .right)
    try sandbox.createDirectory("new", on: .right)
    let action = executorMove(
        "old/item.txt",
        to: "new/item.txt",
        target: .right,
        reference: .left,
        contents: contents
    )

    let log = await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
        point == .beforeRename ? .forceCrossDevice : .proceed
    }) {
        await LocalFolderSyncExecutor().execute(
            plan: FolderSyncPlan(mode: .mirrorLeftToRight, actions: [action]),
            leftRoot: sandbox.left,
            rightRoot: sandbox.right,
            backupRoot: sandbox.backup,
            options: .init(dryRun: false, allowHighRisk: true)
        )
    }

    #expect(log.status == .completed)
    #expect(!sandbox.exists("old/item.txt", on: .right))
    #expect(try sandbox.read("new/item.txt", on: .right) == contents)
}

@Test("Cancellation after move installation restores the source before logging failure")
func localSyncCancellationRollsBackCurrentMove() async throws {
    let sandbox = try ExecutorSandbox()
    defer { sandbox.remove() }
    let contents = "cancel safely"
    try sandbox.write(contents, to: "new/item.txt", on: .left)
    try sandbox.write(contents, to: "old/item.txt", on: .right)
    try sandbox.createDirectory("new", on: .right)
    let action = executorMove(
        "old/item.txt",
        to: "new/item.txt",
        target: .right,
        reference: .left,
        contents: contents
    )

    let log = await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
        point == .afterInstall ? .cancel : .proceed
    }) {
        await LocalFolderSyncExecutor().execute(
            plan: FolderSyncPlan(mode: .mirrorLeftToRight, actions: [action]),
            leftRoot: sandbox.left,
            rightRoot: sandbox.right,
            backupRoot: sandbox.backup,
            options: .init(dryRun: false, allowHighRisk: true)
        )
    }

    #expect(log.status == .failedRolledBack)
    #expect(log.issues.first?.code == .cancelled)
    #expect(try sandbox.read("old/item.txt", on: .right) == contents)
    #expect(!sandbox.exists("new/item.txt", on: .right))
}

private func executorCopy(
    _ path: String,
    from source: FolderSyncSide,
    to target: FolderSyncSide
) -> FolderSyncAction {
    FolderSyncAction(
        kind: .copy,
        sourceSide: source,
        targetSide: target,
        sourceRelativePath: path,
        targetRelativePath: path,
        reason: .sourceOnly,
        risk: .low
    )
}

private func executorReplace(
    _ path: String,
    from source: FolderSyncSide,
    to target: FolderSyncSide
) -> FolderSyncAction {
    FolderSyncAction(
        kind: .replace,
        sourceSide: source,
        targetSide: target,
        sourceRelativePath: path,
        targetRelativePath: path,
        reason: .contentDiffers,
        risk: .medium
    )
}

private func executorDelete(_ path: String, on target: FolderSyncSide) -> FolderSyncAction {
    FolderSyncAction(
        kind: .delete,
        sourceSide: nil,
        targetSide: target,
        sourceRelativePath: nil,
        targetRelativePath: path,
        reason: .mirrorRemovesTargetOnly,
        risk: .high
    )
}

private func executorMove(
    _ sourcePath: String,
    to targetPath: String,
    target: FolderSyncSide,
    reference: FolderSyncSide,
    contents: String
) -> FolderSyncAction {
    let data = Data(contents.utf8)
    return FolderSyncAction(
        kind: .move,
        sourceSide: target,
        targetSide: target,
        sourceRelativePath: sourcePath,
        targetRelativePath: targetPath,
        reason: .renameMatchMovedWithinTarget,
        risk: .high,
        moveProof: FolderSyncMoveProof(
            referenceSide: reference,
            referenceRelativePath: targetPath,
            expectedByteCount: UInt64(data.count),
            expectedSHA256Digest: SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    )
}

private func inode(at url: URL) throws -> UInt64 {
    var information = stat()
    guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
        throw CocoaError(.fileReadUnknown)
    }
    return UInt64(information.st_ino)
}

private struct ExecutorSandbox {
    enum Side {
        case left
        case right
    }

    let root: URL
    let left: URL
    let right: URL
    let backup: URL
    let outside: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "RiffaFolderSyncExecutorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        left = root.appending(path: "left", directoryHint: .isDirectory)
        right = root.appending(path: "right", directoryHint: .isDirectory)
        backup = root.appending(path: "backup", directoryHint: .isDirectory)
        outside = root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func createDirectory(_ path: String, on side: Side) throws {
        try FileManager.default.createDirectory(
            at: root(for: side).appending(path: path, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    func write(_ contents: String, to path: String, on side: Side) throws {
        let url = root(for: side).appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    func read(_ path: String, on side: Side) throws -> String {
        let data = try Data(contentsOf: root(for: side).appending(path: path))
        return String(decoding: data, as: UTF8.self)
    }

    func readBackup(_ path: String) throws -> String {
        let data = try Data(contentsOf: backup.appending(path: path))
        return String(decoding: data, as: UTF8.self)
    }

    func exists(_ path: String, on side: Side) -> Bool {
        FileManager.default.fileExists(atPath: root(for: side).appending(path: path).path)
    }

    private func root(for side: Side) -> URL {
        switch side {
        case .left:
            left
        case .right:
            right
        }
    }
}
