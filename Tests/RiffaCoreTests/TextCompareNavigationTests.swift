import Foundation
import Testing
@testable import RiffaCore

@Suite("Text Compare bookmarks and overview navigation")
struct TextCompareNavigationTests {
    @Test("Bookmarks toggle by side and logical line without accepting invalid input")
    func toggleAndLimits() {
        let document = TextDocument(text: "alpha\nbeta\ngamma")
        var bookmarks = TextBookmarkCollection(
            limits: TextBookmarkLimits(maximumBookmarkCount: 1)
        )

        let first = bookmarks.toggle(side: .left, lineNumber: 2, in: document)
        guard case let .added(bookmark) = first else {
            Issue.record("Expected a bookmark to be added")
            return
        }
        #expect(bookmark.side == .left)
        #expect(bookmark.lineNumber == 2)
        #expect(bookmark.preview == "beta")
        #expect(bookmarks.bookmark(side: .left, lineNumber: 2)?.id == bookmark.id)
        #expect(
            bookmarks.toggle(side: .right, lineNumber: 1, in: document)
                == .limitReached(1)
        )
        #expect(
            bookmarks.toggle(side: .left, lineNumber: 0, in: document)
                == .invalidLine
        )
        #expect(
            bookmarks.toggle(side: .left, lineNumber: Int.min, in: document)
                == .invalidLine
        )

        #expect(
            bookmarks.toggle(side: .left, lineNumber: 2, in: document)
                == .removed(bookmark)
        )
        #expect(bookmarks.bookmarks.isEmpty)
    }

    @Test("Insertion before an anchored line rebinds with the same identity")
    func stableRebinding() {
        let original = TextDocument(text: "alpha\nbeta\ngamma\nomega")
        var bookmarks = TextBookmarkCollection()
        guard case let .added(added) = bookmarks.toggle(
            side: .right,
            lineNumber: 3,
            in: original
        ) else {
            Issue.record("Expected a bookmark to be added")
            return
        }

        let result = bookmarks.rebind(
            side: .right,
            to: TextDocument(text: "new\nalpha\nbeta\ngamma\nomega")
        )

        #expect(result.discardedIDs.isEmpty)
        #expect(result.reboundCount == 1)
        #expect(bookmarks.bookmarks.count == 1)
        #expect(bookmarks.bookmarks[0].id == added.id)
        #expect(bookmarks.bookmarks[0].side == .right)
        #expect(bookmarks.bookmarks[0].lineNumber == 4)
        #expect(bookmarks.bookmarks[0].preview == "gamma")
    }

    @Test("Changed or ambiguous anchors are discarded conservatively")
    func conservativeDiscard() {
        let original = TextDocument(text: "before\ntarget\nafter")
        var changed = TextBookmarkCollection()
        guard case let .added(changedBookmark) = changed.toggle(
            side: .left,
            lineNumber: 2,
            in: original
        ) else {
            Issue.record("Expected a bookmark to be added")
            return
        }

        let changedResult = changed.rebind(
            side: .left,
            to: TextDocument(text: "before\nrewritten\nafter")
        )
        #expect(changedResult.discardedIDs == [changedBookmark.id])
        #expect(changed.bookmarks.isEmpty)

        let repeated = TextDocument(text: "zero\none\nA\nX\nB\nend")
        var ambiguous = TextBookmarkCollection()
        guard case let .added(ambiguousBookmark) = ambiguous.toggle(
            side: .left,
            lineNumber: 4,
            in: repeated
        ) else {
            Issue.record("Expected a bookmark to be added")
            return
        }
        let ambiguousResult = ambiguous.rebind(
            side: .left,
            to: TextDocument(text: "A\nX\nB\nmiddle\nA\nX\nB")
        )
        #expect(ambiguousResult.discardedIDs == [ambiguousBookmark.id])
        #expect(ambiguous.bookmarks.isEmpty)
    }

    @Test("Rebinding obeys distance, scan, and candidate limits")
    func rebindingLimits() {
        let original = TextDocument(text: "a\nanchor\nb")
        var none = TextBookmarkCollection(
            limits: TextBookmarkLimits(maximumBookmarkCount: 0)
        )
        #expect(
            none.toggle(side: .left, lineNumber: 2, in: original)
                == .limitReached(0)
        )

        var noSearch = TextBookmarkCollection(
            limits: TextBookmarkLimits(
                maximumBookmarkCount: 4,
                maximumRebindDistance: 0,
                maximumInspectedLineCount: 4,
                maximumCandidatesPerBookmark: 1
            )
        )
        guard case let .added(bookmark) = noSearch.toggle(
            side: .left,
            lineNumber: 2,
            in: original
        ) else {
            Issue.record("Expected a bookmark to be added")
            return
        }
        let result = noSearch.rebind(
            side: .left,
            to: TextDocument(text: "new\na\nanchor\nb")
        )
        #expect(result.discardedIDs == [bookmark.id])
    }

    @Test("Preview and extreme caller limits remain byte bounded and overflow safe")
    func extremeLimits() {
        let oversizedGrapheme = "a" + String(repeating: "\u{301}", count: 10_000)
        let original = TextDocument(text: "before\n\(oversizedGrapheme)\nafter")
        var bookmarks = TextBookmarkCollection(
            limits: TextBookmarkLimits(
                maximumBookmarkCount: Int.max,
                maximumRebindDistance: Int.max,
                maximumInspectedLineCount: Int.max,
                maximumCandidatesPerBookmark: Int.max,
                maximumPersistenceValueUTF8Length: Int.max
            )
        )
        guard case let .added(bookmark) = bookmarks.toggle(
            side: .left,
            lineNumber: 2,
            in: original
        ) else {
            Issue.record("Expected a bookmark to be added")
            return
        }
        #expect(bookmark.preview.unicodeScalars.count <= 80)
        #expect(bookmark.preview.utf8.count <= 256)

        let result = bookmarks.rebind(
            side: .left,
            to: TextDocument(text: "new\nbefore\n\(oversizedGrapheme)\nafter")
        )
        #expect(result.discardedIDs.isEmpty)
        #expect(bookmarks.bookmarks[0].lineNumber == 3)
    }

    @Test("Side swapping preserves bookmark identity")
    func sideSwap() {
        let document = TextDocument(text: "one\ntwo")
        var bookmarks = TextBookmarkCollection()
        guard case let .added(left) = bookmarks.toggle(
            side: .left,
            lineNumber: 1,
            in: document
        ), case let .added(right) = bookmarks.toggle(
            side: .right,
            lineNumber: 2,
            in: document
        ) else {
            Issue.record("Expected bookmarks to be added")
            return
        }

        bookmarks.swapSides()
        #expect(bookmarks.bookmark(side: .right, lineNumber: 1)?.id == left.id)
        #expect(bookmarks.bookmark(side: .left, lineNumber: 2)?.id == right.id)
    }

    @Test("Saved bookmark values restore only against matching content")
    func persistenceRoundTrip() {
        let left = TextDocument(text: "left one\nleft two")
        let right = TextDocument(text: "right one\nright two")
        var bookmarks = TextBookmarkCollection()
        _ = bookmarks.toggle(side: .left, lineNumber: 2, in: left)
        _ = bookmarks.toggle(side: .right, lineNumber: 1, in: right)

        let values = bookmarks.persistenceValues()
        let restored = TextBookmarkCollection.restore(
            from: values + ["not-a-riffa-bookmark"],
            leftDocument: left,
            rightDocument: right
        )
        #expect(restored.collection.bookmarks.map(\.id) == bookmarks.bookmarks.map(\.id))
        #expect(restored.discardedValueCount == 1)

        let changed = TextBookmarkCollection.restore(
            from: values,
            leftDocument: TextDocument(text: "left one\nchanged"),
            rightDocument: right
        )
        #expect(changed.collection.bookmarks.count == 1)
        #expect(changed.collection.bookmarks[0].side == .right)
        #expect(changed.discardedValueCount == 1)
    }

    @Test("Navigation index maps both sides and fails closed above its bound")
    func navigationIndex() {
        let result = TextDiffEngine(
            options: TextDiffOptions(contextLineCount: 0)
        ).compare(
            TextDocument(text: "a\nb\nc"),
            to: TextDocument(text: "new\na\nc")
        )
        let index = TextDiffNavigationIndex(result: result)

        #expect(index.isComplete)
        #expect(index.alignedOffset(side: .left, lineNumber: 1) == 1)
        #expect(index.alignedOffset(side: .left, lineNumber: 2) == 2)
        #expect(index.alignedOffset(side: .right, lineNumber: 1) == 0)
        #expect(index.alignedOffset(side: .right, lineNumber: 3) == 3)
        #expect(index.alignedOffset(side: .right, lineNumber: 4) == nil)

        let boundedOut = TextDiffNavigationIndex(
            result: result,
            maximumIndexedAlignedLineCount: 2
        )
        #expect(!boundedOut.isComplete)
        #expect(boundedOut.alignedOffset(side: .left, lineNumber: 1) == nil)

        let malformed = TextDiffResult(
            alignedLines: [
                AlignedDiffLine(
                    offset: 0,
                    kind: .unchanged,
                    left: DiffLineValue(
                        lineNumber: Int.max,
                        line: TextLine(content: "x", ending: .none)
                    ),
                    right: nil
                )
            ],
            hunks: [],
            statistics: TextDiffStatistics(
                unchangedLineCount: 1,
                insertedLineCount: 0,
                deletedLineCount: 0,
                modifiedLineCount: 0
            )
        )
        let malformedIndex = TextDiffNavigationIndex(
            result: malformed,
            maximumIndexedAlignedLineCount: Int.max
        )
        #expect(!malformedIndex.isComplete)
    }

    @Test("Overview markers are fixed-bin bounded and target valid hunks")
    func boundedOverview() {
        let leftLines = (0..<900).map { "line \($0)" }
        let rightLines = (0..<900).map { index in
            index.isMultiple(of: 3) ? "changed \(index)" : "line \(index)"
        }
        let result = TextDiffEngine(
            options: TextDiffOptions(contextLineCount: 0)
        ).compare(
            TextDocument(text: leftLines.joined(separator: "\n")),
            to: TextDocument(text: rightLines.joined(separator: "\n"))
        )
        let overview = TextDiffOverviewBuilder(
            limits: TextDiffOverviewLimits(
                maximumMarkerCount: 32,
                maximumSampledHunksPerMarker: Int.max,
                maximumSampledLinesPerHunk: Int.max
            )
        ).build(from: result)

        #expect(result.hunks.count == 300)
        #expect(overview.alignedLineCount == result.alignedLines.count)
        #expect(overview.hunkCount == result.hunks.count)
        #expect(overview.markers.count <= 32)
        #expect(!overview.markers.isEmpty)
        #expect(overview.markers.allSatisfy {
            result.hunks.indices.contains($0.targetHunkIndex)
                && $0.alignedRange.start >= 0
                && $0.alignedRange.end <= result.alignedLines.count
        })
    }

    @Test("Overview handles empty and disabled work without markers")
    func emptyOverview() {
        let same = TextDiffEngine().compare(
            TextDocument(text: "same"),
            to: TextDocument(text: "same")
        )
        #expect(TextDiffOverviewBuilder().build(from: same).markers.isEmpty)

        let changed = TextDiffEngine().compare(
            TextDocument(text: "old"),
            to: TextDocument(text: "new")
        )
        let disabled = TextDiffOverviewBuilder(
            limits: TextDiffOverviewLimits(
                maximumMarkerCount: -1,
                maximumSampledHunksPerMarker: -1,
                maximumSampledLinesPerHunk: -1
            )
        ).build(from: changed)
        #expect(disabled.markers.isEmpty)
    }
}
