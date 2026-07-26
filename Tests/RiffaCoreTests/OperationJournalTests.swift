import Foundation
import Testing
@testable import RiffaCore

@Suite("Crash-recoverable operation journal")
struct OperationJournalTests {
    @Test("Versioned encoding is deterministic and contains only recovery metadata")
    func deterministicRoundTrip() async throws {
        let firstFixture = try JournalFixture()
        let secondFixture = try JournalFixture()
        defer {
            firstFixture.remove()
            secondFixture.remove()
        }
        let journal = syncJournal(
            id: uuid(1),
            rootsPrefix: "/private/tmp/Riffa-Journal-Deterministic"
        )
        let first = OperationJournalStore(directoryURL: firstFixture.storeURL)
        let second = OperationJournalStore(directoryURL: secondFixture.storeURL)

        let firstCreated = try await first.create(journal)
        let secondCreated = try await second.create(journal)
        let firstData = try Data(contentsOf: firstFixture.journalURL(journal.id))
        let secondData = try Data(contentsOf: secondFixture.journalURL(journal.id))
        let envelope = try JSONDecoder().decode(OperationJournalEnvelope.self, from: firstData)
        let encoded = String(decoding: firstData, as: UTF8.self)

        #expect(firstCreated == secondCreated)
        #expect(firstData == secondData)
        #expect(envelope.schemaVersion == OperationJournalEnvelope.currentSchemaVersion)
        #expect(envelope.journal == firstCreated)
        #expect(firstCreated.roots.map(\.role) == [.backup, .left, .right])
        #expect(!encoded.contains("contents"))
        #expect(!encoded.contains("localizedDescription"))
        #expect(!encoded.contains("password"))
        #expect(!encoded.contains("token"))
    }

    @Test("Schema 1 journals decode without source observations and upgrade on mutation")
    func schemaOneCompatibility() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let journal = syncJournal(
            id: uuid(2),
            steps: [validStep(id: uuid(3))]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let legacyData = try encoder.encode(
            OperationJournalEnvelope(schemaVersion: 1, journal: journal)
        )
        let legacyJSON = String(decoding: legacyData, as: UTF8.self)
        #expect(!legacyJSON.contains("sourceBeforeState"))
        #expect(!legacyJSON.contains("sourceAfterState"))
        try legacyData.write(to: fixture.journalURL(journal.id))

        let store = OperationJournalStore(directoryURL: fixture.storeURL)
        let loaded = try await store.load(journal.id)
        #expect(loaded.steps[0].sourceBeforeState == nil)
        #expect(loaded.steps[0].sourceAfterState == nil)

        _ = try await store.appendStep(
            validStep(id: uuid(4), path: "second.txt"),
            to: journal.id,
            updatedAt: journal.createdAt.addingTimeInterval(1)
        )
        let upgradedData = try Data(contentsOf: fixture.journalURL(journal.id))
        let upgraded = try JSONDecoder().decode(OperationJournalEnvelope.self, from: upgradedData)
        #expect(upgraded.schemaVersion == OperationJournalEnvelope.currentSchemaVersion)
        #expect(upgraded.schemaVersion == 2)
    }

    @Test("A same-root regular-file move records both source and target states")
    func validMoveLifecycle() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let timestamp = Date(timeIntervalSince1970: 1_500)
        let step = moveStep(id: uuid(5))
        let journal = syncJournal(id: uuid(6), createdAt: timestamp, steps: [step])
        let store = OperationJournalStore(directoryURL: fixture.storeURL)

        let created = try await store.create(journal)
        #expect(created.steps[0].actionKind == .move)
        #expect(created.steps[0].sourceRootRole == .right)
        #expect(created.steps[0].targetRootRole == .right)
        #expect(created.steps[0].beforeState == .missing)
        #expect(created.steps[0].sourceBeforeState?.kind == .regularFile)

        var current = try await store.transition(
            journal.id,
            to: .executing,
            updatedAt: timestamp.addingTimeInterval(1)
        )
        let executing = replacing(
            step,
            status: .executing,
            before: .missing
        )
        current = try await store.updateStep(
            executing,
            in: journal.id,
            expectedRevision: current.revision,
            updatedAt: timestamp.addingTimeInterval(2)
        )
        let completed = replacing(
            executing,
            status: .completed,
            before: .missing,
            after: regularFileState,
            sourceAfter: .missing
        )
        current = try await store.updateStep(
            completed,
            in: journal.id,
            expectedRevision: current.revision,
            updatedAt: timestamp.addingTimeInterval(3)
        )
        current = try await store.transition(
            journal.id,
            to: .completed,
            expectedRevision: current.revision,
            updatedAt: timestamp.addingTimeInterval(4)
        )

