import Darwin
import Foundation

/// A read-only conclusion about one interrupted journal step.
///
/// `safelyCompleted` and `safelyRolledBack` describe the scene that is present
/// now; they do not authorize a file-system mutation. Every other case refuses
/// automatic recovery.
public enum OperationJournalRecoveryStepClassification: String, Codable, Sendable {
    case safelyCompleted
    case safelyRolledBack
    case requiresUserDecision
    case inconsistentScene
    case notAutomaticallyRecoverable
}

/// Stable, path-free reasons behind a recovery classification.
public enum OperationJournalRecoveryReason: String, Codable, Sendable {
    case recordedCompletedStateMatches
    case recordedRolledBackStateMatches
    case preparationNeverExecuted
    case movePresentAtDestination
    case movePresentAtSource
    case preMutationAbsencePresent
    case destructivePostconditionPresent
    case creationPostconditionPresent
    case insufficientPersistedEvidence
    case ambiguousNoOp
    case failedStepRequiresReview
    case caseOnlyRenameInterruptedAtTemporaryName
    case recordedStateMismatch
    case moveSceneConflict
    case observationUnavailable
}

/// Failures from descriptor-based observation. No errno, local absolute path,
/// file content, or symbolic-link destination is exposed.
public enum OperationJournalRecoveryObservationFailure: String, Codable, Sendable {
    case invalidRelativePath
    case rootUnavailable
    case symbolicLinkTraversal
    case nonDirectoryAncestor
    case permissionDenied
    case concurrentModification
    case ioFailure
}

public enum OperationJournalRecoveryObservationResult: Hashable, Codable, Sendable {
    case observed(OperationJournalItemState)
    case unavailable(OperationJournalRecoveryObservationFailure)

    public var state: OperationJournalItemState? {
        guard case let .observed(state) = self else { return nil }
        return state
    }
}

/// One descriptor-safe observation, addressed only by a validated journal role
/// and relative path. The report deliberately does not repeat an absolute root.
public struct OperationJournalRecoveryItemObservation: Hashable, Codable, Sendable {
    public let rootRole: OperationJournalRootRole
    public let relativePath: String
    public let result: OperationJournalRecoveryObservationResult
}

public struct OperationJournalRecoveryStepAnalysis: Hashable, Codable, Sendable {
    public let stepID: UUID
    public let actionKind: OperationJournalActionKind
    public let recordedStatus: OperationJournalStepStatus
    public let classification: OperationJournalRecoveryStepClassification
    public let reason: OperationJournalRecoveryReason
    public let target: OperationJournalRecoveryItemObservation
    public let source: OperationJournalRecoveryItemObservation?
    public let backup: OperationJournalRecoveryItemObservation?
}

/// A recommendation about journal metadata only. The analyzer never applies it
/// and never writes to a journal or to a user root.
public enum OperationJournalRecoveryDisposition: String, Codable, Sendable {
    case canFinalizeCompleted
    case canFinalizeRolledBack
    case requiresUserDecision
    case inconsistentScene
    case notAutomaticallyRecoverable
}

public struct OperationJournalRecoveryPlan: Hashable, Codable, Sendable {
    public let journalID: UUID
    public let journalKind: OperationJournalKind
    public let journalStatus: OperationJournalStatus
    public let journalRevision: UInt64
    public let disposition: OperationJournalRecoveryDisposition
    public let steps: [OperationJournalRecoveryStepAnalysis]

    var allObservationsAreAvailable: Bool {
        steps.allSatisfy { step in
            step.target.result.state != nil
                && (step.source?.result.state != nil || step.source == nil)
                && (step.backup?.result.state != nil || step.backup == nil)
        }
    }
}

public enum OperationJournalRecoveryError: Error, Equatable, Sendable {
    case journalAlreadyFinished(UUID)
}

/// Fail-closed reasons why an inspected recovery plan was not finalized.
///
/// Finalization changes only the operation-journal JSON. It never authorizes a
/// copy, move, delete, restore, or any other mutation below a journal root.
public enum OperationJournalRecoveryFinalizationError: Error, Equatable, Sendable {
    case dispositionNotFinalizable(OperationJournalRecoveryDisposition)
    case journalIDChanged(expected: UUID, found: UUID)
    case journalAlreadyFinished(UUID)
    case journalKindChanged(expected: OperationJournalKind, found: OperationJournalKind)
    case journalStatusChanged(expected: OperationJournalStatus, found: OperationJournalStatus)
    case journalRevisionChanged(expected: UInt64, found: UInt64)
    case recoveryEvidenceUnavailable
    case recoveryEvidenceChanged
    case invalidRecoveryPlan
}

