import Foundation
import Testing
@testable import RiffaCore

@Test("Update right copies source-only items, replaces differences, and preserves target-only items")
func updateRightPlansNonDestructiveChanges() {
    let nodes = [
        syncNode("folder/file.txt", left: .file, status: .leftOnly),
        syncNode("same.txt", left: .file, right: .file, status: .same),
        syncNode("folder", left: .directory, status: .leftOnly),
        syncNode("different.txt", left: .file, right: .file, status: .different),
        syncNode("right-only.txt", right: .file, status: .rightOnly)
    ]

    let plan = FolderSyncPlanner().plan(nodes: nodes, mode: .updateRight)

    #expect(plan.actions.map(\.kind) == [.createDirectory, .copy, .replace, .noOp, .noOp])
    #expect(plan.actions.first?.targetRelativePath == "folder")
    #expect(action(at: "folder/file.txt", in: plan)?.sourceSide == .left)
    #expect(action(at: "folder/file.txt", in: plan)?.targetSide == .right)
    #expect(action(at: "different.txt", in: plan)?.reason == .contentDiffers)
    #expect(action(at: "different.txt", in: plan)?.risk == .medium)
    #expect(action(at: "right-only.txt", in: plan)?.kind == .noOp)
    #expect(action(at: "right-only.txt", in: plan)?.reason == .targetOnlyPreserved)
    #expect(plan.summary.actionableCount == 3)
    #expect(plan.summary.copyCount == 1)
    #expect(plan.summary.createDirectoryCount == 1)
    #expect(plan.summary.replaceCount == 1)
    #expect(plan.summary.noOpCount == 2)
    #expect(!plan.summary.hasHighRiskActions)
}

@Test("Update left reverses the source and target orientation")
func updateLeftUsesRightAsSource() {
    let nodes = [
        syncNode("left-only.txt", left: .file, status: .leftOnly),
        syncNode("right-only.txt", right: .file, status: .rightOnly),
        syncNode("different.txt", left: .file, right: .file, status: .different)
    ]

    let plan = FolderSyncPlanner().plan(nodes: nodes, mode: .updateLeft)

    #expect(action(at: "left-only.txt", in: plan)?.kind == .noOp)
    #expect(action(at: "right-only.txt", in: plan)?.kind == .copy)
    #expect(action(at: "right-only.txt", in: plan)?.sourceSide == .right)
    #expect(action(at: "right-only.txt", in: plan)?.targetSide == .left)
    #expect(action(at: "different.txt", in: plan)?.kind == .replace)
    #expect(action(at: "different.txt", in: plan)?.sourceSide == .right)
}

@Test("Bidirectional update copies unique items but reports divergent pairs as conflicts")
func updateBothDoesNotGuessAtDivergentContent() {
    let issue = ResourceIssue(path: "broken.txt", message: "Unreadable")
    let nodes = [
        syncNode("left.txt", left: .file, status: .leftOnly),
        syncNode("right.txt", right: .file, status: .rightOnly),
        syncNode("different.txt", left: .file, right: .file, status: .different),
        syncNode("types", left: .file, right: .directory, status: .typeMismatch),
        PairNode(relativePath: "broken.txt", left: nil, right: nil, status: .error, issues: [issue])
    ]

    let plan = FolderSyncPlanner().plan(nodes: nodes, mode: .updateBoth)

    #expect(action(at: "left.txt", in: plan)?.kind == .copy)
    #expect(action(at: "left.txt", in: plan)?.sourceSide == .left)
    #expect(action(at: "right.txt", in: plan)?.kind == .copy)
    #expect(action(at: "right.txt", in: plan)?.sourceSide == .right)
    #expect(action(at: "different.txt", in: plan)?.kind == .conflict)
    #expect(action(at: "different.txt", in: plan)?.reason == .bothSidesDiffer)
    #expect(action(at: "types", in: plan)?.kind == .conflict)
    #expect(action(at: "types", in: plan)?.reason == .typeMismatch)
    #expect(action(at: "broken.txt", in: plan)?.issues == [issue])
    #expect(plan.summary.copyCount == 2)
    #expect(plan.summary.conflictCount == 3)
    #expect(plan.summary.hasConflicts)
}

