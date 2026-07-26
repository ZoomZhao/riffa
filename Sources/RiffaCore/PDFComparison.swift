import CryptoKit
import Foundation
import PDFKit

public enum PDFComparisonSide: String, Codable, Sendable {
    case left
    case right
}

/// Resource limits applied before PDFKit is allowed to parse a document.
///
/// The file limit is enforced through one descriptor-backed bounded read, so
/// PDFKit parses the exact byte sequence whose identity and version were
/// checked before and after the read.
public struct PDFComparisonLimits: Equatable, Codable, Sendable {
    public static let defaultMaximumFileByteCount = 256 * 1_024 * 1_024

    public var maximumFileByteCount: Int
    public var maximumPageCount: Int
    public var maximumExtractedTextCharacterCount: Int

    public init(
        maximumFileByteCount: Int = Self.defaultMaximumFileByteCount,
        maximumPageCount: Int = 10_000,
        maximumExtractedTextCharacterCount: Int = 64 * 1_024 * 1_024
    ) {
        self.maximumFileByteCount = min(max(1, maximumFileByteCount), Int.max - 1)
        self.maximumPageCount = max(1, maximumPageCount)
        self.maximumExtractedTextCharacterCount = max(1, maximumExtractedTextCharacterCount)
    }
}

/// Failures are side-aware without retaining or disclosing an input locator.
public enum PDFComparisonError: Error, Equatable, Codable, Sendable {
    case nonLocalInput(side: PDFComparisonSide)
    case notRegularFile(side: PDFComparisonSide)
    case permissionDenied(side: PDFComparisonSide)
    case readFailed(side: PDFComparisonSide, code: Int)
    case fileTooLarge(side: PDFComparisonSide, actualByteCount: Int, limit: Int)
    case inputChanged(side: PDFComparisonSide)
    case corrupted(side: PDFComparisonSide)
    case encrypted(side: PDFComparisonSide)
    case pageLimitExceeded(side: PDFComparisonSide, actualPageCount: Int, limit: Int)
    case extractedTextLimitExceeded(side: PDFComparisonSide, limit: Int)
}

extension PDFComparisonError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .nonLocalInput(side):
            "The \(side.rawValue) input is not a local file."
        case let .notRegularFile(side):
            "The \(side.rawValue) input is not a regular PDF file."
        case let .permissionDenied(side):
            "The \(side.rawValue) PDF does not permit reading or text extraction."
        case let .readFailed(side, code):
            "The \(side.rawValue) PDF could not be read (error \(code))."
        case let .fileTooLarge(side, actualByteCount, limit):
            "The \(side.rawValue) PDF is \(actualByteCount) bytes, exceeding the \(limit)-byte limit."
        case let .inputChanged(side):
            "The \(side.rawValue) PDF changed after it was compared. Compare the files again before previewing."
        case let .corrupted(side):
            "The \(side.rawValue) input is not a valid PDF document."
        case let .encrypted(side):
            "The \(side.rawValue) PDF is encrypted and cannot be compared without credentials."
        case let .pageLimitExceeded(side, actualPageCount, limit):
            "The \(side.rawValue) PDF has \(actualPageCount) pages, exceeding the \(limit)-page limit."
        case let .extractedTextLimitExceeded(side, limit):
            "Extracted text from the \(side.rawValue) PDF exceeds the \(limit)-character limit."
        }
    }
}

public struct PDFPageDimensions: Equatable, Codable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// A portable page snapshot. It intentionally contains no `PDFPage`, PDF
/// bytes, or source locator so the comparison can cross actor/process bounds.
public struct PDFPageSnapshot: Equatable, Codable, Sendable {
    public let pageNumber: Int
    public let label: String?
    public let dimensions: PDFPageDimensions
    public let rotationDegrees: Int
    public let extractedText: String

