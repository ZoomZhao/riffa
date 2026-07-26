import Darwin
import Foundation

public struct LocalFolderSyncExecutionOptions: Hashable, Sendable {
    /// Execution is preview-only unless the caller explicitly opts into writes.
    public let dryRun: Bool
    /// High-risk actions, including every mirror deletion, require an explicit opt-in.
    public let allowHighRisk: Bool

    public init(dryRun: Bool = true, allowHighRisk: Bool = false) {
        self.dryRun = dryRun
        self.allowHighRisk = allowHighRisk
    }
}

public enum LocalFolderSyncExecutionStatus: String, Hashable, Codable, Sendable {
    case dryRun
    case completed
    case refused
    case failedRolledBack
    case failedRollbackIncomplete
}

public enum LocalFolderSyncItemStatus: String, Hashable, Codable, Sendable {
    case planned
    case completed
    case refused
    case failed
    case notRun
    case rolledBack
    case rollbackFailed
}

public struct LocalFolderSyncExecutionIssue: Error, Hashable, Sendable, LocalizedError {
    public enum Code: String, Hashable, Codable, Sendable {
        case conflict
        case highRiskNotAllowed
        case invalidRoot
        case overlappingRoots
        case invalidRelativePath
        case malformedAction
        case duplicateTarget
        case moveVerificationFailed
        case cancelled
        case missingSource
        case unexpectedSourceType
        case invalidTargetState
        case symbolicLinkTraversal
        case missingParentDirectory
        case backupCollision
        case executionFailed
        case rollbackFailed
    }

    public let code: Code
    public let actionIndex: Int?
    public let path: String?
    public let message: String

