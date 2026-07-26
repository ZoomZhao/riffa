import CryptoKit
import Darwin
import Foundation

/// A compact replacement for raw binary metadata values.
public struct MetadataDataSummary: Hashable, Codable, Sendable {
    public let byteCount: Int
    public let sha256: String

    public init(byteCount: Int, sha256: String) {
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public init(data: Data) {
        byteCount = data.count
        sha256 = SHA256.hash(data: data).map { byte in
            String(format: "%02x", byte)
        }.joined()
    }
}

/// Typed metadata that can represent common media, document, and version
/// properties without depending on a specific file-format framework.
public enum MetadataValue: Equatable, Codable, Sendable {
    case string(String)
    case integer(Int64)
    case decimal(Decimal)
    case boolean(Bool)
    case date(Date)
    case data(MetadataDataSummary)
    case null

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Kind: String, Codable {
        case string
        case integer
        case decimal
        case boolean
        case date
        case data
        case null
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .value))
        case .decimal:
            self = .decimal(try container.decode(Decimal.self, forKey: .value))
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .date:
            self = .date(try container.decode(Date.self, forKey: .value))
        case .data:
            self = .data(try container.decode(MetadataDataSummary.self, forKey: .value))
        case .null:
            self = .null
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try container.encode(Kind.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .decimal(value):
            try container.encode(Kind.decimal, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .date(value):
            try container.encode(Kind.date, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .data(value):
            try container.encode(Kind.data, forKey: .type)
            try container.encode(value, forKey: .value)
        case .null:
            try container.encode(Kind.null, forKey: .type)
        }
    }
}

public enum MetadataImportance: String, CaseIterable, Codable, Sendable {
    case informational
    case normal
    case important
    case critical

    fileprivate var rank: Int {
        switch self {
        case .informational: 0
        case .normal: 1
        case .important: 2
        case .critical: 3
        }
    }
}

public struct MetadataField: Equatable, Codable, Sendable {
    public let key: String
    public let displayName: String
    public let value: MetadataValue
    public let importance: MetadataImportance

    public init(
        key: String,
        displayName: String,
        value: MetadataValue,
        importance: MetadataImportance = .normal
    ) {
        self.key = key
        self.displayName = displayName
        self.value = value
        self.importance = importance
    }
}

public struct MetadataComparisonOptions: Equatable, Codable, Sendable {
    public var ignoreStringCase: Bool
    public var ignoreStringWhitespace: Bool
    public var numericTolerance: Decimal
    public var dateTolerance: TimeInterval
    public var ignoredKeys: Set<String>

    public init(
        ignoreStringCase: Bool = false,
        ignoreStringWhitespace: Bool = false,
        numericTolerance: Decimal = 0,
        dateTolerance: TimeInterval = 0,
        ignoredKeys: Set<String> = []
    ) {
        self.ignoreStringCase = ignoreStringCase
        self.ignoreStringWhitespace = ignoreStringWhitespace
        self.numericTolerance = numericTolerance < 0 ? 0 : numericTolerance
        self.dateTolerance = dateTolerance.isFinite ? max(0, dateTolerance) : 0
        self.ignoredKeys = ignoredKeys
    }
}

public enum MetadataComparisonStatus: String, Codable, Sendable {
    case same
    case different
    case leftOnly
    case rightOnly
}

/// One occurrence-paired metadata row. `occurrenceIndex` is zero-based within
/// its key and ensures duplicate keys are never silently overwritten.
public struct MetadataComparisonRow: Equatable, Codable, Sendable {
    public let key: String
    public let occurrenceIndex: Int
    public let displayName: String
    public let importance: MetadataImportance
    public let left: MetadataField?
    public let right: MetadataField?
    public let status: MetadataComparisonStatus

    public init(
        key: String,
        occurrenceIndex: Int,
        displayName: String,
        importance: MetadataImportance,
        left: MetadataField?,
        right: MetadataField?,
        status: MetadataComparisonStatus
    ) {
        self.key = key
        self.occurrenceIndex = occurrenceIndex
        self.displayName = displayName
        self.importance = importance
        self.left = left
        self.right = right
        self.status = status
    }
}

public struct MetadataComparisonStatistics: Equatable, Codable, Sendable {
    public let totalCount: Int
    public let sameCount: Int
    public let differentCount: Int
    public let leftOnlyCount: Int
    public let rightOnlyCount: Int

    public init(
        totalCount: Int,
        sameCount: Int,
        differentCount: Int,
        leftOnlyCount: Int,
        rightOnlyCount: Int
    ) {
        self.totalCount = totalCount
        self.sameCount = sameCount
        self.differentCount = differentCount
        self.leftOnlyCount = leftOnlyCount
        self.rightOnlyCount = rightOnlyCount
    }
}

public struct MetadataComparisonResult: Equatable, Codable, Sendable {
    public let rows: [MetadataComparisonRow]
    public let statistics: MetadataComparisonStatistics

