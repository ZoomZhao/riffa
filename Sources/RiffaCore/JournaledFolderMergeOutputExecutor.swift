import Darwin
import Foundation

public enum JournaledFolderMergeOutputPersistenceStage: String, Hashable, Codable, Sendable {
    case create
    case markExecuting
    case recordResult
    case markTerminal
}

/// Errors from the persistent recovery layer around folder-merge output.
///
/// A persistence error after the wrapped transaction has run intentionally
/// prevents callers from presenting that transaction as successful.
public enum JournaledFolderMergeOutputError: Error, Equatable, Sendable, LocalizedError {
    case unrepresentableAction(index: Int)
    case inconsistentExecutionLog
    case journalPersistenceFailed(
        stage: JournaledFolderMergeOutputPersistenceStage,
        journalID: UUID?,
        underlying: OperationJournalStoreError
    )

    public var errorDescription: String? {
        switch self {
        case let .unrepresentableAction(index):
            "Merge-output action \(index + 1) cannot be represented safely in the operation journal. No files were changed."
        case .inconsistentExecutionLog:
            "The merge-output result did not match its plan. Its operation journal was left unfinished for inspection."
        case let .journalPersistenceFailed(stage, journalID, _):
            if let journalID {
                "The operation journal could not be persisted during \(stage.rawValue) (\(journalID.uuidString)). Do not treat the merge output as successful."
            } else {
                "The operation journal could not be created. No files were changed."
            }
        }
    }
}

/// Executes one complete folder-merge output transaction behind an atomic,
/// cross-launch operation journal.
///
/// `FolderMergeOutputExecutor` remains the sole owner of preflight, backup,
/// mutation, and rollback. This wrapper calls it exactly once for a formal run
/// and only persists observations before and after that whole transaction.
public struct JournaledFolderMergeOutputExecutor: Sendable {
    private let journalStore: OperationJournalStore
    private let executor: FolderMergeOutputExecutor
    private let testingFailurePoint: TestingFailurePoint?
    private let testingCancelAfterExecutingTransition: Bool
    private let testingExecutionLog: FolderMergeOutputExecutionLog?

    public init(
        journalDirectoryURL: URL = JournaledLocalFolderSyncExecutor
            .defaultApplicationJournalDirectoryURL
    ) {
        journalStore = OperationJournalStore(directoryURL: journalDirectoryURL)
        executor = FolderMergeOutputExecutor()
        testingFailurePoint = nil
        testingCancelAfterExecutingTransition = false
        testingExecutionLog = nil
    }

    public init(journalStore: OperationJournalStore) {
        self.journalStore = journalStore
        executor = FolderMergeOutputExecutor()
        testingFailurePoint = nil
        testingCancelAfterExecutingTransition = false
        testingExecutionLog = nil
    }

    enum TestingFailurePoint: Sendable {
        case beforeCreate
        case beforeMarkExecuting
        case beforeResultPersistence
        case beforeTerminalTransition
    }

    init(
        journalStore: OperationJournalStore,
        testingExecutorFailureAtActionIndex: Int? = nil,
        testingFailurePoint: TestingFailurePoint? = nil,
        testingCancelAfterExecutingTransition: Bool = false,
        testingExecutionLog: FolderMergeOutputExecutionLog? = nil
    ) {
        self.journalStore = journalStore
        executor = FolderMergeOutputExecutor(
            testingFailureAtActionIndex: testingExecutorFailureAtActionIndex
        )
        self.testingFailurePoint = testingFailurePoint
        self.testingCancelAfterExecutingTransition = testingCancelAfterExecutingTransition
        self.testingExecutionLog = testingExecutionLog
    }

