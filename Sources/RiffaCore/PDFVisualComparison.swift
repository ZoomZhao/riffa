import CoreGraphics
import Foundation

public enum PDFVisualLimitKind: String, Codable, Sendable {
    case maximumDocumentByteCount
    case maximumDimension
    case maximumPixelCount
    case maximumRasterByteCount
    case maximumResultByteCount
}

/// Path-free failures for the selected-page visual comparison pipeline.
public enum PDFVisualComparisonError: Error, Equatable, Codable, Sendable {
    case invalidLimit(kind: PDFVisualLimitKind, value: Int)
    case documentByteLimitExceeded(actual: Int, limit: Int)
    case invalidPageGeometry(side: PDFComparisonSide)
    case invalidCanvasGeometry
    case pixelLimitExceeded(actual: Int, limit: Int)
    case rasterByteLimitExceeded(actual: Int, limit: Int)
    case resultByteLimitExceeded(actual: Int, limit: Int)
    case invalidRasterByteCount(expected: Int, actual: Int)
    case invalidMaskByteCount(expected: Int, actual: Int)
    case corruptedDocument(side: PDFComparisonSide)
    case pageUnavailable(side: PDFComparisonSide, pageNumber: Int)
    case renderingFailed(side: PDFComparisonSide)
    case inconsistentPortableResult
}

extension PDFVisualComparisonError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidLimit(kind, value):
            "The visual comparison limit \(kind.rawValue) has an invalid value (\(value))."
        case let .documentByteLimitExceeded(actual, limit):
            "The PDF source has \(actual) bytes, exceeding the \(limit)-byte visual rendering limit."
        case let .invalidPageGeometry(side):
            "The \(side.rawValue) PDF page has invalid visual geometry."
        case .invalidCanvasGeometry:
            "The selected PDF pages cannot be placed on a valid visual canvas."
        case let .pixelLimitExceeded(actual, limit):
            "The visual canvas requires \(actual) pixels, exceeding the \(limit)-pixel limit."
        case let .rasterByteLimitExceeded(actual, limit):
            "A rendered PDF page requires \(actual) bytes, exceeding the \(limit)-byte raster limit."
        case let .resultByteLimitExceeded(actual, limit):
            "The visual result requires \(actual) bytes, exceeding the \(limit)-byte result limit."
        case let .invalidRasterByteCount(expected, actual):
            "A visual raster has \(actual) bytes; \(expected) were required."
        case let .invalidMaskByteCount(expected, actual):
            "A visual difference mask has \(actual) bytes; \(expected) were required."
        case let .corruptedDocument(side):
            "The \(side.rawValue) input is not a valid PDF document."
        case let .pageUnavailable(side, pageNumber):
            "Page \(pageNumber) is unavailable in the \(side.rawValue) PDF."
        case let .renderingFailed(side):
            "The \(side.rawValue) PDF page could not be rendered safely."
        case .inconsistentPortableResult:
            "The portable PDF visual result is internally inconsistent."
        }
    }
}

/// Strict resource limits for one selected-page visual comparison.
///
/// The initializer and decoder reject invalid values instead of clamping them,
/// so persisted or untrusted settings fail closed.
public struct PDFVisualComparisonLimits: Equatable, Codable, Sendable {
    public static let defaultMaximumDocumentByteCount = 256 * 1_024 * 1_024
    public static let defaultMaximumDimension = 1_200
    public static let defaultMaximumPixelCount = 1_440_000
    public static let defaultMaximumRasterByteCount = 5_760_000
    public static let defaultMaximumResultByteCount = 12_960_000

    private static let hardMaximumDocumentByteCount = 512 * 1_024 * 1_024
    private static let hardMaximumDimension = 16_384
    private static let hardMaximumPixelCount = 64 * 1_024 * 1_024
    private static let hardMaximumRasterByteCount = 256 * 1_024 * 1_024
    private static let hardMaximumResultByteCount = 512 * 1_024 * 1_024

