import CryptoKit
import CoreGraphics
import Foundation
import Testing
@testable import RiffaCore

@Suite("Native PDF comparison", .serialized)
struct PDFComparisonTests {
    @Test("Identical PDFs preserve page values and compare equal")
    func identicalPDFs() throws {
        try withTemporaryDirectory { directory in
            let data = makePDF(
                pages: [
                    FixturePage(text: "Hello from page one"),
                    FixturePage(text: "Second page")
                ],
                title: "A stable title",
                author: "Riffa"
            )
            let left = directory.appending(path: "left.pdf")
            let right = directory.appending(path: "right.pdf")
            try data.write(to: left)
            try data.write(to: right)

            let result = try PDFComparisonEngine().compare(leftURL: left, rightURL: right)

            #expect(!result.hasDifferences)
            #expect(result.statistics.samePageCount == 2)
            #expect(result.pages.map(\.pageNumber) == [1, 2])
            #expect(result.pages.allSatisfy { $0.status == .same })
            #expect(result.pages[0].left?.extractedText.contains("Hello from page one") == true)
            #expect(result.pages[0].left?.dimensions == PDFPageDimensions(width: 612, height: 792))
            #expect(result.leftDocument.metadata.map(\.key).contains("title"))
            #expect(result.leftDocument.fileByteCount == data.count)
            #expect(result.leftDocument.contentSHA256 == sha256(data))
            #expect(result.rightDocument.contentSHA256 == result.leftDocument.contentSHA256)
        }
    }

