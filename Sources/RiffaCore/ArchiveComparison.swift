import CryptoKit
import Foundation

/// Resource ceilings for a two-sided, in-memory archive comparison.
///
/// These limits are deliberately stricter than ``ArchiveResourceLimits``: both direct
/// construction and decoding validate every value, and content budgets cover the sum of
/// bytes read and hashed from both archives.
public struct ArchiveComparisonLimits: Hashable, Codable, Sendable {
    public let archiveLimits: ArchiveResourceLimits
    public let maxComparedEntryCount: Int
    public let maxSingleFileReadByteCount: Int
    public let maxTotalReadAndHashByteCount: Int

    public init(
        archiveLimits: ArchiveResourceLimits = .default,
        maxComparedEntryCount: Int = 100_000,
        maxSingleFileReadByteCount: Int = 256 * 1_024 * 1_024,
        maxTotalReadAndHashByteCount: Int = 1_024 * 1_024 * 1_024
    ) throws {
        try Self.validateArchiveLimits(archiveLimits)
        guard maxComparedEntryCount > 0 else {
            throw ArchiveComparisonError(
                code: .invalidLimits,
                detail: "maxComparedEntryCount must be greater than zero"
            )
        }
        guard maxSingleFileReadByteCount > 0 else {
            throw ArchiveComparisonError(
                code: .invalidLimits,
                detail: "maxSingleFileReadByteCount must be greater than zero"
            )
        }
        guard maxTotalReadAndHashByteCount > 0 else {
            throw ArchiveComparisonError(
                code: .invalidLimits,
                detail: "maxTotalReadAndHashByteCount must be greater than zero"
            )
        }
        guard maxSingleFileReadByteCount <= maxTotalReadAndHashByteCount else {
            throw ArchiveComparisonError(
                code: .invalidLimits,
                detail: "maxSingleFileReadByteCount cannot exceed maxTotalReadAndHashByteCount"
            )
        }

        self.archiveLimits = archiveLimits
        self.maxComparedEntryCount = maxComparedEntryCount
        self.maxSingleFileReadByteCount = maxSingleFileReadByteCount
        self.maxTotalReadAndHashByteCount = maxTotalReadAndHashByteCount
    }

    public static let `default`: Self = {
        try! Self()
    }()

    private enum CodingKeys: String, CodingKey {
        case archiveLimits
        case maxComparedEntryCount
        case maxSingleFileReadByteCount
        case maxTotalReadAndHashByteCount
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            archiveLimits: values.decode(ArchiveResourceLimits.self, forKey: .archiveLimits),
            maxComparedEntryCount: values.decode(Int.self, forKey: .maxComparedEntryCount),
            maxSingleFileReadByteCount: values.decode(Int.self, forKey: .maxSingleFileReadByteCount),
            maxTotalReadAndHashByteCount: values.decode(Int.self, forKey: .maxTotalReadAndHashByteCount)
        )
    }

    private static func validateArchiveLimits(_ limits: ArchiveResourceLimits) throws {
        let integers: [(String, Int)] = [
            ("archiveLimits.maxArchiveByteCount", limits.maxArchiveByteCount),
            ("archiveLimits.maxEntryCount", limits.maxEntryCount),
            ("archiveLimits.maxEntryUncompressedByteCount", limits.maxEntryUncompressedByteCount),
            ("archiveLimits.maxTotalUncompressedByteCount", limits.maxTotalUncompressedByteCount),
            ("archiveLimits.maxPathByteCount", limits.maxPathByteCount),
            ("archiveLimits.maxPathDepth", limits.maxPathDepth),
        ]
        if let invalid = integers.first(where: { $0.1 <= 0 }) {
            throw ArchiveComparisonError(
                code: .invalidLimits,
                detail: "\(invalid.0) must be greater than zero"
            )
        }
        guard limits.maxExpansionRatio.isFinite, limits.maxExpansionRatio >= 1 else {
            throw ArchiveComparisonError(
                code: .invalidLimits,
                detail: "archiveLimits.maxExpansionRatio must be finite and at least 1"
            )
        }
        guard limits.maxEntryUncompressedByteCount <= limits.maxTotalUncompressedByteCount else {
            throw ArchiveComparisonError(
                code: .invalidLimits,
                detail: "archiveLimits.maxEntryUncompressedByteCount cannot exceed its total limit"
            )
        }
    }

    fileprivate func validate() throws {
        _ = try Self(
            archiveLimits: archiveLimits,
            maxComparedEntryCount: maxComparedEntryCount,
            maxSingleFileReadByteCount: maxSingleFileReadByteCount,
            maxTotalReadAndHashByteCount: maxTotalReadAndHashByteCount
        )
    }
}