    public init(rows: [MetadataComparisonRow], statistics: MetadataComparisonStatistics) {
        self.rows = rows
        self.statistics = statistics
    }

    public var hasDifferences: Bool {
        statistics.differentCount > 0
            || statistics.leftOnlyCount > 0
            || statistics.rightOnlyCount > 0
    }
}

public struct MetadataComparison: Sendable {
    public init() {}

    public func compare(
        left: [MetadataField],
        right: [MetadataField],
        options: MetadataComparisonOptions = .init()
    ) -> MetadataComparisonResult {
        let leftGroups = groupedByKey(left, ignoring: options.ignoredKeys)
        let rightGroups = groupedByKey(right, ignoring: options.ignoredKeys)
        let keys = Set(leftGroups.keys).union(rightGroups.keys).sorted()
        var rows: [MetadataComparisonRow] = []

        for key in keys {
            let leftFields = leftGroups[key, default: []]
            let rightFields = rightGroups[key, default: []]
            let occurrenceCount = max(leftFields.count, rightFields.count)

            for occurrenceIndex in 0..<occurrenceCount {
                let leftField = leftFields.indices.contains(occurrenceIndex)
                    ? leftFields[occurrenceIndex]
                    : nil
                let rightField = rightFields.indices.contains(occurrenceIndex)
                    ? rightFields[occurrenceIndex]
                    : nil
                let status = status(
                    left: leftField,
                    right: rightField,
                    options: options
                )

                rows.append(
                    MetadataComparisonRow(
                        key: key,
                        occurrenceIndex: occurrenceIndex,
                        displayName: leftField?.displayName ?? rightField?.displayName ?? key,
                        importance: greaterImportance(
                            leftField?.importance,
                            rightField?.importance
                        ),
                        left: leftField,
                        right: rightField,
                        status: status
                    )
                )
            }
        }

        return MetadataComparisonResult(
            rows: rows,
            statistics: statistics(for: rows)
        )
    }

    private func groupedByKey(
        _ fields: [MetadataField],
        ignoring ignoredKeys: Set<String>
    ) -> [String: [MetadataField]] {
        var result: [String: [MetadataField]] = [:]
        for field in fields where !ignoredKeys.contains(field.key) {
            result[field.key, default: []].append(field)
        }
        return result
    }

    private func status(
        left: MetadataField?,
        right: MetadataField?,
        options: MetadataComparisonOptions
    ) -> MetadataComparisonStatus {
        switch (left, right) {
        case let (left?, right?):
            valuesAreEqual(left.value, right.value, options: options) ? .same : .different
        case (.some, nil):
            .leftOnly
        case (nil, .some):
            .rightOnly
        case (nil, nil):
            // Construction never produces an empty pair.
            .same
        }
    }

    private func valuesAreEqual(
        _ left: MetadataValue,
        _ right: MetadataValue,
        options: MetadataComparisonOptions
    ) -> Bool {
        switch (left, right) {
        case let (.string(leftValue), .string(rightValue)):
            return normalizedString(leftValue, options: options)
                == normalizedString(rightValue, options: options)

        case let (.integer(leftValue), .integer(rightValue)):
            return decimalDistance(Decimal(leftValue), Decimal(rightValue))
                <= options.numericTolerance

        case let (.decimal(leftValue), .decimal(rightValue)):
            return decimalDistance(leftValue, rightValue) <= options.numericTolerance

        case let (.boolean(leftValue), .boolean(rightValue)):
            return leftValue == rightValue

        case let (.date(leftValue), .date(rightValue)):
            return abs(leftValue.timeIntervalSince(rightValue)) <= options.dateTolerance

        case let (.data(leftValue), .data(rightValue)):
            return leftValue == rightValue

        case (.null, .null):
            return true

        default:
            // Equal-looking values of different semantic types stay different.
            return false
        }
    }

    private func normalizedString(
        _ value: String,
        options: MetadataComparisonOptions
    ) -> String {
        var result = value
        if options.ignoreStringWhitespace {
            result.removeAll(where: \.isWhitespace)
        }
        if options.ignoreStringCase {
            result = result.lowercased(with: Locale(identifier: "en_US_POSIX"))
        }
        return result
    }

    private func decimalDistance(_ left: Decimal, _ right: Decimal) -> Decimal {
        let difference = left - right
        return difference < 0 ? -difference : difference
    }

    private func greaterImportance(
        _ left: MetadataImportance?,
        _ right: MetadataImportance?
    ) -> MetadataImportance {
        switch (left, right) {
        case let (left?, right?): left.rank >= right.rank ? left : right
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): .normal
        }
    }

