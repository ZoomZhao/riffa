import Testing
@testable import RiffaCore

@Suite("Text merge edit history")
struct TextMergeEditHistoryTests {
    @Test("Manual Unicode edits undo and redo as one complete draft")
    func manualUnicodeEdit() throws {
        let initial = TextMergeDraft(
            outputText: "alpha\n开发者 👩🏽‍💻\n",
            resolutions: [0: .left]
        )
        let edited = TextMergeDraft(
            outputText: "alpha\n开发团队 👩🏽‍💻 café\n",
            resolutions: [0: .left]
        )
        var history = TextMergeEditHistory(initialDraft: initial)

        #expect(history.record(edited, action: .manualOutputEdit) == .recorded)
        #expect(history.currentDraft == edited)
        #expect(history.nextUndoAction == .manualOutputEdit)

        let undone = history.undo()
        #expect(try #require(undone) == initial)
        #expect(history.canRedo)
        #expect(history.undoEntryCount + history.redoEntryCount == 1)
        let redone = history.redo()
        #expect(try #require(redone) == edited)
        #expect(history.undoEntryCount + history.redoEntryCount == 1)
    }

    @Test("Conflict resolution and rebuilt output restore atomically")
    func conflictResolutionRestoresCompleteDraft() throws {
        let unresolved = TextMergeDraft(
            outputText: "<<<<<<< LEFT\nL\n=======\nR\n>>>>>>> RIGHT\n",
            resolutions: [7: .unresolved]
        )
        let resolved = TextMergeDraft(
            outputText: "L\n",
            resolutions: [7: .left]
        )
        var history = TextMergeEditHistory(initialDraft: unresolved)

        #expect(
            history.record(resolved, action: .conflictResolution(conflictID: 7))
                == .recorded
        )
        #expect(history.nextUndoAction == .conflictResolution(conflictID: 7))
        let undone = history.undo()
        #expect(try #require(undone) == unresolved)
        let redone = history.redo()
        #expect(try #require(redone) == resolved)
    }

    @Test("Canonically equivalent Unicode spellings remain byte-exact edits")
    func canonicalUnicodeEditIsNotCollapsed() throws {
        let decomposed = TextMergeDraft(outputText: "cafe\u{301}\n", resolutions: [:])
        let composed = TextMergeDraft(outputText: "caf\u{e9}\n", resolutions: [:])
        var history = TextMergeEditHistory(initialDraft: decomposed)

        #expect(history.record(composed, action: .manualOutputEdit) == .recorded)
        #expect(history.currentDraft.outputText.utf8.elementsEqual(composed.outputText.utf8))
        let undone = history.undo()
        let restored = try #require(undone)
        #expect(restored.outputText.utf8.elementsEqual(decomposed.outputText.utf8))
        let redone = history.redo()
        let reapplied = try #require(redone)
        #expect(reapplied.outputText.utf8.elementsEqual(composed.outputText.utf8))
    }

    @Test("Undo restores manual work replaced by a later conflict choice")
    func undoConflictChoiceRestoresManualWork() throws {
        let initial = TextMergeDraft(
            outputText: "markers\n",
            resolutions: [0: .unresolved]
        )
        let manual = TextMergeDraft(
            outputText: "hand edited markers\n",
            resolutions: [0: .unresolved]
        )
        let resolved = TextMergeDraft(
            outputText: "selected left\n",
            resolutions: [0: .left]
        )
        var history = TextMergeEditHistory(initialDraft: initial)

        history.record(manual, action: .manualOutputEdit)
        history.record(resolved, action: .conflictResolution(conflictID: 0))

        let firstUndo = history.undo()
        #expect(try #require(firstUndo) == manual)
        let secondUndo = history.undo()
        #expect(try #require(secondUndo) == initial)
    }

    @Test("A new edit after undo clears redo without clearing valid undo")
    func divergentEditClearsRedo() throws {
        let initial = draft("a")
        var history = TextMergeEditHistory(initialDraft: initial)
        history.record(draft("ab"), action: .manualOutputEdit)
        history.record(draft("abc"), action: .manualOutputEdit)

        let firstUndo = history.undo()
        #expect(try #require(firstUndo) == draft("ab"))
        #expect(history.canRedo)

        history.record(draft("ab!"), action: .manualOutputEdit)

        #expect(!history.canRedo)
        let divergentUndo = history.undo()
        #expect(try #require(divergentUndo) == draft("ab"))
        let initialUndo = history.undo()
        #expect(try #require(initialUndo) == initial)
    }

    @Test("Entry cap evicts the oldest transitions")
    func entryCapEvictsOldest() throws {
        var history = TextMergeEditHistory(
            initialDraft: draft("a"),
            limits: .init(
                maximumEntryCount: 2,
                maximumStoredUTF8ByteCount: 100,
                maximumStoredResolutionChangeCount: 10
            )
        )
        history.record(draft("ab"), action: .manualOutputEdit)
        history.record(draft("abc"), action: .manualOutputEdit)
        history.record(draft("abcd"), action: .manualOutputEdit)

        #expect(history.undoEntryCount == 2)
        let firstUndo = history.undo()
        #expect(try #require(firstUndo) == draft("abc"))
        let secondUndo = history.undo()
        #expect(try #require(secondUndo) == draft("ab"))
        let unavailableUndo = history.undo()
        #expect(unavailableUndo == nil)
    }

    @Test("Total UTF-8 budget is shared by undo and redo stacks")
    func totalUTF8BudgetIsBounded() throws {
        var history = TextMergeEditHistory(
            initialDraft: draft(""),
            limits: .init(
                maximumEntryCount: 10,
                maximumStoredUTF8ByteCount: 3,
                maximumStoredResolutionChangeCount: 10
            )
        )
        history.record(draft("a"), action: .manualOutputEdit)
        history.record(draft("ab"), action: .manualOutputEdit)
        history.record(draft("abc"), action: .manualOutputEdit)
        history.record(draft("abcd"), action: .manualOutputEdit)

        #expect(history.storedUTF8ByteCount == 3)
        #expect(history.undoEntryCount == 3)

        let firstUndo = history.undo()
        _ = try #require(firstUndo)
        let secondUndo = history.undo()
        _ = try #require(secondUndo)
        #expect(history.storedUTF8ByteCount == 3)
        #expect(history.undoEntryCount + history.redoEntryCount == 3)
    }

    @Test("One oversized text transition becomes current and resets history")
    func oversizedTextTransitionFailsSafe() {
        var history = TextMergeEditHistory(
            initialDraft: draft("base"),
            limits: .init(
                maximumEntryCount: 10,
                maximumStoredUTF8ByteCount: 3,
                maximumStoredResolutionChangeCount: 10
            )
        )
        history.record(draft("base!"), action: .manualOutputEdit)
        #expect(history.canUndo)

        let oversized = draft("a much larger replacement")
        #expect(
            history.record(oversized, action: .manualOutputEdit)
                == .historyResetOversized
        )
        #expect(history.currentDraft == oversized)
        #expect(!history.canUndo)
        #expect(!history.canRedo)
        #expect(history.storedUTF8ByteCount == 0)
    }

    @Test("Conflict resolution metadata has an independent total cap")
    func resolutionMetadataIsBounded() {
        let initial = TextMergeDraft(
            outputText: "same",
            resolutions: [0: .unresolved, 1: .unresolved]
        )
        let changed = TextMergeDraft(
            outputText: "same",
            resolutions: [0: .left, 1: .right]
        )
        var history = TextMergeEditHistory(
            initialDraft: initial,
            limits: .init(
                maximumEntryCount: 10,
                maximumStoredUTF8ByteCount: 100,
                maximumStoredResolutionChangeCount: 1
            )
        )

        #expect(
            history.record(changed, action: .conflictResolution(conflictID: 0))
                == .historyResetOversized
        )
        #expect(history.currentDraft == changed)
        #expect(history.storedResolutionChangeCount == 0)
        #expect(!history.canUndo)
    }

    @Test("Reset and no-op recording have document-safe semantics")
    func resetAndNoOpSemantics() throws {
        var history = TextMergeEditHistory(initialDraft: draft("old"))
        history.record(draft("edited"), action: .manualOutputEdit)
        let undone = history.undo()
        _ = try #require(undone)
        #expect(history.canRedo)

        #expect(
            history.record(draft("old"), action: .manualOutputEdit)
                == .ignoredNoChange
        )
        #expect(history.canRedo)

        history.reset(to: draft("new document"))
        #expect(history.currentDraft == draft("new document"))
        #expect(!history.canUndo)
        #expect(!history.canRedo)
        #expect(history.storedUTF8ByteCount == 0)
    }

    @Test("Public maximum limits and retained counter overflow fail safely")
    func maximumLimitsDoNotTrap() throws {
        #expect(TextMergeEditHistory.checkedRetainedCount(Int.max, adding: 1) == nil)
        #expect(
            TextMergeEditHistory.checkedRetainedCount(Int.max - 1, adding: 1)
                == Int.max
        )

        var history = TextMergeEditHistory(
            initialDraft: draft("a"),
            limits: .init(
                maximumEntryCount: Int.max,
                maximumStoredUTF8ByteCount: Int.max,
                maximumStoredResolutionChangeCount: Int.max
            )
        )
        #expect(history.record(draft("ab"), action: .manualOutputEdit) == .recorded)
        let undone = history.undo()
        #expect(try #require(undone) == draft("a"))
        let redone = history.redo()
        #expect(try #require(redone) == draft("ab"))
    }

    private func draft(_ text: String) -> TextMergeDraft {
        TextMergeDraft(outputText: text, resolutions: [:])
    }
}
