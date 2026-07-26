import Testing
@testable import RiffaCore

@Suite("Text hunk transfer")
struct TextHunkTransferTests {
    private let engine = TextDiffEngine(options: .init(contextLineCount: 0))

    @Test("A replacement copies in either direction and retains exact endings")
    func replacement() throws {
        let left = TextDocument(text: "a\r\nleft\r\ntail")
        let right = TextDocument(text: "a\nright\ntail")
        let hunk = try #require(engine.compare(left, to: right).hunks.first)

        let toRight = try TextHunkTransfer().copy(hunk, from: .left, left: left, right: right)
        let toLeft = try TextHunkTransfer().copy(hunk, from: .right, left: left, right: right)

        #expect(toRight.right.text == "a\nleft\r\ntail")
        #expect(toLeft.left.text == "a\r\nright\ntail")
    }

    @Test("Insertions and deletions copy without off-by-one errors")
    func insertionAndDeletion() throws {
        let left = TextDocument(text: "a\nb\nc\n")
        let right = TextDocument(text: "a\nc\n")
        let hunk = try #require(engine.compare(left, to: right).hunks.first)

        let inserted = try TextHunkTransfer().copy(hunk, from: .left, left: left, right: right)
        let deleted = try TextHunkTransfer().copy(hunk, from: .right, left: left, right: right)

        #expect(inserted.right == left)
        #expect(deleted.left == right)
    }

    @Test("Stale ranges fail atomically")
    func staleRange() {
        let hunk = DiffHunk(
            index: 0,
            alignedRange: .init(start: 0, count: 1),
            leftRange: .init(start: 9, count: 1),
            rightRange: .init(start: 0, count: 1),
            lines: []
        )

        #expect(throws: TextHunkTransferError.sourceRangeOutOfBounds) {
            try TextHunkTransfer().copy(
                hunk,
                from: .left,
                left: TextDocument(text: "a"),
                right: TextDocument(text: "b")
            )
        }
    }
}
