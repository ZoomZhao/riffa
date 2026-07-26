import Foundation

/// Failures produced before an exact selected-row copy plan can be created.
public enum FolderSelectionCopyPlanningError: Error, Equatable, Sendable, LocalizedError {
    case emptySelection
    case selectionIsNotVisible
    case noSourceItems(sourceSide: FolderSyncSide)
    case requiredParentUnavailable
    case unexpectedDeletion
    case actionOutsideVisibleSelection
    case noActionableChanges(hasConflicts: Bool)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            "Select one or more comparison rows first."
        case .selectionIsNotVisible:
            "The selection is no longer visible in the current comparison. Refresh and select the rows again."
        case let .noSourceItems(sourceSide):
            "None of the selected paths exists on the \(sourceSide.rawValue) side."
        case .requiredParentUnavailable:
            "A required source parent directory is unavailable or unsafe. No copy plan was created."
        case .unexpectedDeletion:
            "The selected copy plan unexpectedly contained a deletion and was refused."
        case .actionOutsideVisibleSelection:
            "The selected copy plan attempted to include a hidden path and was refused."
        case let .noActionableChanges(hasConflicts):
            if hasConflicts {
                "The selected source paths contain conflicts that cannot be copied safely. No files were changed."
            } else {
                "The selected source paths already match their targets; there is nothing to copy or replace."
            }
        }
    }
}

/// An exact selected-row plan and UI-facing counts derived from it.
public struct FolderSelectionCopyPlanningResult: Hashable, Sendable {
    public let plan: FolderSyncPlan
    public let selectedCount: Int
    public let sourceAvailableCount: Int
    public let skippedMissingSourceCount: Int
    public let automaticallyAddedParentCount: Int
}

/// Plans a one-way copy for visible rows. Non-public publication support is
/// consulted only for proper directory ancestors of those selected rows; it
/// can never add a hidden leaf or sibling to the resulting plan.
public struct FolderSelectionCopyPlanner: Sendable {
    public init() {}

    public func plan(
        publication: FolderComparisonPublication,
        selectedIDs: Set<PairNode.ID>,
        sourceSide: FolderSyncSide
    ) throws -> FolderSelectionCopyPlanningResult {
        try plan(
            visibleNodes: publication.visibleNodes,
            operationSupportNodes: publication.operationSupportNodes,
            selectedIDs: selectedIDs,
            sourceSide: sourceSide
        )
    }

    public func plan(
        visibleNodes: [PairNode],
        operationSupportNodes: [PairNode],
        selectedIDs: Set<PairNode.ID>,
        sourceSide: FolderSyncSide
    ) throws -> FolderSelectionCopyPlanningResult {
        guard !selectedIDs.isEmpty else {
            throw FolderSelectionCopyPlanningError.emptySelection
        }

        let selectedNodes = visibleNodes.filter {
            selectedIDs.contains($0.id)
        }
        guard !selectedNodes.isEmpty else {
            throw FolderSelectionCopyPlanningError.selectionIsNotVisible
        }

        let sourceNodes = selectedNodes.filter { entry(on: sourceSide, in: $0) != nil }
        guard !sourceNodes.isEmpty else {
            throw FolderSelectionCopyPlanningError.noSourceItems(sourceSide: sourceSide)
        }

        var nodesBySourcePath: [String: PairNode] = [:]
        for node in operationSupportNodes + visibleNodes {
            guard let source = entry(on: sourceSide, in: node) else { continue }
            nodesBySourcePath[source.relativePath] = node
        }

        var includedNodes = Dictionary(uniqueKeysWithValues: sourceNodes.map { ($0.id, $0) })
        var automaticallyAddedParentIDs = Set<PairNode.ID>()
        var permittedPaths = Set(sourceNodes.map(\.relativePath))
        let targetSide = opposite(of: sourceSide)

        for node in sourceNodes {
            guard let source = entry(on: sourceSide, in: node) else { continue }
            for parentPath in parentPaths(of: source.relativePath) {
                permittedPaths.insert(parentPath)
                guard let parentNode = nodesBySourcePath[parentPath],
                      let sourceParent = entry(on: sourceSide, in: parentNode),
                      sourceParent.kind == .directory else {
                    throw FolderSelectionCopyPlanningError.requiredParentUnavailable
                }

                let targetParent = entry(on: targetSide, in: parentNode)
                guard targetParent?.kind != .directory else { continue }
                includedNodes[parentNode.id] = parentNode
                if !selectedIDs.contains(parentNode.id) {
                    automaticallyAddedParentIDs.insert(parentNode.id)
                }
            }
        }

        let mode: FolderSyncMode = sourceSide == .left ? .updateRight : .updateLeft
        let planned = FolderSyncPlanner().plan(
            nodes: Array(includedNodes.values),
            mode: mode
        )
        guard !planned.actions.contains(where: { $0.kind == .delete }) else {
            throw FolderSelectionCopyPlanningError.unexpectedDeletion
        }
        guard planned.actions.allSatisfy({ action in
            let paths = [action.sourceRelativePath, action.targetRelativePath].compactMap { $0 }
            return paths.allSatisfy(permittedPaths.contains)
        }) else {
            throw FolderSelectionCopyPlanningError.actionOutsideVisibleSelection
        }
        guard planned.summary.actionableCount > 0 else {
            throw FolderSelectionCopyPlanningError.noActionableChanges(
                hasConflicts: planned.summary.hasConflicts
            )
        }

        return FolderSelectionCopyPlanningResult(
            plan: planned,
            selectedCount: selectedNodes.count,
            sourceAvailableCount: sourceNodes.count,
            skippedMissingSourceCount: selectedNodes.count - sourceNodes.count,
            automaticallyAddedParentCount: automaticallyAddedParentIDs.count
        )
    }

    private func entry(on side: FolderSyncSide, in node: PairNode) -> ResourceEntry? {
        switch side {
        case .left: node.left
        case .right: node.right
        }
    }

    private func opposite(of side: FolderSyncSide) -> FolderSyncSide {
        switch side {
        case .left: .right
        case .right: .left
        }
    }

    private func parentPaths(of relativePath: String) -> [String] {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count > 1 else { return [] }
        return (1..<components.count).map { count in
            components.prefix(count).joined(separator: "/")
        }
    }
}