    public static let standard: Self = {
        do {
            return try Self()
        } catch {
            preconditionFailure("Invalid built-in PDF visual comparison limits: \(error)")
        }
    }()

    public let maximumDocumentByteCount: Int
    public let maximumDimension: Int
    public let maximumPixelCount: Int
    public let maximumRasterByteCount: Int
    public let maximumResultByteCount: Int

    public init(
        maximumDocumentByteCount: Int = Self.defaultMaximumDocumentByteCount,
        maximumDimension: Int = Self.defaultMaximumDimension,
        maximumPixelCount: Int = Self.defaultMaximumPixelCount,
        maximumRasterByteCount: Int = Self.defaultMaximumRasterByteCount,
        maximumResultByteCount: Int = Self.defaultMaximumResultByteCount
    ) throws {
        try Self.validate(
            maximumDocumentByteCount,
            kind: .maximumDocumentByteCount,
            hardMaximum: Self.hardMaximumDocumentByteCount
        )
        try Self.validate(
            maximumDimension,
            kind: .maximumDimension,
            hardMaximum: Self.hardMaximumDimension
        )
        try Self.validate(
            maximumPixelCount,
            kind: .maximumPixelCount,
            hardMaximum: Self.hardMaximumPixelCount
        )
        try Self.validate(
            maximumRasterByteCount,
            kind: .maximumRasterByteCount,
            hardMaximum: Self.hardMaximumRasterByteCount
        )
        try Self.validate(
            maximumResultByteCount,
            kind: .maximumResultByteCount,
            hardMaximum: Self.hardMaximumResultByteCount
        )

        self.maximumDocumentByteCount = maximumDocumentByteCount
        self.maximumDimension = maximumDimension
        self.maximumPixelCount = maximumPixelCount
        self.maximumRasterByteCount = maximumRasterByteCount
        self.maximumResultByteCount = maximumResultByteCount
    }

    private enum CodingKeys: String, CodingKey {
        case maximumDocumentByteCount
        case maximumDimension
        case maximumPixelCount
        case maximumRasterByteCount
        case maximumResultByteCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumDocumentByteCount: container.decode(
                Int.self,
                forKey: .maximumDocumentByteCount
            ),
            maximumDimension: container.decode(Int.self, forKey: .maximumDimension),
            maximumPixelCount: container.decode(Int.self, forKey: .maximumPixelCount),
            maximumRasterByteCount: container.decode(Int.self, forKey: .maximumRasterByteCount),
            maximumResultByteCount: container.decode(Int.self, forKey: .maximumResultByteCount)
        )
    }

    private static func validate(
        _ value: Int,
        kind: PDFVisualLimitKind,
        hardMaximum: Int
    ) throws {
        guard value > 0, value <= hardMaximum else {
            throw PDFVisualComparisonError.invalidLimit(kind: kind, value: value)
        }
    }
}

/// The shared pixel canvas used for both MediaBox renders.
public struct PDFVisualCanvasPlan: Equatable, Codable, Sendable {
    public let width: Int
    public let height: Int
    public let pointWidth: Double
    public let pointHeight: Double
    public let pointsToPixelsScale: Double

    public init(
        width: Int,
        height: Int,
        pointWidth: Double,
        pointHeight: Double,
        pointsToPixelsScale: Double
    ) throws {
        guard width > 0,
              height > 0,
              width <= 16_384,
              height <= 16_384,
              pointWidth.isFinite,
              pointHeight.isFinite,
              pointWidth > 0,
              pointHeight > 0,
              pointsToPixelsScale.isFinite,
              pointsToPixelsScale > 0 else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= 64 * 1_024 * 1_024 else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        let scaledWidth = pointWidth * pointsToPixelsScale
        let scaledHeight = pointHeight * pointsToPixelsScale
        guard scaledWidth.isFinite,
              scaledHeight.isFinite,
              scaledWidth > 0,
              scaledHeight > 0,
              scaledWidth < Double(Int.max),
              scaledHeight < Double(Int.max),
              width == max(1, Int(floor(scaledWidth))),
              height == max(1, Int(floor(scaledHeight))) else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        self.width = width
        self.height = height
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.pointsToPixelsScale = pointsToPixelsScale
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case pointWidth
        case pointHeight
        case pointsToPixelsScale
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            width: container.decode(Int.self, forKey: .width),
            height: container.decode(Int.self, forKey: .height),
            pointWidth: container.decode(Double.self, forKey: .pointWidth),
            pointHeight: container.decode(Double.self, forKey: .pointHeight),
            pointsToPixelsScale: container.decode(Double.self, forKey: .pointsToPixelsScale)
        )
    }
}