        #expect(current.steps[0].status == .completed)
        #expect(current.steps[0].afterState?.kind == .regularFile)
        #expect(current.steps[0].sourceAfterState == .missing)
    }

    @Test("Move definitions fail closed on unsafe roles, states, and backups")
    func invalidMoveDefinitions() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let store = OperationJournalStore(directoryURL: fixture.storeURL)

        let invalidSteps: [(OperationJournalStep, OperationJournalStoreError)] = [
            (
                moveStep(id: uuid(7), sourcePath: "same.txt", targetPath: "same.txt"),
                .invalidStepRoles(uuid(7))
            ),
            (
                moveStep(id: uuid(8), sourceRoot: .left, targetRoot: .right),
                .invalidStepRoles(uuid(8))
            ),
            (
                moveStep(id: uuid(9), sourceBefore: nil),
                .invalidStepState(uuid(9))
            ),
            (
                moveStep(id: uuid(10), targetBefore: regularFileState),
                .invalidStepState(uuid(10))
            ),
            (
                OperationJournalStep(
                    id: uuid(11),
                    actionKind: .move,
                    relativePath: "new.txt",
                    sourceRootRole: .right,
                    targetRootRole: .right,
                    beforeState: .missing,
                    sourceBeforeState: regularFileState
                ),
                .invalidStepRoles(uuid(11))
            ),
            (
                moveStep(
                    id: uuid(12),
                    backup: OperationJournalBackupMapping(backupRelativePath: "right/old.txt")
                ),
                .invalidStepRoles(uuid(12))
            ),
            (
                OperationJournalStep(
                    id: uuid(13),
                    actionKind: .copy,
                    relativePath: "copy.txt",
                    sourceRootRole: .right,
                    targetRootRole: .right
                ),
                .invalidStepRoles(uuid(13))
            ),
            (
                OperationJournalStep(
                    id: uuid(14),
                    actionKind: .copy,
                    relativePath: "copy.txt",
                    sourceRootRole: .left,
                    targetRootRole: .right,
                    sourceBeforeState: regularFileState
                ),
                .invalidStepState(uuid(14))
            )
        ]

        for (index, entry) in invalidSteps.enumerated() {
            let journal = syncJournal(id: uuid(100 + index), steps: [entry.0])
            do {
                _ = try await store.create(journal)
                Issue.record("Invalid move definition was accepted")
            } catch let error as OperationJournalStoreError {
                #expect(error == entry.1)
            }
        }
    }

    @Test("Move sources cannot be consumed twice or overlap any step target")
    func moveSourceConflicts() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let store = OperationJournalStore(directoryURL: fixture.storeURL)

        let duplicateSource = syncJournal(
            id: uuid(15),
            steps: [
                moveStep(id: uuid(16), sourcePath: "old.txt", targetPath: "new-a.txt"),
                moveStep(id: uuid(17), sourcePath: "OLD.txt", targetPath: "new-b.txt")
            ]
        )
        do {
            _ = try await store.create(duplicateSource)
            Issue.record("A move source must be consumed at most once")
        } catch let error as OperationJournalStoreError {
            #expect(error == .duplicateMoveSourcePath)
        }

        let sourceTargetConflict = syncJournal(
            id: uuid(18),
            steps: [
                validStep(id: uuid(19), path: "old.txt"),
                moveStep(id: uuid(22), sourcePath: "OLD.txt", targetPath: "new.txt")
            ]
        )
        do {
            _ = try await store.create(sourceTargetConflict)
            Issue.record("A move source must not be another step's target")
        } catch let error as OperationJournalStoreError {
            #expect(error == .moveSourceTargetConflict)
        }
    }

    @Test("Move terminal states distinguish commit, rollback, and incomplete failure")
    func moveTerminalStateValidation() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let store = OperationJournalStore(directoryURL: fixture.storeURL)
        let timestamp = Date(timeIntervalSince1970: 1_700)

        let rollbackStep = moveStep(id: uuid(23))
        let rollbackJournal = syncJournal(
            id: uuid(24),
            createdAt: timestamp,
            steps: [rollbackStep]
        )
        _ = try await store.create(rollbackJournal)
        var rollback = try await store.transition(
            rollbackJournal.id,
            to: .executing,
            updatedAt: timestamp.addingTimeInterval(1)
        )
        let committedStep = replacing(
            rollbackStep,
            status: .completed,
            before: .missing,
            after: regularFileState,
            sourceAfter: .missing
        )
        rollback = try await store.updateStep(
            committedStep,
            in: rollbackJournal.id,
            expectedRevision: rollback.revision,
            updatedAt: timestamp.addingTimeInterval(2)
        )
        let rollbackFailure = OperationJournalFailure(
            code: .actionFailed,
            recordedAt: timestamp.addingTimeInterval(3)
        )
        rollback = try await store.transition(
            rollbackJournal.id,
            to: .rollingBack,
            failure: rollbackFailure,
            expectedRevision: rollback.revision,
            updatedAt: rollbackFailure.recordedAt
        )
        let restoredStep = replacing(
            committedStep,
            status: .rolledBack,
            before: .missing,
            after: .missing,
            sourceAfter: regularFileState
        )
        rollback = try await store.updateStep(
            restoredStep,
            in: rollbackJournal.id,
            expectedRevision: rollback.revision,
            updatedAt: timestamp.addingTimeInterval(4)
        )
        rollback = try await store.transition(
            rollbackJournal.id,
            to: .rolledBack,
            failure: rollbackFailure,
            expectedRevision: rollback.revision,
            updatedAt: timestamp.addingTimeInterval(5)
        )
        #expect(rollback.steps[0].afterState == .missing)
        #expect(rollback.steps[0].sourceAfterState?.kind == .regularFile)

        let invalidStep = moveStep(id: uuid(25))
        let invalidJournal = syncJournal(
            id: uuid(26),
            createdAt: timestamp,
            steps: [invalidStep]
        )
        _ = try await store.create(invalidJournal)
        let invalidExecuting = try await store.transition(
            invalidJournal.id,
            to: .executing,
            updatedAt: timestamp.addingTimeInterval(1)
        )
        let invalidCompleted = replacing(
            invalidStep,
            status: .completed,
            before: .missing,
            after: .missing,
            sourceAfter: .missing
        )
        do {
            _ = try await store.updateStep(
                invalidCompleted,
                in: invalidJournal.id,
                expectedRevision: invalidExecuting.revision,
                updatedAt: timestamp.addingTimeInterval(2)
            )
            Issue.record("A completed move must leave exactly the target file")
        } catch let error as OperationJournalStoreError {
            #expect(error == .invalidStepState(invalidStep.id))
        }

        let failedStep = moveStep(id: uuid(27))
        let failedJournal = syncJournal(
            id: uuid(28),
            createdAt: timestamp,
            steps: [failedStep]
        )
        _ = try await store.create(failedJournal)
        let failedExecuting = try await store.transition(
            failedJournal.id,
            to: .executing,
            updatedAt: timestamp.addingTimeInterval(1)
        )
        let failure = OperationJournalFailure(
            code: .ioFailure,
            recordedAt: timestamp.addingTimeInterval(2)
        )
        let incompleteFailure = replacing(
            failedStep,
            status: .failed,
            before: .missing,
            after: regularFileState,
            failure: failure
        )
        do {
            _ = try await store.updateStep(
                incompleteFailure,
                in: failedJournal.id,
                expectedRevision: failedExecuting.revision,
                updatedAt: failure.recordedAt
            )
            Issue.record("A failed move must record both post-failure paths")
        } catch let error as OperationJournalStoreError {
            #expect(error == .invalidStepState(failedStep.id))
        }

        let hostileRaceFailure = replacing(
            failedStep,
            status: .failed,
            before: .missing,
            after: OperationJournalItemState(kind: .symbolicLink),
            sourceAfter: OperationJournalItemState(kind: .other),
            failure: failure
        )
        var failed = try await store.updateStep(
            hostileRaceFailure,
            in: failedJournal.id,
            expectedRevision: failedExecuting.revision,
            updatedAt: failure.recordedAt
        )
        failed = try await store.transition(
            failedJournal.id,
            to: .failed,
            failure: failure,
            expectedRevision: failed.revision,
            updatedAt: timestamp.addingTimeInterval(3)
        )
        #expect(failed.steps[0].afterState?.kind == .symbolicLink)
        #expect(failed.steps[0].sourceAfterState?.kind == .other)
    }

    @Test("Execution follows the journal and step state machines")
    func stateMachine() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let stepID = uuid(11)
        let step = OperationJournalStep(
            id: stepID,
            actionKind: .copy,
            relativePath: "folder/report.txt",
            sourceRootRole: .left,
            targetRootRole: .right,
            backup: OperationJournalBackupMapping(
                backupRelativePath: "right/folder/report.txt"
            )
        )
        let initial = syncJournal(id: uuid(10), createdAt: timestamp, steps: [step])
        let store = OperationJournalStore(directoryURL: fixture.storeURL)
        _ = try await store.create(initial)

        do {
            _ = try await store.transition(initial.id, to: .completed, updatedAt: timestamp)
            Issue.record("Preparing must not jump directly to completed")
        } catch let error as OperationJournalStoreError {
            #expect(error == .invalidStatusTransition(from: .preparing, to: .completed))
        }

        var current = try await store.transition(
            initial.id,
            to: .executing,
            expectedRevision: 0,
            updatedAt: timestamp.addingTimeInterval(1)
        )
        var executing = replacing(
            step,
            status: .executing,
            before: .missing
        )
        current = try await store.updateStep(
            executing,
            in: initial.id,
            expectedRevision: current.revision,
            updatedAt: timestamp.addingTimeInterval(2)
        )
        executing = replacing(
            executing,
            status: .completed,
            before: .missing,
            after: OperationJournalItemState(
                kind: .regularFile,
                byteCount: 42,
                modificationTimeNanoseconds: 123,
                permissions: 0o644
            )
        )
        current = try await store.updateStep(
            executing,
            in: initial.id,
            expectedRevision: current.revision,
            updatedAt: timestamp.addingTimeInterval(3)
        )
        current = try await store.transition(
            initial.id,
            to: .completed,
            expectedRevision: current.revision,
            updatedAt: timestamp.addingTimeInterval(4)
        )

        #expect(current.status == .completed)
        #expect(current.revision == 4)
        #expect(current.steps[0].beforeState == .missing)
        #expect(current.steps[0].afterState?.byteCount == 42)

        do {
            _ = try await store.transition(initial.id, to: .failed, updatedAt: timestamp.addingTimeInterval(5))
            Issue.record("Terminal journals must remain terminal")
        } catch let error as OperationJournalStoreError {
            #expect(error == .invalidStatusTransition(from: .completed, to: .failed))
        }
    }

    @Test("Rollback retains a stable sanitized failure code")
    func rollbackStateMachine() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let start = Date(timeIntervalSince1970: 2_000)
        let initialStep = OperationJournalStep(
            id: uuid(21),
            actionKind: .replace,
            relativePath: "item.bin",
            sourceRootRole: .left,
            targetRootRole: .right,
            backup: OperationJournalBackupMapping(backupRelativePath: "right/item.bin")
        )
        let initial = syncJournal(id: uuid(20), createdAt: start, steps: [initialStep])
        let store = OperationJournalStore(directoryURL: fixture.storeURL)
        _ = try await store.create(initial)
        _ = try await store.transition(initial.id, to: .executing, updatedAt: start.addingTimeInterval(1))

        let completedStep = replacing(
            initialStep,
            status: .completed,
            before: OperationJournalItemState(kind: .regularFile, byteCount: 9),
            after: OperationJournalItemState(kind: .regularFile, byteCount: 12)
        )
        _ = try await store.updateStep(
            completedStep,
            in: initial.id,
            updatedAt: start.addingTimeInterval(2)
        )
        let failure = OperationJournalFailure(
            code: .targetChanged,
            recordedAt: start.addingTimeInterval(3)
        )
        _ = try await store.transition(
            initial.id,
            to: .rollingBack,
            failure: failure,
            updatedAt: start.addingTimeInterval(3)
        )
        let rolledBackStep = replacing(
            completedStep,
            status: .rolledBack,
            before: completedStep.beforeState,
            after: completedStep.afterState
        )
        _ = try await store.updateStep(
            rolledBackStep,
            in: initial.id,
            updatedAt: start.addingTimeInterval(4)
        )
        let finished = try await store.transition(
            initial.id,
            to: .rolledBack,
            failure: failure,
            updatedAt: start.addingTimeInterval(5)
        )

        #expect(finished.status == .rolledBack)
        #expect(finished.failure?.code == .targetChanged)
        let data = try Data(contentsOf: fixture.journalURL(initial.id))
        #expect(String(decoding: data, as: UTF8.self).contains("targetChanged"))
    }

    @Test("Unsafe and duplicate paths are rejected without partial replacement")
    func pathSafetyAndDuplicates() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let store = OperationJournalStore(directoryURL: fixture.storeURL)
        let unsafe = syncJournal(
            id: uuid(30),
            roots: [
                OperationJournalRoot(role: .left, absolutePath: "/private/tmp/left/../escape"),
                OperationJournalRoot(role: .right, absolutePath: "/private/tmp/right"),
                OperationJournalRoot(role: .backup, absolutePath: "/private/tmp/backup")
            ]
        )
        do {
            _ = try await store.create(unsafe)
            Issue.record("An unstandardized root must be rejected")
        } catch let error as OperationJournalStoreError {
            #expect(error == .unsafeAbsolutePath(.left))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL(unsafe.id).path))

        let journal = syncJournal(id: uuid(31))
        _ = try await store.create(journal)
        let traversal = OperationJournalStep(
            id: uuid(32),
            actionKind: .copy,
            relativePath: "../outside",
            sourceRootRole: .left,
            targetRootRole: .right
        )
        do {
            _ = try await store.appendStep(traversal, to: journal.id)
            Issue.record("Traversal must be rejected")
        } catch let error as OperationJournalStoreError {
            #expect(error == .unsafeRelativePath(traversal.id))
        }

        let first = OperationJournalStep(
            id: uuid(33),
            actionKind: .copy,
            relativePath: "Folder/Readme",
            sourceRootRole: .left,
            targetRootRole: .right,
            backup: OperationJournalBackupMapping(backupRelativePath: "right/first")
        )
        _ = try await store.appendStep(first, to: journal.id)
        let duplicateTarget = OperationJournalStep(
            id: uuid(34),
            actionKind: .copy,
            relativePath: "folder/readme",
            sourceRootRole: .left,
            targetRootRole: .right,
            backup: OperationJournalBackupMapping(backupRelativePath: "right/second")
        )
        do {
            _ = try await store.appendStep(duplicateTarget, to: journal.id)
            Issue.record("Case-folded target duplicates must be rejected")
        } catch let error as OperationJournalStoreError {
            #expect(error == .duplicateTargetPath)
        }

        let duplicateBackup = OperationJournalStep(
            id: uuid(35),
            actionKind: .copy,
            relativePath: "unique.txt",
            sourceRootRole: .left,
            targetRootRole: .right,
            backup: OperationJournalBackupMapping(backupRelativePath: "RIGHT/FIRST")
        )
        do {
            _ = try await store.appendStep(duplicateBackup, to: journal.id)
            Issue.record("Backup destinations must be unique")
        } catch let error as OperationJournalStoreError {
            #expect(error == .duplicateBackupPath)
        }

        let loaded = try await store.load(journal.id)
        #expect(loaded.steps.map(\.id) == [first.id])
        #expect(loaded.revision == 1)
    }

    @Test("Corrupted, old, and future schemas fail closed")
    func corruptedAndSchemaProtection() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let store = OperationJournalStore(directoryURL: fixture.storeURL)

        let corruptID = uuid(40)
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: fixture.journalURL(corruptID))
        do {
            _ = try await store.appendStep(validStep(id: uuid(41)), to: corruptID)
            Issue.record("Corrupted data must block mutation")
        } catch let error as OperationJournalStoreError {
            #expect(error == .corruptedJSON(corruptID))
        }
        #expect(try Data(contentsOf: fixture.journalURL(corruptID)) == corrupt)

        let oldID = uuid(42)
        let old = Data("{\"schemaVersion\":0,\"journal\":{}}".utf8)
        try old.write(to: fixture.journalURL(oldID))
        do {
            _ = try await store.load(oldID)
            Issue.record("Old schemas require an explicit migration")
        } catch let error as OperationJournalStoreError {
            #expect(error == .migrationRequired(found: 0, current: 2))
        }
        #expect(try Data(contentsOf: fixture.journalURL(oldID)) == old)

        let futureID = uuid(43)
        let future = Data("{\"schemaVersion\":99,\"journal\":{}}".utf8)
        try future.write(to: fixture.journalURL(futureID))
        do {
            _ = try await store.load(futureID)
            Issue.record("Future schemas must be rejected")
        } catch let error as OperationJournalStoreError {
            #expect(error == .futureSchemaVersion(found: 99, supported: 2))
        }
        #expect(try Data(contentsOf: fixture.journalURL(futureID)) == future)
    }

    @Test("Separate store actors serialize concurrent appends without lost steps")
    func concurrentUpdates() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let firstStore = OperationJournalStore(directoryURL: fixture.storeURL)
        let secondStore = OperationJournalStore(directoryURL: fixture.storeURL)
        let initial = mergeJournal(id: uuid(50))
        _ = try await firstStore.create(initial)
        let timestamp = initial.createdAt.addingTimeInterval(1)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                let store = index.isMultiple(of: 2) ? firstStore : secondStore
                let step = OperationJournalStep(
                    id: uuid(1_000 + index),
                    actionKind: .copy,
                    relativePath: String(format: "items/%02d.txt", index),
                    sourceRootRole: .left,
                    targetRootRole: .output
                )
                group.addTask {
                    _ = try await store.appendStep(step, to: initial.id, updatedAt: timestamp)
                }
            }
            try await group.waitForAll()
        }

        let loaded = try await firstStore.load(initial.id)
        #expect(loaded.steps.count == 40)
        #expect(Set(loaded.steps.map(\.id)).count == 40)
        #expect(loaded.revision == 40)
    }

    @Test("Unfinished scan is sorted and excludes every terminal status")
    func unfinishedScan() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let store = OperationJournalStore(directoryURL: fixture.storeURL)
        let base = Date(timeIntervalSince1970: 5_000)
        let preparing = syncJournal(id: uuid(60), createdAt: base)
        let executing = syncJournal(id: uuid(61), createdAt: base.addingTimeInterval(1))
        let rollingBack = syncJournal(id: uuid(62), createdAt: base.addingTimeInterval(2))
        let completed = syncJournal(id: uuid(63), createdAt: base.addingTimeInterval(3))
        let failed = syncJournal(id: uuid(64), createdAt: base.addingTimeInterval(4))
        for journal in [failed, completed, rollingBack, executing, preparing] {
            _ = try await store.create(journal)
        }

        _ = try await store.transition(
            executing.id,
            to: .executing,
            updatedAt: executing.createdAt.addingTimeInterval(1)
        )
        _ = try await store.transition(
            rollingBack.id,
            to: .executing,
            updatedAt: rollingBack.createdAt.addingTimeInterval(1)
        )
        let rollbackFailure = OperationJournalFailure(
            code: .actionFailed,
            recordedAt: rollingBack.createdAt.addingTimeInterval(2)
        )
        _ = try await store.transition(
            rollingBack.id,
            to: .rollingBack,
            failure: rollbackFailure,
            updatedAt: rollbackFailure.recordedAt
        )
        _ = try await store.transition(
            completed.id,
            to: .executing,
            updatedAt: completed.createdAt.addingTimeInterval(1)
        )
        _ = try await store.transition(
            completed.id,
            to: .completed,
            updatedAt: completed.createdAt.addingTimeInterval(2)
        )
        let terminalFailure = OperationJournalFailure(
            code: .invalidPlan,
            recordedAt: failed.createdAt.addingTimeInterval(1)
        )
        _ = try await store.transition(
            failed.id,
            to: .failed,
            failure: terminalFailure,
            updatedAt: terminalFailure.recordedAt
        )

        let unfinished = try await store.listUnfinished()
        #expect(unfinished.map(\.id) == [preparing.id, executing.id, rollingBack.id])
        #expect(unfinished.map(\.status) == [.preparing, .executing, .rollingBack])
    }

    @Test("Archive and cleanup remove journal files only")
    func archiveAndCleanupScope() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let rootsPrefix = fixture.directoryURL.appending(path: "user-resources").path
        let markerURL = URL(fileURLWithPath: rootsPrefix)
            .appending(path: "left/keep.txt")
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("user data".utf8).write(to: markerURL)

        let journal = syncJournal(id: uuid(70), rootsPrefix: rootsPrefix)
        let store = OperationJournalStore(directoryURL: fixture.storeURL)
        _ = try await store.create(journal)
        _ = try await store.transition(
            journal.id,
            to: .executing,
            updatedAt: journal.createdAt.addingTimeInterval(1)
        )
        _ = try await store.transition(
            journal.id,
            to: .completed,
            updatedAt: journal.createdAt.addingTimeInterval(2)
        )
        let archiveURL = try await store.archiveFinished(journal.id)

        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL(journal.id).path))
        #expect(FileManager.default.fileExists(atPath: archiveURL.path))
        #expect(try String(contentsOf: markerURL, encoding: .utf8) == "user data")
        #expect(try await store.load(journal.id, from: .archive).status == .completed)

        try await store.removeFinished(journal.id, from: .archive)
        #expect(!FileManager.default.fileExists(atPath: archiveURL.path))
        #expect(try String(contentsOf: markerURL, encoding: .utf8) == "user data")
    }

    @Test("Archived scan is empty before first archive and remains stably sorted")
    func archivedScanMissingAndSorted() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let store = OperationJournalStore(directoryURL: fixture.storeURL)

        #expect(!FileManager.default.fileExists(atPath: fixture.archiveURL.path))
        #expect(try await store.listArchived().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveURL.path))

        let base = Date(timeIntervalSince1970: 8_000)
        let later = syncJournal(id: uuid(73), createdAt: base.addingTimeInterval(10))
        let sameTimeHigherID = syncJournal(id: uuid(72), createdAt: base)
        let sameTimeLowerID = syncJournal(id: uuid(71), createdAt: base)

        for journal in [later, sameTimeHigherID, sameTimeLowerID] {
            _ = try await store.create(journal)
            _ = try await store.transition(
                journal.id,
                to: .executing,
                updatedAt: journal.createdAt.addingTimeInterval(1)
            )
            _ = try await store.transition(
                journal.id,
                to: .completed,
                updatedAt: journal.createdAt.addingTimeInterval(2)
            )
        }
        for journal in [sameTimeHigherID, later, sameTimeLowerID] {
            _ = try await store.archiveFinished(journal.id)
        }

        let firstScan = try await store.listArchived()
        let secondScan = try await store.listArchived()
        #expect(firstScan.map(\.id) == [sameTimeLowerID.id, sameTimeHigherID.id, later.id])
        #expect(secondScan.map(\.id) == firstScan.map(\.id))
        #expect(try await store.listActive().isEmpty)
    }

    @Test("Archived scan fails closed for malformed journal files")
    func archivedScanValidatesEveryJournal() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.archiveURL,
            withIntermediateDirectories: true
        )
        let corruptID = uuid(74)
        try Data("not a journal".utf8).write(
            to: fixture.archivedJournalURL(corruptID)
        )
        let store = OperationJournalStore(directoryURL: fixture.storeURL)

        do {
            _ = try await store.listArchived()
            Issue.record("A malformed archived journal must fail the complete scan")
        } catch let error as OperationJournalStoreError {
            #expect(error == .corruptedJSON(corruptID))
        }
    }

    @Test("Archived scan never follows directory or journal symbolic links")
    func archivedScanRejectsSymbolicLinks() async throws {
        let directoryFixture = try JournalFixture()
        defer { directoryFixture.remove() }
        let redirectedDirectory = directoryFixture.directoryURL.appending(
            path: "redirected-archive",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: redirectedDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: directoryFixture.archiveURL,
            withDestinationURL: redirectedDirectory
        )
        let directoryStore = OperationJournalStore(directoryURL: directoryFixture.storeURL)

        do {
            _ = try await directoryStore.listArchived()
            Issue.record("The archive directory itself must not be followed")
        } catch let error as OperationJournalStoreError {
            #expect(error == .ioFailure(.list))
        }

        let fileFixture = try JournalFixture()
        defer { fileFixture.remove() }
        let fileStore = OperationJournalStore(directoryURL: fileFixture.storeURL)
        let journal = syncJournal(id: uuid(75))
        _ = try await fileStore.create(journal)
        try FileManager.default.createDirectory(
            at: fileFixture.archiveURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fileFixture.archivedJournalURL(journal.id),
            withDestinationURL: fileFixture.journalURL(journal.id)
        )

        do {
            _ = try await fileStore.listArchived()
            Issue.record("An archived journal link must not be followed")
        } catch let error as OperationJournalStoreError {
            #expect(error == .corruptedJSON(journal.id))
        }
    }

    @Test("Optimistic revisions reject stale callers without overwriting newer work")
    func revisionConflict() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let store = OperationJournalStore(directoryURL: fixture.storeURL)
        let journal = syncJournal(id: uuid(80))
        _ = try await store.create(journal)
        _ = try await store.appendStep(validStep(id: uuid(81)), to: journal.id, expectedRevision: 0)

        do {
            _ = try await store.appendStep(
                validStep(id: uuid(82), path: "second.txt"),
                to: journal.id,
                expectedRevision: 0
            )
            Issue.record("A stale revision must not overwrite the first append")
        } catch let error as OperationJournalStoreError {
            #expect(error == .invalidRevision(expected: 1, found: 0))
        }

        let loaded = try await store.load(journal.id)
        #expect(loaded.steps.map(\.id) == [uuid(81)])
        #expect(loaded.revision == 1)
    }

    private func syncJournal(
        id: UUID,
        createdAt: Date = Date(timeIntervalSince1970: 100),
        rootsPrefix: String = "/private/tmp/Riffa-Journal-Tests",
        roots: [OperationJournalRoot]? = nil,
        steps: [OperationJournalStep] = []
    ) -> OperationJournal {
        OperationJournal(
            id: id,
            kind: .sync,
            createdAt: createdAt,
            roots: roots ?? [
                OperationJournalRoot(role: .right, absolutePath: rootsPrefix + "/right"),
                OperationJournalRoot(role: .backup, absolutePath: rootsPrefix + "/backup"),
                OperationJournalRoot(role: .left, absolutePath: rootsPrefix + "/left")
            ],
            steps: steps
        )
    }

    private func mergeJournal(id: UUID) -> OperationJournal {
        let prefix = "/private/tmp/Riffa-Merge-Journal-Tests"
        return OperationJournal(
            id: id,
            kind: .merge,
            createdAt: Date(timeIntervalSince1970: 100),
            roots: [
                OperationJournalRoot(role: .base, absolutePath: prefix + "/base"),
                OperationJournalRoot(role: .left, absolutePath: prefix + "/left"),
                OperationJournalRoot(role: .right, absolutePath: prefix + "/right"),
                OperationJournalRoot(role: .output, absolutePath: prefix + "/output"),
                OperationJournalRoot(role: .backup, absolutePath: prefix + "/backup")
            ]
        )
    }

    private func validStep(
        id: UUID,
        path: String = "first.txt"
    ) -> OperationJournalStep {
        OperationJournalStep(
            id: id,
            actionKind: .copy,
            relativePath: path,
            sourceRootRole: .left,
            targetRootRole: .right
        )
    }

    private var regularFileState: OperationJournalItemState {
        OperationJournalItemState(
            kind: .regularFile,
            byteCount: 42,
            modificationTimeNanoseconds: 123,
            permissions: 0o644
        )
    }

    private func moveStep(
        id: UUID,
        sourcePath: String = "old.txt",
        targetPath: String = "new.txt",
        sourceRoot: OperationJournalRootRole = .right,
        targetRoot: OperationJournalRootRole = .right,
        targetBefore: OperationJournalItemState? = .missing,
        sourceBefore: OperationJournalItemState? = OperationJournalItemState(
            kind: .regularFile,
            byteCount: 42
        ),
        backup: OperationJournalBackupMapping? = nil
    ) -> OperationJournalStep {
        OperationJournalStep(
            id: id,
            actionKind: .move,
            relativePath: targetPath,
            sourceRootRole: sourceRoot,
            sourceRelativePath: sourcePath,
            targetRootRole: targetRoot,
            backup: backup,
            beforeState: targetBefore,
            sourceBeforeState: sourceBefore
        )
    }

    private func replacing(
        _ step: OperationJournalStep,
        status: OperationJournalStepStatus,
        before: OperationJournalItemState?,
        after: OperationJournalItemState? = nil,
        sourceBefore: OperationJournalItemState? = nil,
        sourceAfter: OperationJournalItemState? = nil,
        failure: OperationJournalFailure? = nil
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
            beforeState: before,
            afterState: after,
            sourceBeforeState: sourceBefore ?? step.sourceBeforeState,
            sourceAfterState: sourceAfter ?? step.sourceAfterState,
            failure: failure
        )
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

private struct JournalFixture {
    let directoryURL: URL
    let storeURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "RiffaOperationJournalTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        storeURL = directoryURL.appending(path: "journals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: storeURL,
            withIntermediateDirectories: true
        )
    }

    func journalURL(_ id: UUID) -> URL {
        storeURL.appending(
            path: id.uuidString.lowercased() + OperationJournalStore.journalFileSuffix
        )
    }

    var archiveURL: URL {
        storeURL.appending(path: "archive", directoryHint: .isDirectory)
    }

    func archivedJournalURL(_ id: UUID) -> URL {
        archiveURL.appending(
            path: id.uuidString.lowercased() + OperationJournalStore.journalFileSuffix
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
