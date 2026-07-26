import Testing
@testable import RiffaCore

@Suite("Unified patch generation and application")
struct UnifiedPatchRoundTripTests {
    @Test("Generated patches parse and apply insertions, deletions, modifications, and Unicode")
    func generatedRoundTrip() throws {
        let left = TextDocument(
            text: "alpha\nremove me\ncafé 👩🏽‍💻\ntail\n"
        )
        let right = TextDocument(
            text: "alpha\ninserted\nCAFÉ 👩🏽‍💻\ntail\nextra 🌍\n"
        )
        let diff = TextDiffEngine().compare(left, to: right)
        let rendered = try UnifiedDiffGenerator(contextLineCount: 2).generate(
            from: diff,
            oldLabel: "a/sample.txt",
            newLabel: "b/sample.txt"
        )
        let patch = try UnifiedPatchParser().parse(rendered)
        let applied = try UnifiedPatchApplier().apply(patch, to: left)

        #expect(rendered.hasPrefix("--- a/sample.txt\n+++ b/sample.txt\n@@ "))
        #expect(patch.files.count == 1)
        #expect(patch.files[0].oldLabel == "a/sample.txt")
        #expect(patch.files[0].newLabel == "b/sample.txt")
        #expect(patch.files[0].hunks.flatMap(\.lines).contains { $0.kind == .deletion })
        #expect(patch.files[0].hunks.flatMap(\.lines).contains { $0.kind == .addition })
        #expect(applied.text == right.text)
    }

    @Test("Mixed LF, CRLF, CR, and missing final newline survive a round trip")
    func mixedLineEndings() throws {
        let left = TextDocument(text: "one\r\ntwo\rold\nfinal")
        let right = TextDocument(text: "one\r\nTWO\radded\nfinal!")
        let diff = TextDiffEngine().compare(left, to: right)
        let rendered = try UnifiedDiffGenerator(contextLineCount: 1).generate(
            from: diff,
            oldLabel: "left.txt",
            newLabel: "right.txt"
        )
        let patch = try UnifiedPatchParser().parse(rendered)
        let applied = try UnifiedPatchApplier().apply(patch.files[0], to: left)

        #expect(rendered.contains("\\ No newline at end of file"))
        #expect(applied.text == right.text)
        #expect(applied.lines.map(\.ending) == [.crlf, .cr, .lf, .none])
    }

    @Test("A line-ending-only edit is emitted and applied")
    func lineEndingOnlyChange() throws {
        let left = TextDocument(text: "value")
        let right = TextDocument(text: "value\r")
        let diff = TextDiffEngine().compare(left, to: right)
        let generated = try UnifiedDiffGenerator(contextLineCount: 0).patch(
            from: diff,
            oldLabel: "old",
            newLabel: "new"
        )
        let parsed = try UnifiedPatchParser().parse(generated.renderedText())
        let applied = try UnifiedPatchApplier().apply(parsed, to: left)

        #expect(generated.files[0].hunks[0].lines.map(\.kind) == [.deletion, .addition])
        #expect(applied.text == "value\r")
        #expect(applied.lines[0].ending == .cr)
    }

    @Test("Separated changes form multiple hunks and accumulated offsets stay correct")
    func multipleHunksAndOffsets() throws {
        let leftLines = (1...12).map { "line \($0)" }
        let rightLines = ["line 1", "inserted"]
            + (2...9).map { "line \($0)" }
            + ["line 11", "line 12"]
        let left = TextDocument(text: leftLines.joined(separator: "\n") + "\n")
        let right = TextDocument(text: rightLines.joined(separator: "\n") + "\n")
        let diff = TextDiffEngine().compare(left, to: right)
        let generated = try UnifiedDiffGenerator(contextLineCount: 1).patch(
            from: diff,
            oldLabel: "before",
            newLabel: "after"
        )

        #expect(generated.files[0].hunks.count == 2)

        let parsed = try UnifiedPatchParser().parse(generated.renderedText())
        let applied = try UnifiedPatchApplier().apply(parsed.files[0], to: left)
        #expect(applied.text == right.text)
    }

