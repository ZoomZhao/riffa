import Darwin
import Foundation

public enum JournaledLocalFolderSyncPersistenceStage: String, Hashable, Codable, Sendable {
    case create
    case markExecuting
    case recordResult
    case markTerminal
}

/// Errors from the crash-recovery layer. A thrown persistence error means the
/// caller must not present the underlying synchronization as successful.
public enum JournaledLocalFolderSyncError: Error, Equatable, Sendable, LocalizedError {
    case unrepresentableAction(index: Int)
    case inconsistentExecutionLog
    case journalPersistenceFailed(
        stage: JournaledLocalFolderSyncPersistenceStage,
        journalID: UUID?,
        underlying: OperationJournalStoreError
    )

    public var errorDescription: String? {
        switch self {
        case let .unrepresentableAction(index):
            "Synchronization action \(index + 1) cannot be represented safely in the operation journal. No files were changed."
        case .inconsistentExecutionLog:
            "The synchronization result did not match its plan. Inspect its operation journal before continuing."
        case let .journalPersistenceFailed(stage, journalID, _):
            if let journalID {
                "The operation journal could not be persisted during \(stage.rawValue) (\(journalID.uuidString)). Do not treat the synchronization as successful."
            } else {
                "The operation journal could not be created. No files were changed."
            }
        }
    }
}