/// A portable RGBA8 raster. It intentionally contains no image framework
/// object, source bytes, or source locator.
public struct PDFVisualRaster: Equatable, Codable, Sendable {
    public let width: Int
    public let height: Int
    public let rgba8: [UInt8]

    public init(width: Int, height: Int, rgba8: [UInt8]) throws {
        let expected = try Self.expectedByteCount(width: width, height: height)
        let hardMaximumByteCount = 256 * 1_024 * 1_024
        guard expected <= hardMaximumByteCount else {
            throw PDFVisualComparisonError.rasterByteLimitExceeded(
                actual: expected,
                limit: hardMaximumByteCount
            )
        }
        guard rgba8.count == expected else {
            throw PDFVisualComparisonError.invalidRasterByteCount(
                expected: expected,
                actual: rgba8.count
            )
        }
        self.width = width
        self.height = height
        self.rgba8 = rgba8
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case rgba8
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        let expected = try Self.expectedByteCount(width: width, height: height)
        let hardMaximumByteCount = 256 * 1_024 * 1_024
        guard expected <= hardMaximumByteCount else {
            throw PDFVisualComparisonError.rasterByteLimitExceeded(
                actual: expected,
                limit: hardMaximumByteCount
            )
        }
        var byteContainer = try container.nestedUnkeyedContainer(forKey: .rgba8)
        if let count = byteContainer.count, count != expected {
            throw PDFVisualComparisonError.invalidRasterByteCount(
                expected: expected,
                actual: count
            )
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(expected)
        for _ in 0..<expected {
            guard !byteContainer.isAtEnd else {
                throw PDFVisualComparisonError.invalidRasterByteCount(
                    expected: expected,
                    actual: byteContainer.currentIndex
                )
            }
            bytes.append(try byteContainer.decode(UInt8.self))
        }
        guard byteContainer.isAtEnd else {
            throw PDFVisualComparisonError.invalidRasterByteCount(
                expected: expected,
                actual: byteContainer.count ?? expected + 1
            )
        }
        try self.init(
            width: width,
            height: height,
            rgba8: bytes
        )
    }

    fileprivate static func expectedByteCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(
            by: RGBAPixelBuffer.bytesPerPixel
        )
        guard !pixelOverflow, !byteOverflow else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        return bytes
    }
}

/// A portable one-byte-per-pixel heat-map source. Values are 0 for a match
/// and 255 for a mismatch.
public struct PDFVisualDifferenceMask: Equatable, Codable, Sendable {
    public let width: Int
    public let height: Int
    public let values: [UInt8]