@Test("Type mismatches are conflicts in every synchronization mode")
func typeMismatchesRemainConflicts() {
    let node = syncNode("item", left: .file, right: .directory, status: .typeMismatch)

    for mode in FolderSyncMode.allCases {
        let plan = FolderSyncPlanner().plan(nodes: [node], mode: mode)
        #expect(plan.actions.count == 1)
        #expect(plan.actions.first?.kind == .conflict)
        #expect(plan.actions.first?.reason == .typeMismatch)
        #expect(plan.actions.first?.risk == .high)
    }
}

@Test("Mirror deletes target-only children before parents and marks every deletion high risk")
func mirrorDeletionOrderIsSafeAndExplicit() {
    let nodes = [
        syncNode("obsolete", right: .directory, status: .rightOnly),
        syncNode("obsolete/deep", right: .directory, status: .rightOnly),
        syncNode("obsolete/deep/file.txt", right: .file, status: .rightOnly),
        syncNode("new", left: .directory, status: .leftOnly),
        syncNode("new/file.txt", left: .file, status: .leftOnly)
    ]

    let plan = FolderSyncPlanner().plan(nodes: nodes, mode: .mirrorLeftToRight)
    let deletionPaths = plan.actions
        .filter { $0.kind == .delete }
        .compactMap(\.targetRelativePath)

    #expect(plan.actions.map(\.kind) == [.createDirectory, .copy, .delete, .delete, .delete])
    #expect(deletionPaths == ["obsolete/deep/file.txt", "obsolete/deep", "obsolete"])
    #expect(plan.actions.filter { $0.kind == .delete }.allSatisfy { $0.risk == .high })
    #expect(plan.actions.filter { $0.kind == .delete }.allSatisfy { $0.reason == .mirrorRemovesTargetOnly })
    #expect(plan.summary.deleteCount == 3)
    #expect(plan.summary.highRiskCount == 3)
    #expect(plan.summary.hasHighRiskActions)
}

@Test("Right-to-left mirror uses the left side as the deletion target")
func mirrorRightToLeftReversesDeletionTarget() {
    let nodes = [
        syncNode("left-only.txt", left: .file, status: .leftOnly),
        syncNode("right-only.txt", right: .file, status: .rightOnly)
    ]

    let plan = FolderSyncPlanner().plan(nodes: nodes, mode: .mirrorRightToLeft)

    #expect(action(at: "left-only.txt", in: plan)?.kind == .delete)
    #expect(action(at: "left-only.txt", in: plan)?.targetSide == .left)
    #expect(action(at: "right-only.txt", in: plan)?.kind == .copy)
    #expect(action(at: "right-only.txt", in: plan)?.targetSide == .left)
}

@Test("Planning is deterministic regardless of comparison row order")
func planningOrderIsDeterministic() {
    let nodes = [
        syncNode("z/file.txt", left: .file, status: .leftOnly),
        syncNode("a/deep/file.txt", right: .file, status: .rightOnly),
        syncNode("a", left: .directory, status: .leftOnly),
        syncNode("m.txt", left: .file, right: .file, status: .different),
        syncNode("z", left: .directory, status: .leftOnly),
        syncNode("a/deep", right: .directory, status: .rightOnly)
    ]
    let planner = FolderSyncPlanner()

    let forward = planner.plan(nodes: nodes, mode: .mirrorLeftToRight)
    let reversed = planner.plan(nodes: nodes.reversed(), mode: .mirrorLeftToRight)

    #expect(forward == reversed)
    #expect(forward.actions.map(\.targetRelativePath) == [
        "a", "z", "z/file.txt", "m.txt", "a/deep/file.txt", "a/deep"
    ])
}