    /// Dry-runs remain side-effect-free and bypass the journal store entirely.
    /// A formal run throws if recovery metadata cannot be persisted at any stage.
    public func execute(
        plan: FolderMergePlan,
        resolutions: [String: FolderMergeConflictResolution] = [:],
        baseRoot: URL,
        leftRoot: URL,
        rightRoot: URL,
        outputRoot: URL,
        backupRoot: URL,
        options: FolderMergeOutputOptions = .init()
    ) async throws -> FolderMergeOutputExecutionLog {
        if options.dryRun {
            try Task.checkCancellation()
            return executor.execute(
                plan: plan,
                resolutions: resolutions,
                baseRoot: baseRoot,
                leftRoot: leftRoot,
                rightRoot: rightRoot,
                outputRoot: outputRoot,
                backupRoot: backupRoot,
                options: options
            )
        }

        try Task.checkCancellation()
        let roots = canonicalRoots(
            base: baseRoot,
            left: leftRoot,
            right: rightRoot,
            output: outputRoot,
            backup: backupRoot
        )
        let journal = try makeJournal(
            plan: plan,
            resolutions: resolutions,
            roots: roots
        )

        try injectFailureIfRequested(.beforeCreate, journalID: nil, stage: .create)
        do {
            _ = try await journalStore.create(journal)
        } catch let error as OperationJournalStoreError {
            throw JournaledFolderMergeOutputError.journalPersistenceFailed(
                stage: .create,
                journalID: nil,
                underlying: error
            )
        }

        try injectFailureIfRequested(
            .beforeMarkExecuting,
            journalID: journal.id,
            stage: .markExecuting
        )
        do {
            _ = try await journalStore.transition(journal.id, to: .executing)
        } catch let error as OperationJournalStoreError {
            throw JournaledFolderMergeOutputError.journalPersistenceFailed(
                stage: .markExecuting,
                journalID: journal.id,
                underlying: error
            )
        }

        if testingCancelAfterExecutingTransition {
            throw CancellationError()
        }
        try Task.checkCancellation()

        // Deliberately one synchronous call. The wrapped executor retains its
        // transaction-wide preflight, backup staging, and rollback behavior.
        let log = testingExecutionLog ?? executor.execute(
            plan: plan,
            resolutions: resolutions,
            baseRoot: baseRoot,
            leftRoot: leftRoot,
            rightRoot: rightRoot,
            outputRoot: outputRoot,
            backupRoot: backupRoot,
            options: options
        )

        // Cancellation after the transaction leaves `.executing` evidence for
        // a recovery scan instead of guessing about the file-system outcome.
        try Task.checkCancellation()
        try injectFailureIfRequested(
            .beforeResultPersistence,
            journalID: journal.id,
            stage: .recordResult
        )

        let indexedResults = try validatedResults(
            log.itemResults,
            expectedCount: journal.steps.count
        )
        let terminalStatus = terminalJournalStatus(for: log.status)
        let terminalFailure = terminalStatus == .completed
            ? nil
            : OperationJournalFailure(code: rootFailureCode(for: log), recordedAt: Date())
        let enteredRollback = log.status == .failedRolledBack
            || log.status == .failedRollbackIncomplete

        if enteredRollback {
            do {
                _ = try await journalStore.transition(
                    journal.id,
                    to: .rollingBack,
                    failure: terminalFailure
                )
            } catch let error as OperationJournalStoreError {
                throw JournaledFolderMergeOutputError.journalPersistenceFailed(
                    stage: .recordResult,
                    journalID: journal.id,
                    underlying: error
                )
            }
        }

        for (index, definition) in journal.steps.enumerated() {
            try Task.checkCancellation()
            guard let itemResult = indexedResults[index] else {
                throw JournaledFolderMergeOutputError.inconsistentExecutionLog
            }
            let status = journalStepStatus(
                for: itemResult.status,
                terminalStatus: terminalStatus
            )
            let afterState = itemState(
                at: roots.output.appending(path: definition.relativePath)
            )
            let failure: OperationJournalFailure?
            if status == .failed {
                failure = OperationJournalFailure(
                    code: stepFailureCode(for: itemResult, issues: log.issues),
                    recordedAt: Date()
                )
            } else {
                failure = nil
            }
            let updated = OperationJournalStep(
                id: definition.id,
                actionKind: definition.actionKind,
                relativePath: definition.relativePath,
                sourceRootRole: definition.sourceRootRole,
                sourceRelativePath: definition.sourceRelativePath,
                targetRootRole: definition.targetRootRole,
                backup: definition.backup,
                status: status,
                beforeState: definition.beforeState,
                afterState: afterState,
                failure: failure
            )
            do {
                _ = try await journalStore.updateStep(updated, in: journal.id)
            } catch let error as OperationJournalStoreError {
                throw JournaledFolderMergeOutputError.journalPersistenceFailed(
                    stage: .recordResult,
                    journalID: journal.id,
                    underlying: error
                )
            }
        }

        try Task.checkCancellation()
        try injectFailureIfRequested(
            .beforeTerminalTransition,
            journalID: journal.id,
            stage: .markTerminal
        )
        do {
            _ = try await journalStore.transition(
                journal.id,
                to: terminalStatus,
                failure: terminalFailure
            )
        } catch let error as OperationJournalStoreError {
            throw JournaledFolderMergeOutputError.journalPersistenceFailed(
                stage: .markTerminal,
                journalID: journal.id,
                underlying: error
            )
        }

        return log
    }