    private func statistics(
        for rows: [MetadataComparisonRow]
    ) -> MetadataComparisonStatistics {
        var same = 0
        var different = 0
        var leftOnly = 0
        var rightOnly = 0

        for row in rows {
            switch row.status {
            case .same: same += 1
            case .different: different += 1
            case .leftOnly: leftOnly += 1
            case .rightOnly: rightOnly += 1
            }
        }

        return MetadataComparisonStatistics(
            totalCount: rows.count,
            sameCount: same,
            differentCount: different,
            leftOnlyCount: leftOnly,
            rightOnlyCount: rightOnly
        )
    }
}

// MARK: - Bounded local file-system metadata

/// The input side attached to every local metadata read error. The engine does
/// not embed an absolute resource locator in its portable result or errors.
public enum LocalMetadataSide: String, Codable, Sendable {
    case left
    case right
}

public enum LocalMetadataItemType: String, Codable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case characterDevice
    case blockDevice
    case fifo
    case socket
    case unknown
}

public struct LocalMetadataTimestamp: Equatable, Codable, Sendable {
    public let secondsSince1970: Int64
    public let nanoseconds: Int32

    public init(secondsSince1970: Int64, nanoseconds: Int32) {
        self.secondsSince1970 = secondsSince1970
        self.nanoseconds = nanoseconds
    }

    public var date: Date {
        Date(
            timeIntervalSince1970: Double(secondsSince1970)
                + (Double(nanoseconds) / 1_000_000_000)
        )
    }
}

/// A value-free extended-attribute representation. Only the length and digest
/// are retained, so reports and JSON never disclose raw Finder tags, quarantine
/// payloads, or other potentially sensitive xattr contents.
public struct LocalMetadataExtendedAttribute: Equatable, Codable, Sendable {
    public let name: String
    public let valueSummary: MetadataDataSummary

    public init(name: String, valueSummary: MetadataDataSummary) {
        self.name = name
        self.valueSummary = valueSummary
    }
}

/// A value-free representation of one macOS extended ACL. Entry order is
/// semantically meaningful, so the digest covers the bounded external
/// representation in order. Principal UUIDs and permissions are never stored
/// in the portable snapshot or reports.
public struct LocalMetadataAccessControlList: Equatable, Codable, Sendable {
    public let entryCount: Int
    public let valueSummary: MetadataDataSummary

    public init(entryCount: Int, valueSummary: MetadataDataSummary) {
        self.entryCount = entryCount
        self.valueSummary = valueSummary
    }
}

/// A portable snapshot of one directory entry. Directories are represented by
/// their own inode metadata only; they are never recursively enumerated. All
/// reads bind an `O_EVTONLY | O_SYMLINK` descriptor and use descriptor-backed
/// metadata APIs, so a symbolic link remains a link and is not followed into a
/// file or directory tree. A final path `lstat` must still rebind to that inode.
public struct LocalMetadataSnapshot: Equatable, Codable, Sendable {
    public let itemName: String
    public let itemType: LocalMetadataItemType
    public let byteCount: Int64
    public let modificationTime: LocalMetadataTimestamp
    public let creationTime: LocalMetadataTimestamp?
    public let posixPermissions: UInt32
    public let bsdFlags: UInt32?
    public let ownerID: UInt32
    public let groupID: UInt32
    public let symbolicLinkDestination: String?
    public let extendedAttributes: [LocalMetadataExtendedAttribute]
    public let accessControlList: LocalMetadataAccessControlList?

    public init(
        itemName: String,
        itemType: LocalMetadataItemType,
        byteCount: Int64,
        modificationTime: LocalMetadataTimestamp,
        creationTime: LocalMetadataTimestamp? = nil,
        posixPermissions: UInt32,
        bsdFlags: UInt32? = nil,
        ownerID: UInt32,
        groupID: UInt32,
        symbolicLinkDestination: String?,
        extendedAttributes: [LocalMetadataExtendedAttribute],
        accessControlList: LocalMetadataAccessControlList? = nil
    ) {
        self.itemName = itemName
        self.itemType = itemType
        self.byteCount = byteCount
        self.modificationTime = modificationTime
        self.creationTime = creationTime
        self.posixPermissions = posixPermissions
        self.bsdFlags = bsdFlags
        self.ownerID = ownerID
        self.groupID = groupID
        self.symbolicLinkDestination = symbolicLinkDestination
        self.extendedAttributes = extendedAttributes
        self.accessControlList = accessControlList
    }

