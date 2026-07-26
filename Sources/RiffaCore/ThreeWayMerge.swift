/// A configurable set of diff3-style marker lines used when rendering conflicts.
public struct ThreeWayConflictMarkers: Hashable, Sendable {
    public let leftStart: String
    public let baseStart: String
    public let separator: String
    public let rightEnd: String
    public let lineEnding: TextLineEnding?

    public init(
        leftStart: String = "<<<<<<< LEFT",
        baseStart: String = "||||||| BASE",
        separator: String = "=======",
        rightEnd: String = ">>>>>>> RIGHT",
        lineEnding: TextLineEnding? = nil
    ) {
        self.leftStart = leftStart
        self.baseStart = baseStart
        self.separator = separator
        self.rightEnd = rightEnd
        self.lineEnding = lineEnding
    }
}

/// One unresolved region in a three-way text merge.
///
/// Ranges are zero-based line ranges in their respective documents. Text is
/// retained separately so callers never need to reconstruct a conflict from
/// marker-rendered output.
public struct ThreeWayMergeConflict: Identifiable, Hashable, Sendable {
    public let id: Int
    public let baseRange: DiffLineRange
    public let leftRange: DiffLineRange
    public let rightRange: DiffLineRange
    public let baseText: String
    public let leftText: String
    public let rightText: String

    public init(
        id: Int,
        baseRange: DiffLineRange,
        leftRange: DiffLineRange,
        rightRange: DiffLineRange,
        baseText: String,
        leftText: String,
        rightText: String
    ) {
        self.id = id
        self.baseRange = baseRange
        self.leftRange = leftRange
        self.rightRange = rightRange
        self.baseText = baseText
        self.leftText = leftText
        self.rightText = rightText
    }
}

/// An ordered part of a structured merge result.
public enum ThreeWayMergeSegment: Hashable, Sendable {
    case merged(String)
    case conflict(ThreeWayMergeConflict)
}

/// The structured result of merging independent left and right edits against a base.
public struct ThreeWayMergeResult: Hashable, Sendable {
    public let segments: [ThreeWayMergeSegment]
    public let conflicts: [ThreeWayMergeConflict]
    public let preferredLineEnding: TextLineEnding

    public init(
        segments: [ThreeWayMergeSegment],
        conflicts: [ThreeWayMergeConflict],
        preferredLineEnding: TextLineEnding
    ) {
        self.segments = segments
        self.conflicts = conflicts
        self.preferredLineEnding = preferredLineEnding
    }

    public var hasConflicts: Bool {
        !conflicts.isEmpty
    }

    /// Exact merged text when every edit was resolved automatically.
    public var mergedText: String? {
        guard !hasConflicts else { return nil }
        return segments.reduce(into: "") { result, segment in
            if case let .merged(text) = segment {
                result += text
            }
        }
    }

    /// Renders the structured result, adding markers only around unresolved conflicts.
    public func renderedText(markers: ThreeWayConflictMarkers = .init()) -> String {
        let markerEnding: TextLineEnding
        if let configuredEnding = markers.lineEnding, configuredEnding.isTerminated {
            markerEnding = configuredEnding
        } else {
            markerEnding = preferredLineEnding
        }

        return segments.reduce(into: "") { output, segment in
            switch segment {
            case let .merged(text):
                output += text
            case let .conflict(conflict):
                output += Self.render(conflict, markers: markers, lineEnding: markerEnding.rawValue)
            }
        }
    }

    private static func render(
        _ conflict: ThreeWayMergeConflict,
        markers: ThreeWayConflictMarkers,
        lineEnding: String
    ) -> String {
        var output = markers.leftStart + lineEnding
        append(conflict.leftText, to: &output, followedBy: markers.baseStart, lineEnding: lineEnding)
        append(conflict.baseText, to: &output, followedBy: markers.separator, lineEnding: lineEnding)
        append(conflict.rightText, to: &output, followedBy: markers.rightEnd, lineEnding: lineEnding)
        return output
    }

