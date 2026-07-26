import Darwin
import Foundation

public enum OperationJournalKind: String, CaseIterable, Codable, Sendable {
    case sync
    case merge
}

public enum OperationJournalStatus: String, CaseIterable, Codable, Sendable {
    case preparing
    case executing
    case rollingBack
    case completed
    case rolledBack
    case failed

    public var isFinished: Bool {
        switch self {
        case .completed, .rolledBack, .failed:
            true
        case .preparing, .executing, .rollingBack:
            false
        }
    }
}

/// Logical roles deliberately keep local paths separate from operation semantics.
/// Paths are persisted by `OperationJournalRoot` as standardized absolute POSIX paths.
public enum OperationJournalRootRole: String, CaseIterable, Codable, Sendable {
    case base
    case left
    case right
    case output
    case backup
}

public struct OperationJournalRoot: Hashable, Codable, Sendable {
    public let role: OperationJournalRootRole
    public let absolutePath: String

    public init(role: OperationJournalRootRole, absolutePath: String) {
        self.role = role
        self.absolutePath = absolutePath
    }
}

public enum OperationJournalActionKind: String, CaseIterable, Codable, Sendable {
    case copy
    case createDirectory
    case delete
    case move
    case replace
    case omit
}

public enum OperationJournalStepStatus: String, CaseIterable, Codable, Sendable {
    case pending
    case executing
    case completed
    case failed
    case rolledBack
}

/// A privacy-preserving file-system observation. It intentionally contains no
/// file bytes, symbolic-link destination, extended attributes, or credentials.
public struct OperationJournalItemState: Hashable, Codable, Sendable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case missing
        case regularFile
        case directory
        case symbolicLink
        case other
    }

    public let kind: Kind
    public let byteCount: UInt64?
    public let modificationTimeNanoseconds: Int64?
    public let permissions: UInt16?

    public init(
        kind: Kind,
        byteCount: UInt64? = nil,
        modificationTimeNanoseconds: Int64? = nil,
        permissions: UInt16? = nil
    ) {
        self.kind = kind
        self.byteCount = byteCount
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.permissions = permissions
    }

    public static let missing = OperationJournalItemState(kind: .missing)
}

/// Stable, non-localized codes are the only persisted failure details. Callers
/// may present richer transient errors, but must not write their messages here.
public enum OperationJournalFailureCode: String, CaseIterable, Codable, Sendable {
    case cancelled
    case invalidPlan
    case sourceMissing
    case sourceChanged
    case targetChanged
    case permissionDenied
    case insufficientSpace
    case symbolicLinkTraversal
    case backupFailed
    case actionFailed
    case rollbackFailed
    case recoveryInterrupted
    case ioFailure
    case unknown
}

public struct OperationJournalFailure: Hashable, Codable, Sendable {
    public let code: OperationJournalFailureCode
    public let recordedAt: Date

    public init(code: OperationJournalFailureCode, recordedAt: Date) {
        self.code = code
        self.recordedAt = recordedAt
    }
}

/// Maps the step's target `(root role, relativePath)` to an item below the
/// operation's backup root. Both sides are relative to roots already in the journal.
public struct OperationJournalBackupMapping: Hashable, Codable, Sendable {
    public let backupRootRole: OperationJournalRootRole
    public let backupRelativePath: String

    public init(
        backupRootRole: OperationJournalRootRole = .backup,
        backupRelativePath: String
    ) {
        self.backupRootRole = backupRootRole
        self.backupRelativePath = backupRelativePath
    }
}

public struct OperationJournalStep: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let actionKind: OperationJournalActionKind
    /// The path below `targetRootRole`.
    public let relativePath: String
    public let sourceRootRole: OperationJournalRootRole?
    /// Nil means the source uses `relativePath` too.
    public let sourceRelativePath: String?
    public let targetRootRole: OperationJournalRootRole
    public let backup: OperationJournalBackupMapping?
    public let status: OperationJournalStepStatus
    /// The target observation before and after this step.
    public let beforeState: OperationJournalItemState?
    public let afterState: OperationJournalItemState?
    /// Source observations are persisted only for `move`, where both paths are
    /// required to distinguish an uncommitted, committed, or rolled-back step.
    public let sourceBeforeState: OperationJournalItemState?
    public let sourceAfterState: OperationJournalItemState?
    public let failure: OperationJournalFailure?

    public init(
        id: UUID = UUID(),
        actionKind: OperationJournalActionKind,
        relativePath: String,
        sourceRootRole: OperationJournalRootRole? = nil,
        sourceRelativePath: String? = nil,
        targetRootRole: OperationJournalRootRole,
        backup: OperationJournalBackupMapping? = nil,
        status: OperationJournalStepStatus = .pending,
        beforeState: OperationJournalItemState? = nil,
        afterState: OperationJournalItemState? = nil,
        sourceBeforeState: OperationJournalItemState? = nil,
        sourceAfterState: OperationJournalItemState? = nil,
        failure: OperationJournalFailure? = nil
    ) {
        self.id = id
        self.actionKind = actionKind
        self.relativePath = relativePath
        self.sourceRootRole = sourceRootRole
        self.sourceRelativePath = sourceRelativePath
        self.targetRootRole = targetRootRole
        self.backup = backup
        self.status = status
        self.beforeState = beforeState
        self.afterState = afterState
        self.sourceBeforeState = sourceBeforeState
        self.sourceAfterState = sourceAfterState
        self.failure = failure
    }
}

public struct OperationJournal: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let kind: OperationJournalKind
    public let createdAt: Date
    public let updatedAt: Date
    public let status: OperationJournalStatus
    public let roots: [OperationJournalRoot]
    public let steps: [OperationJournalStep]
    public let failure: OperationJournalFailure?
    /// Monotonically increases for every persisted mutation after creation.
    public let revision: UInt64

    public init(
        id: UUID = UUID(),
        kind: OperationJournalKind,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        status: OperationJournalStatus = .preparing,
        roots: [OperationJournalRoot],
        steps: [OperationJournalStep] = [],
        failure: OperationJournalFailure? = nil,
        revision: UInt64 = 0
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.status = status
        self.roots = roots
        self.steps = steps
        self.failure = failure
        self.revision = revision
    }
}

