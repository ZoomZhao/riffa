import Foundation
import Testing
@testable import RiffaCore

@Suite("Selected-side folder deletion planning")
struct FolderSelectionDeletePlannerTests {
    @Test("A selected directory collapses its selected descendants")
    func selectedDirectoryCollapsesDescendants() throws {
        let nodes = [
            deleteNode("archive", right: .directory),
            deleteNode("archive/2024", right: .directory),
            deleteNode("archive/2024/report.txt", right: .file),
            deleteNode("keep.txt", right: .file)
        ]

        let plan = try FolderSelectionDeletePlanner().plan(
            nodes: nodes,
            selectedIDs: ["archive", "archive/2024", "archive/2024/report.txt", "keep.txt"],
            targetSide: .right
        )

        #expect(plan.mode == .mirrorLeftToRight)
        #expect(plan.actions.compactMap(\.targetRelativePath) == ["archive", "keep.txt"])
        #expect(plan.summary.deleteCount == 2)
        #expect(plan.summary.actionableCount == 2)
        #expect(plan.actions.allSatisfy { $0.kind == .delete })
        #expect(plan.actions.allSatisfy { $0.risk == .high })
        #expect(plan.actions.allSatisfy { $0.reason == .selectedForDeletion })
        #expect(plan.actions.allSatisfy { $0.sourceSide == nil && $0.sourceRelativePath == nil })
    }

    @Test("Active path rules forbid recursive directory deletion but permit visible files")
    func pathRulesForbidDirectoryTargets() throws {
        let directory = deleteNode("visible", right: .directory)
        let file = deleteNode("visible/file.txt", right: .file)

        #expect(throws: FolderSelectionDeletePlanningError.directoryTargetsDisallowed) {
            _ = try FolderSelectionDeletePlanner().plan(
                nodes: [directory, file],
                selectedIDs: [directory.id, file.id],
                targetSide: .right,
                allowsDirectoryTargets: false
            )
        }

        let filePlan = try FolderSelectionDeletePlanner().plan(
            nodes: [directory, file],
            selectedIDs: [file.id],
            targetSide: .right,
            allowsDirectoryTargets: false
        )
        #expect(filePlan.actions.map(\.targetRelativePath) == ["visible/file.txt"])
    }

    @Test("Rows missing on the requested target side are ignored")
    func missingTargetSideIsIgnored() throws {
        let nodes = [
            deleteNode("left-only.txt", left: .file),
            deleteNode("both.txt", left: .file, right: .file)
        ]

        let plan = try FolderSelectionDeletePlanner().plan(
            nodes: nodes,
            selectedIDs: Set(nodes.map(\.id)),
            targetSide: .right
        )

        #expect(plan.actions.map(\.targetRelativePath) == ["both.txt"])
        #expect(plan.actions.first?.targetSide == .right)
    }

    @Test("A directory present only on the other side cannot collapse a target descendant")
    func onlyTargetDirectoriesCollapseDescendants() throws {
        let nodes = [
            deleteNode("foreign-directory", left: .directory),
            deleteNode("foreign-directory/target.txt", right: .file)
        ]

        let plan = try FolderSelectionDeletePlanner().plan(
            nodes: nodes,
            selectedIDs: Set(nodes.map(\.id)),
            targetSide: .right
        )

        #expect(plan.actions.map(\.targetRelativePath) == ["foreign-directory/target.txt"])
    }

    @Test("Left-side deletion uses the left target and reverse mirror mode")
    func leftTargetOrientation() throws {
        let node = deleteNode("left.txt", left: .file)
        let plan = try FolderSelectionDeletePlanner().plan(
            nodes: [node],
            selectedIDs: [node.id],
            targetSide: .left
        )

        #expect(plan.mode == .mirrorRightToLeft)
        #expect(plan.actions.first?.targetSide == .left)
        #expect(plan.actions.first?.targetRelativePath == "left.txt")
    }

    @Test("Unicode relative paths are preserved exactly")
    func unicodePathsArePreserved() throws {
        let paths = ["资料/变更-😀.txt", "Ångström.txt", "日本語.md"]
        let nodes = paths.map { deleteNode($0, right: .file) }

        let plan = try FolderSelectionDeletePlanner().plan(
            nodes: nodes,
            selectedIDs: Set(paths),
            targetSide: .right
        )

        #expect(Set(plan.actions.compactMap(\.targetRelativePath)) == Set(paths))
        #expect(plan.actions.count == paths.count)
    }

    @Test("Empty selection and a selection with no target items fail explicitly")
    func emptyAndUnavailableSelectionsFail() {
        let leftOnly = deleteNode("left-only.txt", left: .file)

        #expect(throws: FolderSelectionDeletePlanningError.emptySelection) {
            try FolderSelectionDeletePlanner().plan(
                nodes: [leftOnly],
                selectedIDs: [],
                targetSide: .right
            )
        }

        #expect(throws: FolderSelectionDeletePlanningError.noDeletableTargets(targetSide: .right)) {
            try FolderSelectionDeletePlanner().plan(
                nodes: [leftOnly],
                selectedIDs: [leftOnly.id, "stale-selection.txt"],
                targetSide: .right
            )
        }
    }

    @Test("Planning order is deterministic and deeper deletions precede shallower ones")
    func deterministicDeletionOrder() throws {
        let nodes = [
            deleteNode("zeta.txt", right: .file),
            deleteNode("a/deep/item.txt", right: .file),
            deleteNode("alpha.txt", right: .file),
            deleteNode("alpha.txt", right: .file),
            deleteNode("b/item.txt", right: .file)
        ]
        let selectedIDs = Set(nodes.map(\.id))
        let planner = FolderSelectionDeletePlanner()

        let forward = try planner.plan(
            nodes: nodes,
            selectedIDs: selectedIDs,
            targetSide: .right
        )
        let reversed = try planner.plan(
            nodes: nodes.reversed(),
            selectedIDs: selectedIDs,
            targetSide: .right
        )

        #expect(forward == reversed)
        #expect(forward.actions.map(\.targetRelativePath) == [
            "a/deep/item.txt", "b/item.txt", "alpha.txt", "zeta.txt"
        ])
    }
}

private func deleteNode(
    _ path: String,
    left leftKind: ResourceEntry.Kind? = nil,
    right rightKind: ResourceEntry.Kind? = nil
) -> PairNode {
    let status: PairNode.Status = switch (leftKind, rightKind) {
    case (.some, .some): .different
    case (.some, .none): .leftOnly
    case (.none, .some): .rightOnly
    case (.none, .none): .error
    }
    return PairNode(
        relativePath: path,
        left: leftKind.map { deleteEntry(path, side: .left, kind: $0) },
        right: rightKind.map { deleteEntry(path, side: .right, kind: $0) },
        status: status
    )
}

private func deleteEntry(
    _ path: String,
    side: FolderSyncSide,
    kind: ResourceEntry.Kind
) -> ResourceEntry {
    ResourceEntry(
        locator: ResourceLocator(providerID: "delete-test", path: "/\(side.rawValue)/\(path)"),
        relativePath: path,
        kind: kind,
        byteCount: kind == .file ? 12 : nil
    )
}