    private static func append(
        _ section: String,
        to output: inout String,
        followedBy marker: String,
        lineEnding: String
    ) {
        output += section
        if !section.isEmpty, !section.hasSuffix("\n"), !section.hasSuffix("\r") {
            output += lineEnding
        }
        output += marker + lineEnding
    }
}

/// A deterministic, line-based diff3 merge engine.
public struct ThreeWayMergeEngine: Sendable {
    public init() {}

    public func merge(
        base: String,
        left: String,
        right: String
    ) -> ThreeWayMergeResult {
        merge(
            base: TextDocument(text: base),
            left: TextDocument(text: left),
            right: TextDocument(text: right)
        )
    }

    public func merge(
        base: TextDocument,
        left: TextDocument,
        right: TextDocument
    ) -> ThreeWayMergeResult {
        let leftEdits = makeEdits(base: base.lines, variant: left.lines)
        let rightEdits = makeEdits(base: base.lines, variant: right.lines)
        let preferredLineEnding = base.preferredLineEnding
            ?? left.preferredLineEnding
            ?? right.preferredLineEnding
            ?? .lf

        var segments: [ThreeWayMergeSegment] = []
        var conflicts: [ThreeWayMergeConflict] = []
        var baseCursor = 0
        var leftIndex = 0
        var rightIndex = 0

        while leftIndex < leftEdits.count || rightIndex < rightEdits.count {
            let leftEdit = leftIndex < leftEdits.count ? leftEdits[leftIndex] : nil
            let rightEdit = rightIndex < rightEdits.count ? rightEdits[rightIndex] : nil

            if let leftEdit, let rightEdit, editsOverlap(leftEdit, rightEdit) {
                let group = collectOverlapGroup(
                    leftEdits: leftEdits,
                    rightEdits: rightEdits,
                    leftIndex: leftIndex,
                    rightIndex: rightIndex
                )
                leftIndex = group.nextLeftIndex
                rightIndex = group.nextRightIndex

                appendMerged(
                    text(from: base.lines[baseCursor..<group.baseRange.lowerBound]),
                    to: &segments
                )

                let leftLines = applying(group.leftEdits, to: base.lines, within: group.baseRange)
                let rightLines = applying(group.rightEdits, to: base.lines, within: group.baseRange)

                if leftLines == rightLines {
                    appendMerged(text(from: leftLines[...]), to: &segments)
                } else {
                    let baseText = text(from: base.lines[group.baseRange])
                    let leftText = text(from: leftLines[...])
                    let rightText = text(from: rightLines[...])
                    let leftStart = variantOffset(
                        atBasePosition: group.baseRange.lowerBound,
                        edits: leftEdits
                    )
                    let rightStart = variantOffset(
                        atBasePosition: group.baseRange.lowerBound,
                        edits: rightEdits
                    )
                    let conflict = ThreeWayMergeConflict(
                        id: conflicts.count,
                        baseRange: DiffLineRange(
                            start: group.baseRange.lowerBound,
                            count: group.baseRange.count
                        ),
                        leftRange: DiffLineRange(start: leftStart, count: leftLines.count),
                        rightRange: DiffLineRange(start: rightStart, count: rightLines.count),
                        baseText: baseText,
                        leftText: leftText,
                        rightText: rightText
                    )
                    conflicts.append(conflict)
                    segments.append(.conflict(conflict))
                }

                baseCursor = group.baseRange.upperBound
                continue
            }

            let useLeft: Bool
            switch (leftEdit, rightEdit) {
            case (.some, nil):
                useLeft = true
            case (nil, .some):
                useLeft = false
            case let (left?, right?):
                useLeft = editComesBefore(left, right)
            case (nil, nil):
                useLeft = true
            }

            if useLeft, let edit = leftEdit {
                applySingleEdit(edit, base: base.lines, baseCursor: &baseCursor, segments: &segments)
                leftIndex += 1
            } else if let edit = rightEdit {
                applySingleEdit(edit, base: base.lines, baseCursor: &baseCursor, segments: &segments)
                rightIndex += 1
            }
        }

        appendMerged(text(from: base.lines[baseCursor...]), to: &segments)
        return ThreeWayMergeResult(
            segments: segments,
            conflicts: conflicts,
            preferredLineEnding: preferredLineEnding
        )
    }

