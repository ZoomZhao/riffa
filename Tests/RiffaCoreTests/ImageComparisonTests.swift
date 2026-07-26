import Testing
@testable import RiffaCore

@Suite("RGBA image comparison")
struct ImageComparisonTests {
    private let comparison = ImageComparison()

    @Test("Identical images have an empty mismatch mask")
    func identicalImages() throws {
        let image = try buffer(
            width: 2,
            height: 2,
            pixels: [
                [10, 20, 30, 255], [40, 50, 60, 255],
                [70, 80, 90, 128], [100, 110, 120, 0]
            ]
        )

        let result = comparison.compare(image, to: image)

        #expect(result.dimensionStatus == .equal)
        #expect(result.comparedPixelCount == 4)
        #expect(result.mismatchedPixelCount == 0)
        #expect(result.mismatchRatio == 0)
        #expect(result.maximumChannelDifference == 0)
        #expect(result.averageChannelDifference == 0)
        #expect(result.mismatchBounds == nil)
        #expect(result.mismatchMask.values == [0, 0, 0, 0])
    }

    @Test("A channel difference equal to tolerance is accepted")
    func toleranceBoundary() throws {
        let left = try buffer(width: 1, height: 1, pixels: [[10, 20, 30, 255]])
        let right = try buffer(width: 1, height: 1, pixels: [[12, 20, 30, 255]])

        let accepted = comparison.compare(
            left,
            to: right,
            options: ImageComparisonOptions(channelTolerance: 2)
        )
        let rejected = comparison.compare(
            left,
            to: right,
            options: ImageComparisonOptions(channelTolerance: 1)
        )

        #expect(accepted.mismatchedPixelCount == 0)
        #expect(accepted.maximumChannelDifference == 2)
        #expect(accepted.averageChannelDifference == 0.5)
        #expect(rejected.mismatchedPixelCount == 1)
        #expect(rejected.mismatchRatio == 1)
    }

    @Test("Alpha comparison can be disabled")
    func alphaOption() throws {
        let transparent = try buffer(width: 1, height: 1, pixels: [[1, 2, 3, 0]])
        let opaque = try buffer(width: 1, height: 1, pixels: [[1, 2, 3, 255]])

        let ignored = comparison.compare(
            transparent,
            to: opaque,
            options: ImageComparisonOptions(compareAlpha: false)
        )
        let included = comparison.compare(transparent, to: opaque)

        #expect(ignored.mismatchedPixelCount == 0)
        #expect(ignored.maximumChannelDifference == 0)
        #expect(included.mismatchedPixelCount == 1)
        #expect(included.maximumChannelDifference == 255)
        #expect(included.averageChannelDifference == 63.75)
    }

    @Test("Different dimensions report size separately from overlap")
    func differentDimensions() throws {
        let left = try buffer(
            width: 2,
            height: 2,
            pixels: [
                [1, 1, 1, 255], [9, 9, 9, 255],
                [2, 2, 2, 255], [8, 8, 8, 255]
            ]
        )
        let right = try buffer(
            width: 1,
            height: 2,
            pixels: [[1, 1, 1, 255], [2, 2, 2, 255]]
        )

        let result = comparison.compare(left, to: right)

        #expect(result.dimensionStatus == .different)
        #expect(result.overlapBounds == PixelBounds(x: 0, y: 0, width: 1, height: 2))
        #expect(result.comparedPixelCount == 2)
        #expect(result.mismatchedPixelCount == 0)
        #expect(result.mismatchMask.values == [0, 0])
    }

    @Test("Integer offsets align the right image in left coordinates")
    func offsetAlignment() throws {
        let left = try buffer(
            width: 3,
            height: 1,
            pixels: [
                [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]
            ]
        )
        let right = try buffer(
            width: 2,
            height: 1,
            pixels: [[0, 255, 0, 255], [0, 0, 255, 255]]
        )

        let result = comparison.compare(
            left,
            to: right,
            options: ImageComparisonOptions(xOffset: 1)
        )

        #expect(result.overlapBounds == PixelBounds(x: 1, y: 0, width: 2, height: 1))
        #expect(result.comparedPixelCount == 2)
        #expect(result.mismatchedPixelCount == 0)
        #expect(result.mismatchMask.originX == 1)
        #expect(result.mismatchMask.value(x: 1, y: 0) == 0)
        #expect(result.mismatchMask.value(x: 0, y: 0) == nil)
    }

    @Test("Mismatch bounds tightly enclose changed pixels")
    func mismatchBounds() throws {
        let black = Array(repeating: [UInt8(0), 0, 0, 255], count: 9)
        var changed = black
        changed[1] = [10, 0, 0, 255]
        changed[8] = [0, 20, 0, 255]

        let result = comparison.compare(
            try buffer(width: 3, height: 3, pixels: black),
            to: try buffer(width: 3, height: 3, pixels: changed)
        )

        #expect(result.mismatchedPixelCount == 2)
        #expect(result.mismatchBounds == PixelBounds(x: 1, y: 0, width: 2, height: 3))
        #expect(result.mismatchMask.values == [0, 255, 0, 0, 0, 0, 0, 0, 255])
        #expect(result.maximumChannelDifference == 20)
    }

    @Test("Empty and non-overlapping comparisons are finite and stable")
    func emptyAndNoOverlap() throws {
        let empty = try RGBAPixelBuffer(width: 0, height: 0, bytes: [])
        let pixel = try buffer(width: 1, height: 1, pixels: [[1, 2, 3, 4]])

        let emptyResult = comparison.compare(empty, to: empty)
        let farRight = comparison.compare(
            pixel,
            to: pixel,
            options: ImageComparisonOptions(xOffset: Int.max)
        )
        let farLeft = comparison.compare(
            pixel,
            to: pixel,
            options: ImageComparisonOptions(xOffset: Int.min)
        )

        for result in [emptyResult, farRight, farLeft] {
            #expect(result.comparedPixelCount == 0)
            #expect(result.mismatchedPixelCount == 0)
            #expect(result.mismatchRatio == 0)
            #expect(result.averageChannelDifference == 0)
            #expect(result.mismatchRatio.isFinite)
            #expect(result.mismatchMask.values.isEmpty)
        }
        #expect(farRight == farLeft)
    }

    @Test("Invalid dimensions, overflow, and byte counts are rejected")
    func invalidBuffers() {
        #expect(throws: PixelBufferValidationError.negativeDimension(width: -1, height: 2)) {
            try RGBAPixelBuffer(width: -1, height: 2, bytes: [])
        }
        #expect(throws: PixelBufferValidationError.byteCountOverflow(width: Int.max, height: 2)) {
            try RGBAPixelBuffer(width: Int.max, height: 2, bytes: [])
        }
        #expect(throws: PixelBufferValidationError.invalidByteCount(expected: 8, actual: 7)) {
            try RGBAPixelBuffer(width: 2, height: 1, bytes: Array(repeating: 0, count: 7))
        }
    }

    private func buffer(
        width: Int,
        height: Int,
        pixels: [[UInt8]]
    ) throws -> RGBAPixelBuffer {
        try RGBAPixelBuffer(width: width, height: height, bytes: pixels.flatMap { $0 })
    }
}
