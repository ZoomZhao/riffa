import Foundation

/// A choice for one structured conflict in an editable text-merge draft.
public enum TextMergeConflictResolution: String, CaseIterable, Identifiable, Codable, Sendable {
    case unresolved = "Unresolved"
    case left = "Left"
    case base = "Base"
    case right = "Right"

    public var id: Self { self }
}

/// The complete user-editable state of a text merge.
public struct TextMergeDraft: Equatable, Sendable {
    public var outputText: String
    public var resolutions: [Int: TextMergeConflictResolution]

    public init(
        outputText: String,
        resolutions: [Int: TextMergeConflictResolution]
    ) {
        self.outputText = outputText
        self.resolutions = resolutions
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.outputText.utf8.elementsEqual(rhs.outputText.utf8)
            && lhs.resolutions == rhs.resolutions
    }
}

/// The semantic operation represented by one text-merge history entry.
public enum TextMergeEditAction: Equatable, Sendable {
    case manualOutputEdit
    case conflictResolution(conflictID: Int)

    public var title: String {
        switch self {
        case .manualOutputEdit:
            "Edit Merged Output"
        case let .conflictResolution(conflictID):
            if conflictID == Int.max {
                "Resolve Conflict"
            } else {
                "Resolve Conflict \(conflictID + 1)"
            }
        }
    }
}

/// Hard limits for the memory retained in addition to the current draft.
///
/// Text is stored as removed/inserted spans, so `maximumStoredUTF8ByteCount`
/// applies to the sum of those spans across both the undo and redo stacks.
/// Conflict choices have their own count limit because a zero-byte text
/// change can still update resolution metadata.
public struct TextMergeEditHistoryLimits: Equatable, Sendable {
    public static let defaultMaximumEntryCount = 100
    public static let defaultMaximumStoredUTF8ByteCount = 16 * 1_024 * 1_024
    public static let defaultMaximumStoredResolutionChangeCount = 4_096

    public let maximumEntryCount: Int
    public let maximumStoredUTF8ByteCount: Int
    public let maximumStoredResolutionChangeCount: Int

    public init(
        maximumEntryCount: Int = Self.defaultMaximumEntryCount,
        maximumStoredUTF8ByteCount: Int = Self.defaultMaximumStoredUTF8ByteCount,
        maximumStoredResolutionChangeCount: Int = Self.defaultMaximumStoredResolutionChangeCount
    ) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumStoredUTF8ByteCount = max(1, maximumStoredUTF8ByteCount)
        self.maximumStoredResolutionChangeCount = max(
            1,
            maximumStoredResolutionChangeCount
        )
    }
}

public enum TextMergeEditHistoryRecordOutcome: Equatable, Sendable {
    case recorded
    case ignoredNoChange

    /// The edit became current, but its single delta exceeded a configured
    /// limit. Both stacks were cleared so no partial or misleading transition
    /// remains available.
    case historyResetOversized
}

/// Bounded, deterministic undo/redo history for editable text-merge output.
///
/// The current draft is not part of the history budget because the caller
/// already has to retain it to edit or save. Every additional retained byte
/// and conflict-choice delta is accounted for across both stacks.
public struct TextMergeEditHistory: Sendable {
    public let limits: TextMergeEditHistoryLimits
    public private(set) var currentDraft: TextMergeDraft

    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    private var retainedUTF8ByteCount = 0
    private var retainedResolutionChangeCount = 0

    public init(
        initialDraft: TextMergeDraft,
        limits: TextMergeEditHistoryLimits = .init()
    ) {
        self.currentDraft = initialDraft
        self.limits = limits
    }

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var undoEntryCount: Int { undoEntries.count }
    public var redoEntryCount: Int { redoEntries.count }
    public var storedUTF8ByteCount: Int { retainedUTF8ByteCount }
    public var storedResolutionChangeCount: Int { retainedResolutionChangeCount }
    public var nextUndoAction: TextMergeEditAction? { undoEntries.last?.action }
    public var nextRedoAction: TextMergeEditAction? { redoEntries.last?.action }

    static func checkedRetainedCount(_ current: Int, adding increment: Int) -> Int? {
        let (result, overflow) = current.addingReportingOverflow(increment)
        return overflow ? nil : result
    }

    /// Installs an edit and records one reversible transition when it fits.
    /// A new real edit always clears redo. An oversized transition is applied
    /// fail-safe but clears both stacks because it cannot be represented under
    /// the declared memory limits.
    @discardableResult
    public mutating func record(
        _ draft: TextMergeDraft,
        action: TextMergeEditAction
    ) -> TextMergeEditHistoryRecordOutcome {
        guard draft != currentDraft else { return .ignoredNoChange }

        guard let entry = Entry.make(
            before: currentDraft,
            after: draft,
            action: action,
            limits: limits
        ) else {
            currentDraft = draft
            removeAllEntries()
            return .historyResetOversized
        }

        removeRedoEntries()
        currentDraft = draft
        undoEntries.append(entry)
        guard addToRetainedCounts(entry) else {
            removeAllEntries()
            return .historyResetOversized
        }
        trimOldestUndoEntriesToLimits()
        return .recorded
    }

