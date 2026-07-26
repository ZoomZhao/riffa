import Testing
@testable import RiffaCore

@Suite("Text document parsing")
struct TextDocumentTests {
    @Test("Empty input remains distinct from a blank terminated line")
    func preservesEmptyInput() {
        let empty = TextDocument(text: "")
        let blankLine = TextDocument(text: "\n")

        #expect(empty.lines.isEmpty)
        #expect(empty.text == "")
        #expect(!empty.hasTrailingLineEnding)
        #expect(blankLine.lines == [TextLine(content: "", ending: .lf)])
        #expect(blankLine.text == "\n")
        #expect(blankLine.hasTrailingLineEnding)
    }

    @Test("Mixed line endings and Unicode round-trip exactly")
    func preservesLineEndingsAndUnicode() {
        let source = "第一行\r\n café 👩🏽‍💻\nlast"
        let document = TextDocument(text: source)

        #expect(document.lines.map(\.content) == ["第一行", " café 👩🏽‍💻", "last"])
        #expect(document.lines.map(\.ending) == [.crlf, .lf, .none])
        #expect(document.text == source)
        #expect(document.preferredLineEnding == .crlf)
    }

    @Test("A final line remembers whether it was terminated")
    func preservesTrailingNewline() {
        let terminated = TextDocument(text: "one\n")
        let unterminated = TextDocument(text: "one")

        #expect(terminated.lines == [TextLine(content: "one", ending: .lf)])
        #expect(unterminated.lines == [TextLine(content: "one", ending: .none)])
        #expect(terminated.hasTrailingLineEnding)
        #expect(!unterminated.hasTrailingLineEnding)
    }
}

@Suite("Two-way text diff")
struct TextDiffEngineTests {
    private let engine = TextDiffEngine(options: TextDiffOptions(contextLineCount: 0))

    @Test("Identical and empty documents produce no hunks")
    func identicalDocuments() {
        let emptyResult = engine.compare(TextDocument(text: ""), to: TextDocument(text: ""))
        let textResult = engine.compare(
            TextDocument(text: "alpha\nbeta\n"),
            to: TextDocument(text: "alpha\nbeta\n")
        )

        #expect(!emptyResult.hasDifferences)
        #expect(emptyResult.alignedLines.isEmpty)
        #expect(emptyResult.hunks.isEmpty)
        #expect(!textResult.hasDifferences)
        #expect(textResult.alignedLines.map(\.kind) == [.unchanged, .unchanged])
        #expect(textResult.hunks.isEmpty)
    }

    @Test("An inserted line is aligned against an empty left slot")
    func insertion() {
        let result = engine.compare(
            TextDocument(text: "alpha\nomega"),
            to: TextDocument(text: "alpha\nbeta\nomega")
        )

        #expect(result.alignedLines.map(\.kind) == [.unchanged, .inserted, .unchanged])
        #expect(result.alignedLines[1].left == nil)
        #expect(result.alignedLines[1].right?.line.content == "beta")
        #expect(result.statistics.insertedLineCount == 1)
        #expect(result.hunks.count == 1)
        #expect(result.hunks[0].leftRange == DiffLineRange(start: 1, count: 0))
        #expect(result.hunks[0].rightRange == DiffLineRange(start: 1, count: 1))
    }

    @Test("A deleted line is aligned against an empty right slot")
    func deletion() {
        let result = engine.compare(
            TextDocument(text: "alpha\nbeta\nomega"),
            to: TextDocument(text: "alpha\nomega")
        )

        #expect(result.alignedLines.map(\.kind) == [.unchanged, .deleted, .unchanged])
        #expect(result.alignedLines[1].left?.line.content == "beta")
        #expect(result.alignedLines[1].right == nil)
        #expect(result.statistics.deletedLineCount == 1)
        #expect(result.hunks.count == 1)
    }

