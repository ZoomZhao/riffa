/// The line terminator that followed a logical line in the source document.
///
/// `.none` is significant: it distinguishes a final unterminated line from a
/// line that ended with a newline.
public enum TextLineEnding: String, CaseIterable, Hashable, Sendable {
    case none = ""
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"

    public var isTerminated: Bool {
        self != .none
    }
}

/// One logical line, retaining the exact terminator found in the source.
public struct TextLine: Hashable, Sendable {
    public let content: String
    public let ending: TextLineEnding

    public init(content: String, ending: TextLineEnding) {
        self.content = content
        self.ending = ending
    }

    public var sourceText: String {
        content + ending.rawValue
    }
}

/// The line-matching strategy used by ``TextDiffEngine``.
public enum TextDiffAlgorithm: Hashable, Sendable {
    /// Uses `CollectionDifference` for budgeted small regions and Patience
    /// diff for larger inputs.
    case automatic

    /// Uses Swift's Myers-style `CollectionDifference` when the requested
    /// region fits the exact-diff budget. Oversized regions fail closed to a
    /// deterministic coarse replacement.
    case collectionDifference

    /// Uses unique common lines and a longest-increasing subsequence as
    /// anchors, with exact diff restricted to budgeted subregions.
    case patience

    /// A familiar name for Swift's `CollectionDifference` strategy.
    public static var myers: Self { .collectionDifference }
}

/// Explicit work limits for a text comparison.
///
/// Values below zero are normalized to zero. A zero budget disables that
/// class of expensive work; it never means "unlimited". The comparison API is
/// intentionally non-throwing, so oversized inputs degrade to stable coarse
/// changes instead of bypassing a budget or failing the process.
public struct TextDiffLimits: Hashable, Sendable {
    /// Maximum combined line count eligible for line matching beyond common
    /// prefix and suffix detection.
    public let maximumTotalLineCount: Int

    /// Maximum `leftLineCount * rightLineCount` for one exact
    /// `CollectionDifference` region. Overflow is treated as over budget.
    public let maximumExactRegionCost: Int

    /// Maximum combined token count eligible for token-level inline diff.
    public let maximumInlineTokenCount: Int

    /// Maximum combined grapheme count eligible for tokenization. This also
    /// bounds the cost of a single very long word, which is only one token.
    public let maximumInlineCharacterCount: Int

    /// Maximum number of non-empty Patience subregions examined.
    public let maximumPatienceWorkItemCount: Int

    /// Maximum nesting depth of Patience subregions.
    public let maximumPatienceDepth: Int

    public init(
        maximumTotalLineCount: Int = 500_000,
        maximumExactRegionCost: Int = 4_000_000,
        maximumInlineTokenCount: Int = 4_096,
        maximumInlineCharacterCount: Int = 65_536,
        maximumPatienceWorkItemCount: Int = 65_536,
        maximumPatienceDepth: Int = 64
    ) {
        self.maximumTotalLineCount = max(0, maximumTotalLineCount)
        self.maximumExactRegionCost = max(0, maximumExactRegionCost)
        self.maximumInlineTokenCount = max(0, maximumInlineTokenCount)
        self.maximumInlineCharacterCount = max(0, maximumInlineCharacterCount)
        self.maximumPatienceWorkItemCount = max(0, maximumPatienceWorkItemCount)
        self.maximumPatienceDepth = max(0, maximumPatienceDepth)
    }
}

/// User-controlled rules for a two-way text comparison.
public struct TextDiffOptions: Hashable, Sendable {
    public var ignoreCase: Bool
    public var ignoreWhitespace: Bool

    /// When enabled, LF, CRLF, and CR are equivalent, while the presence or
    /// absence of a final line terminator remains significant.
    public var ignoreLineEndingStyle: Bool

    /// The number of unchanged lines included around each change in a hunk.
    public var contextLineCount: Int

    public var algorithm: TextDiffAlgorithm
    public var limits: TextDiffLimits

    public init(
        ignoreCase: Bool = false,
        ignoreWhitespace: Bool = false,
        ignoreLineEndingStyle: Bool = true,
        contextLineCount: Int = 3,
        algorithm: TextDiffAlgorithm = .automatic,
        limits: TextDiffLimits = TextDiffLimits()
    ) {
        self.ignoreCase = ignoreCase
        self.ignoreWhitespace = ignoreWhitespace
        self.ignoreLineEndingStyle = ignoreLineEndingStyle
        self.contextLineCount = max(0, contextLineCount)
        self.algorithm = algorithm
        self.limits = limits
    }
}

