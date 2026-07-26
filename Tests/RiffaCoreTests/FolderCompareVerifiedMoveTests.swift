import Foundation
import Testing
@testable import RiffaCore

@Suite("Folder Compare verified moves")
struct FolderCompareVerifiedMoveTests {
    @Test("A selected unique match becomes only a target-side move")
    func plansOnlySelectedMove() throws {
        let nodes = [
            node("new", left: .directory, right: .directory, status: .same),
            node("new/moved.txt", left: .file, status: .leftOnly),
            node("unrelated.txt", left: .file, status: .leftOnly),
            node("old", right: .directory, status: .rightOnly),
            node("old/moved.txt", right: .file, status: .rightOnly),
            node("obsolete.txt", right: .file, status: .rightOnly)
        ]
        let detection = result(matches: [
            match(left: "new/moved.txt", right: "old/moved.txt")
        ])

        let planned = try FolderCompareVerifiedMovePlanner().plan(
            visibleNodes: nodes,
            renameDetectionResult: detection,
            selectedIDs: ["new/moved.txt"],
            targetSide: .right
        )

        #expect(planned.targetSide == .right)
        #expect(planned.selectedPathCount == 1)
        #expect(planned.selectedMatchCount == 1)
        #expect(planned.plan.mode == .mirrorLeftToRight)
        #expect(planned.plan.actions.map(\.kind) == [.move])
        #expect(planned.plan.summary.createDirectoryCount == 0)
        #expect(planned.plan.summary.moveCount == 1)
        #expect(planned.plan.summary.copyCount == 0)
        #expect(planned.plan.summary.deleteCount == 0)
        #expect(planned.plan.summary.replaceCount == 0)

        let move = try #require(planned.plan.actions.last)
        #expect(move.sourceSide == .right)
        #expect(move.targetSide == .right)
        #expect(move.sourceRelativePath == "old/moved.txt")
        #expect(move.targetRelativePath == "new/moved.txt")
        #expect(move.risk == .high)
        #expect(move.moveProof?.referenceSide == .left)
        #expect(move.moveProof?.referenceRelativePath == "new/moved.txt")
    }

