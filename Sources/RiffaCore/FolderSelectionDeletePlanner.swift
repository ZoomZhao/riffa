import Foundation

/// Failures produced before a selected-side deletion plan can be created.
public enum FolderSelectionDeletePlanningError: Error, Equatable, Sendable, LocalizedError {
    case emptySelection
    case noDeletableTargets(targetSide: FolderSyncSide)
    case directoryTargetsDisallowed

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            "Select one or more comparison rows before deleting."
        case let .noDeletableTargets(targetSide):
            "None of the selected paths exists on the \(targetSide.rawValue) side. No deletion plan was created."
        case .directoryTargetsDisallowed:
            "Folder deletion is disabled while path rules are active. Delete individual visible files, or disable the rules and refresh first."
        }
    }
}

/// Creates an exact, deterministic high-risk plan for deleting only explicitly
/// selected resources from one side of a folder comparison.
///
/// Selecting a target directory subsumes any selected descendants beneath it so
/// the executor never receives overlapping mutation or backup destinations.
public struct FolderSelectionDeletePlanner: Sendable {
    public init() {}

    public func plan(
        nodes: [PairNode],
        selectedIDs: Set<PairNode.ID>,
        targetSide: FolderSyncSide,
        allowsDirectoryTargets: Bool = true
    ) throws -> FolderSyncPlan {
        guard !selectedIDs.isEmpty else {
            throw FolderSelectionDeletePlanningError.emptySelection
        }

        let candidates = nodes.compactMap { node -> Candidate? in
            guard selectedIDs.contains(node.id),
                  let target = entry(on: targetSide, in: node) else {
                return nil
            }
            return Candidate(path: target.relativePath, isDirectory: target.kind == .directory)
        }

        guard !candidates.isEmpty else {
            throw FolderSelectionDeletePlanningError.noDeletableTargets(targetSide: targetSide)
        }
        guard allowsDirectoryTargets || !candidates.contains(where: \.isDirectory) else {
            throw FolderSelectionDeletePlanningError.directoryTargetsDisallowed
        }

        // A comparison normally has one row per relative path. Deduplicating here
        // keeps the planner safe and deterministic even for malformed input.
        let uniqueByPath = Dictionary(candidates.map { ($0.path, $0) }) { first, second in
            Candidate(
                path: first.path,
                isDirectory: first.isDirectory || second.isDirectory
            )
        }
        let uniqueCandidates = Array(uniqueByPath.values)
        let selectedDirectories = uniqueCandidates
            .filter(\.isDirectory)
            .map(\.path)

        let collapsed = uniqueCandidates.filter { candidate in
            !selectedDirectories.contains { directoryPath in
                directoryPath != candidate.path && isDescendant(candidate.path, of: directoryPath)
            }
        }

        let actions = collapsed
            .sorted(by: deletionOrder)
            .map { candidate in
                FolderSyncAction(
                    kind: .delete,
                    targetSide: targetSide,
                    targetRelativePath: candidate.path,
                    reason: .selectedForDeletion,
                    risk: .high
                )
            }

        return FolderSyncPlan(mode: mode(for: targetSide), actions: actions)
    }

    private func entry(on side: FolderSyncSide, in node: PairNode) -> ResourceEntry? {
        switch side {
        case .left: node.left
        case .right: node.right
        }
    }

    private func mode(for targetSide: FolderSyncSide) -> FolderSyncMode {
        switch targetSide {
        case .left: .mirrorRightToLeft
        case .right: .mirrorLeftToRight
        }
    }

    private func isDescendant(_ path: String, of directoryPath: String) -> Bool {
        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: false)
        let directoryComponents = directoryPath.split(separator: "/", omittingEmptySubsequences: false)
        guard pathComponents.count > directoryComponents.count else { return false }
        return pathComponents.prefix(directoryComponents.count).elementsEqual(directoryComponents)
    }

    private func deletionOrder(_ left: Candidate, _ right: Candidate) -> Bool {
        let leftDepth = left.path.split(separator: "/", omittingEmptySubsequences: false).count
        let rightDepth = right.path.split(separator: "/", omittingEmptySubsequences: false).count
        if leftDepth != rightDepth {
            return leftDepth > rightDepth
        }
        return left.path < right.path
    }
}

private struct Candidate: Sendable {
    let path: String
    let isDirectory: Bool
}