    @Test("Pure insertion and pure deletion use zero-count ranges")
    func emptyFileRanges() throws {
        let empty = TextDocument(text: "")
        let populated = TextDocument(text: "one\ntwo\n")

        let insertionDiff = TextDiffEngine().compare(empty, to: populated)
        let insertion = try UnifiedDiffGenerator(contextLineCount: 0).patch(
            from: insertionDiff,
            oldLabel: "/dev/null",
            newLabel: "new.txt"
        )
        #expect(insertion.files[0].hunks[0].oldRange == UnifiedPatchRange(start: 0, count: 0))
        #expect(try UnifiedPatchApplier().apply(insertion.files[0], to: empty).text == populated.text)

        let deletionDiff = TextDiffEngine().compare(populated, to: empty)
        let deletion = try UnifiedDiffGenerator(contextLineCount: 0).patch(
            from: deletionDiff,
            oldLabel: "old.txt",
            newLabel: "/dev/null"
        )
        #expect(deletion.files[0].hunks[0].newRange == UnifiedPatchRange(start: 0, count: 0))
        #expect(try UnifiedPatchApplier().apply(deletion.files[0], to: populated).text.isEmpty)
    }

    @Test("Identical inputs produce the standard empty patch")
    func identicalInputs() throws {
        let document = TextDocument(text: "same\n")
        let diff = TextDiffEngine().compare(document, to: document)
        let patch = try UnifiedDiffGenerator().patch(
            from: diff,
            oldLabel: "old",
            newLabel: "new"
        )

        #expect(patch.files.isEmpty)
        #expect(patch.renderedText().isEmpty)
        #expect(try UnifiedPatchParser().parse("").files.isEmpty)
    }
}

@Suite("Unified patch parsing")
struct UnifiedPatchParsingTests {
    @Test("Multiple file sections and omitted unit counts are parsed independently")
    func multipleFiles() throws {
        let text = """
        --- ../../labels/one.txt
        +++ renamed/one.txt
        @@ -1 +1 @@ heading
        -old
        +new
        --- two.txt
        +++ two-new.txt
        @@ -0,0 +1 @@
        +created
        """ + "\n"

        let patch = try UnifiedPatchParser().parse(text)

        #expect(patch.files.count == 2)
        #expect(patch.files.map(\.oldLabel) == ["../../labels/one.txt", "two.txt"])
        #expect(patch.files.map(\.newLabel) == ["renamed/one.txt", "two-new.txt"])
        #expect(patch.files[0].hunks[0].sectionHeading == "heading")
        #expect(patch.files[0].hunks[0].oldRange == UnifiedPatchRange(start: 1, count: 1))
        #expect(patch.files[1].hunks[0].oldRange == UnifiedPatchRange(start: 0, count: 0))

        let second = try UnifiedPatchApplier().apply(
            patch,
            fileIndex: 1,
            to: TextDocument(text: "")
        )
        #expect(second.text == "created\n")
    }

    @Test("No-final-newline markers update the preceding hunk lines")
    func noNewlineMarkers() throws {
        let text = """
        --- old
        +++ new
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """ + "\n"

        let patch = try UnifiedPatchParser().parse(text)
        let hunkLines = patch.files[0].hunks[0].lines
        let applied = try UnifiedPatchApplier().apply(
            patch.files[0],
            to: TextDocument(text: "old")
        )

        #expect(hunkLines.map(\.ending) == [.none, .none])
        #expect(applied.text == "new")
        #expect(!applied.hasTrailingLineEnding)
    }

    @Test("Header timestamps are not treated as filesystem paths")
    func headerTimestamps() throws {
        let text = """
        --- a/file.txt\t2026-07-19 01:00:00
        +++ b/file.txt\t2026-07-19 01:01:00
        @@ -1 +1 @@
        -a
        +b
        """ + "\n"
        let patch = try UnifiedPatchParser().parse(text)

        #expect(patch.files[0].oldLabel == "a/file.txt")
        #expect(patch.files[0].newLabel == "b/file.txt")
    }
}