    @Test("A direct move refuses a destination parent that would require an earlier write")
    func rejectsMissingDestinationParent() throws {
        let nodes = [
            node("new", left: .directory, status: .leftOnly),
            node("new/moved.txt", left: .file, status: .leftOnly),
            node("old/moved.txt", right: .file, status: .rightOnly)
        ]
        let detection = result(matches: [
            match(left: "new/moved.txt", right: "old/moved.txt")
        ])

        #expect(throws: FolderCompareVerifiedMovePlanningError.destinationParentRequiresCreation) {
            try FolderCompareVerifiedMovePlanner().plan(
                visibleNodes: nodes,
                renameDetectionResult: detection,
                selectedIDs: ["new/moved.txt"],
                targetSide: .right
            )
        }
    }

    @Test("Moving within left reverses the target and reference sides")
    func plansLeftTarget() throws {
        let nodes = [
            node("old-name.txt", left: .file, status: .leftOnly),
            node("new-name.txt", right: .file, status: .rightOnly)
        ]
        let planned = try FolderCompareVerifiedMovePlanner().plan(
            visibleNodes: nodes,
            renameDetectionResult: result(matches: [
                match(left: "old-name.txt", right: "new-name.txt")
            ]),
            selectedIDs: ["new-name.txt"],
            targetSide: .left
        )

        let move = try #require(planned.plan.actions.first)
        #expect(planned.plan.mode == .mirrorRightToLeft)
        #expect(move.kind == .move)
        #expect(move.sourceSide == .left)
        #expect(move.targetSide == .left)
        #expect(move.sourceRelativePath == "old-name.txt")
        #expect(move.targetRelativePath == "new-name.txt")
        #expect(move.moveProof?.referenceSide == .right)
    }

    @Test("Selecting either or both counterpart rows includes one move exactly once")
    func counterpartSelectionDeduplicatesMatch() throws {
        let nodes = [
            node("new.txt", left: .file, status: .leftOnly),
            node("old.txt", right: .file, status: .rightOnly)
        ]
        let detection = result(matches: [match(left: "new.txt", right: "old.txt")])
        let planner = FolderCompareVerifiedMovePlanner()

        for selection in [Set(["new.txt"]), Set(["old.txt"]), Set(["new.txt", "old.txt"])] {
            let planned = try planner.plan(
                visibleNodes: nodes,
                renameDetectionResult: detection,
                selectedIDs: selection,
                targetSide: .right
            )
            #expect(planned.selectedMatchCount == 1)
            #expect(planned.plan.actions.map(\.kind) == [.move])
        }
    }

    @Test("Every selected row must be covered by one current verified match")
    func rejectsPartialOrEmptySelection() throws {
        let nodes = [
            node("new.txt", left: .file, status: .leftOnly),
            node("old.txt", right: .file, status: .rightOnly),
            node("same.txt", left: .file, right: .file, status: .same)
        ]
        let detection = result(matches: [match(left: "new.txt", right: "old.txt")])
        let planner = FolderCompareVerifiedMovePlanner()

        #expect(throws: FolderCompareVerifiedMovePlanningError.selectionRequired) {
            try planner.plan(
                visibleNodes: nodes,
                renameDetectionResult: detection,
                selectedIDs: [],
                targetSide: .right
            )
        }
        #expect(throws: FolderCompareVerifiedMovePlanningError.selectionContainsUnverifiedPath) {
            try planner.plan(
                visibleNodes: nodes,
                renameDetectionResult: detection,
                selectedIDs: ["new.txt", "same.txt"],
                targetSide: .right
            )
        }
        #expect(throws: FolderCompareVerifiedMovePlanningError.selectionContainsUnverifiedPath) {
            try planner.plan(
                visibleNodes: nodes,
                renameDetectionResult: detection,
                selectedIDs: ["missing-row.txt"],
                targetSide: .right
            )
        }
    }

    @Test("Malformed, duplicate, ambiguous, stale, and duplicate-row claims fail closed")
    func rejectsUntrustedClaims() throws {
        let nodes = [
            node("new.txt", left: .file, status: .leftOnly),
            node("old.txt", right: .file, status: .rightOnly)
        ]
        let valid = match(left: "new.txt", right: "old.txt")
        let malformed = FolderRenameMatch(
            leftRelativePath: "new.txt",
            rightRelativePath: "old.txt",
            byteCount: testByteCount,
            digest: String(repeating: "A", count: 64)
        )
        let stale = FolderRenameMatch(
            leftRelativePath: "new.txt",
            rightRelativePath: "old.txt",
            byteCount: testByteCount + 1,
            digest: testDigest
        )
        let ambiguous = FolderRenameAmbiguousGroup(
            leftRelativePaths: ["new.txt"],
            rightRelativePaths: ["old.txt"],
            byteCount: testByteCount,
            digest: testDigest
        )
        let results = [
            result(matches: [malformed]),
            result(matches: [stale]),
            result(matches: [valid, valid]),
            result(matches: [valid], ambiguousGroups: [ambiguous])
        ]

        for detection in results {
            #expect(throws: FolderCompareVerifiedMovePlanningError.selectionContainsUnverifiedPath) {
                try FolderCompareVerifiedMovePlanner().plan(
                    visibleNodes: nodes,
                    renameDetectionResult: detection,
                    selectedIDs: ["new.txt"],
                    targetSide: .right
                )
            }
        }

        #expect(throws: FolderCompareVerifiedMovePlanningError.duplicateComparisonPath) {
            try FolderCompareVerifiedMovePlanner().plan(
                visibleNodes: nodes,
                operationSupportNodes: [node("new.txt", left: .directory, status: .leftOnly)],
                renameDetectionResult: result(matches: [valid]),
                selectedIDs: ["new.txt"],
                targetSide: .right
            )
        }
    }

    @Test("Only matches touched by the exact selection enter the transaction")
    func selectsExactMatchesDeterministically() throws {
        let nodes = [
            node("a-new.txt", left: .file, status: .leftOnly),
            node("a-old.txt", right: .file, status: .rightOnly),
            node("z-new.txt", left: .file, status: .leftOnly),
            node("z-old.txt", right: .file, status: .rightOnly)
        ]
        let detection = result(matches: [
            match(left: "z-new.txt", right: "z-old.txt", digest: String(repeating: "b", count: 64)),
            match(left: "a-new.txt", right: "a-old.txt")
        ])
        let planner = FolderCompareVerifiedMovePlanner()

        let one = try planner.plan(
            visibleNodes: nodes.reversed(),
            renameDetectionResult: detection,
            selectedIDs: ["z-old.txt"],
            targetSide: .right
        )
        #expect(one.plan.actions.map(\.sourceRelativePath) == ["z-old.txt"])

        let both = try planner.plan(
            visibleNodes: nodes,
            renameDetectionResult: detection,
            selectedIDs: ["z-new.txt", "a-old.txt"],
            targetSide: .right
        )
        #expect(both.plan.actions.map(\.sourceRelativePath) == ["a-old.txt", "z-old.txt"])
        #expect(both.plan.summary.moveCount == 2)
    }

    @Test("The planned transaction executes through the durable journal")
    func executesAndJournalsDirectMove() async throws {
        let fixture = try MoveFixture(contents: ["one.txt": "first payload"])
        defer { fixture.remove() }
        let detection = try await LocalFolderRenameDetector().detect(nodes: fixture.nodes)
        let planned = try FolderCompareVerifiedMovePlanner().plan(
            visibleNodes: fixture.nodes,
            renameDetectionResult: detection,
            selectedIDs: ["new/one.txt"],
            targetSide: .right
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)

        let dryRun = try await JournaledLocalFolderSyncExecutor(journalStore: store).execute(
            plan: planned.plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: true, allowHighRisk: true)
        )
        #expect(dryRun.status == .dryRun)
        #expect(fixture.exists("old/one.txt", in: fixture.right))
        #expect(!fixture.exists("new/one.txt", in: fixture.right))

        let applied = try await JournaledLocalFolderSyncExecutor(journalStore: store).execute(
            plan: planned.plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: false, allowHighRisk: true)
        )

        #expect(applied.status == .completed)
        #expect(!fixture.exists("old/one.txt", in: fixture.right))
        #expect(try fixture.read("new/one.txt", in: fixture.right) == "first payload")
        let journal = try #require(try await store.listActive().first)
        #expect(journal.status == .completed)
        #expect(journal.steps.map(\.actionKind) == [.move])
        #expect(journal.steps.map(\.status) == [.completed])
    }

    @Test("A later direct-move failure reverses every earlier move")
    func laterFailureRollsBackWholePlan() async throws {
        let fixture = try MoveFixture(contents: [
            "one.txt": "first payload",
            "two.txt": "second payload"
        ])
        defer { fixture.remove() }
        let detection = try await LocalFolderRenameDetector().detect(nodes: fixture.nodes)
        let planned = try FolderCompareVerifiedMovePlanner().plan(
            visibleNodes: fixture.nodes,
            renameDetectionResult: detection,
            selectedIDs: ["new/one.txt", "new/two.txt"],
            targetSide: .right
        )
        #expect(planned.plan.actions.map(\.kind) == [.move, .move])

        let store = OperationJournalStore(directoryURL: fixture.journals)
        let applied = try await JournaledLocalFolderSyncExecutor(
            journalStore: store,
            testingExecutorFailureAtActionIndex: 1
        ).execute(
            plan: planned.plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: false, allowHighRisk: true)
        )

        #expect(applied.status == .failedRolledBack)
        #expect(fixture.exists("old/one.txt", in: fixture.right))
        #expect(fixture.exists("old/two.txt", in: fixture.right))
        #expect(!fixture.exists("new/one.txt", in: fixture.right))
        #expect(!fixture.exists("new/two.txt", in: fixture.right))
        let journal = try #require(try await store.listActive().first)
        #expect(journal.status == .rolledBack)
        #expect(journal.steps.map(\.status) == [.rolledBack, .failed])
    }

    @Test("Cancellation after installation restores the direct-move source and journals rollback")
    func cancellationRollsBackAndJournals() async throws {
        let fixture = try MoveFixture(contents: ["one.txt": "cancelled payload"])
        defer { fixture.remove() }
        let detection = try await LocalFolderRenameDetector().detect(nodes: fixture.nodes)
        let planned = try FolderCompareVerifiedMovePlanner().plan(
            visibleNodes: fixture.nodes,
            renameDetectionResult: detection,
            selectedIDs: ["new/one.txt"],
            targetSide: .right
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)

        let applied = try await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
            point == .afterInstall ? .cancel : .proceed
        }) {
            try await JournaledLocalFolderSyncExecutor(journalStore: store).execute(
                plan: planned.plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false, allowHighRisk: true)
            )
        }

        #expect(applied.status == .failedRolledBack)
        #expect(applied.issues.first?.code == .cancelled)
        #expect(try fixture.read("old/one.txt", in: fixture.right) == "cancelled payload")
        #expect(!fixture.exists("new/one.txt", in: fixture.right))
        let journal = try #require(try await store.listActive().first)
        #expect(journal.status == .rolledBack)
        let step = try #require(journal.steps.first)
        #expect(step.status == .failed)
        #expect(step.sourceAfterState?.kind == .regularFile)
        #expect(step.afterState == .missing)
    }

    @Test("A stale later proof refuses the whole plan before its first write")
    func staleProofRefusesBeforeWriting() async throws {
        let fixture = try MoveFixture(contents: [
            "one.txt": "first payload",
            "two.txt": "second payload"
        ])
        defer { fixture.remove() }
        let detection = try await LocalFolderRenameDetector().detect(nodes: fixture.nodes)
        let planned = try FolderCompareVerifiedMovePlanner().plan(
            visibleNodes: fixture.nodes,
            renameDetectionResult: detection,
            selectedIDs: ["new/one.txt", "new/two.txt"],
            targetSide: .right
        )
        try Data("changed after confirmation".utf8).write(
            to: fixture.left.appending(path: "new/two.txt")
        )

        let applied = await LocalFolderSyncExecutor().execute(
            plan: planned.plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: false, allowHighRisk: true)
        )

        #expect(applied.status == .refused)
        #expect(fixture.exists("old/one.txt", in: fixture.right))
        #expect(fixture.exists("old/two.txt", in: fixture.right))
        #expect(!fixture.exists("new/one.txt", in: fixture.right))
        #expect(!fixture.exists("new/two.txt", in: fixture.right))
    }
}