/// Converts a still-valid, unambiguous recovery assessment into terminal log
/// metadata. The store performs the decisive descriptor-safe observation again
/// under its process-wide journal lock immediately before its single atomic
/// replacement of the journal file.
public struct OperationJournalRecoveryFinalizer: Sendable {
    private let journalStore: OperationJournalStore

    public init(journalStore: OperationJournalStore) {
        self.journalStore = journalStore
    }

    public init(journalDirectoryURL: URL) {
        journalStore = OperationJournalStore(directoryURL: journalDirectoryURL)
    }

    /// `journalID` is supplied independently of the plan so a selection change
    /// cannot accidentally finalize a different visible record.
    @discardableResult
    public func finalize(
        journalID: UUID,
        using plan: OperationJournalRecoveryPlan,
        finalizedAt: Date = Date()
    ) async throws -> OperationJournal {
        guard journalID == plan.journalID else {
            throw OperationJournalRecoveryFinalizationError.journalIDChanged(
                expected: journalID,
                found: plan.journalID
            )
        }
        guard plan.disposition == .canFinalizeCompleted
                || plan.disposition == .canFinalizeRolledBack else {
            throw OperationJournalRecoveryFinalizationError.dispositionNotFinalizable(
                plan.disposition
            )
        }
        guard plan.allObservationsAreAvailable else {
            throw OperationJournalRecoveryFinalizationError.recoveryEvidenceUnavailable
        }
        return try await journalStore.finalizeRecoveryMetadata(
            journalID: journalID,
            using: plan,
            finalizedAt: finalizedAt
        )
    }
}

/// Produces fail-closed, read-only recovery plans for active operation journals.
///
/// Paths are resolved below descriptors opened with `O_NOFOLLOW_ANY`; each
/// intermediate component is opened with `openat(..., O_NOFOLLOW)`. A root or
/// parent that cannot be observed safely makes the corresponding step
/// non-automatic rather than falling back to path-based inspection.
public struct OperationJournalRecoveryAnalyzer: Sendable {
    private let journalStore: OperationJournalStore

    public init(journalStore: OperationJournalStore) {
        self.journalStore = journalStore
    }

    public init(journalDirectoryURL: URL) {
        journalStore = OperationJournalStore(directoryURL: journalDirectoryURL)
    }

    /// Loads every validated, unfinished journal from the active store. A bad
    /// journal entry fails the store scan closed through `OperationJournalStore`.
    public func plansForUnfinishedJournals() async throws -> [OperationJournalRecoveryPlan] {
        let journals = try await journalStore.listUnfinished()
        return journals.map(Self.makePlan)
    }

    /// Loads exactly one active journal and rejects terminal records, avoiding a
    /// stale recovery UI accidentally treating history as unfinished work.
    public func planForUnfinishedJournal(_ id: UUID) async throws -> OperationJournalRecoveryPlan {
        let journal = try await journalStore.load(id, from: .active)
        guard !journal.status.isFinished else {
            throw OperationJournalRecoveryError.journalAlreadyFinished(id)
        }
        return Self.makePlan(for: journal)
    }

    /// Synchronous so the journal store can repeat the complete descriptor-safe
    /// analysis while it owns the cross-process lock used for final persistence.
    static func makePlan(for journal: OperationJournal) -> OperationJournalRecoveryPlan {
        let roots = RecoveryRootCapabilities(journal.roots)
        let steps = journal.steps.map { step in
            Self.analyze(step, journalStatus: journal.status, roots: roots)
        }
        return OperationJournalRecoveryPlan(
            journalID: journal.id,
            journalKind: journal.kind,
            journalStatus: journal.status,
            journalRevision: journal.revision,
            disposition: Self.disposition(for: steps, journalStatus: journal.status),
            steps: steps
        )
    }

