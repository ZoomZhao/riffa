import Darwin
import Foundation

public enum FolderMergeConflictResolution: String, CaseIterable, Hashable, Codable, Sendable {
    case useBase
    case useLeft
    case useRight
    case omit
}

public struct FolderMergeOutputOptions: Hashable, Sendable {
    public let dryRun: Bool

    public init(dryRun: Bool = true) {
        self.dryRun = dryRun
    }
}

public enum FolderMergeOutputExecutionStatus: String, Hashable, Codable, Sendable {
    case dryRun
    case completed
    case refused
    case failedRolledBack
    case failedRollbackIncomplete
}

public enum FolderMergeOutputItemStatus: String, Hashable, Codable, Sendable {
    case planned
    case completed
    case refused
    case failed
    case notRun
    case rolledBack
    case rollbackFailed
}

public struct FolderMergeOutputIssue: Error, Hashable, Sendable, LocalizedError {
    public enum Code: String, Hashable, Codable, Sendable {
        case invalidRoot
        case overlappingRoots
        case unresolvedConflict
        case unexpectedResolution
        case invalidRelativePath
        case malformedAction
        case duplicateOutputPath
        case invalidPlanStructure
        case missingSource
        case unsupportedSourceType
        case symbolicLinkTraversal
        case missingParentDirectory
        case backupCollision
        case targetChanged
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

public struct FolderMergeOutputItemResult: Hashable, Sendable {
    public let actionIndex: Int
    public let action: FolderMergeAction
    public let resolution: FolderMergeConflictResolution?
    public let status: FolderMergeOutputItemStatus
    public let message: String

    public init(
        actionIndex: Int,
        action: FolderMergeAction,
        resolution: FolderMergeConflictResolution?,
        status: FolderMergeOutputItemStatus,
        message: String
    ) {
        self.actionIndex = actionIndex
        self.action = action
        self.resolution = resolution
        self.status = status
        self.message = message
    }
}

public struct FolderMergeOutputExecutionLog: Hashable, Sendable {
    public let status: FolderMergeOutputExecutionStatus
    public let dryRun: Bool
    public let rollbackAttempted: Bool
    public let rollbackSucceeded: Bool?
    public let itemResults: [FolderMergeOutputItemResult]
    public let issues: [FolderMergeOutputIssue]

    public init(
        status: FolderMergeOutputExecutionStatus,
        dryRun: Bool,
        rollbackAttempted: Bool,
        rollbackSucceeded: Bool?,
        itemResults: [FolderMergeOutputItemResult],
        issues: [FolderMergeOutputIssue]
    ) {
        self.status = status
        self.dryRun = dryRun
        self.rollbackAttempted = rollbackAttempted
        self.rollbackSucceeded = rollbackSucceeded
        self.itemResults = itemResults
        self.issues = issues
    }
}

/// Materializes a folder merge plan beneath a separate local output root.
///
/// Source roots are strictly read-only. Existing output items are moved to the
/// caller-provided external backup root before replacement or omission.
public struct FolderMergeOutputExecutor: Sendable {
    private let injectedFailureActionIndex: Int?

    public init() {
        injectedFailureActionIndex = nil
    }

    init(testingFailureAtActionIndex index: Int?) {
        injectedFailureActionIndex = index
    }

    public func execute(
        plan: FolderMergePlan,
        resolutions: [String: FolderMergeConflictResolution] = [:],
        baseRoot: URL,
        leftRoot: URL,
        rightRoot: URL,
        outputRoot: URL,
        backupRoot: URL,
        options: FolderMergeOutputOptions = .init()
    ) -> FolderMergeOutputExecutionLog {
        let preflight = preflight(
            plan: plan,
            resolutions: resolutions,
            baseRoot: baseRoot,
            leftRoot: leftRoot,
            rightRoot: rightRoot,
            outputRoot: outputRoot,
            backupRoot: backupRoot
        )

        switch preflight {
        case let .failure(issues):
            return refusalLog(plan: plan, resolutions: resolutions, dryRun: options.dryRun, issues: issues)

        case let .success(context):
            if options.dryRun {
                return FolderMergeOutputExecutionLog(
                    status: .dryRun,
                    dryRun: true,
                    rollbackAttempted: false,
                    rollbackSucceeded: nil,
                    itemResults: plan.actions.enumerated().map { index, action in
                        FolderMergeOutputItemResult(
                            actionIndex: index,
                            action: action,
                            resolution: resolutions[action.outputRelativePath],
                            status: .planned,
                            message: "Preflight passed; no file-system changes were made."
                        )
                    },
                    issues: []
                )
            }
            return perform(plan: plan, resolutions: resolutions, context: context)
        }
    }