    public init(width: Int, height: Int, values: [UInt8]) throws {
        guard width > 0, height > 0 else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        let (expected, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        let hardMaximumByteCount = 64 * 1_024 * 1_024
        guard expected <= hardMaximumByteCount else {
            throw PDFVisualComparisonError.resultByteLimitExceeded(
                actual: expected,
                limit: hardMaximumByteCount
            )
        }
        guard values.count == expected else {
            throw PDFVisualComparisonError.invalidMaskByteCount(
                expected: expected,
                actual: values.count
            )
        }
        guard values.allSatisfy({ $0 == 0 || $0 == 255 }) else {
            throw PDFVisualComparisonError.inconsistentPortableResult
        }
        self.width = width
        self.height = height
        self.values = values
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case values
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        guard width > 0, height > 0 else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        let (expected, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        let hardMaximumByteCount = 64 * 1_024 * 1_024
        guard expected <= hardMaximumByteCount else {
            throw PDFVisualComparisonError.resultByteLimitExceeded(
                actual: expected,
                limit: hardMaximumByteCount
            )
        }
        var valueContainer = try container.nestedUnkeyedContainer(forKey: .values)
        if let count = valueContainer.count, count != expected {
            throw PDFVisualComparisonError.invalidMaskByteCount(
                expected: expected,
                actual: count
            )
        }
        var values: [UInt8] = []
        values.reserveCapacity(expected)
        for _ in 0..<expected {
            guard !valueContainer.isAtEnd else {
                throw PDFVisualComparisonError.invalidMaskByteCount(
                    expected: expected,
                    actual: valueContainer.currentIndex
                )
            }
            values.append(try valueContainer.decode(UInt8.self))
        }
        guard valueContainer.isAtEnd else {
            throw PDFVisualComparisonError.invalidMaskByteCount(
                expected: expected,
                actual: valueContainer.count ?? expected + 1
            )
        }
        try self.init(
            width: width,
            height: height,
            values: values
        )
    }
}

/// A selected-page visual result. This is deliberately separate from
/// `PDFComparisonResult`: producing it never changes page/text statuses and it
/// is not included in the existing whole-document reports.
public struct PDFVisualPageComparisonResult: Equatable, Codable, Sendable {
    public let pageNumber: Int
    public let channelTolerance: UInt8
    public let canvas: PDFVisualCanvasPlan
    public let left: PDFVisualRaster
    public let right: PDFVisualRaster
    public let differenceMask: PDFVisualDifferenceMask
    public let comparedPixelCount: Int
    public let mismatchedPixelCount: Int
    public let mismatchRatio: Double
    public let maximumChannelDifference: UInt8
    public let averageChannelDifference: Double
    public let mismatchBounds: PixelBounds?

    public init(
        pageNumber: Int,
        channelTolerance: UInt8,
        canvas: PDFVisualCanvasPlan,
        left: PDFVisualRaster,
        right: PDFVisualRaster,
        differenceMask: PDFVisualDifferenceMask,
        comparedPixelCount: Int,
        mismatchedPixelCount: Int,
        mismatchRatio: Double,
        maximumChannelDifference: UInt8,
        averageChannelDifference: Double,
        mismatchBounds: PixelBounds?
    ) throws {
        try Self.validate(
            pageNumber: pageNumber,
            channelTolerance: channelTolerance,
            canvas: canvas,
            left: left,
            right: right,
            differenceMask: differenceMask,
            comparedPixelCount: comparedPixelCount,
            mismatchedPixelCount: mismatchedPixelCount,
            mismatchRatio: mismatchRatio,
            maximumChannelDifference: maximumChannelDifference,
            averageChannelDifference: averageChannelDifference,
            mismatchBounds: mismatchBounds
        )
        self.pageNumber = pageNumber
        self.channelTolerance = channelTolerance
        self.canvas = canvas
        self.left = left
        self.right = right
        self.differenceMask = differenceMask
        self.comparedPixelCount = comparedPixelCount
        self.mismatchedPixelCount = mismatchedPixelCount
        self.mismatchRatio = mismatchRatio
        self.maximumChannelDifference = maximumChannelDifference
        self.averageChannelDifference = averageChannelDifference
        self.mismatchBounds = mismatchBounds
    }

    private enum CodingKeys: String, CodingKey {
        case pageNumber
        case channelTolerance
        case canvas
        case left
        case right
        case differenceMask
        case comparedPixelCount
        case mismatchedPixelCount
        case mismatchRatio
        case maximumChannelDifference
        case averageChannelDifference
        case mismatchBounds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            pageNumber: container.decode(Int.self, forKey: .pageNumber),
            channelTolerance: container.decode(UInt8.self, forKey: .channelTolerance),
            canvas: container.decode(PDFVisualCanvasPlan.self, forKey: .canvas),
            left: container.decode(PDFVisualRaster.self, forKey: .left),
            right: container.decode(PDFVisualRaster.self, forKey: .right),
            differenceMask: container.decode(
                PDFVisualDifferenceMask.self,
                forKey: .differenceMask
            ),
            comparedPixelCount: container.decode(Int.self, forKey: .comparedPixelCount),
            mismatchedPixelCount: container.decode(Int.self, forKey: .mismatchedPixelCount),
            mismatchRatio: container.decode(Double.self, forKey: .mismatchRatio),
            maximumChannelDifference: container.decode(
                UInt8.self,
                forKey: .maximumChannelDifference
            ),
            averageChannelDifference: container.decode(
                Double.self,
                forKey: .averageChannelDifference
            ),
            mismatchBounds: container.decodeIfPresent(PixelBounds.self, forKey: .mismatchBounds)
        )
    }

    public var hasPixelDifferences: Bool {
        mismatchedPixelCount > 0
    }

    private static func validate(
        pageNumber: Int,
        channelTolerance: UInt8,
        canvas: PDFVisualCanvasPlan,
        left: PDFVisualRaster,
        right: PDFVisualRaster,
        differenceMask: PDFVisualDifferenceMask,
        comparedPixelCount: Int,
        mismatchedPixelCount: Int,
        mismatchRatio: Double,
        maximumChannelDifference: UInt8,
        averageChannelDifference: Double,
        mismatchBounds: PixelBounds?
    ) throws {
        let (expectedPixels, overflow) = canvas.width.multipliedReportingOverflow(
            by: canvas.height
        )
        let rasterTotal = left.rgba8.count.addingReportingOverflow(right.rgba8.count)
        let portableTotal = rasterTotal.partialValue.addingReportingOverflow(
            differenceMask.values.count
        )
        guard !overflow,
              !rasterTotal.overflow,
              !portableTotal.overflow,
              portableTotal.partialValue <= 512 * 1_024 * 1_024,
              pageNumber > 0,
              left.width == canvas.width,
              left.height == canvas.height,
              right.width == canvas.width,
              right.height == canvas.height,
              differenceMask.width == canvas.width,
              differenceMask.height == canvas.height,
              comparedPixelCount == expectedPixels,
              mismatchedPixelCount >= 0,
              mismatchedPixelCount <= comparedPixelCount,
              mismatchRatio.isFinite,
              mismatchRatio == Double(mismatchedPixelCount) / Double(comparedPixelCount),
              averageChannelDifference.isFinite,
              (0...255).contains(averageChannelDifference) else {
            throw PDFVisualComparisonError.inconsistentPortableResult
        }

        var mismatchCount = 0
        var minimumX = Int.max
        var minimumY = Int.max
        var maximumX = Int.min
        var maximumY = Int.min
        for (offset, value) in differenceMask.values.enumerated() where value == 255 {
            mismatchCount += 1
            let x = offset % canvas.width
            let y = offset / canvas.width
            minimumX = min(minimumX, x)
            minimumY = min(minimumY, y)
            maximumX = max(maximumX, x)
            maximumY = max(maximumY, y)
        }
        let expectedBounds: PixelBounds? = mismatchCount == 0
            ? nil
            : PixelBounds(
                x: minimumX,
                y: minimumY,
                width: maximumX - minimumX + 1,
                height: maximumY - minimumY + 1
            )
        guard mismatchCount == mismatchedPixelCount,
              expectedBounds == mismatchBounds,
              (mismatchedPixelCount == 0
                  ? maximumChannelDifference <= channelTolerance
                  : maximumChannelDifference > channelTolerance) else {
            throw PDFVisualComparisonError.inconsistentPortableResult
        }
    }
}

/// Pure planning and pixel comparison for selected PDF pages.
public struct PDFVisualPageComparator: Sendable {
    public static let defaultChannelTolerance: UInt8 = 8