    private func makeJournal(
        plan: FolderMergePlan,
        resolutions: [String: FolderMergeConflictResolution],
        roots: CanonicalMergeRoots
    ) throws -> OperationJournal {
        let definitions = try plan.actions.enumerated().map { index, action in
            try resolvedDefinition(
                action,
                index: index,
                resolution: resolutions[action.outputRelativePath],
                roots: roots
            )
        }
        let steps = definitions.enumerated().map { index, definition in
            makeStep(
                definition,
                isCovered: isCoveredOmission(at: index, definitions: definitions),
                roots: roots
            )
        }
        return OperationJournal(
            kind: .merge,
            roots: [
                OperationJournalRoot(role: .base, absolutePath: roots.base.path),
                OperationJournalRoot(role: .left, absolutePath: roots.left.path),
                OperationJournalRoot(role: .right, absolutePath: roots.right.path),
                OperationJournalRoot(role: .output, absolutePath: roots.output.path),
                OperationJournalRoot(role: .backup, absolutePath: roots.backup.path)
            ],
            steps: steps
        )
    }

    private func resolvedDefinition(
        _ action: FolderMergeAction,
        index: Int,
        resolution: FolderMergeConflictResolution?,
        roots: CanonicalMergeRoots
    ) throws -> ResolvedMergeStepDefinition {
        guard isSafeRelativePath(action.outputRelativePath) else {
            throw JournaledFolderMergeOutputError.unrepresentableAction(index: index)
        }

        let sourceRole: OperationJournalRootRole?
        let sourcePath: String?
        let desired: JournalDesiredState
        switch action.kind {
        case .copyFromBase:
            guard action.source == .base,
                  let path = action.sourceRelativePath,
                  isSafeRelativePath(path) else {
                throw JournaledFolderMergeOutputError.unrepresentableAction(index: index)
            }
            sourceRole = .base
            sourcePath = path
            desired = .resource

        case .copyFromLeft:
            guard action.source == .left,
                  let path = action.sourceRelativePath,
                  isSafeRelativePath(path) else {
                throw JournaledFolderMergeOutputError.unrepresentableAction(index: index)
            }
            sourceRole = .left
            sourcePath = path
            desired = .resource

        case .copyFromRight:
            guard action.source == .right,
                  let path = action.sourceRelativePath,
                  isSafeRelativePath(path) else {
                throw JournaledFolderMergeOutputError.unrepresentableAction(index: index)
            }
            sourceRole = .right
            sourcePath = path
            desired = .resource

        case .createDirectory:
            guard let source = action.source,
                  let path = action.sourceRelativePath,
                  isSafeRelativePath(path) else {
                throw JournaledFolderMergeOutputError.unrepresentableAction(index: index)
            }
            sourceRole = rootRole(for: source)
            sourcePath = path
            desired = .directory

        case .omit:
            sourceRole = nil
            sourcePath = nil
            desired = .omit

        case .conflict:
            switch resolution {
            case .useBase:
                sourceRole = .base
                sourcePath = action.outputRelativePath
                desired = desiredState(
                    at: roots.base.appending(path: action.outputRelativePath)
                )
            case .useLeft:
                sourceRole = .left
                sourcePath = action.outputRelativePath
                desired = desiredState(
                    at: roots.left.appending(path: action.outputRelativePath)
                )
            case .useRight:
                sourceRole = .right
                sourcePath = action.outputRelativePath
                desired = desiredState(
                    at: roots.right.appending(path: action.outputRelativePath)
                )
            case .omit, nil:
                // An unresolved conflict is still representable as a pending,
                // non-materializing definition. The wrapped executor will refuse
                // it and the journal will finish as failed without user writes.
                sourceRole = nil
                sourcePath = nil
                desired = .omit
            }
        }

        return ResolvedMergeStepDefinition(
            relativePath: action.outputRelativePath,
            sourceRootRole: sourceRole,
            sourceRelativePath: sourcePath,
            desired: desired
        )
    }