    private func preflight(
        plan: FolderMergePlan,
        resolutions: [String: FolderMergeConflictResolution],
        baseRoot: URL,
        leftRoot: URL,
        rightRoot: URL,
        outputRoot: URL,
        backupRoot: URL
    ) -> OutputPreflightOutcome {
        var issues: [FolderMergeOutputIssue] = []
        let base = canonicalExistingDirectory(baseRoot, label: "base root", issues: &issues)
        let left = canonicalExistingDirectory(leftRoot, label: "left root", issues: &issues)
        let right = canonicalExistingDirectory(rightRoot, label: "right root", issues: &issues)
        let output = canonicalPotentialDirectory(outputRoot, label: "output root", issues: &issues)
        let backup = canonicalPotentialDirectory(backupRoot, label: "backup root", issues: &issues)

        if let base, let left, let right, let output, let backup {
            for (source, label) in [(base, "base"), (left, "left"), (right, "right")] {
                if pathsOverlap(source, output) {
                    issues.append(issue(.overlappingRoots, "The output root must not overlap the \(label) source root."))
                }
                if pathsOverlap(source, backup) {
                    issues.append(issue(.overlappingRoots, "The backup root must not overlap the \(label) source root."))
                }
            }
            if pathsOverlap(output, backup) {
                issues.append(issue(.overlappingRoots, "The output and backup roots must not overlap."))
            }
        }

        let conflictPaths = Set(plan.actions.filter { $0.kind == .conflict }.map(\.outputRelativePath))
        for (index, action) in plan.actions.enumerated() where action.kind == .conflict {
            if resolutions[action.outputRelativePath] == nil {
                issues.append(
                    issue(
                        .unresolvedConflict,
                        index: index,
                        path: action.outputRelativePath,
                        "Every conflict action requires an explicit resolution."
                    )
                )
            }
        }
        for path in resolutions.keys {
            if !validRelativePath(path) {
                issues.append(
                    issue(.invalidRelativePath, path: path, "A resolution key is not a safe relative path.")
                )
            } else if !conflictPaths.contains(path) {
                issues.append(
                    issue(.unexpectedResolution, path: path, "A resolution was supplied for a non-conflict path.")
                )
            }
        }

        guard let base, let left, let right, let output, let backup else {
            return .failure(issues)
        }
        let roots = OutputRoots(base: base, left: left, right: right, output: output, backup: backup)
        if itemKind(at: output) == nil,
           itemKind(at: output.deletingLastPathComponent()) != .directory {
            issues.append(
                issue(
                    .invalidRoot,
                    path: output.path,
                    "A new output root requires an existing direct parent directory."
                )
            )
        }
        var operations: [PreparedOutputOperation] = []
        var outputPaths = Set<String>()

        for (index, action) in plan.actions.enumerated() {
            guard validRelativePath(action.outputRelativePath) else {
                issues.append(
                    issue(
                        .invalidRelativePath,
                        index: index,
                        path: action.outputRelativePath,
                        "Output paths must not be empty or absolute and cannot contain '.', '..', or empty components."
                    )
                )
                continue
            }
            guard outputPaths.insert(normalizedPathKey(action.outputRelativePath)).inserted else {
                issues.append(
                    issue(
                        .duplicateOutputPath,
                        index: index,
                        path: action.outputRelativePath,
                        "The plan contains more than one action for the same output path."
                    )
                )
                continue
            }

            if let operation = prepareOperation(
                action,
                index: index,
                resolution: resolutions[action.outputRelativePath],
                roots: roots,
                issues: &issues
            ) {
                operations.append(operation)
            }
        }

        markCoveredDescendantsAndValidateStructure(operations: &operations, issues: &issues)
        let plannedDirectories = Set(
            operations.compactMap { operation -> String? in
                if case .directory = operation.desired, !operation.isCovered {
                    return operation.action.outputRelativePath
                }
                return nil
            }
        )

        for operation in operations where !operation.isCovered {
            validateIntermediateComponents(
                root: roots.output,
                relativePath: operation.action.outputRelativePath,
                plannedDirectories: plannedDirectories,
                allowAnyMissing: false,
                index: operation.actionIndex,
                issues: &issues
            )

            if operation.expectedTargetKind != nil {
                let finalBackup = backupURL(for: operation.action, roots: roots)
                let backupRelativePath = relativePath(of: finalBackup, below: roots.backup)
                validateIntermediateComponents(
                    root: roots.backup,
                    relativePath: backupRelativePath,
                    plannedDirectories: [],
                    allowAnyMissing: true,
                    index: operation.actionIndex,
                    issues: &issues
                )
                if itemKind(at: finalBackup) != nil {
                    issues.append(
                        issue(
                            .backupCollision,
                            index: operation.actionIndex,
                            path: finalBackup.path,
                            "The final backup destination already exists."
                        )
                    )
                }
            }
        }

        guard issues.isEmpty else { return .failure(issues) }
        return .success(OutputExecutionContext(roots: roots, operations: ordered(operations)))
    }