    private static func analyze(
        _ step: OperationJournalStep,
        journalStatus: OperationJournalStatus,
        roots: RecoveryRootCapabilities
    ) -> OperationJournalRecoveryStepAnalysis {
        let requiresExactLeafSpelling = Self.isCaseOnlyMove(step)
        let target = roots.observe(
            role: step.targetRootRole,
            relativePath: step.relativePath,
            requiresExactLeafSpelling: requiresExactLeafSpelling
        )
        let source: OperationJournalRecoveryItemObservation?
        if let sourceRootRole = step.sourceRootRole {
            source = roots.observe(
                role: sourceRootRole,
                relativePath: step.sourceRelativePath ?? step.relativePath,
                requiresExactLeafSpelling: requiresExactLeafSpelling
            )
        } else {
            source = nil
        }
        let backup = step.backup.map {
            roots.observe(
                role: $0.backupRootRole,
                relativePath: $0.backupRelativePath,
                requiresExactLeafSpelling: false
            )
        }

        let observationsAreAvailable = target.result.state != nil
            && (source?.result.state != nil || source == nil)
            && (backup?.result.state != nil || backup == nil)
        let conclusion: RecoveryConclusion
        if !observationsAreAvailable {
            conclusion = .notAutomatic(.observationUnavailable)
        } else if step.actionKind == .move {
            conclusion = Self.classifyMove(
                step,
                journalStatus: journalStatus,
                target: target.result,
                source: source?.result,
                isCaseOnly: requiresExactLeafSpelling
            )
        } else {
            conclusion = Self.classifyOrdinary(
                step,
                journalStatus: journalStatus,
                target: target.result
            )
        }

        return OperationJournalRecoveryStepAnalysis(
            stepID: step.id,
            actionKind: step.actionKind,
            recordedStatus: step.status,
            classification: conclusion.classification,
            reason: conclusion.reason,
            target: target,
            source: source,
            backup: backup
        )
    }

    private static func classifyOrdinary(
        _ step: OperationJournalStep,
        journalStatus: OperationJournalStatus,
        target: OperationJournalRecoveryObservationResult
    ) -> RecoveryConclusion {
        guard case let .observed(actual) = target else {
            return .notAutomatic(.observationUnavailable)
        }

        switch step.status {
        case .completed:
            guard let recorded = step.afterState, actual == recorded else {
                return .inconsistent(.recordedStateMismatch)
            }
            return .completed(.recordedCompletedStateMatches)

        case .rolledBack:
            guard let recorded = step.afterState, actual == recorded else {
                return .inconsistent(.recordedStateMismatch)
            }
            return .rolledBack(.recordedRolledBackStateMatches)

        case .failed:
            if let recorded = step.afterState, actual != recorded {
                return .inconsistent(.recordedStateMismatch)
            }
            return .manual(.failedStepRequiresReview)

        case .pending, .executing:
            break
        }

        guard let before = step.beforeState else {
            return .notAutomatic(.insufficientPersistedEvidence)
        }

        if journalStatus == .preparing {
            guard actual == before else {
                return .inconsistent(.recordedStateMismatch)
            }
            return .rolledBack(.preparationNeverExecuted)
        }

        if actual == before {
            // Absence is an exact state. Existing files and directories have no
            // persisted content identity in schema 2, so metadata equality alone
            // cannot prove that the original item is still present.
            if before == .missing {
                switch step.actionKind {
                case .copy, .createDirectory:
                    return .rolledBack(.preMutationAbsencePresent)
                case .delete, .omit:
                    return .manual(.ambiguousNoOp)
                case .replace, .move:
                    return .manual(.insufficientPersistedEvidence)
                }
            }
            return .manual(.insufficientPersistedEvidence)
        }

        switch step.actionKind {
        case .delete, .omit:
            if before.kind != .missing, actual == .missing {
                return .completed(.destructivePostconditionPresent)
            }
            return .manual(.insufficientPersistedEvidence)

        case .createDirectory:
            if before == .missing, actual.kind == .directory {
                return .completed(.creationPostconditionPresent)
            }
            return .manual(.insufficientPersistedEvidence)

        case .copy, .replace:
            // Source-before identity is not persisted for these actions. Even a
            // live source/target match could describe a source edited after the
            // crash, so completion is intentionally not inferred.
            return .manual(.insufficientPersistedEvidence)

        case .move:
            return .notAutomatic(.insufficientPersistedEvidence)
        }
    }