    public init(
        pageNumber: Int,
        label: String?,
        dimensions: PDFPageDimensions,
        rotationDegrees: Int,
        extractedText: String
    ) {
        self.pageNumber = pageNumber
        self.label = label
        self.dimensions = dimensions
        self.rotationDegrees = rotationDegrees
        self.extractedText = extractedText
    }
}

public struct PDFDocumentSnapshot: Equatable, Codable, Sendable {
    public let fileByteCount: Int
    public let pageCount: Int
    public let metadata: [MetadataField]
    /// Lowercase SHA-256 of the exact bounded byte sequence parsed by PDFKit.
    /// This is intentionally content-only: no locator or source bytes are kept.
    public let contentSHA256: String

    public init(
        fileByteCount: Int,
        pageCount: Int,
        metadata: [MetadataField],
        contentSHA256: String = ""
    ) {
        self.fileByteCount = fileByteCount
        self.pageCount = pageCount
        self.metadata = metadata
        self.contentSHA256 = contentSHA256
    }
}

public enum PDFTextLineEnding: String, Codable, Sendable {
    case none
    case lf
    case crlf
    case cr
}

public struct PDFTextLineValue: Equatable, Codable, Sendable {
    public let lineNumber: Int
    public let content: String
    public let ending: PDFTextLineEnding

    public init(lineNumber: Int, content: String, ending: PDFTextLineEnding) {
        self.lineNumber = lineNumber
        self.content = content
        self.ending = ending
    }
}

public enum PDFTextDifferenceStatus: String, Codable, Sendable {
    case same
    case inserted
    case deleted
    case modified
}

public enum PDFInlineDifferenceStatus: String, Codable, Sendable {
    case inserted
    case deleted
    case modified
}

public struct PDFTextRange: Equatable, Codable, Sendable {
    public let offset: Int
    public let length: Int

    public init(offset: Int, length: Int) {
        self.offset = offset
        self.length = length
    }
}

public struct PDFInlineDifference: Equatable, Codable, Sendable {
    public let status: PDFInlineDifferenceStatus
    public let leftRange: PDFTextRange?
    public let rightRange: PDFTextRange?

    public init(
        status: PDFInlineDifferenceStatus,
        leftRange: PDFTextRange?,
        rightRange: PDFTextRange?
    ) {
        self.status = status
        self.leftRange = leftRange
        self.rightRange = rightRange
    }
}

public struct PDFTextLineComparison: Equatable, Codable, Sendable {
    public let offset: Int
    public let status: PDFTextDifferenceStatus
    public let left: PDFTextLineValue?
    public let right: PDFTextLineValue?
    public let inlineDifferences: [PDFInlineDifference]
    public let hasLineEndingDifference: Bool

    public init(
        offset: Int,
        status: PDFTextDifferenceStatus,
        left: PDFTextLineValue?,
        right: PDFTextLineValue?,
        inlineDifferences: [PDFInlineDifference],
        hasLineEndingDifference: Bool
    ) {
        self.offset = offset
        self.status = status
        self.left = left
        self.right = right
        self.inlineDifferences = inlineDifferences
        self.hasLineEndingDifference = hasLineEndingDifference
    }
}

public struct PDFTextComparisonStatistics: Equatable, Codable, Sendable {
    public let sameLineCount: Int
    public let insertedLineCount: Int
    public let deletedLineCount: Int
    public let modifiedLineCount: Int

    public init(
        sameLineCount: Int,
        insertedLineCount: Int,
        deletedLineCount: Int,
        modifiedLineCount: Int
    ) {
        self.sameLineCount = sameLineCount
        self.insertedLineCount = insertedLineCount
        self.deletedLineCount = deletedLineCount
        self.modifiedLineCount = modifiedLineCount
    }

    public var changedLineCount: Int {
        insertedLineCount + deletedLineCount + modifiedLineCount
    }
}

public struct PDFTextComparisonResult: Equatable, Codable, Sendable {
    public let lines: [PDFTextLineComparison]
    public let statistics: PDFTextComparisonStatistics

    public init(lines: [PDFTextLineComparison], statistics: PDFTextComparisonStatistics) {
        self.lines = lines
        self.statistics = statistics
    }

