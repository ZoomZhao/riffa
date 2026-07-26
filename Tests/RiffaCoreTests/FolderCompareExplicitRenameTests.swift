import Darwin
import Foundation
import Testing
@testable import RiffaCore

@Suite("Folder Compare explicit rename")
struct FolderCompareExplicitRenameTests {
    @Test("UI eligibility accepts exactly one visible issue-free ordinary file on the chosen side")
    func eligibilityIsExactAndSideSpecific() throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("nested/original.txt", "payload", side: .left)
        let file = try fixture.node("nested/original.txt", side: .left)
        let directory = try fixture.node("nested", side: .left)
        let planner = FolderCompareExplicitRenamePlanner()

        let eligible = try planner.eligibility(
            visibleNodes: [file],
            selectedIDs: [file.id],
            side: .left
        )
        #expect(eligible.sourceRelativePath == "nested/original.txt")
        #expect(eligible.currentLeafName == "original.txt")
        #expect(eligible.side == .left)

        #expect(throws: FolderCompareExplicitRenamePlanningError.selectionRequired) {
            try planner.eligibility(visibleNodes: [file], selectedIDs: [], side: .left)
        }
        #expect(throws: FolderCompareExplicitRenamePlanningError.exactlyOneSelectionRequired) {
            try planner.eligibility(
                visibleNodes: [file, directory],
                selectedIDs: [file.id, directory.id],
                side: .left
            )
        }
        #expect(throws: FolderCompareExplicitRenamePlanningError.selectionNotVisible) {
            try planner.eligibility(
                visibleNodes: [],
                selectedIDs: [file.id],
                side: .left
            )
        }
        #expect(throws: FolderCompareExplicitRenamePlanningError.selectedSideMissing) {
            try planner.eligibility(
                visibleNodes: [file],
                selectedIDs: [file.id],
                side: .right
            )
        }
        #expect(throws: FolderCompareExplicitRenamePlanningError.ordinaryFileRequired) {
            try planner.eligibility(
                visibleNodes: [directory],
                selectedIDs: [directory.id],
                side: .left
            )
        }

        let issueNode = PairNode(
            relativePath: file.relativePath,
            left: file.left,
            right: nil,
            status: .error,
            issues: [ResourceIssue(path: file.relativePath, message: "unreadable")]
        )
        #expect(throws: FolderCompareExplicitRenamePlanningError.comparisonIssue) {
            try planner.eligibility(
                visibleNodes: [issueNode],
                selectedIDs: [issueNode.id],
                side: .left
            )
        }
    }

    @Test("Leaf validation rejects empty, dot, separators, NUL, and over-budget UTF-8 names")
    func leafValidation() throws {
        let rejected: [(String, FolderCompareExplicitRenameLeafProblem)] = [
            ("", .empty),
            (".", .dotComponent),
            ("..", .dotComponent),
            ("folder/name", .containsSlash),
            ("bad\0name", .containsNUL),
            (String(repeating: "é", count: 128), .exceedsUTF8Budget)
        ]
        for (leaf, problem) in rejected {
            #expect(throws: FolderCompareExplicitRenamePlanningError.invalidLeaf(problem)) {
                try FolderCompareExplicitRenamePlanner.validateLeaf(leaf)
            }
        }
        try FolderCompareExplicitRenamePlanner.validateLeaf(
            String(repeating: "a", count: FolderCompareExplicitRenamePlanner.maximumLeafUTF8ByteCount)
        )
    }

    @Test("Planner emits one distinct same-directory explicit move with a persistent source snapshot")
    func plansExplicitMoveWithoutRenameDetection() async throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("nested/original.txt", "rename me", side: .left)
        let node = try fixture.node("nested/original.txt", side: .left)

        let result = try await FolderCompareExplicitRenamePlanner().plan(
            visibleNodes: [node],
            selectedIDs: [node.id],
            side: .left,
            newLeafName: "renamed.txt",
            root: fixture.left
        )

        #expect(result.sourceRelativePath == "nested/original.txt")
        #expect(result.destinationRelativePath == "nested/renamed.txt")
        #expect(result.kind == .ordinary)
        #expect(result.sourceSnapshot.byteCount == 9)
        #expect(result.sourceSnapshot.sha256.count == 64)
        #expect(result.plan.mode == .mirrorRightToLeft)
        #expect(result.plan.actions.count == 1)
        let action = try #require(result.plan.actions.first)
        #expect(action.kind == .move)
        #expect(action.sourceSide == .left)
        #expect(action.targetSide == .left)
        #expect(action.reason == .explicitlyRenamedWithinSide)
        #expect(action.risk == .high)
        #expect(action.moveProof?.authorization == .explicitSameDirectoryRename)
        #expect(action.moveProof?.referenceSide == .left)
        #expect(action.moveProof?.referenceRelativePath == "nested/original.txt")
        #expect(action.moveProof?.explicitSourceSnapshot == result.sourceSnapshot)
    }

    @Test("Detected-match and explicit-rename proof domains cannot substitute for each other")
    func proofDomainsStaySeparate() async throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("original.txt", "rename me", side: .left)
        try fixture.write("reference.txt", "rename me", side: .right)
        let node = try fixture.node("original.txt", side: .left)
        let valid = try await fixture.plan(node, side: .left, newLeaf: "renamed.txt")
        let snapshot = valid.sourceSnapshot

        let invalidActions = [
            FolderSyncAction(
                kind: .move,
                sourceSide: .left,
                targetSide: .left,
                sourceRelativePath: "original.txt",
                targetRelativePath: "renamed.txt",
                reason: .explicitlyRenamedWithinSide,
                risk: .high,
                moveProof: FolderSyncMoveProof(
                    referenceSide: .left,
                    referenceRelativePath: "original.txt",
                    expectedByteCount: snapshot.byteCount,
                    expectedSHA256Digest: snapshot.sha256,
                    authorization: .explicitSameDirectoryRename,
                    explicitSourceSnapshot: nil
                )
            ),
            FolderSyncAction(
                kind: .move,
                sourceSide: .left,
                targetSide: .left,
                sourceRelativePath: "original.txt",
                targetRelativePath: "other/renamed.txt",
                reason: .explicitlyRenamedWithinSide,
                risk: .high,
                moveProof: FolderSyncMoveProof(
                    referenceSide: .left,
                    referenceRelativePath: "original.txt",
                    expectedByteCount: snapshot.byteCount,
                    expectedSHA256Digest: snapshot.sha256,
                    authorization: .explicitSameDirectoryRename,
                    explicitSourceSnapshot: snapshot
                )
            ),
            FolderSyncAction(
                kind: .move,
                sourceSide: .left,
                targetSide: .left,
                sourceRelativePath: "original.txt",
                targetRelativePath: "renamed.txt",
                reason: .renameMatchMovedWithinTarget,
                risk: .high,
                moveProof: FolderSyncMoveProof(
                    referenceSide: .right,
                    referenceRelativePath: "reference.txt",
                    expectedByteCount: snapshot.byteCount,
                    expectedSHA256Digest: snapshot.sha256,
                    authorization: .detectedRenameMatch,
                    explicitSourceSnapshot: snapshot
                )
            ),
            FolderSyncAction(
                kind: .move,
                sourceSide: .left,
                targetSide: .left,
                sourceRelativePath: "original.txt",
                targetRelativePath: "renamed.txt",
                reason: .renameMatchMovedWithinTarget,
                risk: .high,
                moveProof: FolderSyncMoveProof(
                    referenceSide: .left,
                    referenceRelativePath: "original.txt",
                    expectedByteCount: snapshot.byteCount,
                    expectedSHA256Digest: snapshot.sha256
                )
            )
        ]

        for action in invalidActions {
            let log = await LocalFolderSyncExecutor().execute(
                plan: FolderSyncPlan(mode: .mirrorRightToLeft, actions: [action]),
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: true, allowHighRisk: true)
            )
            #expect(log.status == .refused)
            #expect(log.issues.contains { $0.code == .malformedAction })
        }
        #expect(fixture.exists("original.txt", side: .left))
        #expect(!fixture.exists("renamed.txt", side: .left))
    }

    @Test("Existing targets, symbolic links, unchanged names, and changed comparison metadata fail closed")
    func plannerRefusesUnsafeInputs() async throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("original.txt", "source", side: .left)
        try fixture.write("occupied.txt", "target", side: .left)
        let node = try fixture.node("original.txt", side: .left)
        let planner = FolderCompareExplicitRenamePlanner()

        await #expect(throws: LocalVerifiedFileMoveError.destinationExists) {
            try await planner.plan(
                visibleNodes: [node],
                selectedIDs: [node.id],
                side: .left,
                newLeafName: "occupied.txt",
                root: fixture.left
            )
        }
        await #expect(throws: FolderCompareExplicitRenamePlanningError.nameUnchanged) {
            try await planner.plan(
                visibleNodes: [node],
                selectedIDs: [node.id],
                side: .left,
                newLeafName: "original.txt",
                root: fixture.left
            )
        }

        let forgedEntry = ResourceEntry(
            locator: node.left!.locator,
            relativePath: node.relativePath,
            kind: .file,
            byteCount: node.left!.byteCount! + 1,
            modificationDate: node.left!.modificationDate,
            permissions: node.left!.permissions,
            fileIdentifier: node.left!.fileIdentifier
        )
        let forgedNode = PairNode(
            relativePath: node.relativePath,
            left: forgedEntry,
            right: nil,
            status: .leftOnly
        )
        await #expect(throws: FolderCompareExplicitRenamePlanningError.declaredSourceMetadataChanged) {
            try await planner.plan(
                visibleNodes: [forgedNode],
                selectedIDs: [forgedNode.id],
                side: .left,
                newLeafName: "new.txt",
                root: fixture.left
            )
        }

        try FileManager.default.createSymbolicLink(
            at: fixture.left.appending(path: "link.txt"),
            withDestinationURL: fixture.left.appending(path: "original.txt")
        )
        let linkEntry = ResourceEntry(
            locator: ResourceLocator(fileURL: fixture.left.appending(path: "link.txt")),
            relativePath: "link.txt",
            kind: .symbolicLink
        )
        let linkNode = PairNode(
            relativePath: "link.txt",
            left: linkEntry,
            right: nil,
            status: .leftOnly
        )
        #expect(throws: FolderCompareExplicitRenamePlanningError.ordinaryFileRequired) {
            try planner.eligibility(
                visibleNodes: [linkNode],
                selectedIDs: [linkNode.id],
                side: .left
            )
        }
    }

    @Test("Dry run is mutation-free and formal execution is journaled")
    func dryRunAndJournaledExecution() async throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("original.txt", "journal payload", side: .right)
        let node = try fixture.node("original.txt", side: .right)
        let result = try await fixture.plan(node, side: .right, newLeaf: "renamed.txt")
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let executor = JournaledLocalFolderSyncExecutor(journalStore: store)

        let dryRun = try await executor.execute(
            plan: result.plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: true, allowHighRisk: true)
        )
        #expect(dryRun.status == .dryRun)
        #expect(fixture.exists("original.txt", side: .right))
        #expect(!fixture.exists("renamed.txt", side: .right))
        #expect(try await store.listActive().isEmpty)

        let applied = try await executor.execute(
            plan: result.plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: false, allowHighRisk: true)
        )
        #expect(applied.status == .completed)
        #expect(!fixture.exists("original.txt", side: .right))
        #expect(try fixture.read("renamed.txt", side: .right) == "journal payload")
        let journal = try #require(try await store.listActive().first)
        #expect(journal.status == .completed)
        let step = try #require(journal.steps.first)
        #expect(step.actionKind == .move)
        #expect(step.sourceRelativePath == "original.txt")
        #expect(step.relativePath == "renamed.txt")
        #expect(step.status == .completed)
    }

    @Test("A stale identity or content snapshot refuses execution before writing")
    func staleSnapshotRefusesExecution() async throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("original.txt", "first", side: .left)
        let node = try fixture.node("original.txt", side: .left)
        let result = try await fixture.plan(node, side: .left, newLeaf: "renamed.txt")
        try fixture.write("original.txt", "other", side: .left)

        let applied = await LocalFolderSyncExecutor().execute(
            plan: result.plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: false, allowHighRisk: true)
        )
        #expect(applied.status == .refused)
        #expect(try fixture.read("original.txt", side: .left) == "other")
        #expect(!fixture.exists("renamed.txt", side: .left))
    }

    @Test("Proof-to-commit source replacement and target occupation races are refused")
    func sourceAndTargetRacesFailClosed() async throws {
        for race in [ExplicitRenameRace.replaceSource, .occupyTarget] {
            let fixture = try ExplicitRenameFixture()
            defer { fixture.remove() }
            try fixture.write("original.txt", "same bytes", side: .left)
            let node = try fixture.node("original.txt", side: .left)
            let result = try await fixture.plan(node, side: .left, newLeaf: "renamed.txt")
            let once = ExplicitRenameOnce()

            let applied = await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
                guard point == .beforeRename, once.claim() else { return .proceed }
                switch race {
                case .replaceSource:
                    try? FileManager.default.moveItem(
                        at: fixture.left.appending(path: "original.txt"),
                        to: fixture.left.appending(path: "displaced.txt")
                    )
                    try? Data("same bytes".utf8).write(
                        to: fixture.left.appending(path: "original.txt")
                    )
                case .occupyTarget:
                    try? Data("foreign".utf8).write(
                        to: fixture.left.appending(path: "renamed.txt")
                    )
                }
                return .proceed
            }) {
                await LocalFolderSyncExecutor().execute(
                    plan: result.plan,
                    leftRoot: fixture.left,
                    rightRoot: fixture.right,
                    backupRoot: fixture.backup,
                    options: .init(dryRun: false, allowHighRisk: true)
                )
            }

            #expect(applied.status == .failedRolledBack)
            switch race {
            case .replaceSource:
                #expect(try fixture.read("original.txt", side: .left) == "same bytes")
                #expect(try fixture.read("displaced.txt", side: .left) == "same bytes")
                #expect(!fixture.exists("renamed.txt", side: .left))
            case .occupyTarget:
                #expect(try fixture.read("original.txt", side: .left) == "same bytes")
                #expect(try fixture.read("renamed.txt", side: .left) == "foreign")
            }
        }
    }

    @Test("Parent rebinding at commit is detected through no-follow descriptor rebinding")
    func parentRebindingFailsClosed() async throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("nested/original.txt", "payload", side: .left)
        let node = try fixture.node("nested/original.txt", side: .left)
        let result = try await fixture.plan(node, side: .left, newLeaf: "renamed.txt")
        let once = ExplicitRenameOnce()

        let applied = await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
            guard point == .beforeRename, once.claim() else { return .proceed }
            try? FileManager.default.moveItem(
                at: fixture.left.appending(path: "nested"),
                to: fixture.left.appending(path: "displaced")
            )
            try? FileManager.default.createDirectory(
                at: fixture.left.appending(path: "nested"),
                withIntermediateDirectories: false
            )
            return .proceed
        }) {
            await LocalFolderSyncExecutor().execute(
                plan: result.plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false, allowHighRisk: true)
            )
        }

        #expect(applied.status == .failedRolledBack)
        #expect(try fixture.read("displaced/original.txt", side: .left) == "payload")
        #expect(!fixture.exists("displaced/renamed.txt", side: .left))
        #expect(!fixture.exists("nested/renamed.txt", side: .left))
    }

    @Test("Root rebinding at commit is detected before the stale capability can rename")
    func rootRebindingFailsClosed() async throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("original.txt", "payload", side: .left)
        let node = try fixture.node("original.txt", side: .left)
        let result = try await fixture.plan(node, side: .left, newLeaf: "renamed.txt")
        let once = ExplicitRenameOnce()
        let displacedRoot = fixture.root.appending(
            path: "displaced-left",
            directoryHint: .isDirectory
        )

        let applied = await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
            guard point == .beforeRename, once.claim() else { return .proceed }
            try? FileManager.default.moveItem(at: fixture.left, to: displacedRoot)
            try? FileManager.default.createDirectory(
                at: fixture.left,
                withIntermediateDirectories: false
            )
            return .proceed
        }) {
            await LocalFolderSyncExecutor().execute(
                plan: result.plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false, allowHighRisk: true)
            )
        }

        #expect(applied.status == .failedRolledBack)
        #expect(try String(
            contentsOf: displacedRoot.appending(path: "original.txt"),
            encoding: .utf8
        ) == "payload")
        #expect(!FileManager.default.fileExists(
            atPath: displacedRoot.appending(path: "renamed.txt").path
        ))
        #expect(!fixture.exists("renamed.txt", side: .left))
    }

    @Test("Explicit rename never falls back to cross-device copying")
    func crossDeviceFallbackIsForbidden() async throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("original.txt", "payload", side: .left)
        let node = try fixture.node("original.txt", side: .left)
        let result = try await fixture.plan(node, side: .left, newLeaf: "renamed.txt")

        let applied = await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
            point == .beforeRename ? .forceCrossDevice : .proceed
        }) {
            await LocalFolderSyncExecutor().execute(
                plan: result.plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false, allowHighRisk: true)
            )
        }

        #expect(applied.status == .failedRolledBack)
        #expect(try fixture.read("original.txt", side: .left) == "payload")
        #expect(!fixture.exists("renamed.txt", side: .left))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.left.path)
        #expect(!names.contains { $0.hasPrefix(".riffa-verified-move-") })
    }

    @Test("Cancellation after install restores the source and records a rolled-back journal")
    func cancellationRollsBackAndJournals() async throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("original.txt", "payload", side: .left)
        let node = try fixture.node("original.txt", side: .left)
        let result = try await fixture.plan(node, side: .left, newLeaf: "renamed.txt")
        let store = OperationJournalStore(directoryURL: fixture.journals)

        let applied = try await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
            point == .afterInstall ? .cancel : .proceed
        }) {
            try await JournaledLocalFolderSyncExecutor(journalStore: store).execute(
                plan: result.plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false, allowHighRisk: true)
            )
        }

        #expect(applied.status == .failedRolledBack)
        #expect(applied.issues.first?.code == .cancelled)
        #expect(try fixture.read("original.txt", side: .left) == "payload")
        #expect(!fixture.exists("renamed.txt", side: .left))
        let journal = try #require(try await store.listActive().first)
        #expect(journal.status == .rolledBack)
        #expect(journal.steps.first?.status == .failed)
        #expect(journal.steps.first?.sourceAfterState?.kind == .regularFile)
        #expect(journal.steps.first?.afterState == .missing)
    }

    @Test("A later failure reverses an already completed explicit rename by installed identity")
    func laterFailureReversesEarlierRename() async throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("one.txt", "first", side: .left)
        try fixture.write("two.txt", "second", side: .left)
        let first = try await fixture.plan(
            try fixture.node("one.txt", side: .left),
            side: .left,
            newLeaf: "one-renamed.txt"
        )
        let second = try await fixture.plan(
            try fixture.node("two.txt", side: .left),
            side: .left,
            newLeaf: "two-renamed.txt"
        )
        let combined = FolderSyncPlan(
            mode: .mirrorRightToLeft,
            actions: first.plan.actions + second.plan.actions
        )
        let store = OperationJournalStore(directoryURL: fixture.journals)

        let applied = try await JournaledLocalFolderSyncExecutor(
            journalStore: store,
            testingExecutorFailureAtActionIndex: 1
        ).execute(
            plan: combined,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: false, allowHighRisk: true)
        )

        #expect(applied.status == .failedRolledBack)
        #expect(try fixture.read("one.txt", side: .left) == "first")
        #expect(try fixture.read("two.txt", side: .left) == "second")
        #expect(!fixture.exists("one-renamed.txt", side: .left))
        #expect(!fixture.exists("two-renamed.txt", side: .left))
        let journal = try #require(try await store.listActive().first)
        #expect(journal.status == .rolledBack)
        #expect(journal.steps.map(\.status) == [.rolledBack, .failed])
    }

    @Test("Case-only classification distinguishes no-op, case-sensitive absence, alias, and occupation")
    func caseOnlyClassificationAndVolumeRelationships() throws {
        #expect(try FolderCompareExplicitRenamePlanner.renameKind(
            currentLeafName: "Readme.txt",
            newLeafName: "README.txt"
        ) == .caseOnly)
        #expect(try FolderCompareExplicitRenamePlanner.renameKind(
            currentLeafName: "Readme.txt",
            newLeafName: "Guide.txt"
        ) == .ordinary)
        #expect(throws: FolderCompareExplicitRenamePlanningError.nameUnchanged) {
            try FolderCompareExplicitRenamePlanner.renameKind(
                currentLeafName: "é.txt",
                newLeafName: "e\u{301}.txt"
            )
        }

        #expect(classifyCaseOnlyDestinationRelationship(
            exactDestinationExists: false,
            lookupFound: false,
            lookupMatchesSelectedRegularFile: false
        ) == .missingOnCaseSensitiveVolume)
        #expect(classifyCaseOnlyDestinationRelationship(
            exactDestinationExists: false,
            lookupFound: true,
            lookupMatchesSelectedRegularFile: true
        ) == .selectedSourceAliasOnCaseInsensitiveVolume)
        #expect(classifyCaseOnlyDestinationRelationship(
            exactDestinationExists: true,
            lookupFound: true,
            lookupMatchesSelectedRegularFile: true
        ) == .occupied)
        #expect(classifyCaseOnlyDestinationRelationship(
            exactDestinationExists: false,
            lookupFound: true,
            lookupMatchesSelectedRegularFile: false
        ) == .occupied)
    }

    @Test("Case-only rename uses its own proof domain and persists only public names")
    func caseOnlyRenameExecutesAndJournals() async throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("nested/Readme.txt", "case payload", side: .left)
        let node = try fixture.node("nested/Readme.txt", side: .left)
        let result = try await fixture.plan(node, side: .left, newLeaf: "README.txt")

        #expect(result.kind == .caseOnly)
        #expect(result.plan.actions.first?.moveProof?.authorization
            == .explicitSameDirectoryCaseOnlyRename)
        let store = OperationJournalStore(directoryURL: fixture.journals)
        let execution = try await JournaledLocalFolderSyncExecutor(journalStore: store).execute(
            plan: result.plan,
            leftRoot: fixture.left,
            rightRoot: fixture.right,
            backupRoot: fixture.backup,
            options: .init(dryRun: false, allowHighRisk: true)
        )

        #expect(execution.status == .completed)
        #expect(try fixture.read("nested/README.txt", side: .left) == "case payload")
        let names = try fixture.exactNames(in: "nested", side: .left)
        #expect(names.contains("README.txt"))
        #expect(!names.contains("Readme.txt"))
        #expect(!names.contains { $0.hasPrefix(riffaCaseOnlyRenameTemporaryLeafPrefix) })

        let journal = try #require(try await store.listActive().first)
        #expect(journal.status == .completed)
        #expect(journal.steps.first?.relativePath == "nested/README.txt")
        #expect(journal.steps.first?.sourceRelativePath == "nested/Readme.txt")
        #expect(journal.steps.first?.afterState?.kind == .regularFile)
        #expect(journal.steps.first?.sourceAfterState == .missing)
        let journalURL = fixture.journals.appending(
            path: journal.id.uuidString.lowercased() + OperationJournalStore.journalFileSuffix
        )
        let persisted = String(decoding: try Data(contentsOf: journalURL), as: UTF8.self)
        #expect(!persisted.contains(riffaCaseOnlyRenameTemporaryLeafPrefix))
    }

    @Test("Failures and cancellation at every case-only install boundary restore the original spelling")
    func caseOnlyStageFailuresRestoreSource() async throws {
        let scenarios: [(LocalVerifiedFileMoveCheckpoint, LocalVerifiedFileMoveFaultAction)] = [
            (.afterCaseOnlyTemporaryInstall, .fail(code: EIO)),
            (.beforeCaseOnlyFinalRename, .cancel),
            (.afterInstall, .cancel)
        ]
        for (point, action) in scenarios {
            let fixture = try ExplicitRenameFixture()
            defer { fixture.remove() }
            try fixture.write("Readme.txt", "payload", side: .left)
            let result = try await fixture.plan(
                try fixture.node("Readme.txt", side: .left),
                side: .left,
                newLeaf: "README.txt"
            )

            let execution = await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ current in
                current == point ? action : .proceed
            }) {
                await LocalFolderSyncExecutor().execute(
                    plan: result.plan,
                    leftRoot: fixture.left,
                    rightRoot: fixture.right,
                    backupRoot: fixture.backup,
                    options: .init(dryRun: false, allowHighRisk: true)
                )
            }

            #expect(execution.status == .failedRolledBack)
            #expect(try fixture.read("Readme.txt", side: .left) == "payload")
            let names = try fixture.exactNames(side: .left)
            #expect(names.contains("Readme.txt"))
            #expect(!names.contains("README.txt"))
            #expect(!names.contains { $0.hasPrefix(riffaCaseOnlyRenameTemporaryLeafPrefix) })
        }
    }

    @Test("A destination race never overwrites a foreign node and reports an unrecoverable alias collision")
    func caseOnlyDestinationRaceNeverClobbers() async throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("Readme.txt", "selected", side: .left)
        let destinationAliasesSourceBeforeMove = fixture.exists("README.txt", side: .left)
        let result = try await fixture.plan(
            try fixture.node("Readme.txt", side: .left),
            side: .left,
            newLeaf: "README.txt"
        )
        let once = ExplicitRenameOnce()

        let execution = await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
            guard point == .beforeCaseOnlyFinalRename, once.claim() else { return .proceed }
            try? Data("foreign".utf8).write(
                to: fixture.left.appending(path: "README.txt")
            )
            return .proceed
        }) {
            await LocalFolderSyncExecutor().execute(
                plan: result.plan,
                leftRoot: fixture.left,
                rightRoot: fixture.right,
                backupRoot: fixture.backup,
                options: .init(dryRun: false, allowHighRisk: true)
            )
        }

        #expect(try fixture.read("README.txt", side: .left) == "foreign")
        #expect(execution.issues.allSatisfy {
            !$0.message.contains(riffaCaseOnlyRenameTemporaryLeafPrefix)
        })
        let names = try fixture.exactNames(side: .left)
        if destinationAliasesSourceBeforeMove {
            #expect(execution.status == .failedRollbackIncomplete)
            #expect(!names.contains("Readme.txt"))
            #expect(names.contains { $0.hasPrefix(riffaCaseOnlyRenameTemporaryLeafPrefix) })
        } else {
            #expect(execution.status == .failedRolledBack)
            #expect(try fixture.read("Readme.txt", side: .left) == "selected")
            #expect(!names.contains { $0.hasPrefix(riffaCaseOnlyRenameTemporaryLeafPrefix) })
        }
    }

    @Test("Exact-name descriptor scans are repeatable on one retained parent")
    func exactNameScansDoNotShareDirectoryOffsets() throws {
        let fixture = try ExplicitRenameFixture()
        defer { fixture.remove() }
        try fixture.write("Readme.txt", "payload", side: .left)

        let parent = Darwin.open(
            fixture.left.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parent >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(parent) }

        #expect(
            try riffaExactDirectoryEntryName(
                parent: parent,
                requestedLeaf: "Readme.txt"
            ) == "Readme.txt"
        )
        #expect(
            try riffaExactDirectoryEntryName(
                parent: parent,
                requestedLeaf: "Readme.txt"
            ) == "Readme.txt"
        )
    }
}