@Suite("Unified patch validation")
struct UnifiedPatchValidationTests {
    @Test("Context mismatches report patch line and hunk without returning partial output")
    func contextMismatch() throws {
        let patch = try UnifiedPatchParser().parse(
            "--- old\n+++ new\n@@ -1,1 +1,1 @@\n expected\n"
        )
        let source = TextDocument(text: "actual\n")

        do {
            _ = try UnifiedPatchApplier().apply(patch.files[0], to: source)
            Issue.record("Expected context validation to fail")
        } catch let error as UnifiedPatchError {
            #expect(error.code == .contextMismatch)
            #expect(error.lineNumber == 4)
            #expect(error.fileIndex == 0)
            #expect(error.hunkIndex == 0)
            #expect(source.text == "actual\n")
        }
    }

    @Test("Deletion mismatches are distinguished from context mismatches")
    func deletionMismatch() throws {
        let patch = try UnifiedPatchParser().parse(
            "--- old\n+++ new\n@@ -1,1 +1,1 @@\n-wrong\n+new\n"
        )

        do {
            _ = try UnifiedPatchApplier().apply(
                patch.files[0],
                to: TextDocument(text: "actual\n")
            )
            Issue.record("Expected deletion validation to fail")
        } catch let error as UnifiedPatchError {
            #expect(error.code == .deletionMismatch)
            #expect(error.lineNumber == 4)
            #expect(error.hunkIndex == 0)
        }
    }

    @Test("Overlapping hunks are rejected during atomic application")
    func overlappingHunks() throws {
        let text = """
        --- old
        +++ new
        @@ -2,1 +2,1 @@
        -b
        +B
        @@ -2,1 +2,1 @@
        -b
        +C
        """ + "\n"
        let patch = try UnifiedPatchParser().parse(text)

        do {
            _ = try UnifiedPatchApplier().apply(
                patch.files[0],
                to: TextDocument(text: "a\nb\n")
            )
            Issue.record("Expected overlapping hunks to fail")
        } catch let error as UnifiedPatchError {
            #expect(error.code == .hunkOutOfOrder)
            #expect(error.lineNumber == 6)
            #expect(error.hunkIndex == 1)
        }
    }

    @Test("A no-newline marker cannot create a non-final unterminated line")
    func invalidNoNewlinePlacement() throws {
        let text = """
        --- old
        +++ new
        @@ -1,1 +1,2 @@
        +prefix
        \\ No newline at end of file
         old
        """ + "\n"
        let patch = try UnifiedPatchParser().parse(text)

        do {
            _ = try UnifiedPatchApplier().apply(
                patch.files[0],
                to: TextDocument(text: "old\n")
            )
            Issue.record("Expected invalid line-ending placement to fail")
        } catch let error as UnifiedPatchError {
            #expect(error.code == .invalidLineEndingPlacement)
            #expect(error.hunkIndex == 0)
        }
    }

