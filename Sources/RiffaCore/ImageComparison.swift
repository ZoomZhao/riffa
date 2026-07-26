/// A validation failure for an interleaved, eight-bit RGBA pixel buffer.
public enum PixelBufferValidationError: Error, Equatable, Sendable {
    case negativeDimension(width: Int, height: Int)
    case byteCountOverflow(width: Int, height: Int)
    case invalidByteCount(expected: Int, actual: Int)
}

/// An AppKit-independent, row-major RGBA8 image buffer.
public struct RGBAPixelBuffer: Hashable, Sendable {
    public static let bytesPerPixel = 4

    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) throws {
        guard width >= 0, height >= 0 else {
            throw PixelBufferValidationError.negativeDimension(width: width, height: height)
        }

        let (pixelCount, pixelCountOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelCountOverflow else {
            throw PixelBufferValidationError.byteCountOverflow(width: width, height: height)
        }

        let (expectedByteCount, byteCountOverflow) = pixelCount.multipliedReportingOverflow(
            by: Self.bytesPerPixel
        )
        guard !byteCountOverflow else {
            throw PixelBufferValidationError.byteCountOverflow(width: width, height: height)
        }

        guard bytes.count == expectedByteCount else {
            throw PixelBufferValidationError.invalidByteCount(
                expected: expectedByteCount,
                actual: bytes.count
            )
        }

        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public var pixelCount: Int {
        bytes.count / Self.bytesPerPixel
    }
}

/// Places the right image at `(xOffset, yOffset)` in the left image's pixel
/// coordinate system. Only the overlapping rectangle is sampled.
public struct ImageComparisonOptions: Hashable, Sendable {
    public var channelTolerance: UInt8
    public var compareAlpha: Bool
    public var xOffset: Int
    public var yOffset: Int

    public init(
        channelTolerance: UInt8 = 0,
        compareAlpha: Bool = true,
        xOffset: Int = 0,
        yOffset: Int = 0
    ) {
        self.channelTolerance = channelTolerance
        self.compareAlpha = compareAlpha
        self.xOffset = xOffset
        self.yOffset = yOffset
    }
}

public enum ImageDimensionStatus: String, Hashable, Sendable {
    case equal
    case different
}

/// A pixel rectangle in the left image's coordinate system.
public struct PixelBounds: Hashable, Codable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// An 8-bit heat-map source over the comparison's overlapping rectangle.
/// Values are `0` for a match and `255` for a mismatch.
public struct ImageMismatchMask: Hashable, Sendable {
    public let originX: Int
    public let originY: Int
    public let width: Int
    public let height: Int
    public let values: [UInt8]

    init(originX: Int, originY: Int, width: Int, height: Int, values: [UInt8]) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.values = values
    }

    public func value(x: Int, y: Int) -> UInt8? {
        guard x >= originX, y >= originY else { return nil }
        let localX = x - originX
        let localY = y - originY
        guard localX < width, localY < height else { return nil }
        return values[localY * width + localX]
    }
}

public struct ImageComparisonResult: Hashable, Sendable {
    public let dimensionStatus: ImageDimensionStatus
    public let overlapBounds: PixelBounds?
    public let comparedPixelCount: Int
    public let mismatchedPixelCount: Int
    public let mismatchRatio: Double
    public let maximumChannelDifference: UInt8
    public let averageChannelDifference: Double
    public let mismatchBounds: PixelBounds?
    public let mismatchMask: ImageMismatchMask

    public init(
        dimensionStatus: ImageDimensionStatus,
        overlapBounds: PixelBounds?,
        comparedPixelCount: Int,
        mismatchedPixelCount: Int,
        mismatchRatio: Double,
        maximumChannelDifference: UInt8,
        averageChannelDifference: Double,
        mismatchBounds: PixelBounds?,
        mismatchMask: ImageMismatchMask
    ) {
        self.dimensionStatus = dimensionStatus
        self.overlapBounds = overlapBounds
        self.comparedPixelCount = comparedPixelCount
        self.mismatchedPixelCount = mismatchedPixelCount
        self.mismatchRatio = mismatchRatio
        self.maximumChannelDifference = maximumChannelDifference
        self.averageChannelDifference = averageChannelDifference
        self.mismatchBounds = mismatchBounds
        self.mismatchMask = mismatchMask
    }

    public var hasPixelDifferences: Bool {
        mismatchedPixelCount > 0
    }
}

/// Compares two RGBA8 buffers over their offset-adjusted intersection.
public struct ImageComparison: Sendable {
    public init() {}