    private static func classifyMove(
        _ step: OperationJournalStep,
        journalStatus: OperationJournalStatus,
        target: OperationJournalRecoveryObservationResult,
        source: OperationJournalRecoveryObservationResult?,
        isCaseOnly: Bool
    ) -> RecoveryConclusion {
        guard case let .observed(actualTarget) = target,
              case let .observed(actualSource)? = source else {
            return .notAutomatic(.observationUnavailable)
        }

        switch step.status {
        case .completed:
            guard let recordedTarget = step.afterState,
                  let recordedSource = step.sourceAfterState,
                  actualTarget == recordedTarget,
                  actualSource == recordedSource else {
                return .inconsistent(.recordedStateMismatch)
            }
            return .completed(.recordedCompletedStateMatches)

        case .rolledBack:
            guard let recordedTarget = step.afterState,
                  let recordedSource = step.sourceAfterState,
                  actualTarget == recordedTarget,
                  actualSource == recordedSource else {
                return .inconsistent(.recordedStateMismatch)
            }
            return .rolledBack(.recordedRolledBackStateMatches)

        case .failed:
            if let recordedTarget = step.afterState,
               let recordedSource = step.sourceAfterState,
               (actualTarget != recordedTarget || actualSource != recordedSource) {
                return .inconsistent(.recordedStateMismatch)
            }
            return .manual(.failedStepRequiresReview)

        case .pending, .executing:
            break
        }

        guard step.beforeState == .missing,
              let sourceBefore = step.sourceBeforeState else {
            return .notAutomatic(.insufficientPersistedEvidence)
        }

        if actualTarget == .missing, actualSource == sourceBefore {
            return .rolledBack(
                journalStatus == .preparing ? .preparationNeverExecuted : .movePresentAtSource
            )
        }
        if journalStatus != .preparing,
           actualSource == .missing,
           actualTarget == sourceBefore {
            return .completed(.movePresentAtDestination)
        }
        if journalStatus != .preparing,
           isCaseOnly,
           actualSource == .missing,
           actualTarget == .missing {
            // The two-stage mover may have durably installed its unguessable
            // hidden leaf immediately before process termination. The exact
            // leaf is intentionally absent from the journal, so this scene is
            // reported for user review and is never metadata-finalized.
            return .manual(.caseOnlyRenameInterruptedAtTemporaryName)
        }
        return .inconsistent(.moveSceneConflict)
    }

    private static func isCaseOnlyMove(_ step: OperationJournalStep) -> Bool {
        guard step.actionKind == .move,
              let source = step.sourceRelativePath else { return false }
        let normalizedSource = source.precomposedStringWithCanonicalMapping
        let normalizedTarget = step.relativePath.precomposedStringWithCanonicalMapping
        guard normalizedSource != normalizedTarget else { return false }
        let locale = Locale(identifier: "en_US_POSIX")
        return normalizedSource.folding(options: [.caseInsensitive], locale: locale)
            == normalizedTarget.folding(options: [.caseInsensitive], locale: locale)
    }

    private static func disposition(
        for steps: [OperationJournalRecoveryStepAnalysis],
        journalStatus: OperationJournalStatus
    ) -> OperationJournalRecoveryDisposition {
        if steps.contains(where: { $0.classification == .notAutomaticallyRecoverable }) {
            return .notAutomaticallyRecoverable
        }
        if steps.contains(where: { $0.classification == .inconsistentScene }) {
            return .inconsistentScene
        }
        if steps.contains(where: { $0.classification == .requiresUserDecision }) {
            return .requiresUserDecision
        }

        let classifications = Set(steps.map(\.classification))
        if classifications.isEmpty || classifications == [.safelyRolledBack] {
            return .canFinalizeRolledBack
        }
        if classifications == [.safelyCompleted] {
            // A persisted rollback intent is never silently replaced by a
            // completion decision, even if every current step still looks done.
            return journalStatus == .rollingBack
                ? .requiresUserDecision
                : .canFinalizeCompleted
        }
        return .requiresUserDecision
    }
}

private struct RecoveryConclusion {
    let classification: OperationJournalRecoveryStepClassification
    let reason: OperationJournalRecoveryReason

