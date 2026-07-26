import Darwin
import Foundation

/// Resource ceilings for descriptor-backed local binary comparison.
///
/// The public initializer rejects zero, negative, and operationally unsafe
/// values instead of silently normalizing them. `maximumComparisonChunkCount`
/// bounds CPU/I/O work even when a caller selects a very small chunk size.
public struct LocalHexComparisonLimits: Hashable, Sendable {
    /// 128 GiB, exactly matching the default 131,072 × 1 MiB work budget.
    public static let standard = LocalHexComparisonLimits(
        validatedMaximumComparableByteCount: 128 * 1_024 * 1_024 * 1_024,
        comparisonChunkByteCount: 1 * 1_024 * 1_024,
        maximumComparisonChunkCount: 131_072,
        maximumPublishedDifferenceRangeCount: 4_096,
        pageByteCount: 8 * 1_024,
        bytesPerRow: 16
    )

    public let maximumComparableByteCount: UInt64
    public let comparisonChunkByteCount: Int
    public let maximumComparisonChunkCount: Int
    public let maximumPublishedDifferenceRangeCount: Int
    public let pageByteCount: Int
    public let bytesPerRow: Int

    public init(
        /// 128 GiB, before the independent chunk-work ceiling is applied.
        maximumComparableByteCount: UInt64 = 128 * 1_024 * 1_024 * 1_024,
        comparisonChunkByteCount: Int = 1 * 1_024 * 1_024,
        maximumComparisonChunkCount: Int = 131_072,
        maximumPublishedDifferenceRangeCount: Int = 4_096,
        pageByteCount: Int = 8 * 1_024,
        bytesPerRow: Int = 16
    ) throws {
        guard maximumComparableByteCount > 0,
              maximumComparableByteCount <= UInt64(Int64.max),
              (1...Self.maximumChunkByteCount).contains(comparisonChunkByteCount),
              (1...Self.maximumChunkCount).contains(maximumComparisonChunkCount),
              (1...Self.maximumPublishedRangeCount).contains(maximumPublishedDifferenceRangeCount),
              (1...Self.maximumPageByteCount).contains(pageByteCount),
              (1...Self.maximumBytesPerRow).contains(bytesPerRow) else {
            throw LocalHexComparisonError.invalidLimits
        }

        self.init(
            validatedMaximumComparableByteCount: maximumComparableByteCount,
            comparisonChunkByteCount: comparisonChunkByteCount,
            maximumComparisonChunkCount: maximumComparisonChunkCount,
            maximumPublishedDifferenceRangeCount: maximumPublishedDifferenceRangeCount,
            pageByteCount: pageByteCount,
            bytesPerRow: bytesPerRow
        )
    }

    private init(
        validatedMaximumComparableByteCount: UInt64,
        comparisonChunkByteCount: Int,
        maximumComparisonChunkCount: Int,
        maximumPublishedDifferenceRangeCount: Int,
        pageByteCount: Int,
        bytesPerRow: Int
    ) {
        maximumComparableByteCount = validatedMaximumComparableByteCount
        self.comparisonChunkByteCount = comparisonChunkByteCount
        self.maximumComparisonChunkCount = maximumComparisonChunkCount
        self.maximumPublishedDifferenceRangeCount = maximumPublishedDifferenceRangeCount
        self.pageByteCount = pageByteCount
        self.bytesPerRow = bytesPerRow
    }

    private static let maximumChunkByteCount = 16 * 1_024 * 1_024
    private static let maximumChunkCount = 16_777_216
    private static let maximumPublishedRangeCount = 1_000_000
    private static let maximumPageByteCount = 4 * 1_024 * 1_024
    private static let maximumBytesPerRow = 256
}

/// A published contiguous differing range from a streamed comparison.
public struct LocalBinaryDifferenceRange: Identifiable, Hashable, Sendable {
    public let startOffset: UInt64
    public let leftCount: UInt64
    public let rightCount: UInt64

    public init(startOffset: UInt64, leftCount: UInt64, rightCount: UInt64) {
        self.startOffset = startOffset
        self.leftCount = leftCount
        self.rightCount = rightCount
    }

    public var id: UInt64 { startOffset }
    public var comparedCount: UInt64 { max(leftCount, rightCount) }
}

private struct LocalHexFileVersion: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: UInt64
    let mode: UInt16
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64
}