public enum DiffLineKind: Hashable, Sendable {
    case unchanged
    case inserted
    case deleted
    case modified
}

/// A line and its one-based location within one side of a comparison.
public struct DiffLineValue: Hashable, Sendable {
    public let lineNumber: Int
    public let line: TextLine

    public init(lineNumber: Int, line: TextLine) {
        self.lineNumber = lineNumber
        self.line = line
    }
}

/// A range measured in extended grapheme clusters (`Character` values).
public struct TextCharacterRange: Hashable, Sendable {
    public let offset: Int
    public let length: Int

    public init(offset: Int, length: Int) {
        self.offset = offset
        self.length = length
    }

    public var endOffset: Int {
        offset + length
    }
}

public enum InlineDifferenceKind: Hashable, Sendable {
    case inserted
    case deleted
    case modified
}

/// A token-level change within a paired, modified line.
///
/// A missing range means that the token run exists only on the other side.
public struct InlineDifference: Hashable, Sendable {
    public let kind: InlineDifferenceKind
    public let leftRange: TextCharacterRange?
    public let rightRange: TextCharacterRange?

    public init(
        kind: InlineDifferenceKind,
        leftRange: TextCharacterRange?,
        rightRange: TextCharacterRange?
    ) {
        self.kind = kind
        self.leftRange = leftRange
        self.rightRange = rightRange
    }
}

/// One display row in the fully aligned two-way comparison.
public struct AlignedDiffLine: Hashable, Sendable {
    public let offset: Int
    public let kind: DiffLineKind
    public let left: DiffLineValue?
    public let right: DiffLineValue?
    public let inlineDifferences: [InlineDifference]
    public let hasLineEndingDifference: Bool

    public init(
        offset: Int,
        kind: DiffLineKind,
        left: DiffLineValue?,
        right: DiffLineValue?,
        inlineDifferences: [InlineDifference] = [],
        hasLineEndingDifference: Bool = false
    ) {
        self.offset = offset
        self.kind = kind
        self.left = left
        self.right = right
        self.inlineDifferences = inlineDifferences
        self.hasLineEndingDifference = hasLineEndingDifference
    }
}

/// A zero-based half-open line range represented without non-Sendable indices.
public struct DiffLineRange: Hashable, Sendable {
    public let start: Int
    public let count: Int

    public init(start: Int, count: Int) {
        self.start = start
        self.count = count
    }

    public var end: Int {
        start + count
    }
}

/// A run of changes plus the configured surrounding context.
public struct DiffHunk: Hashable, Sendable {
    public let index: Int
    public let alignedRange: DiffLineRange
    public let leftRange: DiffLineRange
    public let rightRange: DiffLineRange
    public let lines: [AlignedDiffLine]

    public init(
        index: Int,
        alignedRange: DiffLineRange,
        leftRange: DiffLineRange,
        rightRange: DiffLineRange,
        lines: [AlignedDiffLine]
    ) {
        self.index = index
        self.alignedRange = alignedRange
        self.leftRange = leftRange
        self.rightRange = rightRange
        self.lines = lines
    }
}

public struct TextDiffStatistics: Hashable, Sendable {
    public let unchangedLineCount: Int
    public let insertedLineCount: Int
    public let deletedLineCount: Int
    public let modifiedLineCount: Int

    public init(
        unchangedLineCount: Int,
        insertedLineCount: Int,
        deletedLineCount: Int,
        modifiedLineCount: Int
    ) {
        self.unchangedLineCount = unchangedLineCount
        self.insertedLineCount = insertedLineCount
        self.deletedLineCount = deletedLineCount
        self.modifiedLineCount = modifiedLineCount
    }

    public var changedLineCount: Int {
        insertedLineCount + deletedLineCount + modifiedLineCount
    }
}

public struct TextDiffResult: Hashable, Sendable {
    public let alignedLines: [AlignedDiffLine]
    public let hunks: [DiffHunk]
    public let statistics: TextDiffStatistics

    public init(
        alignedLines: [AlignedDiffLine],
        hunks: [DiffHunk],
        statistics: TextDiffStatistics
    ) {
        self.alignedLines = alignedLines
        self.hunks = hunks
        self.statistics = statistics
    }

    public var hasDifferences: Bool {
        statistics.changedLineCount > 0
    }
}