    static func completed(_ reason: OperationJournalRecoveryReason) -> Self {
        Self(classification: .safelyCompleted, reason: reason)
    }

    static func rolledBack(_ reason: OperationJournalRecoveryReason) -> Self {
        Self(classification: .safelyRolledBack, reason: reason)
    }

    static func manual(_ reason: OperationJournalRecoveryReason) -> Self {
        Self(classification: .requiresUserDecision, reason: reason)
    }

    static func inconsistent(_ reason: OperationJournalRecoveryReason) -> Self {
        Self(classification: .inconsistentScene, reason: reason)
    }

    static func notAutomatic(_ reason: OperationJournalRecoveryReason) -> Self {
        Self(classification: .notAutomaticallyRecoverable, reason: reason)
    }
}

/// Keeps every successfully opened root descriptor alive for the complete
/// analysis so a root-name replacement cannot redirect later observations.
private final class RecoveryRootCapabilities {
    private let roots: [OperationJournalRootRole: RecoveryRootAccess]

    init(_ definitions: [OperationJournalRoot]) {
        roots = Dictionary(uniqueKeysWithValues: definitions.map { definition in
            (definition.role, Self.openRoot(definition.absolutePath))
        })
    }

    func observe(
        role: OperationJournalRootRole,
        relativePath: String,
        requiresExactLeafSpelling: Bool = false
    ) -> OperationJournalRecoveryItemObservation {
        let result: OperationJournalRecoveryObservationResult
        guard Self.isStrictRelativePath(relativePath) else {
            result = .unavailable(.invalidRelativePath)
            return OperationJournalRecoveryItemObservation(
                rootRole: role,
                relativePath: relativePath,
                result: result
            )
        }

        switch roots[role] {
        case let .directory(root):
            guard root.stillIdentifiesNamedRoot() else {
                result = .unavailable(.concurrentModification)
                break
            }
            let observed = Self.observe(
                relativePath,
                below: root.descriptor,
                requiresExactLeafSpelling: requiresExactLeafSpelling
            )
            result = root.stillIdentifiesNamedRoot()
                ? observed
                : .unavailable(.concurrentModification)
        case let .unavailable(failure):
            result = .unavailable(failure)
        case nil:
            result = .unavailable(.rootUnavailable)
        }
        return OperationJournalRecoveryItemObservation(
            rootRole: role,
            relativePath: relativePath,
            result: result
        )
    }