/// Exact aggregate statistics plus a bounded prefix of differing ranges.
/// File identity tokens are private and exist only to keep later page reads
/// coherent with this summary; portable reports never expose them.
public struct LocalHexComparisonSummary: Hashable, Sendable {
    public let leftByteCount: UInt64
    public let rightByteCount: UInt64
    public let differingBytePositionCount: UInt64
    public let differenceRangeCount: UInt64
    public let publishedDifferenceRanges: [LocalBinaryDifferenceRange]
    public let differenceRangesTruncated: Bool

    fileprivate let leftVersion: LocalHexFileVersion
    fileprivate let rightVersion: LocalHexFileVersion

    fileprivate init(
        leftByteCount: UInt64,
        rightByteCount: UInt64,
        differingBytePositionCount: UInt64,
        differenceRangeCount: UInt64,
        publishedDifferenceRanges: [LocalBinaryDifferenceRange],
        leftVersion: LocalHexFileVersion,
        rightVersion: LocalHexFileVersion
    ) {
        self.leftByteCount = leftByteCount
        self.rightByteCount = rightByteCount
        self.differingBytePositionCount = differingBytePositionCount
        self.differenceRangeCount = differenceRangeCount
        self.publishedDifferenceRanges = publishedDifferenceRanges
        differenceRangesTruncated = UInt64(publishedDifferenceRanges.count) < differenceRangeCount
        self.leftVersion = leftVersion
        self.rightVersion = rightVersion
    }

    public var hasDifferences: Bool { differingBytePositionCount > 0 }
    public var maximumByteCount: UInt64 { max(leftByteCount, rightByteCount) }
}

/// One bounded page row. Unlike the in-memory row, its offset remains valid
/// for local files larger than `Int.max` on other supported POSIX targets.
public struct LocalHexComparisonRow: Identifiable, Hashable, Sendable {
    public let offset: UInt64
    public let leftBytes: [UInt8]
    public let rightBytes: [UInt8]
    public let differingColumns: [Int]

    public init(
        offset: UInt64,
        leftBytes: [UInt8],
        rightBytes: [UInt8],
        differingColumns: [Int]
    ) {
        self.offset = offset
        self.leftBytes = leftBytes
        self.rightBytes = rightBytes
        self.differingColumns = differingColumns
    }

    public var id: UInt64 { offset }
}

public struct LocalHexComparisonPage: Hashable, Sendable {
    public let offset: UInt64
    public let endOffset: UInt64
    public let maximumByteCount: UInt64
    public let rows: [LocalHexComparisonRow]

    public init(
        offset: UInt64,
        endOffset: UInt64,
        maximumByteCount: UInt64,
        rows: [LocalHexComparisonRow]
    ) {
        self.offset = offset
        self.endOffset = endOffset
        self.maximumByteCount = maximumByteCount
        self.rows = rows
    }

    public var displayedByteCount: UInt64 { endOffset - offset }
    public var hasPreviousPage: Bool { offset > 0 }
    public var hasNextPage: Bool { endOffset < maximumByteCount }
}

/// Path-free failures from local hexadecimal comparison.
public enum LocalHexComparisonError: Error, Equatable, Sendable {
    public enum Side: String, Equatable, Sendable { case left, right }
    public enum Operation: String, Equatable, Sendable { case open, inspect, read }

    case invalidLimits
    case nonFileURL(side: Side)
    case relativePath(side: Side)
    case operationFailed(side: Side, operation: Operation, code: Int32)
    case notRegularFile(side: Side)
    case fileTooLarge(side: Side, actualByteCount: UInt64, limit: UInt64)
    case comparisonChunkLimitExceeded(requiredChunkCount: UInt64, limit: Int)
    case pageLengthOutOfBounds(requested: Int, limit: Int)
    case pageOffsetOutOfBounds(offset: UInt64, maximum: UInt64)
    case offsetOverflow
    case fileChangedDuringOperation(side: Side)
}

extension LocalHexComparisonError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidLimits:
            "The local hexadecimal comparison limits are invalid."
        case let .nonFileURL(side):
            "The \(side.rawValue) input is not a local file URL."
        case let .relativePath(side):
            "The \(side.rawValue) local file path is not absolute."
        case let .operationFailed(side, operation, code):
            "The \(side.rawValue) file \(operation.rawValue) operation failed (errno \(code): \(Self.posixMessage(code)))."
        case let .notRegularFile(side):
            "The \(side.rawValue) input is not a regular file."
        case let .fileTooLarge(side, actualByteCount, limit):
            "The \(side.rawValue) file has \(actualByteCount) bytes, exceeding the \(limit)-byte comparison limit."
        case let .comparisonChunkLimitExceeded(requiredChunkCount, limit):
            "The comparison requires \(requiredChunkCount) chunks, exceeding the \(limit)-chunk work limit."
        case let .pageLengthOutOfBounds(requested, limit):
            "The requested \(requested)-byte page is outside the allowed range of 1 through \(limit) bytes."
        case let .pageOffsetOutOfBounds(offset, maximum):
            "The requested page offset \(offset) exceeds the \(maximum)-byte comparison extent."
        case .offsetOverflow:
            "The requested local hexadecimal comparison offset overflows."
        case let .fileChangedDuringOperation(side):
            "The \(side.rawValue) file changed during hexadecimal comparison."
        }
    }

    private static func posixMessage(_ code: Int32) -> String {
        guard let message = strerror(code) else { return "unknown error" }
        return String(cString: message)
    }
}

