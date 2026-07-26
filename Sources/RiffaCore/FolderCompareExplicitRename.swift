import Foundation

public enum FolderCompareExplicitRenameLeafProblem: String, Error, Codable, Sendable {
    case empty
    case dotComponent
    case containsSlash
    case containsNUL
    case exceedsUTF8Budget
}

/// Fail-closed reasons why one current Folder Compare row cannot become an
/// explicit, same-parent ordinary-file rename.
public enum FolderCompareExplicitRenamePlanningError: Error, Equatable, Sendable {
    case selectionRequired
    case exactlyOneSelectionRequired
    case duplicateComparisonPath
    case selectionNotVisible
    case comparisonIssue
    case selectedSideMissing
    case ordinaryFileRequired
    case localResourceRequired
    case invalidLeaf(FolderCompareExplicitRenameLeafProblem)
    case nameUnchanged
    case declaredSourceMetadataChanged
}

extension FolderCompareExplicitRenamePlanningError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .selectionRequired:
            "Select one ordinary file first."
        case .exactlyOneSelectionRequired:
            "Rename supports exactly one selected file at a time."
        case .duplicateComparisonPath:
            "The current comparison contains duplicate paths, so rename is unavailable."
        case .selectionNotVisible:
            "The selected row is no longer visible. Clear the filter or select the file again."
        case .comparisonIssue:
            "The selected row has a comparison issue and cannot be renamed safely."
        case .selectedSideMissing:
            "The selected file does not exist on the chosen side."
        case .ordinaryFileRequired:
            "Only ordinary files can be renamed here. Directory and symbolic-link rename is not supported."
        case .localResourceRequired:
            "Explicit rename is available only for local files."
        case let .invalidLeaf(problem):
            switch problem {
            case .empty:
                "Enter a non-empty file name."
            case .dotComponent:
                "The names '.' and '..' are not allowed."
            case .containsSlash:
                "Enter a leaf name only; '/' is not allowed."
            case .containsNUL:
                "The file name contains an invalid NUL byte."
            case .exceedsUTF8Budget:
                "The file name exceeds the 255-byte UTF-8 safety limit."
            }
        case .nameUnchanged:
            "Enter a different file name."
        case .declaredSourceMetadataChanged:
            "The selected source changed after the comparison. Refresh and try again."
        }
    }
}

public struct FolderCompareExplicitRenameEligibility: Hashable, Sendable {
    public let side: FolderSyncSide
    public let sourceRelativePath: String
    public let currentLeafName: String

    public init(
        side: FolderSyncSide,
        sourceRelativePath: String,
        currentLeafName: String
    ) {
        self.side = side
        self.sourceRelativePath = sourceRelativePath
        self.currentLeafName = currentLeafName
    }
}

public enum FolderCompareExplicitRenameKind: String, Hashable, Codable, Sendable {
    case ordinary
    case caseOnly
}

public struct FolderCompareExplicitRenamePlanningResult: Hashable, Sendable {
    public let side: FolderSyncSide
    public let kind: FolderCompareExplicitRenameKind
    public let sourceRelativePath: String
    public let destinationRelativePath: String
    public let sourceSnapshot: LocalVerifiedFileMoveSourceSnapshot
    public let plan: FolderSyncPlan

    public init(
        side: FolderSyncSide,
        kind: FolderCompareExplicitRenameKind,
        sourceRelativePath: String,
        destinationRelativePath: String,
        sourceSnapshot: LocalVerifiedFileMoveSourceSnapshot,
        plan: FolderSyncPlan
    ) {
        self.side = side
        self.kind = kind
        self.sourceRelativePath = sourceRelativePath
        self.destinationRelativePath = destinationRelativePath
        self.sourceSnapshot = sourceSnapshot
        self.plan = plan
    }
}

/// Plans only a user-requested leaf rename. It does not consume rename
/// detection results and therefore cannot accidentally convert an ambiguous or
/// stale detector candidate into an explicit file operation.
public struct FolderCompareExplicitRenamePlanner: Sendable {
    public static let maximumLeafUTF8ByteCount = 255