    private static func openRoot(_ absolutePath: String) -> RecoveryRootAccess {
        let descriptor = absolutePath.withCString { path in
            retrying { Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW_ANY) }
        }
        if descriptor >= 0 {
            var metadata = stat()
            guard retrying({ Darwin.fstat(descriptor, &metadata) }) == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                let code = errno == 0 ? ENOTDIR : errno
                _ = Darwin.close(descriptor)
                return .unavailable(observationFailure(for: code, openingDirectory: true))
            }
            return .directory(
                RecoveryRootDescriptor(
                    descriptor,
                    absolutePath: absolutePath,
                    metadata: metadata
                )
            )
        }

        let firstCode = errno
        if firstCode == ENOENT {
            // Confirm absence once more; a root appearing during the scan is a
            // concurrent scene, not an absent capability.
            let retry = absolutePath.withCString { path in
                retrying { Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW_ANY) }
            }
            if retry >= 0 {
                _ = Darwin.close(retry)
                return .unavailable(.concurrentModification)
            }
            return errno == ENOENT
                ? .unavailable(.rootUnavailable)
                : .unavailable(observationFailure(for: errno, openingDirectory: true))
        }
        return .unavailable(observationFailure(for: firstCode, openingDirectory: true))
    }

    private static func observe(
        _ relativePath: String,
        below root: Int32,
        requiresExactLeafSpelling: Bool
    ) -> OperationJournalRecoveryObservationResult {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard let leaf = components.last else {
            return .unavailable(.invalidRelativePath)
        }

        let rootCopy = ".".withCString { dot in
            retrying { Darwin.openat(root, dot, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW) }
        }
        guard rootCopy >= 0 else {
            return .unavailable(observationFailure(for: errno, openingDirectory: true))
        }
        var chain = [RecoveryOwnedDescriptor(rootCopy)]

        for component in components.dropLast() {
            let current = chain[chain.count - 1]
            let next = component.withCString { name in
                retrying {
                    Darwin.openat(
                        current.descriptor,
                        name,
                        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                    )
                }
            }
            if next >= 0 {
                chain.append(RecoveryOwnedDescriptor(next))
                continue
            }

            let firstCode = errno
            if firstCode == ELOOP || firstCode == ENOTDIR {
                var named = stat()
                let inspection = component.withCString {
                    Darwin.fstatat(current.descriptor, $0, &named, AT_SYMLINK_NOFOLLOW)
                }
                if inspection == 0,
                   named.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                    return .unavailable(.symbolicLinkTraversal)
                }
                if inspection == 0 {
                    return .unavailable(.nonDirectoryAncestor)
                }
            }
            if firstCode == ENOENT {
                let retry = component.withCString { name in
                    retrying {
                        Darwin.openat(
                            current.descriptor,
                            name,
                            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                        )
                    }
                }
                if retry >= 0 {
                    _ = Darwin.close(retry)
                    return .unavailable(.concurrentModification)
                }
                if errno == ENOENT {
                    return chainStillNamesOpenedDirectories(chain, components: components)
                        ? .observed(.missing)
                        : .unavailable(.concurrentModification)
                }
                return .unavailable(observationFailure(for: errno, openingDirectory: true))
            }
            return .unavailable(observationFailure(for: firstCode, openingDirectory: true))
        }

        let current = chain[chain.count - 1]
        let observedLeaf: String
        if requiresExactLeafSpelling {
            let beforeDirectory = RecoveryDirectoryVersion(descriptor: current.descriptor)
            let firstExact = exactDirectoryEntryName(
                parent: current.descriptor,
                requestedLeaf: leaf
            )
            let secondExact = exactDirectoryEntryName(
                parent: current.descriptor,
                requestedLeaf: leaf
            )
            let afterDirectory = RecoveryDirectoryVersion(descriptor: current.descriptor)
            guard let beforeDirectory,
                  let afterDirectory,
                  beforeDirectory == afterDirectory,
                  firstExact == secondExact else {
                return .unavailable(.concurrentModification)
            }
            switch firstExact {
            case let .found(actual):
                observedLeaf = actual
            case .missing:
                return chainStillNamesOpenedDirectories(chain, components: components)
                    ? .observed(.missing)
                    : .unavailable(.concurrentModification)
            case let .unavailable(failure):
                return .unavailable(failure)
            }
        } else {
            observedLeaf = leaf
        }
        var first = stat()
        let firstResult = observedLeaf.withCString {
            Darwin.fstatat(current.descriptor, $0, &first, AT_SYMLINK_NOFOLLOW)
        }
        let firstCode = errno
        var second = stat()
        let secondResult = observedLeaf.withCString {
            Darwin.fstatat(current.descriptor, $0, &second, AT_SYMLINK_NOFOLLOW)
        }
        let secondCode = errno

        if firstResult != 0 || secondResult != 0 {
            if firstResult != 0, secondResult != 0,
               firstCode == ENOENT, secondCode == ENOENT {
                return chainStillNamesOpenedDirectories(chain, components: components)
                    ? .observed(.missing)
                    : .unavailable(.concurrentModification)
            }
            if (firstResult != 0 && firstCode != ENOENT)
                || (secondResult != 0 && secondCode != ENOENT) {
                let code = firstResult != 0 && firstCode != ENOENT ? firstCode : secondCode
                return .unavailable(observationFailure(for: code, openingDirectory: false))
            }
            return .unavailable(.concurrentModification)
        }

        guard RecoveryFileVersion(first) == RecoveryFileVersion(second) else {
            return .unavailable(.concurrentModification)
        }
        guard chainStillNamesOpenedDirectories(chain, components: components) else {
            return .unavailable(.concurrentModification)
        }
        return .observed(itemState(first))
    }

    private static func exactDirectoryEntryName(
        parent: Int32,
        requestedLeaf: String
    ) -> RecoveryExactNameObservation {
        let duplicate = retrying { Darwin.dup(parent) }
        guard duplicate >= 0 else { return .unavailable(.ioFailure) }
        guard let directory = Darwin.fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            return .unavailable(.ioFailure)
        }
        defer { _ = Darwin.closedir(directory) }

        let requested = requestedLeaf.precomposedStringWithCanonicalMapping
        var match: String?
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: length + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard name.precomposedStringWithCanonicalMapping == requested else { continue }
            guard match == nil else { return .unavailable(.concurrentModification) }
            match = name
        }
        guard errno == 0 else { return .unavailable(.ioFailure) }
        return match.map(RecoveryExactNameObservation.found) ?? .missing
    }

    private static func chainStillNamesOpenedDirectories(
        _ chain: [RecoveryOwnedDescriptor],
        components: [String]
    ) -> Bool {
        for index in chain.indices.dropFirst().reversed() {
            var named = stat()
            let component = components[index - 1]
            let result = component.withCString {
                Darwin.fstatat(chain[index - 1].descriptor, $0, &named, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0,
                  RecoveryFileIdentity(named) == RecoveryFileIdentity(
                      descriptor: chain[index].descriptor
                  ) else {
                return false
            }
        }
        return true
    }

    private static func itemState(_ information: stat) -> OperationJournalItemState {
        let kind: OperationJournalItemState.Kind
        switch information.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): kind = .regularFile
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symbolicLink
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

    private static func isStrictRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\0") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func observationFailure(
        for code: Int32,
        openingDirectory: Bool
    ) -> OperationJournalRecoveryObservationFailure {
        switch code {
        case ELOOP:
            .symbolicLinkTraversal
        case ENOTDIR where openingDirectory:
            .nonDirectoryAncestor
        case EACCES, EPERM:
            .permissionDenied
        case ESTALE:
            .concurrentModification
        default:
            .ioFailure
        }
    }
}