/// Semantic rules used by ``ArchiveComparisonEngine``.
///
/// Compression is representation metadata, so it is ignored by default. Modification dates
/// and permissions are likewise opt-in to keep cross-format comparisons useful. File content,
/// uncompressed size, entry kind, and symbolic-link destination are semantic by default.
public struct ArchiveComparisonOptions: Hashable, Codable, Sendable {
    public let limits: ArchiveComparisonLimits
    public let compareContent: Bool
    public let compareModificationDate: Bool
    public let comparePermissions: Bool
    public let compareCompression: Bool

    public init(
        limits: ArchiveComparisonLimits = .default,
        compareContent: Bool = true,
        compareModificationDate: Bool = false,
        comparePermissions: Bool = false,
        compareCompression: Bool = false
    ) throws {
        try limits.validate()
        self.limits = limits
        self.compareContent = compareContent
        self.compareModificationDate = compareModificationDate
        self.comparePermissions = comparePermissions
        self.compareCompression = compareCompression
    }

    public static let `default`: Self = {
        try! Self()
    }()

    private enum CodingKeys: String, CodingKey {
        case limits
        case compareContent
        case compareModificationDate
        case comparePermissions
        case compareCompression
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            limits: values.decode(ArchiveComparisonLimits.self, forKey: .limits),
            compareContent: values.decode(Bool.self, forKey: .compareContent),
            compareModificationDate: values.decode(Bool.self, forKey: .compareModificationDate),
            comparePermissions: values.decode(Bool.self, forKey: .comparePermissions),
            compareCompression: values.decode(Bool.self, forKey: .compareCompression)
        )
    }
}

/// Stable, path-free failures owned by the comparison layer.
public struct ArchiveComparisonError: Error, Hashable, Codable, Sendable, LocalizedError {
    public enum Code: String, Hashable, Codable, Sendable {
        case invalidLimits
        case archiveResourceLimitExceeded
        case comparedEntryLimitExceeded
        case singleFileReadLimitExceeded
        case totalReadAndHashLimitExceeded
    }

    public let code: Code
    public let detail: String

    public init(code: Code, detail: String) {
        self.code = code
        self.detail = detail
    }

    public var errorDescription: String? { detail }
}

public enum ArchiveComparisonStatus: String, Hashable, Codable, Sendable {
    case same
    case different
    case leftOnly
    case rightOnly
}

public enum ArchiveComparisonDifferenceField: String, CaseIterable, Hashable, Codable, Sendable {
    case kind
    case uncompressedByteCount
    case modificationDate
    case permissions
    case compression
    case symbolicLinkDestination
    case content
}

/// A report-safe archive entry summary. It contains neither member bytes nor an external
/// resource locator; `path` lives on the row and is always normalized by the provider.
public struct ArchiveComparisonEntrySummary: Hashable, Codable, Sendable {
    public let kind: ArchiveResourceEntry.Kind
    public let uncompressedByteCount: Int
    public let compressedByteCount: Int
    public let compression: ArchiveResourceEntry.Compression
    public let modificationDate: Date?
    public let permissions: UInt16?
    public let symbolicLinkDestination: String?
    public let contentSHA256: String?

