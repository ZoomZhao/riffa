import Foundation

/// The side of a folder comparison involved in a synchronization action.
public enum FolderSyncSide: String, Hashable, Codable, Sendable {
    case left
    case right
}

/// The synchronization behavior to preview.
public enum FolderSyncMode: String, CaseIterable, Hashable, Codable, Sendable {
    /// Use the right side as the source, without removing left-only items.
    case updateLeft
    /// Use the left side as the source, without removing right-only items.
    case updateRight
    /// Copy unique items in both directions. Divergent pairs remain conflicts.
    case updateBoth
    /// Make the right side match the left, including high-risk deletions.
    case mirrorLeftToRight
    /// Make the left side match the right, including high-risk deletions.
    case mirrorRightToLeft
}

/// A coarse risk classification suitable for preview UI and approval gates.
public enum FolderSyncRisk: String, CaseIterable, Hashable, Codable, Sendable {
    case none
    case low
    case medium
    case high
}

/// The reason a synchronization action was proposed.
public enum FolderSyncReason: String, Hashable, Codable, Sendable {
    case alreadySame
    case sourceOnly
    case targetOnlyPreserved
    case contentDiffers
    case bothSidesDiffer
    case typeMismatch
    case comparisonError
    case mirrorRemovesTargetOnly
    case renameMatchMovedWithinTarget
    case explicitlyRenamedWithinSide
    case selectedForDeletion

    public var description: String {
        switch self {
        case .alreadySame:
            "The item already matches on both sides."
        case .sourceOnly:
            "The item exists only on the synchronization source."
        case .targetOnlyPreserved:
            "The item exists only on the target and update mode preserves it."
        case .contentDiffers:
            "The paired items differ and the target should be replaced from the source."
        case .bothSidesDiffer:
            "Both sides contain different content, so bidirectional sync cannot choose safely."
        case .typeMismatch:
            "The path represents different item types on the two sides."
        case .comparisonError:
            "The comparison could not determine a safe synchronization action."
        case .mirrorRemovesTargetOnly:
            "Mirror mode removes an item that exists only on the target."
        case .renameMatchMovedWithinTarget:
            "Mirror mode can move a verified matching file within the target instead of copying and deleting it."
        case .explicitlyRenamedWithinSide:
            "The user explicitly chose a new leaf name for one ordinary file on this side."
        case .selectedForDeletion:
            "The user explicitly selected this item for deletion from one side."
        }
    }
}

/// Keeps detected rename matches and explicit user renames as separate proof
/// domains. The executor validates each shape independently; an explicit
/// source snapshot can never satisfy a rename-detector claim, or vice versa.
public enum FolderSyncMoveAuthorization: String, Hashable, Codable, Sendable {
    case detectedRenameMatch
    case explicitSameDirectoryRename
    case explicitSameDirectoryCaseOnlyRename
}

/// Immutable evidence that an executor must revalidate before applying a move.
///
/// The move source and destination are both on the action's target side. This
/// proof names the authoritative file on the opposite side whose bytes were
/// matched by rename detection. It intentionally contains no absolute paths.
public struct FolderSyncMoveProof: Hashable, Codable, Sendable {
    public let referenceSide: FolderSyncSide
    public let referenceRelativePath: String
    public let expectedByteCount: UInt64
    public let expectedSHA256Digest: String
    public let authorization: FolderSyncMoveAuthorization
    public let explicitSourceSnapshot: LocalVerifiedFileMoveSourceSnapshot?

    public init(
        referenceSide: FolderSyncSide,
        referenceRelativePath: String,
        expectedByteCount: UInt64,
        expectedSHA256Digest: String,
        authorization: FolderSyncMoveAuthorization = .detectedRenameMatch,
        explicitSourceSnapshot: LocalVerifiedFileMoveSourceSnapshot? = nil
    ) {
        self.referenceSide = referenceSide
        self.referenceRelativePath = referenceRelativePath
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256Digest = expectedSHA256Digest
        self.authorization = authorization
        self.explicitSourceSnapshot = explicitSourceSnapshot
    }
}

