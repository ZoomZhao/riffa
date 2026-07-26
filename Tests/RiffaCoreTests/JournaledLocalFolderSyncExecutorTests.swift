import Foundation
import Testing
@testable import RiffaCore

@Suite("Journaled local folder synchronization")
struct JournaledLocalFolderSyncExecutorTests {
    @Test("Dry-run leaves neither user changes nor a journal directory")
    func dryRunHasNoJournalSideEffects() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source", path: "source.txt", root: fixture.left)
        let plan = FolderSyncPlan(mode: .updateRight, actions: [
            copy("source.txt", from: .left, to: .right)
        ])
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let result = try await JournaledLocalFolderSyncExecutor(journalStore: store).execute(
            plan: plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup
        )

        #expect(result.status == .dryRun)
        #expect(!fixture.exists("source.txt", root: fixture.right))
        #expect(!FileManager.default.fileExists(atPath: fixture.journals.path))
    }

    @Test("A complete plan is atomically defined before execution and records observations")
    func completedJournalContainsEveryPlanStep() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("new bytes", path: "new.txt", root: fixture.left)
        try fixture.write("same", path: "same.txt", root: fixture.left)
        try fixture.write("same", path: "same.txt", root: fixture.right)
        let plan = FolderSyncPlan(mode: .updateRight, actions: [
            copy("new.txt", from: .left, to: .right),
            noOp("same.txt")
        ])
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let result = try await JournaledLocalFolderSyncExecutor(journalStore: store).execute(
            plan: plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: false)
        )

        #expect(result.status == .completed)
        #expect(try fixture.read("new.txt", root: fixture.right) == "new bytes")
        let journals = try await store.listActive()
        #expect(journals.count == 1)
        let journal = try #require(journals.first)
        #expect(journal.status == .completed)
        #expect(journal.steps.count == plan.actions.count)
        #expect(journal.steps.map(\.actionKind) == [.copy, .omit])
        #expect(journal.steps.map(\.status) == [.completed, .completed])
        #expect(journal.steps[0].beforeState == .missing)
        #expect(journal.steps[0].afterState?.kind == .regularFile)
        #expect(journal.steps[0].afterState?.byteCount == 9)
        #expect(journal.steps[0].sourceBeforeState == nil)
        #expect(journal.steps[0].sourceAfterState == nil)
        #expect(journal.steps[1].beforeState?.kind == .regularFile)
        #expect(journal.steps[1].afterState?.kind == .regularFile)
        #expect(journal.steps[1].sourceBeforeState == nil)
        #expect(journal.steps[1].sourceAfterState == nil)
        #expect(journal.roots.map(\.role) == [.backup, .left, .right])
    }

    @Test("A committed move journals the target-side source and both terminal states")
    func committedMoveRecordsBothPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("renamed", path: "old.txt", root: fixture.right)
        let action = move("old.txt", to: "new.txt", on: .right)
        let plan = FolderSyncPlan(mode: .mirrorLeftToRight, actions: [action])
        let log = executionLog(
            mode: plan.mode,
            status: .completed,
            actions: [action],
            itemStatuses: [.completed]
        )
        let source = fixture.right.appending(path: "old.txt")
        let target = fixture.right.appending(path: "new.txt")
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledLocalFolderSyncExecutor(
            journalStore: store,
            testingExecutionLog: log,
            testingAfterExecution: {
                try FileManager.default.moveItem(at: source, to: target)
            }
        )

        let result = try await executor.execute(
            plan: plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: false, allowHighRisk: true)
        )

        #expect(result.status == .completed)
        let journal = try #require(try await store.listActive().first)
        let step = try #require(journal.steps.first)
        #expect(journal.status == .completed)
        #expect(step.actionKind == .move)
        #expect(step.sourceRootRole == .right)
        #expect(step.targetRootRole == .right)
        #expect(step.sourceRelativePath == "old.txt")
        #expect(step.relativePath == "new.txt")
        #expect(step.backup == nil)
        #expect(step.beforeState == .missing)
        #expect(step.sourceBeforeState?.kind == .regularFile)
        #expect(step.sourceBeforeState?.byteCount == 7)
        #expect(step.afterState?.kind == .regularFile)
        #expect(step.sourceAfterState == .missing)
    }

    @Test("A rolled-back move journals the restored source and missing target")
    func rolledBackMoveRecordsBothPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("original", path: "old.txt", root: fixture.right)
        let action = move("old.txt", to: "new.txt", on: .right)
        let plan = FolderSyncPlan(mode: .mirrorLeftToRight, actions: [action])
        let issue = LocalFolderSyncExecutionIssue(
            code: .executionFailed,
            actionIndex: 0,
            path: "new.txt",
            message: "Synthetic later failure"
        )
        let log = executionLog(
            mode: plan.mode,
            status: .failedRolledBack,
            actions: [action],
            itemStatuses: [.rolledBack],
            issues: [issue]
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let result = try await JournaledLocalFolderSyncExecutor(
            journalStore: store,
            testingExecutionLog: log
        ).execute(
            plan: plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: false, allowHighRisk: true)
        )

        #expect(result.status == .failedRolledBack)
        let journal = try #require(try await store.listActive().first)
        let step = try #require(journal.steps.first)
        #expect(journal.status == .rolledBack)
        #expect(step.status == .rolledBack)
        #expect(step.afterState == .missing)
        #expect(step.sourceAfterState?.kind == .regularFile)
    }

    @Test("A hostile move outcome is persisted as failed instead of rejecting the journal update")
    func hostileMoveOutcomeIsDowngraded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source", path: "old.txt", root: fixture.right)
        let action = move("old.txt", to: "new.txt", on: .right)
        let plan = FolderSyncPlan(mode: .mirrorLeftToRight, actions: [action])
        let log = executionLog(
            mode: plan.mode,
            status: .completed,
            actions: [action],
            itemStatuses: [.completed]
        )
        let source = fixture.right.appending(path: "old.txt")
        let target = fixture.right.appending(path: "new.txt")
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledLocalFolderSyncExecutor(
            journalStore: store,
            testingExecutionLog: log,
            testingAfterExecution: {
                try FileManager.default.removeItem(at: source)
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
            }
        )

        await #expect(throws: JournaledLocalFolderSyncError.inconsistentExecutionLog) {
            _ = try await executor.execute(
                plan: plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false, allowHighRisk: true)
            )
        }

        let journal = try #require(try await store.listActive().first)
        let step = try #require(journal.steps.first)
        #expect(journal.status == .failed)
        #expect(journal.failure?.code == .sourceChanged)
        #expect(step.status == .failed)
        #expect(step.failure?.code == .sourceChanged)
        #expect(step.afterState?.kind == .symbolicLink)
        #expect(step.sourceAfterState?.kind == .directory)
    }

    @Test("Cancellation after a committed move cannot interrupt terminal persistence")
    func cancellationAfterMovePersistsTerminalJournal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source", path: "old.txt", root: fixture.right)
        let action = move("old.txt", to: "new.txt", on: .right)
        let plan = FolderSyncPlan(mode: .mirrorLeftToRight, actions: [action])
        let log = executionLog(
            mode: plan.mode,
            status: .completed,
            actions: [action],
            itemStatuses: [.completed]
        )
        let source = fixture.right.appending(path: "old.txt")
        let target = fixture.right.appending(path: "new.txt")
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledLocalFolderSyncExecutor(
            journalStore: store,
            testingExecutionLog: log,
            testingAfterExecution: {
                try FileManager.default.moveItem(at: source, to: target)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        )

        let task = Task {
            try await executor.execute(
                plan: plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false, allowHighRisk: true)
            )
        }
        let result = try await task.value

        #expect(task.isCancelled)
        #expect(result.status == .completed)
        let journal = try #require(try await store.listActive().first)
        #expect(journal.status == .completed)
        #expect(journal.steps.first?.status == .completed)
        #expect(journal.steps.first?.sourceAfterState == .missing)
    }

    @Test("Unrepresentable move shapes fail before journal creation or file changes")
    func unsafeMoveDefinitionsFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source", path: "old.txt", root: fixture.right)
        try fixture.write("occupied", path: "occupied.txt", root: fixture.right)
        let actions = [
            move("old.txt", to: "OLD.txt", on: .right),
            move("old.txt", to: "new.txt", from: .right, toSide: .left),
            move("missing.txt", to: "new.txt", on: .right),
            move("old.txt", to: "occupied.txt", on: .right)
        ]
        let store = OperationJournalStore(directoryURL: fixture.journals)

        for action in actions {
            let plan = FolderSyncPlan(mode: .mirrorLeftToRight, actions: [action])
            let log = executionLog(
                mode: plan.mode,
                status: .completed,
                actions: [action],
                itemStatuses: [.completed]
            )
            let executor = JournaledLocalFolderSyncExecutor(
                journalStore: store,
                testingExecutionLog: log
            )
            do {
                _ = try await executor.execute(
                    plan: plan,
                    leftRoot: fixture.left,
                    rightRoot: fixture.right,
                    backupRoot: fixture.backup,
                    options: .init(dryRun: false, allowHighRisk: true)
                )
                Issue.record("An unsafe move definition was accepted")
            } catch let error as JournaledLocalFolderSyncError {
                #expect(error == .unrepresentableAction(index: 0))
            }
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.journals.path))
        #expect(try fixture.read("old.txt", root: fixture.right) == "source")
        #expect(try fixture.read("occupied.txt", root: fixture.right) == "occupied")
    }

    @Test("A failed transaction maps rollback and failure steps without splitting execution")
    func rolledBackExecutionIsRecorded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("new", path: "replace.txt", root: fixture.left)
        try fixture.write("old", path: "replace.txt", root: fixture.right)
        try fixture.write("later", path: "later.txt", root: fixture.left)
        let plan = FolderSyncPlan(mode: .updateRight, actions: [
            replace("replace.txt", from: .left, to: .right),
            copy("later.txt", from: .left, to: .right)
        ])
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledLocalFolderSyncExecutor(
            journalStore: store,
            testingExecutorFailureAtActionIndex: 1
        )
        let result = try await executor.execute(
            plan: plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: false)
        )

        #expect(result.status == .failedRolledBack)
        #expect(try fixture.read("replace.txt", root: fixture.right) == "old")
        #expect(!fixture.exists("later.txt", root: fixture.right))
        let journal = try #require(try await store.listActive().first)
        #expect(journal.status == .rolledBack)
        #expect(journal.failure?.code == .actionFailed)
        #expect(journal.steps.map(\.status) == [.rolledBack, .failed])
        #expect(journal.steps[0].beforeState?.byteCount == 3)
        #expect(journal.steps[0].afterState?.byteCount == 3)
        #expect(journal.steps[1].beforeState == .missing)
        #expect(journal.steps[1].afterState == .missing)
        #expect(journal.steps[1].failure?.code == .actionFailed)
    }

    @Test("Preflight refusal becomes a stable failed journal without touching the target")
    func refusedExecutionIsRecorded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("keep", path: "item.txt", root: fixture.right)
        let plan = FolderSyncPlan(mode: .mirrorLeftToRight, actions: [
            delete("item.txt", on: .right)
        ])
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let result = try await JournaledLocalFolderSyncExecutor(journalStore: store).execute(
            plan: plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: false, allowHighRisk: false)
        )

        #expect(result.status == .refused)
        #expect(try fixture.read("item.txt", root: fixture.right) == "keep")
        let journal = try #require(try await store.listActive().first)
        #expect(journal.status == .failed)
        #expect(journal.failure?.code == .invalidPlan)
        #expect(journal.steps[0].status == .failed)
        #expect(journal.steps[0].failure?.code == .invalidPlan)
        #expect(journal.steps[0].beforeState?.byteCount == 4)
        #expect(journal.steps[0].afterState?.byteCount == 4)
    }

    @Test("Incomplete rollback retains rolled-back and rollback-failed step states")
    func incompleteRollbackIsRecordedAsFailed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("first", path: "first.txt", root: fixture.left)
        try fixture.write("second", path: "second.txt", root: fixture.left)
        let actions = [
            copy("first.txt", from: .left, to: .right),
            copy("second.txt", from: .left, to: .right)
        ]
        let plan = FolderSyncPlan(mode: .updateRight, actions: actions)
        let rollbackIssue = LocalFolderSyncExecutionIssue(
            code: .rollbackFailed,
            actionIndex: 1,
            path: "second.txt",
            message: "Synthetic rollback failure"
        )
        let syntheticLog = LocalFolderSyncExecutionLog(
            mode: .updateRight,
            status: .failedRollbackIncomplete,
            dryRun: false,
            rollbackAttempted: true,
            rollbackSucceeded: false,
            itemResults: [
                LocalFolderSyncItemResult(
                    actionIndex: 0,
                    action: actions[0],
                    status: .rolledBack,
                    message: "Rolled back"
                ),
                LocalFolderSyncItemResult(
                    actionIndex: 1,
                    action: actions[1],
                    status: .rollbackFailed,
                    message: "Rollback failed"
                )
            ],
            issues: [rollbackIssue]
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledLocalFolderSyncExecutor(
            journalStore: store,
            testingExecutionLog: syntheticLog
        )

        let result = try await executor.execute(
            plan: plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: false)
        )

        #expect(result.status == .failedRollbackIncomplete)
        let journal = try #require(try await store.listActive().first)
        #expect(journal.status == .failed)
        #expect(journal.failure?.code == .rollbackFailed)
        #expect(journal.steps.map(\.status) == [.rolledBack, .failed])
        #expect(journal.steps[1].failure?.code == .rollbackFailed)
    }

    @Test("Journal creation failure closes before any user-file write")
    func creationFailureIsFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source", path: "source.txt", root: fixture.left)
        let plan = FolderSyncPlan(mode: .updateRight, actions: [
            copy("source.txt", from: .left, to: .right)
        ])
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledLocalFolderSyncExecutor(
            journalStore: store,
            testingFailurePoint: .beforeCreate
        )

        do {
            _ = try await executor.execute(
                plan: plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false)
            )
            Issue.record("A journal creation failure must throw")
        } catch let error as JournaledLocalFolderSyncError {
            guard case let .journalPersistenceFailed(stage, journalID, _) = error else {
                Issue.record("Unexpected journal error: \(error)")
                return
            }
            #expect(stage == .create)
            #expect(journalID == nil)
        }

        #expect(!fixture.exists("source.txt", root: fixture.right))
        #expect(!FileManager.default.fileExists(atPath: fixture.journals.path))
    }

    @Test("An unusable real journal location fails closed before execution")
    func unusableStoreIsFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source", path: "source.txt", root: fixture.left)
        let blockedStoreURL = fixture.root.appending(path: "blocked-journal-location")
        try Data("not a directory".utf8).write(to: blockedStoreURL)
        let plan = FolderSyncPlan(mode: .updateRight, actions: [
            copy("source.txt", from: .left, to: .right)
        ])
        let executor = JournaledLocalFolderSyncExecutor(
            journalStore: OperationJournalStore(directoryURL: blockedStoreURL)
        )

        do {
            _ = try await executor.execute(
                plan: plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false)
            )
            Issue.record("An unusable journal store must block execution")
        } catch let error as JournaledLocalFolderSyncError {
            guard case let .journalPersistenceFailed(stage, journalID, underlying) = error else {
                Issue.record("Unexpected journal error: \(error)")
                return
            }
            #expect(stage == .create)
            #expect(journalID == nil)
            #expect(underlying == .ioFailure(.createDirectory))
        }

        #expect(!fixture.exists("source.txt", root: fixture.right))
        #expect(try String(contentsOf: blockedStoreURL, encoding: .utf8) == "not a directory")
    }

    @Test("Failure to mark executing leaves a preparing journal and no user changes")
    func executingTransitionFailureIsScannable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source", path: "source.txt", root: fixture.left)
        let plan = FolderSyncPlan(mode: .updateRight, actions: [
            copy("source.txt", from: .left, to: .right)
        ])
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledLocalFolderSyncExecutor(
            journalStore: store,
            testingFailurePoint: .beforeMarkExecuting
        )

        await #expect(throws: JournaledLocalFolderSyncError.self) {
            _ = try await executor.execute(
                plan: plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false)
            )
        }
        #expect(!fixture.exists("source.txt", root: fixture.right))
        let unfinished = try await store.listUnfinished()
        #expect(unfinished.count == 1)
        #expect(unfinished.first?.status == .preparing)
        #expect(unfinished.first?.steps.count == plan.actions.count)
    }

    @Test("Cancellation after executing transition remains discoverable and performs no write")
    func cancellationLeavesUnfinishedJournal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source", path: "source.txt", root: fixture.left)
        let plan = FolderSyncPlan(mode: .updateRight, actions: [
            copy("source.txt", from: .left, to: .right)
        ])
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledLocalFolderSyncExecutor(
            journalStore: store,
            testingCancelAfterExecutingTransition: true
        )

        await #expect(throws: CancellationError.self) {
            _ = try await executor.execute(
                plan: plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false)
            )
        }
        #expect(!fixture.exists("source.txt", root: fixture.right))
        let unfinished = try await store.listUnfinished()
        #expect(unfinished.count == 1)
        #expect(unfinished.first?.status == .executing)
        #expect(unfinished.first?.steps.first?.status == .pending)
    }

    @Test("Terminal journal failure cannot be returned as a successful synchronization")
    func terminalFailureDoesNotMisreportSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source", path: "source.txt", root: fixture.left)
        let plan = FolderSyncPlan(mode: .updateRight, actions: [
            copy("source.txt", from: .left, to: .right)
        ])
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledLocalFolderSyncExecutor(
            journalStore: store,
            testingFailurePoint: .beforeTerminalTransition
        )

        do {
            _ = try await executor.execute(
                plan: plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false)
            )
            Issue.record("A terminal journal failure must not return the completed log")
        } catch let error as JournaledLocalFolderSyncError {
            guard case let .journalPersistenceFailed(stage, journalID, _) = error else {
                Issue.record("Unexpected journal error: \(error)")
                return
            }
            #expect(stage == .markTerminal)
            #expect(journalID != nil)
        }

        #expect(try fixture.read("source.txt", root: fixture.right) == "source")
        let unfinished = try await store.listUnfinished()
        #expect(unfinished.count == 1)
        #expect(unfinished.first?.status == .executing)
        #expect(unfinished.first?.steps.first?.status == .completed)
    }

    @Test("An inconsistent execution result fails safely and leaves recovery evidence")
    func inconsistentResultDoesNotTrapOrFinishJournal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("first", path: "first.txt", root: fixture.left)
        try fixture.write("second", path: "second.txt", root: fixture.left)
        let actions = [
            copy("first.txt", from: .left, to: .right),
            copy("second.txt", from: .left, to: .right)
        ]
        let plan = FolderSyncPlan(mode: .updateRight, actions: actions)
        let duplicatedIndexLog = LocalFolderSyncExecutionLog(
            mode: .updateRight,
            status: .completed,
            dryRun: false,
            rollbackAttempted: false,
            rollbackSucceeded: nil,
            itemResults: actions.map {
                LocalFolderSyncItemResult(
                    actionIndex: 0,
                    action: $0,
                    status: .completed,
                    message: "Synthetic result"
                )
            },
            issues: []
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledLocalFolderSyncExecutor(
            journalStore: store,
            testingExecutionLog: duplicatedIndexLog
        )

        await #expect(throws: JournaledLocalFolderSyncError.inconsistentExecutionLog) {
            _ = try await executor.execute(
                plan: plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false)
            )
        }
        let unfinished = try await store.listUnfinished()
        #expect(unfinished.count == 1)
        #expect(unfinished.first?.status == .executing)
        #expect(unfinished.first?.steps.allSatisfy { $0.status == .pending } == true)
    }

    @Test("Execution results must preserve the plan mode and exact action identity")
    func executionResultIdentityIsValidated() async throws {
        let modeFixture = try Fixture()
        defer { modeFixture.remove() }
        try modeFixture.write("source", path: "source.txt", root: modeFixture.left)
        let action = copy("source.txt", from: .left, to: .right)
        let plan = FolderSyncPlan(mode: .updateRight, actions: [action])
        let wrongModeLog = executionLog(
            mode: .updateLeft,
            status: .completed,
            actions: [action],
            itemStatuses: [.completed]
        )
        let modeStore = OperationJournalStore(directoryURL: modeFixture.journals)
        let modeExecutor = JournaledLocalFolderSyncExecutor(
            journalStore: modeStore,
            testingExecutionLog: wrongModeLog
        )

        await #expect(throws: JournaledLocalFolderSyncError.inconsistentExecutionLog) {
            _ = try await modeExecutor.execute(
                plan: plan,
                leftRoot: modeFixture.left,
                rightRoot: modeFixture.right,
                backupRoot: modeFixture.backup,
                options: .init(dryRun: false)
            )
        }
        #expect(try await modeStore.listUnfinished().first?.steps.first?.status == .pending)

        let actionFixture = try Fixture()
        defer { actionFixture.remove() }
        try actionFixture.write("source", path: "source.txt", root: actionFixture.left)
        let mismatchedAction = copy("other.txt", from: .left, to: .right)
        let wrongActionLog = executionLog(
            mode: plan.mode,
            status: .completed,
            actions: [mismatchedAction],
            itemStatuses: [.completed]
        )
        let actionStore = OperationJournalStore(directoryURL: actionFixture.journals)
        let actionExecutor = JournaledLocalFolderSyncExecutor(
            journalStore: actionStore,
            testingExecutionLog: wrongActionLog
        )

        await #expect(throws: JournaledLocalFolderSyncError.inconsistentExecutionLog) {
            _ = try await actionExecutor.execute(
                plan: plan,
                leftRoot: actionFixture.left,
                rightRoot: actionFixture.right,
                backupRoot: actionFixture.backup,
                options: .init(dryRun: false)
            )
        }
        #expect(try await actionStore.listUnfinished().first?.steps.first?.status == .pending)
    }

    private func copy(
        _ path: String,
        from source: FolderSyncSide,
        to target: FolderSyncSide
    ) -> FolderSyncAction {
        FolderSyncAction(
            kind: .copy,
            sourceSide: source,
            targetSide: target,
            sourceRelativePath: path,
            targetRelativePath: path,
            reason: .sourceOnly,
            risk: .low
        )
    }

    private func replace(
        _ path: String,
        from source: FolderSyncSide,
        to target: FolderSyncSide
    ) -> FolderSyncAction {
        FolderSyncAction(
            kind: .replace,
            sourceSide: source,
            targetSide: target,
            sourceRelativePath: path,
            targetRelativePath: path,
            reason: .contentDiffers,
            risk: .medium
        )
    }

    private func delete(_ path: String, on target: FolderSyncSide) -> FolderSyncAction {
        FolderSyncAction(
            kind: .delete,
            targetSide: target,
            targetRelativePath: path,
            reason: .mirrorRemovesTargetOnly,
            risk: .high
        )
    }

    private func noOp(_ path: String) -> FolderSyncAction {
        FolderSyncAction(
            kind: .noOp,
            sourceSide: .left,
            targetSide: .right,
            sourceRelativePath: path,
            targetRelativePath: path,
            reason: .alreadySame,
            risk: .none
        )
    }

    private func move(
        _ sourcePath: String,
        to targetPath: String,
        on side: FolderSyncSide
    ) -> FolderSyncAction {
        move(sourcePath, to: targetPath, from: side, toSide: side)
    }

    private func move(
        _ sourcePath: String,
        to targetPath: String,
        from sourceSide: FolderSyncSide,
        toSide targetSide: FolderSyncSide
    ) -> FolderSyncAction {
        FolderSyncAction(
            kind: .move,
            sourceSide: sourceSide,
            targetSide: targetSide,
            sourceRelativePath: sourcePath,
            targetRelativePath: targetPath,
            reason: .renameMatchMovedWithinTarget,
            risk: .high,
            moveProof: FolderSyncMoveProof(
                referenceSide: targetSide == .right ? .left : .right,
                referenceRelativePath: targetPath,
                expectedByteCount: 6,
                expectedSHA256Digest: String(repeating: "0", count: 64)
            )
        )
    }

    private func executionLog(
        mode: FolderSyncMode,
        status: LocalFolderSyncExecutionStatus,
        actions: [FolderSyncAction],
        itemStatuses: [LocalFolderSyncItemStatus],
        issues: [LocalFolderSyncExecutionIssue] = []
    ) -> LocalFolderSyncExecutionLog {
        let rollbackSucceeded: Bool?
        switch status {
        case .failedRolledBack:
            rollbackSucceeded = true
        case .failedRollbackIncomplete:
            rollbackSucceeded = false
        case .dryRun, .completed, .refused:
            rollbackSucceeded = nil
        }

        return LocalFolderSyncExecutionLog(
            mode: mode,
            status: status,
            dryRun: false,
            rollbackAttempted: status == .failedRolledBack
                || status == .failedRollbackIncomplete,
            rollbackSucceeded: rollbackSucceeded,
            itemResults: zip(actions, itemStatuses).enumerated().map { index, pair in
                LocalFolderSyncItemResult(
                    actionIndex: index,
                    action: pair.0,
                    status: pair.1,
                    message: "Synthetic result"
                )
            },
            issues: issues
        )
    }
}

private struct Fixture {
    let root: URL
    let left: URL
    let right: URL
    let backup: URL
    let journals: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "RiffaJournaledSyncTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        left = root.appending(path: "left", directoryHint: .isDirectory)
        right = root.appending(path: "right", directoryHint: .isDirectory)
        backup = root.appending(path: "backup", directoryHint: .isDirectory)
        journals = root.appending(path: "journals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    }

    func write(_ contents: String, path: String, root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    func read(_ path: String, root: URL) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    func exists(_ path: String, root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