    /// Stable typed fields consumed by the generic metadata comparison and
    /// report pipeline.
    public var fields: [MetadataField] {
        var result: [MetadataField] = [
            MetadataField(
                key: "file.name",
                displayName: "Name",
                value: .string(itemName),
                importance: .important
            ),
            MetadataField(
                key: "file.type",
                displayName: "Type",
                value: .string(itemType.rawValue),
                importance: .critical
            ),
            MetadataField(
                key: "file.byteCount",
                displayName: "Size (bytes)",
                value: .integer(byteCount),
                importance: .important
            ),
            MetadataField(
                key: "file.modified",
                displayName: "Modified",
                value: .date(modificationTime.date),
                importance: .normal
            ),
            MetadataField(
                key: "file.modifiedNanoseconds",
                displayName: "Modified nanosecond component",
                value: .integer(Int64(modificationTime.nanoseconds)),
                importance: .informational
            ),
            MetadataField(
                key: "file.posixPermissions",
                displayName: "POSIX permissions",
                value: .string(String(format: "%04o", posixPermissions)),
                importance: .important
            ),
            MetadataField(
                key: "file.ownerID",
                displayName: "Owner ID",
                value: .integer(Int64(ownerID)),
                importance: .normal
            ),
            MetadataField(
                key: "file.groupID",
                displayName: "Group ID",
                value: .integer(Int64(groupID)),
                importance: .normal
            )
        ]

        if let creationTime {
            result.append(contentsOf: [
                MetadataField(
                    key: "file.created",
                    displayName: "Created",
                    value: .date(creationTime.date),
                    importance: .normal
                ),
                MetadataField(
                    key: "file.createdNanoseconds",
                    displayName: "Created nanosecond component",
                    value: .integer(Int64(creationTime.nanoseconds)),
                    importance: .informational
                )
            ])
        }
        if let bsdFlags {
            result.append(
                MetadataField(
                    key: "file.bsdFlags",
                    displayName: "BSD flags",
                    value: .string(String(format: "0x%08x", bsdFlags)),
                    importance: .important
                )
            )
        }

        if let symbolicLinkDestination {
            result.append(
                MetadataField(
                    key: "file.symbolicLinkDestination",
                    displayName: "Symbolic link destination",
                    value: .string(symbolicLinkDestination),
                    importance: .critical
                )
            )
        }
        for attribute in extendedAttributes {
            result.append(
                MetadataField(
                    key: "xattr.\(attribute.name)",
                    displayName: "Extended attribute: \(attribute.name)",
                    value: .data(attribute.valueSummary),
                    importance: .normal
                )
            )
        }
        if let accessControlList {
            result.append(contentsOf: [
                MetadataField(
                    key: "file.accessControlEntryCount",
                    displayName: "Access-control entries",
                    value: .integer(Int64(accessControlList.entryCount)),
                    importance: .important
                ),
                MetadataField(
                    key: "file.accessControlList",
                    displayName: "Access-control list",
                    value: .data(accessControlList.valueSummary),
                    importance: .critical
                )
            ])
        }
        return result
    }
}

public struct LocalMetadataComparisonResult: Equatable, Codable, Sendable {
    public let left: LocalMetadataSnapshot
    public let right: LocalMetadataSnapshot
    public let comparison: MetadataComparisonResult

    public init(
        left: LocalMetadataSnapshot,
        right: LocalMetadataSnapshot,
        comparison: MetadataComparisonResult
    ) {
        self.left = left
        self.right = right
        self.comparison = comparison
    }

    public var hasDifferences: Bool { comparison.hasDifferences }
}

public struct LocalMetadataReadLimits: Equatable, Codable, Sendable {
    public let maximumExtendedAttributeNameBytes: Int
    public let maximumExtendedAttributeCount: Int
    public let maximumExtendedAttributeValueBytes: Int
    public let maximumTotalExtendedAttributeValueBytes: Int
    public let maximumSymbolicLinkDestinationBytes: Int
    public let maximumAccessControlListBytes: Int
    public let maximumAccessControlEntryCount: Int

    public init(
        maximumExtendedAttributeNameBytes: Int = 256 * 1_024,
        maximumExtendedAttributeCount: Int = 512,
        maximumExtendedAttributeValueBytes: Int = 1 * 1_024 * 1_024,
        maximumTotalExtendedAttributeValueBytes: Int = 8 * 1_024 * 1_024,
        maximumSymbolicLinkDestinationBytes: Int = 16 * 1_024,
        maximumAccessControlListBytes: Int = 64 * 1_024,
        maximumAccessControlEntryCount: Int = 256
    ) {
        self.maximumExtendedAttributeNameBytes = max(1, maximumExtendedAttributeNameBytes)
        self.maximumExtendedAttributeCount = max(1, maximumExtendedAttributeCount)
        self.maximumExtendedAttributeValueBytes = max(0, maximumExtendedAttributeValueBytes)
        self.maximumTotalExtendedAttributeValueBytes = max(0, maximumTotalExtendedAttributeValueBytes)
        self.maximumSymbolicLinkDestinationBytes = max(1, maximumSymbolicLinkDestinationBytes)
        self.maximumAccessControlListBytes = max(0, maximumAccessControlListBytes)
        self.maximumAccessControlEntryCount = max(1, maximumAccessControlEntryCount)
    }