    private let mover: LocalVerifiedFileMove

    public init(limits: LocalVerifiedFileMoveLimits = .standard) {
        mover = LocalVerifiedFileMove(limits: limits)
    }

    /// The exact synchronous predicate used by Folder Compare to enable the
    /// Left/Right rename commands. Pass only rows currently visible to the user.
    public func eligibility(
        visibleNodes: [PairNode],
        selectedIDs: Set<PairNode.ID>,
        side: FolderSyncSide
    ) throws -> FolderCompareExplicitRenameEligibility {
        guard !selectedIDs.isEmpty else {
            throw FolderCompareExplicitRenamePlanningError.selectionRequired
        }
        guard selectedIDs.count == 1 else {
            throw FolderCompareExplicitRenamePlanningError.exactlyOneSelectionRequired
        }
        guard Set(visibleNodes.map(\.id)).count == visibleNodes.count else {
            throw FolderCompareExplicitRenamePlanningError.duplicateComparisonPath
        }
        let selectedID = selectedIDs.first!
        guard let node = visibleNodes.first(where: { $0.id == selectedID }) else {
            throw FolderCompareExplicitRenamePlanningError.selectionNotVisible
        }
        guard node.issues.isEmpty else {
            throw FolderCompareExplicitRenamePlanningError.comparisonIssue
        }
        let entry = switch side {
        case .left: node.left
        case .right: node.right
        }
        guard let entry else {
            throw FolderCompareExplicitRenamePlanningError.selectedSideMissing
        }
        guard entry.kind == .file else {
            throw FolderCompareExplicitRenamePlanningError.ordinaryFileRequired
        }
        guard entry.locator.providerID == ResourceLocator.localProviderID else {
            throw FolderCompareExplicitRenamePlanningError.localResourceRequired
        }
        return FolderCompareExplicitRenameEligibility(
            side: side,
            sourceRelativePath: node.relativePath,
            currentLeafName: Self.leaf(of: node.relativePath)
        )
    }

    public func plan(
        visibleNodes: [PairNode],
        selectedIDs: Set<PairNode.ID>,
        side: FolderSyncSide,
        newLeafName: String,
        root: URL
    ) async throws -> FolderCompareExplicitRenamePlanningResult {
        let eligible = try eligibility(
            visibleNodes: visibleNodes,
            selectedIDs: selectedIDs,
            side: side
        )
        try Self.validateLeaf(newLeafName)
        let kind = try Self.renameKind(
            currentLeafName: eligible.currentLeafName,
            newLeafName: newLeafName
        )

        let parent = Self.parent(of: eligible.sourceRelativePath)
        let destinationRelativePath = parent.isEmpty
            ? newLeafName
            : parent + "/" + newLeafName
        let snapshot = try await mover.captureSourceSnapshot(
            root: root,
            relativePath: eligible.sourceRelativePath
        )
        try validateDeclaredMetadata(
            visibleNodes: visibleNodes,
            selectedID: selectedIDs.first!,
            side: side,
            snapshot: snapshot
        )

        let proof = LocalVerifiedFileMoveProof(
            expectedByteCount: snapshot.byteCount,
            expectedSHA256: snapshot.sha256
        )
        let request = LocalVerifiedFileMoveRequest(
            targetRoot: root,
            sourceRelativePath: eligible.sourceRelativePath,
            destinationRelativePath: destinationRelativePath,
            referenceRoot: root,
            referenceRelativePath: eligible.sourceRelativePath,
            proof: proof,
            expectedSourceSnapshot: snapshot,
            referenceBinding: kind == .caseOnly
                ? .selectedSourceCaseOnlyRename
                : .selectedSource,
            allowsCrossDeviceFallback: false
        )
        // A second descriptor-backed pass proves destination absence and
        // narrows races after the snapshot was captured. Execution repeats it.
        _ = try await mover.verify(request)
        try Task.checkCancellation()

        let action = FolderSyncAction(
            kind: .move,
            sourceSide: side,
            targetSide: side,
            sourceRelativePath: eligible.sourceRelativePath,
            targetRelativePath: destinationRelativePath,
            reason: .explicitlyRenamedWithinSide,
            risk: .high,
            moveProof: FolderSyncMoveProof(
                referenceSide: side,
                referenceRelativePath: eligible.sourceRelativePath,
                expectedByteCount: snapshot.byteCount,
                expectedSHA256Digest: snapshot.sha256,
                authorization: kind == .caseOnly
                    ? .explicitSameDirectoryCaseOnlyRename
                    : .explicitSameDirectoryRename,
                explicitSourceSnapshot: snapshot
            )
        )
        let mode: FolderSyncMode = side == .left ? .mirrorRightToLeft : .mirrorLeftToRight
        return FolderCompareExplicitRenamePlanningResult(
            side: side,
            kind: kind,
            sourceRelativePath: eligible.sourceRelativePath,
            destinationRelativePath: destinationRelativePath,
            sourceSnapshot: snapshot,
            plan: FolderSyncPlan(mode: mode, actions: [action])
        )
    }