    /// Restores the complete prior draft, including conflict choices.
    /// If an internal invariant ever fails, no state is partially applied and
    /// the unusable history is discarded.
    @discardableResult
    public mutating func undo() -> TextMergeDraft? {
        guard let entry = undoEntries.last,
              let restored = entry.applying(to: currentDraft, forward: false) else {
            if !undoEntries.isEmpty { removeAllEntries() }
            return nil
        }

        undoEntries.removeLast()
        redoEntries.append(entry)
        currentDraft = restored
        return restored
    }

    /// Reapplies the next complete draft transition.
    @discardableResult
    public mutating func redo() -> TextMergeDraft? {
        guard let entry = redoEntries.last,
              let restored = entry.applying(to: currentDraft, forward: true) else {
            if !redoEntries.isEmpty { removeAllEntries() }
            return nil
        }

        redoEntries.removeLast()
        undoEntries.append(entry)
        currentDraft = restored
        return restored
    }

    /// Replaces the document baseline. Reloading or opening another input must
    /// never make edits from the previous document available for replay.
    public mutating func reset(to draft: TextMergeDraft) {
        currentDraft = draft
        removeAllEntries()
    }

    private mutating func trimOldestUndoEntriesToLimits() {
        while entryCountExceedsLimit
            || retainedUTF8ByteCount > limits.maximumStoredUTF8ByteCount
            || retainedResolutionChangeCount
                > limits.maximumStoredResolutionChangeCount
        {
            guard !undoEntries.isEmpty else {
                removeAllEntries()
                return
            }
            let removed = undoEntries.removeFirst()
            guard subtractFromRetainedCounts(removed) else {
                removeAllEntries()
                return
            }
        }
    }

    private var entryCountExceedsLimit: Bool {
        undoEntries.count > limits.maximumEntryCount
            || redoEntries.count > limits.maximumEntryCount
            || undoEntries.count > limits.maximumEntryCount - redoEntries.count
    }

    private mutating func removeRedoEntries() {
        for entry in redoEntries {
            guard subtractFromRetainedCounts(entry) else {
                removeAllEntries()
                return
            }
        }
        redoEntries.removeAll(keepingCapacity: true)
    }

    private mutating func removeAllEntries() {
        undoEntries.removeAll(keepingCapacity: true)
        redoEntries.removeAll(keepingCapacity: true)
        retainedUTF8ByteCount = 0
        retainedResolutionChangeCount = 0
    }

    private mutating func addToRetainedCounts(_ entry: Entry) -> Bool {
        guard let utf8ByteCount = Self.checkedRetainedCount(
            retainedUTF8ByteCount,
            adding: entry.storedUTF8ByteCount
        ),
        let resolutionCount = Self.checkedRetainedCount(
            retainedResolutionChangeCount,
            adding: entry.resolutionChanges.count
        ) else { return false }
        retainedUTF8ByteCount = utf8ByteCount
        retainedResolutionChangeCount = resolutionCount
        return true
    }

    private mutating func subtractFromRetainedCounts(_ entry: Entry) -> Bool {
        guard retainedUTF8ByteCount >= entry.storedUTF8ByteCount,
              retainedResolutionChangeCount >= entry.resolutionChanges.count else {
            return false
        }
        retainedUTF8ByteCount -= entry.storedUTF8ByteCount
        retainedResolutionChangeCount -= entry.resolutionChanges.count
        return true
    }
}

private extension TextMergeEditHistory {
    struct Entry: Sendable {
        let action: TextMergeEditAction
        let textReplacement: TextReplacement?
        let resolutionChanges: [ResolutionChange]
        let storedUTF8ByteCount: Int

        static func make(
            before: TextMergeDraft,
            after: TextMergeDraft,
            action: TextMergeEditAction,
            limits: TextMergeEditHistoryLimits
        ) -> Self? {
            let textReplacement: TextReplacement?
            let storedUTF8ByteCount: Int
            if before.outputText.utf8.elementsEqual(after.outputText.utf8) {
                textReplacement = nil
                storedUTF8ByteCount = 0
            } else {
                guard let replacement = TextReplacement.make(
                    before: before.outputText,
                    after: after.outputText,
                    maximumStoredUTF8ByteCount: limits.maximumStoredUTF8ByteCount
                ) else { return nil }
                textReplacement = replacement
                storedUTF8ByteCount = replacement.storedUTF8ByteCount
            }

            guard let resolutionChanges = ResolutionChange.makeAll(
                before: before.resolutions,
                after: after.resolutions,
                maximumCount: limits.maximumStoredResolutionChangeCount
            ) else { return nil }

            return Self(
                action: action,
                textReplacement: textReplacement,
                resolutionChanges: resolutionChanges,
                storedUTF8ByteCount: storedUTF8ByteCount
            )
        }