    public let limits: PDFVisualComparisonLimits

    public init(limits: PDFVisualComparisonLimits = .standard) {
        self.limits = limits
    }

    public func makeCanvasPlan(
        left: PDFPageDimensions,
        right: PDFPageDimensions
    ) throws -> PDFVisualCanvasPlan {
        try validate(dimensions: left, side: .left)
        try validate(dimensions: right, side: .right)

        let pointWidth = max(left.width, right.width)
        let pointHeight = max(left.height, right.height)
        let maximumPointDimension = max(pointWidth, pointHeight)
        let dimensionScale = Double(limits.maximumDimension) / maximumPointDimension
        let area = pointWidth * pointHeight
        guard area.isFinite, area > 0 else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        let pixelScale = sqrt(Double(limits.maximumPixelCount) / area)
        let scale = min(dimensionScale, pixelScale)
        guard scale.isFinite, scale > 0 else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }

        let width = max(1, Int(floor(pointWidth * scale)))
        let height = max(1, Int(floor(pointHeight * scale)))
        let pixelCount = try checkedPixelCount(width: width, height: height)
        guard pixelCount <= limits.maximumPixelCount else {
            throw PDFVisualComparisonError.pixelLimitExceeded(
                actual: pixelCount,
                limit: limits.maximumPixelCount
            )
        }
        let byteCount = try PDFVisualRaster.expectedByteCount(width: width, height: height)
        guard byteCount <= limits.maximumRasterByteCount else {
            throw PDFVisualComparisonError.rasterByteLimitExceeded(
                actual: byteCount,
                limit: limits.maximumRasterByteCount
            )
        }
        let (resultByteCount, resultOverflow) = pixelCount.multipliedReportingOverflow(by: 9)
        guard !resultOverflow else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        guard resultByteCount <= limits.maximumResultByteCount else {
            throw PDFVisualComparisonError.resultByteLimitExceeded(
                actual: resultByteCount,
                limit: limits.maximumResultByteCount
            )
        }