    public init(
        kind: ArchiveResourceEntry.Kind,
        uncompressedByteCount: Int,
        compressedByteCount: Int,
        compression: ArchiveResourceEntry.Compression,
        modificationDate: Date? = nil,
        permissions: UInt16? = nil,
        symbolicLinkDestination: String? = nil,
        contentSHA256: String? = nil
    ) {
        self.kind = kind
        self.uncompressedByteCount = uncompressedByteCount
        self.compressedByteCount = compressedByteCount
        self.compression = compression
        self.modificationDate = modificationDate
        self.permissions = permissions
        self.symbolicLinkDestination = symbolicLinkDestination
        self.contentSHA256 = contentSHA256
    }
}

public struct ArchiveComparisonRow: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: ArchiveComparisonStatus
    public let left: ArchiveComparisonEntrySummary?
    public let right: ArchiveComparisonEntrySummary?
    public let differenceFields: [ArchiveComparisonDifferenceField]

    public init(
        path: String,
        status: ArchiveComparisonStatus,
        left: ArchiveComparisonEntrySummary?,
        right: ArchiveComparisonEntrySummary?,
        differenceFields: [ArchiveComparisonDifferenceField] = []
    ) {
        self.path = path
        self.status = status
        self.left = left
        self.right = right
        self.differenceFields = differenceFields
    }
}

public struct ArchiveComparisonStatistics: Hashable, Codable, Sendable {
    public let totalCount: Int
    public let sameCount: Int
    public let differentCount: Int
    public let leftOnlyCount: Int
    public let rightOnlyCount: Int
    public let hashedFileCount: Int
    public let readAndHashedByteCount: Int

    public init(
        totalCount: Int,
        sameCount: Int,
        differentCount: Int,
        leftOnlyCount: Int,
        rightOnlyCount: Int,
        hashedFileCount: Int,
        readAndHashedByteCount: Int
    ) {
        self.totalCount = totalCount
        self.sameCount = sameCount
        self.differentCount = differentCount
        self.leftOnlyCount = leftOnlyCount
        self.rightOnlyCount = rightOnlyCount
        self.hashedFileCount = hashedFileCount
        self.readAndHashedByteCount = readAndHashedByteCount
    }
}

public struct ArchiveComparisonResult: Hashable, Codable, Sendable {
    public let leftFormat: ArchiveResourceFormat
    public let rightFormat: ArchiveResourceFormat
    public let options: ArchiveComparisonOptions
    public let rows: [ArchiveComparisonRow]
    public let statistics: ArchiveComparisonStatistics

    public init(
        leftFormat: ArchiveResourceFormat,
        rightFormat: ArchiveResourceFormat,
        options: ArchiveComparisonOptions,
        rows: [ArchiveComparisonRow],
        statistics: ArchiveComparisonStatistics
    ) {
        self.leftFormat = leftFormat
        self.rightFormat = rightFormat
        self.options = options
        self.rows = rows
        self.statistics = statistics
    }

    public var hasDifferences: Bool {
        statistics.differentCount > 0
            || statistics.leftOnlyCount > 0
            || statistics.rightOnlyCount > 0
    }
}

/// Compares two already-bounded TAR or ZIP byte buffers without extracting any member.
public struct ArchiveComparisonEngine: Sendable {
    public init() {}

