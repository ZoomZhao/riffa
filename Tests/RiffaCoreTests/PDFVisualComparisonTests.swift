import Foundation
import Testing
@testable import RiffaCore

@Suite("PDF selected-page visual comparison")
struct PDFVisualComparisonTests {
    @Test("Limits reject nonpositive, excessive, and invalid decoded values")
    func strictLimits() throws {
        #expect(throws: PDFVisualComparisonError.invalidLimit(
            kind: .maximumDimension,
            value: 0
        )) {
            try PDFVisualComparisonLimits(maximumDimension: 0)
        }
        #expect(throws: PDFVisualComparisonError.invalidLimit(
            kind: .maximumPixelCount,
            value: -1
        )) {
            try PDFVisualComparisonLimits(maximumPixelCount: -1)
        }
        #expect(throws: PDFVisualComparisonError.invalidLimit(
            kind: .maximumDimension,
            value: 16_385
        )) {
            try PDFVisualComparisonLimits(maximumDimension: 16_385)
        }

        let invalidJSON = Data(
            """
            {
              "maximumDocumentByteCount": 268435456,
              "maximumDimension": 1200,
              "maximumPixelCount": 0,
              "maximumRasterByteCount": 5760000,
              "maximumResultByteCount": 12960000
            }
            """.utf8
        )
        #expect(throws: PDFVisualComparisonError.invalidLimit(
            kind: .maximumPixelCount,
            value: 0
        )) {
            try JSONDecoder().decode(PDFVisualComparisonLimits.self, from: invalidJSON)
        }

        let limits = try PDFVisualComparisonLimits(
            maximumDimension: 64,
            maximumPixelCount: 4_096,
            maximumRasterByteCount: 16_384,
            maximumResultByteCount: 36_864
        )
        let decoded = try JSONDecoder().decode(
            PDFVisualComparisonLimits.self,
            from: JSONEncoder().encode(limits)
        )
        #expect(decoded == limits)
        requireSendable(limits)
    }

    @Test("Canvas planning uses one bounded scale for both MediaBoxes")
    func boundedCanvasPlanning() throws {
        let limits = try PDFVisualComparisonLimits(
            maximumDimension: 100,
            maximumPixelCount: 5_000,
            maximumRasterByteCount: 20_000,
            maximumResultByteCount: 45_000
        )
        let plan = try PDFVisualPageComparator(limits: limits).makeCanvasPlan(
            left: PDFPageDimensions(width: 200, height: 100),
            right: PDFPageDimensions(width: 100, height: 200)
        )

        #expect(plan.width == 70)
        #expect(plan.height == 70)
        #expect(plan.width * plan.height <= limits.maximumPixelCount)
        #expect(plan.width <= limits.maximumDimension)
        #expect(plan.height <= limits.maximumDimension)
        #expect(plan.pointWidth == 200)
        #expect(plan.pointHeight == 200)
        #expect(plan.pointsToPixelsScale.isFinite)

        #expect(throws: PDFVisualComparisonError.invalidPageGeometry(side: .left)) {
            try PDFVisualPageComparator(limits: limits).makeCanvasPlan(
                left: PDFPageDimensions(width: .infinity, height: 100),
                right: PDFPageDimensions(width: 100, height: 100)
            )
        }
    }

    @Test("Pixel comparison reuses tolerance semantics and emits a bounded mask")
    func pixelComparison() throws {
        let limits = try PDFVisualComparisonLimits(
            maximumDimension: 2,
            maximumPixelCount: 2,
            maximumRasterByteCount: 8,
            maximumResultByteCount: 18
        )
        let canvas = try PDFVisualCanvasPlan(
            width: 2,
            height: 1,
            pointWidth: 2,
            pointHeight: 1,
            pointsToPixelsScale: 1
        )
        let left = try PDFVisualRaster(
            width: 2,
            height: 1,
            rgba8: [10, 20, 30, 255, 100, 110, 120, 255]
        )
        let right = try PDFVisualRaster(
            width: 2,
            height: 1,
            rgba8: [18, 20, 30, 0, 109, 110, 120, 255]
        )
        let comparator = PDFVisualPageComparator(limits: limits)
        let antialiasFriendly = try comparator.compare(
            left: left,
            right: right,
            pageNumber: 3,
            canvas: canvas
        )
        let strict = try comparator.compare(
            left: left,
            right: right,
            pageNumber: 3,
            canvas: canvas,
            channelTolerance: 7
        )

        #expect(PDFVisualPageComparator.defaultChannelTolerance == 8)
        #expect(antialiasFriendly.mismatchedPixelCount == 1)
        #expect(antialiasFriendly.differenceMask.values == [0, 255])
        #expect(antialiasFriendly.maximumChannelDifference == 9)
        #expect(strict.mismatchedPixelCount == 2)
        // Alpha differs by 255 in the first pixel but is intentionally ignored.
        #expect(strict.maximumChannelDifference == 9)
        #expect(strict.mismatchBounds == PixelBounds(x: 0, y: 0, width: 2, height: 1))
    }

    @Test("Raster, mask, and total byte budgets are independently enforced")
    func byteBudgets() throws {
        let canvas = try PDFVisualCanvasPlan(
            width: 2,
            height: 1,
            pointWidth: 2,
            pointHeight: 1,
            pointsToPixelsScale: 1
        )
        let raster = try PDFVisualRaster(
            width: 2,
            height: 1,
            rgba8: Array(repeating: 255, count: 8)
        )
        let limits = try PDFVisualComparisonLimits(
            maximumDimension: 2,
            maximumPixelCount: 2,
            maximumRasterByteCount: 8,
            maximumResultByteCount: 17
        )

        #expect(throws: PDFVisualComparisonError.resultByteLimitExceeded(actual: 18, limit: 17)) {
            try PDFVisualPageComparator(limits: limits).compare(
                left: raster,
                right: raster,
                pageNumber: 1,
                canvas: canvas
            )
        }
        #expect(throws: PDFVisualComparisonError.invalidRasterByteCount(expected: 8, actual: 7)) {
            try PDFVisualRaster(
                width: 2,
                height: 1,
                rgba8: Array(repeating: 0, count: 7)
            )
        }

        let invalidRasterJSON = Data("{\"width\":2,\"height\":1,\"rgba8\":[0]}".utf8)
        #expect(throws: PDFVisualComparisonError.invalidRasterByteCount(expected: 8, actual: 1)) {
            try JSONDecoder().decode(PDFVisualRaster.self, from: invalidRasterJSON)
        }

        let overlongRasterJSON = Data(
            "{\"width\":2,\"height\":1,\"rgba8\":[0,0,0,0,0,0,0,0,0]}".utf8
        )
        #expect(throws: PDFVisualComparisonError.invalidRasterByteCount(expected: 8, actual: 9)) {
            try JSONDecoder().decode(PDFVisualRaster.self, from: overlongRasterJSON)
        }

        let oversizedRasterJSON = Data(
            "{\"width\":16384,\"height\":16384,\"rgba8\":[]}".utf8
        )
        #expect(throws: PDFVisualComparisonError.rasterByteLimitExceeded(
            actual: 1_073_741_824,
            limit: 268_435_456
        )) {
            try JSONDecoder().decode(PDFVisualRaster.self, from: oversizedRasterJSON)
        }
    }

    @Test("Cancellable comparison observes a superseded task at its pixel boundary")
    func cancellationBoundary() async throws {
        let limits = try PDFVisualComparisonLimits(
            maximumDimension: 1,
            maximumPixelCount: 1,
            maximumRasterByteCount: 4,
            maximumResultByteCount: 9
        )
        let canvas = try PDFVisualCanvasPlan(
            width: 1,
            height: 1,
            pointWidth: 1,
            pointHeight: 1,
            pointsToPixelsScale: 1
        )
        let raster = try PDFVisualRaster(width: 1, height: 1, rgba8: [255, 255, 255, 255])
        let comparator = PDFVisualPageComparator(limits: limits)
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try comparator.compareCheckingCancellation(
                left: raster,
                right: raster,
                pageNumber: 1,
                canvas: canvas
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("Portable result round-trips without URL, Data, or framework objects")
    func portableResult() throws {
        let limits = try PDFVisualComparisonLimits(
            maximumDimension: 1,
            maximumPixelCount: 1,
            maximumRasterByteCount: 4,
            maximumResultByteCount: 9
        )
        let canvas = try PDFVisualCanvasPlan(
            width: 1,
            height: 1,
            pointWidth: 1,
            pointHeight: 1,
            pointsToPixelsScale: 1
        )
        let left = try PDFVisualRaster(width: 1, height: 1, rgba8: [255, 255, 255, 255])
        let right = try PDFVisualRaster(width: 1, height: 1, rgba8: [0, 0, 0, 255])
        let result = try PDFVisualPageComparator(limits: limits).compare(
            left: left,
            right: right,
            pageNumber: 1,
            canvas: canvas
        )

        requireSendable(result)
        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(
            PDFVisualPageComparisonResult.self,
            from: encoded
        )
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(decoded == result)
        #expect(!json.lowercased().contains("url"))
        #expect(!json.lowercased().contains("data"))

        var tamperedObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        tamperedObject["mismatchedPixelCount"] = 0
        let tampered = try JSONSerialization.data(withJSONObject: tamperedObject)
        #expect(throws: PDFVisualComparisonError.inconsistentPortableResult) {
            try JSONDecoder().decode(PDFVisualPageComparisonResult.self, from: tampered)
        }

        let invalidCanvas = Data(
            """
            {
              "width": 2,
              "height": 1,
              "pointWidth": 1,
              "pointHeight": 1,
              "pointsToPixelsScale": 1
            }
            """.utf8
        )
        #expect(throws: PDFVisualComparisonError.invalidCanvasGeometry) {
            try JSONDecoder().decode(PDFVisualCanvasPlan.self, from: invalidCanvas)
        }
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