    public func compare(
        _ left: RGBAPixelBuffer,
        to right: RGBAPixelBuffer,
        options: ImageComparisonOptions = .init()
    ) -> ImageComparisonResult {
        let dimensionStatus: ImageDimensionStatus =
            left.width == right.width && left.height == right.height ? .equal : .different

        guard let horizontal = overlapAxis(
            leftLength: left.width,
            rightLength: right.width,
            offset: options.xOffset
        ), let vertical = overlapAxis(
            leftLength: left.height,
            rightLength: right.height,
            offset: options.yOffset
        ) else {
            return emptyResult(dimensionStatus: dimensionStatus)
        }

        // Each axis is bounded by a validated source buffer, so this product
        // cannot exceed either buffer's already validated pixel count.
        let comparedPixelCount = horizontal.count * vertical.count
        var mask = Array(repeating: UInt8(0), count: comparedPixelCount)
        var mismatchedPixelCount = 0
        var maximumChannelDifference: UInt8 = 0
        var channelDifferenceTotal = 0.0
        let comparedChannelCount = options.compareAlpha ? 4 : 3

        var minimumMismatchX = Int.max
        var minimumMismatchY = Int.max
        var maximumMismatchX = Int.min
        var maximumMismatchY = Int.min

        for localY in 0..<vertical.count {
            let leftY = vertical.leftStart + localY
            let rightY = vertical.rightStart + localY

            for localX in 0..<horizontal.count {
                let leftX = horizontal.leftStart + localX
                let rightX = horizontal.rightStart + localX
                let leftByteOffset = ((leftY * left.width) + leftX) * RGBAPixelBuffer.bytesPerPixel
                let rightByteOffset = ((rightY * right.width) + rightX) * RGBAPixelBuffer.bytesPerPixel
                var pixelMismatches = false

                for channel in 0..<comparedChannelCount {
                    let leftValue = left.bytes[leftByteOffset + channel]
                    let rightValue = right.bytes[rightByteOffset + channel]
                    let difference = absoluteDifference(leftValue, rightValue)
                    maximumChannelDifference = max(maximumChannelDifference, difference)
                    channelDifferenceTotal += Double(difference)
                    if difference > options.channelTolerance {
                        pixelMismatches = true
                    }
                }

                if pixelMismatches {
                    mismatchedPixelCount += 1
                    mask[(localY * horizontal.count) + localX] = 255
                    minimumMismatchX = min(minimumMismatchX, leftX)
                    minimumMismatchY = min(minimumMismatchY, leftY)
                    maximumMismatchX = max(maximumMismatchX, leftX)
                    maximumMismatchY = max(maximumMismatchY, leftY)
                }
            }
        }

        let channelSampleCount = Double(comparedPixelCount) * Double(comparedChannelCount)
        let mismatchBounds: PixelBounds?
        if mismatchedPixelCount == 0 {
            mismatchBounds = nil
        } else {
            mismatchBounds = PixelBounds(
                x: minimumMismatchX,
                y: minimumMismatchY,
                width: maximumMismatchX - minimumMismatchX + 1,
                height: maximumMismatchY - minimumMismatchY + 1
            )
        }

        let overlapBounds = PixelBounds(
            x: horizontal.leftStart,
            y: vertical.leftStart,
            width: horizontal.count,
            height: vertical.count
        )

        return ImageComparisonResult(
            dimensionStatus: dimensionStatus,
            overlapBounds: overlapBounds,
            comparedPixelCount: comparedPixelCount,
            mismatchedPixelCount: mismatchedPixelCount,
            mismatchRatio: Double(mismatchedPixelCount) / Double(comparedPixelCount),
            maximumChannelDifference: maximumChannelDifference,
            averageChannelDifference: channelDifferenceTotal / channelSampleCount,
            mismatchBounds: mismatchBounds,
            mismatchMask: ImageMismatchMask(
                originX: horizontal.leftStart,
                originY: vertical.leftStart,
                width: horizontal.count,
                height: vertical.count,
                values: mask
            )
        )
    }

    private func emptyResult(dimensionStatus: ImageDimensionStatus) -> ImageComparisonResult {
        ImageComparisonResult(
            dimensionStatus: dimensionStatus,
            overlapBounds: nil,
            comparedPixelCount: 0,
            mismatchedPixelCount: 0,
            mismatchRatio: 0,
            maximumChannelDifference: 0,
            averageChannelDifference: 0,
            mismatchBounds: nil,
            mismatchMask: ImageMismatchMask(
                originX: 0,
                originY: 0,
                width: 0,
                height: 0,
                values: []
            )
        )
    }

    /// Returns corresponding starts and a count without ever computing
    /// `offset + length`, which could overflow for arbitrary integer offsets.
    private func overlapAxis(
        leftLength: Int,
        rightLength: Int,
        offset: Int
    ) -> AxisOverlap? {
        guard leftLength > 0, rightLength > 0 else { return nil }

        if offset >= 0 {
            guard offset < leftLength else { return nil }
            let count = min(leftLength - offset, rightLength)
            guard count > 0 else { return nil }
            return AxisOverlap(leftStart: offset, rightStart: 0, count: count)
        }

        // Negating Int.min traps, and its magnitude is necessarily beyond any
        // valid in-memory buffer length.
        guard offset != Int.min else { return nil }
        let rightStart = -offset
        guard rightStart < rightLength else { return nil }
        let count = min(leftLength, rightLength - rightStart)
        guard count > 0 else { return nil }
        return AxisOverlap(leftStart: 0, rightStart: rightStart, count: count)
    }

    private func absoluteDifference(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }
}

private struct AxisOverlap {
    let leftStart: Int
    let rightStart: Int
    let count: Int
}