    @Test("Preview bytes are bounded and must match the compared size and SHA-256")
    func verifiedPreviewBytes() throws {
        try withTemporaryDirectory { directory in
            let original = makePDF(pages: [FixturePage(text: "Original text")])
            let left = directory.appending(path: "left.pdf")
            let right = directory.appending(path: "right.pdf")
            try original.write(to: left)
            try original.write(to: right)

            let result = try PDFComparisonEngine().compare(leftURL: left, rightURL: right)
            let preview = try PDFComparisonEngine().verifiedPreviewData(
                url: left,
                side: .left,
                matching: result.leftDocument
            )
            #expect(preview == original)

            // Preserve the byte count so the digest check, rather than just
            // the size check, proves that a same-size replacement is rejected.
            let changed = makePDF(pages: [FixturePage(text: "Changed! text")])
            #expect(changed.count == original.count)
            try changed.write(to: left)
            #expect(throws: PDFComparisonError.inputChanged(side: .left)) {
                try PDFComparisonEngine().verifiedPreviewData(
                    url: left,
                    side: .left,
                    matching: result.leftDocument
                )
            }

            #expect(throws: PDFComparisonError.fileTooLarge(
                side: .right,
                actualByteCount: original.count,
                limit: original.count - 1
            )) {
                try PDFComparisonEngine(
                    limits: PDFComparisonLimits(maximumFileByteCount: original.count - 1)
                ).verifiedPreviewData(
                    url: right,
                    side: .right,
                    matching: result.rightDocument
                )
            }
        }
    }

    @Test("Changed page text uses the shared line and inline diff")
    func changedPageText() throws {
        try withTemporaryDirectory { directory in
            let left = directory.appending(path: "left.pdf")
            let right = directory.appending(path: "right.pdf")
            try makePDF(pages: [FixturePage(text: "Alpha line\nShared line")]).write(to: left)
            try makePDF(pages: [FixturePage(text: "Beta line\nShared line")]).write(to: right)

            let result = try PDFComparisonEngine().compare(leftURL: left, rightURL: right)
            let page = try #require(result.pages.first)
            let text = try #require(page.textComparison)

            #expect(result.hasDifferences)
            #expect(page.status == .changed)
            #expect(page.differences == [.text])
            #expect(text.hasDifferences)
            #expect(text.statistics.modifiedLineCount >= 1)
            #expect(text.lines.contains { $0.status == .modified })
            #expect(text.lines.first(where: { $0.status == .modified })?.inlineDifferences.isEmpty == false)
            #expect(text.lines.contains { line in
                line.left?.content.contains("Alpha") == true
                    && line.right?.content.contains("Beta") == true
            })
        }
    }

    @Test("Pages are aligned by number and additions remain side-only")
    func pageAdditionAndDeletion() throws {
        try withTemporaryDirectory { directory in
            let onePage = directory.appending(path: "one.pdf")
            let twoPages = directory.appending(path: "two.pdf")
            try makePDF(pages: [FixturePage(text: "First")]).write(to: onePage)
            try makePDF(pages: [FixturePage(text: "First"), FixturePage(text: "Second")]).write(to: twoPages)

            let added = try PDFComparisonEngine().compare(leftURL: onePage, rightURL: twoPages)
            let deleted = try PDFComparisonEngine().compare(leftURL: twoPages, rightURL: onePage)

            #expect(added.pages.map(\.status) == [.same, .rightOnly])
            #expect(added.pages.map(\.pageNumber) == [1, 2])
            #expect(added.statistics.rightOnlyPageCount == 1)
            #expect(deleted.pages.map(\.status) == [.same, .leftOnly])
            #expect(deleted.statistics.leftOnlyPageCount == 1)
        }
    }

    @Test("Dimensions, rotation, and page labels are distinct change reasons")
    func pageGeometryRotationAndLabel() throws {
        try withTemporaryDirectory { directory in
            let left = directory.appending(path: "left.pdf")
            let right = directory.appending(path: "right.pdf")
            try makePDF(
                pages: [FixturePage(text: "Same", width: 612, height: 792, rotation: 0)],
                labelPrefix: "L-"
            ).write(to: left)
            try makePDF(
                pages: [FixturePage(text: "Same", width: 640, height: 800, rotation: 90)],
                labelPrefix: "R-"
            ).write(to: right)

            let page = try #require(
                PDFComparisonEngine().compare(leftURL: left, rightURL: right).pages.first
            )

            #expect(page.status == .changed)
            #expect(page.differences == [.dimensions, .rotation, .label])
            #expect(page.left?.rotationDegrees == 0)
            #expect(page.right?.rotationDegrees == 90)
            #expect(page.left?.label == "L-1")
            #expect(page.right?.label == "R-1")
        }
    }

    @Test("Stable public document attributes are typed and compared")
    func metadataComparison() throws {
        try withTemporaryDirectory { directory in
            let left = directory.appending(path: "left.pdf")
            let right = directory.appending(path: "right.pdf")
            try makePDF(
                pages: [FixturePage(text: "Same")],
                title: "Original",
                author: "Ada",
                creationDate: "D:20240102030405Z"
            ).write(to: left)
            try makePDF(
                pages: [FixturePage(text: "Same")],
                title: "Revised",
                author: "Ada",
                creationDate: "D:20240102030405Z"
            ).write(to: right)

            let result = try PDFComparisonEngine().compare(leftURL: left, rightURL: right)
            let title = try #require(result.metadataComparison.rows.first { $0.key == "title" })

            #expect(result.pages[0].status == .same)
            #expect(result.hasDifferences)
            #expect(title.status == .different)
            #expect(title.left?.value == .string("Original"))
            #expect(title.right?.value == .string("Revised"))
            #expect(result.metadataComparison.rows.map(\.key) == result.metadataComparison.rows.map(\.key).sorted())
        }
    }

    @Test("Corrupted, non-file, and oversized inputs fail explicitly")
    func invalidAndOversizedInputs() throws {
        try withTemporaryDirectory { directory in
            let valid = directory.appending(path: "valid.pdf")
            let corrupt = directory.appending(path: "corrupt.pdf")
            let validData = makePDF(pages: [FixturePage(text: "Valid")])
            try validData.write(to: valid)
            try Data("not a pdf".utf8).write(to: corrupt)

            #expect(throws: PDFComparisonError.corrupted(side: .left)) {
                try PDFComparisonEngine().compare(leftURL: corrupt, rightURL: valid)
            }
            #expect(throws: PDFComparisonError.notRegularFile(side: .left)) {
                try PDFComparisonEngine().compare(leftURL: directory, rightURL: valid)
            }
            #expect(throws: PDFComparisonError.nonLocalInput(side: .left)) {
                try PDFComparisonEngine().compare(
                    leftURL: URL(string: "https://example.invalid/document.pdf")!,
                    rightURL: valid
                )
            }

            let byteCount = validData.count
            #expect(throws: PDFComparisonError.fileTooLarge(
                side: .left,
                actualByteCount: byteCount,
                limit: byteCount - 1
            )) {
                try PDFComparisonEngine(
                    limits: PDFComparisonLimits(maximumFileByteCount: byteCount - 1)
                ).compare(leftURL: valid, rightURL: valid)
            }
        }
    }

    @Test("Encrypted PDFs are rejected before page extraction")
    func encryptedInput() throws {
        try withTemporaryDirectory { directory in
            let encrypted = directory.appending(path: "encrypted.pdf")
            let valid = directory.appending(path: "valid.pdf")
            try makeEncryptedPDF().write(to: encrypted)
            try makePDF(pages: [FixturePage(text: "Valid")]).write(to: valid)

            #expect(throws: PDFComparisonError.encrypted(side: .left)) {
                try PDFComparisonEngine().compare(leftURL: encrypted, rightURL: valid)
            }
        }
    }

    @Test("Page and extracted-text limits are enforced after parsing")
    func parsingLimits() throws {
        try withTemporaryDirectory { directory in
            let pdf = directory.appending(path: "pages.pdf")
            try makePDF(
                pages: [FixturePage(text: "one"), FixturePage(text: "two")]
            ).write(to: pdf)

            #expect(throws: PDFComparisonError.pageLimitExceeded(
                side: .left,
                actualPageCount: 2,
                limit: 1
            )) {
                try PDFComparisonEngine(
                    limits: PDFComparisonLimits(maximumPageCount: 1)
                ).compare(leftURL: pdf, rightURL: pdf)
            }

            #expect(throws: PDFComparisonError.extractedTextLimitExceeded(side: .left, limit: 2)) {
                try PDFComparisonEngine(
                    limits: PDFComparisonLimits(maximumExtractedTextCharacterCount: 2)
                ).compare(leftURL: pdf, rightURL: pdf)
            }
        }
    }

    @Test("Results and errors are Codable, Sendable, and locator-free")
    func portableModel() throws {
        try withTemporaryDirectory { directory in
            let left = directory.appending(path: "secret-left.pdf")
            let right = directory.appending(path: "secret-right.pdf")
            try makePDF(pages: [FixturePage(text: "Left")]).write(to: left)
            try makePDF(pages: [FixturePage(text: "Right")]).write(to: right)

            let result = try PDFComparisonEngine().compare(leftURL: left, rightURL: right)
            requireSendable(result)
            requireSendable(PDFComparisonError.encrypted(side: .left))

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(result)
            let decoded = try JSONDecoder().decode(PDFComparisonResult.self, from: encoded)
            let json = try #require(String(data: encoded, encoding: .utf8))

            #expect(decoded == result)
            #expect(!json.contains(left.path))
            #expect(!json.contains(right.path))

            let encodedError = try encoder.encode(PDFComparisonError.encrypted(side: .right))
            #expect(
                try JSONDecoder().decode(PDFComparisonError.self, from: encodedError)
                    == .encrypted(side: .right)
            )
        }
    }

    @Test("Selected-page rasterization is deterministic, white RGBA8, and MediaBox aligned")
    func selectedPageRasterization() throws {
        let leftData = makePDF(
            pages: [FixturePage(text: "Left visual ink", width: 200, height: 100)]
        )
        let rightData = makePDF(
            pages: [FixturePage(text: "Right visual ink", width: 100, height: 200)]
        )
        let limits = try PDFVisualComparisonLimits(
            maximumDimension: 100,
            maximumPixelCount: 10_000,
            maximumRasterByteCount: 40_000,
            maximumResultByteCount: 90_000
        )
        let comparator = PDFVisualPageComparator(limits: limits)
        let canvas = try comparator.makeCanvasPlan(
            left: PDFPageDimensions(width: 200, height: 100),
            right: PDFPageDimensions(width: 100, height: 200)
        )
        let rasterizer = PDFVisualPageRasterizer(limits: limits)
        let left = try rasterizer.render(
            documentData: leftData,
            side: .left,
            pageNumber: 1,
            expectedDimensions: PDFPageDimensions(width: 200, height: 100),
            expectedRotationDegrees: 0,
            canvas: canvas
        )
        let leftAgain = try rasterizer.render(
            documentData: leftData,
            side: .left,
            pageNumber: 1,
            expectedDimensions: PDFPageDimensions(width: 200, height: 100),
            expectedRotationDegrees: 0,
            canvas: canvas
        )
        let right = try rasterizer.render(
            documentData: rightData,
            side: .right,
            pageNumber: 1,
            expectedDimensions: PDFPageDimensions(width: 100, height: 200),
            expectedRotationDegrees: 0,
            canvas: canvas
        )

        #expect(canvas.width == 100)
        #expect(canvas.height == 100)
        #expect(left == leftAgain)
        #expect(left.rgba8.count == 40_000)
        #expect(
            stride(from: 3, to: left.rgba8.count, by: 4)
                .allSatisfy { left.rgba8[$0] == 255 }
        )
        #expect(left.rgba8.contains { $0 < 255 })
        #expect(right.rgba8.contains { $0 < 255 })

        let result = try comparator.compare(
            left: left,
            right: right,
            pageNumber: 1,
            canvas: canvas
        )
        #expect(result.hasPixelDifferences)
        #expect(result.comparedPixelCount == 10_000)
    }

    @Test("Rasterizer independently enforces document bytes and immutable page geometry")
    func selectedPageRasterizerValidation() throws {
        let data = makePDF(pages: [FixturePage(text: "Visual", width: 200, height: 100)])
        let canvas = try PDFVisualPageComparator().makeCanvasPlan(
            left: PDFPageDimensions(width: 200, height: 100),
            right: PDFPageDimensions(width: 200, height: 100)
        )
        let byteLimited = try PDFVisualComparisonLimits(maximumDocumentByteCount: data.count - 1)

        #expect(throws: PDFVisualComparisonError.documentByteLimitExceeded(
            actual: data.count,
            limit: data.count - 1
        )) {
            try PDFVisualPageRasterizer(limits: byteLimited).render(
                documentData: data,
                side: .left,
                pageNumber: 1,
                expectedDimensions: PDFPageDimensions(width: 200, height: 100),
                expectedRotationDegrees: 0,
                canvas: canvas
            )
        }
        #expect(throws: PDFVisualComparisonError.invalidPageGeometry(side: .left)) {
            try PDFVisualPageRasterizer().render(
                documentData: data,
                side: .left,
                pageNumber: 1,
                expectedDimensions: PDFPageDimensions(width: 201, height: 100),
                expectedRotationDegrees: 0,
                canvas: canvas
            )
        }
        #expect(throws: PDFVisualComparisonError.invalidPageGeometry(side: .left)) {
            try PDFVisualPageRasterizer().render(
                documentData: data,
                side: .left,
                pageNumber: 1,
                expectedDimensions: PDFPageDimensions(width: 200, height: 100),
                expectedRotationDegrees: 90,
                canvas: canvas
            )
        }
        #expect(throws: PDFVisualComparisonError.pageUnavailable(side: .right, pageNumber: 2)) {
            try PDFVisualPageRasterizer().render(
                documentData: data,
                side: .right,
                pageNumber: 2,
                expectedDimensions: PDFPageDimensions(width: 200, height: 100),
                expectedRotationDegrees: 0,
                canvas: canvas
            )
        }
    }

    @Test("Rasterizer accepts the immutable PDFKit snapshot for a rotated page")
    func rotatedSelectedPageRasterization() throws {
        try withTemporaryDirectory { directory in
            let data = makePDF(
                pages: [FixturePage(text: "Rotated", width: 200, height: 100, rotation: 90)]
            )
            let leftURL = directory.appending(path: "left.pdf")
            let rightURL = directory.appending(path: "right.pdf")
            try data.write(to: leftURL)
            try data.write(to: rightURL)

            let semantic = try PDFComparisonEngine().compare(
                leftURL: leftURL,
                rightURL: rightURL
            )
            let snapshot = try #require(semantic.pages.first?.left)
            let canvas = try PDFVisualPageComparator().makeCanvasPlan(
                left: snapshot.dimensions,
                right: snapshot.dimensions
            )
            let raster = try PDFVisualPageRasterizer().render(
                documentData: data,
                side: .left,
                pageNumber: 1,
                expectedDimensions: snapshot.dimensions,
                expectedRotationDegrees: snapshot.rotationDegrees,
                canvas: canvas
            )

            #expect(snapshot.rotationDegrees == 90)
            #expect(raster.width == canvas.width)
            #expect(raster.height == canvas.height)
            #expect(raster.rgba8.contains { $0 < 255 })
        }
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Riffa-PDF-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func makePDF(
        pages: [FixturePage],
        title: String? = nil,
        author: String? = nil,
        creationDate: String? = nil,
        labelPrefix: String? = nil
    ) -> Data {
        precondition(!pages.isEmpty)

        let fontObject = 3
        let firstPageObject = 4
        let infoObject = firstPageObject + pages.count * 2
        let pageObjectNumbers = pages.indices.map { firstPageObject + $0 * 2 }
        let labelDictionary = labelPrefix.map {
            " /PageLabels << /Nums [0 << /S /D /P (\(escapePDFLiteral($0))) /St 1 >>] >>"
        } ?? ""

        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R\(labelDictionary) >>")
        objects.append(
            "<< /Type /Pages /Kids [\(pageObjectNumbers.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>"
        )
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

        for (index, page) in pages.enumerated() {
            let pageObject = firstPageObject + index * 2
            let contentObject = pageObject + 1
            let mediaBox = "[0 0 \(number(page.width)) \(number(page.height))]"
            objects.append(
                "<< /Type /Page /Parent 2 0 R /MediaBox \(mediaBox) /Rotate \(page.rotation) /Resources << /Font << /F1 \(fontObject) 0 R >> >> /Contents \(contentObject) 0 R >>"
            )
            let stream = contentStream(for: page.text, pageHeight: page.height)
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }

        var infoParts: [String] = []
        if let title { infoParts.append("/Title (\(escapePDFLiteral(title)))") }
        if let author { infoParts.append("/Author (\(escapePDFLiteral(author)))") }
        if let creationDate { infoParts.append("/CreationDate (\(escapePDFLiteral(creationDate)))") }
        objects.append("<< \(infoParts.joined(separator: " ")) >>")

        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }

        let xrefOffset = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n".utf8))
        data.append(Data("0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(
            Data(
                "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info \(infoObject) 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8
            )
        )
        return data
    }

    private func contentStream(for text: String, pageHeight: Double) -> String {
        let lines = text.components(separatedBy: "\n")
        var commands = [
            "BT",
            "/F1 12 Tf",
            "72 \(number(max(72, pageHeight - 72))) Td"
        ]
        for (index, line) in lines.enumerated() {
            if index > 0 {
                commands.append("0 -16 Td")
            }
            commands.append("(\(escapePDFLiteral(line))) Tj")
        }
        commands.append("ET")
        return commands.joined(separator: "\n")
    }

    private func makeEncryptedPDF() -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else {
            preconditionFailure("Could not create a PDF data consumer")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        let options = [
            kCGPDFContextUserPassword as String: "secret",
            kCGPDFContextOwnerPassword as String: "owner",
            kCGPDFContextEncryptionKeyLength as String: 128
        ] as CFDictionary
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            options
        ) else {
            preconditionFailure("Could not create an encrypted PDF context")
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }

    private func escapePDFLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func number(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private struct FixturePage {
    let text: String
    let width: Double
    let height: Double
    let rotation: Int

    init(
        text: String,
        width: Double = 612,
        height: Double = 792,
        rotation: Int = 0
    ) {
        self.text = text
        self.width = width
        self.height = height
        self.rotation = rotation
    }
}