/// One immutable action in a folder synchronization preview.
public struct FolderSyncAction: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Hashable, Codable, Sendable {
        case copy
        case createDirectory
        case delete
        case move
        case replace
        case conflict
        case noOp
    }

    public var id: String {
        [
            kind.rawValue,
            sourceSide?.rawValue ?? "-",
            sourceRelativePath ?? "-",
            targetSide?.rawValue ?? "-",
            targetRelativePath ?? "-"
        ].joined(separator: "|")
    }

    public let kind: Kind
    public let sourceSide: FolderSyncSide?
    public let targetSide: FolderSyncSide?
    public let sourceRelativePath: String?
    public let targetRelativePath: String?
    public let reason: FolderSyncReason
    public let risk: FolderSyncRisk
    public let issues: [ResourceIssue]
    /// Present only for independently validated detected-match or explicit
    /// same-directory move actions.
    public let moveProof: FolderSyncMoveProof?

    public init(
        kind: Kind,
        sourceSide: FolderSyncSide? = nil,
        targetSide: FolderSyncSide? = nil,
        sourceRelativePath: String? = nil,
        targetRelativePath: String? = nil,
        reason: FolderSyncReason,
        risk: FolderSyncRisk,
        issues: [ResourceIssue] = [],
        moveProof: FolderSyncMoveProof? = nil
    ) {
        self.kind = kind
        self.sourceSide = sourceSide
        self.targetSide = targetSide
        self.sourceRelativePath = sourceRelativePath
        self.targetRelativePath = targetRelativePath
        self.reason = reason
        self.risk = risk
        self.issues = issues
        self.moveProof = kind == .move ? moveProof : nil
    }
}

/// Counts derived from a synchronization preview.
public struct FolderSyncSummary: Hashable, Sendable {
    public let totalCount: Int
    public let actionableCount: Int
    public let copyCount: Int
    public let createDirectoryCount: Int
    public let deleteCount: Int
    public let moveCount: Int
    public let replaceCount: Int
    public let conflictCount: Int
    public let noOpCount: Int
    public let highRiskCount: Int

    public var hasConflicts: Bool { conflictCount > 0 }
    public var hasHighRiskActions: Bool { highRiskCount > 0 }

    public init(actions: [FolderSyncAction]) {
        var copies = 0
        var directories = 0
        var deletions = 0
        var moves = 0
        var replacements = 0
        var conflicts = 0
        var noOps = 0

        for action in actions {
            switch action.kind {
            case .copy:
                copies += 1
            case .createDirectory:
                directories += 1
            case .delete:
                deletions += 1
            case .move:
                moves += 1
            case .replace:
                replacements += 1
            case .conflict:
                conflicts += 1
            case .noOp:
                noOps += 1
            }
        }

        totalCount = actions.count
        actionableCount = copies + directories + deletions + moves + replacements
        copyCount = copies
        createDirectoryCount = directories
        deleteCount = deletions
        moveCount = moves
        replaceCount = replacements
        conflictCount = conflicts
        noOpCount = noOps
        highRiskCount = actions.count { $0.risk == .high }
    }
}

/// A complete, read-only folder synchronization preview.
public struct FolderSyncPlan: Hashable, Sendable {
    public let mode: FolderSyncMode
    public let actions: [FolderSyncAction]
    public let summary: FolderSyncSummary

    public init(mode: FolderSyncMode, actions: [FolderSyncAction]) {
        self.mode = mode
        self.actions = actions
        summary = FolderSyncSummary(actions: actions)
    }
}

/// Converts folder comparison rows into a deterministic synchronization preview.
///
/// This type deliberately performs no file-system operations. Applying a plan must
/// be handled by a separate executor with its own validation and approval checks.
public struct FolderSyncPlanner: Sendable {
    public init() {}