    @Test("A replacement includes token-level character ranges")
    func replacementAndInlineTokens() {
        let result = engine.compare(
            TextDocument(text: "hello brave world"),
            to: TextDocument(text: "hello bold world")
        )

        #expect(result.alignedLines.map(\.kind) == [.modified])
        #expect(result.statistics.modifiedLineCount == 1)
        #expect(result.alignedLines[0].inlineDifferences == [
            InlineDifference(
                kind: .modified,
                leftRange: TextCharacterRange(offset: 6, length: 5),
                rightRange: TextCharacterRange(offset: 6, length: 4)
            )
        ])
    }

    @Test("Repeated equal lines remain useful alignment anchors")
    func repeatedLines() {
        let result = engine.compare(
            TextDocument(text: "same\nold\nsame\ntail"),
            to: TextDocument(text: "same\nnew\nsame\ntail")
        )

        #expect(result.alignedLines.map(\.kind) == [
            .unchanged, .modified, .unchanged, .unchanged
        ])
        #expect(result.alignedLines[1].left?.lineNumber == 2)
        #expect(result.alignedLines[1].right?.lineNumber == 2)
    }

    @Test("Case and whitespace can be ignored independently")
    func comparisonOptions() {
        let exact = TextDiffEngine(
            options: TextDiffOptions(contextLineCount: 0)
        ).compare(
            TextDocument(text: "Alpha  Beta"),
            to: TextDocument(text: "alphaBeta")
        )
        let relaxed = TextDiffEngine(
            options: TextDiffOptions(
                ignoreCase: true,
                ignoreWhitespace: true,
                contextLineCount: 0
            )
        ).compare(
            TextDocument(text: "Alpha  Beta"),
            to: TextDocument(text: "alphaBeta")
        )

        #expect(exact.hasDifferences)
        #expect(!relaxed.hasDifferences)
        #expect(relaxed.alignedLines.map(\.kind) == [.unchanged])
    }

    @Test("Unicode grapheme offsets are stable in inline differences")
    func unicodeInlineDifference() {
        let result = engine.compare(
            TextDocument(text: "👩🏽‍💻 likes 茶"),
            to: TextDocument(text: "👩🏽‍💻 likes 咖啡")
        )

        #expect(result.alignedLines[0].kind == .modified)
        #expect(result.alignedLines[0].inlineDifferences == [
            InlineDifference(
                kind: .modified,
                leftRange: TextCharacterRange(offset: 8, length: 1),
                rightRange: TextCharacterRange(offset: 8, length: 2)
            )
        ])
    }

    @Test("Line-ending style is optional, but trailing termination is significant")
    func lineEndingRules() {
        let defaultEngine = TextDiffEngine(
            options: TextDiffOptions(contextLineCount: 0)
        )
        let exactEndingsEngine = TextDiffEngine(
            options: TextDiffOptions(
                ignoreLineEndingStyle: false,
                contextLineCount: 0
            )
        )

        let styleIgnored = defaultEngine.compare(
            TextDocument(text: "a\r\n"),
            to: TextDocument(text: "a\n")
        )
        let styleCompared = exactEndingsEngine.compare(
            TextDocument(text: "a\r\n"),
            to: TextDocument(text: "a\n")
        )
        let trailingCompared = defaultEngine.compare(
            TextDocument(text: "a\n"),
            to: TextDocument(text: "a")
        )

        #expect(!styleIgnored.hasDifferences)
        #expect(styleIgnored.alignedLines[0].hasLineEndingDifference)
        #expect(styleCompared.alignedLines[0].kind == .modified)
        #expect(styleCompared.alignedLines[0].hasLineEndingDifference)
        #expect(trailingCompared.alignedLines[0].kind == .modified)
        #expect(trailingCompared.alignedLines[0].inlineDifferences.isEmpty)
    }

    @Test("Configured context creates separated hunks")
    func hunkContext() {
        let contextEngine = TextDiffEngine(
            options: TextDiffOptions(contextLineCount: 1)
        )
        let result = contextEngine.compare(
            TextDocument(text: "a\nb\nc\nd\ne\nf\ng"),
            to: TextDocument(text: "a\nB\nc\nd\ne\nF\ng")
        )

        #expect(result.hunks.count == 2)
        #expect(result.hunks[0].alignedRange == DiffLineRange(start: 0, count: 3))
        #expect(result.hunks[1].alignedRange == DiffLineRange(start: 4, count: 3))
    }
}