    private func prepareOperation(
        _ action: FolderMergeAction,
        index: Int,
        resolution: FolderMergeConflictResolution?,
        roots: OutputRoots,
        issues: inout [FolderMergeOutputIssue]
    ) -> PreparedOutputOperation? {
        let outputURL = roots.output.appending(path: action.outputRelativePath)
        guard contains(outputURL, in: roots.output) else {
            issues.append(issue(.invalidRelativePath, index: index, path: action.outputRelativePath, "The output path escapes its root."))
            return nil
        }

        let selection: OutputSelection
        switch action.kind {
        case .copyFromBase:
            guard action.source == .base else {
                issues.append(issue(.malformedAction, index: index, path: action.outputRelativePath, "copyFromBase requires a base source."))
                return nil
            }
            selection = .source(.base, action.sourceRelativePath)

        case .copyFromLeft:
            guard action.source == .left else {
                issues.append(issue(.malformedAction, index: index, path: action.outputRelativePath, "copyFromLeft requires a left source."))
                return nil
            }
            selection = .source(.left, action.sourceRelativePath)

        case .copyFromRight:
            guard action.source == .right else {
                issues.append(issue(.malformedAction, index: index, path: action.outputRelativePath, "copyFromRight requires a right source."))
                return nil
            }
            selection = .source(.right, action.sourceRelativePath)

        case .createDirectory:
            guard let source = action.source else {
                issues.append(issue(.malformedAction, index: index, path: action.outputRelativePath, "createDirectory requires a source tree."))
                return nil
            }
            selection = .directory(source, action.sourceRelativePath)

        case .omit:
            selection = .omit

        case .conflict:
            guard let resolution else { return nil }
            switch resolution {
            case .useBase:
                selection = .resolvedSource(.base)
            case .useLeft:
                selection = .resolvedSource(.left)
            case .useRight:
                selection = .resolvedSource(.right)
            case .omit:
                selection = .omit
            }
        }

        let desired: OutputDesiredState
        var sourceURL: URL?
        var sourceRoot: URL?

        switch selection {
        case .omit:
            desired = .omit

        case let .source(source, path), let .directory(source, path):
            guard let path, validRelativePath(path) else {
                issues.append(
                    issue(.invalidRelativePath, index: index, path: path, "The action has an invalid source relative path.")
                )
                return nil
            }
            let root = roots.root(for: source)
            let url = root.appending(path: path)
            guard contains(url, in: root) else {
                issues.append(issue(.invalidRelativePath, index: index, path: path, "The source path escapes its root."))
                return nil
            }
            validateSourcePath(root: root, relativePath: path, index: index, issues: &issues)
            guard let kind = itemKind(at: url) else {
                issues.append(issue(.missingSource, index: index, path: path, "The selected source does not exist."))
                return nil
            }
            if case .directory = selection {
                guard kind == .directory else {
                    issues.append(issue(.unsupportedSourceType, index: index, path: path, "createDirectory requires a source directory."))
                    return nil
                }
                desired = .directory
            } else {
                guard kind == .regularFile || kind == .symbolicLink else {
                    issues.append(issue(.unsupportedSourceType, index: index, path: path, "Copy actions support regular files and symbolic links."))
                    return nil
                }
                desired = .resource(kind)
                validateReadableSource(url, kind: kind, index: index, path: path, issues: &issues)
            }
            sourceURL = url
            sourceRoot = root

        case let .resolvedSource(source):
            let path = action.outputRelativePath
            let root = roots.root(for: source)
            let url = root.appending(path: path)
            validateSourcePath(root: root, relativePath: path, index: index, issues: &issues)
            guard let kind = itemKind(at: url) else {
                issues.append(issue(.missingSource, index: index, path: path, "The conflict resolution selected a missing source."))
                return nil
            }
            switch kind {
            case .directory:
                desired = .directory
            case .regularFile, .symbolicLink:
                desired = .resource(kind)
                validateReadableSource(url, kind: kind, index: index, path: path, issues: &issues)
            case .other:
                issues.append(issue(.unsupportedSourceType, index: index, path: path, "The selected source type cannot be materialized safely."))
                return nil
            }
            sourceURL = url
            sourceRoot = root
        }

        return PreparedOutputOperation(
            actionIndex: index,
            action: action,
            resolution: resolution,
            desired: desired,
            sourceURL: sourceURL,
            sourceRoot: sourceRoot,
            outputURL: outputURL,
            expectedTargetKind: itemKind(at: outputURL),
            isCovered: false
        )
    }

    private func markCoveredDescendantsAndValidateStructure(
        operations: inout [PreparedOutputOperation],
        issues: inout [FolderMergeOutputIssue]
    ) {
        for ancestorIndex in operations.indices {
            let ancestor = operations[ancestorIndex]
            guard !ancestor.desired.isDirectory else { continue }
            let prefix = normalizedPathKey(ancestor.action.outputRelativePath) + "/"

            for descendantIndex in operations.indices where descendantIndex != ancestorIndex {
                let descendantPath = normalizedPathKey(operations[descendantIndex].action.outputRelativePath)
                guard descendantPath.hasPrefix(prefix) else { continue }
                if operations[descendantIndex].desired.isOmit {
                    operations[descendantIndex].isCovered = true
                } else {
                    issues.append(
                        issue(
                            .invalidPlanStructure,
                            index: operations[descendantIndex].actionIndex,
                            path: operations[descendantIndex].action.outputRelativePath,
                            "A materialized child cannot exist below an omitted or non-directory output path."
                        )
                    )
                }
            }
        }
    }