/// Executes one complete local folder-sync transaction behind an atomic,
/// cross-launch operation journal.
///
/// The existing `LocalFolderSyncExecutor` remains the sole owner of preflight,
/// backup, mutation, and rollback behavior. This wrapper never decomposes the
/// plan into independently executed actions.
public struct JournaledLocalFolderSyncExecutor: Sendable {
    /// The app-owned location used by Folder Compare and Folder Sync.
    public static var defaultApplicationJournalDirectoryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return applicationSupport
            .appending(path: "dev.riffa.Riffa", directoryHint: .isDirectory)
            .appending(path: "operation-journals", directoryHint: .isDirectory)
    }

    private let journalStore: OperationJournalStore
    private let executor: LocalFolderSyncExecutor
    private let testingFailurePoint: TestingFailurePoint?
    private let testingCancelAfterExecutingTransition: Bool
    private let testingExecutionLog: LocalFolderSyncExecutionLog?
    private let testingAfterExecution: (@Sendable () throws -> Void)?

    public init(journalDirectoryURL: URL) {
        journalStore = OperationJournalStore(directoryURL: journalDirectoryURL)
        executor = LocalFolderSyncExecutor()
        testingFailurePoint = nil
        testingCancelAfterExecutingTransition = false
        testingExecutionLog = nil
        testingAfterExecution = nil
    }

    public init(journalStore: OperationJournalStore) {
        self.journalStore = journalStore
        executor = LocalFolderSyncExecutor()
        testingFailurePoint = nil
        testingCancelAfterExecutingTransition = false
        testingExecutionLog = nil
        testingAfterExecution = nil
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
        testingExecutionLog: LocalFolderSyncExecutionLog? = nil,
        testingAfterExecution: (@Sendable () throws -> Void)? = nil
    ) {
        self.journalStore = journalStore
        executor = LocalFolderSyncExecutor(
            testingFailureAtActionIndex: testingExecutorFailureAtActionIndex
        )
        self.testingFailurePoint = testingFailurePoint
        self.testingCancelAfterExecutingTransition = testingCancelAfterExecutingTransition
        self.testingExecutionLog = testingExecutionLog
        self.testingAfterExecution = testingAfterExecution
    }

    /// Dry-runs bypass journaling entirely. A formal run throws whenever recovery
    /// metadata cannot be written, including after the file transaction itself.
    public func execute(
        plan: FolderSyncPlan,
        leftRoot: URL,
        rightRoot: URL,
        backupRoot: URL,
        options: LocalFolderSyncExecutionOptions = .init()
    ) async throws -> LocalFolderSyncExecutionLog {
        if options.dryRun {
            try Task.checkCancellation()
            return await executor.execute(
                plan: plan,
                leftRoot: leftRoot,
                rightRoot: rightRoot,
                backupRoot: backupRoot,
                options: options
            )
        }

        let roots = canonicalRoots(left: leftRoot, right: rightRoot, backup: backupRoot)
        let journal = try makeJournal(plan: plan, roots: roots)

        try injectFailureIfRequested(.beforeCreate, journalID: nil, stage: .create)
        do {
            _ = try await journalStore.create(journal)
        } catch let error as OperationJournalStoreError {
            throw JournaledLocalFolderSyncError.journalPersistenceFailed(
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
            throw JournaledLocalFolderSyncError.journalPersistenceFailed(
                stage: .markExecuting,
                journalID: journal.id,
                underlying: error
            )
        }

        if testingCancelAfterExecutingTransition {
            throw CancellationError()
        }
        try Task.checkCancellation()

        // Deliberately one call: the wrapped executor retains whole-plan
        // preflight, staged backups, and transaction-wide rollback.
        let log: LocalFolderSyncExecutionLog
        if let testingExecutionLog {
            log = testingExecutionLog
        } else {
            log = await executor.execute(
                plan: plan,
                leftRoot: leftRoot,
                rightRoot: rightRoot,
                backupRoot: backupRoot,
                options: options
            )
        }
        try testingAfterExecution?()

        // Once the file transaction returns, result and terminal persistence are
        // deliberately non-cancellable. A cancelled caller must never strand a
        // committed or rolled-back move behind pending journal metadata.
        try injectFailureIfRequested(
            .beforeResultPersistence,
            journalID: journal.id,
            stage: .recordResult
        )

        let indexedResults = try validatedResults(log, plan: plan)
        var terminalStatus = terminalJournalStatus(for: log.status)
        var terminalFailure = terminalStatus == .completed
            ? nil
            : OperationJournalFailure(code: rootFailureCode(for: log), recordedAt: Date())
        var observedMoveMismatch = false

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
                throw JournaledLocalFolderSyncError.journalPersistenceFailed(
                    stage: .recordResult,
                    journalID: journal.id,
                    underlying: error
                )
            }
        }

        for (index, definition) in journal.steps.enumerated() {
            guard let itemResult = indexedResults[index] else {
                throw JournaledLocalFolderSyncError.inconsistentExecutionLog
            }
            var status = journalStepStatus(for: itemResult.status)
            let usesExactLeafSpelling = isCaseOnlyMove(definition)
            let targetURL = targetURL(for: definition, roots: roots)
            let afterState = usesExactLeafSpelling
                ? exactLeafItemState(at: targetURL) ?? OperationJournalItemState(kind: .other)
                : itemState(at: targetURL)
            let sourceAfterState = sourceURL(for: definition, roots: roots).map { source in
                usesExactLeafSpelling
                    ? exactLeafItemState(at: source) ?? OperationJournalItemState(kind: .other)
                    : itemState(at: source)
            }
            let moveMismatchCode = moveObservationMismatchCode(
                for: definition,
                claimedStatus: status,
                targetAfterState: afterState,
                sourceAfterState: sourceAfterState
            )
            if let moveMismatchCode {
                status = .failed
                observedMoveMismatch = true
                terminalStatus = .failed
                terminalFailure = OperationJournalFailure(
                    code: moveMismatchCode,
                    recordedAt: Date()
                )
            }
            let failure: OperationJournalFailure?
            if status == .failed {
                failure = OperationJournalFailure(
                    code: moveMismatchCode
                        ?? stepFailureCode(for: itemResult, issues: log.issues),
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
                sourceBeforeState: definition.sourceBeforeState,
                sourceAfterState: sourceAfterState,
                failure: failure
            )
            do {
                _ = try await journalStore.updateStep(updated, in: journal.id)
            } catch let error as OperationJournalStoreError {
                throw JournaledLocalFolderSyncError.journalPersistenceFailed(
                    stage: .recordResult,
                    journalID: journal.id,
                    underlying: error
                )
            }
        }

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
            throw JournaledLocalFolderSyncError.journalPersistenceFailed(
                stage: .markTerminal,
                journalID: journal.id,
                underlying: error
            )
        }

        if observedMoveMismatch {
            throw JournaledLocalFolderSyncError.inconsistentExecutionLog
        }
        return log
    }

    private func makeJournal(
        plan: FolderSyncPlan,
        roots: CanonicalRoots
    ) throws -> OperationJournal {
        let steps = try plan.actions.enumerated().map { index, action in
            try makeStep(action, index: index, roots: roots)
        }
        return OperationJournal(
            kind: .sync,
            roots: [
                OperationJournalRoot(role: .left, absolutePath: roots.left.path),
                OperationJournalRoot(role: .right, absolutePath: roots.right.path),
                OperationJournalRoot(role: .backup, absolutePath: roots.backup.path)
            ],
            steps: steps
        )
    }

    private func makeStep(
        _ action: FolderSyncAction,
        index: Int,
        roots: CanonicalRoots
    ) throws -> OperationJournalStep {
        guard let targetSide = action.targetSide,
              let targetPath = action.targetRelativePath,
              isSafeRelativePath(targetPath) else {
            throw JournaledLocalFolderSyncError.unrepresentableAction(index: index)
        }
        let targetRole = rootRole(for: targetSide)
        let target = roots.url(for: targetRole).appending(path: targetPath)
        let isCaseOnlyRename = action.kind == .move
            && action.moveProof?.authorization == .explicitSameDirectoryCaseOnlyRename
        let targetBeforeState: OperationJournalItemState
        if isCaseOnlyRename {
            guard let exactTarget = exactLeafItemState(at: target) else {
                throw JournaledLocalFolderSyncError.unrepresentableAction(index: index)
            }
            targetBeforeState = exactTarget
        } else {
            targetBeforeState = itemState(at: target)
        }

        let actionKind: OperationJournalActionKind
        let sourceRole: OperationJournalRootRole?
        let sourcePath: String?
        let sourceBeforeState: OperationJournalItemState?
        switch action.kind {
        case .move:
            guard let sourceSide = action.sourceSide,
                  sourceSide == targetSide,
                  let explicitSourcePath = action.sourceRelativePath,
                  isSafeRelativePath(explicitSourcePath),
                  explicitSourcePath.precomposedStringWithCanonicalMapping
                    != targetPath.precomposedStringWithCanonicalMapping,
                  isCaseOnlyRename
                    ? pathKey(explicitSourcePath) == pathKey(targetPath)
                    : pathKey(explicitSourcePath) != pathKey(targetPath) else {
                throw JournaledLocalFolderSyncError.unrepresentableAction(index: index)
            }
            actionKind = .move
            let moveSourceRole = rootRole(for: sourceSide)
            sourceRole = moveSourceRole
            sourcePath = explicitSourcePath
            let source = roots.url(for: moveSourceRole).appending(path: explicitSourcePath)
            let observedSource: OperationJournalItemState
            if isCaseOnlyRename {
                guard let exactSource = exactLeafItemState(at: source) else {
                    throw JournaledLocalFolderSyncError.unrepresentableAction(index: index)
                }
                observedSource = exactSource
            } else {
                observedSource = itemState(at: source)
            }
            guard observedSource.kind == .regularFile,
                  targetBeforeState == .missing else {
                throw JournaledLocalFolderSyncError.unrepresentableAction(index: index)
            }
            sourceBeforeState = observedSource
        case .copy:
            actionKind = .copy
            (sourceRole, sourcePath) = try journalSource(for: action, index: index)
            sourceBeforeState = nil
        case .createDirectory:
            actionKind = .createDirectory
            (sourceRole, sourcePath) = try journalSource(for: action, index: index)
            sourceBeforeState = nil
        case .delete:
            actionKind = .delete
            sourceRole = nil
            sourcePath = nil
            sourceBeforeState = nil
        case .replace:
            actionKind = .replace
            (sourceRole, sourcePath) = try journalSource(for: action, index: index)
            sourceBeforeState = nil
        case .conflict, .noOp:
            actionKind = .omit
            sourceRole = nil
            sourcePath = nil
            sourceBeforeState = nil
        }

        let backup = action.kind == .delete || action.kind == .replace
            ? OperationJournalBackupMapping(
                backupRelativePath: targetSide.rawValue + "/" + targetPath
            )
            : nil
        return OperationJournalStep(
            actionKind: actionKind,
            relativePath: targetPath,
            sourceRootRole: sourceRole,
            sourceRelativePath: actionKind == .move
                ? sourcePath
                : sourcePath == targetPath ? nil : sourcePath,
            targetRootRole: targetRole,
            backup: backup,
            beforeState: targetBeforeState,
            sourceBeforeState: sourceBeforeState
        )
    }

    private func journalSource(
        for action: FolderSyncAction,
        index: Int
    ) throws -> (OperationJournalRootRole, String) {
        guard let sourceSide = action.sourceSide,
              let sourcePath = action.sourceRelativePath,
              isSafeRelativePath(sourcePath) else {
            throw JournaledLocalFolderSyncError.unrepresentableAction(index: index)
        }
        return (rootRole(for: sourceSide), sourcePath)
    }

    private func validatedResults(
        _ log: LocalFolderSyncExecutionLog,
        plan: FolderSyncPlan
    ) throws -> [Int: LocalFolderSyncItemResult] {
        let results = log.itemResults
        guard log.mode == plan.mode,
              results.count == plan.actions.count else {
            throw JournaledLocalFolderSyncError.inconsistentExecutionLog
        }
        var indexed: [Int: LocalFolderSyncItemResult] = [:]
        indexed.reserveCapacity(results.count)
        for result in results {
            guard plan.actions.indices.contains(result.actionIndex),
                  result.action == plan.actions[result.actionIndex],
                  indexed.updateValue(result, forKey: result.actionIndex) == nil else {
                throw JournaledLocalFolderSyncError.inconsistentExecutionLog
            }
        }
        guard Set(indexed.keys) == Set(plan.actions.indices) else {
            throw JournaledLocalFolderSyncError.inconsistentExecutionLog
        }
        return indexed
    }

    private func moveObservationMismatchCode(
        for step: OperationJournalStep,
        claimedStatus: OperationJournalStepStatus,
        targetAfterState: OperationJournalItemState,
        sourceAfterState: OperationJournalItemState?
    ) -> OperationJournalFailureCode? {
        guard step.actionKind == .move else { return nil }
        switch claimedStatus {
        case .completed:
            guard targetAfterState.kind == .regularFile,
                  sourceAfterState == .missing else {
                return sourceAfterState == .missing ? .targetChanged : .sourceChanged
            }
        case .rolledBack:
            guard targetAfterState == .missing,
                  sourceAfterState?.kind == .regularFile else {
                return .rollbackFailed
            }
        case .pending, .executing, .failed:
            break
        }
        return nil
    }

    private func terminalJournalStatus(
        for status: LocalFolderSyncExecutionStatus
    ) -> OperationJournalStatus {
        switch status {
        case .completed: .completed
        case .failedRolledBack: .rolledBack
        case .refused, .failedRollbackIncomplete: .failed
        case .dryRun: .failed
        }
    }

    private func journalStepStatus(
        for status: LocalFolderSyncItemStatus
    ) -> OperationJournalStepStatus {
        switch status {
        case .completed: .completed
        case .rolledBack: .rolledBack
        case .planned, .refused, .failed, .notRun, .rollbackFailed: .failed
        }
    }

    private func rootFailureCode(
        for log: LocalFolderSyncExecutionLog
    ) -> OperationJournalFailureCode {
        if log.status == .failedRollbackIncomplete { return .rollbackFailed }
        return log.issues.first.map(failureCode(for:)) ?? .unknown
    }

    private func stepFailureCode(
        for result: LocalFolderSyncItemResult,
        issues: [LocalFolderSyncExecutionIssue]
    ) -> OperationJournalFailureCode {
        if result.status == .rollbackFailed { return .rollbackFailed }
        return issues.first(where: { $0.actionIndex == result.actionIndex })
            .map(failureCode(for:))
            ?? issues.first.map(failureCode(for:))
            ?? .actionFailed
    }

    private func failureCode(
        for issue: LocalFolderSyncExecutionIssue
    ) -> OperationJournalFailureCode {
        switch issue.code {
        case .conflict, .highRiskNotAllowed, .invalidRoot, .overlappingRoots,
             .invalidRelativePath, .malformedAction, .duplicateTarget:
            .invalidPlan
        case .missingSource:
            .sourceMissing
        case .moveVerificationFailed, .unexpectedSourceType:
            .sourceChanged
        case .cancelled:
            .cancelled
        case .invalidTargetState, .missingParentDirectory:
            .targetChanged
        case .symbolicLinkTraversal:
            .symbolicLinkTraversal
        case .backupCollision:
            .backupFailed
        case .executionFailed:
            .actionFailed
        case .rollbackFailed:
            .rollbackFailed
        }
    }

    private func canonicalRoots(left: URL, right: URL, backup: URL) -> CanonicalRoots {
        CanonicalRoots(
            left: canonicalFileSystemURL(left.standardizedFileURL)
                ?? left.standardizedFileURL.resolvingSymlinksInPath(),
            right: canonicalFileSystemURL(right.standardizedFileURL)
                ?? right.standardizedFileURL.resolvingSymlinksInPath(),
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
        let canonicalAncestor = canonicalFileSystemURL(ancestor)
            ?? ancestor.resolvingSymlinksInPath()
        return missing.reversed().reduce(canonicalAncestor) { partial, component in
            partial.appending(path: component, directoryHint: .isDirectory)
        }
    }

    /// Foundation's `resolvingSymlinksInPath()` can preserve `/tmp` on macOS.
    /// `realpath` gives the journal the same no-symlink root spelling used by the
    /// descriptor-backed executor, so `O_NOFOLLOW_ANY` observes the intended root.
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

    private func targetURL(for step: OperationJournalStep, roots: CanonicalRoots) -> URL {
        roots.url(for: step.targetRootRole).appending(path: step.relativePath)
    }

    private func sourceURL(for step: OperationJournalStep, roots: CanonicalRoots) -> URL? {
        guard step.actionKind == .move,
              let sourceRootRole = step.sourceRootRole,
              let sourceRelativePath = step.sourceRelativePath else {
            return nil
        }
        return roots.url(for: sourceRootRole).appending(path: sourceRelativePath)
    }

    private func rootRole(for side: FolderSyncSide) -> OperationJournalRootRole {
        switch side {
        case .left: .left
        case .right: .right
        }
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func pathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func isCaseOnlyMove(_ step: OperationJournalStep) -> Bool {
        guard step.actionKind == .move,
              let source = step.sourceRelativePath else { return false }
        return source.precomposedStringWithCanonicalMapping
            != step.relativePath.precomposedStringWithCanonicalMapping
            && pathKey(source) == pathKey(step.relativePath)
    }

    /// Observes one exact directory-entry spelling. A normal path lookup is
    /// insufficient on case-insensitive volumes because the old spelling also
    /// resolves after a successful case-only rename.
    private func exactLeafItemState(at url: URL) -> OperationJournalItemState? {
        let parentURL = url.deletingLastPathComponent()
        let parent = parentURL.path.withCString { path in
            journalRetrying { Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW_ANY) }
        }
        guard parent >= 0 else { return nil }
        defer { _ = Darwin.close(parent) }
        let actualLeaf: String?
        do {
            actualLeaf = try riffaExactDirectoryEntryName(
                parent: parent,
                requestedLeaf: url.lastPathComponent
            )
        } catch {
            return nil
        }
        guard let actualLeaf else {
            return .missing
        }

        var first = stat()
        let firstResult = actualLeaf.withCString {
            Darwin.fstatat(parent, $0, &first, AT_SYMLINK_NOFOLLOW)
        }
        var second = stat()
        let secondResult = actualLeaf.withCString {
            Darwin.fstatat(parent, $0, &second, AT_SYMLINK_NOFOLLOW)
        }
        guard firstResult == 0,
              secondResult == 0,
              JournalObservationVersion(first) == JournalObservationVersion(second) else {
            return nil
        }
        return itemState(first)
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

    private func itemState(_ information: stat) -> OperationJournalItemState {
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
        stage: JournaledLocalFolderSyncPersistenceStage
    ) throws {
        guard testingFailurePoint == point else { return }
        throw JournaledLocalFolderSyncError.journalPersistenceFailed(
            stage: stage,
            journalID: journalID,
            underlying: .ioFailure(.write)
        )
    }
}

private struct JournalObservationVersion: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let mode: mode_t
    let flags: UInt32
    let mtimeSeconds: Int64
    let mtimeNanoseconds: Int64
    let ctimeSeconds: Int64
    let ctimeNanoseconds: Int64

    init(_ value: stat) {
        device = UInt64(bitPattern: Int64(value.st_dev))
        inode = UInt64(value.st_ino)
        size = value.st_size
        mode = value.st_mode
        flags = UInt32(value.st_flags)
        mtimeSeconds = Int64(value.st_mtimespec.tv_sec)
        mtimeNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        ctimeSeconds = Int64(value.st_ctimespec.tv_sec)
        ctimeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

private func journalRetrying<T: FixedWidthInteger>(_ operation: () -> T) -> T {
    var result: T
    repeat {
        result = operation()
    } while result == -1 && errno == EINTR
    return result
}

private struct CanonicalRoots: Sendable {
    let left: URL
    let right: URL
    let backup: URL

    func url(for role: OperationJournalRootRole) -> URL {
        switch role {
        case .left: left
        case .right: right
        case .backup: backup
        case .base, .output:
            preconditionFailure("Folder synchronization cannot reference merge-only roots.")
        }
    }
}