/// Actor-isolated, descriptor-backed same-offset local binary comparison.
/// It never materializes either full file or the full set of display rows.
public actor LocalHexComparisonEngine {
    public nonisolated let limits: LocalHexComparisonLimits

    public init(limits: LocalHexComparisonLimits = .standard) {
        self.limits = limits
    }

    public func compare(leftURL: URL, rightURL: URL) async throws -> LocalHexComparisonSummary {
        try Task.checkCancellation()
        let pair = try openPair(leftURL: leftURL, rightURL: rightURL)
        defer {
            _ = Darwin.close(pair.left.descriptor)
            _ = Darwin.close(pair.right.descriptor)
        }

        let maximumByteCount = max(pair.left.version.byteCount, pair.right.version.byteCount)
        try enforceComparisonLimits(maximumByteCount: maximumByteCount)

        var offset: UInt64 = 0
        var differingBytePositionCount: UInt64 = 0
        var differenceRangeCount: UInt64 = 0
        var publishedRanges: [LocalBinaryDifferenceRange] = []
        publishedRanges.reserveCapacity(
            min(limits.maximumPublishedDifferenceRangeCount, 4_096)
        )
        var openDifferenceStart: UInt64?

        while offset < maximumByteCount {
            try Task.checkCancellation()
            let remaining = maximumByteCount - offset
            let plannedCount = Int(min(UInt64(limits.comparisonChunkByteCount), remaining))
            let leftCount = boundedReadCount(
                fileByteCount: pair.left.version.byteCount,
                offset: offset,
                maximumCount: plannedCount
            )
            let rightCount = boundedReadCount(
                fileByteCount: pair.right.version.byteCount,
                offset: offset,
                maximumCount: plannedCount
            )
            let leftBytes = try readExactly(
                pair.left,
                side: .left,
                offset: offset,
                count: leftCount
            )
            let rightBytes = try readExactly(
                pair.right,
                side: .right,
                offset: offset,
                count: rightCount
            )

            for index in 0..<plannedCount {
                let leftByte: UInt8? = index < leftBytes.count ? leftBytes[index] : nil
                let rightByte: UInt8? = index < rightBytes.count ? rightBytes[index] : nil
                let absoluteOffset = offset + UInt64(index)
                if leftByte != rightByte {
                    differingBytePositionCount += 1
                    if openDifferenceStart == nil {
                        openDifferenceStart = absoluteOffset
                    }
                } else if let start = openDifferenceStart {
                    appendRange(
                        start: start,
                        end: absoluteOffset,
                        leftByteCount: pair.left.version.byteCount,
                        rightByteCount: pair.right.version.byteCount,
                        differenceRangeCount: &differenceRangeCount,
                        publishedRanges: &publishedRanges
                    )
                    openDifferenceStart = nil
                }
            }
            offset += UInt64(plannedCount)
            await Task.yield()
        }

        if let start = openDifferenceStart {
            appendRange(
                start: start,
                end: maximumByteCount,
                leftByteCount: pair.left.version.byteCount,
                rightByteCount: pair.right.version.byteCount,
                differenceRangeCount: &differenceRangeCount,
                publishedRanges: &publishedRanges
            )
        }

        try Task.checkCancellation()
        try verifyUnchanged(pair.left, side: .left)
        try verifyUnchanged(pair.right, side: .right)
        return LocalHexComparisonSummary(
            leftByteCount: pair.left.version.byteCount,
            rightByteCount: pair.right.version.byteCount,
            differingBytePositionCount: differingBytePositionCount,
            differenceRangeCount: differenceRangeCount,
            publishedDifferenceRanges: publishedRanges,
            leftVersion: pair.left.version,
            rightVersion: pair.right.version
        )
    }

    /// Reads one bounded page and verifies that both files still match the
    /// versions used to produce `summary` before and after the page read.
    public func page(
        leftURL: URL,
        rightURL: URL,
        matching summary: LocalHexComparisonSummary,
        offset: UInt64,
        byteCount requestedByteCount: Int? = nil
    ) async throws -> LocalHexComparisonPage {
        try Task.checkCancellation()
        let byteCount = requestedByteCount ?? limits.pageByteCount
        guard byteCount > 0, byteCount <= limits.pageByteCount else {
            throw LocalHexComparisonError.pageLengthOutOfBounds(
                requested: byteCount,
                limit: limits.pageByteCount
            )
        }
        guard offset <= summary.maximumByteCount else {
            throw LocalHexComparisonError.pageOffsetOutOfBounds(
                offset: offset,
                maximum: summary.maximumByteCount
            )
        }
        let requestedEnd = offset.addingReportingOverflow(UInt64(byteCount))
        guard !requestedEnd.overflow else {
            throw LocalHexComparisonError.offsetOverflow
        }
        let endOffset = min(requestedEnd.partialValue, summary.maximumByteCount)

        let pair = try openPair(leftURL: leftURL, rightURL: rightURL)
        defer {
            _ = Darwin.close(pair.left.descriptor)
            _ = Darwin.close(pair.right.descriptor)
        }
        guard pair.left.version == summary.leftVersion else {
            throw LocalHexComparisonError.fileChangedDuringOperation(side: .left)
        }
        guard pair.right.version == summary.rightVersion else {
            throw LocalHexComparisonError.fileChangedDuringOperation(side: .right)
        }

        let pageCount = Int(endOffset - offset)
        let leftCount = boundedReadCount(
            fileByteCount: pair.left.version.byteCount,
            offset: offset,
            maximumCount: pageCount
        )
        let rightCount = boundedReadCount(
            fileByteCount: pair.right.version.byteCount,
            offset: offset,
            maximumCount: pageCount
        )
        let leftBytes = try readExactly(
            pair.left,
            side: .left,
            offset: offset,
            count: leftCount
        )
        let rightBytes = try readExactly(
            pair.right,
            side: .right,
            offset: offset,
            count: rightCount
        )

        var rows: [LocalHexComparisonRow] = []
        let estimatedRows = pageCount == 0
            ? 0
            : (pageCount + limits.bytesPerRow - 1) / limits.bytesPerRow
        rows.reserveCapacity(estimatedRows)
        var pageIndex = 0
        while pageIndex < pageCount {
            try Task.checkCancellation()
            let rowCount = min(limits.bytesPerRow, pageCount - pageIndex)
            let leftEnd = min(pageIndex + rowCount, leftBytes.count)
            let rightEnd = min(pageIndex + rowCount, rightBytes.count)
            let leftRow = pageIndex < leftEnd ? Array(leftBytes[pageIndex..<leftEnd]) : []
            let rightRow = pageIndex < rightEnd ? Array(rightBytes[pageIndex..<rightEnd]) : []
            var differingColumns: [Int] = []
            for column in 0..<rowCount {
                let leftByte: UInt8? = column < leftRow.count ? leftRow[column] : nil
                let rightByte: UInt8? = column < rightRow.count ? rightRow[column] : nil
                if leftByte != rightByte { differingColumns.append(column) }
            }
            rows.append(LocalHexComparisonRow(
                offset: offset + UInt64(pageIndex),
                leftBytes: leftRow,
                rightBytes: rightRow,
                differingColumns: differingColumns
            ))
            pageIndex += rowCount
        }

        await Task.yield()
        try Task.checkCancellation()
        try verifyUnchanged(pair.left, side: .left)
        try verifyUnchanged(pair.right, side: .right)
        return LocalHexComparisonPage(
            offset: offset,
            endOffset: endOffset,
            maximumByteCount: summary.maximumByteCount,
            rows: rows
        )
    }

    private struct OpenFile {
        let descriptor: Int32
        let version: LocalHexFileVersion
    }

    private struct OpenPair {
        let left: OpenFile
        let right: OpenFile
    }

    private func openPair(leftURL: URL, rightURL: URL) throws -> OpenPair {
        let left = try openFile(leftURL, side: .left)
        do {
            let right = try openFile(rightURL, side: .right)
            return OpenPair(left: left, right: right)
        } catch {
            _ = Darwin.close(left.descriptor)
            throw error
        }
    }

    private func openFile(_ url: URL, side: LocalHexComparisonError.Side) throws -> OpenFile {
        guard url.isFileURL else {
            throw LocalHexComparisonError.nonFileURL(side: side)
        }
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/") else {
            throw LocalHexComparisonError.relativePath(side: side)
        }
        let descriptor = standardized.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw LocalHexComparisonError.operationFailed(
                side: side,
                operation: .open,
                code: errno
            )
        }
        do {
            let version = try inspect(descriptor, side: side)
            guard (version.mode & UInt16(S_IFMT)) == UInt16(S_IFREG) else {
                throw LocalHexComparisonError.notRegularFile(side: side)
            }
            guard version.byteCount <= limits.maximumComparableByteCount else {
                throw LocalHexComparisonError.fileTooLarge(
                    side: side,
                    actualByteCount: version.byteCount,
                    limit: limits.maximumComparableByteCount
                )
            }
            return OpenFile(descriptor: descriptor, version: version)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func inspect(
        _ descriptor: Int32,
        side: LocalHexComparisonError.Side
    ) throws -> LocalHexFileVersion {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw LocalHexComparisonError.operationFailed(
                side: side,
                operation: .inspect,
                code: errno
            )
        }
        guard information.st_size >= 0 else {
            throw LocalHexComparisonError.operationFailed(
                side: side,
                operation: .inspect,
                code: EIO
            )
        }
        return LocalHexFileVersion(
            device: UInt64(bitPattern: Int64(information.st_dev)),
            inode: UInt64(information.st_ino),
            byteCount: UInt64(information.st_size),
            mode: UInt16(information.st_mode),
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(information.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(information.st_ctimespec.tv_nsec)
        )
    }

    private func verifyUnchanged(
        _ file: OpenFile,
        side: LocalHexComparisonError.Side
    ) throws {
        guard try inspect(file.descriptor, side: side) == file.version else {
            throw LocalHexComparisonError.fileChangedDuringOperation(side: side)
        }
    }

    private func enforceComparisonLimits(maximumByteCount: UInt64) throws {
        guard maximumByteCount > 0 else { return }
        let chunkSize = UInt64(limits.comparisonChunkByteCount)
        let requiredChunks = 1 + ((maximumByteCount - 1) / chunkSize)
        guard requiredChunks <= UInt64(limits.maximumComparisonChunkCount) else {
            throw LocalHexComparisonError.comparisonChunkLimitExceeded(
                requiredChunkCount: requiredChunks,
                limit: limits.maximumComparisonChunkCount
            )
        }
    }

    private func boundedReadCount(
        fileByteCount: UInt64,
        offset: UInt64,
        maximumCount: Int
    ) -> Int {
        guard offset < fileByteCount else { return 0 }
        return Int(min(UInt64(maximumCount), fileByteCount - offset))
    }

    private func readExactly(
        _ file: OpenFile,
        side: LocalHexComparisonError.Side,
        offset: UInt64,
        count: Int
    ) throws -> [UInt8] {
        guard count > 0 else { return [] }
        guard offset <= UInt64(Int64.max) else {
            throw LocalHexComparisonError.offsetOverflow
        }
        var bytes = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            try Task.checkCancellation()
            let currentOffset = offset.addingReportingOverflow(UInt64(total))
            guard !currentOffset.overflow,
                  currentOffset.partialValue <= UInt64(Int64.max) else {
                throw LocalHexComparisonError.offsetOverflow
            }
            let readCount: Int = bytes.withUnsafeMutableBytes { storage in
                while true {
                    let result = Darwin.pread(
                        file.descriptor,
                        storage.baseAddress?.advanced(by: total),
                        count - total,
                        off_t(currentOffset.partialValue)
                    )
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard readCount >= 0 else {
                throw LocalHexComparisonError.operationFailed(
                    side: side,
                    operation: .read,
                    code: errno
                )
            }
            guard readCount > 0 else {
                throw LocalHexComparisonError.fileChangedDuringOperation(side: side)
            }
            total += readCount
        }
        return bytes
    }

    private func appendRange(
        start: UInt64,
        end: UInt64,
        leftByteCount: UInt64,
        rightByteCount: UInt64,
        differenceRangeCount: inout UInt64,
        publishedRanges: inout [LocalBinaryDifferenceRange]
    ) {
        differenceRangeCount += 1
        guard publishedRanges.count < limits.maximumPublishedDifferenceRangeCount else { return }
        publishedRanges.append(LocalBinaryDifferenceRange(
            startOffset: start,
            leftCount: coveredByteCount(start: start, end: end, fileByteCount: leftByteCount),
            rightCount: coveredByteCount(start: start, end: end, fileByteCount: rightByteCount)
        ))
    }

    private func coveredByteCount(
        start: UInt64,
        end: UInt64,
        fileByteCount: UInt64
    ) -> UInt64 {
        guard start < fileByteCount else { return 0 }
        return min(end, fileByteCount) - start
    }
}