    public func compare(
        left: Data,
        right: Data,
        leftFormat: ArchiveResourceFormat = .automatic,
        rightFormat: ArchiveResourceFormat = .automatic,
        options: ArchiveComparisonOptions = .default
    ) throws -> ArchiveComparisonResult {
        try Task.checkCancellation()
        try options.limits.validate()
        let leftProvider = try makeProvider(
            data: left,
            format: leftFormat,
            limits: options.limits.archiveLimits
        )
        let rightProvider = try makeProvider(
            data: right,
            format: rightFormat,
            limits: options.limits.archiveLimits
        )
        let leftEntries = leftProvider.list()
        let rightEntries = rightProvider.list()
        try Task.checkCancellation()

        var rows: [ArchiveComparisonRow] = []
        rows.reserveCapacity(min(
            options.limits.maxComparedEntryCount,
            max(leftEntries.count, rightEntries.count)
        ))
        var leftIndex = 0
        var rightIndex = 0
        var contentBudget = ContentBudget()

        while leftIndex < leftEntries.count || rightIndex < rightEntries.count {
            try Task.checkCancellation()
            guard rows.count < options.limits.maxComparedEntryCount else {
                throw ArchiveComparisonError(
                    code: .comparedEntryLimitExceeded,
                    detail: "Archive comparison entry limit was exceeded"
                )
            }

            if leftIndex == leftEntries.count {
                let entry = rightEntries[rightIndex]
                rows.append(oneSidedRow(entry, status: .rightOnly))
                rightIndex += 1
                continue
            }
            if rightIndex == rightEntries.count {
                let entry = leftEntries[leftIndex]
                rows.append(oneSidedRow(entry, status: .leftOnly))
                leftIndex += 1
                continue
            }

            let leftEntry = leftEntries[leftIndex]
            let rightEntry = rightEntries[rightIndex]
            if leftEntry.path < rightEntry.path {
                rows.append(oneSidedRow(leftEntry, status: .leftOnly))
                leftIndex += 1
            } else if rightEntry.path < leftEntry.path {
                rows.append(oneSidedRow(rightEntry, status: .rightOnly))
                rightIndex += 1
            } else {
                rows.append(try comparePair(
                    leftEntry,
                    rightEntry,
                    leftProvider: leftProvider,
                    rightProvider: rightProvider,
                    options: options,
                    budget: &contentBudget
                ))
                leftIndex += 1
                rightIndex += 1
            }
        }

        let sameCount = rows.lazy.filter { $0.status == .same }.count
        let differentCount = rows.lazy.filter { $0.status == .different }.count
        let leftOnlyCount = rows.lazy.filter { $0.status == .leftOnly }.count
        let rightOnlyCount = rows.lazy.filter { $0.status == .rightOnly }.count
        return ArchiveComparisonResult(
            leftFormat: leftProvider.format,
            rightFormat: rightProvider.format,
            options: options,
            rows: rows,
            statistics: ArchiveComparisonStatistics(
                totalCount: rows.count,
                sameCount: sameCount,
                differentCount: differentCount,
                leftOnlyCount: leftOnlyCount,
                rightOnlyCount: rightOnlyCount,
                hashedFileCount: contentBudget.hashedFileCount,
                readAndHashedByteCount: contentBudget.byteCount
            )
        )
    }

    private func comparePair(
        _ left: ArchiveResourceEntry,
        _ right: ArchiveResourceEntry,
        leftProvider: ArchiveResourceProvider,
        rightProvider: ArchiveResourceProvider,
        options: ArchiveComparisonOptions,
        budget: inout ContentBudget
    ) throws -> ArchiveComparisonRow {
        var differences: [ArchiveComparisonDifferenceField] = []
        var leftDigest: String?
        var rightDigest: String?

        if left.kind != right.kind {
            differences.append(.kind)
        } else {
            switch left.kind {
            case .file:
                if left.uncompressedByteCount != right.uncompressedByteCount {
                    differences.append(.uncompressedByteCount)
                    if options.compareContent {
                        differences.append(.content)
                    }
                } else if options.compareContent {
                    try reserveContentBytes(
                        left.uncompressedByteCount,
                        right.uncompressedByteCount,
                        limits: options.limits,
                        budget: &budget
                    )
                    let leftData = try read(left.path, from: leftProvider)
                    try Task.checkCancellation()
                    let rightData = try read(right.path, from: rightProvider)
                    try Task.checkCancellation()
                    leftDigest = try Self.sha256(leftData)
                    rightDigest = try Self.sha256(rightData)
                    budget.hashedFileCount += 2
                    budget.byteCount += leftData.count + rightData.count
                    if leftDigest != rightDigest {
                        differences.append(.content)
                    }
                }
                if options.compareCompression, left.compression != right.compression {
                    differences.append(.compression)
                }
            case .directory:
                break
            case .symbolicLink:
                if left.symbolicLinkDestination != right.symbolicLinkDestination {
                    differences.append(.symbolicLinkDestination)
                }
            }
        }

        if options.compareModificationDate, left.modificationDate != right.modificationDate {
            differences.append(.modificationDate)
        }
        if options.comparePermissions, left.permissions != right.permissions {
            differences.append(.permissions)
        }

        return ArchiveComparisonRow(
            path: left.path,
            status: differences.isEmpty ? .same : .different,
            left: summary(left, digest: leftDigest),
            right: summary(right, digest: rightDigest),
            differenceFields: differences
        )
    }