        return try PDFVisualCanvasPlan(
            width: width,
            height: height,
            pointWidth: pointWidth,
            pointHeight: pointHeight,
            pointsToPixelsScale: scale
        )
    }

    public func compare(
        left: PDFVisualRaster,
        right: PDFVisualRaster,
        pageNumber: Int,
        canvas: PDFVisualCanvasPlan,
        channelTolerance: UInt8 = Self.defaultChannelTolerance
    ) throws -> PDFVisualPageComparisonResult {
        guard pageNumber > 0,
              left.width == canvas.width,
              left.height == canvas.height,
              right.width == canvas.width,
              right.height == canvas.height else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }

        let pixelCount = try checkedPixelCount(width: canvas.width, height: canvas.height)
        guard pixelCount <= limits.maximumPixelCount else {
            throw PDFVisualComparisonError.pixelLimitExceeded(
                actual: pixelCount,
                limit: limits.maximumPixelCount
            )
        }
        guard left.rgba8.count <= limits.maximumRasterByteCount else {
            throw PDFVisualComparisonError.rasterByteLimitExceeded(
                actual: left.rgba8.count,
                limit: limits.maximumRasterByteCount
            )
        }
        guard right.rgba8.count <= limits.maximumRasterByteCount else {
            throw PDFVisualComparisonError.rasterByteLimitExceeded(
                actual: right.rgba8.count,
                limit: limits.maximumRasterByteCount
            )
        }

        let firstTotal = left.rgba8.count.addingReportingOverflow(right.rgba8.count)
        let finalTotal = firstTotal.partialValue.addingReportingOverflow(pixelCount)
        guard !firstTotal.overflow, !finalTotal.overflow else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        guard finalTotal.partialValue <= limits.maximumResultByteCount else {
            throw PDFVisualComparisonError.resultByteLimitExceeded(
                actual: finalTotal.partialValue,
                limit: limits.maximumResultByteCount
            )
        }