    public static func validateLeaf(_ leaf: String) throws {
        guard !leaf.isEmpty else {
            throw FolderCompareExplicitRenamePlanningError.invalidLeaf(.empty)
        }
        guard leaf != ".", leaf != ".." else {
            throw FolderCompareExplicitRenamePlanningError.invalidLeaf(.dotComponent)
        }
        guard !leaf.contains("/") else {
            throw FolderCompareExplicitRenamePlanningError.invalidLeaf(.containsSlash)
        }
        guard !leaf.utf8.contains(0) else {
            throw FolderCompareExplicitRenamePlanningError.invalidLeaf(.containsNUL)
        }
        guard leaf.utf8.count <= maximumLeafUTF8ByteCount else {
            throw FolderCompareExplicitRenamePlanningError.invalidLeaf(.exceedsUTF8Budget)
        }
    }

    /// Classifies a leaf change without consulting volume case sensitivity.
    /// Canonically equivalent spellings are a no-op; normalized spellings that
    /// differ only by case use the dedicated two-stage authorization domain.
    public static func renameKind(
        currentLeafName: String,
        newLeafName: String
    ) throws -> FolderCompareExplicitRenameKind {
        let current = currentLeafName.precomposedStringWithCanonicalMapping
        let proposed = newLeafName.precomposedStringWithCanonicalMapping
        guard current != proposed else {
            throw FolderCompareExplicitRenamePlanningError.nameUnchanged
        }
        return caseFoldKey(current) == caseFoldKey(proposed) ? .caseOnly : .ordinary
    }

    private func validateDeclaredMetadata(
        visibleNodes: [PairNode],
        selectedID: PairNode.ID,
        side: FolderSyncSide,
        snapshot: LocalVerifiedFileMoveSourceSnapshot
    ) throws {
        guard let node = visibleNodes.first(where: { $0.id == selectedID }) else {
            throw FolderCompareExplicitRenamePlanningError.selectionNotVisible
        }
        let entry = side == .left ? node.left : node.right
        guard let entry,
              entry.byteCount.map({ $0 >= 0 && UInt64($0) == snapshot.byteCount }) ?? false,
              entry.permissions.map({ $0 == snapshot.permissions }) ?? true,
              Self.declaredIdentity(entry.fileIdentifier, matches: snapshot) else {
            throw FolderCompareExplicitRenamePlanningError.declaredSourceMetadataChanged
        }
    }

    private static func declaredIdentity(
        _ identifier: String?,
        matches snapshot: LocalVerifiedFileMoveSourceSnapshot
    ) -> Bool {
        guard let identifier else { return true }
        let components = identifier.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let device = UInt64(components[0]),
              let file = UInt64(components[1]) else {
            return false
        }
        return device == snapshot.deviceID && file == snapshot.fileID
    }

    private static func parent(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .dropLast()
            .joined(separator: "/")
    }

    private static func leaf(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
    }


    private static func caseFoldKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