private enum RecoveryRootAccess {
    case directory(RecoveryRootDescriptor)
    case unavailable(OperationJournalRecoveryObservationFailure)
}

private enum RecoveryExactNameObservation: Equatable {
    case found(String)
    case missing
    case unavailable(OperationJournalRecoveryObservationFailure)
}

private struct RecoveryDirectoryVersion: Equatable {
    let device: UInt64
    let inode: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    init?(descriptor: Int32) {
        var value = stat()
        guard retrying({ Darwin.fstat(descriptor, &value) }) == 0,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            return nil
        }
        device = UInt64(bitPattern: Int64(value.st_dev))
        inode = UInt64(value.st_ino)
        modificationSeconds = Int64(value.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(value.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

private final class RecoveryRootDescriptor {
    let descriptor: Int32
    private let absolutePath: String
    private let identity: RecoveryFileIdentity

    init(_ descriptor: Int32, absolutePath: String, metadata: stat) {
        self.descriptor = descriptor
        self.absolutePath = absolutePath
        identity = RecoveryFileIdentity(metadata)
    }

    func stillIdentifiesNamedRoot() -> Bool {
        let reopened = absolutePath.withCString { path in
            retrying { Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW_ANY) }
        }
        guard reopened >= 0 else { return false }
        defer { _ = Darwin.close(reopened) }
        return RecoveryFileIdentity(descriptor: reopened) == identity
    }

    deinit {
        _ = Darwin.close(descriptor)
    }
}

private final class RecoveryOwnedDescriptor {
    let descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = Darwin.close(descriptor)
    }
}

private struct RecoveryFileVersion: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int

    init(_ information: stat) {
        device = information.st_dev
        inode = information.st_ino
        mode = information.st_mode
        size = information.st_size
        modificationSeconds = information.st_mtimespec.tv_sec
        modificationNanoseconds = information.st_mtimespec.tv_nsec
        changeSeconds = information.st_ctimespec.tv_sec
        changeNanoseconds = information.st_ctimespec.tv_nsec
    }
}

private struct RecoveryFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let kind: mode_t

    init(_ information: stat) {
        device = information.st_dev
        inode = information.st_ino
        kind = information.st_mode & mode_t(S_IFMT)
    }

    init?(descriptor: Int32) {
        var information = stat()
        guard retrying({ Darwin.fstat(descriptor, &information) }) == 0 else { return nil }
        self.init(information)
    }
}

private func retrying(_ operation: () -> Int32) -> Int32 {
    while true {
        let result = operation()
        if result >= 0 || errno != EINTR { return result }
    }
}