        let leftBuffer = try RGBAPixelBuffer(
            width: left.width,
            height: left.height,
            bytes: left.rgba8
        )
        let rightBuffer = try RGBAPixelBuffer(
            width: right.width,
            height: right.height,
            bytes: right.rgba8
        )
        let comparison = ImageComparison().compare(
            leftBuffer,
            to: rightBuffer,
            options: ImageComparisonOptions(
                channelTolerance: channelTolerance,
                compareAlpha: false
            )
        )
        let mask = try PDFVisualDifferenceMask(
            width: comparison.mismatchMask.width,
            height: comparison.mismatchMask.height,
            values: comparison.mismatchMask.values
        )

        return try PDFVisualPageComparisonResult(
            pageNumber: pageNumber,
            channelTolerance: channelTolerance,
            canvas: canvas,
            left: left,
            right: right,
            differenceMask: mask,
            comparedPixelCount: comparison.comparedPixelCount,
            mismatchedPixelCount: comparison.mismatchedPixelCount,
            mismatchRatio: comparison.mismatchRatio,
            maximumChannelDifference: comparison.maximumChannelDifference,
            averageChannelDifference: comparison.averageChannelDifference,
            mismatchBounds: comparison.mismatchBounds
        )
    }

    /// Adds task-cancellation boundaries around the strictly bounded pixel
    /// loop. The underlying shared `ImageComparison` remains nonthrowing; with
    /// the standard limits it can examine at most 1.44 million pixels before
    /// the second checkpoint.
    public func compareCheckingCancellation(
        left: PDFVisualRaster,
        right: PDFVisualRaster,
        pageNumber: Int,
        canvas: PDFVisualCanvasPlan,
        channelTolerance: UInt8 = Self.defaultChannelTolerance
    ) throws -> PDFVisualPageComparisonResult {
        try Task.checkCancellation()
        let result = try compare(
            left: left,
            right: right,
            pageNumber: pageNumber,
            canvas: canvas,
            channelTolerance: channelTolerance
        )
        try Task.checkCancellation()
        return result
    }

    private func validate(
        dimensions: PDFPageDimensions,
        side: PDFComparisonSide
    ) throws {
        guard dimensions.width.isFinite,
              dimensions.height.isFinite,
              dimensions.width > 0,
              dimensions.height > 0 else {
            throw PDFVisualComparisonError.invalidPageGeometry(side: side)
        }
    }

    private func checkedPixelCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        return pixelCount
    }
}

/// Deterministically renders one PDF MediaBox into a preplanned white RGBA8
/// canvas. Callers control document lifetime by passing only the bounded bytes
/// for one side at a time.
public struct PDFVisualPageRasterizer: Sendable {
    public let limits: PDFVisualComparisonLimits

    public init(limits: PDFVisualComparisonLimits = .standard) {
        self.limits = limits
    }

    public func render(
        documentData: Data,
        side: PDFComparisonSide,
        pageNumber: Int,
        expectedDimensions: PDFPageDimensions,
        expectedRotationDegrees: Int,
        canvas: PDFVisualCanvasPlan
    ) throws -> PDFVisualRaster {
        guard documentData.count <= limits.maximumDocumentByteCount else {
            throw PDFVisualComparisonError.documentByteLimitExceeded(
                actual: documentData.count,
                limit: limits.maximumDocumentByteCount
            )
        }
        guard pageNumber > 0 else {
            throw PDFVisualComparisonError.pageUnavailable(side: side, pageNumber: pageNumber)
        }
        guard expectedDimensions.width.isFinite,
              expectedDimensions.height.isFinite,
              expectedDimensions.width > 0,
              expectedDimensions.height > 0 else {
            throw PDFVisualComparisonError.invalidPageGeometry(side: side)
        }
        guard canvas.width > 0,
              canvas.height > 0,
              canvas.width <= limits.maximumDimension,
              canvas.height <= limits.maximumDimension,
              canvas.pointsToPixelsScale.isFinite,
              canvas.pointsToPixelsScale > 0 else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }

