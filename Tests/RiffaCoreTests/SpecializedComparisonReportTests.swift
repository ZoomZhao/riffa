import Foundation
import Testing
@testable import RiffaCore

@Suite("Specialized comparison reports")
struct SpecializedComparisonReportTests {
    private let generator = SpecializedComparisonReportGenerator()

    @Test("HTML escapes Unicode labels, keys, values, and diagnostics")
    func htmlEscapingAndUnicode() throws {
        let left = [
            MetadataField(
                key: "标题<script>",
                displayName: "标题 & 作者",
                value: .string("你好 <img src=x onerror='bad'>"),
                importance: .important
            )
        ]
        let right = [
            MetadataField(
                key: "标题<script>",
                displayName: "标题 & 作者",
                value: .string("你好 & 再见"),
                importance: .important
            )
        ]
        let result = MetadataComparison().compare(left: left, right: right)
        let html = try generator.generate(
            metadata: result,
            format: .html,
            leftLabel: "左<unsafe>",
            rightLabel: "右's & side"
        )

        #expect(html.contains("你好"))
        #expect(html.contains("标题&lt;script&gt;"))
        #expect(html.contains("&lt;img src=x onerror=&#39;bad&#39;&gt;"))
        #expect(html.contains("左&lt;unsafe&gt;"))
        #expect(html.contains("右&#39;s &amp; side"))
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<img src=x"))
        #expect(!html.contains("https://"))
        #expect(!html.contains("http://"))
    }