    private func makeEdits(base: [TextLine], variant: [TextLine]) -> [LineEdit] {
        let difference = variant.difference(from: base)
        var removedOffsets: Set<Int> = []
        var insertedOffsets: Set<Int> = []

        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removedOffsets.insert(offset)
            case let .insert(offset, _, _):
                insertedOffsets.insert(offset)
            }
        }

        var edits: [LineEdit] = []
        var baseOffset = 0
        var variantOffset = 0

        while baseOffset < base.count || variantOffset < variant.count {
            if baseOffset < base.count,
               variantOffset < variant.count,
               !removedOffsets.contains(baseOffset),
               !insertedOffsets.contains(variantOffset)
            {
                baseOffset += 1
                variantOffset += 1
                continue
            }

            let baseStart = baseOffset
            let variantStart = variantOffset
            while baseOffset < base.count, removedOffsets.contains(baseOffset) {
                baseOffset += 1
            }
            while variantOffset < variant.count, insertedOffsets.contains(variantOffset) {
                variantOffset += 1
            }

            if baseStart == baseOffset, variantStart == variantOffset {
                // Defensive progress for a malformed or future difference source.
                if baseOffset < base.count { baseOffset += 1 }
                if variantOffset < variant.count { variantOffset += 1 }
                continue
            }

            edits.append(
                LineEdit(
                    baseRange: baseStart..<baseOffset,
                    variantRange: variantStart..<variantOffset,
                    replacement: Array(variant[variantStart..<variantOffset])
                )
            )
        }
        return edits
    }

    private func collectOverlapGroup(
        leftEdits: [LineEdit],
        rightEdits: [LineEdit],
        leftIndex: Int,
        rightIndex: Int
    ) -> OverlapGroup {
        var groupLeft = [leftEdits[leftIndex]]
        var groupRight = [rightEdits[rightIndex]]
        var nextLeftIndex = leftIndex + 1
        var nextRightIndex = rightIndex + 1
        var lowerBound = min(groupLeft[0].baseRange.lowerBound, groupRight[0].baseRange.lowerBound)
        var upperBound = max(groupLeft[0].baseRange.upperBound, groupRight[0].baseRange.upperBound)

        var addedEdit = true
        while addedEdit {
            addedEdit = false
            let region = lowerBound..<upperBound

            if nextLeftIndex < leftEdits.count,
               edit(leftEdits[nextLeftIndex], intersects: region)
            {
                let next = leftEdits[nextLeftIndex]
                groupLeft.append(next)
                lowerBound = min(lowerBound, next.baseRange.lowerBound)
                upperBound = max(upperBound, next.baseRange.upperBound)
                nextLeftIndex += 1
                addedEdit = true
            }

            let updatedRegion = lowerBound..<upperBound
            if nextRightIndex < rightEdits.count,
               edit(rightEdits[nextRightIndex], intersects: updatedRegion)
            {
                let next = rightEdits[nextRightIndex]
                groupRight.append(next)
                lowerBound = min(lowerBound, next.baseRange.lowerBound)
                upperBound = max(upperBound, next.baseRange.upperBound)
                nextRightIndex += 1
                addedEdit = true
            }
        }

        return OverlapGroup(
            baseRange: lowerBound..<upperBound,
            leftEdits: groupLeft,
            rightEdits: groupRight,
            nextLeftIndex: nextLeftIndex,
            nextRightIndex: nextRightIndex
        )
    }

    private func applying(
        _ edits: [LineEdit],
        to base: [TextLine],
        within range: Range<Int>
    ) -> [TextLine] {
        var result: [TextLine] = []
        var cursor = range.lowerBound

        for edit in edits {
            if cursor < edit.baseRange.lowerBound {
                result += base[cursor..<edit.baseRange.lowerBound]
            }
            result += edit.replacement
            cursor = edit.baseRange.upperBound
        }
        if cursor < range.upperBound {
            result += base[cursor..<range.upperBound]
        }
        return result
    }

    private func applySingleEdit(
        _ edit: LineEdit,
        base: [TextLine],
        baseCursor: inout Int,
        segments: inout [ThreeWayMergeSegment]
    ) {
        if baseCursor < edit.baseRange.lowerBound {
            appendMerged(text(from: base[baseCursor..<edit.baseRange.lowerBound]), to: &segments)
        }
        appendMerged(text(from: edit.replacement[...]), to: &segments)
        baseCursor = edit.baseRange.upperBound
    }

    private func editsOverlap(_ left: LineEdit, _ right: LineEdit) -> Bool {
        if left.isInsertion, right.isInsertion {
            return left.baseRange.lowerBound == right.baseRange.lowerBound
        }
        if left.isInsertion {
            let position = left.baseRange.lowerBound
            return position > right.baseRange.lowerBound && position < right.baseRange.upperBound
        }
        if right.isInsertion {
            let position = right.baseRange.lowerBound
            return position > left.baseRange.lowerBound && position < left.baseRange.upperBound
        }
        return max(left.baseRange.lowerBound, right.baseRange.lowerBound)
            < min(left.baseRange.upperBound, right.baseRange.upperBound)
    }

    private func edit(_ edit: LineEdit, intersects region: Range<Int>) -> Bool {
        if region.isEmpty {
            return edit.isInsertion && edit.baseRange.lowerBound == region.lowerBound
        }
        if edit.isInsertion {
            let position = edit.baseRange.lowerBound
            return position > region.lowerBound && position < region.upperBound
        }
        return max(edit.baseRange.lowerBound, region.lowerBound)
            < min(edit.baseRange.upperBound, region.upperBound)
    }

    private func editComesBefore(_ left: LineEdit, _ right: LineEdit) -> Bool {
        if left.baseRange.lowerBound != right.baseRange.lowerBound {
            return left.baseRange.lowerBound < right.baseRange.lowerBound
        }
        if left.isInsertion != right.isInsertion {
            return left.isInsertion
        }
        return true
    }

    private func variantOffset(atBasePosition position: Int, edits: [LineEdit]) -> Int {
        var delta = 0
        for edit in edits {
            let isBeforePosition = edit.isInsertion
                ? edit.baseRange.lowerBound < position
                : edit.baseRange.upperBound <= position
            if isBeforePosition {
                delta += edit.variantRange.count - edit.baseRange.count
            } else {
                break
            }
        }
        return position + delta
    }

    private func appendMerged(_ text: String, to segments: inout [ThreeWayMergeSegment]) {
        guard !text.isEmpty else { return }
        if case let .merged(previous)? = segments.last {
            segments[segments.count - 1] = .merged(previous + text)
        } else {
            segments.append(.merged(text))
        }
    }

    private func text<C: Collection>(from lines: C) -> String where C.Element == TextLine {
        lines.lazy.map(\.sourceText).joined()
    }
}

private struct LineEdit: Sendable {
    let baseRange: Range<Int>
    let variantRange: Range<Int>
    let replacement: [TextLine]

    var isInsertion: Bool {
        baseRange.isEmpty
    }
}

private struct OverlapGroup: Sendable {
    let baseRange: Range<Int>
    let leftEdits: [LineEdit]
    let rightEdits: [LineEdit]
    let nextLeftIndex: Int
    let nextRightIndex: Int
}
