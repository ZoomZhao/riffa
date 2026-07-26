import Foundation

/// Options shared by the binary comparison engine and hex-oriented clients.
public struct HexComparisonOptions: Hashable, Sendable {
    public var bytesPerRow: Int

    public init(bytesPerRow: Int = 16) {
        self.bytesPerRow = max(1, bytesPerRow)
    }
}

/// A contiguous range of byte positions that differs at the same offset.
public struct BinaryDifferenceRange: Identifiable, Hashable, Sendable {
    public let startOffset: Int
    public let leftCount: Int
    public let rightCount: Int

    public init(startOffset: Int, leftCount: Int, rightCount: Int) {
        self.startOffset = startOffset
        self.leftCount = leftCount
        self.rightCount = rightCount
    }

    public var id: Int { startOffset }
    public var comparedCount: Int { max(leftCount, rightCount) }
}

/// One display row. `differingColumns` uses zero-based indices within the row.
public struct HexComparisonRow: Identifiable, Hashable, Sendable {
    public let offset: Int
    public let leftBytes: [UInt8]
    public let rightBytes: [UInt8]
    public let differingColumns: [Int]

    public init(
        offset: Int,
        leftBytes: [UInt8],
        rightBytes: [UInt8],
        differingColumns: [Int]
    ) {
        self.offset = offset
        self.leftBytes = leftBytes
        self.rightBytes = rightBytes
        self.differingColumns = differingColumns
    }

    public var id: Int { offset }
}

public struct HexComparisonResult: Hashable, Sendable {
    public let leftByteCount: Int
    public let rightByteCount: Int
    public let rows: [HexComparisonRow]
    public let differences: [BinaryDifferenceRange]
    public let differingBytePositionCount: Int

    public init(
        leftByteCount: Int,
        rightByteCount: Int,
        rows: [HexComparisonRow],
        differences: [BinaryDifferenceRange],
        differingBytePositionCount: Int
    ) {
        self.leftByteCount = leftByteCount
        self.rightByteCount = rightByteCount
        self.rows = rows
        self.differences = differences
        self.differingBytePositionCount = differingBytePositionCount
    }

    public var hasDifferences: Bool { !differences.isEmpty }
}

/// Deterministic same-offset binary comparison.
///
/// This engine intentionally does not guess insertion alignment. A future complete-alignment
/// strategy can produce the same public rows after using a different offset mapping.
public struct HexComparisonEngine: Sendable {
    public let options: HexComparisonOptions

    public init(options: HexComparisonOptions = .init()) {
        self.options = options
    }

    public func compare(left: Data, right: Data) -> HexComparisonResult {
        compare(left: Array(left), right: Array(right))
    }

    public func compare(left: [UInt8], right: [UInt8]) -> HexComparisonResult {
        let maximumCount = max(left.count, right.count)
        var rows: [HexComparisonRow] = []
        var differenceRanges: [BinaryDifferenceRange] = []
        var differingPositionCount = 0
        var openDifferenceStart: Int?

        for rowOffset in stride(from: 0, to: maximumCount, by: options.bytesPerRow) {
            let rowEnd = min(rowOffset + options.bytesPerRow, maximumCount)
            var differingColumns: [Int] = []

            for offset in rowOffset..<rowEnd {
                let leftByte = left.indices.contains(offset) ? left[offset] : nil
                let rightByte = right.indices.contains(offset) ? right[offset] : nil
                let differs = leftByte != rightByte

                if differs {
                    differingPositionCount += 1
                    differingColumns.append(offset - rowOffset)
                    if openDifferenceStart == nil {
                        openDifferenceStart = offset
                    }
                } else if let start = openDifferenceStart {
                    differenceRanges.append(
                        makeRange(start: start, end: offset, leftCount: left.count, rightCount: right.count)
                    )
                    openDifferenceStart = nil
                }
            }

            let leftEnd = min(rowEnd, left.count)
            let rightEnd = min(rowEnd, right.count)
            rows.append(
                HexComparisonRow(
                    offset: rowOffset,
                    leftBytes: rowOffset < leftEnd ? Array(left[rowOffset..<leftEnd]) : [],
                    rightBytes: rowOffset < rightEnd ? Array(right[rowOffset..<rightEnd]) : [],
                    differingColumns: differingColumns
                )
            )
        }

        if let start = openDifferenceStart {
            differenceRanges.append(
                makeRange(start: start, end: maximumCount, leftCount: left.count, rightCount: right.count)
            )
        }

        return HexComparisonResult(
            leftByteCount: left.count,
            rightByteCount: right.count,
            rows: rows,
            differences: differenceRanges,
            differingBytePositionCount: differingPositionCount
        )
    }

    private func makeRange(
        start: Int,
        end: Int,
        leftCount: Int,
        rightCount: Int
    ) -> BinaryDifferenceRange {
        BinaryDifferenceRange(
            startOffset: start,
            leftCount: max(0, min(end, leftCount) - start),
            rightCount: max(0, min(end, rightCount) - start)
        )
    }
}
