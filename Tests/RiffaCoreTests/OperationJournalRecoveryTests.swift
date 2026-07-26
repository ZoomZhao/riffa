import Darwin
import Foundation
import Testing
@testable import RiffaCore

@Suite("Operation journal recovery analysis")
struct OperationJournalRecoveryTests {
    @Test("A preparing journal is safely recognized as never executed")
    func preparingJournalIsRolledBack() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let target = fixture.right.appending(path: "kept.txt")
        try Data("original".utf8).write(to: target)
        let before = itemState(at: target)
        let step = OperationJournalStep(
            actionKind: .delete,
            relativePath: "kept.txt",
            targetRootRole: .right,
            beforeState: before
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let journal = try await store.create(fixture.journal(steps: [step]))

        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)

        #expect(plan.disposition == .canFinalizeRolledBack)
        #expect(plan.steps[0].classification == .safelyRolledBack)
        #expect(plan.steps[0].reason == .preparationNeverExecuted)
        #expect(plan.steps[0].target.result.state == before)

        let finalized = try await OperationJournalRecoveryFinalizer(journalStore: store)
            .finalize(journalID: journal.id, using: plan)
        #expect(finalized.status == .rolledBack)
        #expect(finalized.steps[0].status == .rolledBack)
        #expect(finalized.steps[0].afterState == before)
        #expect(try Data(contentsOf: target) == Data("original".utf8))
    }

    @Test("An interrupted move is classified from both paths without writing")
    func movePairDistinguishesCommitAndRollback() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let source = fixture.right.appending(path: "old.bin")
        let target = fixture.right.appending(path: "new.bin")
        try Data([1, 2, 3, 4]).write(to: source)
        let sourceBefore = itemState(at: source)
        let step = OperationJournalStep(
            actionKind: .move,
            relativePath: "new.bin",
            sourceRootRole: .right,
            sourceRelativePath: "old.bin",
            targetRootRole: .right,
            beforeState: .missing,
            sourceBeforeState: sourceBefore
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        var journal = try await store.create(fixture.journal(steps: [step]))
        journal = try await store.transition(journal.id, to: .executing)
        let analyzer = OperationJournalRecoveryAnalyzer(journalStore: store)

        let uncommitted = try await analyzer.planForUnfinishedJournal(journal.id)
        #expect(uncommitted.disposition == .canFinalizeRolledBack)
        #expect(uncommitted.steps[0].classification == .safelyRolledBack)
        #expect(uncommitted.steps[0].reason == .movePresentAtSource)

        try FileManager.default.moveItem(at: source, to: target)
        let committed = try await analyzer.planForUnfinishedJournal(journal.id)
        #expect(committed.disposition == .canFinalizeCompleted)
        #expect(committed.steps[0].classification == .safelyCompleted)
        #expect(committed.steps[0].reason == .movePresentAtDestination)
        #expect(committed.steps[0].source?.result.state == .missing)
        #expect(committed.steps[0].target.result.state == sourceBefore)
    }

    @Test("An interrupted case-only temporary stage is visible without persisting its hidden leaf")
    func caseOnlyTemporaryStageRequiresReview() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let source = fixture.right.appending(path: "Readme.bin")
        let hidden = fixture.right.appending(
            path: riffaCaseOnlyRenameTemporaryLeafPrefix + UUID().uuidString.lowercased()
        )
        try Data("payload".utf8).write(to: source)
        let sourceBefore = itemState(at: source)
        let step = OperationJournalStep(
            actionKind: .move,
            relativePath: "README.bin",
            sourceRootRole: .right,
            sourceRelativePath: "Readme.bin",
            targetRootRole: .right,
            beforeState: .missing,
            sourceBeforeState: sourceBefore
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        var journal = try await store.create(fixture.journal(steps: [step]))
        journal = try await store.transition(journal.id, to: .executing)
        try FileManager.default.moveItem(at: source, to: hidden)

        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)

        #expect(plan.disposition == .requiresUserDecision)
        #expect(plan.steps[0].classification == .requiresUserDecision)
        #expect(plan.steps[0].reason == .caseOnlyRenameInterruptedAtTemporaryName)
        #expect(plan.steps[0].source?.result.state == .missing)
        #expect(plan.steps[0].target.result.state == .missing)
        let journalData = try Data(contentsOf: fixture.journals.appending(
            path: journal.id.uuidString.lowercased() + OperationJournalStore.journalFileSuffix
        ))
        #expect(!String(decoding: journalData, as: UTF8.self).contains(hidden.lastPathComponent))
    }

    @Test("Two occupied move paths are an inconsistent scene")
    func moveConflictFailsClosed() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let source = fixture.right.appending(path: "old.bin")
        let target = fixture.right.appending(path: "new.bin")
        try Data("source".utf8).write(to: source)
        let sourceBefore = itemState(at: source)
        try Data("target".utf8).write(to: target)
        let step = OperationJournalStep(
            actionKind: .move,
            relativePath: "new.bin",
            sourceRootRole: .right,
            sourceRelativePath: "old.bin",
            targetRootRole: .right,
            beforeState: .missing,
            sourceBeforeState: sourceBefore
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        var journal = try await store.create(fixture.journal(steps: [step]))
        journal = try await store.transition(journal.id, to: .executing)

        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)

        #expect(plan.disposition == .inconsistentScene)
        #expect(plan.steps[0].classification == .inconsistentScene)
        #expect(plan.steps[0].reason == .moveSceneConflict)
    }

    @Test("Unpersisted copy content remains a manual decision")
    func copyDoesNotGuessFromLiveContent() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let source = fixture.left.appending(path: "copy.bin")
        let target = fixture.right.appending(path: "copy.bin")
        try Data("same bytes".utf8).write(to: source)
        try Data("same bytes".utf8).write(to: target)
        let step = OperationJournalStep(
            actionKind: .copy,
            relativePath: "copy.bin",
            sourceRootRole: .left,
            targetRootRole: .right,
            beforeState: .missing
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        var journal = try await store.create(fixture.journal(steps: [step]))
        journal = try await store.transition(journal.id, to: .executing)

        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)

        #expect(plan.disposition == .requiresUserDecision)
        #expect(plan.steps[0].classification == .requiresUserDecision)
        #expect(plan.steps[0].reason == .insufficientPersistedEvidence)
        #expect(plan.steps[0].source?.result.state?.kind == .regularFile)
    }

    @Test("Exact persisted step outcomes can be finalized")
    func persistedOutcomesAreRecognized() async throws {
        let completedFixture = try RecoveryFixture()
        defer { completedFixture.remove() }
        let completedTarget = completedFixture.right.appending(path: "created.bin")
        let completedStep = OperationJournalStep(
            actionKind: .copy,
            relativePath: "created.bin",
            sourceRootRole: .left,
            targetRootRole: .right,
            beforeState: .missing
        )
        let completedStore = OperationJournalStore(directoryURL: completedFixture.journals)
        var completedJournal = try await completedStore.create(
            completedFixture.journal(steps: [completedStep])
        )
        completedJournal = try await completedStore.transition(
            completedJournal.id,
            to: .executing
        )
        try Data("finished".utf8).write(to: completedTarget)
        let completedState = itemState(at: completedTarget)
        let recordedCompleted = replacing(
            completedStep,
            status: .completed,
            afterState: completedState
        )
        completedJournal = try await completedStore.updateStep(
            recordedCompleted,
            in: completedJournal.id
        )

        let completedPlan = try await OperationJournalRecoveryAnalyzer(
            journalStore: completedStore
        ).planForUnfinishedJournal(completedJournal.id)
        #expect(completedPlan.disposition == .canFinalizeCompleted)
        #expect(completedPlan.steps[0].reason == .recordedCompletedStateMatches)

        let rolledBackFixture = try RecoveryFixture()
        defer { rolledBackFixture.remove() }
        let rolledBackStep = OperationJournalStep(
            actionKind: .copy,
            relativePath: "absent.bin",
            sourceRootRole: .left,
            targetRootRole: .right,
            beforeState: .missing
        )
        let rolledBackStore = OperationJournalStore(directoryURL: rolledBackFixture.journals)
        var rolledBackJournal = try await rolledBackStore.create(
            rolledBackFixture.journal(steps: [rolledBackStep])
        )
        rolledBackJournal = try await rolledBackStore.transition(
            rolledBackJournal.id,
            to: .executing
        )
        let failure = OperationJournalFailure(code: .recoveryInterrupted, recordedAt: Date())
        rolledBackJournal = try await rolledBackStore.transition(
            rolledBackJournal.id,
            to: .rollingBack,
            failure: failure
        )
        rolledBackJournal = try await rolledBackStore.updateStep(
            replacing(rolledBackStep, status: .rolledBack, afterState: .missing),
            in: rolledBackJournal.id
        )

        let rolledBackPlan = try await OperationJournalRecoveryAnalyzer(
            journalStore: rolledBackStore
        ).planForUnfinishedJournal(rolledBackJournal.id)
        #expect(rolledBackPlan.disposition == .canFinalizeRolledBack)
        #expect(rolledBackPlan.steps[0].reason == .recordedRolledBackStateMatches)
    }

    @Test("A recorded outcome that no longer matches is inconsistent")
    func recordedOutcomeMismatchIsInconsistent() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let target = fixture.right.appending(path: "changed.bin")
        let step = OperationJournalStep(
            actionKind: .copy,
            relativePath: "changed.bin",
            sourceRootRole: .left,
            targetRootRole: .right,
            beforeState: .missing
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        var journal = try await store.create(fixture.journal(steps: [step]))
        journal = try await store.transition(journal.id, to: .executing)
        try Data("first".utf8).write(to: target)
        let recorded = itemState(at: target)
        journal = try await store.updateStep(
            replacing(step, status: .completed, afterState: recorded),
            in: journal.id
        )
        try Data("different length".utf8).write(to: target)

        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)

        #expect(plan.disposition == .inconsistentScene)
        #expect(plan.steps[0].reason == .recordedStateMismatch)
    }

    @Test("An intermediate symbolic link disables automatic recovery")
    func symbolicLinkTraversalIsRefused() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let step = OperationJournalStep(
            actionKind: .copy,
            relativePath: "nested/file.bin",
            sourceRootRole: .left,
            targetRootRole: .right,
            beforeState: .missing
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        var journal = try await store.create(fixture.journal(steps: [step]))
        journal = try await store.transition(journal.id, to: .executing)
        let outside = fixture.directory.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.right.appending(path: "nested"),
            withDestinationURL: outside
        )

        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)

        #expect(plan.disposition == .notAutomaticallyRecoverable)
        #expect(plan.steps[0].classification == .notAutomaticallyRecoverable)
        #expect(plan.steps[0].target.result == .unavailable(.symbolicLinkTraversal))
    }

    @Test("A missing root is unavailable rather than pretending every child is absent")
    func missingRootIsRefused() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let step = OperationJournalStep(
            actionKind: .copy,
            relativePath: "file.bin",
            sourceRootRole: .left,
            targetRootRole: .right,
            beforeState: .missing
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        var journal = try await store.create(fixture.journal(steps: [step]))
        journal = try await store.transition(journal.id, to: .executing)
        try FileManager.default.removeItem(at: fixture.right)

        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)

        #expect(plan.disposition == .notAutomaticallyRecoverable)
        #expect(plan.steps[0].target.result == .unavailable(.rootUnavailable))
    }

    @Test("An unavailable source refuses finalization even when the target is safely absent")
    func unavailableSourceIsRefused() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let step = OperationJournalStep(
            actionKind: .copy,
            relativePath: "file.bin",
            sourceRootRole: .left,
            targetRootRole: .right,
            beforeState: .missing
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let journal = try await store.create(fixture.journal(steps: [step]))
        try FileManager.default.removeItem(at: fixture.left)

        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)

        #expect(plan.steps[0].target.result.state == .missing)
        #expect(plan.steps[0].source?.result == .unavailable(.rootUnavailable))
        #expect(plan.steps[0].classification == .notAutomaticallyRecoverable)
        #expect(plan.disposition == .notAutomaticallyRecoverable)
        do {
            _ = try await OperationJournalRecoveryFinalizer(journalStore: store)
                .finalize(journalID: journal.id, using: plan)
            Issue.record("Expected unavailable recovery evidence to be rejected")
        } catch let error as OperationJournalRecoveryFinalizationError {
            #expect(
                error == .dispositionNotFinalizable(.notAutomaticallyRecoverable)
            )
        }
    }

    @Test("Backup state is reported but never treated as rollback proof")
    func backupIsObservationOnly() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let target = fixture.right.appending(path: "replace.bin")
        let backup = fixture.backup.appending(path: "right/replace.bin")
        try FileManager.default.createDirectory(
            at: backup.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: target)
        let before = itemState(at: target)
        let step = OperationJournalStep(
            actionKind: .replace,
            relativePath: "replace.bin",
            sourceRootRole: .left,
            targetRootRole: .right,
            backup: OperationJournalBackupMapping(backupRelativePath: "right/replace.bin"),
            beforeState: before
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        var journal = try await store.create(fixture.journal(steps: [step]))
        journal = try await store.transition(journal.id, to: .executing)
        try Data("old".utf8).write(to: backup)
        try Data("new value".utf8).write(to: target)

        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)

        #expect(plan.disposition == .requiresUserDecision)
        #expect(plan.steps[0].backup?.result.state?.kind == .regularFile)
        #expect(plan.steps[0].classification == .requiresUserDecision)
    }

    @Test("Only unfinished active journals are scanned and terminal IDs are rejected")
    func scanAndTerminalGuard() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let unfinished = try await store.create(fixture.journal())
        var finished = try await store.create(fixture.journal())
        finished = try await store.transition(finished.id, to: .executing)
        finished = try await store.transition(finished.id, to: .completed)
        let analyzer = OperationJournalRecoveryAnalyzer(journalStore: store)

        let plans = try await analyzer.plansForUnfinishedJournals()
        #expect(plans.map(\.journalID) == [unfinished.id])

        do {
            _ = try await analyzer.planForUnfinishedJournal(finished.id)
            Issue.record("Expected terminal recovery analysis to be rejected")
        } catch let error as OperationJournalRecoveryError {
            #expect(error == .journalAlreadyFinished(finished.id))
        }
    }

    @Test("A preparing empty journal is finalized in one metadata-only write")
    func preparingEmptyJournalFinalizesRolledBack() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let sentinel = fixture.left.appending(path: "sentinel.bin")
        let originalBytes = Data([0, 1, 2, 3, 255])
        try originalBytes.write(to: sentinel)
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let journal = try await store.create(fixture.journal())
        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)

        let finalized = try await OperationJournalRecoveryFinalizer(journalStore: store)
            .finalize(journalID: journal.id, using: plan)

        #expect(plan.disposition == .canFinalizeRolledBack)
        #expect(finalized.status == .rolledBack)
        #expect(finalized.revision == journal.revision + 1)
        #expect(finalized.steps.isEmpty)
        #expect(finalized.failure?.code == .recoveryInterrupted)
        #expect(try Data(contentsOf: sentinel) == originalBytes)

        do {
            _ = try await OperationJournalRecoveryFinalizer(journalStore: store)
                .finalize(journalID: journal.id, using: plan)
            Issue.record("Expected replay of a terminalized plan to be rejected")
        } catch let error as OperationJournalRecoveryFinalizationError {
            #expect(error == .journalAlreadyFinished(journal.id))
        }

        // The dedicated recovery API must not widen the ordinary transition API.
        let second = try await store.create(fixture.journal())
        do {
            _ = try await store.transition(
                second.id,
                to: .rolledBack,
                failure: OperationJournalFailure(
                    code: .recoveryInterrupted,
                    recordedAt: Date()
                )
            )
            Issue.record("Expected the normal state machine to reject preparing → rolledBack")
        } catch let error as OperationJournalStoreError {
            #expect(
                error == .invalidStatusTransition(from: .preparing, to: .rolledBack)
            )
        }
    }

    @Test("An interrupted ordinary step is finalized without replaying the delete")
    func ordinaryCompletionFinalizesMetadataOnly() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let target = fixture.right.appending(path: "deleted.bin")
        try Data("delete me".utf8).write(to: target)
        let step = OperationJournalStep(
            actionKind: .delete,
            relativePath: "deleted.bin",
            targetRootRole: .right,
            beforeState: itemState(at: target)
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        var journal = try await store.create(fixture.journal(steps: [step]))
        journal = try await store.transition(journal.id, to: .executing)
        try FileManager.default.removeItem(at: target)
        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)

        let finalized = try await OperationJournalRecoveryFinalizer(journalStore: store)
            .finalize(journalID: journal.id, using: plan)

        #expect(plan.disposition == .canFinalizeCompleted)
        #expect(finalized.status == .completed)
        #expect(finalized.failure == nil)
        #expect(finalized.steps[0].status == .completed)
        #expect(finalized.steps[0].afterState == .missing)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("An interrupted move records both observed endpoints without moving again")
    func moveCompletionFinalizesMetadataOnly() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let source = fixture.right.appending(path: "before.bin")
        let target = fixture.right.appending(path: "after.bin")
        let bytes = Data([9, 8, 7, 6, 5])
        try bytes.write(to: source)
        let sourceBefore = itemState(at: source)
        let step = OperationJournalStep(
            actionKind: .move,
            relativePath: "after.bin",
            sourceRootRole: .right,
            sourceRelativePath: "before.bin",
            targetRootRole: .right,
            beforeState: .missing,
            sourceBeforeState: sourceBefore
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        var journal = try await store.create(fixture.journal(steps: [step]))
        journal = try await store.transition(journal.id, to: .executing)
        try FileManager.default.moveItem(at: source, to: target)
        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)

        let finalized = try await OperationJournalRecoveryFinalizer(journalStore: store)
            .finalize(journalID: journal.id, using: plan)

        #expect(finalized.status == .completed)
        #expect(finalized.steps[0].status == .completed)
        #expect(finalized.steps[0].afterState == sourceBefore)
        #expect(finalized.steps[0].sourceAfterState == .missing)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test("A concurrent journal revision makes a visible plan stale")
    func concurrentRevisionIsRejected() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let journal = try await store.create(fixture.journal())
        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)
        let appended = try await store.appendStep(
            OperationJournalStep(
                actionKind: .copy,
                relativePath: "later.bin",
                sourceRootRole: .left,
                targetRootRole: .right,
                beforeState: .missing
            ),
            to: journal.id
        )

        do {
            _ = try await OperationJournalRecoveryFinalizer(journalStore: store)
                .finalize(journalID: journal.id, using: plan)
            Issue.record("Expected a stale recovery revision to be rejected")
        } catch let error as OperationJournalRecoveryFinalizationError {
            #expect(
                error == .journalRevisionChanged(
                    expected: plan.journalRevision,
                    found: appended.revision
                )
            )
        }
        let reloaded = try await store.load(journal.id)
        #expect(reloaded.status == .preparing)
        #expect(reloaded.revision == appended.revision)
    }

    @Test("A status change is rejected independently from the revision check")
    func concurrentStatusIsRejected() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let journal = try await store.create(fixture.journal())
        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)
        _ = try await store.transition(journal.id, to: .executing)

        do {
            _ = try await OperationJournalRecoveryFinalizer(journalStore: store)
                .finalize(journalID: journal.id, using: plan)
            Issue.record("Expected a changed journal status to be rejected")
        } catch let error as OperationJournalRecoveryFinalizationError {
            #expect(
                error == .journalStatusChanged(expected: .preparing, found: .executing)
            )
        }
    }

    @Test("A file-system scene change after inspection refuses finalization")
    func sceneChangeIsRejected() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let target = fixture.right.appending(path: "appeared.bin")
        let step = OperationJournalStep(
            actionKind: .copy,
            relativePath: "appeared.bin",
            sourceRootRole: .left,
            targetRootRole: .right,
            beforeState: .missing
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let journal = try await store.create(fixture.journal(steps: [step]))
        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)
        let unexpectedBytes = Data("external change".utf8)
        try unexpectedBytes.write(to: target)

        do {
            _ = try await OperationJournalRecoveryFinalizer(journalStore: store)
                .finalize(journalID: journal.id, using: plan)
            Issue.record("Expected changed recovery evidence to be rejected")
        } catch let error as OperationJournalRecoveryFinalizationError {
            #expect(error == .recoveryEvidenceChanged)
        }
        let reloaded = try await store.load(journal.id)
        #expect(reloaded.status == .preparing)
        #expect(reloaded.revision == plan.journalRevision)
        #expect(try Data(contentsOf: target) == unexpectedBytes)
    }

    @Test("Manual and inconsistent dispositions can never enter the finalizer")
    func unsafeDispositionIsRejected() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let target = fixture.right.appending(path: "copy.bin")
        try Data("unrecorded content".utf8).write(to: target)
        let step = OperationJournalStep(
            actionKind: .copy,
            relativePath: "copy.bin",
            sourceRootRole: .left,
            targetRootRole: .right,
            beforeState: .missing
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        var journal = try await store.create(fixture.journal(steps: [step]))
        journal = try await store.transition(journal.id, to: .executing)
        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(journal.id)

        do {
            _ = try await OperationJournalRecoveryFinalizer(journalStore: store)
                .finalize(journalID: journal.id, using: plan)
            Issue.record("Expected a manual disposition to be rejected")
        } catch let error as OperationJournalRecoveryFinalizationError {
            #expect(error == .dispositionNotFinalizable(.requiresUserDecision))
        }
        #expect(try Data(contentsOf: target) == Data("unrecorded content".utf8))
    }

    @Test("The selected journal ID must independently match the visible plan")
    func selectionIDMismatchIsRejected() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let first = try await store.create(fixture.journal())
        let second = try await store.create(fixture.journal())
        let plan = try await OperationJournalRecoveryAnalyzer(journalStore: store)
            .planForUnfinishedJournal(first.id)

        do {
            _ = try await OperationJournalRecoveryFinalizer(journalStore: store)
                .finalize(journalID: second.id, using: plan)
            Issue.record("Expected the independent journal ID check to fail")
        } catch let error as OperationJournalRecoveryFinalizationError {
            #expect(
                error == .journalIDChanged(expected: second.id, found: first.id)
            )
        }
    }

    private func replacing(
        _ step: OperationJournalStep,
        status: OperationJournalStepStatus,
        afterState: OperationJournalItemState
    ) -> OperationJournalStep {
        OperationJournalStep(
            id: step.id,
            actionKind: step.actionKind,
            relativePath: step.relativePath,
            sourceRootRole: step.sourceRootRole,
            sourceRelativePath: step.sourceRelativePath,
            targetRootRole: step.targetRootRole,
            backup: step.backup,
            status: status,
            beforeState: step.beforeState,
            afterState: afterState,
            sourceBeforeState: step.sourceBeforeState,
            sourceAfterState: step.sourceAfterState
        )
    }

    private func itemState(at url: URL) -> OperationJournalItemState {
        var information = stat()
        let result = url.path.withCString { Darwin.lstat($0, &information) }
        guard result == 0 else { return .missing }
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
        return OperationJournalItemState(
            kind: kind,
            byteCount: kind == .regularFile && information.st_size >= 0
                ? UInt64(information.st_size)
                : nil,
            modificationTimeNanoseconds: product.overflow || total.overflow
                ? nil
                : total.partialValue,
            permissions: UInt16(information.st_mode & 0o7777)
        )
    }
}

private struct RecoveryFixture {
    let directory: URL
    let left: URL
    let right: URL
    let backup: URL
    let journals: URL

    init() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let provisional = workspace.appending(path: ".build", directoryHint: .isDirectory).appending(
            path: "RiffaOperationRecoveryTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: provisional, withIntermediateDirectories: true)
        directory = provisional
        left = directory.appending(path: "left", directoryHint: .isDirectory)
        right = directory.appending(path: "right", directoryHint: .isDirectory)
        backup = directory.appending(path: "backup", directoryHint: .isDirectory)
        journals = directory.appending(path: "journals", directoryHint: .isDirectory)
        for root in [left, right, backup, journals] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    func journal(steps: [OperationJournalStep] = []) -> OperationJournal {
        let now = Date()
        return OperationJournal(
            kind: .sync,
            createdAt: now.addingTimeInterval(-1),
            roots: [
                OperationJournalRoot(role: .left, absolutePath: left.path),
                OperationJournalRoot(role: .right, absolutePath: right.path),
                OperationJournalRoot(role: .backup, absolutePath: backup.path)
            ],
            steps: steps
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