    private func makeStep(
        _ definition: ResolvedMergeStepDefinition,
        isCovered: Bool,
        roots: CanonicalMergeRoots
    ) -> OperationJournalStep {
        let target = roots.output.appending(path: definition.relativePath)
        let beforeState = itemState(at: target)
        let targetExists = beforeState.kind != .missing
        let actionKind: OperationJournalActionKind
        let needsBackup: Bool

        switch definition.desired {
        case .directory:
            if beforeState.kind == .directory {
                actionKind = .createDirectory
                needsBackup = false
            } else if targetExists {
                actionKind = .replace
                needsBackup = true
            } else {
                actionKind = .createDirectory
                needsBackup = false
            }
        case .resource:
            actionKind = targetExists ? .replace : .copy
            needsBackup = targetExists
        case .omit:
            actionKind = targetExists ? .delete : .omit
            needsBackup = targetExists && !isCovered
        }

        return OperationJournalStep(
            actionKind: actionKind,
            relativePath: definition.relativePath,
            sourceRootRole: definition.sourceRootRole,
            sourceRelativePath: definition.sourceRelativePath == definition.relativePath
                ? nil
                : definition.sourceRelativePath,
            targetRootRole: .output,
            backup: needsBackup
                ? OperationJournalBackupMapping(
                    backupRelativePath: "output/" + definition.relativePath
                )
                : nil,
            beforeState: beforeState
        )
    }

    private func isCoveredOmission(
        at index: Int,
        definitions: [ResolvedMergeStepDefinition]
    ) -> Bool {
        let definition = definitions[index]
        guard definition.desired == .omit else { return false }
        let key = normalizedPathKey(definition.relativePath)
        return definitions.enumerated().contains { ancestorIndex, ancestor in
            guard ancestorIndex != index, ancestor.desired != .directory else { return false }
            return key.hasPrefix(normalizedPathKey(ancestor.relativePath) + "/")
        }
    }

    private func validatedResults(
        _ results: [FolderMergeOutputItemResult],
        expectedCount: Int
    ) throws -> [Int: FolderMergeOutputItemResult] {
        guard results.count == expectedCount else {
            throw JournaledFolderMergeOutputError.inconsistentExecutionLog
        }
        var indexed: [Int: FolderMergeOutputItemResult] = [:]
        indexed.reserveCapacity(results.count)
        for result in results {
            guard indexed.updateValue(result, forKey: result.actionIndex) == nil else {
                throw JournaledFolderMergeOutputError.inconsistentExecutionLog
            }
        }
        guard Set(indexed.keys) == Set(0..<expectedCount) else {
            throw JournaledFolderMergeOutputError.inconsistentExecutionLog
        }
        return indexed
    }

    private func terminalJournalStatus(
        for status: FolderMergeOutputExecutionStatus
    ) -> OperationJournalStatus {
        switch status {
        case .completed: .completed
        case .failedRolledBack: .rolledBack
        case .refused, .failedRollbackIncomplete: .failed
        case .dryRun: .failed
        }
    }

    private func journalStepStatus(
        for status: FolderMergeOutputItemStatus,
        terminalStatus: OperationJournalStatus
    ) -> OperationJournalStepStatus {
        switch status {
        case .completed:
            // Some successful no-op/covered items carry no undo record. At a
            // transaction-wide rolled-back terminal state they are nevertheless
            // recorded as restored, keeping the journal state internally valid.
            terminalStatus == .rolledBack ? .rolledBack : .completed
        case .rolledBack:
            .rolledBack
        case .planned, .refused, .failed, .notRun, .rollbackFailed:
            .failed
        }
    }

    private func rootFailureCode(
        for log: FolderMergeOutputExecutionLog
    ) -> OperationJournalFailureCode {
        if log.status == .failedRollbackIncomplete { return .rollbackFailed }
        return log.issues.first.map(failureCode(for:)) ?? .unknown
    }