@Test("Left-to-right mirror folds a verified rename into a proved target-side move")
func mirrorLeftToRightFoldsVerifiedRename() {
    let nodes = [
        syncNode("new", left: .directory, status: .leftOnly),
        syncNode("new/moved.txt", left: .file, status: .leftOnly),
        syncNode("copy.txt", left: .file, status: .leftOnly),
        syncNode("changed.txt", left: .file, right: .file, status: .different),
        syncNode("old", right: .directory, status: .rightOnly),
        syncNode("old/moved.txt", right: .file, status: .rightOnly)
    ]
    let result = renameResult(matches: [
        renameMatch(left: "new/moved.txt", right: "old/moved.txt")
    ])

    let plan = FolderSyncPlanner().plan(
        nodes: nodes,
        mode: .mirrorLeftToRight,
        renameDetectionResult: result
    )

    #expect(plan.actions.map(\.kind) == [.createDirectory, .move, .copy, .replace, .delete])
    let move = plan.actions.first { $0.kind == .move }
    #expect(move?.sourceSide == .right)
    #expect(move?.targetSide == .right)
    #expect(move?.sourceRelativePath == "old/moved.txt")
    #expect(move?.targetRelativePath == "new/moved.txt")
    #expect(move?.reason == .renameMatchMovedWithinTarget)
    #expect(move?.risk == .high)
    #expect(move?.moveProof == FolderSyncMoveProof(
        referenceSide: .left,
        referenceRelativePath: "new/moved.txt",
        expectedByteCount: 10,
        expectedSHA256Digest: testSHA256
    ))
    #expect(plan.summary.totalCount == 5)
    #expect(plan.summary.actionableCount == 5)
    #expect(plan.summary.createDirectoryCount == 1)
    #expect(plan.summary.moveCount == 1)
    #expect(plan.summary.copyCount == 1)
    #expect(plan.summary.replaceCount == 1)
    #expect(plan.summary.deleteCount == 1)
    #expect(plan.summary.highRiskCount == 2)
    #expect(plan.summary.hasHighRiskActions)
    requireFolderSyncSendable(move)
    requireFolderSyncSendable(plan)
}

@Test("Right-to-left mirror reverses the same-root move and proof reference")
func mirrorRightToLeftFoldsVerifiedRename() {
    let nodes = [
        syncNode("old-name.txt", left: .file, status: .leftOnly),
        syncNode("new-name.txt", right: .file, status: .rightOnly)
    ]
    let result = renameResult(matches: [
        renameMatch(left: "old-name.txt", right: "new-name.txt")
    ])

    let plan = FolderSyncPlanner().plan(
        nodes: nodes,
        mode: .mirrorRightToLeft,
        renameDetectionResult: result
    )

    #expect(plan.actions.count == 1)
    #expect(plan.actions.first?.kind == .move)
    #expect(plan.actions.first?.sourceSide == .left)
    #expect(plan.actions.first?.targetSide == .left)
    #expect(plan.actions.first?.sourceRelativePath == "old-name.txt")
    #expect(plan.actions.first?.targetRelativePath == "new-name.txt")
    #expect(plan.actions.first?.moveProof?.referenceSide == .right)
    #expect(plan.actions.first?.moveProof?.referenceRelativePath == "new-name.txt")
    #expect(plan.summary.moveCount == 1)
    #expect(plan.summary.copyCount == 0)
    #expect(plan.summary.deleteCount == 0)
    #expect(plan.summary.highRiskCount == 1)
    #expect(plan.summary.hasHighRiskActions)
}

@Test("Update modes never fold rename matches")
func updateModesIgnoreRenameDetectionForMoves() {
    let nodes = [
        syncNode("new.txt", left: .file, status: .leftOnly),
        syncNode("old.txt", right: .file, status: .rightOnly)
    ]
    let result = renameResult(matches: [renameMatch(left: "new.txt", right: "old.txt")])

    for mode in [FolderSyncMode.updateLeft, .updateRight, .updateBoth] {
        let baseline = FolderSyncPlanner().plan(nodes: nodes, mode: mode)
        let withDetection = FolderSyncPlanner().plan(
            nodes: nodes,
            mode: mode,
            renameDetectionResult: result
        )
        #expect(withDetection == baseline)
        #expect(withDetection.summary.moveCount == 0)
    }
}