    private enum CodingKeys: String, CodingKey {
        case maximumExtendedAttributeNameBytes
        case maximumExtendedAttributeCount
        case maximumExtendedAttributeValueBytes
        case maximumTotalExtendedAttributeValueBytes
        case maximumSymbolicLinkDestinationBytes
        case maximumAccessControlListBytes
        case maximumAccessControlEntryCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maximumExtendedAttributeNameBytes: try container.decode(
                Int.self,
                forKey: .maximumExtendedAttributeNameBytes
            ),
            maximumExtendedAttributeCount: try container.decode(
                Int.self,
                forKey: .maximumExtendedAttributeCount
            ),
            maximumExtendedAttributeValueBytes: try container.decode(
                Int.self,
                forKey: .maximumExtendedAttributeValueBytes
            ),
            maximumTotalExtendedAttributeValueBytes: try container.decode(
                Int.self,
                forKey: .maximumTotalExtendedAttributeValueBytes
            ),
            maximumSymbolicLinkDestinationBytes: try container.decode(
                Int.self,
                forKey: .maximumSymbolicLinkDestinationBytes
            ),
            maximumAccessControlListBytes: try container.decodeIfPresent(
                Int.self,
                forKey: .maximumAccessControlListBytes
            ) ?? 64 * 1_024,
            maximumAccessControlEntryCount: try container.decodeIfPresent(
                Int.self,
                forKey: .maximumAccessControlEntryCount
            ) ?? 256
        )
    }
}

public enum LocalMetadataComparisonError: Error, Equatable, Codable, Sendable {
    case nonFileURL(side: LocalMetadataSide)
    case relativePath(side: LocalMetadataSide, itemName: String)
    case metadataReadFailed(side: LocalMetadataSide, itemName: String, operation: String, code: Int32)
    case extendedAttributeNameListTooLarge(side: LocalMetadataSide, itemName: String, actual: Int, limit: Int)
    case tooManyExtendedAttributes(side: LocalMetadataSide, itemName: String, actual: Int, limit: Int)
    case invalidExtendedAttributeName(side: LocalMetadataSide, itemName: String)
    case extendedAttributeValueTooLarge(side: LocalMetadataSide, itemName: String, attributeName: String, actual: Int, limit: Int)
    case extendedAttributeBudgetExceeded(side: LocalMetadataSide, itemName: String, actual: Int, limit: Int)
    case symbolicLinkDestinationTooLarge(side: LocalMetadataSide, itemName: String, actual: Int, limit: Int)
    case accessControlListTooLarge(side: LocalMetadataSide, itemName: String, actual: Int, limit: Int)
    case tooManyAccessControlEntries(side: LocalMetadataSide, itemName: String, actual: Int, limit: Int)
    case resourceChangedDuringRead(side: LocalMetadataSide, itemName: String)
}

extension LocalMetadataComparisonError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .nonFileURL(side):
            "The \(side.rawValue) metadata input is not a local file URL."
        case let .relativePath(side, itemName):
            "The \(side.rawValue) metadata input is not absolute: \(itemName)."
        case let .metadataReadFailed(side, itemName, operation, code):
            "Could not \(operation) \(side.rawValue) item “\(itemName)” (errno \(code): \(Self.posixMessage(code)))."
        case let .extendedAttributeNameListTooLarge(side, itemName, actual, limit):
            "The \(side.rawValue) item “\(itemName)” has an extended-attribute name list of \(actual) bytes; the limit is \(limit)."
        case let .tooManyExtendedAttributes(side, itemName, actual, limit):
            "The \(side.rawValue) item “\(itemName)” has \(actual) extended attributes; the limit is \(limit)."
        case let .invalidExtendedAttributeName(side, itemName):
            "The \(side.rawValue) item “\(itemName)” has a non-UTF-8 extended-attribute name."
        case let .extendedAttributeValueTooLarge(side, itemName, attributeName, actual, limit):
            "Extended attribute “\(attributeName)” on \(side.rawValue) item “\(itemName)” is \(actual) bytes; the per-attribute limit is \(limit)."
        case let .extendedAttributeBudgetExceeded(side, itemName, actual, limit):
            "Extended attributes on \(side.rawValue) item “\(itemName)” total \(actual) bytes; the limit is \(limit)."
        case let .symbolicLinkDestinationTooLarge(side, itemName, actual, limit):
            "The symbolic-link destination on \(side.rawValue) item “\(itemName)” is \(actual) bytes; the limit is \(limit)."
        case let .accessControlListTooLarge(side, itemName, actual, limit):
            "The access-control list on \(side.rawValue) item “\(itemName)” is \(actual) bytes; the limit is \(limit)."
        case let .tooManyAccessControlEntries(side, itemName, actual, limit):
            "The \(side.rawValue) item “\(itemName)” has \(actual) access-control entries; the limit is \(limit)."
        case let .resourceChangedDuringRead(side, itemName):
            "The \(side.rawValue) metadata item “\(itemName)” changed while it was being read."
        }
    }

    private static func posixMessage(_ code: Int32) -> String {
        guard let message = strerror(code) else { return "unknown error" }
        return String(cString: message)
    }
}