    public func plan(
        nodes: [PairNode],
        mode: FolderSyncMode,
        renameDetectionResult: FolderRenameDetectionResult? = nil
    ) -> FolderSyncPlan {
        let unorderedActions = nodes.map { node in
            switch mode {
            case .updateBoth:
                actionForBidirectionalUpdate(node)
            case .updateLeft, .updateRight, .mirrorLeftToRight, .mirrorRightToLeft:
                actionForOneWayMode(node, mode: mode)
            }
        }

        let foldedActions: [FolderSyncAction]
        if mode.isMirror, let renameDetectionResult {
            foldedActions = foldingVerifiedMoves(
                nodes: nodes,
                actions: unorderedActions,
                mode: mode,
                result: renameDetectionResult
            )
        } else {
            foldedActions = unorderedActions
        }

        return FolderSyncPlan(mode: mode, actions: ordered(foldedActions))
    }

    /// Replaces one source-side copy plus one target-side delete with a single
    /// same-root move. Every public rename-result field is treated as untrusted;
    /// a malformed or stale match simply leaves the original actions intact.
    private func foldingVerifiedMoves(
        nodes: [PairNode],
        actions: [FolderSyncAction],
        mode: FolderSyncMode,
        result: FolderRenameDetectionResult
    ) -> [FolderSyncAction] {
        guard nodes.count == actions.count else { return actions }

        let leftMatchCounts = occurrenceCounts(result.matches.map(\.leftRelativePath))
        let rightMatchCounts = occurrenceCounts(result.matches.map(\.rightRelativePath))
        let digestMatchCounts = result.matches.reduce(into: [RenameDigestKey: Int]()) {
            counts, match in
            counts[RenameDigestKey(match), default: 0] += 1
        }
        let ambiguousLeftPaths = Set(result.ambiguousGroups.flatMap(\.leftRelativePaths))
        let ambiguousRightPaths = Set(result.ambiguousGroups.flatMap(\.rightRelativePaths))
        let ambiguousDigestKeys = Set(result.ambiguousGroups.map(RenameDigestKey.init))
        let nodeIndicesByPath = Dictionary(grouping: nodes.indices) { nodes[$0].relativePath }

        var consumedIndices: Set<Int> = []
        var moves: [FolderSyncAction] = []

        for match in result.matches {
            guard isSafeRelativePath(match.leftRelativePath),
                  isSafeRelativePath(match.rightRelativePath),
                  match.leftRelativePath != match.rightRelativePath,
                  !hasAncestorRelationship(
                      match.leftRelativePath,
                      match.rightRelativePath
                  ),
                  isCanonicalSHA256Digest(match.digest),
                  leftMatchCounts[match.leftRelativePath] == 1,
                  rightMatchCounts[match.rightRelativePath] == 1,
                  digestMatchCounts[RenameDigestKey(match)] == 1,
                  !ambiguousLeftPaths.contains(match.leftRelativePath),
                  !ambiguousRightPaths.contains(match.rightRelativePath),
                  !ambiguousDigestKeys.contains(RenameDigestKey(match)),
                  let leftIndices = nodeIndicesByPath[match.leftRelativePath],
                  leftIndices.count == 1,
                  let leftIndex = leftIndices.first,
                  let rightIndices = nodeIndicesByPath[match.rightRelativePath],
                  rightIndices.count == 1,
                  let rightIndex = rightIndices.first,
                  leftIndex != rightIndex,
                  !consumedIndices.contains(leftIndex),
                  !consumedIndices.contains(rightIndex),
                  isValidUniqueFileNode(
                      nodes[leftIndex],
                      side: .left,
                      path: match.leftRelativePath,
                      expectedByteCount: match.byteCount
                  ),
                  isValidUniqueFileNode(
                      nodes[rightIndex],
                      side: .right,
                      path: match.rightRelativePath,
                      expectedByteCount: match.byteCount
                  ) else {
                continue
            }

            let referenceIndex: Int
            let moveSourceIndex: Int
            let referenceSide: FolderSyncSide
            let targetSide: FolderSyncSide
            let referencePath: String
            let moveSourcePath: String
            switch mode {
            case .mirrorLeftToRight:
                referenceIndex = leftIndex
                moveSourceIndex = rightIndex
                referenceSide = .left
                targetSide = .right
                referencePath = match.leftRelativePath
                moveSourcePath = match.rightRelativePath
            case .mirrorRightToLeft:
                referenceIndex = rightIndex
                moveSourceIndex = leftIndex
                referenceSide = .right
                targetSide = .left
                referencePath = match.rightRelativePath
                moveSourcePath = match.leftRelativePath
            case .updateLeft, .updateRight, .updateBoth:
                return actions
            }

            guard isExpectedCopy(
                      actions[referenceIndex],
                      sourceSide: referenceSide,
                      targetSide: targetSide,
                      path: referencePath
                  ),
                  isExpectedMirrorDelete(
                      actions[moveSourceIndex],
                      targetSide: targetSide,
                      path: moveSourcePath
                  ) else {
                continue
            }

            consumedIndices.insert(referenceIndex)
            consumedIndices.insert(moveSourceIndex)
            moves.append(FolderSyncAction(
                kind: .move,
                sourceSide: targetSide,
                targetSide: targetSide,
                sourceRelativePath: moveSourcePath,
                targetRelativePath: referencePath,
                reason: .renameMatchMovedWithinTarget,
                risk: .high,
                moveProof: FolderSyncMoveProof(
                    referenceSide: referenceSide,
                    referenceRelativePath: referencePath,
                    expectedByteCount: match.byteCount,
                    expectedSHA256Digest: match.digest
                )
            ))
        }

        guard !moves.isEmpty else { return actions }
        return actions.indices.compactMap { index in
            consumedIndices.contains(index) ? nil : actions[index]
        } + moves
    }