@Test("Malformed, duplicate, ambiguous, and stale rename claims fail safe")
func invalidRenameClaimsDoNotFoldMoves() {
    let nodes = [
        syncNode("new.txt", left: .file, status: .leftOnly),
        syncNode("old.txt", right: .file, status: .rightOnly)
    ]
    let validMatch = renameMatch(left: "new.txt", right: "old.txt")
    let malformedDigest = FolderRenameMatch(
        leftRelativePath: "new.txt",
        rightRelativePath: "old.txt",
        byteCount: 10,
        digest: String(repeating: "A", count: 64)
    )
    let wrongByteCount = FolderRenameMatch(
        leftRelativePath: "new.txt",
        rightRelativePath: "old.txt",
        byteCount: 11,
        digest: testSHA256
    )
    let ambiguous = FolderRenameAmbiguousGroup(
        leftRelativePaths: ["new.txt"],
        rightRelativePaths: ["old.txt", "another-old.txt"],
        byteCount: 10,
        digest: testSHA256
    )
    let results = [
        renameResult(matches: [malformedDigest]),
        renameResult(matches: [wrongByteCount]),
        renameResult(matches: [validMatch, validMatch]),
        renameResult(matches: [validMatch], ambiguousGroups: [ambiguous])
    ]

    let baseline = FolderSyncPlanner().plan(nodes: nodes, mode: .mirrorLeftToRight)
    for result in results {
        let plan = FolderSyncPlanner().plan(
            nodes: nodes,
            mode: .mirrorLeftToRight,
            renameDetectionResult: result
        )
        #expect(plan == baseline)
        #expect(plan.summary.moveCount == 0)
    }

    let repeatedContentNodes = nodes + [
        syncNode("second-new.txt", left: .file, status: .leftOnly),
        syncNode("second-old.txt", right: .file, status: .rightOnly)
    ]
    let repeatedContentResult = renameResult(matches: [
        validMatch,
        renameMatch(left: "second-new.txt", right: "second-old.txt")
    ])
    let repeatedContentPlan = FolderSyncPlanner().plan(
        nodes: repeatedContentNodes,
        mode: .mirrorLeftToRight,
        renameDetectionResult: repeatedContentResult
    )
    #expect(repeatedContentPlan.summary.moveCount == 0)
    #expect(repeatedContentPlan.summary.copyCount == 2)
    #expect(repeatedContentPlan.summary.deleteCount == 2)

    let digestAmbiguity = FolderRenameAmbiguousGroup(
        leftRelativePaths: ["unrelated-new.txt"],
        rightRelativePaths: ["unrelated-old.txt"],
        byteCount: 10,
        digest: testSHA256
    )
    let digestAmbiguousPlan = FolderSyncPlanner().plan(
        nodes: nodes,
        mode: .mirrorLeftToRight,
        renameDetectionResult: renameResult(
            matches: [validMatch],
            ambiguousGroups: [digestAmbiguity]
        )
    )
    #expect(digestAmbiguousPlan.summary.moveCount == 0)

    let issue = ResourceIssue(path: "new.txt", message: "Stale comparison row")
    let staleNodes = [
        PairNode(
            relativePath: "new.txt",
            left: syncEntry("new.txt", side: .left, kind: .file),
            right: nil,
            status: .leftOnly,
            issues: [issue]
        ),
        syncNode("old.txt", right: .file, status: .rightOnly)
    ]
    let stalePlan = FolderSyncPlanner().plan(
        nodes: staleNodes,
        mode: .mirrorLeftToRight,
        renameDetectionResult: renameResult(matches: [validMatch])
    )
    #expect(stalePlan.summary.moveCount == 0)
    #expect(stalePlan.actions.contains { $0.kind == .conflict })

    let directoryNodes = [
        syncNode("new.txt", left: .directory, status: .leftOnly),
        syncNode("old.txt", right: .file, status: .rightOnly)
    ]
    let directoryPlan = FolderSyncPlanner().plan(
        nodes: directoryNodes,
        mode: .mirrorLeftToRight,
        renameDetectionResult: renameResult(matches: [validMatch])
    )
    #expect(directoryPlan.summary.moveCount == 0)
    #expect(directoryPlan.actions.map(\.kind) == [.createDirectory, .delete])

    let unsafeNodes = [
        syncNode("../new.txt", left: .file, status: .leftOnly),
        syncNode("old.txt", right: .file, status: .rightOnly)
    ]
    let unsafePlan = FolderSyncPlanner().plan(
        nodes: unsafeNodes,
        mode: .mirrorLeftToRight,
        renameDetectionResult: renameResult(matches: [
            renameMatch(left: "../new.txt", right: "old.txt")
        ])
    )
    #expect(unsafePlan.summary.moveCount == 0)

    let ancestorNodes = [
        syncNode("nested", left: .file, status: .leftOnly),
        syncNode("nested/old.txt", right: .file, status: .rightOnly)
    ]
    let ancestorPlan = FolderSyncPlanner().plan(
        nodes: ancestorNodes,
        mode: .mirrorLeftToRight,
        renameDetectionResult: renameResult(matches: [
            renameMatch(left: "nested", right: "nested/old.txt")
        ])
    )
    #expect(ancestorPlan.summary.moveCount == 0)
}