private let testByteCount: UInt64 = 10
private let testDigest = String(repeating: "a", count: 64)

private func node(
    _ path: String,
    left leftKind: ResourceEntry.Kind? = nil,
    right rightKind: ResourceEntry.Kind? = nil,
    status: PairNode.Status
) -> PairNode {
    PairNode(
        relativePath: path,
        left: leftKind.map { entry(path, side: .left, kind: $0) },
        right: rightKind.map { entry(path, side: .right, kind: $0) },
        status: status
    )
}

private func entry(
    _ path: String,
    side: FolderSyncSide,
    kind: ResourceEntry.Kind
) -> ResourceEntry {
    ResourceEntry(
        locator: ResourceLocator(providerID: "test", path: "/\(side.rawValue)/\(path)"),
        relativePath: path,
        kind: kind,
        byteCount: kind == .file ? Int64(testByteCount) : nil,
        modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func match(
    left: String,
    right: String,
    digest: String = testDigest
) -> FolderRenameMatch {
    FolderRenameMatch(
        leftRelativePath: left,
        rightRelativePath: right,
        byteCount: testByteCount,
        digest: digest
    )
}

private func result(
    matches: [FolderRenameMatch],
    ambiguousGroups: [FolderRenameAmbiguousGroup] = []
) -> FolderRenameDetectionResult {
    FolderRenameDetectionResult(
        matches: matches,
        ambiguousGroups: ambiguousGroups,
        eligibleCandidateCount: matches.count * 2,
        hashedCandidateCount: matches.count * 2,
        hashedByteCount: UInt64(matches.count) * testByteCount * 2,
        unmatchedCandidateCount: 0
    )
}

private final class MoveFixture: @unchecked Sendable {
    let root: URL
    let left: URL
    let right: URL
    let backup: URL
    let journals: URL
    let nodes: [PairNode]

    init(contents: [String: String]) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "RiffaFolderCompareMoveTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        left = root.appending(path: "left", directoryHint: .isDirectory)
        right = root.appending(path: "right", directoryHint: .isDirectory)
        backup = root.appending(path: "backup", directoryHint: .isDirectory)
        journals = root.appending(path: "journals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: left.appending(path: "new", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: right.appending(path: "old", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: right.appending(path: "new", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)

        var builtNodes: [PairNode] = [
            PairNode(
                relativePath: "new",
                left: Self.entry(at: left, path: "new", kind: .directory),
                right: Self.entry(at: right, path: "new", kind: .directory),
                status: .same
            ),
            PairNode(
                relativePath: "old",
                left: nil,
                right: Self.entry(at: right, path: "old", kind: .directory),
                status: .rightOnly
            )
        ]
        for name in contents.keys.sorted() {
            let payload = try #require(contents[name])
            try Data(payload.utf8).write(to: left.appending(path: "new/\(name)"))
            try Data(payload.utf8).write(to: right.appending(path: "old/\(name)"))
            builtNodes.append(PairNode(
                relativePath: "new/\(name)",
                left: Self.entry(at: left, path: "new/\(name)", kind: .file),
                right: nil,
                status: .leftOnly
            ))
            builtNodes.append(PairNode(
                relativePath: "old/\(name)",
                left: nil,
                right: Self.entry(at: right, path: "old/\(name)", kind: .file),
                status: .rightOnly
            ))
        }
        nodes = builtNodes
    }

    func exists(_ path: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    func read(_ path: String, in root: URL) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func entry(
        at root: URL,
        path: String,
        kind: ResourceEntry.Kind
    ) -> ResourceEntry {
        let url = root.appending(path: path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ResourceEntry(
            locator: ResourceLocator(fileURL: url),
            relativePath: path,
            kind: kind,
            byteCount: (attributes?[.size] as? NSNumber)?.int64Value,
            modificationDate: attributes?[.modificationDate] as? Date
        )
    }
}
