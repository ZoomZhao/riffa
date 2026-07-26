import Foundation
import Testing
@testable import RiffaCore

@Suite("Same-offset binary comparison")
struct HexComparisonTests {
    @Test("Identical and empty inputs have no differences")
    func identicalInputs() {
        let engine = HexComparisonEngine()

        #expect(!engine.compare(left: [], right: []).hasDifferences)
        let result = engine.compare(left: [0x00, 0x7F, 0xFF], right: [0x00, 0x7F, 0xFF])
        #expect(!result.hasDifferences)
        #expect(result.rows.count == 1)
        #expect(result.differingBytePositionCount == 0)
    }

    @Test("Separated changed regions remain separated")
    func separatedRegions() {
        let result = HexComparisonEngine().compare(
            left: [0, 1, 2, 3, 4, 5],
            right: [0, 9, 8, 3, 7, 5]
        )

        #expect(result.differences == [
            BinaryDifferenceRange(startOffset: 1, leftCount: 2, rightCount: 2),
            BinaryDifferenceRange(startOffset: 4, leftCount: 1, rightCount: 1),
        ])
        #expect(result.differingBytePositionCount == 3)
    }

    @Test("A length mismatch reports missing bytes explicitly")
    func lengthMismatch() {
        let result = HexComparisonEngine().compare(
            left: [0x41, 0x42],
            right: [0x41, 0x42, 0x43, 0x44]
        )

        #expect(result.differences == [
            BinaryDifferenceRange(startOffset: 2, leftCount: 0, rightCount: 2),
        ])
        #expect(result.rows[0].differingColumns == [2, 3])
    }

    @Test("Rows use the configured width and stable offsets")
    func rows() {
        let bytes = Array(UInt8(0)..<UInt8(10))
        let result = HexComparisonEngine(options: .init(bytesPerRow: 4)).compare(
            left: bytes,
            right: bytes
        )

        #expect(result.rows.map(\.offset) == [0, 4, 8])
        #expect(result.rows.map(\.leftBytes.count) == [4, 4, 2])
    }

    @Test("Data input matches byte-array input")
    func dataInput() {
        let left = Data([1, 2, 3])
        let right = Data([1, 4, 3])
        #expect(
            HexComparisonEngine().compare(left: left, right: right)
                == HexComparisonEngine().compare(left: Array(left), right: Array(right))
        )
    }
}