public struct OperationJournalEnvelope: Hashable, Codable, Sendable {
    /// Schema 2 adds first-class move steps and optional source observations.
    /// Schema 1 remains decodable because the new observations are optional.
    public static let currentSchemaVersion = 2
    static let minimumReadableSchemaVersion = 1

    public let schemaVersion: Int
    public let journal: OperationJournal

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        journal: OperationJournal
    ) {
        self.schemaVersion = schemaVersion
        self.journal = journal
    }
}

public enum OperationJournalStorageLocation: String, Codable, Sendable {
    case active
    case archive
}

public enum OperationJournalIOOperation: String, Codable, Sendable {
    case createDirectory
    case lock
    case read
    case encode
    case write
    case list
    case archive
    case remove
}

/// Store errors contain stable codes and model identifiers only. In particular,
/// Foundation error descriptions and absolute paths are never retained here.
public enum OperationJournalStoreError: Error, Equatable, Sendable {
    case ioFailure(OperationJournalIOOperation)
    case journalNotFound(UUID)
    case journalAlreadyExists(UUID)
    case archivedJournalAlreadyExists(UUID)
    case corruptedJSON(UUID?)
    case unsupportedJournalFile
    case futureSchemaVersion(found: Int, supported: Int)
    case migrationRequired(found: Int, current: Int)
    case journalIDMismatch(expected: UUID, found: UUID)
    case invalidInitialStatus(OperationJournalStatus)
    case invalidRevision(expected: UInt64, found: UInt64)
    case revisionOverflow
    case invalidTimestamp
    case duplicateRootRole(OperationJournalRootRole)
    case duplicateRootPath
    case missingRootRole(OperationJournalRootRole)
    case unexpectedRootRole(OperationJournalRootRole)
    case overlappingRootPaths
    case unsafeAbsolutePath(OperationJournalRootRole)
    case tooManySteps
    case duplicateStepID(UUID)
    case duplicateTargetPath
    case duplicateMoveSourcePath
    case moveSourceTargetConflict
    case duplicateBackupPath
    case unsafeRelativePath(UUID)
    case unknownStepRoot(stepID: UUID, role: OperationJournalRootRole)
    case invalidStepRoles(UUID)
    case invalidStepState(UUID)
    case invalidItemState(UUID)
    case invalidFailureTimestamp
    case invalidStatusTransition(from: OperationJournalStatus, to: OperationJournalStatus)
    case invalidStepStatusTransition(
        stepID: UUID,
        from: OperationJournalStepStatus,
        to: OperationJournalStepStatus
    )
    case immutableJournalField
    case immutableStepField(UUID)
    case stepNotFound(UUID)
    case journalNotFinished(UUID)
}