    private func occurrenceCounts(_ paths: [String]) -> [String: Int] {
        paths.reduce(into: [:]) { counts, path in
            counts[path, default: 0] += 1
        }
    }

    private func isValidUniqueFileNode(
        _ node: PairNode,
        side: FolderSyncSide,
        path: String,
        expectedByteCount: UInt64
    ) -> Bool {
        guard node.relativePath == path, node.issues.isEmpty else { return false }

        let entry: ResourceEntry
        switch side {
        case .left:
            guard node.status == .leftOnly, let left = node.left, node.right == nil else {
                return false
            }
            entry = left
        case .right:
            guard node.status == .rightOnly, let right = node.right, node.left == nil else {
                return false
            }
            entry = right
        }

        guard entry.relativePath == path,
              entry.kind == .file,
              entry.issue == nil,
              let byteCount = entry.byteCount,
              byteCount >= 0 else {
            return false
        }
        return UInt64(byteCount) == expectedByteCount
    }

    private func isExpectedCopy(
        _ action: FolderSyncAction,
        sourceSide: FolderSyncSide,
        targetSide: FolderSyncSide,
        path: String
    ) -> Bool {
        action.kind == .copy
            && action.sourceSide == sourceSide
            && action.targetSide == targetSide
            && action.sourceRelativePath == path
            && action.targetRelativePath == path
            && action.reason == .sourceOnly
            && action.moveProof == nil
    }

    private func isExpectedMirrorDelete(
        _ action: FolderSyncAction,
        targetSide: FolderSyncSide,
        path: String
    ) -> Bool {
        action.kind == .delete
            && action.sourceSide == nil
            && action.sourceRelativePath == nil
            && action.targetSide == targetSide
            && action.targetRelativePath == path
            && action.reason == .mirrorRemovesTargetOnly
            && action.moveProof == nil
    }

