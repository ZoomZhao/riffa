import Testing
@testable import RiffaCore

@Suite("Bounded text diff algorithms")
struct TextDiffBudgetTests {
    @Test("Automatic preserves CollectionDifference results for small inputs")
    func smallInputCompatibility() {
        let samples = [
            ("", "only"),
            ("only", ""),
            ("alpha\nbeta\nomega", "alpha\nnew\nomega"),
            ("same\nold\nsame\ntail", "same\nnew\nsame\ntail"),
            ("a\nb\nc", "a\nx\ny\nc"),
            ("first\nsecond", "zero\nfirst\nsecond")
        ]
        let automatic = TextDiffEngine(
            options: TextDiffOptions(contextLineCount: 0, algorithm: .automatic)
        )
        let exact = TextDiffEngine(
            options: TextDiffOptions(
                contextLineCount: 0,
                algorithm: .collectionDifference
            )
        )

        for (left, right) in samples {
            #expect(
                automatic.compare(TextDocument(text: left), to: TextDocument(text: right))
                    == exact.compare(TextDocument(text: left), to: TextDocument(text: right))
            )
        }
        #expect(TextDiffAlgorithm.myers == .collectionDifference)
    }

    @Test("Patience uses a deterministic subsequence for moved unique lines")
    func patienceMovement() {
        let engine = TextDiffEngine(
            options: TextDiffOptions(contextLineCount: 0, algorithm: .patience)
        )
        let result = engine.compare(
            TextDocument(text: "a\nb\nc\nd"),
            to: TextDocument(text: "b\na\nc\nd")
        )

        #expect(result.alignedLines.map(\.kind) == [
            .deleted, .unchanged, .inserted, .unchanged, .unchanged
        ])
        #expect(result.alignedLines[1].left?.line.content == "b")
        #expect(result.alignedLines[1].right?.line.content == "b")
    }

    @Test("Patience handles repeated and anchor-free regions")
    func patienceRepeatedAndAnchorFree() {
        let exactFallback = TextDiffEngine(
            options: TextDiffOptions(contextLineCount: 0, algorithm: .patience)
        ).compare(
            TextDocument(text: "same\nleft\nsame"),
            to: TextDocument(text: "same\nright\nsame")
        )
        #expect(exactFallback.alignedLines.map(\.kind) == [
            .unchanged, .modified, .unchanged
        ])

        let coarseFallback = TextDiffEngine(
            options: TextDiffOptions(
                contextLineCount: 0,
                algorithm: .patience,
                limits: TextDiffLimits(maximumExactRegionCost: 0)
            )
        ).compare(
            TextDocument(text: "repeat\nrepeat\nrepeat"),
            to: TextDocument(text: "other\nother\nother")
        )
        #expect(coarseFallback.alignedLines.map(\.kind) == [
            .modified, .modified, .modified
        ])
    }

    @Test("Oversized inline changes become displayable whole-line ranges")
    func oversizedInlineDifference() {
        let limits = TextDiffLimits(
            maximumInlineTokenCount: 8,
            maximumInlineCharacterCount: 32
        )
        let result = TextDiffEngine(
            options: TextDiffOptions(
                contextLineCount: 0,
                algorithm: .automatic,
                limits: limits
            )
        ).compare(
            TextDocument(text: String(repeating: "a", count: 10_000)),
            to: TextDocument(text: String(repeating: "b", count: 12_000))
        )

        #expect(result.alignedLines.map(\.kind) == [.modified])
        #expect(result.alignedLines[0].inlineDifferences == [
            InlineDifference(
                kind: .modified,
                leftRange: TextCharacterRange(offset: 0, length: 10_000),
                rightRange: TextCharacterRange(offset: 0, length: 12_000)
            )
        ])
    }

    @Test("Negative budgets normalize to disabled work")
    func invalidBudgetsFailClosed() {
        let limits = TextDiffLimits(
            maximumTotalLineCount: -1,
            maximumExactRegionCost: -1,
            maximumInlineTokenCount: -1,
            maximumInlineCharacterCount: -1,
            maximumPatienceWorkItemCount: -1,
            maximumPatienceDepth: -1
        )

        #expect(limits.maximumTotalLineCount == 0)
        #expect(limits.maximumExactRegionCost == 0)
        #expect(limits.maximumInlineTokenCount == 0)
        #expect(limits.maximumInlineCharacterCount == 0)
        #expect(limits.maximumPatienceWorkItemCount == 0)
        #expect(limits.maximumPatienceDepth == 0)

        let result = TextDiffEngine(
            options: TextDiffOptions(
                contextLineCount: 0,
                algorithm: .collectionDifference,
                limits: limits
            )
        ).compare(
            TextDocument(text: "prefix\nleft\nsuffix"),
            to: TextDocument(text: "prefix\nright\nsuffix")
        )
        #expect(result.alignedLines.map(\.kind) == [
            .unchanged, .modified, .unchanged
        ])
        #expect(result.alignedLines[1].inlineDifferences == [
            InlineDifference(
                kind: .modified,
                leftRange: TextCharacterRange(offset: 0, length: 4),
                rightRange: TextCharacterRange(offset: 0, length: 5)
            )
        ])
    }

    @Test("A comparison is deterministic across repeated Patience runs")
    func deterministic() {
        let engine = TextDiffEngine(
            options: TextDiffOptions(
                contextLineCount: 2,
                algorithm: .patience,
                limits: TextDiffLimits(maximumExactRegionCost: 4)
            )
        )
        let left = TextDocument(text: "u\na\nr\nb\nr\nc\nz")
        let right = TextDocument(text: "u\nb\nr\na\nr\nc\nz")
        let expected = engine.compare(left, to: right)

        for _ in 0..<10 {
            #expect(engine.compare(left, to: right) == expected)
        }
    }

    @Test("Automatic comparison remains bounded above one hundred thousand lines")
    func largeInputStress() {
        let lineCount = 100_001
        let split = lineCount / 2
        let prefix = makeTextLines(0..<split)
        let suffix = makeTextLines(split..<lineCount)
        let left = TextDocument(text: prefix + "\n" + suffix)
        let right = TextDocument(text: prefix + "\ninserted-middle\n" + suffix)
        let engine = TextDiffEngine(
            options: TextDiffOptions(contextLineCount: 0, algorithm: .automatic)
        )

        let result = engine.compare(left, to: right)

        #expect(result.alignedLines.count == lineCount + 1)
        #expect(result.statistics.unchangedLineCount == lineCount)
        #expect(result.statistics.insertedLineCount == 1)
        #expect(result.statistics.deletedLineCount == 0)
        #expect(result.alignedLines[split].kind == .inserted)
    }

    @Test("Public algorithm and budget values are Sendable")
    func publicValuesAreSendable() {
        requireSendable(TextDiffAlgorithm.automatic)
        requireSendable(TextDiffAlgorithm.collectionDifference)
        requireSendable(TextDiffAlgorithm.patience)
        requireSendable(TextDiffLimits())
        requireSendable(TextDiffOptions())
        requireSendable(TextDiffEngine())
    }

    private func makeTextLines(_ range: Range<Int>) -> String {
        var text = ""
        text.reserveCapacity(range.count * 12)
        for offset in range {
            if !text.isEmpty {
                text.append("\n")
            }
            text.append("row-")
            text.append(String(offset))
        }
        return text
    }

    private func requireSendable<Value: Sendable>(_ value: Value) {
        _ = value
    }
}