        let byteCount = try PDFVisualRaster.expectedByteCount(
            width: canvas.width,
            height: canvas.height
        )
        let pixelCount = byteCount / RGBAPixelBuffer.bytesPerPixel
        guard pixelCount <= limits.maximumPixelCount else {
            throw PDFVisualComparisonError.pixelLimitExceeded(
                actual: pixelCount,
                limit: limits.maximumPixelCount
            )
        }
        guard byteCount <= limits.maximumRasterByteCount else {
            throw PDFVisualComparisonError.rasterByteLimitExceeded(
                actual: byteCount,
                limit: limits.maximumRasterByteCount
            )
        }

        guard let provider = CGDataProvider(data: documentData as CFData),
              let document = CGPDFDocument(provider) else {
            throw PDFVisualComparisonError.corruptedDocument(side: side)
        }
        guard document.numberOfPages >= pageNumber,
              let page = document.page(at: pageNumber) else {
            throw PDFVisualComparisonError.pageUnavailable(side: side, pageNumber: pageNumber)
        }

        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width.isFinite,
              mediaBox.height.isFinite,
              mediaBox.width > 0,
              mediaBox.height > 0 else {
            throw PDFVisualComparisonError.invalidPageGeometry(side: side)
        }
        let largestGeometryDimension = max(
            max(mediaBox.width, mediaBox.height),
            max(expectedDimensions.width, expectedDimensions.height)
        )
        let geometryTolerance = max(0.01, largestGeometryDimension * 0.000_000_1)
        guard abs(mediaBox.width - expectedDimensions.width) <= geometryTolerance,
              abs(mediaBox.height - expectedDimensions.height) <= geometryTolerance,
              normalizedRotation(Int(page.rotationAngle))
                == normalizedRotation(expectedRotationDegrees) else {
            throw PDFVisualComparisonError.invalidPageGeometry(side: side)
        }

        let proposedTargetWidth = expectedDimensions.width * canvas.pointsToPixelsScale
        let proposedTargetHeight = expectedDimensions.height * canvas.pointsToPixelsScale
        guard proposedTargetWidth.isFinite,
              proposedTargetHeight.isFinite,
              proposedTargetWidth > 0,
              proposedTargetHeight > 0,
              expectedDimensions.width <= canvas.pointWidth,
              expectedDimensions.height <= canvas.pointHeight else {
            throw PDFVisualComparisonError.invalidCanvasGeometry
        }
        let targetWidth = max(
            1,
            Int(floor(min(Double(canvas.width), proposedTargetWidth)))
        )
        let targetHeight = max(
            1,
            Int(floor(min(Double(canvas.height), proposedTargetHeight)))
        )
        let targetRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        var bytes = Array(repeating: UInt8(255), count: byteCount)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        let rendered = bytes.withUnsafeMutableBytes { rawBytes -> Bool in
            guard let baseAddress = rawBytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: canvas.width,
                    height: canvas.height,
                    bitsPerComponent: 8,
                    bytesPerRow: canvas.width * RGBAPixelBuffer.bytesPerPixel,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                return false
            }

            context.setBlendMode(.normal)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
            context.saveGState()
            context.concatenate(
                page.getDrawingTransform(
                    .mediaBox,
                    rect: targetRect,
                    rotate: 0,
                    preserveAspectRatio: true
                )
            )
            context.drawPDFPage(page)
            context.restoreGState()
            context.flush()
            return true
        }
        guard rendered else {
            throw PDFVisualComparisonError.renderingFailed(side: side)
        }

        return try PDFVisualRaster(width: canvas.width, height: canvas.height, rgba8: bytes)
    }

    private func normalizedRotation(_ value: Int) -> Int {
        let remainder = value % 360
        return remainder >= 0 ? remainder : remainder + 360
    }
}