    private func isCanonicalSHA256Digest(_ digest: String) -> Bool {
        let bytes = Array(digest.utf8)
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.utf8.contains(0) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func hasAncestorRelationship(_ first: String, _ second: String) -> Bool {
        let firstComponents = first.split(separator: "/")
        let secondComponents = second.split(separator: "/")
        let sharedCount = min(firstComponents.count, secondComponents.count)
        guard firstComponents.prefix(sharedCount) == secondComponents.prefix(sharedCount) else {
            return false
        }
        return firstComponents.count != secondComponents.count
    }

    private struct RenameDigestKey: Hashable {
        let byteCount: UInt64
        let digest: String

        init(_ match: FolderRenameMatch) {
            byteCount = match.byteCount
            digest = match.digest
        }

        init(_ group: FolderRenameAmbiguousGroup) {
            byteCount = group.byteCount
            digest = group.digest
        }
    }

    private func actionForBidirectionalUpdate(_ node: PairNode) -> FolderSyncAction {
        switch node.status {
        case .same:
            return action(
                kind: .noOp,
                sourceSide: .left,
                targetSide: .right,
                source: node.left,
                target: node.right,
                fallbackPath: node.relativePath,
                reason: .alreadySame,
                risk: .none
            )

        case .leftOnly:
            return materialize(
                source: node.left,
                sourceSide: .left,
                targetSide: .right,
                fallbackPath: node.relativePath,
                issues: node.issues
            )

        case .rightOnly:
            return materialize(
                source: node.right,
                sourceSide: .right,
                targetSide: .left,
                fallbackPath: node.relativePath,
                issues: node.issues
            )

        case .different:
            return conflict(
                node,
                sourceSide: .left,
                targetSide: .right,
                reason: .bothSidesDiffer
            )

        case .typeMismatch:
            return conflict(
                node,
                sourceSide: .left,
                targetSide: .right,
                reason: .typeMismatch
            )

        case .error:
            return conflict(
                node,
                sourceSide: .left,
                targetSide: .right,
                reason: .comparisonError
            )
        }
    }

    private func actionForOneWayMode(
        _ node: PairNode,
        mode: FolderSyncMode
    ) -> FolderSyncAction {
        let orientation = mode.orientation
        let source = entry(on: orientation.source, in: node)
        let target = entry(on: orientation.target, in: node)

        switch node.status {
        case .same:
            return action(
                kind: .noOp,
                sourceSide: orientation.source,
                targetSide: orientation.target,
                source: source,
                target: target,
                fallbackPath: node.relativePath,
                reason: .alreadySame,
                risk: .none
            )

        case .different:
            guard source != nil, target != nil else {
                return conflict(
                    node,
                    sourceSide: orientation.source,
                    targetSide: orientation.target,
                    reason: .comparisonError
                )
            }
            return action(
                kind: .replace,
                sourceSide: orientation.source,
                targetSide: orientation.target,
                source: source,
                target: target,
                fallbackPath: node.relativePath,
                reason: .contentDiffers,
                risk: .medium
            )

        case .typeMismatch:
            return conflict(
                node,
                sourceSide: orientation.source,
                targetSide: orientation.target,
                reason: .typeMismatch
            )

        case .error:
            return conflict(
                node,
                sourceSide: orientation.source,
                targetSide: orientation.target,
                reason: .comparisonError
            )

        case .leftOnly, .rightOnly:
            if let source {
                return materialize(
                    source: source,
                    sourceSide: orientation.source,
                    targetSide: orientation.target,
                    fallbackPath: node.relativePath,
                    issues: node.issues
                )
            }

            guard let target else {
                return conflict(
                    node,
                    sourceSide: orientation.source,
                    targetSide: orientation.target,
                    reason: .comparisonError
                )
            }

            if mode.isMirror {
                return action(
                    kind: .delete,
                    sourceSide: nil,
                    targetSide: orientation.target,
                    source: nil,
                    target: target,
                    fallbackPath: node.relativePath,
                    reason: .mirrorRemovesTargetOnly,
                    risk: .high
                )
            }

            return action(
                kind: .noOp,
                sourceSide: nil,
                targetSide: orientation.target,
                source: nil,
                target: target,
                fallbackPath: node.relativePath,
                reason: .targetOnlyPreserved,
                risk: .none
            )
        }
    }

    private func materialize(
        source: ResourceEntry?,
        sourceSide: FolderSyncSide,
        targetSide: FolderSyncSide,
        fallbackPath: String,
        issues: [ResourceIssue]
    ) -> FolderSyncAction {
        guard let source, source.issue == nil, issues.isEmpty else {
            return FolderSyncAction(
                kind: .conflict,
                sourceSide: sourceSide,
                targetSide: targetSide,
                sourceRelativePath: source?.relativePath,
                targetRelativePath: source?.relativePath ?? fallbackPath,
                reason: .comparisonError,
                risk: .high,
                issues: issues + [source?.issue].compactMap { $0 }
            )
        }

        let kind: FolderSyncAction.Kind = source.kind == .directory ? .createDirectory : .copy
        return FolderSyncAction(
            kind: kind,
            sourceSide: sourceSide,
            targetSide: targetSide,
            sourceRelativePath: source.relativePath,
            targetRelativePath: source.relativePath,
            reason: .sourceOnly,
            risk: .low
        )
    }

    private func conflict(
        _ node: PairNode,
        sourceSide: FolderSyncSide,
        targetSide: FolderSyncSide,
        reason: FolderSyncReason
    ) -> FolderSyncAction {
        let source = entry(on: sourceSide, in: node)
        let target = entry(on: targetSide, in: node)
        return action(
            kind: .conflict,
            sourceSide: sourceSide,
            targetSide: targetSide,
            source: source,
            target: target,
            fallbackPath: node.relativePath,
            reason: reason,
            risk: .high,
            issues: node.issues
        )
    }

    private func action(
        kind: FolderSyncAction.Kind,
        sourceSide: FolderSyncSide?,
        targetSide: FolderSyncSide?,
        source: ResourceEntry?,
        target: ResourceEntry?,
        fallbackPath: String,
        reason: FolderSyncReason,
        risk: FolderSyncRisk,
        issues: [ResourceIssue] = []
    ) -> FolderSyncAction {
        FolderSyncAction(
            kind: kind,
            sourceSide: sourceSide,
            targetSide: targetSide,
            sourceRelativePath: source?.relativePath,
            targetRelativePath: target?.relativePath ?? (targetSide == nil ? nil : fallbackPath),
            reason: reason,
            risk: risk,
            issues: issues
        )
    }

    private func entry(on side: FolderSyncSide, in node: PairNode) -> ResourceEntry? {
        switch side {
        case .left:
            node.left
        case .right:
            node.right
        }
    }

    private func ordered(_ actions: [FolderSyncAction]) -> [FolderSyncAction] {
        actions.sorted { left, right in
            let leftPhase = phase(for: left.kind)
            let rightPhase = phase(for: right.kind)
            if leftPhase != rightPhase {
                return leftPhase < rightPhase
            }

            let leftPath = left.targetRelativePath ?? left.sourceRelativePath ?? ""
            let rightPath = right.targetRelativePath ?? right.sourceRelativePath ?? ""
            let leftDepth = pathDepth(leftPath)
            let rightDepth = pathDepth(rightPath)

            if left.kind == .createDirectory, leftDepth != rightDepth {
                return leftDepth < rightDepth
            }
            if left.kind == .delete, leftDepth != rightDepth {
                return leftDepth > rightDepth
            }
            if leftPath != rightPath {
                return leftPath < rightPath
            }

            return left.id < right.id
        }
    }

    private func phase(for kind: FolderSyncAction.Kind) -> Int {
        switch kind {
        case .createDirectory:
            0
        case .move:
            1
        case .copy:
            2
        case .replace:
            3
        case .conflict:
            4
        case .noOp:
            5
        case .delete:
            6
        }
    }

    private func pathDepth(_ path: String) -> Int {
        path.split(separator: "/", omittingEmptySubsequences: true).count
    }
}

private extension FolderSyncMode {
    var orientation: (source: FolderSyncSide, target: FolderSyncSide) {
        switch self {
        case .updateLeft, .mirrorRightToLeft:
            (source: .right, target: .left)
        case .updateRight, .mirrorLeftToRight, .updateBoth:
            (source: .left, target: .right)
        }
    }

    var isMirror: Bool {
        switch self {
        case .mirrorLeftToRight, .mirrorRightToLeft:
            true
        case .updateLeft, .updateRight, .updateBoth:
            false
        }
    }
}