@Test("Move folding is deterministic across node and match order")
func moveFoldingOrderIsDeterministic() {
    let nodes = [
        syncNode("z-new.txt", left: .file, status: .leftOnly),
        syncNode("a-old.txt", right: .file, status: .rightOnly),
        syncNode("a-new.txt", left: .file, status: .leftOnly),
        syncNode("z-old.txt", right: .file, status: .rightOnly)
    ]
    let matches = [
        renameMatch(left: "z-new.txt", right: "z-old.txt", digest: String(repeating: "b", count: 64)),
        renameMatch(left: "a-new.txt", right: "a-old.txt")
    ]
    let planner = FolderSyncPlanner()

    let forward = planner.plan(
        nodes: nodes,
        mode: .mirrorLeftToRight,
        renameDetectionResult: renameResult(matches: matches)
    )
    let reversed = planner.plan(
        nodes: nodes.reversed(),
        mode: .mirrorLeftToRight,
        renameDetectionResult: renameResult(matches: matches.reversed())
    )

    #expect(forward == reversed)
    #expect(forward.actions.map(\.kind) == [.move, .move])
    #expect(forward.actions.map(\.targetRelativePath) == ["a-new.txt", "z-new.txt"])
    #expect(forward.summary.moveCount == 2)
}

@Test("Non-move actions cannot retain move proof")
func nonMoveActionsDiscardMoveProof() {
    let proof = FolderSyncMoveProof(
        referenceSide: .left,
        referenceRelativePath: "reference.txt",
        expectedByteCount: 10,
        expectedSHA256Digest: testSHA256
    )
    let action = FolderSyncAction(
        kind: .copy,
        sourceSide: .left,
        targetSide: .right,
        sourceRelativePath: "source.txt",
        targetRelativePath: "target.txt",
        reason: .sourceOnly,
        risk: .low,
        moveProof: proof
    )

    #expect(action.moveProof == nil)
    requireFolderSyncSendable(proof)
    requireFolderSyncSendable(action)
}

private func action(at path: String, in plan: FolderSyncPlan) -> FolderSyncAction? {
    plan.actions.first { ($0.targetRelativePath ?? $0.sourceRelativePath) == path }
}

private func syncNode(
    _ path: String,
    left leftKind: ResourceEntry.Kind? = nil,
    right rightKind: ResourceEntry.Kind? = nil,
    status: PairNode.Status
) -> PairNode {
    PairNode(
        relativePath: path,
        left: leftKind.map { syncEntry(path, side: .left, kind: $0) },
        right: rightKind.map { syncEntry(path, side: .right, kind: $0) },
        status: status
    )
}

private func syncEntry(
    _ path: String,
    side: FolderSyncSide,
    kind: ResourceEntry.Kind
) -> ResourceEntry {
    ResourceEntry(
        locator: ResourceLocator(providerID: "test", path: "/\(side.rawValue)/\(path)"),
        relativePath: path,
        kind: kind,
        byteCount: kind == .file ? 10 : nil,
        modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private let testSHA256 = String(repeating: "a", count: 64)

private func renameMatch(
    left: String,
    right: String,
    digest: String = testSHA256
) -> FolderRenameMatch {
    FolderRenameMatch(
        leftRelativePath: left,
        rightRelativePath: right,
        byteCount: 10,
        digest: digest
    )
}

private func renameResult<S: Sequence>(
    matches: S,
    ambiguousGroups: [FolderRenameAmbiguousGroup] = []
) -> FolderRenameDetectionResult where S.Element == FolderRenameMatch {
    let matches = Array(matches)
    return FolderRenameDetectionResult(
        matches: matches,
        ambiguousGroups: ambiguousGroups,
        eligibleCandidateCount: matches.count * 2,
        hashedCandidateCount: matches.count * 2,
        hashedByteCount: UInt64(matches.count * 20),
        unmatchedCandidateCount: 0
    )
}

private func requireFolderSyncSendable<T: Sendable>(_: T) {}
