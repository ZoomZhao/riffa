import Foundation

/// A fail-closed reason why Folder Compare cannot turn the current selection
/// into direct, same-root verified moves.
public enum FolderCompareVerifiedMovePlanningError: Error, Equatable, Sendable {
    case selectionRequired
    case duplicateComparisonPath
    case selectionContainsUnverifiedPath
    case destinationParentRequiresCreation
}

extension FolderCompareVerifiedMovePlanningError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .selectionRequired:
            "Select at least one verified move match first."
        case .duplicateComparisonPath:
            "The comparison contains duplicate paths, so no direct move can be planned safely."
        case .selectionContainsUnverifiedPath:
            "Every selected row must belong to exactly one current, unique, verified move match."
        case .destinationParentRequiresCreation:
            "A selected move needs a destination parent that does not yet exist on the target side. Create it first or use Folder Sync."
        }
    }
}

/// The exact transaction Folder Compare may offer after rename detection.
///
/// The plan contains only target-side moves. It never carries over directory
/// creations, mirror deletions, copies, replacements, conflicts, or unrelated
/// rows. Destination parents must already exist so the entire descriptor-backed
/// move plan can be preflighted without any preliminary writes.
public struct FolderCompareVerifiedMovePlanningResult: Hashable, Sendable {
    public let targetSide: FolderSyncSide
    public let selectedPathCount: Int
    public let selectedMatchCount: Int
    public let plan: FolderSyncPlan

    public init(
        targetSide: FolderSyncSide,
        selectedPathCount: Int,
        selectedMatchCount: Int,
        plan: FolderSyncPlan
    ) {
        self.targetSide = targetSide
        self.selectedPathCount = selectedPathCount
        self.selectedMatchCount = selectedMatchCount
        self.plan = plan
    }
}

/// Builds a minimal direct-move transaction from Folder Compare's current,
/// verified rename-detection result.
///
/// `FolderSyncPlanner` remains the owner of all match validation. This adapter
/// deliberately consumes only move actions that survived those strict checks,
/// so malformed, duplicated, stale, or ambiguous public detector data can
/// never become an executable action here.
public struct FolderCompareVerifiedMovePlanner: Sendable {
    public init() {}

    public func plan(
        visibleNodes: [PairNode],
        operationSupportNodes: [PairNode] = [],
        renameDetectionResult: FolderRenameDetectionResult,
        selectedIDs: Set<PairNode.ID>,
        targetSide: FolderSyncSide
    ) throws -> FolderCompareVerifiedMovePlanningResult {
        guard !selectedIDs.isEmpty else {
            throw FolderCompareVerifiedMovePlanningError.selectionRequired
        }

        let visibleIDs = Set(visibleNodes.map(\.id))
        guard selectedIDs.isSubset(of: visibleIDs) else {
            throw FolderCompareVerifiedMovePlanningError.selectionContainsUnverifiedPath
        }

        let allNodes = visibleNodes + operationSupportNodes
        guard Set(allNodes.map(\.id)).count == allNodes.count else {
            throw FolderCompareVerifiedMovePlanningError.duplicateComparisonPath
        }

        let mode: FolderSyncMode = switch targetSide {
        case .left: .mirrorRightToLeft
        case .right: .mirrorLeftToRight
        }
        let fullMirrorPlan = FolderSyncPlanner().plan(
            nodes: allNodes,
            mode: mode,
            renameDetectionResult: renameDetectionResult
        )

        let moveIndices = fullMirrorPlan.actions.indices.filter {
            fullMirrorPlan.actions[$0].kind == .move
        }
        var moveIndicesByVisiblePath: [String: [Int]] = [:]
        moveIndicesByVisiblePath.reserveCapacity(moveIndices.count * 2)
        for index in moveIndices {
            let action = fullMirrorPlan.actions[index]
            if let sourcePath = action.sourceRelativePath {
                moveIndicesByVisiblePath[sourcePath, default: []].append(index)
            }
            if let targetPath = action.targetRelativePath {
                moveIndicesByVisiblePath[targetPath, default: []].append(index)
            }
        }

        var selectedMoveIndices: Set<Int> = []
        selectedMoveIndices.reserveCapacity(selectedIDs.count)
        for selectedID in selectedIDs {
            guard let indices = moveIndicesByVisiblePath[selectedID],
                  indices.count == 1,
                  let index = indices.first else {
                throw FolderCompareVerifiedMovePlanningError.selectionContainsUnverifiedPath
            }
            selectedMoveIndices.insert(index)
        }

        guard !selectedMoveIndices.isEmpty else {
            throw FolderCompareVerifiedMovePlanningError.selectionContainsUnverifiedPath
        }

        let destinationPaths = selectedMoveIndices.compactMap {
            fullMirrorPlan.actions[$0].targetRelativePath
        }
        let requiresDirectoryCreation = fullMirrorPlan.actions.indices.contains { index in
            let action = fullMirrorPlan.actions[index]
            guard action.kind == .createDirectory,
                  action.targetSide == targetSide,
                  let directoryPath = action.targetRelativePath else {
                return false
            }
            return destinationPaths.contains {
                Self.isStrictAncestor(directoryPath, of: $0)
            }
        }
        guard !requiresDirectoryCreation else {
            throw FolderCompareVerifiedMovePlanningError.destinationParentRequiresCreation
        }

        let actions: [FolderSyncAction] = fullMirrorPlan.actions.indices.compactMap { index in
            guard selectedMoveIndices.contains(index) else {
                return nil
            }
            return fullMirrorPlan.actions[index]
        }
        let plan = FolderSyncPlan(mode: mode, actions: actions)
        return FolderCompareVerifiedMovePlanningResult(
            targetSide: targetSide,
            selectedPathCount: selectedIDs.count,
            selectedMatchCount: selectedMoveIndices.count,
            plan: plan
        )
    }

    private static func isStrictAncestor(_ candidate: String, of path: String) -> Bool {
        guard candidate.count < path.count else { return false }
        return path.hasPrefix(candidate + "/")
    }
}