private enum ExplicitRenameRace: Sendable {
    case replaceSource
    case occupyTarget
}

private final class ExplicitRenameOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}

private final class ExplicitRenameFixture: @unchecked Sendable {
    let root: URL
    let left: URL
    let right: URL
    let backup: URL
    let journals: URL

    init() throws {
        // O_NOFOLLOW_ANY intentionally rejects the `/var` and `/tmp` symlink
        // spellings used by Foundation's temporaryDirectory. Use the real
        // `/private/tmp` path, matching the verified-move security fixtures.
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appending(
            path: "RiffaExplicitRenameTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        left = root.appending(path: "left", directoryHint: .isDirectory)
        right = root.appending(path: "right", directoryHint: .isDirectory)
        backup = root.appending(path: "backup", directoryHint: .isDirectory)
        journals = root.appending(path: "journals", directoryHint: .isDirectory)
        for directory in [left, right, backup] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func write(_ path: String, _ contents: String, side: FolderSyncSide) throws {
        let url = root(for: side).appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    func node(_ path: String, side: FolderSyncSide) throws -> PairNode {
        let url = root(for: side).appending(path: path)
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let kind: ResourceEntry.Kind = switch information.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): .file
        case mode_t(S_IFDIR): .directory
        case mode_t(S_IFLNK): .symbolicLink
        default: .other
        }
        let seconds = TimeInterval(information.st_mtimespec.tv_sec)
            + TimeInterval(information.st_mtimespec.tv_nsec) / 1_000_000_000
        let entry = ResourceEntry(
            locator: ResourceLocator(fileURL: url),
            relativePath: path,
            kind: kind,
            byteCount: kind == .file ? Int64(information.st_size) : nil,
            modificationDate: Date(timeIntervalSince1970: seconds),
            permissions: UInt16(information.st_mode & 0o7777),
            fileIdentifier: "\(UInt64(bitPattern: Int64(information.st_dev))):\(UInt64(information.st_ino))"
        )
        return PairNode(
            relativePath: path,
            left: side == .left ? entry : nil,
            right: side == .right ? entry : nil,
            status: side == .left ? .leftOnly : .rightOnly
        )
    }

    func plan(
        _ node: PairNode,
        side: FolderSyncSide,
        newLeaf: String
    ) async throws -> FolderCompareExplicitRenamePlanningResult {
        try await FolderCompareExplicitRenamePlanner().plan(
            visibleNodes: [node],
            selectedIDs: [node.id],
            side: side,
            newLeafName: newLeaf,
            root: root(for: side)
        )
    }

    func exists(_ path: String, side: FolderSyncSide) -> Bool {
        FileManager.default.fileExists(atPath: root(for: side).appending(path: path).path)
    }

    func read(_ path: String, side: FolderSyncSide) throws -> String {
        try String(contentsOf: root(for: side).appending(path: path), encoding: .utf8)
    }

    func exactNames(
        in relativeDirectory: String = "",
        side: FolderSyncSide
    ) throws -> [String] {
        let directory = relativeDirectory.isEmpty
            ? root(for: side)
            : root(for: side).appending(path: relativeDirectory, directoryHint: .isDirectory)
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func root(for side: FolderSyncSide) -> URL {
        side == .left ? left : right
    }
}