    private func oneSidedRow(
        _ entry: ArchiveResourceEntry,
        status: ArchiveComparisonStatus
    ) -> ArchiveComparisonRow {
        ArchiveComparisonRow(
            path: entry.path,
            status: status,
            left: status == .leftOnly ? summary(entry, digest: nil) : nil,
            right: status == .rightOnly ? summary(entry, digest: nil) : nil
        )
    }

    private func summary(
        _ entry: ArchiveResourceEntry,
        digest: String?
    ) -> ArchiveComparisonEntrySummary {
        ArchiveComparisonEntrySummary(
            kind: entry.kind,
            uncompressedByteCount: entry.uncompressedByteCount,
            compressedByteCount: entry.compressedByteCount,
            compression: entry.compression,
            modificationDate: entry.modificationDate,
            permissions: entry.permissions,
            symbolicLinkDestination: entry.symbolicLinkDestination,
            contentSHA256: digest
        )
    }

    private func reserveContentBytes(
        _ leftCount: Int,
        _ rightCount: Int,
        limits: ArchiveComparisonLimits,
        budget: inout ContentBudget
    ) throws {
        guard leftCount <= limits.maxSingleFileReadByteCount,
              rightCount <= limits.maxSingleFileReadByteCount else {
            throw ArchiveComparisonError(
                code: .singleFileReadLimitExceeded,
                detail: "An archive member exceeds the single-file content-read limit"
            )
        }
        let (pairCount, pairOverflow) = leftCount.addingReportingOverflow(rightCount)
        let (nextTotal, totalOverflow) = budget.byteCount.addingReportingOverflow(pairCount)
        guard !pairOverflow, !totalOverflow,
              nextTotal <= limits.maxTotalReadAndHashByteCount else {
            throw ArchiveComparisonError(
                code: .totalReadAndHashLimitExceeded,
                detail: "Archive comparison content-read and hash budget was exceeded"
            )
        }
    }

    private func makeProvider(
        data: Data,
        format: ArchiveResourceFormat,
        limits: ArchiveResourceLimits
    ) throws -> ArchiveResourceProvider {
        do {
            return try ArchiveResourceProvider(data: data, format: format, limits: limits)
        } catch let error as ArchiveResourceError {
            throw sanitizedProviderError(error)
        }
    }

    private func read(_ path: String, from provider: ArchiveResourceProvider) throws -> Data {
        do {
            return try provider.read(path)
        } catch let error as ArchiveResourceError {
            throw sanitizedProviderError(error)
        }
    }

    private func sanitizedProviderError(_ error: ArchiveResourceError) -> any Error {
        switch error.code {
        case .pathLimitExceeded,
             .entryLimitExceeded,
             .entrySizeLimitExceeded,
             .totalSizeLimitExceeded,
             .archiveSizeLimitExceeded,
             .expansionRatioLimitExceeded:
            ArchiveComparisonError(
                code: .archiveResourceLimitExceeded,
                detail: "Archive resource limit was exceeded (\(error.code.rawValue))"
            )
        default:
            error
        }
    }

    private static func sha256(_ data: Data) throws -> String {
        var hasher = SHA256()
        let chunkByteCount = 1 * 1_024 * 1_024
        var offset = data.startIndex
        while offset < data.endIndex {
            try Task.checkCancellation()
            let end = min(data.endIndex, offset + chunkByteCount)
            hasher.update(data: data[offset..<end])
            offset = end
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct ContentBudget {
    var hashedFileCount = 0
    var byteCount = 0
}