    public var hasDifferences: Bool {
        statistics.changedLineCount > 0
    }
}

public enum PDFPageDifferenceKind: String, CaseIterable, Codable, Sendable {
    case dimensions
    case rotation
    case label
    case text
}

public enum PDFPageComparisonStatus: String, Codable, Sendable {
    case same
    case changed
    case leftOnly
    case rightOnly
}

public struct PDFPageComparison: Equatable, Codable, Sendable {
    public let pageNumber: Int
    public let status: PDFPageComparisonStatus
    public let differences: [PDFPageDifferenceKind]
    public let left: PDFPageSnapshot?
    public let right: PDFPageSnapshot?
    public let textComparison: PDFTextComparisonResult?

    public init(
        pageNumber: Int,
        status: PDFPageComparisonStatus,
        differences: [PDFPageDifferenceKind],
        left: PDFPageSnapshot?,
        right: PDFPageSnapshot?,
        textComparison: PDFTextComparisonResult?
    ) {
        self.pageNumber = pageNumber
        self.status = status
        self.differences = differences
        self.left = left
        self.right = right
        self.textComparison = textComparison
    }
}

public struct PDFComparisonStatistics: Equatable, Codable, Sendable {
    public let samePageCount: Int
    public let changedPageCount: Int
    public let leftOnlyPageCount: Int
    public let rightOnlyPageCount: Int

    public init(
        samePageCount: Int,
        changedPageCount: Int,
        leftOnlyPageCount: Int,
        rightOnlyPageCount: Int
    ) {
        self.samePageCount = samePageCount
        self.changedPageCount = changedPageCount
        self.leftOnlyPageCount = leftOnlyPageCount
        self.rightOnlyPageCount = rightOnlyPageCount
    }

    public var differentPageCount: Int {
        changedPageCount + leftOnlyPageCount + rightOnlyPageCount
    }
}

public struct PDFComparisonResult: Equatable, Codable, Sendable {
    public let leftDocument: PDFDocumentSnapshot
    public let rightDocument: PDFDocumentSnapshot
    public let metadataComparison: MetadataComparisonResult
    public let pages: [PDFPageComparison]
    public let statistics: PDFComparisonStatistics

    public init(
        leftDocument: PDFDocumentSnapshot,
        rightDocument: PDFDocumentSnapshot,
        metadataComparison: MetadataComparisonResult,
        pages: [PDFPageComparison],
        statistics: PDFComparisonStatistics
    ) {
        self.leftDocument = leftDocument
        self.rightDocument = rightDocument
        self.metadataComparison = metadataComparison
        self.pages = pages
        self.statistics = statistics
    }

    public var hasDifferences: Bool {
        metadataComparison.hasDifferences || statistics.differentPageCount > 0
    }
}

/// Native macOS PDF comparison backed by PDFKit and the shared Riffa text
/// engine. Pages are aligned strictly by their one-based page number.
public struct PDFComparisonEngine: Sendable {
    public var limits: PDFComparisonLimits
    public var textOptions: TextDiffOptions

    public init(
        limits: PDFComparisonLimits = PDFComparisonLimits(),
        textOptions: TextDiffOptions = TextDiffOptions()
    ) {
        self.limits = limits
        self.textOptions = textOptions
    }

    public func compare(leftURL: URL, rightURL: URL) throws -> PDFComparisonResult {
        let left = try load(url: leftURL, side: .left)
        let right = try load(url: rightURL, side: .right)
        let metadataComparison = MetadataComparison().compare(
            left: left.document.metadata,
            right: right.document.metadata
        )
        let pages = comparePages(left.pages, right.pages)

        return PDFComparisonResult(
            leftDocument: left.document,
            rightDocument: right.document,
            metadataComparison: metadataComparison,
            pages: pages,
            statistics: PDFComparisonStatistics(
                samePageCount: pages.count { $0.status == .same },
                changedPageCount: pages.count { $0.status == .changed },
                leftOnlyPageCount: pages.count { $0.status == .leftOnly },
                rightOnlyPageCount: pages.count { $0.status == .rightOnly }
            )
        )
    }