/// A versioned, crash-resistant operation journal directory.
///
/// Each mutation is performed while holding both actor isolation and a process-wide
/// advisory lock, so separate store actors cannot silently overwrite each other's
/// updates. Every existing file is decoded and validated before replacement.
public actor OperationJournalStore {
    public static let journalFileSuffix = ".riffa-operation.json"

    public nonisolated let directoryURL: URL
    public nonisolated let archiveDirectoryURL: URL

    private static let maximumJournalByteCount = 16 * 1_024 * 1_024
    private static let maximumStepCount = 100_000
    private static let maximumPathByteCount = 16_384

    public init(directoryURL: URL) {
        let standardized = directoryURL.standardizedFileURL
        self.directoryURL = standardized
        self.archiveDirectoryURL = standardized.appending(
            path: "archive",
            directoryHint: .isDirectory
        )
    }

    @discardableResult
    public func create(_ journal: OperationJournal) throws -> OperationJournal {
        try withExclusiveLock {
            guard journal.status == .preparing else {
                throw OperationJournalStoreError.invalidInitialStatus(journal.status)
            }
            guard journal.revision == 0 else {
                throw OperationJournalStoreError.invalidRevision(expected: 0, found: journal.revision)
            }

            let normalized = try validatedAndNormalized(journal)
            let destination = journalURL(for: journal.id, location: .active)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw OperationJournalStoreError.journalAlreadyExists(journal.id)
            }
            try write(normalized, to: destination)
            return normalized
        }
    }

    public func load(
        _ id: UUID,
        from location: OperationJournalStorageLocation = .active
    ) throws -> OperationJournal {
        try withExclusiveLock {
            try read(id, from: location)
        }
    }

    /// Appends one immutable action definition. Concurrent calls are merged against
    /// the latest file under the store lock rather than replacing a stale array.
    @discardableResult
    public func appendStep(
        _ step: OperationJournalStep,
        to journalID: UUID,
        expectedRevision: UInt64? = nil,
        updatedAt: Date = Date()
    ) throws -> OperationJournal {
        try withExclusiveLock {
            let current = try read(journalID, from: .active)
            try requireRevision(expectedRevision, current: current)
            guard current.status == .preparing else {
                throw OperationJournalStoreError.invalidStatusTransition(
                    from: current.status,
                    to: current.status
                )
            }
            guard step.status == .pending,
                  step.afterState == nil,
                  step.sourceAfterState == nil,
                  step.failure == nil else {
                throw OperationJournalStoreError.invalidStepState(step.id)
            }

            let candidate = try incremented(
                current,
                updatedAt: updatedAt,
                steps: current.steps + [step]
            )
            let normalized = try validatedMutation(from: current, to: candidate)
            try write(normalized, to: journalURL(for: journalID, location: .active))
            return normalized
        }
    }

    /// Replaces only a step's mutable execution observations. Its action, paths,
    /// roles, backup mapping, and identifier are immutable after append.
    @discardableResult
    public func updateStep(
        _ step: OperationJournalStep,
        in journalID: UUID,
        expectedRevision: UInt64? = nil,
        updatedAt: Date = Date()
    ) throws -> OperationJournal {
        try withExclusiveLock {
            let current = try read(journalID, from: .active)
            try requireRevision(expectedRevision, current: current)
            guard let index = current.steps.firstIndex(where: { $0.id == step.id }) else {
                throw OperationJournalStoreError.stepNotFound(step.id)
            }

            var steps = current.steps
            steps[index] = step
            let candidate = try incremented(current, updatedAt: updatedAt, steps: steps)
            let normalized = try validatedMutation(from: current, to: candidate)
            try write(normalized, to: journalURL(for: journalID, location: .active))
            return normalized
        }
    }

    @discardableResult
    public func transition(
        _ journalID: UUID,
        to status: OperationJournalStatus,
        failure: OperationJournalFailure? = nil,
        expectedRevision: UInt64? = nil,
        updatedAt: Date = Date()
    ) throws -> OperationJournal {
        try withExclusiveLock {
            let current = try read(journalID, from: .active)
            try requireRevision(expectedRevision, current: current)
            let candidate = try incremented(
                current,
                updatedAt: updatedAt,
                status: status,
                failure: failure
            )
            let normalized = try validatedMutation(from: current, to: candidate)
            try write(normalized, to: journalURL(for: journalID, location: .active))
            return normalized
        }
    }

    /// Atomically records a terminal recovery conclusion after revalidating the
    /// exact plan under the store's process-wide lock. This API is deliberately
    /// internal: callers use `OperationJournalRecoveryFinalizer`, which also
    /// binds the visible selection ID to the inspected plan.
    ///
    /// No path from the journal is mutated. The only write is one atomic
    /// replacement of the active journal JSON containing both the finalized
    /// step states and the journal's terminal state.
    @discardableResult
    func finalizeRecoveryMetadata(
        journalID: UUID,
        using plan: OperationJournalRecoveryPlan,
        finalizedAt: Date
    ) throws -> OperationJournal {
        try withExclusiveLock {
            guard plan.disposition == .canFinalizeCompleted
                    || plan.disposition == .canFinalizeRolledBack else {
                throw OperationJournalRecoveryFinalizationError.dispositionNotFinalizable(
                    plan.disposition
                )
            }
            guard plan.allObservationsAreAvailable else {
                throw OperationJournalRecoveryFinalizationError.recoveryEvidenceUnavailable
            }

            let current = try read(journalID, from: .active)
            guard current.id == plan.journalID else {
                throw OperationJournalRecoveryFinalizationError.journalIDChanged(
                    expected: current.id,
                    found: plan.journalID
                )
            }
            guard !current.status.isFinished else {
                throw OperationJournalRecoveryFinalizationError.journalAlreadyFinished(current.id)
            }
            guard current.kind == plan.journalKind else {
                throw OperationJournalRecoveryFinalizationError.journalKindChanged(
                    expected: plan.journalKind,
                    found: current.kind
                )
            }
            guard current.status == plan.journalStatus else {
                throw OperationJournalRecoveryFinalizationError.journalStatusChanged(
                    expected: plan.journalStatus,
                    found: current.status
                )
            }
            guard current.revision == plan.journalRevision else {
                throw OperationJournalRecoveryFinalizationError.journalRevisionChanged(
                    expected: plan.journalRevision,
                    found: current.revision
                )
            }

            // Exact plan equality rejects changes to source or backup
            // observations even when the transaction-wide disposition happens
            // to remain the same.
            let refreshedPlan = OperationJournalRecoveryAnalyzer.makePlan(for: current)
            guard refreshedPlan == plan else {
                throw OperationJournalRecoveryFinalizationError.recoveryEvidenceChanged
            }
            guard refreshedPlan.allObservationsAreAvailable else {
                throw OperationJournalRecoveryFinalizationError.recoveryEvidenceUnavailable
            }

            let terminalStatus: OperationJournalStatus = switch plan.disposition {
            case .canFinalizeCompleted: .completed
            case .canFinalizeRolledBack: .rolledBack
            case .requiresUserDecision, .inconsistentScene, .notAutomaticallyRecoverable:
                throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
            }
            guard current.steps.count == refreshedPlan.steps.count else {
                throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
            }
            let finalizedSteps = try zip(current.steps, refreshedPlan.steps).map {
                try recoveryFinalizedStep(
                    $0.0,
                    analysis: $0.1,
                    terminalStatus: terminalStatus
                )
            }
            let terminalFailure: OperationJournalFailure? = switch terminalStatus {
            case .completed:
                nil
            case .rolledBack:
                current.failure ?? OperationJournalFailure(
                    code: .recoveryInterrupted,
                    recordedAt: finalizedAt
                )
            case .preparing, .executing, .rollingBack, .failed:
                throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
            }
            let candidate = try incremented(
                current,
                updatedAt: finalizedAt,
                status: terminalStatus,
                steps: finalizedSteps,
                failure: terminalFailure
            )
            let normalized = try validatedRecoveryFinalization(
                from: current,
                to: candidate,
                disposition: plan.disposition
            )
            let encodedJournal = try encodedJournalData(normalized)

            // Proposal construction and validation can be non-trivial for a
            // large journal, as can JSON encoding. Repeat the complete
            // descriptor-safe observation after both, leaving only equality
            // comparison between the decisive scene check and the atomic write.
            let decisivePlan = OperationJournalRecoveryAnalyzer.makePlan(for: current)
            guard decisivePlan == refreshedPlan else {
                throw OperationJournalRecoveryFinalizationError.recoveryEvidenceChanged
            }
            try writeJournalData(
                encodedJournal,
                to: journalURL(for: journalID, location: .active)
            )
            return normalized
        }
    }

    public func listUnfinished() throws -> [OperationJournal] {
        try withExclusiveLock {
            try activeJournals().filter { !$0.status.isFinished }
        }
    }

    public func listActive() throws -> [OperationJournal] {
        try withExclusiveLock {
            try activeJournals()
        }
    }

    /// Returns validated terminal and non-terminal journals that have already
    /// been moved below the archive directory. A store that has never archived
    /// an operation returns an empty collection and does not create the archive
    /// directory as a side effect.
    ///
    /// The archive directory and every journal entry are inspected without
    /// following symbolic links. As with `listActive()`, a malformed journal
    /// fails the entire scan closed instead of silently disappearing from the
    /// operation history.
    public func listArchived() throws -> [OperationJournal] {
        try withExclusiveLock {
            try archivedJournals()
        }
    }

    /// Atomically moves a terminal journal below this store's archive directory.
    /// No path referenced by the journal is touched.
    @discardableResult
    public func archiveFinished(_ id: UUID) throws -> URL {
        try withExclusiveLock {
            let journal = try read(id, from: .active)
            guard journal.status.isFinished else {
                throw OperationJournalStoreError.journalNotFinished(id)
            }

            try ensureDirectory(archiveDirectoryURL)
            let source = journalURL(for: id, location: .active)
            let destination = journalURL(for: id, location: .archive)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw OperationJournalStoreError.archivedJournalAlreadyExists(id)
            }
            do {
                try FileManager.default.moveItem(at: source, to: destination)
            } catch {
                throw OperationJournalStoreError.ioFailure(.archive)
            }
            return destination
        }
    }

    /// Removes exactly one validated, terminal journal file. It never follows a
    /// journal path or deletes a root, backup, or other user resource.
    public func removeFinished(
        _ id: UUID,
        from location: OperationJournalStorageLocation = .active
    ) throws {
        try withExclusiveLock {
            let journal = try read(id, from: location)
            guard journal.status.isFinished else {
                throw OperationJournalStoreError.journalNotFinished(id)
            }
            do {
                try FileManager.default.removeItem(at: journalURL(for: id, location: location))
            } catch {
                throw OperationJournalStoreError.ioFailure(.remove)
            }
        }
    }

    private func activeJournals() throws -> [OperationJournal] {
        try journals(in: .active, missingDirectoryIsEmpty: false)
    }

    private func archivedJournals() throws -> [OperationJournal] {
        try journals(in: .archive, missingDirectoryIsEmpty: true)
    }

    private func journals(
        in location: OperationJournalStorageLocation,
        missingDirectoryIsEmpty: Bool
    ) throws -> [OperationJournal] {
        let fileManager = FileManager.default
        let scanDirectory = switch location {
        case .active: directoryURL
        case .archive: archiveDirectoryURL
        }

        switch try directoryKindWithoutFollowingLinks(at: scanDirectory) {
        case .missing where missingDirectoryIsEmpty:
            return []
        case .missing, .unsupported:
            throw OperationJournalStoreError.ioFailure(.list)
        case .directory:
            break
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: scanDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw OperationJournalStoreError.ioFailure(.list)
        }

        var journals: [OperationJournal] = []
        for entry in entries where entry.lastPathComponent.hasSuffix(Self.journalFileSuffix) {
            let name = String(entry.lastPathComponent.dropLast(Self.journalFileSuffix.count))
            guard let id = UUID(uuidString: name) else {
                throw OperationJournalStoreError.unsupportedJournalFile
            }
            journals.append(try read(id, from: location))
        }
        return journals.sorted(by: journalComesBefore)
    }

    private enum DirectoryKind {
        case missing
        case directory
        case unsupported
    }

    /// `FileManager.fileExists` follows links, which is inappropriate for a
    /// recovery log store. `lstat` lets list operations distinguish a genuinely
    /// absent archive from a symlink (including a broken one) without traversing it.
    private func directoryKindWithoutFollowingLinks(at url: URL) throws -> DirectoryKind {
        guard url.isFileURL else {
            throw OperationJournalStoreError.ioFailure(.list)
        }

        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &metadata)
        }
        guard result == 0 else {
            if errno == ENOENT {
                return .missing
            }
            throw OperationJournalStoreError.ioFailure(.list)
        }

        let kind = metadata.st_mode & mode_t(S_IFMT)
        if kind == mode_t(S_IFDIR) {
            return .directory
        }
        return .unsupported
    }

    private func read(
        _ id: UUID,
        from location: OperationJournalStorageLocation
    ) throws -> OperationJournal {
        let url = journalURL(for: id, location: location)
        let data = try readJournalDataWithoutFollowingLinks(at: url, id: id)

        let header: OperationJournalSchemaHeader
        do {
            header = try JSONDecoder().decode(OperationJournalSchemaHeader.self, from: data)
        } catch {
            throw OperationJournalStoreError.corruptedJSON(id)
        }
        if header.schemaVersion > OperationJournalEnvelope.currentSchemaVersion {
            throw OperationJournalStoreError.futureSchemaVersion(
                found: header.schemaVersion,
                supported: OperationJournalEnvelope.currentSchemaVersion
            )
        }
        if header.schemaVersion < OperationJournalEnvelope.minimumReadableSchemaVersion {
            throw OperationJournalStoreError.migrationRequired(
                found: header.schemaVersion,
                current: OperationJournalEnvelope.currentSchemaVersion
            )
        }

        let envelope: OperationJournalEnvelope
        do {
            envelope = try JSONDecoder().decode(OperationJournalEnvelope.self, from: data)
        } catch {
            throw OperationJournalStoreError.corruptedJSON(id)
        }
        guard envelope.journal.id == id else {
            throw OperationJournalStoreError.journalIDMismatch(
                expected: id,
                found: envelope.journal.id
            )
        }
        return try validatedAndNormalized(envelope.journal)
    }

    /// Opens the exact directory entry with `O_NOFOLLOW`, validates the opened
    /// descriptor, and performs a bounded read. This avoids a check/use window
    /// where a journal could be swapped for a symbolic link after enumeration.
    private func readJournalDataWithoutFollowingLinks(at url: URL, id: UUID) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw OperationJournalStoreError.journalNotFound(id)
            }
            if errno == ELOOP {
                throw OperationJournalStoreError.corruptedJSON(id)
            }
            throw OperationJournalStoreError.ioFailure(.read)
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw OperationJournalStoreError.ioFailure(.read)
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(Self.maximumJournalByteCount) else {
            throw OperationJournalStoreError.corruptedJSON(id)
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 {
                break
            }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw OperationJournalStoreError.ioFailure(.read)
            }
            guard data.count <= Self.maximumJournalByteCount - count else {
                throw OperationJournalStoreError.corruptedJSON(id)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func write(_ journal: OperationJournal, to url: URL) throws {
        try writeJournalData(try encodedJournalData(journal), to: url)
    }

    private func encodedJournalData(_ journal: OperationJournal) throws -> Data {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(OperationJournalEnvelope(journal: journal))
        } catch {
            throw OperationJournalStoreError.ioFailure(.encode)
        }
        guard data.count <= Self.maximumJournalByteCount else {
            throw OperationJournalStoreError.tooManySteps
        }
        return data
    }

    private func writeJournalData(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw OperationJournalStoreError.ioFailure(.write)
        }
    }

    private func validatedAndNormalized(_ journal: OperationJournal) throws -> OperationJournal {
        try validate(journal)
        let roots = journal.roots.sorted { $0.role.rawValue < $1.role.rawValue }
        return OperationJournal(
            id: journal.id,
            kind: journal.kind,
            createdAt: journal.createdAt,
            updatedAt: journal.updatedAt,
            status: journal.status,
            roots: roots,
            steps: journal.steps,
            failure: journal.failure,
            revision: journal.revision
        )
    }

    private func validate(_ journal: OperationJournal) throws {
        guard journal.createdAt.timeIntervalSinceReferenceDate.isFinite,
              journal.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              journal.createdAt <= journal.updatedAt else {
            throw OperationJournalStoreError.invalidTimestamp
        }
        guard journal.steps.count <= Self.maximumStepCount else {
            throw OperationJournalStoreError.tooManySteps
        }

        let expectedRoles: Set<OperationJournalRootRole>
        switch journal.kind {
        case .sync:
            expectedRoles = [.left, .right, .backup]
        case .merge:
            expectedRoles = [.base, .left, .right, .output, .backup]
        }

        var roles = Set<OperationJournalRootRole>()
        var rootPathKeys = Set<String>()
        var rootPaths: [OperationJournalRootRole: String] = [:]
        for root in journal.roots {
            guard roles.insert(root.role).inserted else {
                throw OperationJournalStoreError.duplicateRootRole(root.role)
            }
            guard expectedRoles.contains(root.role) else {
                throw OperationJournalStoreError.unexpectedRootRole(root.role)
            }
            guard isSafeAbsolutePath(root.absolutePath) else {
                throw OperationJournalStoreError.unsafeAbsolutePath(root.role)
            }
            guard rootPathKeys.insert(pathKey(root.absolutePath)).inserted else {
                throw OperationJournalStoreError.duplicateRootPath
            }
            rootPaths[root.role] = root.absolutePath
        }
        for role in expectedRoles where !roles.contains(role) {
            throw OperationJournalStoreError.missingRootRole(role)
        }
        try validateRootOverlaps(kind: journal.kind, paths: rootPaths)

        try validateFailure(journal.failure, journal: journal)
        switch journal.status {
        case .preparing:
            guard journal.failure == nil,
                  journal.steps.allSatisfy({ $0.status == .pending }) else {
                throw OperationJournalStoreError.invalidInitialStatus(journal.status)
            }
        case .executing:
            guard journal.failure == nil else {
                throw OperationJournalStoreError.invalidInitialStatus(journal.status)
            }
            if let rolledBack = journal.steps.first(where: { $0.status == .rolledBack }) {
                throw OperationJournalStoreError.invalidStepState(rolledBack.id)
            }
        case .rollingBack:
            guard journal.failure != nil,
                  !journal.steps.contains(where: { $0.status == .executing }) else {
                throw OperationJournalStoreError.invalidInitialStatus(journal.status)
            }
        case .completed:
            guard journal.failure == nil,
                  journal.steps.allSatisfy({ $0.status == .completed }) else {
                throw OperationJournalStoreError.invalidInitialStatus(journal.status)
            }
        case .rolledBack:
            guard journal.failure != nil,
                  journal.steps.allSatisfy({
                      $0.status == .pending || $0.status == .failed || $0.status == .rolledBack
                  }) else {
                throw OperationJournalStoreError.invalidInitialStatus(journal.status)
            }
        case .failed:
            guard journal.failure != nil else {
                throw OperationJournalStoreError.invalidInitialStatus(journal.status)
            }
        }

        var stepIDs = Set<UUID>()
        var targets: [String: UUID] = [:]
        var moveSources: [String: UUID] = [:]
        var backups = Set<String>()
        for step in journal.steps {
            guard stepIDs.insert(step.id).inserted else {
                throw OperationJournalStoreError.duplicateStepID(step.id)
            }
            try validate(step, kind: journal.kind, roots: roles, journal: journal)

            let targetKey = step.targetRootRole.rawValue + "\0" + pathKey(step.relativePath)
            guard targets.updateValue(step.id, forKey: targetKey) == nil else {
                throw OperationJournalStoreError.duplicateTargetPath
            }
            if step.actionKind == .move,
               let sourceRole = step.sourceRootRole,
               let sourcePath = step.sourceRelativePath {
                let sourceKey = sourceRole.rawValue + "\0" + pathKey(sourcePath)
                guard moveSources.updateValue(step.id, forKey: sourceKey) == nil else {
                    throw OperationJournalStoreError.duplicateMoveSourcePath
                }
            }
            if let backup = step.backup {
                let backupKey = backup.backupRootRole.rawValue + "\0" + pathKey(backup.backupRelativePath)
                guard backups.insert(backupKey).inserted else {
                    throw OperationJournalStoreError.duplicateBackupPath
                }
            }
        }
        for key in Set(moveSources.keys).intersection(targets.keys) {
            let sourceStepID = moveSources[key]!
            let targetStepID = targets[key]!
            if sourceStepID == targetStepID,
               let step = journal.steps.first(where: { $0.id == sourceStepID }),
               isCaseOnlyMove(step) {
                continue
            }
            throw OperationJournalStoreError.moveSourceTargetConflict
        }
    }

    private func validate(
        _ step: OperationJournalStep,
        kind: OperationJournalKind,
        roots: Set<OperationJournalRootRole>,
        journal: OperationJournal
    ) throws {
        guard isSafeRelativePath(step.relativePath),
              step.sourceRelativePath.map(isSafeRelativePath) ?? true else {
            throw OperationJournalStoreError.unsafeRelativePath(step.id)
        }
        guard roots.contains(step.targetRootRole) else {
            throw OperationJournalStoreError.unknownStepRoot(
                stepID: step.id,
                role: step.targetRootRole
            )
        }
        if let source = step.sourceRootRole, !roots.contains(source) {
            throw OperationJournalStoreError.unknownStepRoot(stepID: step.id, role: source)
        }

        switch step.actionKind {
        case .copy, .createDirectory, .replace:
            guard step.sourceRootRole != nil,
                  step.sourceRootRole != step.targetRootRole else {
                throw OperationJournalStoreError.invalidStepRoles(step.id)
            }
        case .move:
            guard let sourceRootRole = step.sourceRootRole,
                  let sourceRelativePath = step.sourceRelativePath,
                  sourceRootRole == step.targetRootRole,
                  sourceRelativePath.precomposedStringWithCanonicalMapping
                    != step.relativePath.precomposedStringWithCanonicalMapping,
                  pathKey(sourceRelativePath) != pathKey(step.relativePath)
                    || parentPath(of: sourceRelativePath) == parentPath(of: step.relativePath) else {
                throw OperationJournalStoreError.invalidStepRoles(step.id)
            }
        case .delete, .omit:
            guard step.sourceRootRole == nil, step.sourceRelativePath == nil else {
                throw OperationJournalStoreError.invalidStepRoles(step.id)
            }
        }

        if step.sourceRootRole == nil, step.sourceRelativePath != nil {
            throw OperationJournalStoreError.invalidStepRoles(step.id)
        }
        switch kind {
        case .sync:
            guard step.targetRootRole == .left || step.targetRootRole == .right,
                  step.sourceRootRole.map({ $0 == .left || $0 == .right }) ?? true else {
                throw OperationJournalStoreError.invalidStepRoles(step.id)
            }
        case .merge:
            guard step.targetRootRole == .output,
                  step.sourceRootRole.map({ $0 == .base || $0 == .left || $0 == .right }) ?? true else {
                throw OperationJournalStoreError.invalidStepRoles(step.id)
            }
        }

        if let backup = step.backup {
            guard step.actionKind != .move,
                  backup.backupRootRole == .backup,
                  roots.contains(backup.backupRootRole) else {
                throw OperationJournalStoreError.invalidStepRoles(step.id)
            }
            guard isSafeRelativePath(backup.backupRelativePath) else {
                throw OperationJournalStoreError.unsafeRelativePath(step.id)
            }
        }

        try validateItemState(step.beforeState, stepID: step.id)
        try validateItemState(step.afterState, stepID: step.id)
        try validateItemState(step.sourceBeforeState, stepID: step.id)
        try validateItemState(step.sourceAfterState, stepID: step.id)
        try validateFailure(step.failure, journal: journal)

        if step.actionKind == .move {
            try validateMoveStates(step)
        } else if step.sourceBeforeState != nil || step.sourceAfterState != nil {
            throw OperationJournalStoreError.invalidStepState(step.id)
        }

        switch step.status {
        case .pending:
            guard step.afterState == nil, step.failure == nil else {
                throw OperationJournalStoreError.invalidStepState(step.id)
            }
        case .executing:
            guard step.afterState == nil, step.failure == nil else {
                throw OperationJournalStoreError.invalidStepState(step.id)
            }
        case .completed:
            guard step.afterState != nil, step.failure == nil else {
                throw OperationJournalStoreError.invalidStepState(step.id)
            }
        case .failed:
            guard step.failure != nil else {
                throw OperationJournalStoreError.invalidStepState(step.id)
            }
        case .rolledBack:
            guard step.afterState != nil else {
                throw OperationJournalStoreError.invalidStepState(step.id)
            }
        }
    }

    private func validateMoveStates(_ step: OperationJournalStep) throws {
        guard step.backup == nil,
              step.beforeState == .missing,
              step.sourceBeforeState?.kind == .regularFile else {
            throw OperationJournalStoreError.invalidStepState(step.id)
        }

        switch step.status {
        case .pending, .executing:
            guard step.afterState == nil,
                  step.sourceAfterState == nil else {
                throw OperationJournalStoreError.invalidStepState(step.id)
            }
        case .completed:
            guard step.afterState?.kind == .regularFile,
                  step.sourceAfterState == .missing else {
                throw OperationJournalStoreError.invalidStepState(step.id)
            }
        case .rolledBack:
            guard step.afterState == .missing,
                  step.sourceAfterState?.kind == .regularFile else {
                throw OperationJournalStoreError.invalidStepState(step.id)
            }
        case .failed:
            // A failed move may legitimately expose any pair of observed kinds
            // (including a link inserted by another process). Persist the exact
            // failure scene so recovery can refuse it safely instead of making
            // the journal itself impossible to write.
            guard step.afterState != nil,
                  step.sourceAfterState != nil else {
                throw OperationJournalStoreError.invalidStepState(step.id)
            }
        }
    }

    private func validateItemState(
        _ state: OperationJournalItemState?,
        stepID: UUID
    ) throws {
        guard let state else { return }
        if state.kind == .missing,
           state.byteCount != nil || state.modificationTimeNanoseconds != nil || state.permissions != nil {
            throw OperationJournalStoreError.invalidItemState(stepID)
        }
        if state.kind != .regularFile, state.byteCount != nil {
            throw OperationJournalStoreError.invalidItemState(stepID)
        }
        if let permissions = state.permissions, permissions > 0o7777 {
            throw OperationJournalStoreError.invalidItemState(stepID)
        }
    }

    private func validateFailure(
        _ failure: OperationJournalFailure?,
        journal: OperationJournal
    ) throws {
        guard let failure else { return }
        guard failure.recordedAt.timeIntervalSinceReferenceDate.isFinite,
              failure.recordedAt >= journal.createdAt,
              failure.recordedAt <= journal.updatedAt else {
            throw OperationJournalStoreError.invalidFailureTimestamp
        }
    }

    private func validatedMutation(
        from old: OperationJournal,
        to proposed: OperationJournal
    ) throws -> OperationJournal {
        guard old.id == proposed.id,
              old.kind == proposed.kind,
              old.createdAt == proposed.createdAt,
              old.roots == proposed.roots else {
            throw OperationJournalStoreError.immutableJournalField
        }
        guard proposed.revision == old.revision + 1 else {
            throw OperationJournalStoreError.invalidRevision(
                expected: old.revision + 1,
                found: proposed.revision
            )
        }
        guard allowedTransition(from: old.status, to: proposed.status) else {
            throw OperationJournalStoreError.invalidStatusTransition(
                from: old.status,
                to: proposed.status
            )
        }
        guard proposed.steps.count >= old.steps.count else {
            throw OperationJournalStoreError.immutableJournalField
        }

        for index in old.steps.indices {
            let previous = old.steps[index]
            let next = proposed.steps[index]
            guard sameStepDefinition(previous, next) else {
                throw OperationJournalStoreError.immutableStepField(previous.id)
            }
            guard allowedStepTransition(from: previous.status, to: next.status) else {
                throw OperationJournalStoreError.invalidStepStatusTransition(
                    stepID: previous.id,
                    from: previous.status,
                    to: next.status
                )
            }
            if let before = previous.beforeState, next.beforeState != before {
                throw OperationJournalStoreError.immutableStepField(previous.id)
            }
            if let after = previous.afterState, next.afterState != after {
                guard permitsMoveRollbackObservationChange(from: previous, to: next) else {
                    throw OperationJournalStoreError.immutableStepField(previous.id)
                }
            }
            if let sourceBefore = previous.sourceBeforeState,
               next.sourceBeforeState != sourceBefore {
                throw OperationJournalStoreError.immutableStepField(previous.id)
            }
            if let sourceAfter = previous.sourceAfterState,
               next.sourceAfterState != sourceAfter {
                guard permitsMoveRollbackObservationChange(from: previous, to: next) else {
                    throw OperationJournalStoreError.immutableStepField(previous.id)
                }
            }
            if let failure = previous.failure, next.failure != failure {
                throw OperationJournalStoreError.immutableStepField(previous.id)
            }
        }
        if proposed.steps.count > old.steps.count, old.status != .preparing {
            throw OperationJournalStoreError.invalidStatusTransition(from: old.status, to: old.status)
        }

        return try validatedAndNormalized(proposed)
    }

    /// A separate, narrower validator for metadata-only crash finalization. It
    /// does not alter `allowedTransition` or `allowedStepTransition`, so normal
    /// execution APIs retain their existing state machine.
    private func validatedRecoveryFinalization(
        from old: OperationJournal,
        to proposed: OperationJournal,
        disposition: OperationJournalRecoveryDisposition
    ) throws -> OperationJournal {
        let expectedStatus: OperationJournalStatus = switch disposition {
        case .canFinalizeCompleted: .completed
        case .canFinalizeRolledBack: .rolledBack
        case .requiresUserDecision, .inconsistentScene, .notAutomaticallyRecoverable:
            throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
        }
        let expectedStepStatus: OperationJournalStepStatus = switch disposition {
        case .canFinalizeCompleted: .completed
        case .canFinalizeRolledBack: .rolledBack
        case .requiresUserDecision, .inconsistentScene, .notAutomaticallyRecoverable:
            throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
        }

        guard old.id == proposed.id,
              old.kind == proposed.kind,
              old.createdAt == proposed.createdAt,
              old.roots == proposed.roots,
              old.steps.count == proposed.steps.count,
              proposed.status == expectedStatus,
              proposed.steps.allSatisfy({ $0.status == expectedStepStatus }) else {
            throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
        }
        guard old.revision < UInt64.max,
              proposed.revision == old.revision + 1 else {
            throw OperationJournalStoreError.invalidRevision(
                expected: old.revision == UInt64.max ? old.revision : old.revision + 1,
                found: proposed.revision
            )
        }

        if expectedStatus == .completed {
            guard proposed.failure == nil else {
                throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
            }
        } else {
            guard let proposedFailure = proposed.failure,
                  old.failure == nil || old.failure == proposedFailure else {
                throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
            }
        }

        for (previous, next) in zip(old.steps, proposed.steps) {
            guard sameStepDefinition(previous, next),
                  previous.beforeState == next.beforeState,
                  previous.sourceBeforeState == next.sourceBeforeState else {
                throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
            }
            // Persisted post-operation observations are evidence, not scratch
            // fields. Finalization may fill an absent observation from the fresh
            // descriptor-safe scene, but can never rewrite existing evidence.
            if let after = previous.afterState, next.afterState != after {
                throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
            }
            if let sourceAfter = previous.sourceAfterState,
               next.sourceAfterState != sourceAfter {
                throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
            }
            if let failure = previous.failure, next.failure != failure {
                throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
            }
        }
        return try validatedAndNormalized(proposed)
    }

    private func recoveryFinalizedStep(
        _ step: OperationJournalStep,
        analysis: OperationJournalRecoveryStepAnalysis,
        terminalStatus: OperationJournalStatus
    ) throws -> OperationJournalStep {
        guard step.id == analysis.stepID,
              step.actionKind == analysis.actionKind,
              step.status == analysis.recordedStatus,
              let targetState = analysis.target.result.state else {
            throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
        }

        let stepStatus: OperationJournalStepStatus
        let afterState: OperationJournalItemState
        let sourceAfterState: OperationJournalItemState?
        switch terminalStatus {
        case .completed:
            guard analysis.classification == .safelyCompleted else {
                throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
            }
            if step.status == .completed {
                return step
            }
            guard step.status == .pending || step.status == .executing else {
                throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
            }
            stepStatus = .completed
            afterState = targetState
            if step.actionKind == .move {
                guard step.beforeState == .missing,
                      let sourceBefore = step.sourceBeforeState,
                      let observedSource = analysis.source?.result.state,
                      targetState == sourceBefore,
                      observedSource == .missing else {
                    throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
                }
                sourceAfterState = observedSource
            } else {
                switch step.actionKind {
                case .delete, .omit:
                    guard step.beforeState?.kind != .missing,
                          targetState == .missing else {
                        throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
                    }
                case .createDirectory:
                    guard step.beforeState == .missing,
                          targetState.kind == .directory else {
                        throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
                    }
                case .copy, .replace, .move:
                    // Schema 2 has no content identity from which an unrecorded
                    // copy/replace completion could be truthfully synthesized.
                    throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
                }
                sourceAfterState = nil
            }

        case .rolledBack:
            guard analysis.classification == .safelyRolledBack else {
                throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
            }
            if step.status == .rolledBack {
                return step
            }
            guard step.status == .pending || step.status == .executing else {
                throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
            }
            stepStatus = .rolledBack
            afterState = targetState
            if step.actionKind == .move {
                guard targetState == .missing,
                      let sourceBefore = step.sourceBeforeState,
                      let observedSource = analysis.source?.result.state,
                      observedSource == sourceBefore else {
                    throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
                }
                sourceAfterState = observedSource
            } else {
                guard targetState == step.beforeState else {
                    throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
                }
                sourceAfterState = nil
            }

        case .preparing, .executing, .rollingBack, .failed:
            throw OperationJournalRecoveryFinalizationError.invalidRecoveryPlan
        }

        return OperationJournalStep(
            id: step.id,
            actionKind: step.actionKind,
            relativePath: step.relativePath,
            sourceRootRole: step.sourceRootRole,
            sourceRelativePath: step.sourceRelativePath,
            targetRootRole: step.targetRootRole,
            backup: step.backup,
            status: stepStatus,
            beforeState: step.beforeState,
            afterState: afterState,
            sourceBeforeState: step.sourceBeforeState,
            sourceAfterState: sourceAfterState,
            failure: step.failure
        )
    }

    private func permitsMoveRollbackObservationChange(
        from previous: OperationJournalStep,
        to next: OperationJournalStep
    ) -> Bool {
        previous.actionKind == .move
            && previous.status != .rolledBack
            && next.status == .rolledBack
    }

    private func sameStepDefinition(
        _ left: OperationJournalStep,
        _ right: OperationJournalStep
    ) -> Bool {
        left.id == right.id
            && left.actionKind == right.actionKind
            && left.relativePath == right.relativePath
            && left.sourceRootRole == right.sourceRootRole
            && left.sourceRelativePath == right.sourceRelativePath
            && left.targetRootRole == right.targetRootRole
            && left.backup == right.backup
    }

    private func allowedTransition(
        from old: OperationJournalStatus,
        to new: OperationJournalStatus
    ) -> Bool {
        if old == new { return !old.isFinished }
        return switch (old, new) {
        case (.preparing, .executing),
             (.preparing, .failed),
             (.executing, .rollingBack),
             (.executing, .completed),
             (.executing, .failed),
             (.rollingBack, .rolledBack),
             (.rollingBack, .failed):
            true
        default:
            false
        }
    }

    private func allowedStepTransition(
        from old: OperationJournalStepStatus,
        to new: OperationJournalStepStatus
    ) -> Bool {
        if old == new { return true }
        return switch (old, new) {
        case (.pending, .executing),
             (.pending, .completed),
             (.pending, .failed),
             (.pending, .rolledBack),
             (.executing, .completed),
             (.executing, .failed),
             (.completed, .rolledBack),
             (.completed, .failed),
             (.failed, .rolledBack):
            true
        default:
            false
        }
    }

    private func incremented(
        _ journal: OperationJournal,
        updatedAt: Date,
        status: OperationJournalStatus? = nil,
        steps: [OperationJournalStep]? = nil,
        failure: OperationJournalFailure? = nil
    ) throws -> OperationJournal {
        guard updatedAt >= journal.updatedAt else {
            throw OperationJournalStoreError.invalidTimestamp
        }
        guard journal.revision < UInt64.max else {
            throw OperationJournalStoreError.revisionOverflow
        }
        return OperationJournal(
            id: journal.id,
            kind: journal.kind,
            createdAt: journal.createdAt,
            updatedAt: updatedAt,
            status: status ?? journal.status,
            roots: journal.roots,
            steps: steps ?? journal.steps,
            failure: status == nil ? journal.failure : failure,
            revision: journal.revision + 1
        )
    }

    private func requireRevision(
        _ expected: UInt64?,
        current: OperationJournal
    ) throws {
        guard let expected else { return }
        guard expected == current.revision else {
            throw OperationJournalStoreError.invalidRevision(
                expected: current.revision,
                found: expected
            )
        }
    }

    private func validateRootOverlaps(
        kind: OperationJournalKind,
        paths: [OperationJournalRootRole: String]
    ) throws {
        let pairs: [(OperationJournalRootRole, OperationJournalRootRole)]
        switch kind {
        case .sync:
            pairs = [(.left, .right), (.left, .backup), (.right, .backup)]
        case .merge:
            pairs = [
                (.base, .output), (.left, .output), (.right, .output),
                (.base, .backup), (.left, .backup), (.right, .backup),
                (.output, .backup)
            ]
        }

        for (first, second) in pairs {
            guard let firstPath = paths[first], let secondPath = paths[second] else { continue }
            if pathContains(firstPath, secondPath) || pathContains(secondPath, firstPath) {
                throw OperationJournalStoreError.overlappingRootPaths
            }
        }
    }

    private func pathContains(_ candidate: String, _ root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private func isSafeAbsolutePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= Self.maximumPathByteCount,
              path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("://") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first?.isEmpty == true,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return path == "/"
        }
        // The component checks above are deliberately lexical. Foundation may
        // rewrite an existing canonical `/private/tmp/...` path back through the
        // `/tmp` symlink during `standardizedFileURL`, which would reject the
        // no-symlink spelling required by descriptor-backed recovery.
        return true
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= Self.maximumPathByteCount,
              !path.hasPrefix("/"),
              !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private func pathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func parentPath(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .dropLast()
            .joined(separator: "/")
            .precomposedStringWithCanonicalMapping
    }

    private func isCaseOnlyMove(_ step: OperationJournalStep) -> Bool {
        guard step.actionKind == .move,
              let source = step.sourceRelativePath else { return false }
        return source.precomposedStringWithCanonicalMapping
            != step.relativePath.precomposedStringWithCanonicalMapping
            && pathKey(source) == pathKey(step.relativePath)
            && parentPath(of: source) == parentPath(of: step.relativePath)
    }

    private func journalComesBefore(_ left: OperationJournal, _ right: OperationJournal) -> Bool {
        if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
        return left.id.uuidString < right.id.uuidString
    }

    private func journalURL(
        for id: UUID,
        location: OperationJournalStorageLocation
    ) -> URL {
        let directory = location == .active ? directoryURL : archiveDirectoryURL
        return directory.appending(
            path: id.uuidString.lowercased() + Self.journalFileSuffix,
            directoryHint: .notDirectory
        )
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try ensureDirectory(directoryURL)
        let lockURL = directoryURL.appending(path: ".operation-journal.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw OperationJournalStoreError.ioFailure(.lock)
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw OperationJournalStoreError.ioFailure(.lock)
        }
        return try body()
    }

    private func ensureDirectory(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw OperationJournalStoreError.ioFailure(.createDirectory)
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw OperationJournalStoreError.ioFailure(.createDirectory)
            }
        } catch let error as OperationJournalStoreError {
            throw error
        } catch {
            throw OperationJournalStoreError.ioFailure(.createDirectory)
        }
    }
}

private struct OperationJournalSchemaHeader: Decodable {
    let schemaVersion: Int
}
