import Foundation
import Testing
@testable import RiffaCore

@Suite("Journaled folder merge output")
struct JournaledFolderMergeOutputExecutorTests {
    @Test("Dry-run leaves neither output changes nor a journal directory")
    func dryRunHasNoJournalSideEffects() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("left", path: "item.txt", root: fixture.left)
        let plan = FolderMergePlan(actions: [copy("item.txt", from: .left)])
        let result = try await JournaledFolderMergeOutputExecutor(
            journalStore: OperationJournalStore(directoryURL: fixture.journals)
        ).execute(
            plan: plan,
            baseRoot: fixture.base,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            outputRoot: fixture.output,
            backupRoot: fixture.backup
        )

        #expect(result.status == .dryRun)
        #expect(!fixture.exists("item.txt", root: fixture.output))
        #expect(!FileManager.default.fileExists(atPath: fixture.journals.path))
    }

    @Test("A complete merge plan and its five roots are persisted before execution")
    func completedJournalContainsResolvedPlan() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("new", path: "new.txt", root: fixture.left)
        try fixture.write("replacement", path: "replace.txt", root: fixture.right)
        try fixture.write("old", path: "replace.txt", root: fixture.output)
        try fixture.write("retire", path: "retired.txt", root: fixture.output)
        let plan = FolderMergePlan(actions: [
            copy("new.txt", from: .left),
            copy("replace.txt", from: .right),
            omit("retired.txt")
        ])
        let store = OperationJournalStore(directoryURL: fixture.journals)

        let result = try await JournaledFolderMergeOutputExecutor(journalStore: store).execute(
            plan: plan,
            baseRoot: fixture.base,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            outputRoot: fixture.output,
            backupRoot: fixture.backup,
            options: .init(dryRun: false)
        )

        #expect(result.status == .completed)
        #expect(try fixture.read("new.txt", root: fixture.output) == "new")
        #expect(try fixture.read("replace.txt", root: fixture.output) == "replacement")
        #expect(!fixture.exists("retired.txt", root: fixture.output))
        #expect(try fixture.read("output/replace.txt", root: fixture.backup) == "old")
        #expect(try fixture.read("output/retired.txt", root: fixture.backup) == "retire")

        let journal = try #require(try await store.listActive().first)
        #expect(journal.kind == .merge)
        #expect(journal.status == .completed)
        #expect(journal.roots.map(\.role) == [.backup, .base, .left, .output, .right])
        #expect(journal.steps.count == plan.actions.count)
        #expect(journal.steps.map(\.actionKind) == [.copy, .replace, .delete])
        #expect(journal.steps.map(\.sourceRootRole) == [.left, .right, nil])
        #expect(journal.steps.map(\.status) == [.completed, .completed, .completed])
        #expect(journal.steps[0].beforeState == .missing)
        #expect(journal.steps[0].afterState?.byteCount == 3)
        #expect(journal.steps[0].backup == nil)
        #expect(journal.steps[1].beforeState?.byteCount == 3)
        #expect(journal.steps[1].afterState?.byteCount == 11)
        #expect(journal.steps[1].backup?.backupRelativePath == "output/replace.txt")
        #expect(journal.steps[2].beforeState?.byteCount == 6)
        #expect(journal.steps[2].afterState == .missing)
        #expect(journal.steps[2].backup?.backupRelativePath == "output/retired.txt")
    }

    @Test("An explicit conflict resolution is journaled with its selected source")
    func conflictResolutionRecordsSelectedSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("base", path: "choice.txt", root: fixture.base)
        try fixture.write("left", path: "choice.txt", root: fixture.left)
        try fixture.write("right", path: "choice.txt", root: fixture.right)
        let action = FolderMergeAction(
            kind: .conflict,
            outputRelativePath: "choice.txt",
            status: .conflict,
            reason: "Test conflict"
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)

        let result = try await JournaledFolderMergeOutputExecutor(journalStore: store).execute(
            plan: FolderMergePlan(actions: [action]),
            resolutions: ["choice.txt": .useRight],
            baseRoot: fixture.base,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            outputRoot: fixture.output,
            backupRoot: fixture.backup,
            options: .init(dryRun: false)
        )

        #expect(result.status == .completed)
        #expect(try fixture.read("choice.txt", root: fixture.output) == "right")
        let step = try #require(try await store.listActive().first?.steps.first)
        #expect(step.actionKind == .copy)
        #expect(step.sourceRootRole == .right)
        #expect(step.sourceRelativePath == nil)
        #expect(step.status == .completed)
    }

    @Test("A failed merge transaction records its rollback without splitting execution")
    func rolledBackExecutionIsRecorded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("new-a", path: "a.txt", root: fixture.left)
        try fixture.write("old-a", path: "a.txt", root: fixture.output)
        try fixture.write("new-b", path: "b.txt", root: fixture.left)
        let plan = FolderMergePlan(actions: [
            copy("a.txt", from: .left),
            copy("b.txt", from: .left)
        ])
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledFolderMergeOutputExecutor(
            journalStore: store,
            testingExecutorFailureAtActionIndex: 1
        )

        let result = try await executor.execute(
            plan: plan,
            baseRoot: fixture.base,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            outputRoot: fixture.output,
            backupRoot: fixture.backup,
            options: .init(dryRun: false)
        )

        #expect(result.status == .failedRolledBack)
        #expect(try fixture.read("a.txt", root: fixture.output) == "old-a")
        #expect(!fixture.exists("b.txt", root: fixture.output))
        let journal = try #require(try await store.listActive().first)
        #expect(journal.status == .rolledBack)
        #expect(journal.failure?.code == .actionFailed)
        #expect(journal.steps.map(\.status) == [.rolledBack, .failed])
        #expect(journal.steps[0].beforeState?.byteCount == 5)
        #expect(journal.steps[0].afterState?.byteCount == 5)
        #expect(journal.steps[1].beforeState == .missing)
        #expect(journal.steps[1].afterState == .missing)
        #expect(journal.steps[1].failure?.code == .actionFailed)
    }

    @Test("Journal creation failure closes before any output write")
    func creationFailureIsFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source", path: "item.txt", root: fixture.left)
        let plan = FolderMergePlan(actions: [copy("item.txt", from: .left)])
        let executor = JournaledFolderMergeOutputExecutor(
            journalStore: OperationJournalStore(directoryURL: fixture.journals),
            testingFailurePoint: .beforeCreate
        )

        do {
            _ = try await executor.execute(
                plan: plan,
                baseRoot: fixture.base,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                outputRoot: fixture.output,
                backupRoot: fixture.backup,
                options: .init(dryRun: false)
            )
            Issue.record("A journal creation failure must throw")
        } catch let error as JournaledFolderMergeOutputError {
            guard case let .journalPersistenceFailed(stage, journalID, _) = error else {
                Issue.record("Unexpected journal error: \(error)")
                return
            }
            #expect(stage == .create)
            #expect(journalID == nil)
        }

        #expect(!fixture.exists("item.txt", root: fixture.output))
        #expect(!FileManager.default.fileExists(atPath: fixture.journals.path))
    }

    @Test("An output nested below a source root is refused before execution")
    func overlappingRootsAreFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source", path: "item.txt", root: fixture.right)
        let nestedOutput = fixture.left.appending(
            path: "nested-output",
            directoryHint: .isDirectory
        )
        let plan = FolderMergePlan(actions: [copy("item.txt", from: .right)])
        let store = OperationJournalStore(directoryURL: fixture.journals)

        do {
            _ = try await JournaledFolderMergeOutputExecutor(journalStore: store).execute(
                plan: plan,
                baseRoot: fixture.base,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                outputRoot: nestedOutput,
                backupRoot: fixture.backup,
                options: .init(dryRun: false)
            )
            Issue.record("Overlapping roots must fail before merge output execution")
        } catch let error as JournaledFolderMergeOutputError {
            guard case let .journalPersistenceFailed(stage, journalID, underlying) = error else {
                Issue.record("Unexpected journal error: \(error)")
                return
            }
            #expect(stage == .create)
            #expect(journalID == nil)
            #expect(underlying == .overlappingRootPaths)
        }

        #expect(!FileManager.default.fileExists(atPath: nestedOutput.path))
        #expect(try await store.listActive().isEmpty)
    }

    @Test("Failure to mark executing leaves a complete preparing journal and no writes")
    func executingTransitionFailureIsScannable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source", path: "item.txt", root: fixture.left)
        let plan = FolderMergePlan(actions: [copy("item.txt", from: .left)])
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledFolderMergeOutputExecutor(
            journalStore: store,
            testingFailurePoint: .beforeMarkExecuting
        )

        await #expect(throws: JournaledFolderMergeOutputError.self) {
            _ = try await executor.execute(
                plan: plan,
                baseRoot: fixture.base,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                outputRoot: fixture.output,
                backupRoot: fixture.backup,
                options: .init(dryRun: false)
            )
        }

        #expect(!fixture.exists("item.txt", root: fixture.output))
        let journal = try #require(try await store.listUnfinished().first)
        #expect(journal.status == .preparing)
        #expect(journal.kind == .merge)
        #expect(journal.steps.count == plan.actions.count)
        #expect(journal.steps.allSatisfy { $0.status == .pending })
    }

    @Test("Terminal persistence failure cannot be returned as a successful merge")
    func terminalFailureDoesNotMisreportSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source", path: "item.txt", root: fixture.left)
        let plan = FolderMergePlan(actions: [copy("item.txt", from: .left)])
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledFolderMergeOutputExecutor(
            journalStore: store,
            testingFailurePoint: .beforeTerminalTransition
        )

        do {
            _ = try await executor.execute(
                plan: plan,
                baseRoot: fixture.base,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                outputRoot: fixture.output,
                backupRoot: fixture.backup,
                options: .init(dryRun: false)
            )
            Issue.record("A terminal journal failure must throw")
        } catch let error as JournaledFolderMergeOutputError {
            guard case let .journalPersistenceFailed(stage, journalID, _) = error else {
                Issue.record("Unexpected journal error: \(error)")
                return
            }
            #expect(stage == .markTerminal)
            #expect(journalID != nil)
        }

        #expect(try fixture.read("item.txt", root: fixture.output) == "source")
        let journal = try #require(try await store.listUnfinished().first)
        #expect(journal.status == .executing)
        #expect(journal.steps.first?.status == .completed)
    }

    @Test("An inconsistent result leaves recovery evidence unfinished")
    func inconsistentResultDoesNotFinishJournal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("a", path: "a.txt", root: fixture.left)
        try fixture.write("b", path: "b.txt", root: fixture.left)
        let actions = [copy("a.txt", from: .left), copy("b.txt", from: .left)]
        let plan = FolderMergePlan(actions: actions)
        let synthetic = FolderMergeOutputExecutionLog(
            status: .completed,
            dryRun: false,
            rollbackAttempted: false,
            rollbackSucceeded: nil,
            itemResults: [
                FolderMergeOutputItemResult(
                    actionIndex: 0,
                    action: actions[0],
                    resolution: nil,
                    status: .completed,
                    message: "Synthetic result"
                )
            ],
            issues: []
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledFolderMergeOutputExecutor(
            journalStore: store,
            testingExecutionLog: synthetic
        )

        await #expect(throws: JournaledFolderMergeOutputError.inconsistentExecutionLog) {
            _ = try await executor.execute(
                plan: plan,
                baseRoot: fixture.base,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                outputRoot: fixture.output,
                backupRoot: fixture.backup,
                options: .init(dryRun: false)
            )
        }

        let journal = try #require(try await store.listUnfinished().first)
        #expect(journal.status == .executing)
        #expect(journal.steps.allSatisfy { $0.status == .pending })
    }

    private func copy(
        _ path: String,
        from source: FolderMergeSource
    ) -> FolderMergeAction {
        let kind: FolderMergeAction.Kind = switch source {
        case .base: .copyFromBase
        case .left: .copyFromLeft
        case .right: .copyFromRight
        }
        return FolderMergeAction(
            kind: kind,
            outputRelativePath: path,
            source: source,
            sourceRelativePath: path,
            status: source == .right ? .rightChanged : .leftChanged,
            reason: "Test copy"
        )
    }

    private func omit(_ path: String) -> FolderMergeAction {
        FolderMergeAction(
            kind: .omit,
            outputRelativePath: path,
            status: .bothDeleted,
            reason: "Test omission"
        )
    }
}

private struct JournaledFolderMergeFixture {
    let root: URL
    let base: URL
    let left: URL
    let right: URL
    let output: URL
    let backup: URL
    let journals: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "RiffaJournaledFolderMergeTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        base = root.appending(path: "base", directoryHint: .isDirectory)
        left = root.appending(path: "left", directoryHint: .isDirectory)
        right = root.appending(path: "right", directoryHint: .isDirectory)
        output = root.appending(path: "output", directoryHint: .isDirectory)
        backup = root.appending(path: "backup", directoryHint: .isDirectory)
        journals = root.appending(path: "journals", directoryHint: .isDirectory)
        for directory in [base, left, right, output] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ contents: String, path: String, root: URL) throws {
        let destination = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: destination)
    }

    func read(_ path: String, root: URL) throws -> String {
        String(decoding: try Data(contentsOf: root.appending(path: path)), as: UTF8.self)
    }

    func exists(_ path: String, root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }
}

private typealias Fixture = JournaledFolderMergeFixture