    private func validateSourcePath(
        root: URL,
        relativePath: String,
        index: Int,
        issues: inout [FolderMergeOutputIssue]
    ) {
        validateIntermediateComponents(
            root: root,
            relativePath: relativePath,
            plannedDirectories: [],
            allowAnyMissing: false,
            index: index,
            issues: &issues
        )
    }

    private func validateReadableSource(
        _ url: URL,
        kind: OutputItemKind,
        index: Int,
        path: String,
        issues: inout [FolderMergeOutputIssue]
    ) {
        do {
            switch kind {
            case .regularFile:
                let handle = try FileHandle(forReadingFrom: url)
                _ = try handle.read(upToCount: 1)
                try handle.close()
            case .symbolicLink:
                _ = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            case .directory, .other:
                return
            }
        } catch {
            issues.append(
                issue(
                    .missingSource,
                    index: index,
                    path: path,
                    "The selected source cannot be read during preflight: \(error.localizedDescription)"
                )
            )
        }
    }

    private func validateIntermediateComponents(
        root: URL,
        relativePath: String,
        plannedDirectories: Set<String>,
        allowAnyMissing: Bool,
        index: Int,
        issues: inout [FolderMergeOutputIssue]
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
                let path = prefix.joined(separator: "/")
                if !allowAnyMissing, !plannedDirectories.contains(path) {
                    issues.append(
                        issue(
                            .missingParentDirectory,
                            index: index,
                            path: path,
                            "An intermediate directory is missing and is not created by this plan."
                        )
                    )
                    return
                }
            }
        }
    }

    private func ordered(_ operations: [PreparedOutputOperation]) -> [PreparedOutputOperation] {
        operations.sorted { left, right in
            let leftPhase = operationPhase(left)
            let rightPhase = operationPhase(right)
            if leftPhase != rightPhase { return leftPhase < rightPhase }

            let leftDepth = pathDepth(left.action.outputRelativePath)
            let rightDepth = pathDepth(right.action.outputRelativePath)
            if left.desired.isDirectory, leftDepth != rightDepth { return leftDepth < rightDepth }
            if left.desired.isOmit, leftDepth != rightDepth { return leftDepth > rightDepth }
            if left.action.outputRelativePath != right.action.outputRelativePath {
                return left.action.outputRelativePath < right.action.outputRelativePath
            }
            return left.actionIndex < right.actionIndex
        }
    }

    private func operationPhase(_ operation: PreparedOutputOperation) -> Int {
        if operation.isCovered { return 3 }
        switch operation.desired {
        case .directory:
            return 0
        case .resource:
            return 1
        case .omit:
            return 2
        }
    }