public struct LocalMetadataComparisonEngine: Sendable {
    public let limits: LocalMetadataReadLimits

    public init(limits: LocalMetadataReadLimits = .init()) {
        self.limits = limits
    }

    public func compare(
        leftURL: URL,
        rightURL: URL,
        options: MetadataComparisonOptions = .init()
    ) throws -> LocalMetadataComparisonResult {
        let left = try snapshot(url: leftURL, side: .left)
        let right = try snapshot(url: rightURL, side: .right)
        return LocalMetadataComparisonResult(
            left: left,
            right: right,
            comparison: MetadataComparison().compare(
                left: left.fields,
                right: right.fields,
                options: options
            )
        )
    }

    public func snapshot(
        url: URL,
        side: LocalMetadataSide
    ) throws -> LocalMetadataSnapshot {
        guard url.isFileURL else {
            throw LocalMetadataComparisonError.nonFileURL(side: side)
        }
        let standardized = url.standardizedFileURL
        let itemName = standardized.lastPathComponent.isEmpty
            ? standardized.path
            : standardized.lastPathComponent
        guard standardized.path.hasPrefix("/") else {
            throw LocalMetadataComparisonError.relativePath(side: side, itemName: itemName)
        }

        let descriptor = standardized.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_EVTONLY | O_CLOEXEC | O_SYMLINK)
        }
        guard descriptor >= 0 else {
            let code = errno
            throw readFailure(side: side, itemName: itemName, operation: "open metadata for", code: code)
        }
        defer { Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw readFailure(side: side, itemName: itemName, operation: "read metadata for")
        }

        let type = Self.itemType(mode: information.st_mode)
        let linkDestination: String?
        if type == .symbolicLink {
            linkDestination = try readSymbolicLink(
                at: standardized,
                side: side,
                itemName: itemName,
                sizeHint: Int(information.st_size)
            )
        } else {
            linkDestination = nil
        }

        let extendedAttributes = try readExtendedAttributes(
            descriptor: descriptor,
            side: side,
            itemName: itemName
        )
        let accessControlList = try readAccessControlList(
            descriptor: descriptor,
            side: side,
            itemName: itemName
        )

        var finalDescriptorInformation = stat()
        guard Darwin.fstat(descriptor, &finalDescriptorInformation) == 0,
              Self.hasStableMetadataIdentity(information, finalDescriptorInformation) else {
            throw LocalMetadataComparisonError.resourceChangedDuringRead(
                side: side,
                itemName: itemName
            )
        }
        var finalPathInformation = stat()
        let finalPathStatResult = standardized.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &finalPathInformation)
        }
        guard finalPathStatResult == 0,
              Self.hasStableMetadataIdentity(information, finalPathInformation) else {
            throw LocalMetadataComparisonError.resourceChangedDuringRead(
                side: side,
                itemName: itemName
            )
        }
        if let linkDestination {
            let finalLinkDestination = try readSymbolicLink(
                at: standardized,
                side: side,
                itemName: itemName,
                sizeHint: Int(information.st_size)
            )
            var reboundPathInformation = stat()
            let reboundResult = standardized.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.lstat(path, &reboundPathInformation)
            }
            guard finalLinkDestination == linkDestination,
                  reboundResult == 0,
                  Self.hasStableMetadataIdentity(information, reboundPathInformation) else {
                throw LocalMetadataComparisonError.resourceChangedDuringRead(
                    side: side,
                    itemName: itemName
                )
            }
        }

        return LocalMetadataSnapshot(
            itemName: itemName,
            itemType: type,
            byteCount: Int64(information.st_size),
            modificationTime: LocalMetadataTimestamp(
                secondsSince1970: Int64(information.st_mtimespec.tv_sec),
                nanoseconds: Int32(information.st_mtimespec.tv_nsec)
            ),
            creationTime: LocalMetadataTimestamp(
                secondsSince1970: Int64(information.st_birthtimespec.tv_sec),
                nanoseconds: Int32(information.st_birthtimespec.tv_nsec)
            ),
            posixPermissions: UInt32(information.st_mode & 0o7777),
            bsdFlags: UInt32(information.st_flags),
            ownerID: UInt32(information.st_uid),
            groupID: UInt32(information.st_gid),
            symbolicLinkDestination: linkDestination,
            extendedAttributes: extendedAttributes,
            accessControlList: accessControlList
        )
    }

    private func readAccessControlList(
        descriptor: Int32,
        side: LocalMetadataSide,
        itemName: String
    ) throws -> LocalMetadataAccessControlList? {
        errno = 0
        let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
        guard let acl else {
            let code = errno
            if code == ENOENT { return nil }
            throw readFailure(
                side: side,
                itemName: itemName,
                operation: "read the access-control list for",
                code: code == 0 ? EIO : code
            )
        }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        guard Darwin.acl_valid(acl) == 0 else {
            throw readFailure(
                side: side,
                itemName: itemName,
                operation: "validate the access-control list for"
            )
        }

        var entryCount = 0
        while true {
            guard entryCount <= Int(Int32.max) else {
                throw LocalMetadataComparisonError.tooManyAccessControlEntries(
                    side: side,
                    itemName: itemName,
                    actual: entryCount,
                    limit: limits.maximumAccessControlEntryCount
                )
            }
            var entry: acl_entry_t?
            errno = 0
            let entryResult = Darwin.acl_get_entry(acl, Int32(entryCount), &entry)
            if entryResult == 0 {
                entryCount += 1
                guard entryCount <= limits.maximumAccessControlEntryCount else {
                    throw LocalMetadataComparisonError.tooManyAccessControlEntries(
                        side: side,
                        itemName: itemName,
                        actual: entryCount,
                        limit: limits.maximumAccessControlEntryCount
                    )
                }
                continue
            }
            if errno == EINVAL { break }
            throw readFailure(
                side: side,
                itemName: itemName,
                operation: "enumerate the access-control list for",
                code: errno == 0 ? EIO : errno
            )
        }

        let externalSize = Darwin.acl_size(acl)
        guard externalSize >= 0 else {
            throw readFailure(
                side: side,
                itemName: itemName,
                operation: "size the access-control list for"
            )
        }
        guard externalSize <= limits.maximumAccessControlListBytes else {
            throw LocalMetadataComparisonError.accessControlListTooLarge(
                side: side,
                itemName: itemName,
                actual: externalSize,
                limit: limits.maximumAccessControlListBytes
            )
        }

        var externalRepresentation = Data(count: externalSize)
        let copiedSize = externalRepresentation.withUnsafeMutableBytes { buffer in
            Darwin.acl_copy_ext(buffer.baseAddress, acl, externalSize)
        }
        guard copiedSize == externalSize else {
            throw readFailure(
                side: side,
                itemName: itemName,
                operation: "copy the access-control list for",
                code: copiedSize < 0 ? errno : EIO
            )
        }
        return LocalMetadataAccessControlList(
            entryCount: entryCount,
            valueSummary: MetadataDataSummary(data: externalRepresentation)
        )
    }

    private func readExtendedAttributes(
        descriptor: Int32,
        side: LocalMetadataSide,
        itemName: String
    ) throws -> [LocalMetadataExtendedAttribute] {
        let requiredSize = Darwin.flistxattr(descriptor, nil, 0, 0)
        guard requiredSize >= 0 else {
            throw readFailure(side: side, itemName: itemName, operation: "list extended attributes for")
        }
        guard requiredSize <= limits.maximumExtendedAttributeNameBytes else {
            throw LocalMetadataComparisonError.extendedAttributeNameListTooLarge(
                side: side,
                itemName: itemName,
                actual: requiredSize,
                limit: limits.maximumExtendedAttributeNameBytes
            )
        }
        guard requiredSize > 0 else { return [] }

        var nameBuffer = [CChar](repeating: 0, count: requiredSize)
        let bytesRead = nameBuffer.withUnsafeMutableBufferPointer { buffer in
            Darwin.flistxattr(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard bytesRead >= 0 else {
            throw readFailure(side: side, itemName: itemName, operation: "list extended attributes for")
        }

        let names = try parseExtendedAttributeNames(
            nameBuffer.prefix(bytesRead),
            side: side,
            itemName: itemName
        ).sorted { left, right in
            left.utf8.lexicographicallyPrecedes(right.utf8)
        }
        guard names.count <= limits.maximumExtendedAttributeCount else {
            throw LocalMetadataComparisonError.tooManyExtendedAttributes(
                side: side,
                itemName: itemName,
                actual: names.count,
                limit: limits.maximumExtendedAttributeCount
            )
        }

        var totalBytes = 0
        var attributes: [LocalMetadataExtendedAttribute] = []
        attributes.reserveCapacity(names.count)
        for name in names {
            let valueSize = try extendedAttributeSize(
                name: name,
                descriptor: descriptor,
                side: side,
                itemName: itemName
            )
            guard valueSize <= limits.maximumExtendedAttributeValueBytes else {
                throw LocalMetadataComparisonError.extendedAttributeValueTooLarge(
                    side: side,
                    itemName: itemName,
                    attributeName: name,
                    actual: valueSize,
                    limit: limits.maximumExtendedAttributeValueBytes
                )
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(valueSize)
            guard !overflow, newTotal <= limits.maximumTotalExtendedAttributeValueBytes else {
                throw LocalMetadataComparisonError.extendedAttributeBudgetExceeded(
                    side: side,
                    itemName: itemName,
                    actual: overflow ? Int.max : newTotal,
                    limit: limits.maximumTotalExtendedAttributeValueBytes
                )
            }
            totalBytes = newTotal

            var value = Data(count: valueSize)
            let actualSize = try value.withUnsafeMutableBytes { bytes -> Int in
                let result = name.withCString { attributeName in
                    Darwin.fgetxattr(
                        descriptor,
                        attributeName,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        0
                    )
                }
                guard result >= 0 else {
                    throw readFailure(
                        side: side,
                        itemName: itemName,
                        operation: "read extended attribute “\(name)” from"
                    )
                }
                return result
            }
            guard actualSize <= valueSize else {
                throw readFailure(
                    side: side,
                    itemName: itemName,
                    operation: "read stable extended attribute “\(name)” from",
                    code: ERANGE
                )
            }
            if actualSize < value.count { value.removeSubrange(actualSize..<value.count) }
            attributes.append(
                LocalMetadataExtendedAttribute(
                    name: name,
                    valueSummary: MetadataDataSummary(data: value)
                )
            )
        }
        return attributes
    }

    private func extendedAttributeSize(
        name: String,
        descriptor: Int32,
        side: LocalMetadataSide,
        itemName: String
    ) throws -> Int {
        let result = name.withCString { attributeName in
            Darwin.fgetxattr(descriptor, attributeName, nil, 0, 0, 0)
        }
        guard result >= 0 else {
            throw readFailure(
                side: side,
                itemName: itemName,
                operation: "size extended attribute “\(name)” on"
            )
        }
        return result
    }

    private func parseExtendedAttributeNames(
        _ bytes: ArraySlice<CChar>,
        side: LocalMetadataSide,
        itemName: String
    ) throws -> [String] {
        var names: [String] = []
        var current: [UInt8] = []
        for byte in bytes {
            if byte == 0 {
                guard !current.isEmpty,
                      let name = String(bytes: current, encoding: .utf8) else {
                    throw LocalMetadataComparisonError.invalidExtendedAttributeName(
                        side: side,
                        itemName: itemName
                    )
                }
                names.append(name)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(UInt8(bitPattern: byte))
            }
        }
        guard current.isEmpty else {
            throw LocalMetadataComparisonError.invalidExtendedAttributeName(
                side: side,
                itemName: itemName
            )
        }
        return names
    }

    private func readSymbolicLink(
        at url: URL,
        side: LocalMetadataSide,
        itemName: String,
        sizeHint: Int
    ) throws -> String {
        let requestedCapacity = max(1, sizeHint + 1)
        guard requestedCapacity <= limits.maximumSymbolicLinkDestinationBytes + 1 else {
            throw LocalMetadataComparisonError.symbolicLinkDestinationTooLarge(
                side: side,
                itemName: itemName,
                actual: max(0, sizeHint),
                limit: limits.maximumSymbolicLinkDestinationBytes
            )
        }
        var bytes = [UInt8](repeating: 0, count: requestedCapacity)
        let count = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return bytes.withUnsafeMutableBytes { buffer in
                Darwin.readlink(path, buffer.baseAddress, buffer.count)
            }
        }
        guard count >= 0 else {
            throw readFailure(side: side, itemName: itemName, operation: "read symbolic link")
        }
        guard count < bytes.count else {
            throw readFailure(
                side: side,
                itemName: itemName,
                operation: "read stable symbolic link",
                code: ERANGE
            )
        }
        guard count <= limits.maximumSymbolicLinkDestinationBytes else {
            throw LocalMetadataComparisonError.symbolicLinkDestinationTooLarge(
                side: side,
                itemName: itemName,
                actual: count,
                limit: limits.maximumSymbolicLinkDestinationBytes
            )
        }
        return String(decoding: bytes.prefix(count), as: UTF8.self)
    }

    private static func itemType(mode: mode_t) -> LocalMetadataItemType {
        switch mode & S_IFMT {
        case S_IFREG: .regularFile
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        case S_IFCHR: .characterDevice
        case S_IFBLK: .blockDevice
        case S_IFIFO: .fifo
        case S_IFSOCK: .socket
        default: .unknown
        }
    }

    private static func hasStableMetadataIdentity(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev
            && left.st_ino == right.st_ino
            && left.st_mode == right.st_mode
            && left.st_nlink == right.st_nlink
            && left.st_uid == right.st_uid
            && left.st_gid == right.st_gid
            && left.st_size == right.st_size
            && left.st_flags == right.st_flags
            && sameTimestamp(left.st_mtimespec, right.st_mtimespec)
            && sameTimestamp(left.st_ctimespec, right.st_ctimespec)
            && sameTimestamp(left.st_birthtimespec, right.st_birthtimespec)
    }

    private static func sameTimestamp(_ left: timespec, _ right: timespec) -> Bool {
        left.tv_sec == right.tv_sec && left.tv_nsec == right.tv_nsec
    }

    private func readFailure(
        side: LocalMetadataSide,
        itemName: String,
        operation: String,
        code: Int32 = errno
    ) -> LocalMetadataComparisonError {
        .metadataReadFailed(
            side: side,
            itemName: itemName,
            operation: operation,
            code: code
        )
    }
}