    /// Re-reads a comparison input with the same strict byte limit and only
    /// returns the bounded bytes when both their size and SHA-256 still match
    /// the immutable comparison snapshot. Callers must construct any preview
    /// `PDFDocument` from this returned `Data`, never from the source URL.
    public func verifiedPreviewData(
        url: URL,
        side: PDFComparisonSide,
        matching snapshot: PDFDocumentSnapshot
    ) throws -> Data {
        let input = try boundedRead(url: url, side: side)
        guard input.data.count == snapshot.fileByteCount,
              input.contentSHA256 == snapshot.contentSHA256 else {
            throw PDFComparisonError.inputChanged(side: side)
        }
        return input.data
    }

    private func load(url: URL, side: PDFComparisonSide) throws -> LoadedPDF {
        let input = try boundedRead(url: url, side: side)
        guard let pdf = PDFDocument(data: input.data) else {
            throw PDFComparisonError.corrupted(side: side)
        }
        guard !pdf.isEncrypted else {
            throw PDFComparisonError.encrypted(side: side)
        }
        guard !pdf.isLocked else {
            throw PDFComparisonError.encrypted(side: side)
        }
        guard pdf.allowsCopying else {
            throw PDFComparisonError.permissionDenied(side: side)
        }
        guard pdf.pageCount > 0 else {
            throw PDFComparisonError.corrupted(side: side)
        }
        guard pdf.pageCount <= limits.maximumPageCount else {
            throw PDFComparisonError.pageLimitExceeded(
                side: side,
                actualPageCount: pdf.pageCount,
                limit: limits.maximumPageCount
            )
        }

        var pages: [PDFPageSnapshot] = []
        pages.reserveCapacity(pdf.pageCount)
        var extractedCharacterCount = 0

        for pageIndex in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIndex) else {
                throw PDFComparisonError.corrupted(side: side)
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width.isFinite,
                  bounds.height.isFinite,
                  bounds.width >= 0,
                  bounds.height >= 0 else {
                throw PDFComparisonError.corrupted(side: side)
            }

            let text = page.string ?? ""
            let (nextCount, overflow) = extractedCharacterCount.addingReportingOverflow(text.count)
            guard !overflow, nextCount <= limits.maximumExtractedTextCharacterCount else {
                throw PDFComparisonError.extractedTextLimitExceeded(
                    side: side,
                    limit: limits.maximumExtractedTextCharacterCount
                )
            }
            extractedCharacterCount = nextCount

            pages.append(
                PDFPageSnapshot(
                    pageNumber: pageIndex + 1,
                    label: page.label,
                    dimensions: PDFPageDimensions(
                        width: bounds.width,
                        height: bounds.height
                    ),
                    rotationDegrees: normalizedRotation(page.rotation),
                    extractedText: text
                )
            )
        }