    private func perform(
        plan: FolderMergePlan,
        resolutions: [String: FolderMergeConflictResolution],
        context: OutputExecutionContext
    ) -> FolderMergeOutputExecutionLog {
        let fileManager = FileManager()
        var results = plan.actions.enumerated().map { index, action in
            FolderMergeOutputItemResult(
                actionIndex: index,
                action: action,
                resolution: resolutions[action.outputRelativePath],
                status: .notRun,
                message: "Not run."
            )
        }
        var undoRecords: [OutputUndoRecord] = []
        var pendingBackups: [OutputPendingBackup] = []
        var finalizedBackups: [OutputPendingBackup] = []
        var createdBackupDirectories: [URL] = []
        let transactionRoot = context.roots.backup
            .appending(path: ".riffa-folder-merge-transactions", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let outputRootWasMissing = itemKind(at: context.roots.output) == nil

        do {
            if outputRootWasMissing {
                try createDirectorySafely(context.roots.output, fileManager: fileManager)
            }

            for operation in context.operations {
                if injectedFailureActionIndex == operation.actionIndex {
                    throw OutputExecutionFailure(actionIndex: operation.actionIndex, message: "Injected execution failure.")
                }

                if operation.isCovered {
                    results[operation.actionIndex] = itemResult(
                        operation,
                        status: .completed,
                        message: "Covered by an ancestor output operation."
                    )
                    continue
                }

                try revalidate(operation, roots: context.roots)
                try apply(
                    operation,
                    roots: context.roots,
                    transactionRoot: transactionRoot,
                    fileManager: fileManager,
                    undoRecords: &undoRecords,
                    pendingBackups: &pendingBackups,
                    createdBackupDirectories: &createdBackupDirectories
                )
                results[operation.actionIndex] = itemResult(operation, status: .completed, message: "Completed.")
            }

            try finalizeBackups(
                pendingBackups,
                roots: context.roots,
                fileManager: fileManager,
                finalized: &finalizedBackups,
                createdBackupDirectories: &createdBackupDirectories
            )
            removeEmptyTransactionDirectories(transactionRoot, fileManager: fileManager)
            return FolderMergeOutputExecutionLog(
                status: .completed,
                dryRun: false,
                rollbackAttempted: false,
                rollbackSucceeded: nil,
                itemResults: results,
                issues: []
            )
        } catch {
            let failedIndex = (error as? OutputExecutionFailure)?.actionIndex
                ?? (error as? OutputBackupFinalizationFailure)?.actionIndex
            let message = error.localizedDescription
            if let failedIndex, results.indices.contains(failedIndex) {
                results[failedIndex] = FolderMergeOutputItemResult(
                    actionIndex: failedIndex,
                    action: results[failedIndex].action,
                    resolution: results[failedIndex].resolution,
                    status: .failed,
                    message: "Execution failed: \(message)"
                )
            }

            var rollbackIssues: [FolderMergeOutputIssue] = []
            restoreFinalizedBackupsToStaging(
                finalizedBackups,
                fileManager: fileManager,
                issues: &rollbackIssues
            )
            rollback(
                records: undoRecords,
                results: &results,
                fileManager: fileManager,
                issues: &rollbackIssues
            )
            if outputRootWasMissing {
                removeDirectoryIfEmpty(context.roots.output, fileManager: fileManager)
            }
            removeCreatedBackupDirectories(createdBackupDirectories, fileManager: fileManager)

            let failureIssue = issue(
                .executionFailed,
                index: failedIndex,
                path: failedIndex.flatMap { index in
                    plan.actions.indices.contains(index) ? plan.actions[index].outputRelativePath : nil
                },
                "Execution failed: \(message)"
            )
            let rollbackSucceeded = rollbackIssues.isEmpty
            let rollbackAttempted = !undoRecords.isEmpty || outputRootWasMissing || !finalizedBackups.isEmpty
            return FolderMergeOutputExecutionLog(
                status: rollbackSucceeded ? .failedRolledBack : .failedRollbackIncomplete,
                dryRun: false,
                rollbackAttempted: rollbackAttempted,
                rollbackSucceeded: rollbackAttempted ? rollbackSucceeded : nil,
                itemResults: results,
                issues: [failureIssue] + rollbackIssues
            )
        }
    }

    private func revalidate(_ operation: PreparedOutputOperation, roots: OutputRoots) throws {
        if let sourceURL = operation.sourceURL, let sourceRoot = operation.sourceRoot {
            try requireNoSymbolicLinkIntermediates(
                root: sourceRoot,
                relativePath: relativePath(of: sourceURL, below: sourceRoot)
            )
            let kind = itemKind(at: sourceURL)
            switch operation.desired {
            case .directory:
                guard kind == .directory else {
                    throw OutputExecutionFailure(actionIndex: operation.actionIndex, message: "The source directory changed after preflight.")
                }
            case let .resource(expectedKind):
                guard kind == expectedKind else {
                    throw OutputExecutionFailure(actionIndex: operation.actionIndex, message: "The source resource changed after preflight.")
                }
            case .omit:
                break
            }
        }

        try requireNoSymbolicLinkIntermediates(
            root: roots.output,
            relativePath: operation.action.outputRelativePath
        )
        guard itemKind(at: operation.outputURL) == operation.expectedTargetKind else {
            throw OutputExecutionFailure(actionIndex: operation.actionIndex, message: "The output target changed after preflight.")
        }
    }

    private func apply(
        _ operation: PreparedOutputOperation,
        roots: OutputRoots,
        transactionRoot: URL,
        fileManager: FileManager,
        undoRecords: inout [OutputUndoRecord],
        pendingBackups: inout [OutputPendingBackup],
        createdBackupDirectories: inout [URL]
    ) throws {
        switch operation.desired {
        case .directory:
            if operation.expectedTargetKind == .directory { return }
            if operation.expectedTargetKind != nil {
                try stageExistingTarget(
                    operation,
                    roots: roots,
                    transactionRoot: transactionRoot,
                    removeReplacementDuringRollback: true,
                    fileManager: fileManager,
                    undoRecords: &undoRecords,
                    pendingBackups: &pendingBackups,
                    createdBackupDirectories: &createdBackupDirectories
                )
                try fileManager.createDirectory(at: operation.outputURL, withIntermediateDirectories: false)
            } else {
                try fileManager.createDirectory(at: operation.outputURL, withIntermediateDirectories: false)
                undoRecords.append(.removeCreated(actionIndex: operation.actionIndex, url: operation.outputURL))
            }

        case .resource:
            let temporary = try temporaryResource(
                source: operation.sourceURL!,
                beside: operation.outputURL,
                fileManager: fileManager
            )
            defer { try? removeIfPresent(temporary, fileManager: fileManager) }
            if operation.expectedTargetKind != nil {
                try stageExistingTarget(
                    operation,
                    roots: roots,
                    transactionRoot: transactionRoot,
                    removeReplacementDuringRollback: true,
                    fileManager: fileManager,
                    undoRecords: &undoRecords,
                    pendingBackups: &pendingBackups,
                    createdBackupDirectories: &createdBackupDirectories
                )
            }
            try fileManager.moveItem(at: temporary, to: operation.outputURL)
            if operation.expectedTargetKind == nil {
                undoRecords.append(.removeCreated(actionIndex: operation.actionIndex, url: operation.outputURL))
            }

        case .omit:
            guard operation.expectedTargetKind != nil else { return }
            try stageExistingTarget(
                operation,
                roots: roots,
                transactionRoot: transactionRoot,
                removeReplacementDuringRollback: false,
                fileManager: fileManager,
                undoRecords: &undoRecords,
                pendingBackups: &pendingBackups,
                createdBackupDirectories: &createdBackupDirectories
            )
        }
    }

    private func stageExistingTarget(
        _ operation: PreparedOutputOperation,
        roots: OutputRoots,
        transactionRoot: URL,
        removeReplacementDuringRollback: Bool,
        fileManager: FileManager,
        undoRecords: inout [OutputUndoRecord],
        pendingBackups: inout [OutputPendingBackup],
        createdBackupDirectories: inout [URL]
    ) throws {
        let staging = transactionRoot.appending(path: String(operation.actionIndex))
        let final = backupURL(for: operation.action, roots: roots)
        try createParentDirectories(
            for: staging,
            stoppingAt: roots.backup,
            fileManager: fileManager,
            created: &createdBackupDirectories
        )
        try requireNoSymbolicLinkIntermediates(
            root: roots.backup,
            relativePath: relativePath(of: staging, below: roots.backup)
        )
        guard itemKind(at: staging) == nil, itemKind(at: final) == nil else {
            throw OutputExecutionFailure(actionIndex: operation.actionIndex, message: "A backup destination appeared after preflight.")
        }
        try fileManager.moveItem(at: operation.outputURL, to: staging)
        undoRecords.append(
            .restoreBackup(
                actionIndex: operation.actionIndex,
                target: operation.outputURL,
                staging: staging,
                removeCurrentTarget: removeReplacementDuringRollback
            )
        )
        pendingBackups.append(
            OutputPendingBackup(actionIndex: operation.actionIndex, staging: staging, final: final)
        )
    }

    private func finalizeBackups(
        _ pending: [OutputPendingBackup],
        roots: OutputRoots,
        fileManager: FileManager,
        finalized: inout [OutputPendingBackup],
        createdBackupDirectories: inout [URL]
    ) throws {
        let ordered = pending.sorted { left, right in
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
                    throw OutputExecutionFailure(actionIndex: backup.actionIndex, message: "The final backup path is occupied.")
                }
                try fileManager.moveItem(at: backup.staging, to: backup.final)
                finalized.append(backup)
            } catch {
                throw OutputBackupFinalizationFailure(actionIndex: backup.actionIndex, underlying: error)
            }
        }
    }

    private func restoreFinalizedBackupsToStaging(
        _ finalized: [OutputPendingBackup],
        fileManager: FileManager,
        issues: inout [FolderMergeOutputIssue]
    ) {
        for backup in finalized.reversed() {
            do {
                guard itemKind(at: backup.final) != nil, itemKind(at: backup.staging) == nil else {
                    throw OutputExecutionFailure(actionIndex: backup.actionIndex, message: "A finalized backup cannot return to staging.")
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
        records: [OutputUndoRecord],
        results: inout [FolderMergeOutputItemResult],
        fileManager: FileManager,
        issues: inout [FolderMergeOutputIssue]
    ) {
        for record in records.reversed() {
            let index = record.actionIndex
            do {
                switch record {
                case let .removeCreated(_, url):
                    try removeIfPresent(url, fileManager: fileManager)

                case let .restoreBackup(_, target, staging, removeCurrentTarget):
                    if removeCurrentTarget {
                        try removeIfPresent(target, fileManager: fileManager)
                    }
                    guard itemKind(at: staging) != nil, itemKind(at: target) == nil else {
                        throw OutputExecutionFailure(actionIndex: index, message: "The rollback source or target is invalid.")
                    }
                    try fileManager.moveItem(at: staging, to: target)
                }

                results[index] = FolderMergeOutputItemResult(
                    actionIndex: index,
                    action: results[index].action,
                    resolution: results[index].resolution,
                    status: .rolledBack,
                    message: "Completed, then rolled back after a later failure."
                )
            } catch {
                let rollbackIssue = issue(
                    .rollbackFailed,
                    index: index,
                    path: results[index].action.outputRelativePath,
                    "Rollback failed: \(error.localizedDescription)"
                )
                issues.append(rollbackIssue)
                results[index] = FolderMergeOutputItemResult(
                    actionIndex: index,
                    action: results[index].action,
                    resolution: results[index].resolution,
                    status: .rollbackFailed,
                    message: rollbackIssue.message
                )
            }
        }
    }

    private func refusalLog(
        plan: FolderMergePlan,
        resolutions: [String: FolderMergeConflictResolution],
        dryRun: Bool,
        issues: [FolderMergeOutputIssue]
    ) -> FolderMergeOutputExecutionLog {
        FolderMergeOutputExecutionLog(
            status: .refused,
            dryRun: dryRun,
            rollbackAttempted: false,
            rollbackSucceeded: nil,
            itemResults: plan.actions.enumerated().map { index, action in
                FolderMergeOutputItemResult(
                    actionIndex: index,
                    action: action,
                    resolution: resolutions[action.outputRelativePath],
                    status: .refused,
                    message: "The plan failed preflight; no file-system changes were made."
                )
            },
            issues: issues
        )
    }

    private func itemResult(
        _ operation: PreparedOutputOperation,
        status: FolderMergeOutputItemStatus,
        message: String
    ) -> FolderMergeOutputItemResult {
        FolderMergeOutputItemResult(
            actionIndex: operation.actionIndex,
            action: operation.action,
            resolution: operation.resolution,
            status: status,
            message: message
        )
    }

    private func temporaryResource(source: URL, beside target: URL, fileManager: FileManager) throws -> URL {
        let temporary = target.deletingLastPathComponent().appending(
            path: ".riffa-merge-\(UUID().uuidString).tmp"
        )
        switch itemKind(at: source) {
        case .regularFile:
            try fileManager.copyItem(at: source, to: temporary)
        case .symbolicLink:
            let destination = try fileManager.destinationOfSymbolicLink(atPath: source.path)
            try fileManager.createSymbolicLink(atPath: temporary.path, withDestinationPath: destination)
        case .directory, .other, nil:
            throw OutputExecutionFailure(actionIndex: nil, message: "The source is no longer a supported resource.")
        }
        return temporary
    }

    private func backupURL(for action: FolderMergeAction, roots: OutputRoots) -> URL {
        roots.backup
            .appending(path: "output", directoryHint: .isDirectory)
            .appending(path: action.outputRelativePath)
    }

    private func validRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func canonicalExistingDirectory(
        _ url: URL,
        label: String,
        issues: inout [FolderMergeOutputIssue]
    ) -> URL? {
        guard url.isFileURL else {
            issues.append(issue(.invalidRoot, path: url.absoluteString, "The \(label) must be a file URL."))
            return nil
        }
        let standardized = url.standardizedFileURL
        guard itemKind(at: standardized) == .directory else {
            issues.append(issue(.invalidRoot, path: standardized.path, "The \(label) must be an existing directory and not a symbolic link."))
            return nil
        }
        return standardized.resolvingSymlinksInPath()
    }

    private func canonicalPotentialDirectory(
        _ url: URL,
        label: String,
        issues: inout [FolderMergeOutputIssue]
    ) -> URL? {
        guard url.isFileURL else {
            issues.append(issue(.invalidRoot, path: url.absoluteString, "The \(label) must be a file URL."))
            return nil
        }
        let standardized = url.standardizedFileURL
        if let kind = itemKind(at: standardized) {
            guard kind == .directory else {
                issues.append(issue(.invalidRoot, path: standardized.path, "The \(label) must be a directory and not a symbolic link."))
                return nil
            }
            return standardized.resolvingSymlinksInPath()
        }

        var ancestor = standardized
        var missing: [String] = []
        while itemKind(at: ancestor) == nil {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else {
                issues.append(issue(.invalidRoot, path: standardized.path, "The \(label) has no accessible ancestor."))
                return nil
            }
            missing.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        guard itemKind(at: ancestor) == .directory else {
            issues.append(issue(.invalidRoot, path: ancestor.path, "An ancestor of the \(label) is not a directory."))
            return nil
        }
        let canonicalAncestor = ancestor.resolvingSymlinksInPath()
        return missing.reversed().reduce(canonicalAncestor) { partial, component in
            partial.appending(path: component, directoryHint: .isDirectory)
        }
    }

    private func createDirectorySafely(_ url: URL, fileManager: FileManager) throws {
        let parent = url.deletingLastPathComponent()
        guard itemKind(at: parent) == .directory else {
            throw OutputExecutionFailure(actionIndex: nil, message: "The output root parent is unavailable.")
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
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
                throw OutputExecutionFailure(actionIndex: nil, message: "A backup parent is a symbolic link.")
            case .regularFile, .other:
                throw OutputExecutionFailure(actionIndex: nil, message: "A backup parent is not a directory.")
            }
        }
        switch itemKind(at: root) {
        case nil:
            missing.append(root)
        case .directory:
            break
        case .symbolicLink:
            throw OutputExecutionFailure(actionIndex: nil, message: "The backup root became a symbolic link.")
        case .regularFile, .other:
            throw OutputExecutionFailure(actionIndex: nil, message: "The backup root is not a directory.")
        }
        for directory in missing.reversed() {
            guard itemKind(at: directory.deletingLastPathComponent()) == .directory else {
                throw OutputExecutionFailure(actionIndex: nil, message: "A backup directory parent changed before creation.")
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            created.append(directory)
        }
    }

    private func requireNoSymbolicLinkIntermediates(root: URL, relativePath: String) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count > 1 else { return }
        var current = root
        for component in components.dropLast() {
            current.append(path: String(component), directoryHint: .isDirectory)
            if itemKind(at: current) == .symbolicLink {
                throw OutputExecutionFailure(actionIndex: nil, message: "An intermediate path component became a symbolic link.")
            }
        }
    }

    private func removeCreatedBackupDirectories(_ directories: [URL], fileManager: FileManager) {
        for directory in directories.reversed() {
            removeDirectoryIfEmpty(directory, fileManager: fileManager)
        }
    }

    private func removeEmptyTransactionDirectories(_ transactionRoot: URL, fileManager: FileManager) {
        removeDirectoryIfEmpty(transactionRoot, fileManager: fileManager)
        removeDirectoryIfEmpty(transactionRoot.deletingLastPathComponent(), fileManager: fileManager)
    }

    private func removeDirectoryIfEmpty(_ url: URL, fileManager: FileManager) {
        guard itemKind(at: url) == .directory,
              let contents = try? fileManager.contentsOfDirectory(atPath: url.path),
              contents.isEmpty else { return }
        try? fileManager.removeItem(at: url)
    }

    private func removeIfPresent(_ url: URL, fileManager: FileManager) throws {
        if itemKind(at: url) != nil {
            try fileManager.removeItem(at: url)
        }
    }

    private func itemKind(at url: URL) -> OutputItemKind? {
        var information = stat()
        let result = url.path.withCString { Darwin.lstat($0, &information) }
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

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func relativePath(of url: URL, below root: URL) -> String {
        String(url.path.dropFirst(root.path.count + 1))
    }

    private func pathDepth(_ path: String) -> Int {
        path.split(separator: "/", omittingEmptySubsequences: true).count
    }

    private func normalizedPathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private func issue(
        _ code: FolderMergeOutputIssue.Code,
        index: Int? = nil,
        path: String? = nil,
        _ message: String
    ) -> FolderMergeOutputIssue {
        FolderMergeOutputIssue(code: code, actionIndex: index, path: path, message: message)
    }
}

private enum OutputItemKind: Equatable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

private enum OutputSelection {
    case source(FolderMergeSource, String?)
    case directory(FolderMergeSource, String?)
    case resolvedSource(FolderMergeSource)
    case omit
}

private enum OutputDesiredState {
    case directory
    case resource(OutputItemKind)
    case omit

    var isDirectory: Bool {
        if case .directory = self { return true }
        return false
    }

    var isOmit: Bool {
        if case .omit = self { return true }
        return false
    }
}

private struct OutputRoots {
    let base: URL
    let left: URL
    let right: URL
    let output: URL
    let backup: URL

    func root(for source: FolderMergeSource) -> URL {
        switch source {
        case .base:
            base
        case .left:
            left
        case .right:
            right
        }
    }
}

private struct PreparedOutputOperation {
    let actionIndex: Int
    let action: FolderMergeAction
    let resolution: FolderMergeConflictResolution?
    let desired: OutputDesiredState
    let sourceURL: URL?
    let sourceRoot: URL?
    let outputURL: URL
    let expectedTargetKind: OutputItemKind?
    var isCovered: Bool
}

private struct OutputExecutionContext {
    let roots: OutputRoots
    let operations: [PreparedOutputOperation]
}

private enum OutputPreflightOutcome {
    case success(OutputExecutionContext)
    case failure([FolderMergeOutputIssue])
}

private enum OutputUndoRecord {
    case removeCreated(actionIndex: Int, url: URL)
    case restoreBackup(actionIndex: Int, target: URL, staging: URL, removeCurrentTarget: Bool)

    var actionIndex: Int {
        switch self {
        case let .removeCreated(actionIndex, _),
             let .restoreBackup(actionIndex, _, _, _):
            actionIndex
        }
    }
}

private struct OutputPendingBackup {
    let actionIndex: Int
    let staging: URL
    let final: URL
}

private struct OutputExecutionFailure: Error, LocalizedError {
    let actionIndex: Int?
    let message: String
    var errorDescription: String? { message }
}

private struct OutputBackupFinalizationFailure: Error, LocalizedError {
    let actionIndex: Int
    let underlying: any Error
    var errorDescription: String? { underlying.localizedDescription }
}
