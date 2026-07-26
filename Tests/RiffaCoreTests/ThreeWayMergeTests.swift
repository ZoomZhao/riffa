import Testing
@testable import RiffaCore

@Suite("Three-way text merge")
struct ThreeWayMergeTests {
    private let engine = ThreeWayMergeEngine()

    @Test("No changes preserve the source exactly")
    func noChanges() {
        let source = "alpha\r\nbeta\ngamma\r"

        let result = engine.merge(base: source, left: source, right: source)

        #expect(!result.hasConflicts)
        #expect(result.mergedText == source)
        #expect(result.renderedText() == source)
    }

    @Test("A one-sided modification is adopted")
    func oneSidedModification() {
        let base = "alpha\nbeta\n"
        let left = "alpha\nleft\n"

        let result = engine.merge(base: base, left: left, right: base)

        #expect(!result.hasConflicts)
        #expect(result.mergedText == left)
    }

    @Test("Identical edits from both sides are folded")
    func identicalEdits() {
        let base = "alpha\nbeta\n"
        let changed = "alpha\nshared\n"

        let result = engine.merge(base: base, left: changed, right: changed)

        #expect(!result.hasConflicts)
        #expect(result.mergedText == changed)
    }

    @Test("Non-overlapping edits are combined and retain line endings")
    func nonOverlappingEdits() {
        let base = "alpha\nbeta\r\ngamma\n"
        let left = "LEFT\nbeta\r\ngamma\n"
        let right = "alpha\nbeta\r\nRIGHT\n"

        let result = engine.merge(base: base, left: left, right: right)

        #expect(!result.hasConflicts)
        #expect(result.mergedText == "LEFT\nbeta\r\nRIGHT\n")
    }

    @Test("Deletion versus modification creates a structured conflict")
    func deletionVersusModification() throws {
        let base = "keep\nvictim\nend\n"
        let left = "keep\nend\n"
        let right = "keep\nchanged\nend\n"

        let result = engine.merge(base: base, left: left, right: right)
        let conflict = try #require(result.conflicts.first)

        #expect(result.hasConflicts)
        #expect(result.mergedText == nil)
        #expect(conflict.baseRange == DiffLineRange(start: 1, count: 1))
        #expect(conflict.leftRange == DiffLineRange(start: 1, count: 0))
        #expect(conflict.rightRange == DiffLineRange(start: 1, count: 1))
        #expect(conflict.baseText == "victim\n")
        #expect(conflict.leftText == "")
        #expect(conflict.rightText == "changed\n")

        let rendered = result.renderedText(
            markers: ThreeWayConflictMarkers(
                leftStart: "<LEFT",
                baseStart: "<BASE",
                separator: "---",
                rightEnd: ">RIGHT",
                lineEnding: .lf
            )
        )
        #expect(rendered.contains("<LEFT\n<BASE\nvictim\n---\nchanged\n>RIGHT\n"))
    }

    @Test("Same-position identical insertions fold, different insertions conflict")
    func samePositionInsertions() throws {
        let base = "alpha\nbeta\n"
        let same = "alpha\ninserted\nbeta\n"
        let folded = engine.merge(base: base, left: same, right: same)

        #expect(!folded.hasConflicts)
        #expect(folded.mergedText == same)

        let conflicted = engine.merge(
            base: base,
            left: "alpha\nLEFT\nbeta\n",
            right: "alpha\nRIGHT\nbeta\n"
        )
        let conflict = try #require(conflicted.conflicts.first)

        #expect(conflicted.hasConflicts)
        #expect(conflict.baseRange == DiffLineRange(start: 1, count: 0))
        #expect(conflict.leftRange == DiffLineRange(start: 1, count: 1))
        #expect(conflict.rightRange == DiffLineRange(start: 1, count: 1))
        #expect(conflict.baseText == "")
        #expect(conflict.leftText == "LEFT\n")
        #expect(conflict.rightText == "RIGHT\n")
    }

    @Test("Unicode edits on different lines merge without loss")
    func unicodeEdits() {
        let base = "你好 🌍\n开发者 👩🏽‍💻 café\n"
        let left = "您好 🌍\n开发者 👩🏽‍💻 café\n"
        let right = "你好 🌍\n开发者 👩🏽‍💻 CAFÉ\n"

        let result = engine.merge(base: base, left: left, right: right)

        #expect(!result.hasConflicts)
        #expect(result.mergedText == "您好 🌍\n开发者 👩🏽‍💻 CAFÉ\n")
    }
}