    @Test("Every format is deterministic for all specialized result kinds")
    func deterministicOutput() throws {
        let hex = HexComparisonEngine().compare(left: [0, 1, 2], right: [0, 9, 2, 3])
        let image = try imageResult()
        let table = TableComparisonEngine().compare(
            leftText: "id,name\n1,旧值",
            rightText: "id,name\n1,新值"
        )
        let metadata = MetadataComparison().compare(
            left: [MetadataField(key: "标题", displayName: "标题", value: .string("旧"))],
            right: [MetadataField(key: "标题", displayName: "标题", value: .string("新"))]
        )

        for format in ComparisonReportFormat.allCases {
            #expect(
                try generator.generate(hex: hex, format: format)
                    == generator.generate(hex: hex, format: format)
            )
            #expect(
                try generator.generate(image: image, format: format)
                    == generator.generate(image: image, format: format)
            )
            #expect(
                try generator.generate(table: table, format: format)
                    == generator.generate(table: table, format: format)
            )
            #expect(
                try generator.generate(metadata: metadata, format: format)
                    == generator.generate(metadata: metadata, format: format)
            )
        }
    }

    @Test("Empty specialized results render explicit summaries")
    func emptyResults() throws {
        let hex = HexComparisonEngine().compare(left: [], right: [])
        let emptyBuffer = try RGBAPixelBuffer(width: 0, height: 0, bytes: [])
        let image = ImageComparison().compare(emptyBuffer, to: emptyBuffer)
        let table = TableComparisonEngine().compare(leftText: "", rightText: "")
        let metadata = MetadataComparison().compare(left: [], right: [])

        let documents = [
            generator.document(for: hex),
            generator.document(for: image),
            generator.document(for: table),
            generator.document(for: metadata)
        ]

        #expect(documents.allSatisfy { document in document.rows.isEmpty })
        for document in documents {
            let plain = try generator.render(document, as: .plainText)
            let html = try generator.render(document, as: .html)
            #expect(!document.summary.isEmpty)
            #expect(plain.contains("Summary:"))
            #expect(html.contains("No detail rows"))
        }
    }

    @Test("JSON round-trips through the stable public DTO")
    func jsonRoundTrip() throws {
        let documents = [
            generator.document(for: HexComparisonEngine().compare(left: [1], right: [2])),
            generator.document(for: try imageResult()),
            generator.document(
                for: TableComparisonEngine().compare(leftText: "a\n旧", rightText: "a\n新")
            ),
            generator.document(
                for: MetadataComparison().compare(
                    left: [MetadataField(key: "名", displayName: "名称", value: .string("左"))],
                    right: [MetadataField(key: "名", displayName: "名称", value: .string("右"))]
                )
            )
        ]

        for document in documents {
            let json = try generator.render(document, as: .json)
            let decoded = try JSONDecoder().decode(
                SpecializedComparisonReportDocument.self,
                from: Data(json.utf8)
            )
            #expect(decoded == document)
        }
    }

    @Test("Image masks and raw metadata Data never enter reports")
    func privacyAndMaskSummary() throws {
        let image = try imageResult(width: 64, height: 64)
        let imageJSON = try generator.generate(image: image, format: .json)
        let secret = Data("SECRET_RAW_BYTES_DO_NOT_REPORT".utf8)
        let summary = MetadataDataSummary(data: secret)
        let metadata = MetadataComparison().compare(
            left: [MetadataField(key: "blob", displayName: "Blob", value: .data(summary))],
            right: []
        )
        let metadataJSON = try generator.generate(metadata: metadata, format: .json)

        #expect(!imageJSON.contains("values"))
        #expect(!imageJSON.contains(Array(repeating: "255", count: 20).joined(separator: ",")))
        #expect(imageJSON.utf8.count < 8_000)
        #expect(imageJSON.contains("mask.sampleCount"))
        #expect(!metadataJSON.contains("SECRET_RAW_BYTES_DO_NOT_REPORT"))
        #expect(metadataJSON.contains(summary.sha256))
        #expect(!metadataJSON.contains("providerID"))
        #expect(!metadataJSON.contains("locator"))
    }

    @Test("Strict Sendable DTOs cross a task boundary")
    func sendableDTO() async {
        let document = generator.document(
            for: HexComparisonEngine().compare(left: [1], right: [2])
        )
        let copied = await Task.detached { @Sendable in document }.value
        #expect(copied == document)
    }

    @Test("Local metadata reports omit paths, raw xattrs, and raw ACL principals")
    func localMetadataFormatsAndPrivacy() throws {
        let secret = Data("DO_NOT_EXPORT_THIS_XATTR_VALUE".utf8)
        let aclSecret = Data("DO_NOT_EXPORT_THIS_ACL_PRINCIPAL".utf8)
        let left = LocalMetadataSnapshot(
            itemName: "左<文件>",
            itemType: .regularFile,
            byteCount: 12,
            modificationTime: LocalMetadataTimestamp(
                secondsSince1970: 1_700_000_000,
                nanoseconds: 123
            ),
            posixPermissions: 0o640,
            ownerID: 501,
            groupID: 20,
            symbolicLinkDestination: nil,
            extendedAttributes: [
                LocalMetadataExtendedAttribute(
                    name: "dev.riffa.private",
                    valueSummary: MetadataDataSummary(data: secret)
                )
            ],
            accessControlList: LocalMetadataAccessControlList(
                entryCount: 1,
                valueSummary: MetadataDataSummary(data: aclSecret)
            )
        )
        let right = LocalMetadataSnapshot(
            itemName: "右&文件",
            itemType: .regularFile,
            byteCount: 18,
            modificationTime: LocalMetadataTimestamp(
                secondsSince1970: 1_700_000_001,
                nanoseconds: 456
            ),
            posixPermissions: 0o644,
            ownerID: 502,
            groupID: 20,
            symbolicLinkDestination: nil,
            extendedAttributes: []
        )
        let result = LocalMetadataComparisonResult(
            left: left,
            right: right,
            comparison: MetadataComparison().compare(left: left.fields, right: right.fields)
        )

        for format in ComparisonReportFormat.allCases {
            let first = try generator.generate(
                metadata: result,
                format: format,
                leftLabel: left.itemName,
                rightLabel: right.itemName
            )
            let second = try generator.generate(
                metadata: result,
                format: format,
                leftLabel: left.itemName,
                rightLabel: right.itemName
            )
            #expect(first == second)
            #expect(first.contains("metadata"))
            #expect(!first.contains("/Users/example/private"))
            #expect(!first.contains("DO_NOT_EXPORT_THIS_XATTR_VALUE"))
            #expect(!first.contains("DO_NOT_EXPORT_THIS_ACL_PRINCIPAL"))
            #expect(first.contains(MetadataDataSummary(data: secret).sha256))
            #expect(first.contains(MetadataDataSummary(data: aclSecret).sha256))
        }

        let document = generator.document(
            for: result,
            leftLabel: left.itemName,
            rightLabel: right.itemName
        )
        #expect(document.kind == .metadata)
        #expect(document.rows.contains { $0.key == "file.byteCount#0" })

        let html = try generator.generate(
            metadata: result,
            format: .html,
            leftLabel: left.itemName,
            rightLabel: right.itemName
        )
        #expect(html.contains("左&lt;文件&gt;"))
        #expect(html.contains("右&amp;文件"))
    }

    private func imageResult(width: Int = 2, height: Int = 2) throws -> ImageComparisonResult {
        let pixelCount = width * height
        let left = try RGBAPixelBuffer(
            width: width,
            height: height,
            bytes: Array(repeating: UInt8(0), count: pixelCount * 4)
        )
        var rightBytes = Array(repeating: UInt8(0), count: pixelCount * 4)
        if !rightBytes.isEmpty {
            for pixel in 0..<pixelCount {
                rightBytes[pixel * 4] = 255
            }
        }
        let right = try RGBAPixelBuffer(width: width, height: height, bytes: rightBytes)
        return ImageComparison().compare(left, to: right)
    }
}