    public init(code: Code, actionIndex: Int? = nil, path: String? = nil, message: String) {
        self.code = code
        self.actionIndex = actionIndex
        self.path = path
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct LocalFolderSyncItemResult: Hashable, Sendable {
    public let actionIndex: Int
    public let action: FolderSyncAction
    public let status: LocalFolderSyncItemStatus
    public let message: String

    public init(
        actionIndex: Int,
        action: FolderSyncAction,
        status: LocalFolderSyncItemStatus,
        message: String
    ) {
        self.actionIndex = actionIndex
        self.action = action
        self.status = status
        self.message = message
    }
}

/// A complete audit record for one attempted plan execution.
public struct LocalFolderSyncExecutionLog: Hashable, Sendable {
    public let mode: FolderSyncMode
    public let status: LocalFolderSyncExecutionStatus
    public let dryRun: Bool
    public let rollbackAttempted: Bool
    public let rollbackSucceeded: Bool?
    public let itemResults: [LocalFolderSyncItemResult]
    public let issues: [LocalFolderSyncExecutionIssue]

    public init(
        mode: FolderSyncMode,
        status: LocalFolderSyncExecutionStatus,
        dryRun: Bool,
        rollbackAttempted: Bool,
        rollbackSucceeded: Bool?,
        itemResults: [LocalFolderSyncItemResult],
        issues: [LocalFolderSyncExecutionIssue]
    ) {
        self.mode = mode
        self.status = status
        self.dryRun = dryRun
        self.rollbackAttempted = rollbackAttempted
        self.rollbackSucceeded = rollbackSucceeded
        self.itemResults = itemResults
        self.issues = issues
    }
}

/// Executes a folder synchronization plan against two local roots.
///
/// The executor is deliberately conservative: it defaults to dry-run, rejects an
/// entire plan before writing when any action is unsafe, never follows an
/// intermediate symbolic link, and moves old target data into `backupRoot`.
public struct LocalFolderSyncExecutor: Sendable {
    private let injectedFailureActionIndex: Int?
    private let verifiedFileMove: LocalVerifiedFileMove

    public init() {
        injectedFailureActionIndex = nil
        verifiedFileMove = LocalVerifiedFileMove()
    }

    /// A deterministic fault hook used only by the core test target.
    init(testingFailureAtActionIndex index: Int?) {
        injectedFailureActionIndex = index
        verifiedFileMove = LocalVerifiedFileMove()
    }

    public func execute(
        plan: FolderSyncPlan,
        leftRoot: URL,
        rightRoot: URL,
        backupRoot: URL,
        options: LocalFolderSyncExecutionOptions = .init()
    ) async -> LocalFolderSyncExecutionLog {
        let preflight = await preflight(
            plan: plan,
            leftRoot: leftRoot,
            rightRoot: rightRoot,
            backupRoot: backupRoot,
            allowHighRisk: options.allowHighRisk
        )

        switch preflight {
        case let .failure(issues):
            return refusalLog(plan: plan, dryRun: options.dryRun, issues: issues)

        case let .success(context):
            if options.dryRun {
                return LocalFolderSyncExecutionLog(
                    mode: plan.mode,
                    status: .dryRun,
                    dryRun: true,
                    rollbackAttempted: false,
                    rollbackSucceeded: nil,
                    itemResults: plan.actions.enumerated().map { index, action in
                        LocalFolderSyncItemResult(
                            actionIndex: index,
                            action: action,
                            status: .planned,
                            message: "Preflight passed; no file-system changes were made."
                        )
                    },
                    issues: []
                )
            }

            return await perform(plan: plan, context: context)
        }
    }

    private func preflight(
        plan: FolderSyncPlan,
        leftRoot: URL,
        rightRoot: URL,
        backupRoot: URL,
        allowHighRisk: Bool
    ) async -> PreflightOutcome {
        var issues: [LocalFolderSyncExecutionIssue] = []

        for (index, action) in plan.actions.enumerated() {
            if action.kind == .conflict {
                issues.append(
                    issue(
                        .conflict,
                        index: index,
                        path: displayedPath(action),
                        "Plans containing conflicts cannot be executed."
                    )
                )
            }
            if action.risk == .high, !allowHighRisk {
                issues.append(
                    issue(
                        .highRiskNotAllowed,
                        index: index,
                        path: displayedPath(action),
                        "High-risk actions require allowHighRisk: true."
                    )
                )
            }
        }

        let left = canonicalExistingDirectory(leftRoot, label: "left root", issues: &issues)
        let right = canonicalExistingDirectory(rightRoot, label: "right root", issues: &issues)
        let backup = canonicalPotentialDirectory(backupRoot, label: "backup root", issues: &issues)

        if let left, let right, pathsOverlap(left, right) {
            issues.append(
                issue(.overlappingRoots, "Left and right roots must not overlap.")
            )
        }
        if let left, let backup, pathsOverlap(left, backup) {
            issues.append(
                issue(.overlappingRoots, "The backup root must not overlap the left root.")
            )
        }
        if let right, let backup, pathsOverlap(right, backup) {
            issues.append(
                issue(.overlappingRoots, "The backup root must not overlap the right root.")
            )
        }

        guard let left, let right, let backup else {
            return .failure(issues)
        }

        let roots = ExecutionRoots(left: left, right: right, backup: backup)
        var validatedPaths: [ValidatedActionPaths?] = Array(repeating: nil, count: plan.actions.count)
        var plannedDirectories = Set<SidePath>()

        for (index, action) in plan.actions.enumerated() {
            let paths = validateActionShape(
                action,
                mode: plan.mode,
                index: index,
                roots: roots,
                issues: &issues
            )
            validatedPaths[index] = paths
            if action.kind == .createDirectory,
               let side = action.targetSide,
               let path = action.targetRelativePath,
               validRelativePath(path) {
                plannedDirectories.insert(SidePath(side: side, path: path))
            }
        }

        var mutationTargets: [String: Int] = [:]
        var moveSources: [String: Int] = [:]
        var backupTargets = Set<String>()

        for (index, action) in plan.actions.enumerated() {
            guard let paths = validatedPaths[index] else { continue }

            if let sourceURL = paths.sourceURL,
               action.kind == .copy || action.kind == .createDirectory
                || action.kind == .replace || action.kind == .move {
                validateIntermediateComponents(
                    root: roots.root(for: action.sourceSide!),
                    relativePath: action.sourceRelativePath!,
                    plannedDirectories: [],
                    side: action.sourceSide!,
                    allowUnplannedMissing: false,
                    index: index,
                    issues: &issues
                )
                validateSourceLeaf(
                    sourceURL,
                    action: action,
                    index: index,
                    issues: &issues
                )

                if action.kind == .move {
                    let key = pathKey(sourceURL.path)
                    if moveSources.updateValue(index, forKey: key) != nil {
                        issues.append(
                            issue(
                                .duplicateTarget,
                                index: index,
                                path: action.sourceRelativePath,
                                "More than one move removes the same source path."
                            )
                        )
                    }
                }
            }

            if let targetURL = paths.targetURL, action.kind != .noOp, action.kind != .conflict {
                validateIntermediateComponents(
                    root: roots.root(for: action.targetSide!),
                    relativePath: action.targetRelativePath!,
                    plannedDirectories: plannedDirectories,
                    side: action.targetSide!,
                    allowUnplannedMissing: false,
                    index: index,
                    issues: &issues
                )
                validateTargetLeaf(targetURL, action: action, index: index, issues: &issues)

                let key = pathKey(targetURL.path)
                if mutationTargets.updateValue(index, forKey: key) != nil {
                    issues.append(
                        issue(
                            .duplicateTarget,
                            index: index,
                            path: action.targetRelativePath,
                            "More than one action mutates the same target path."
                        )
                    )
                }
            }

            if let backupURL = paths.backupURL {
                validateIntermediateComponents(
                    root: roots.backup,
                    relativePath: backupRelativePath(action),
                    plannedDirectories: [],
                    side: action.targetSide!,
                    allowUnplannedMissing: true,
                    index: index,
                    issues: &issues
                )

                if itemKind(at: backupURL) != nil {
                    issues.append(
                        issue(
                            .backupCollision,
                            index: index,
                            path: backupURL.path,
                            "The backup destination already exists."
                        )
                    )
                }
                if !backupTargets.insert(backupURL.path).inserted {
                    issues.append(
                        issue(
                            .backupCollision,
                            index: index,
                            path: backupURL.path,
                            "More than one action uses the same backup destination."
                        )
                    )
                }
            }
        }

        for (key, sourceIndex) in moveSources where mutationTargets[key] != nil {
            if mutationTargets[key] == sourceIndex,
               plan.actions[sourceIndex].moveProof?.authorization
                    == .explicitSameDirectoryCaseOnlyRename {
                continue
            }
            issues.append(
                issue(
                    .duplicateTarget,
                    index: sourceIndex,
                    path: plan.actions[sourceIndex].sourceRelativePath,
                    "A move source cannot also be the target of another action in the same plan."
                )
            )
        }

        if issues.isEmpty {
            for (index, paths) in validatedPaths.enumerated() {
                guard let request = paths?.moveRequest else { continue }
                do {
                    _ = try await verifiedFileMove.verify(request)
                } catch is CancellationError {
                    issues.append(
                        issue(
                            .cancelled,
                            index: index,
                            path: displayedPath(plan.actions[index]),
                            "Move verification was cancelled before any file-system changes were made."
                        )
                    )
                } catch let error as LocalVerifiedFileMoveError {
                    issues.append(
                        issue(
                            .moveVerificationFailed,
                            index: index,
                            path: displayedPath(plan.actions[index]),
                            "Move verification failed: \(error.localizedDescription)"
                        )
                    )
                } catch {
                    issues.append(
                        issue(
                            .moveVerificationFailed,
                            index: index,
                            path: displayedPath(plan.actions[index]),
                            "Move verification failed safely."
                        )
                    )
                }
            }
        }

        guard issues.isEmpty else { return .failure(issues) }
        let prepared = plan.actions.indices.map { index in
            PreparedAction(index: index, action: plan.actions[index], paths: validatedPaths[index]!)
        }
        return .success(ExecutionContext(roots: roots, actions: prepared))
    }

    private func validateActionShape(
        _ action: FolderSyncAction,
        mode: FolderSyncMode,
        index: Int,
        roots: ExecutionRoots,
        issues: inout [LocalFolderSyncExecutionIssue]
    ) -> ValidatedActionPaths? {
        var isValid = true

        func validatePair(side: FolderSyncSide?, path: String?, role: String) {
            if (side == nil) != (path == nil) {
                issues.append(
                    issue(
                        .malformedAction,
                        index: index,
                        path: path,
                        "The \(role) side and relative path must either both be set or both be nil."
                    )
                )
                isValid = false
            }
            if let path, !validRelativePath(path) {
                issues.append(
                    issue(
                        .invalidRelativePath,
                        index: index,
                        path: path,
                        "Relative paths must not be empty or absolute and cannot contain '.', '..', or empty components."
                    )
                )
                isValid = false
            }
        }

        validatePair(side: action.sourceSide, path: action.sourceRelativePath, role: "source")
        validatePair(side: action.targetSide, path: action.targetRelativePath, role: "target")

        switch action.kind {
        case .copy, .createDirectory, .replace:
            if action.sourceSide == nil || action.sourceRelativePath == nil ||
                action.targetSide == nil || action.targetRelativePath == nil {
                issues.append(
                    issue(
                        .malformedAction,
                        index: index,
                        path: displayedPath(action),
                        "This action requires both a source and a target."
                    )
                )
                isValid = false
            }
        case .move:
            let expectedTargetSide = mirrorTargetSide(for: mode)
            let isWellFormed: Bool
            if let sourceSide = action.sourceSide,
               let sourcePath = action.sourceRelativePath,
               let targetSide = action.targetSide,
               let targetPath = action.targetRelativePath,
               let proof = action.moveProof,
               let expectedTargetSide {
                let sharedShape = sourceSide == targetSide
                    && targetSide == expectedTargetSide
                    && validRelativePath(proof.referenceRelativePath)
                    && action.risk == .high
                    && action.issues.isEmpty
                switch proof.authorization {
                case .detectedRenameMatch:
                    isWellFormed = sharedShape
                        && pathKey(sourcePath) != pathKey(targetPath)
                        && proof.referenceSide != targetSide
                        && proof.explicitSourceSnapshot == nil
                        && action.reason == .renameMatchMovedWithinTarget
                case .explicitSameDirectoryRename:
                    let snapshotMatches = proof.explicitSourceSnapshot.map {
                        $0.byteCount == proof.expectedByteCount
                            && $0.sha256 == proof.expectedSHA256Digest
                    } ?? false
                    isWellFormed = sharedShape
                        && pathKey(sourcePath) != pathKey(targetPath)
                        && proof.referenceSide == targetSide
                        && proof.referenceRelativePath == sourcePath
                        && sameParent(sourcePath, targetPath)
                        && snapshotMatches
                        && action.reason == .explicitlyRenamedWithinSide
                case .explicitSameDirectoryCaseOnlyRename:
                    let snapshotMatches = proof.explicitSourceSnapshot.map {
                        $0.byteCount == proof.expectedByteCount
                            && $0.sha256 == proof.expectedSHA256Digest
                    } ?? false
                    isWellFormed = sharedShape
                        && sourcePath.precomposedStringWithCanonicalMapping
                            != targetPath.precomposedStringWithCanonicalMapping
                        && pathKey(sourcePath) == pathKey(targetPath)
                        && proof.referenceSide == targetSide
                        && proof.referenceRelativePath == sourcePath
                        && sameParent(sourcePath, targetPath)
                        && snapshotMatches
                        && action.reason == .explicitlyRenamedWithinSide
                }
            } else {
                isWellFormed = false
            }
            if !isWellFormed {
                issues.append(
                    issue(
                        .malformedAction,
                        index: index,
                        path: displayedPath(action),
                        "A move requires a high-risk same-side action and a valid detected-match or explicit-rename proof."
                    )
                )
                isValid = false
            }
        case .delete:
            if action.sourceSide != nil || action.sourceRelativePath != nil ||
                action.targetSide == nil || action.targetRelativePath == nil {
                issues.append(
                    issue(
                        .malformedAction,
                        index: index,
                        path: displayedPath(action),
                        "Delete requires only a target side and relative path."
                    )
                )
                isValid = false
            }
        case .conflict, .noOp:
            break
        }

        if let mirrorTarget = mirrorTargetSide(for: mode),
           action.kind != .move,
           action.kind != .conflict,
           action.kind != .noOp {
            let sourceMustBeAuthoritative = action.kind == .copy
                || action.kind == .createDirectory
                || action.kind == .replace
            if action.targetSide != mirrorTarget
                || (sourceMustBeAuthoritative && action.sourceSide == mirrorTarget) {
                issues.append(
                    issue(
                        .malformedAction,
                        index: index,
                        path: displayedPath(action),
                        "Every mutating mirror action must write only to the mirror target and read materialized content from the authoritative side."
                    )
                )
                isValid = false
            }
        }

        guard isValid else { return nil }

        let sourceURL = action.sourceSide.flatMap { side in
            action.sourceRelativePath.map { roots.root(for: side).appending(path: $0) }
        }
        let targetURL = action.targetSide.flatMap { side in
            action.targetRelativePath.map { roots.root(for: side).appending(path: $0) }
        }
        let backupURL: URL?
        if action.kind == .delete || action.kind == .replace {
            backupURL = roots.backup
                .appending(path: action.targetSide!.rawValue, directoryHint: .isDirectory)
                .appending(path: action.targetRelativePath!)
        } else {
            backupURL = nil
        }

        for url in [sourceURL, targetURL, backupURL].compactMap({ $0 }) {
            let expectedRoot: URL
            if url == backupURL {
                expectedRoot = roots.backup
            } else if url == sourceURL, let side = action.sourceSide {
                expectedRoot = roots.root(for: side)
            } else if let side = action.targetSide {
                expectedRoot = roots.root(for: side)
            } else {
                continue
            }
            if !contains(url, in: expectedRoot) {
                issues.append(
                    issue(
                        .invalidRelativePath,
                        index: index,
                        path: url.path,
                        "The resolved action path escapes its root."
                    )
                )
                return nil
            }
        }

        let moveRequest: LocalVerifiedFileMoveRequest?
        if action.kind == .move,
           let sourcePath = action.sourceRelativePath,
           let targetPath = action.targetRelativePath,
           let targetSide = action.targetSide,
           let proof = action.moveProof {
            let referenceBinding: LocalVerifiedFileMoveReferenceBinding = switch proof.authorization {
            case .detectedRenameMatch:
                .independent
            case .explicitSameDirectoryRename:
                .selectedSource
            case .explicitSameDirectoryCaseOnlyRename:
                .selectedSourceCaseOnlyRename
            }
            moveRequest = LocalVerifiedFileMoveRequest(
                targetRoot: roots.root(for: targetSide),
                sourceRelativePath: sourcePath,
                destinationRelativePath: targetPath,
                referenceRoot: roots.root(for: proof.referenceSide),
                referenceRelativePath: proof.referenceRelativePath,
                proof: LocalVerifiedFileMoveProof(
                    expectedByteCount: proof.expectedByteCount,
                    expectedSHA256: proof.expectedSHA256Digest
                ),
                expectedSourceSnapshot: proof.explicitSourceSnapshot,
                referenceBinding: referenceBinding,
                allowsCrossDeviceFallback: proof.authorization == .detectedRenameMatch
            )
        } else {
            moveRequest = nil
        }

        return ValidatedActionPaths(
            sourceURL: sourceURL,
            targetURL: targetURL,
            backupURL: backupURL,
            moveRequest: moveRequest
        )
    }

    private func validateSourceLeaf(
        _ url: URL,
        action: FolderSyncAction,
        index: Int,
        issues: inout [LocalFolderSyncExecutionIssue]
    ) {
        guard let kind = itemKind(at: url) else {
            issues.append(
                issue(.missingSource, index: index, path: action.sourceRelativePath, "The source does not exist.")
            )
            return
        }

        let expected: LocalItemKind = action.kind == .createDirectory ? .directory : .regularFile
        if kind != expected {
            issues.append(
                issue(
                    .unexpectedSourceType,
                    index: index,
                    path: action.sourceRelativePath,
                    action.kind == .createDirectory
                        ? "A directory creation action requires a source directory."
                        : "Copy, replace, and move require a regular source file."
                )
            )
        }
    }

    private func validateTargetLeaf(
        _ url: URL,
        action: FolderSyncAction,
        index: Int,
        issues: inout [LocalFolderSyncExecutionIssue]
    ) {
        let kind = itemKind(at: url)
        switch action.kind {
        case .copy, .createDirectory:
            if kind != nil {
                issues.append(
                    issue(
                        .invalidTargetState,
                        index: index,
                        path: action.targetRelativePath,
                        "Copy and create-directory targets must not already exist."
                    )
                )
            }
        case .replace:
            if kind != .regularFile {
                issues.append(
                    issue(
                        .invalidTargetState,
                        index: index,
                        path: action.targetRelativePath,
                        "Replace currently requires an existing regular target file."
                    )
                )
            }
        case .delete:
            if kind == nil {
                issues.append(
                    issue(
                        .invalidTargetState,
                        index: index,
                        path: action.targetRelativePath,
                        "A delete target must exist."
                    )
                )
            }
        case .move:
            if action.moveProof?.authorization != .explicitSameDirectoryCaseOnlyRename,
               kind != nil {
                issues.append(
                    issue(
                        .invalidTargetState,
                        index: index,
                        path: action.targetRelativePath,
                        "A move destination must not already exist."
                    )
                )
            }
        case .conflict, .noOp:
            break
        }
    }

    private func validateIntermediateComponents(
        root: URL,
        relativePath: String,
        plannedDirectories: Set<SidePath>,
        side: FolderSyncSide,
        allowUnplannedMissing: Bool,
        index: Int,
        issues: inout [LocalFolderSyncExecutionIssue]
    ) {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 1 else { return }

        var current = root
        var prefix: [String] = []
        for component in components.dropLast() {
            prefix.append(component)
            current.append(path: component, directoryHint: .isDirectory)

            switch itemKind(at: current) {
            case .symbolicLink:
                issues.append(
                    issue(
                        .symbolicLinkTraversal,
                        index: index,
                        path: prefix.joined(separator: "/"),
                        "An intermediate path component is a symbolic link."
                    )
                )
                return
            case .directory:
                continue
            case .regularFile, .other:
                issues.append(
                    issue(
                        .missingParentDirectory,
                        index: index,
                        path: prefix.joined(separator: "/"),
                        "An intermediate path component is not a directory."
                    )
                )
                return
            case nil:
                let prefixPath = prefix.joined(separator: "/")
                if !allowUnplannedMissing,
                   !plannedDirectories.contains(SidePath(side: side, path: prefixPath)) {
                    issues.append(
                        issue(
                            .missingParentDirectory,
                            index: index,
                            path: prefixPath,
                            "An intermediate directory is missing and is not created by this plan."
                        )
                    )
                    return
                }
            }
        }
    }

    private func perform(
        plan: FolderSyncPlan,
        context: ExecutionContext
    ) async -> LocalFolderSyncExecutionLog {
        let fileManager = FileManager()
        var results = plan.actions.enumerated().map { index, action in
            LocalFolderSyncItemResult(
                actionIndex: index,
                action: action,
                status: .notRun,
                message: "Not run."
            )
        }
        var undoRecords: [UndoRecord] = []
        var pendingBackups: [PendingBackup] = []
        var finalizedBackups: [PendingBackup] = []
        var createdBackupDirectories: [URL] = []
        let transactionRoot = context.roots.backup
            .appending(path: ".riffa-transactions", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)

        for prepared in context.actions {
            do {
                try Task.checkCancellation()
                if injectedFailureActionIndex == prepared.index {
                    throw ExecutionFailure(message: "Injected execution failure.")
                }

                try revalidate(prepared, roots: context.roots)
                if let moveRequest = prepared.paths.moveRequest {
                    let moveResult = try await verifiedFileMove.execute(moveRequest)
                    undoRecords.append(
                        .reverseMove(
                            actionIndex: prepared.index,
                            request: moveRequest,
                            installedSourceSnapshot: moveResult.installedSourceSnapshot
                        )
                    )
                } else {
                    try apply(
                        prepared,
                        roots: context.roots,
                        transactionRoot: transactionRoot,
                        fileManager: fileManager,
                        undoRecords: &undoRecords,
                        pendingBackups: &pendingBackups,
                        createdBackupDirectories: &createdBackupDirectories
                    )
                }
                results[prepared.index] = LocalFolderSyncItemResult(
                    actionIndex: prepared.index,
                    action: prepared.action,
                    status: .completed,
                    message: prepared.action.kind == .noOp ? "No change was required." : "Completed."
                )
            } catch {
                let wasCancelled = error is CancellationError
                let moveRollbackIncomplete: Bool
                if case .rollbackIncomplete = error as? LocalVerifiedFileMoveError {
                    moveRollbackIncomplete = true
                } else {
                    moveRollbackIncomplete = false
                }
                let failureIssue = issue(
                    wasCancelled ? .cancelled : .executionFailed,
                    index: prepared.index,
                    path: displayedPath(prepared.action),
                    wasCancelled
                        ? "Execution was cancelled; completed actions are being rolled back."
                        : "Execution failed: \(error.localizedDescription)"
                )
                results[prepared.index] = LocalFolderSyncItemResult(
                    actionIndex: prepared.index,
                    action: prepared.action,
                    status: .failed,
                    message: failureIssue.message
                )

                let rollbackResult = await rollback(
                    records: undoRecords,
                    results: results,
                    fileManager: fileManager
                )
                results = rollbackResult.results
                var rollbackIssues = rollbackResult.issues
                if moveRollbackIncomplete {
                    let rollbackIssue = issue(
                        .rollbackFailed,
                        index: prepared.index,
                        path: displayedPath(prepared.action),
                        "The verified move could not fully restore its original public path."
                    )
                    rollbackIssues.append(rollbackIssue)
                    results[prepared.index] = LocalFolderSyncItemResult(
                        actionIndex: prepared.index,
                        action: prepared.action,
                        status: .rollbackFailed,
                        message: rollbackIssue.message
                    )
                }
                removeCreatedBackupDirectories(
                    createdBackupDirectories,
                    fileManager: fileManager
                )
                let rollbackSucceeded = rollbackIssues.isEmpty
                return LocalFolderSyncExecutionLog(
                    mode: plan.mode,
                    status: rollbackSucceeded ? .failedRolledBack : .failedRollbackIncomplete,
                    dryRun: false,
                    rollbackAttempted: !undoRecords.isEmpty || moveRollbackIncomplete,
                    rollbackSucceeded: undoRecords.isEmpty && !moveRollbackIncomplete
                        ? nil
                        : rollbackSucceeded,
                    itemResults: results,
                    issues: [failureIssue] + rollbackIssues
                )
            }
        }

        do {
            try finalizeBackups(
                pendingBackups,
                roots: context.roots,
                fileManager: fileManager,
                finalized: &finalizedBackups,
                createdBackupDirectories: &createdBackupDirectories
            )
        } catch {
            let failedIndex = (error as? BackupFinalizationFailure)?.actionIndex
                ?? pendingBackups.first?.actionIndex
                ?? 0
            let failureIssue = issue(
                .executionFailed,
                index: failedIndex,
                path: plan.actions.indices.contains(failedIndex)
                    ? displayedPath(plan.actions[failedIndex])
                    : nil,
                "Backup finalization failed: \(error.localizedDescription)"
            )
            if results.indices.contains(failedIndex) {
                results[failedIndex] = LocalFolderSyncItemResult(
                    actionIndex: failedIndex,
                    action: results[failedIndex].action,
                    status: .failed,
                    message: failureIssue.message
                )
            }

            var rollbackIssues: [LocalFolderSyncExecutionIssue] = []
            restoreFinalizedBackupsToStaging(
                finalizedBackups,
                fileManager: fileManager,
                issues: &rollbackIssues
            )
            let rollbackResult = await rollback(
                records: undoRecords,
                results: results,
                fileManager: fileManager
            )
            results = rollbackResult.results
            rollbackIssues.append(contentsOf: rollbackResult.issues)
            removeCreatedBackupDirectories(createdBackupDirectories, fileManager: fileManager)
            let rollbackSucceeded = rollbackIssues.isEmpty
            return LocalFolderSyncExecutionLog(
                mode: plan.mode,
                status: rollbackSucceeded ? .failedRolledBack : .failedRollbackIncomplete,
                dryRun: false,
                rollbackAttempted: !undoRecords.isEmpty,
                rollbackSucceeded: undoRecords.isEmpty ? nil : rollbackSucceeded,
                itemResults: results,
                issues: [failureIssue] + rollbackIssues
            )
        }

        removeEmptyTransactionDirectories(transactionRoot, fileManager: fileManager)

        return LocalFolderSyncExecutionLog(
            mode: plan.mode,
            status: .completed,
            dryRun: false,
            rollbackAttempted: false,
            rollbackSucceeded: nil,
            itemResults: results,
            issues: []
        )
    }

    private func revalidate(_ prepared: PreparedAction, roots: ExecutionRoots) throws {
        let action = prepared.action
        if let sourceURL = prepared.paths.sourceURL,
           action.kind == .copy || action.kind == .replace || action.kind == .createDirectory {
            try requireNoSymbolicLinkIntermediates(
                root: roots.root(for: action.sourceSide!),
                relativePath: action.sourceRelativePath!
            )
            let expected: LocalItemKind = action.kind == .createDirectory ? .directory : .regularFile
            guard itemKind(at: sourceURL) == expected else {
                throw ExecutionFailure(message: "The source changed after preflight.")
            }
        }

        if let targetURL = prepared.paths.targetURL,
           action.kind != .noOp,
           action.kind != .conflict {
            try requireNoSymbolicLinkIntermediates(
                root: roots.root(for: action.targetSide!),
                relativePath: action.targetRelativePath!
            )
            let kind = itemKind(at: targetURL)
            switch action.kind {
            case .copy, .createDirectory:
                guard kind == nil else {
                    throw ExecutionFailure(message: "The target appeared after preflight.")
                }
            case .replace:
                guard kind == .regularFile else {
                    throw ExecutionFailure(message: "The replacement target changed after preflight.")
                }
            case .delete:
                guard kind != nil else {
                    throw ExecutionFailure(message: "The deletion target disappeared after preflight.")
                }
            case .move:
                // The descriptor-backed mover repeats the full proof, source,
                // destination, and path-binding validation immediately before
                // its no-clobber mutation.
                break
            case .conflict, .noOp:
                break
            }
        }
    }

    private func apply(
        _ prepared: PreparedAction,
        roots: ExecutionRoots,
        transactionRoot: URL,
        fileManager: FileManager,
        undoRecords: inout [UndoRecord],
        pendingBackups: inout [PendingBackup],
        createdBackupDirectories: inout [URL]
    ) throws {
        switch prepared.action.kind {
        case .noOp:
            return

        case .conflict:
            throw ExecutionFailure(message: "Conflicts are never executable.")

        case .move:
            throw ExecutionFailure(message: "A verified move bypassed its descriptor-backed execution path.")

        case .createDirectory:
            let target = prepared.paths.targetURL!
            try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
            undoRecords.append(.removeCreated(actionIndex: prepared.index, url: target))

        case .copy:
            let source = prepared.paths.sourceURL!
            let target = prepared.paths.targetURL!
            let temporary = try temporaryCopy(
                source: source,
                beside: target,
                fileManager: fileManager
            )
            defer { try? removeIfPresent(temporary, fileManager: fileManager) }
            try fileManager.moveItem(at: temporary, to: target)
            undoRecords.append(.removeCreated(actionIndex: prepared.index, url: target))

        case .replace:
            let source = prepared.paths.sourceURL!
            let target = prepared.paths.targetURL!
            let finalBackup = prepared.paths.backupURL!
            let stagingBackup = transactionRoot.appending(path: String(prepared.index))
            let temporary = try temporaryCopy(
                source: source,
                beside: target,
                fileManager: fileManager
            )
            defer { try? removeIfPresent(temporary, fileManager: fileManager) }
            try createParentDirectories(
                for: stagingBackup,
                stoppingAt: roots.backup,
                fileManager: fileManager,
                created: &createdBackupDirectories
            )
            try requireNoSymbolicLinkIntermediates(
                root: roots.backup,
                relativePath: relativePath(of: stagingBackup, below: roots.backup)
            )
            guard itemKind(at: stagingBackup) == nil,
                  itemKind(at: finalBackup) == nil else {
                throw ExecutionFailure(message: "A backup destination appeared after preflight.")
            }
            try fileManager.moveItem(at: target, to: stagingBackup)
            undoRecords.append(
                .restoreBackup(
                    actionIndex: prepared.index,
                    target: target,
                    backup: stagingBackup,
                    removeCurrentTarget: true
                )
            )
            pendingBackups.append(
                PendingBackup(
                    actionIndex: prepared.index,
                    staging: stagingBackup,
                    final: finalBackup
                )
            )
            try fileManager.moveItem(at: temporary, to: target)

        case .delete:
            let target = prepared.paths.targetURL!
            let finalBackup = prepared.paths.backupURL!
            let stagingBackup = transactionRoot.appending(path: String(prepared.index))
            try createParentDirectories(
                for: stagingBackup,
                stoppingAt: roots.backup,
                fileManager: fileManager,
                created: &createdBackupDirectories
            )
            try requireNoSymbolicLinkIntermediates(
                root: roots.backup,
                relativePath: relativePath(of: stagingBackup, below: roots.backup)
            )
            guard itemKind(at: stagingBackup) == nil,
                  itemKind(at: finalBackup) == nil else {
                throw ExecutionFailure(message: "A backup destination appeared after preflight.")
            }
            try fileManager.moveItem(at: target, to: stagingBackup)
            undoRecords.append(
                .restoreBackup(
                    actionIndex: prepared.index,
                    target: target,
                    backup: stagingBackup,
                    removeCurrentTarget: false
                )
            )
            pendingBackups.append(
                PendingBackup(
                    actionIndex: prepared.index,
                    staging: stagingBackup,
                    final: finalBackup
                )
            )
        }
    }

    private func finalizeBackups(
        _ pendingBackups: [PendingBackup],
        roots: ExecutionRoots,
        fileManager: FileManager,
        finalized: inout [PendingBackup],
        createdBackupDirectories: inout [URL]
    ) throws {
        let ordered = pendingBackups.sorted { left, right in
            let leftDepth = left.final.pathComponents.count
            let rightDepth = right.final.pathComponents.count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            if left.final.path != right.final.path { return left.final.path < right.final.path }
            return left.actionIndex < right.actionIndex
        }

        for backup in ordered {
            do {
                try createParentDirectories(
                    for: backup.final,
                    stoppingAt: roots.backup,
                    fileManager: fileManager,
                    created: &createdBackupDirectories
                )
                try requireNoSymbolicLinkIntermediates(
                    root: roots.backup,
                    relativePath: relativePath(of: backup.final, below: roots.backup)
                )
                guard itemKind(at: backup.final) == nil else {
                    throw ExecutionFailure(message: "The final backup destination is occupied.")
                }
                try fileManager.moveItem(at: backup.staging, to: backup.final)
                finalized.append(backup)
            } catch {
                throw BackupFinalizationFailure(actionIndex: backup.actionIndex, underlying: error)
            }
        }
    }

    private func restoreFinalizedBackupsToStaging(
        _ finalized: [PendingBackup],
        fileManager: FileManager,
        issues: inout [LocalFolderSyncExecutionIssue]
    ) {
        for backup in finalized.reversed() {
            do {
                guard itemKind(at: backup.final) != nil,
                      itemKind(at: backup.staging) == nil else {
                    throw ExecutionFailure(message: "A finalized backup cannot be returned to staging.")
                }
                try fileManager.moveItem(at: backup.final, to: backup.staging)
            } catch {
                issues.append(
                    issue(
                        .rollbackFailed,
                        index: backup.actionIndex,
                        path: backup.final.path,
                        "Could not unwind backup finalization: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    private func rollback(
        records: [UndoRecord],
        results initialResults: [LocalFolderSyncItemResult],
        fileManager: FileManager
    ) async -> (
        results: [LocalFolderSyncItemResult],
        issues: [LocalFolderSyncExecutionIssue]
    ) {
        var results = initialResults
        var issues: [LocalFolderSyncExecutionIssue] = []
        for record in records.reversed() {
            let index = record.actionIndex
            do {
                switch record {
                case let .removeCreated(_, url):
                    try removeIfPresent(url, fileManager: fileManager)

                case let .restoreBackup(_, target, backup, removeCurrentTarget):
                    if removeCurrentTarget {
                        try removeIfPresent(target, fileManager: fileManager)
                    }
                    guard itemKind(at: backup) != nil else {
                        throw ExecutionFailure(message: "The rollback backup is missing.")
                    }
                    guard itemKind(at: target) == nil else {
                        throw ExecutionFailure(message: "The rollback target is occupied.")
                    }
                    try fileManager.moveItem(at: backup, to: target)

                case let .reverseMove(_, request, installedSourceSnapshot):
                    try await reverseVerifiedMove(
                        request,
                        installedSourceSnapshot: installedSourceSnapshot
                    )
                }

                results[index] = LocalFolderSyncItemResult(
                    actionIndex: index,
                    action: results[index].action,
                    status: .rolledBack,
                    message: "Completed, then rolled back after a later failure."
                )
            } catch {
                let rollbackIssue = issue(
                    .rollbackFailed,
                    index: index,
                    path: displayedPath(results[index].action),
                    "Rollback failed: \(error.localizedDescription)"
                )
                issues.append(rollbackIssue)
                results[index] = LocalFolderSyncItemResult(
                    actionIndex: index,
                    action: results[index].action,
                    status: .rollbackFailed,
                    message: rollbackIssue.message
                )
            }
        }
        return (results, issues)
    }

    private func reverseVerifiedMove(
        _ request: LocalVerifiedFileMoveRequest,
        installedSourceSnapshot: LocalVerifiedFileMoveSourceSnapshot?
    ) async throws {
        let referenceRoot: URL
        let referenceRelativePath: String
        switch request.referenceBinding {
        case .independent:
            referenceRoot = request.referenceRoot
            referenceRelativePath = request.referenceRelativePath
        case .selectedSource, .selectedSourceCaseOnlyRename:
            // The explicitly selected reference moved with the source, so the
            // installed destination is the only valid self-reference during
            // transaction rollback.
            referenceRoot = request.targetRoot
            referenceRelativePath = request.destinationRelativePath
        }
        let reverse = LocalVerifiedFileMoveRequest(
            targetRoot: request.targetRoot,
            sourceRelativePath: request.destinationRelativePath,
            destinationRelativePath: request.sourceRelativePath,
            referenceRoot: referenceRoot,
            referenceRelativePath: referenceRelativePath,
            proof: request.proof,
            expectedSourceSnapshot: installedSourceSnapshot,
            referenceBinding: request.referenceBinding,
            allowsCrossDeviceFallback: request.allowsCrossDeviceFallback
        )
        let mover = verifiedFileMove
        _ = try await Task.detached(priority: .userInitiated) {
            try await mover.execute(reverse)
        }.value
    }

    private func refusalLog(
        plan: FolderSyncPlan,
        dryRun: Bool,
        issues: [LocalFolderSyncExecutionIssue]
    ) -> LocalFolderSyncExecutionLog {
        LocalFolderSyncExecutionLog(
            mode: plan.mode,
            status: .refused,
            dryRun: dryRun,
            rollbackAttempted: false,
            rollbackSucceeded: nil,
            itemResults: plan.actions.enumerated().map { index, action in
                LocalFolderSyncItemResult(
                    actionIndex: index,
                    action: action,
                    status: .refused,
                    message: "The plan failed preflight; no file-system changes were made."
                )
            },
            issues: issues
        )
    }

    private func validRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func pathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func mirrorTargetSide(for mode: FolderSyncMode) -> FolderSyncSide? {
        switch mode {
        case .mirrorLeftToRight:
            .right
        case .mirrorRightToLeft:
            .left
        case .updateLeft, .updateRight, .updateBoth:
            nil
        }
    }

    private func canonicalExistingDirectory(
        _ url: URL,
        label: String,
        issues: inout [LocalFolderSyncExecutionIssue]
    ) -> URL? {
        guard url.isFileURL else {
            issues.append(issue(.invalidRoot, path: url.absoluteString, "The \(label) must be a file URL."))
            return nil
        }
        guard let canonical = canonicalFileSystemURL(url.standardizedFileURL) else {
            issues.append(issue(.invalidRoot, path: url.path, "The \(label) could not be resolved safely."))
            return nil
        }
        guard itemKind(at: canonical) == .directory else {
            issues.append(issue(.invalidRoot, path: canonical.path, "The \(label) must be an existing directory."))
            return nil
        }
        return canonical
    }

    private func canonicalPotentialDirectory(
        _ url: URL,
        label: String,
        issues: inout [LocalFolderSyncExecutionIssue]
    ) -> URL? {
        guard url.isFileURL else {
            issues.append(issue(.invalidRoot, path: url.absoluteString, "The \(label) must be a file URL."))
            return nil
        }

        let standardized = url.standardizedFileURL
        var ancestor = standardized
        var missingComponents: [String] = []
        while itemKind(at: ancestor) == nil {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else {
                issues.append(issue(.invalidRoot, path: standardized.path, "The \(label) has no accessible ancestor."))
                return nil
            }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
        }

        guard let canonicalAncestor = canonicalFileSystemURL(ancestor) else {
            issues.append(issue(.invalidRoot, path: ancestor.path, "The \(label) has no safely resolvable ancestor."))
            return nil
        }
        guard itemKind(at: canonicalAncestor) == .directory else {
            issues.append(issue(.invalidRoot, path: ancestor.path, "An ancestor of the \(label) is not a directory."))
            return nil
        }
        return missingComponents.reversed().reduce(canonicalAncestor) { partial, component in
            partial.appending(path: component, directoryHint: .isDirectory)
        }
    }

    private func canonicalFileSystemURL(_ url: URL) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = url.path.withCString { path in
            buffer.withUnsafeMutableBufferPointer { storage in
                Darwin.realpath(path, storage.baseAddress)
            }
        }
        guard resolved != nil else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(
            fileURLWithPath: String(decoding: bytes, as: UTF8.self),
            isDirectory: true
        )
    }

    private func requireNoSymbolicLinkIntermediates(root: URL, relativePath: String) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count > 1 else { return }
        var current = root
        for component in components.dropLast() {
            current.append(path: String(component), directoryHint: .isDirectory)
            if itemKind(at: current) == .symbolicLink {
                throw ExecutionFailure(message: "An intermediate path component became a symbolic link.")
            }
        }
    }

    private func temporaryCopy(source: URL, beside target: URL, fileManager: FileManager) throws -> URL {
        let parent = target.deletingLastPathComponent()
        var temporary: URL
        repeat {
            temporary = parent.appending(
                path: ".riffa-\(UUID().uuidString).tmp",
                directoryHint: .notDirectory
            )
        } while itemKind(at: temporary) != nil
        try fileManager.copyItem(at: source, to: temporary)
        return temporary
    }

    private func createParentDirectories(
        for item: URL,
        stoppingAt root: URL,
        fileManager: FileManager,
        created: inout [URL]
    ) throws {
        var current = item.deletingLastPathComponent()
        var missing: [URL] = []
        while current.path != root.path {
            switch itemKind(at: current) {
            case nil:
                missing.append(current)
                current = current.deletingLastPathComponent()
            case .directory:
                current = root
            case .symbolicLink:
                throw ExecutionFailure(message: "A backup parent is a symbolic link.")
            case .regularFile, .other:
                throw ExecutionFailure(message: "A backup parent is not a directory.")
            }
        }
        switch itemKind(at: root) {
        case nil:
            missing.append(root)
        case .directory:
            break
        case .symbolicLink:
            throw ExecutionFailure(message: "The backup root became a symbolic link.")
        case .regularFile, .other:
            throw ExecutionFailure(message: "The backup root is not a directory.")
        }

        for directory in missing.reversed() {
            let parent = directory.deletingLastPathComponent()
            guard itemKind(at: parent) == .directory else {
                throw ExecutionFailure(message: "A backup directory parent changed before creation.")
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            created.append(directory)
        }
    }

    private func removeCreatedBackupDirectories(_ directories: [URL], fileManager: FileManager) {
        for directory in directories.reversed() {
            guard itemKind(at: directory) == .directory else { continue }
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path), contents.isEmpty else {
                continue
            }
            try? fileManager.removeItem(at: directory)
        }
    }

    private func removeEmptyTransactionDirectories(_ transactionRoot: URL, fileManager: FileManager) {
        let transactionsRoot = transactionRoot.deletingLastPathComponent()
        for directory in [transactionRoot, transactionsRoot] {
            guard itemKind(at: directory) == .directory,
                  let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
                  contents.isEmpty else {
                continue
            }
            try? fileManager.removeItem(at: directory)
        }
    }

    private func removeIfPresent(_ url: URL, fileManager: FileManager) throws {
        if itemKind(at: url) != nil {
            try fileManager.removeItem(at: url)
        }
    }

    private func itemKind(at url: URL) -> LocalItemKind? {
        var information = stat()
        let result = url.path.withCString { pointer in
            Darwin.lstat(pointer, &information)
        }
        guard result == 0 else { return nil }
        switch information.st_mode & S_IFMT {
        case S_IFREG:
            return .regularFile
        case S_IFDIR:
            return .directory
        case S_IFLNK:
            return .symbolicLink
        default:
            return .other
        }
    }

    private func pathsOverlap(_ first: URL, _ second: URL) -> Bool {
        contains(first, in: second) || contains(second, in: first)
    }

    private func sameParent(_ first: String, _ second: String) -> Bool {
        first.split(separator: "/", omittingEmptySubsequences: false).dropLast()
            == second.split(separator: "/", omittingEmptySubsequences: false).dropLast()
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func displayedPath(_ action: FolderSyncAction) -> String? {
        action.targetRelativePath ?? action.sourceRelativePath
    }

    private func backupRelativePath(_ action: FolderSyncAction) -> String {
        [action.targetSide!.rawValue, action.targetRelativePath!].joined(separator: "/")
    }

    private func relativePath(of url: URL, below root: URL) -> String {
        String(url.path.dropFirst(root.path.count + 1))
    }

    private func issue(
        _ code: LocalFolderSyncExecutionIssue.Code,
        index: Int? = nil,
        path: String? = nil,
        _ message: String
    ) -> LocalFolderSyncExecutionIssue {
        LocalFolderSyncExecutionIssue(code: code, actionIndex: index, path: path, message: message)
    }
}

private enum LocalItemKind {
    case regularFile
    case directory
    case symbolicLink
    case other
}

private struct SidePath: Hashable {
    let side: FolderSyncSide
    let path: String
}

private struct ExecutionRoots {
    let left: URL
    let right: URL
    let backup: URL

    func root(for side: FolderSyncSide) -> URL {
        switch side {
        case .left:
            left
        case .right:
            right
        }
    }
}

private struct ValidatedActionPaths {
    let sourceURL: URL?
    let targetURL: URL?
    let backupURL: URL?
    let moveRequest: LocalVerifiedFileMoveRequest?
}

private struct PreparedAction {
    let index: Int
    let action: FolderSyncAction
    let paths: ValidatedActionPaths
}

private struct ExecutionContext {
    let roots: ExecutionRoots
    let actions: [PreparedAction]
}

private struct PendingBackup {
    let actionIndex: Int
    let staging: URL
    let final: URL
}

private enum PreflightOutcome {
    case success(ExecutionContext)
    case failure([LocalFolderSyncExecutionIssue])
}

private enum UndoRecord {
    case removeCreated(actionIndex: Int, url: URL)
    case reverseMove(
        actionIndex: Int,
        request: LocalVerifiedFileMoveRequest,
        installedSourceSnapshot: LocalVerifiedFileMoveSourceSnapshot?
    )
    case restoreBackup(
        actionIndex: Int,
        target: URL,
        backup: URL,
        removeCurrentTarget: Bool
    )

    var actionIndex: Int {
        switch self {
        case let .removeCreated(actionIndex, _),
             let .reverseMove(actionIndex, _, _),
             let .restoreBackup(actionIndex, _, _, _):
            actionIndex
        }
    }
}

private struct ExecutionFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct BackupFinalizationFailure: Error, LocalizedError {
    let actionIndex: Int
    let underlying: any Error

    var errorDescription: String? {
        underlying.localizedDescription
    }
}