        func applying(to draft: TextMergeDraft, forward: Bool) -> TextMergeDraft? {
            for change in resolutionChanges {
                let expected = forward ? change.before : change.after
                guard draft.resolutions[change.conflictID] == expected else { return nil }
            }

            var restoredText = draft.outputText
            if let textReplacement {
                guard let replaced = textReplacement.applying(
                    to: restoredText,
                    forward: forward
                ) else { return nil }
                restoredText = replaced
            }

            var restoredResolutions = draft.resolutions
            for change in resolutionChanges {
                let replacement = forward ? change.after : change.before
                if let replacement {
                    restoredResolutions[change.conflictID] = replacement
                } else {
                    restoredResolutions.removeValue(forKey: change.conflictID)
                }
            }

            return TextMergeDraft(
                outputText: restoredText,
                resolutions: restoredResolutions
            )
        }
    }

    struct TextReplacement: Sendable {
        let prefixUnicodeScalarCount: Int
        let removedText: String
        let insertedText: String
        let removedUnicodeScalarCount: Int
        let insertedUnicodeScalarCount: Int
        let storedUTF8ByteCount: Int

        static func make(
            before: String,
            after: String,
            maximumStoredUTF8ByteCount: Int
        ) -> Self? {
            let beforeScalars = before.unicodeScalars
            let afterScalars = after.unicodeScalars
            var beforeStart = beforeScalars.startIndex
            var afterStart = afterScalars.startIndex
            var prefixUnicodeScalarCount = 0

            while beforeStart < beforeScalars.endIndex,
                  afterStart < afterScalars.endIndex,
                  beforeScalars[beforeStart] == afterScalars[afterStart] {
                beforeScalars.formIndex(after: &beforeStart)
                afterScalars.formIndex(after: &afterStart)
                prefixUnicodeScalarCount += 1
            }

            var beforeEnd = beforeScalars.endIndex
            var afterEnd = afterScalars.endIndex
            while beforeEnd > beforeStart, afterEnd > afterStart {
                let previousBefore = beforeScalars.index(before: beforeEnd)
                let previousAfter = afterScalars.index(before: afterEnd)
                guard beforeScalars[previousBefore] == afterScalars[previousAfter] else { break }
                beforeEnd = previousBefore
                afterEnd = previousAfter
            }

            let removedSlice = before[beforeStart..<beforeEnd]
            let insertedSlice = after[afterStart..<afterEnd]
            let removedUTF8ByteCount = removedSlice.utf8.count
            let insertedUTF8ByteCount = insertedSlice.utf8.count
            let (storedUTF8ByteCount, overflow) = removedUTF8ByteCount.addingReportingOverflow(
                insertedUTF8ByteCount
            )
            guard !overflow,
                  storedUTF8ByteCount <= maximumStoredUTF8ByteCount else { return nil }

            return Self(
                prefixUnicodeScalarCount: prefixUnicodeScalarCount,
                removedText: String(removedSlice),
                insertedText: String(insertedSlice),
                removedUnicodeScalarCount: removedSlice.unicodeScalars.count,
                insertedUnicodeScalarCount: insertedSlice.unicodeScalars.count,
                storedUTF8ByteCount: storedUTF8ByteCount
            )
        }

        func applying(to text: String, forward: Bool) -> String? {
            let expectedText = forward ? removedText : insertedText
            let expectedUnicodeScalarCount = forward
                ? removedUnicodeScalarCount
                : insertedUnicodeScalarCount
            let replacementText = forward ? insertedText : removedText
            let scalars = text.unicodeScalars

            guard let start = scalars.index(
                scalars.startIndex,
                offsetBy: prefixUnicodeScalarCount,
                limitedBy: scalars.endIndex
            ),
            let end = scalars.index(
                start,
                offsetBy: expectedUnicodeScalarCount,
                limitedBy: scalars.endIndex
            ),
            text[start..<end].utf8.elementsEqual(expectedText.utf8) else { return nil }

            var result = text
            result.replaceSubrange(start..<end, with: replacementText)
            return result
        }
    }

    struct ResolutionChange: Sendable {
        let conflictID: Int
        let before: TextMergeConflictResolution?
        let after: TextMergeConflictResolution?

        static func makeAll(
            before: [Int: TextMergeConflictResolution],
            after: [Int: TextMergeConflictResolution],
            maximumCount: Int
        ) -> [Self]? {
            var result: [Self] = []
            result.reserveCapacity(min(maximumCount, max(before.count, after.count)))

            for (conflictID, beforeValue) in before {
                let afterValue = after[conflictID]
                guard afterValue != beforeValue else { continue }
                guard result.count < maximumCount else { return nil }
                result.append(
                    Self(
                        conflictID: conflictID,
                        before: beforeValue,
                        after: afterValue
                    )
                )
            }

            for (conflictID, afterValue) in after where before[conflictID] == nil {
                guard result.count < maximumCount else { return nil }
                result.append(
                    Self(
                        conflictID: conflictID,
                        before: nil,
                        after: afterValue
                    )
                )
            }
            return result
        }
    }
}