    private func stepFailureCode(
        for result: FolderMergeOutputItemResult,
        issues: [FolderMergeOutputIssue]
    ) -> OperationJournalFailureCode {
        if result.status == .rollbackFailed { return .rollbackFailed }
        return issues.first(where: { $0.actionIndex == result.actionIndex })
            .map(failureCode(for:))
            ?? issues.first.map(failureCode(for:))
            ?? .actionFailed
    }

    private func failureCode(
        for issue: FolderMergeOutputIssue
    ) -> OperationJournalFailureCode {
        switch issue.code {
        case .invalidRoot, .overlappingRoots, .unresolvedConflict,
             .unexpectedResolution, .invalidRelativePath, .malformedAction,
             .duplicateOutputPath, .invalidPlanStructure:
            .invalidPlan
        case .missingSource:
            .sourceMissing
        case .unsupportedSourceType:
            .sourceChanged
        case .symbolicLinkTraversal:
            .symbolicLinkTraversal
        case .missingParentDirectory, .targetChanged:
            .targetChanged
        case .backupCollision:
            .backupFailed
        case .executionFailed:
            .actionFailed
        case .rollbackFailed:
            .rollbackFailed
        }
    }

    private func canonicalRoots(
        base: URL,
        left: URL,
        right: URL,
        output: URL,
        backup: URL
    ) -> CanonicalMergeRoots {
        CanonicalMergeRoots(
            base: canonicalPotentialDirectory(base),
            left: canonicalPotentialDirectory(left),
            right: canonicalPotentialDirectory(right),
            output: canonicalPotentialDirectory(output),
            backup: canonicalPotentialDirectory(backup)
        )
    }

    private func canonicalPotentialDirectory(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var ancestor = standardized
        var missing: [String] = []
        while itemState(at: ancestor).kind == .missing {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return standardized }
            missing.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        return missing.reversed().reduce(ancestor.resolvingSymlinksInPath()) { partial, component in
            partial.appending(path: component, directoryHint: .isDirectory)
        }
    }

    private func rootRole(for source: FolderMergeSource) -> OperationJournalRootRole {
        switch source {
        case .base: .base
        case .left: .left
        case .right: .right
        }
    }

    private func desiredState(at sourceURL: URL) -> JournalDesiredState {
        itemState(at: sourceURL).kind == .directory ? .directory : .resource
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func normalizedPathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func itemState(at url: URL) -> OperationJournalItemState {
        var information = stat()
        let result = url.path.withCString { Darwin.lstat($0, &information) }
        guard result == 0 else { return .missing }

        let kind: OperationJournalItemState.Kind
        switch information.st_mode & S_IFMT {
        case S_IFREG: kind = .regularFile
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }

        let seconds = Int64(information.st_mtimespec.tv_sec)
        let nanoseconds = Int64(information.st_mtimespec.tv_nsec)
        let product = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let total = product.partialValue.addingReportingOverflow(nanoseconds)
        let modificationTime = product.overflow || total.overflow ? nil : total.partialValue
        let byteCount: UInt64? = kind == .regularFile && information.st_size >= 0
            ? UInt64(information.st_size)
            : nil
        return OperationJournalItemState(
            kind: kind,
            byteCount: byteCount,
            modificationTimeNanoseconds: modificationTime,
            permissions: UInt16(information.st_mode & 0o7777)
        )
    }

    private func injectFailureIfRequested(
        _ point: TestingFailurePoint,
        journalID: UUID?,
        stage: JournaledFolderMergeOutputPersistenceStage
    ) throws {
        guard testingFailurePoint == point else { return }
        throw JournaledFolderMergeOutputError.journalPersistenceFailed(
            stage: stage,
            journalID: journalID,
            underlying: .ioFailure(.write)
        )
    }
}

private enum JournalDesiredState: Equatable, Sendable {
    case directory
    case resource
    case omit
}

private struct ResolvedMergeStepDefinition: Sendable {
    let relativePath: String
    let sourceRootRole: OperationJournalRootRole?
    let sourceRelativePath: String?
    let desired: JournalDesiredState
}

private struct CanonicalMergeRoots: Sendable {
    let base: URL
    let left: URL
    let right: URL
    let output: URL
    let backup: URL
}