    @Test("Malformed counts, orphan markers, and invalid zero starts are rejected")
    func malformedInputs() {
        let cases: [(String, UnifiedPatchErrorCode)] = [
            (
                "--- a\n+++ b\n@@ -1,2 +1,1 @@\n-a\n+b\n",
                .countMismatch
            ),
            (
                "--- a\n+++ b\n@@ -0,0 +0,0 @@\n\\ No newline at end of file\n",
                .orphanNoNewlineMarker
            ),
            (
                "--- a\n+++ b\n@@ -0,1 +1,1 @@\n-a\n+b\n",
                .malformedHunkHeader
            ),
            (
                "--- a\n+++ b\n@@ -1,1 +1,1 @@\n?a\n",
                .malformedHunkLine
            )
        ]

        for (text, expectedCode) in cases {
            do {
                _ = try UnifiedPatchParser().parse(text)
                Issue.record("Expected malformed patch to fail with \(expectedCode)")
            } catch let error as UnifiedPatchError {
                #expect(error.code == expectedCode)
                #expect(error.lineNumber != nil)
                #expect(error.hunkIndex == 0)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test("Overflowing and configured-over-limit ranges are rejected before allocation")
    func maliciousCounts() {
        let huge = "--- a\n+++ b\n@@ -1,999999999999999999999999 +1,0 @@\n"
        let overLimit = "--- a\n+++ b\n@@ -1,101 +1,0 @@\n"

        for (parser, text) in [
            (UnifiedPatchParser(), huge),
            (UnifiedPatchParser(maximumLineCount: 100), overLimit)
        ] {
            do {
                _ = try parser.parse(text)
                Issue.record("Expected oversized hunk range to fail")
            } catch let error as UnifiedPatchError {
                #expect(error.code == .countOverflow)
                #expect(error.lineNumber == 3)
                #expect(error.hunkIndex == 0)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test("The parser rejects actual LF CRLF and CR line counts before line allocation")
    func actualInputLineLimit() {
        let inputs = [
            String(repeating: "+\n", count: 101),
            String(repeating: "+\r\n", count: 101),
            String(repeating: "+\r", count: 101),
            String(repeating: "+\n", count: 100) + "+unterminated",
        ]

        for input in inputs {
            do {
                _ = try UnifiedPatchParser(maximumLineCount: 100).parse(input)
                Issue.record("Expected the physical patch line budget to fail")
            } catch let error as UnifiedPatchError {
                #expect(error.code == .countOverflow)
                #expect(error.lineNumber == nil)
                #expect(error.fileIndex == nil)
                #expect(error.hunkIndex == nil)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }

        #expect(throws: Never.self) {
            _ = try UnifiedPatchParser(maximumLineCount: 1).parse("")
        }
        #expect(throws: Never.self) {
            let parsed = try UnifiedPatchParser(maximumLineCount: 2).parse(
                "--- a\r\n+++ b\r\n"
            )
            #expect(parsed.files.count == 1)
        }
        #expect(throws: Never.self) {
            let parsed = try UnifiedPatchParser(maximumLineCount: 2).parse(
                "--- a\n+++ b"
            )
            #expect(parsed.files.count == 1)
        }

        do {
            _ = try UnifiedPatchParser(
                maximumLineCount: 10,
                maximumLineUTF8ByteCount: 5
            ).parse("--- abcdef\n+++ b\n")
            Issue.record("Expected the per-line UTF-8 byte budget to fail")
        } catch let error as UnifiedPatchError {
            #expect(error.code == .countOverflow)
            #expect(error.lineNumber == nil)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Generator labels cannot inject patch syntax")
    func invalidLabels() {
        let document = TextDocument(text: "a\n")
        let changed = TextDocument(text: "b\n")
        let diff = TextDiffEngine().compare(document, to: changed)

        do {
            _ = try UnifiedDiffGenerator().generate(
                from: diff,
                oldLabel: "safe",
                newLabel: "bad\n+++ injected"
            )
            Issue.record("Expected injected label to fail")
        } catch let error as UnifiedPatchError {
            #expect(error.code == .invalidLabel)
            #expect(error.lineNumber == nil)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Public patch models satisfy strict Sendable constraints")
    func sendableModels() {
        func requireSendable<T: Sendable>(_: T.Type) {}

        requireSendable(UnifiedPatchError.self)
        requireSendable(UnifiedPatchRange.self)
        requireSendable(UnifiedPatchLine.self)
        requireSendable(UnifiedPatchHunk.self)
        requireSendable(UnifiedPatchFile.self)
        requireSendable(UnifiedPatch.self)
        requireSendable(UnifiedDiffGenerator.self)
        requireSendable(UnifiedPatchParser.self)
        requireSendable(UnifiedPatchApplier.self)
    }
}