        let metadata = publicMetadata(from: pdf)
        return LoadedPDF(
            document: PDFDocumentSnapshot(
                fileByteCount: input.data.count,
                pageCount: pages.count,
                metadata: metadata,
                contentSHA256: input.contentSHA256
            ),
            pages: pages
        )
    }

    private func boundedRead(url: URL, side: PDFComparisonSide) throws -> BoundedPDFInput {
        guard url.isFileURL else {
            throw PDFComparisonError.nonLocalInput(side: side)
        }

        do {
            let data = try BoundedLocalFileReader(
                limits: BoundedLocalFileReadLimits(
                    maximumByteCount: limits.maximumFileByteCount
                )
            ).read(url: url)
            return BoundedPDFInput(
                data: data,
                contentSHA256: Self.hexDigest(SHA256.hash(data: data))
            )
        } catch let error as BoundedLocalFileReadError {
            throw classifiedBoundedReadError(error, side: side)
        } catch {
            throw classifiedReadError(error, side: side)
        }
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func classifiedBoundedReadError(
        _ error: BoundedLocalFileReadError,
        side: PDFComparisonSide
    ) -> PDFComparisonError {
        switch error {
        case .nonFileURL:
            return .nonLocalInput(side: side)
        case .notRegularFile:
            return .notRegularFile(side: side)
        case let .fileTooLarge(actualByteCount, limit):
            return .fileTooLarge(
                side: side,
                actualByteCount: Int(clamping: actualByteCount),
                limit: limit
            )
        case .fileChangedDuringRead:
            return .inputChanged(side: side)
        case let .operationFailed(_, code) where code == EACCES || code == EPERM:
            return .permissionDenied(side: side)
        case let .operationFailed(_, code):
            return .readFailed(side: side, code: Int(code))
        case .invalidLimits, .relativePath:
            return .readFailed(side: side, code: Int(EINVAL))
        }
    }

    private func classifiedReadError(_ error: any Error, side: PDFComparisonSide) -> PDFComparisonError {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain,
           cocoa.code == CocoaError.fileReadNoPermission.rawValue {
            return .permissionDenied(side: side)
        }
        if cocoa.domain == NSPOSIXErrorDomain,
           cocoa.code == Int(EACCES) || cocoa.code == Int(EPERM) {
            return .permissionDenied(side: side)
        }
        return .readFailed(side: side, code: cocoa.code)
    }

    private func publicMetadata(from document: PDFDocument) -> [MetadataField] {
        let attributes = document.documentAttributes ?? [:]
        let specifications: [MetadataSpecification] = [
            .init(.titleAttribute, key: "title", displayName: "Title", importance: .important),
            .init(.authorAttribute, key: "author", displayName: "Author", importance: .important),
            .init(.subjectAttribute, key: "subject", displayName: "Subject"),
            .init(.keywordsAttribute, key: "keywords", displayName: "Keywords"),
            .init(.creatorAttribute, key: "creator", displayName: "Creator", importance: .informational),
            .init(.producerAttribute, key: "producer", displayName: "Producer", importance: .informational),
            .init(.creationDateAttribute, key: "creationDate", displayName: "Creation Date", importance: .informational),
            .init(.modificationDateAttribute, key: "modificationDate", displayName: "Modification Date", importance: .informational)
        ]

        return specifications.compactMap { specification in
            guard let rawValue = attributes[specification.attribute],
                  let value = metadataValue(from: rawValue) else {
                return nil
            }
            return MetadataField(
                key: specification.key,
                displayName: specification.displayName,
                value: value,
                importance: specification.importance
            )
        }
    }

    private func metadataValue(from value: Any) -> MetadataValue? {
        if let string = value as? String {
            return .string(string)
        }
        if let date = value as? Date {
            return .date(date)
        }
        if let strings = value as? [String] {
            return .string(strings.joined(separator: ", "))
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            return .decimal(number.decimalValue)
        }
        return nil
    }

    private func comparePages(
        _ leftPages: [PDFPageSnapshot],
        _ rightPages: [PDFPageSnapshot]
    ) -> [PDFPageComparison] {
        let count = max(leftPages.count, rightPages.count)
        var comparisons: [PDFPageComparison] = []
        comparisons.reserveCapacity(count)

        for offset in 0..<count {
            let left = leftPages.indices.contains(offset) ? leftPages[offset] : nil
            let right = rightPages.indices.contains(offset) ? rightPages[offset] : nil

            switch (left, right) {
            case let (left?, right?):
                let textComparison = compareText(left.extractedText, right.extractedText)
                var differences: [PDFPageDifferenceKind] = []
                if !dimensionsAreEqual(left.dimensions, right.dimensions) {
                    differences.append(.dimensions)
                }
                if left.rotationDegrees != right.rotationDegrees {
                    differences.append(.rotation)
                }
                if left.label != right.label {
                    differences.append(.label)
                }
                if textComparison.hasDifferences {
                    differences.append(.text)
                }
                comparisons.append(
                    PDFPageComparison(
                        pageNumber: offset + 1,
                        status: differences.isEmpty ? .same : .changed,
                        differences: differences,
                        left: left,
                        right: right,
                        textComparison: textComparison
                    )
                )

            case let (left?, nil):
                comparisons.append(
                    PDFPageComparison(
                        pageNumber: offset + 1,
                        status: .leftOnly,
                        differences: [],
                        left: left,
                        right: nil,
                        textComparison: nil
                    )
                )

            case let (nil, right?):
                comparisons.append(
                    PDFPageComparison(
                        pageNumber: offset + 1,
                        status: .rightOnly,
                        differences: [],
                        left: nil,
                        right: right,
                        textComparison: nil
                    )
                )

            case (nil, nil):
                break
            }
        }

        return comparisons
    }

    private func compareText(_ left: String, _ right: String) -> PDFTextComparisonResult {
        let result = TextDiffEngine(options: textOptions).compare(
            TextDocument(text: left),
            to: TextDocument(text: right)
        )
        return PDFTextComparisonResult(
            lines: result.alignedLines.map(convertTextLine),
            statistics: PDFTextComparisonStatistics(
                sameLineCount: result.statistics.unchangedLineCount,
                insertedLineCount: result.statistics.insertedLineCount,
                deletedLineCount: result.statistics.deletedLineCount,
                modifiedLineCount: result.statistics.modifiedLineCount
            )
        )
    }

    private func convertTextLine(_ line: AlignedDiffLine) -> PDFTextLineComparison {
        let status: PDFTextDifferenceStatus = switch line.kind {
        case .unchanged: .same
        case .inserted: .inserted
        case .deleted: .deleted
        case .modified: .modified
        }
        return PDFTextLineComparison(
            offset: line.offset,
            status: status,
            left: line.left.map(convertTextValue),
            right: line.right.map(convertTextValue),
            inlineDifferences: line.inlineDifferences.map { difference in
                let inlineStatus: PDFInlineDifferenceStatus = switch difference.kind {
                case .inserted: .inserted
                case .deleted: .deleted
                case .modified: .modified
                }
                return PDFInlineDifference(
                    status: inlineStatus,
                    leftRange: difference.leftRange.map {
                        PDFTextRange(offset: $0.offset, length: $0.length)
                    },
                    rightRange: difference.rightRange.map {
                        PDFTextRange(offset: $0.offset, length: $0.length)
                    }
                )
            },
            hasLineEndingDifference: line.hasLineEndingDifference
        )
    }

    private func convertTextValue(_ value: DiffLineValue) -> PDFTextLineValue {
        let ending: PDFTextLineEnding = switch value.line.ending {
        case .none: .none
        case .lf: .lf
        case .crlf: .crlf
        case .cr: .cr
        }
        return PDFTextLineValue(
            lineNumber: value.lineNumber,
            content: value.line.content,
            ending: ending
        )
    }

    private func dimensionsAreEqual(
        _ left: PDFPageDimensions,
        _ right: PDFPageDimensions
    ) -> Bool {
        abs(left.width - right.width) <= 0.001
            && abs(left.height - right.height) <= 0.001
    }

    private func normalizedRotation(_ rotation: Int) -> Int {
        let remainder = rotation % 360
        return remainder >= 0 ? remainder : remainder + 360
    }
}

private struct LoadedPDF {
    let document: PDFDocumentSnapshot
    let pages: [PDFPageSnapshot]
}

private struct BoundedPDFInput {
    let data: Data
    let contentSHA256: String
}

private struct MetadataSpecification {
    let attribute: PDFDocumentAttribute
    let key: String
    let displayName: String
    let importance: MetadataImportance

    init(
        _ attribute: PDFDocumentAttribute,
        key: String,
        displayName: String,
        importance: MetadataImportance = .normal
    ) {
        self.attribute = attribute
        self.key = key
        self.displayName = displayName
        self.importance = importance
    }
}
