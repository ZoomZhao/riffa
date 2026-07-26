import Foundation
import zlib

/// Archive encodings supported by ``ArchiveResourceProvider``.
public enum ArchiveResourceFormat: String, Codable, Sendable {
    case automatic
    case tar
    case zip
}

/// Hard resource limits applied while an archive is indexed and read.
///
/// Limits are checked against values declared by the archive before any allocation or
/// decompression. `maxExpansionRatio` applies to deflated ZIP members and prevents a
/// small compressed payload from expanding without bound.
public struct ArchiveResourceLimits: Hashable, Codable, Sendable {
    public var maxArchiveByteCount: Int
    public var maxEntryCount: Int
    public var maxEntryUncompressedByteCount: Int
    public var maxTotalUncompressedByteCount: Int
    public var maxExpansionRatio: Double
    public var maxPathByteCount: Int
    public var maxPathDepth: Int

    public init(
        maxArchiveByteCount: Int = 512 * 1_024 * 1_024,
        maxEntryCount: Int = 100_000,
        maxEntryUncompressedByteCount: Int = 256 * 1_024 * 1_024,
        maxTotalUncompressedByteCount: Int = 1_024 * 1_024 * 1_024,
        maxExpansionRatio: Double = 200,
        maxPathByteCount: Int = 4_096,
        maxPathDepth: Int = 256
    ) {
        self.maxArchiveByteCount = maxArchiveByteCount
        self.maxEntryCount = maxEntryCount
        self.maxEntryUncompressedByteCount = maxEntryUncompressedByteCount
        self.maxTotalUncompressedByteCount = maxTotalUncompressedByteCount
        self.maxExpansionRatio = maxExpansionRatio
        self.maxPathByteCount = maxPathByteCount
        self.maxPathDepth = maxPathDepth
    }

    public static let `default` = Self()
}

/// One safe, normalized path exposed by an archive.
public struct ArchiveResourceEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file
        case directory
        case symbolicLink
    }

    public enum Compression: String, Codable, Sendable {
        case none
        case deflate
    }

    public var id: String { path }

    /// A relative, slash-separated, NFC-normalized path without `.` or `..` components.
    public let path: String
    public let kind: Kind
    public let uncompressedByteCount: Int
    public let compressedByteCount: Int
    public let compression: Compression
    public let modificationDate: Date?
    public let permissions: UInt16?
    public let symbolicLinkDestination: String?

    public init(
        path: String,
        kind: Kind,
        uncompressedByteCount: Int,
        compressedByteCount: Int,
        compression: Compression,
        modificationDate: Date? = nil,
        permissions: UInt16? = nil,
        symbolicLinkDestination: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.uncompressedByteCount = uncompressedByteCount
        self.compressedByteCount = compressedByteCount
        self.compression = compression
        self.modificationDate = modificationDate
        self.permissions = permissions
        self.symbolicLinkDestination = symbolicLinkDestination
    }
}

/// A stable error returned for malformed, unsafe, or unsupported archive input.
public struct ArchiveResourceError: Error, Hashable, Codable, Sendable, LocalizedError {
    public enum Code: String, Codable, Sendable {
        case unsupportedFormat
        case malformedArchive
        case truncatedArchive
        case invalidEncoding
        case invalidPath
        case duplicatePath
        case pathLimitExceeded
        case entryLimitExceeded
        case entrySizeLimitExceeded
        case totalSizeLimitExceeded
        case archiveSizeLimitExceeded
        case expansionRatioLimitExceeded
        case unsupportedEntryType
        case unsupportedCompression
        case unsupportedZIP64
        case encryptedEntry
        case multiDiskZIP
        case checksumMismatch
        case notFound
        case notRegularFile
        case symbolicLinkReadDenied
        case decompressionFailed
    }

    public let code: Code
    public let path: String?
    public let message: String

    public init(code: Code, path: String? = nil, message: String) {
        self.code = code
        self.path = path
        self.message = message
    }

    public var errorDescription: String? {
        if let path {
            return "\(path): \(message)"
        }
        return message
    }
}

/// A read-only, in-memory virtual resource provider for TAR and ZIP archives.
///
/// The provider never writes archive contents to disk and never follows symbolic links.
/// Paths are validated and normalized before becoming visible. ZIP CRC-32 is verified
/// whenever a regular file is read.
public struct ArchiveResourceProvider: Sendable {
    public static let providerID = "archive"

    public let format: ArchiveResourceFormat
    public let limits: ArchiveResourceLimits
    public let capabilities: ResourceCapabilities = [
        .enumerate,
        .recursiveEnumeration,
        .read,
        .readMetadata,
        .symbolicLinks,
    ]

    private let archiveData: Data
    private let records: [String: StoredArchiveRecord]
    private let orderedEntries: [ArchiveResourceEntry]

    public init(
        data: Data,
        format requestedFormat: ArchiveResourceFormat = .automatic,
        limits: ArchiveResourceLimits = .default
    ) throws {
        guard data.count <= limits.maxArchiveByteCount else {
            throw ArchiveResourceError(
                code: .archiveSizeLimitExceeded,
                message: "Archive contains \(data.count) bytes; the limit is \(limits.maxArchiveByteCount)"
            )
        }

        let detectedFormat: ArchiveResourceFormat
        switch requestedFormat {
        case .automatic:
            detectedFormat = try Self.detectFormat(in: data)
        case .tar, .zip:
            detectedFormat = requestedFormat
        }

        var builder = ArchiveIndexBuilder(data: data, limits: limits)
        switch detectedFormat {
        case .tar:
            try builder.parseTAR()
        case .zip:
            try builder.parseZIP()
        case .automatic:
            preconditionFailure("Automatic archive format must be resolved before parsing")
        }

        self.format = detectedFormat
        self.limits = limits
        archiveData = data
        records = builder.records
        orderedEntries = builder.records.values
            .map(\.entry)
            .sorted { $0.path < $1.path }
    }

    /// Lists all explicit and synthesized directory entries, excluding the virtual root.
    public func list() -> [ArchiveResourceEntry] {
        orderedEntries
    }

    /// Returns metadata for a normalized relative path.
    public func stat(_ path: String) throws -> ArchiveResourceEntry {
        let normalized = try ArchivePath.normalize(path, limits: limits)
        guard let record = records[normalized] else {
            throw ArchiveResourceError(code: .notFound, path: normalized, message: "Archive entry was not found")
        }
        return record.entry
    }

    /// Reads a regular file into memory. Directories and symbolic links are never followed.
    public func read(_ path: String) throws -> Data {
        let normalized = try ArchivePath.normalize(path, limits: limits)
        guard let record = records[normalized] else {
            throw ArchiveResourceError(code: .notFound, path: normalized, message: "Archive entry was not found")
        }

        switch record.entry.kind {
        case .directory:
            throw ArchiveResourceError(code: .notRegularFile, path: normalized, message: "Directories cannot be read as data")
        case .symbolicLink:
            throw ArchiveResourceError(
                code: .symbolicLinkReadDenied,
                path: normalized,
                message: "Symbolic links are metadata only and are never followed"
            )
        case .file:
            break
        }

        guard let payload = record.payload else {
            throw ArchiveResourceError(code: .malformedArchive, path: normalized, message: "File payload is missing")
        }

        let result: Data
        switch payload {
        case let .stored(range):
            result = archiveData.subdata(in: range)
        case let .deflated(range):
            let compressed = archiveData.subdata(in: range)
            result = try Self.inflateRawDeflate(
                compressed,
                expectedByteCount: record.entry.uncompressedByteCount,
                path: normalized
            )
        }

        guard result.count == record.entry.uncompressedByteCount else {
            throw ArchiveResourceError(
                code: .decompressionFailed,
                path: normalized,
                message: "Decoded \(result.count) bytes; expected \(record.entry.uncompressedByteCount)"
            )
        }

        if let expectedCRC32 = record.crc32 {
            let actualCRC32 = ArchiveCRC32.checksum(result)
            guard actualCRC32 == expectedCRC32 else {
                throw ArchiveResourceError(
                    code: .checksumMismatch,
                    path: normalized,
                    message: String(
                        format: "CRC-32 mismatch (expected %08x, got %08x)",
                        expectedCRC32,
                        actualCRC32
                    )
                )
            }
        }
        return result
    }

    private static func detectFormat(in data: Data) throws -> ArchiveResourceFormat {
        if data.count >= 4 {
            let signature = data.uint32LEUnchecked(at: 0)
            if signature == ZIPSignature.localFile
                || signature == ZIPSignature.endOfCentralDirectory
                || signature == ZIPSignature.centralDirectory
            {
                return .zip
            }
        }

        if data.count >= 512,
           String(bytes: data[257..<262], encoding: .ascii) == "ustar"
        {
            return .tar
        }

        throw ArchiveResourceError(code: .unsupportedFormat, message: "Data is neither a supported USTAR/PAX archive nor a ZIP archive")
    }

    private static func inflateRawDeflate(
        _ compressed: Data,
        expectedByteCount: Int,
        path: String
    ) throws -> Data {
        guard compressed.count <= Int(UInt32.max), expectedByteCount <= Int(UInt32.max) else {
            throw ArchiveResourceError(
                code: .entrySizeLimitExceeded,
                path: path,
                message: "This build cannot decode one ZIP member larger than 4 GiB"
            )
        }

        var stream = z_stream()
        let initialization = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialization == Z_OK else {
            throw ArchiveResourceError(code: .decompressionFailed, path: path, message: "Unable to initialize the DEFLATE decoder")
        }
        defer { inflateEnd(&stream) }

        let outputCapacity = max(expectedByteCount, 1)
        var output = Data(count: outputCapacity)
        let status: Int32 = compressed.withUnsafeBytes { sourceBytes in
            output.withUnsafeMutableBytes { destinationBytes in
                stream.next_in = UnsafeMutablePointer(
                    mutating: sourceBytes.baseAddress?.assumingMemoryBound(to: Bytef.self)
                )
                stream.avail_in = uInt(compressed.count)
                stream.next_out = destinationBytes.baseAddress?.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(outputCapacity)
                return inflate(&stream, Z_FINISH)
            }
        }

        guard status == Z_STREAM_END,
              stream.avail_in == 0,
              Int(stream.total_out) == expectedByteCount
        else {
            throw ArchiveResourceError(
                code: .decompressionFailed,
                path: path,
                message: "Invalid or truncated raw DEFLATE stream"
            )
        }
        output.count = expectedByteCount
        return output
    }
}

private struct StoredArchiveRecord: Sendable {
    let entry: ArchiveResourceEntry
    let payload: ArchivePayload?
    let crc32: UInt32?
    let isExplicit: Bool
}

private enum ArchivePayload: Sendable {
    case stored(Range<Int>)
    case deflated(Range<Int>)
}

private enum ZIPSignature {
    static let localFile: UInt32 = 0x0403_4b50
    static let centralDirectory: UInt32 = 0x0201_4b50
    static let endOfCentralDirectory: UInt32 = 0x0605_4b50
}

private enum ArchivePath {
    static func isVirtualRoot(_ untrustedPath: String) -> Bool {
        let slashPath = untrustedPath.replacingOccurrences(of: "\\", with: "/")
        guard !slashPath.hasPrefix("/") else { return false }
        return slashPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { $0.isEmpty || $0 == "." }
    }

    static func normalize(_ untrustedPath: String, limits: ArchiveResourceLimits) throws -> String {
        guard !untrustedPath.isEmpty else {
            throw ArchiveResourceError(code: .invalidPath, path: untrustedPath, message: "Archive paths cannot be empty")
        }
        guard !untrustedPath.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ArchiveResourceError(code: .invalidPath, path: untrustedPath, message: "Archive path contains NUL")
        }

        // Treat backslashes as separators too. This avoids archives that are safe on Unix
        // but become traversal paths when consumed by another platform or API.
        let slashPath = untrustedPath.replacingOccurrences(of: "\\", with: "/")
        guard !slashPath.hasPrefix("/") else {
            throw ArchiveResourceError(code: .invalidPath, path: untrustedPath, message: "Absolute archive paths are forbidden")
        }

        let rawComponents = slashPath.split(separator: "/", omittingEmptySubsequences: false)
        var components: [String] = []
        components.reserveCapacity(rawComponents.count)
        for rawComponent in rawComponents {
            let component = String(rawComponent)
            if component.isEmpty || component == "." {
                continue
            }
            guard component != ".." else {
                throw ArchiveResourceError(code: .invalidPath, path: untrustedPath, message: "Parent traversal components are forbidden")
            }
            if components.isEmpty,
               component.count >= 2,
               component[component.index(after: component.startIndex)] == ":",
               component.first?.isASCII == true,
               component.first?.isLetter == true
            {
                throw ArchiveResourceError(code: .invalidPath, path: untrustedPath, message: "Drive-qualified archive paths are forbidden")
            }
            components.append(component.precomposedStringWithCanonicalMapping)
        }

        guard !components.isEmpty else {
            throw ArchiveResourceError(code: .invalidPath, path: untrustedPath, message: "Archive path resolves to the virtual root")
        }
        guard components.count <= limits.maxPathDepth else {
            throw ArchiveResourceError(code: .pathLimitExceeded, path: untrustedPath, message: "Archive path exceeds the component-depth limit")
        }

        let normalized = components.joined(separator: "/")
        guard normalized.utf8.count <= limits.maxPathByteCount else {
            throw ArchiveResourceError(code: .pathLimitExceeded, path: untrustedPath, message: "Archive path exceeds the byte-length limit")
        }
        return normalized
    }
}

private struct ArchiveIndexBuilder {
    let data: Data
    let limits: ArchiveResourceLimits
    var records: [String: StoredArchiveRecord] = [:]
    private var explicitPaths: Set<String> = []
    private var totalUncompressedByteCount = 0

    init(data: Data, limits: ArchiveResourceLimits) {
        self.data = data
        self.limits = limits
    }

    mutating func parseTAR() throws {
        var offset = 0
        var foundEndMarker = false
        var pendingPAX: [String: String] = [:]

        while offset < data.count {
            guard let headerRange = checkedRange(start: offset, count: 512, upperBound: data.count) else {
                throw error(.truncatedArchive, message: "TAR header is truncated")
            }
            let header = data[headerRange]
            if header.allSatisfy({ $0 == 0 }) {
                foundEndMarker = true
                let trailingStart = offset + 512
                if trailingStart < data.count, data[trailingStart...].contains(where: { $0 != 0 }) {
                    throw error(.malformedArchive, message: "Non-zero data appears after the TAR end marker")
                }
                break
            }

            try validateTARHeader(header, archiveOffset: offset)
            let typeFlag = header[header.index(header.startIndex, offsetBy: 156)]
            let headerSize = try tarNumber(header, offset: 124, length: 12, field: "size")
            let effectiveSize: Int
            if typeFlag != 0x78, let paxSize = pendingPAX["size"] {
                effectiveSize = try decimalInt(paxSize, field: "PAX size")
            } else {
                effectiveSize = headerSize
            }
            try enforceEntrySize(effectiveSize, path: nil)

            let payloadStart = try checkedAdd(offset, 512)
            guard let payloadRange = checkedRange(start: payloadStart, count: effectiveSize, upperBound: data.count) else {
                throw error(.truncatedArchive, message: "TAR payload is truncated")
            }
            let paddedSize = try roundedUpToTARBlock(effectiveSize)
            let nextOffset = try checkedAdd(payloadStart, paddedSize)
            guard nextOffset <= data.count else {
                throw error(.truncatedArchive, message: "TAR payload padding is truncated")
            }

            if typeFlag == 0x78 { // POSIX PAX extended header for the following entry.
                let values = try parsePAX(data[payloadRange])
                pendingPAX.merge(values) { _, new in new }
                offset = nextOffset
                continue
            }

            let headerName = try tarPath(header)
            let untrustedPath = pendingPAX["path"] ?? headerName
            if typeFlag == 0x35, ArchivePath.isVirtualRoot(untrustedPath) {
                pendingPAX.removeAll(keepingCapacity: true)
                offset = nextOffset
                continue
            }
            let path = try ArchivePath.normalize(untrustedPath, limits: limits)
            let mode = UInt16(clamping: try tarNumber(header, offset: 100, length: 8, field: "mode"))
            let modificationDate: Date?
            if let paxModification = pendingPAX["mtime"], let seconds = Double(paxModification) {
                modificationDate = Date(timeIntervalSince1970: seconds)
            } else {
                let seconds = try tarNumber(header, offset: 136, length: 12, field: "mtime")
                modificationDate = Date(timeIntervalSince1970: TimeInterval(seconds))
            }

            switch typeFlag {
            case 0, 0x30: // NUL or "0"
                try addExplicit(
                    ArchiveResourceEntry(
                        path: path,
                        kind: .file,
                        uncompressedByteCount: effectiveSize,
                        compressedByteCount: effectiveSize,
                        compression: .none,
                        modificationDate: modificationDate,
                        permissions: mode
                    ),
                    payload: .stored(payloadRange),
                    crc32: nil
                )

            case 0x35: // "5"
                try addExplicit(
                    ArchiveResourceEntry(
                        path: path,
                        kind: .directory,
                        uncompressedByteCount: 0,
                        compressedByteCount: 0,
                        compression: .none,
                        modificationDate: modificationDate,
                        permissions: mode
                    ),
                    payload: nil,
                    crc32: nil
                )

            case 0x32: // "2"
                let headerDestination = try tarString(header, offset: 157, length: 100, field: "link name")
                try addExplicit(
                    ArchiveResourceEntry(
                        path: path,
                        kind: .symbolicLink,
                        uncompressedByteCount: 0,
                        compressedByteCount: 0,
                        compression: .none,
                        modificationDate: modificationDate,
                        permissions: mode,
                        symbolicLinkDestination: pendingPAX["linkpath"] ?? headerDestination
                    ),
                    payload: nil,
                    crc32: nil
                )

            default:
                throw error(
                    .unsupportedEntryType,
                    path: path,
                    message: String(format: "Unsupported TAR type flag 0x%02x", typeFlag)
                )
            }

            pendingPAX.removeAll(keepingCapacity: true)
            offset = nextOffset
        }

        guard foundEndMarker else {
            throw error(.truncatedArchive, message: "TAR archive has no end marker")
        }
        guard pendingPAX.isEmpty else {
            throw error(.malformedArchive, message: "PAX metadata is not followed by an archive entry")
        }
    }

    mutating func parseZIP() throws {
        let eocdOffset = try findEndOfCentralDirectory()
        guard let eocdRange = checkedRange(start: eocdOffset, count: 22, upperBound: data.count) else {
            throw error(.truncatedArchive, message: "ZIP end-of-central-directory record is truncated")
        }
        let eocd = data[eocdRange]
        let diskNumber = eocd.uint16LEUnchecked(atRelative: 4)
        let centralDirectoryDisk = eocd.uint16LEUnchecked(atRelative: 6)
        let entriesOnDisk = eocd.uint16LEUnchecked(atRelative: 8)
        let entryCount = eocd.uint16LEUnchecked(atRelative: 10)
        let centralDirectorySize32 = eocd.uint32LEUnchecked(atRelative: 12)
        let centralDirectoryOffset32 = eocd.uint32LEUnchecked(atRelative: 16)

        if diskNumber != 0 || centralDirectoryDisk != 0 || entriesOnDisk != entryCount {
            throw error(.multiDiskZIP, message: "Multi-disk ZIP archives are not supported")
        }
        if entryCount == UInt16.max
            || centralDirectorySize32 == UInt32.max
            || centralDirectoryOffset32 == UInt32.max
        {
            throw error(.unsupportedZIP64, message: "ZIP64 archives are not supported")
        }
        guard Int(entryCount) <= limits.maxEntryCount else {
            throw error(.entryLimitExceeded, message: "ZIP declares more entries than the configured limit")
        }

        let centralDirectoryOffset = Int(centralDirectoryOffset32)
        let centralDirectorySize = Int(centralDirectorySize32)
        guard let centralDirectoryRange = checkedRange(
            start: centralDirectoryOffset,
            count: centralDirectorySize,
            upperBound: eocdOffset
        ) else {
            throw error(.truncatedArchive, message: "ZIP central directory lies outside the archive")
        }

        var cursor = centralDirectoryRange.lowerBound
        for _ in 0..<Int(entryCount) {
            guard let fixedRange = checkedRange(start: cursor, count: 46, upperBound: centralDirectoryRange.upperBound) else {
                throw error(.truncatedArchive, message: "ZIP central-directory entry is truncated")
            }
            let fixed = data[fixedRange]
            guard fixed.uint32LEUnchecked(atRelative: 0) == ZIPSignature.centralDirectory else {
                throw error(.malformedArchive, message: "ZIP central-directory signature is invalid")
            }

            let versionMadeBy = fixed.uint16LEUnchecked(atRelative: 4)
            let flags = fixed.uint16LEUnchecked(atRelative: 8)
            let method = fixed.uint16LEUnchecked(atRelative: 10)
            let dosTime = fixed.uint16LEUnchecked(atRelative: 12)
            let dosDate = fixed.uint16LEUnchecked(atRelative: 14)
            let expectedCRC32 = fixed.uint32LEUnchecked(atRelative: 16)
            let compressedSize32 = fixed.uint32LEUnchecked(atRelative: 20)
            let uncompressedSize32 = fixed.uint32LEUnchecked(atRelative: 24)
            let nameLength = Int(fixed.uint16LEUnchecked(atRelative: 28))
            let extraLength = Int(fixed.uint16LEUnchecked(atRelative: 30))
            let commentLength = Int(fixed.uint16LEUnchecked(atRelative: 32))
            let startDisk = fixed.uint16LEUnchecked(atRelative: 34)
            let externalAttributes = fixed.uint32LEUnchecked(atRelative: 38)
            let localHeaderOffset32 = fixed.uint32LEUnchecked(atRelative: 42)

            if compressedSize32 == UInt32.max
                || uncompressedSize32 == UInt32.max
                || localHeaderOffset32 == UInt32.max
            {
                throw error(.unsupportedZIP64, message: "ZIP64 member metadata is not supported")
            }
            guard startDisk == 0 else {
                throw error(.multiDiskZIP, message: "ZIP member starts on another disk")
            }
            try validateZIPFlags(flags, path: nil)
            guard method == 0 || method == 8 else {
                throw error(.unsupportedCompression, message: "ZIP compression method \(method) is not supported")
            }

            let variableStart = cursor + 46
            guard let nameRange = checkedRange(start: variableStart, count: nameLength, upperBound: centralDirectoryRange.upperBound),
                  let extraRange = checkedRange(start: nameRange.upperBound, count: extraLength, upperBound: centralDirectoryRange.upperBound),
                  let wholeRange = checkedRange(start: extraRange.upperBound, count: commentLength, upperBound: centralDirectoryRange.upperBound)
            else {
                throw error(.truncatedArchive, message: "ZIP central-directory variable fields are truncated")
            }
            let rawName = data[nameRange]
            let extra = data[extraRange]
            let extraFields = try parseZIPExtraFields(extra)
            if extraFields[0x0001] != nil {
                throw error(.unsupportedZIP64, message: "ZIP64 extra fields are not supported")
            }

            let decodedName = try decodeZIPName(rawName, flags: flags, extraFields: extraFields)
            let path = try ArchivePath.normalize(decodedName, limits: limits)
            let compressedSize = Int(compressedSize32)
            let uncompressedSize = Int(uncompressedSize32)
            try enforceEntrySize(uncompressedSize, path: path)
            try enforceExpansionRatio(
                compressedByteCount: compressedSize,
                uncompressedByteCount: uncompressedSize,
                method: method,
                path: path
            )

            let payloadRange = try zipPayloadRange(
                localHeaderOffset: Int(localHeaderOffset32),
                centralName: rawName,
                centralFlags: flags,
                centralMethod: method,
                centralCRC32: expectedCRC32,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                upperBound: centralDirectoryOffset
            )

            let unixMode = UInt16((externalAttributes >> 16) & 0xffff)
            let madeByUnix = (versionMadeBy >> 8) == 3
            let unixFileType = unixMode & 0xf000
            let kind: ArchiveResourceEntry.Kind
            if decodedName.hasSuffix("/") || (madeByUnix && unixFileType == 0x4000) {
                kind = .directory
            } else if madeByUnix && unixFileType == 0xa000 {
                kind = .symbolicLink
            } else {
                kind = .file
            }
            if kind == .directory, uncompressedSize != 0 {
                throw error(.malformedArchive, path: path, message: "ZIP directory has a non-empty payload")
            }

            let compression: ArchiveResourceEntry.Compression = method == 0 ? .none : .deflate
            let payload: ArchivePayload? = kind == .directory
                ? nil
                : (method == 0 ? .stored(payloadRange) : .deflated(payloadRange))
            try addExplicit(
                ArchiveResourceEntry(
                    path: path,
                    kind: kind,
                    uncompressedByteCount: kind == .directory ? 0 : uncompressedSize,
                    compressedByteCount: kind == .directory ? 0 : compressedSize,
                    compression: compression,
                    modificationDate: zipDate(time: dosTime, date: dosDate),
                    permissions: madeByUnix ? unixMode & 0o7777 : nil,
                    symbolicLinkDestination: nil
                ),
                payload: payload,
                crc32: kind == .directory ? nil : expectedCRC32
            )
            cursor = wholeRange.upperBound
        }

        guard cursor == centralDirectoryRange.upperBound else {
            throw error(.malformedArchive, message: "ZIP central-directory size does not match its entries")
        }
    }

    private mutating func addExplicit(
        _ entry: ArchiveResourceEntry,
        payload: ArchivePayload?,
        crc32: UInt32?
    ) throws {
        guard !explicitPaths.contains(entry.path) else {
            throw error(.duplicatePath, path: entry.path, message: "Archive contains duplicate normalized paths")
        }

        let components = entry.path.split(separator: "/")
        if components.count > 1 {
            for end in 1..<components.count {
                let parent = components.prefix(end).joined(separator: "/")
                if let existing = records[parent] {
                    guard existing.entry.kind == .directory else {
                        throw error(.invalidPath, path: entry.path, message: "An archive child is nested below a non-directory entry")
                    }
                } else {
                    try addSynthesizedDirectory(parent)
                }
            }
        }

        if let existing = records[entry.path] {
            // An explicit directory may replace an earlier synthesized parent.
            guard !existing.isExplicit, existing.entry.kind == .directory, entry.kind == .directory else {
                throw error(.duplicatePath, path: entry.path, message: "Archive path conflicts with another entry")
            }
        }

        if entry.kind != .directory {
            let nextTotal = try checkedAdd(totalUncompressedByteCount, entry.uncompressedByteCount)
            guard nextTotal <= limits.maxTotalUncompressedByteCount else {
                throw error(.totalSizeLimitExceeded, path: entry.path, message: "Archive exceeds the total uncompressed-size limit")
            }
            totalUncompressedByteCount = nextTotal
        }

        explicitPaths.insert(entry.path)
        records[entry.path] = StoredArchiveRecord(entry: entry, payload: payload, crc32: crc32, isExplicit: true)
        try enforceRecordCount()
    }

    private mutating func addSynthesizedDirectory(_ path: String) throws {
        let entry = ArchiveResourceEntry(
            path: path,
            kind: .directory,
            uncompressedByteCount: 0,
            compressedByteCount: 0,
            compression: .none
        )
        records[path] = StoredArchiveRecord(entry: entry, payload: nil, crc32: nil, isExplicit: false)
        try enforceRecordCount()
    }

    private func enforceRecordCount() throws {
        guard records.count <= limits.maxEntryCount else {
            throw error(.entryLimitExceeded, message: "Archive exceeds the entry limit, including virtual parent directories")
        }
    }

    private func enforceEntrySize(_ size: Int, path: String?) throws {
        guard size >= 0, size <= limits.maxEntryUncompressedByteCount else {
            throw error(.entrySizeLimitExceeded, path: path, message: "Archive member exceeds the uncompressed-size limit")
        }
    }

    private func enforceExpansionRatio(
        compressedByteCount: Int,
        uncompressedByteCount: Int,
        method: UInt16,
        path: String
    ) throws {
        if method == 0 {
            guard compressedByteCount == uncompressedByteCount else {
                throw error(.malformedArchive, path: path, message: "Stored ZIP member sizes do not match")
            }
            return
        }
        guard uncompressedByteCount == 0 || compressedByteCount > 0 else {
            throw error(.expansionRatioLimitExceeded, path: path, message: "Non-empty ZIP member has no compressed data")
        }
        if uncompressedByteCount > 0 {
            let ratio = Double(uncompressedByteCount) / Double(compressedByteCount)
            guard ratio <= limits.maxExpansionRatio else {
                throw error(
                    .expansionRatioLimitExceeded,
                    path: path,
                    message: "ZIP member expansion ratio \(ratio) exceeds the configured limit"
                )
            }
        }
    }

    private func validateTARHeader(_ header: Data.SubSequence, archiveOffset: Int) throws {
        guard String(bytes: header.dropFirst(257).prefix(5), encoding: .ascii) == "ustar" else {
            throw error(.unsupportedFormat, message: "TAR header at \(archiveOffset) is not USTAR/PAX")
        }
        let expected = try tarNumber(header, offset: 148, length: 8, field: "checksum")
        var actual = 0
        for index in 0..<512 {
            actual += (148..<156).contains(index) ? 0x20 : Int(header[header.index(header.startIndex, offsetBy: index)])
        }
        guard actual == expected else {
            throw error(.checksumMismatch, message: "TAR header checksum is invalid at byte \(archiveOffset)")
        }
    }

    private func tarNumber(
        _ header: Data.SubSequence,
        offset: Int,
        length: Int,
        field: String
    ) throws -> Int {
        let bytes = header.dropFirst(offset).prefix(length)
        guard bytes.count == length else {
            throw error(.truncatedArchive, message: "TAR \(field) field is truncated")
        }
        if let first = bytes.first, first & 0x80 != 0 {
            throw error(.unsupportedFormat, message: "Base-256 TAR \(field) values are not supported")
        }
        let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 0 }
        guard text.allSatisfy({ ("0"..."7").contains($0) }),
              let value = Int(text, radix: 8)
        else {
            throw error(.malformedArchive, message: "TAR \(field) is not a valid octal number")
        }
        return value
    }

    private func tarPath(_ header: Data.SubSequence) throws -> String {
        let name = try tarString(header, offset: 0, length: 100, field: "name")
        let prefix = try tarString(header, offset: 345, length: 155, field: "prefix")
        return prefix.isEmpty ? name : prefix + "/" + name
    }

    private func tarString(
        _ header: Data.SubSequence,
        offset: Int,
        length: Int,
        field: String
    ) throws -> String {
        let bytes = header.dropFirst(offset).prefix(length)
        guard bytes.count == length else {
            throw error(.truncatedArchive, message: "TAR \(field) field is truncated")
        }
        let content = Data(bytes.prefix { $0 != 0 })
        guard let result = String(data: content, encoding: .utf8) else {
            throw error(.invalidEncoding, message: "TAR \(field) is not valid UTF-8")
        }
        return result
    }

    private func parsePAX(_ bytes: Data.SubSequence) throws -> [String: String] {
        var result: [String: String] = [:]
        var cursor = 0
        let payload = Data(bytes)
        while cursor < payload.count {
            guard let space = payload[cursor...].firstIndex(of: 0x20) else {
                throw error(.malformedArchive, message: "PAX record has no length delimiter")
            }
            guard let lengthText = String(data: payload[cursor..<space], encoding: .ascii),
                  let recordLength = Int(lengthText),
                  recordLength > 0,
                  let end = optionalCheckedAdd(cursor, recordLength),
                  end <= payload.count
            else {
                throw error(.malformedArchive, message: "PAX record length is invalid")
            }
            let record = payload[cursor..<end]
            guard record.last == 0x0a else {
                throw error(.malformedArchive, message: "PAX record is not newline terminated")
            }
            let valueStart = space + 1
            guard valueStart < end - 1,
                  let equals = payload[valueStart..<(end - 1)].firstIndex(of: 0x3d)
            else {
                throw error(.malformedArchive, message: "PAX record has no key/value delimiter")
            }
            guard let key = String(data: payload[valueStart..<equals], encoding: .utf8), !key.isEmpty else {
                throw error(.invalidEncoding, message: "PAX key is not valid UTF-8")
            }

            // libarchive/bsdtar can store opaque extended-attribute payloads under
            // SCHILY.xattr.* and LIBARCHIVE.xattr.* keys. They do not affect virtual
            // resource addressing, so leave them as raw bytes and ignore them. Only
            // fields used by this parser must be valid UTF-8.
            if key == "path" || key == "linkpath" || key == "size" || key == "mtime" {
                guard let value = String(
                    data: payload[(equals + 1)..<(end - 1)],
                    encoding: .utf8
                ) else {
                    throw error(.invalidEncoding, message: "PAX \(key) value is not valid UTF-8")
                }
                result[key] = value
            }
            cursor = end
        }
        return result
    }

    private func decimalInt(_ text: String, field: String) throws -> Int {
        guard !text.isEmpty,
              text.allSatisfy(\.isNumber),
              let result = Int(text)
        else {
            throw error(.malformedArchive, message: "\(field) is not a non-negative decimal integer")
        }
        return result
    }

    private func roundedUpToTARBlock(_ value: Int) throws -> Int {
        let withPadding = try checkedAdd(value, 511)
        return (withPadding / 512) * 512
    }

    private func findEndOfCentralDirectory() throws -> Int {
        guard data.count >= 22 else {
            throw error(.truncatedArchive, message: "ZIP end-of-central-directory record is missing")
        }
        let lowestCandidate = max(0, data.count - 22 - Int(UInt16.max))
        for candidate in stride(from: data.count - 22, through: lowestCandidate, by: -1) {
            guard data.uint32LEUnchecked(at: candidate) == ZIPSignature.endOfCentralDirectory else { continue }
            let commentLength = Int(data.uint16LEUnchecked(at: candidate + 20))
            if candidate + 22 + commentLength == data.count {
                return candidate
            }
        }
        throw error(.truncatedArchive, message: "Valid ZIP end-of-central-directory record was not found")
    }

    private func validateZIPFlags(_ flags: UInt16, path: String?) throws {
        if flags & 0x0001 != 0 || flags & 0x0040 != 0 {
            throw error(.encryptedEntry, path: path, message: "Encrypted ZIP members are not supported")
        }
    }

    private func parseZIPExtraFields(_ extra: Data.SubSequence) throws -> [UInt16: Data] {
        let bytes = Data(extra)
        var result: [UInt16: Data] = [:]
        var cursor = 0
        while cursor < bytes.count {
            guard cursor + 4 <= bytes.count else {
                throw error(.truncatedArchive, message: "ZIP extra-field header is truncated")
            }
            let identifier = bytes.uint16LEUnchecked(at: cursor)
            let length = Int(bytes.uint16LEUnchecked(at: cursor + 2))
            guard let valueRange = checkedRange(start: cursor + 4, count: length, upperBound: bytes.count) else {
                throw error(.truncatedArchive, message: "ZIP extra-field payload is truncated")
            }
            result[identifier] = bytes.subdata(in: valueRange)
            cursor = valueRange.upperBound
        }
        return result
    }

    private func decodeZIPName(
        _ rawName: Data.SubSequence,
        flags: UInt16,
        extraFields: [UInt16: Data]
    ) throws -> String {
        let bytes = Data(rawName)
        guard !bytes.isEmpty else {
            throw error(.invalidPath, message: "ZIP member name is empty")
        }
        if flags & 0x0800 != 0 {
            guard let utf8 = String(data: bytes, encoding: .utf8) else {
                throw error(.invalidEncoding, message: "ZIP UTF-8 member name is invalid")
            }
            return utf8
        }

        if let unicodePath = extraFields[0x7075], unicodePath.count >= 5,
           unicodePath[0] == 1,
           unicodePath.uint32LEUnchecked(at: 1) == ArchiveCRC32.checksum(bytes),
           let utf8 = String(data: unicodePath.dropFirst(5), encoding: .utf8)
        {
            return utf8
        }
        return CP437.decode(bytes)
    }

    private func zipPayloadRange(
        localHeaderOffset: Int,
        centralName: Data.SubSequence,
        centralFlags: UInt16,
        centralMethod: UInt16,
        centralCRC32: UInt32,
        compressedSize: Int,
        uncompressedSize: Int,
        upperBound: Int
    ) throws -> Range<Int> {
        guard let fixedRange = checkedRange(start: localHeaderOffset, count: 30, upperBound: upperBound) else {
            throw error(.truncatedArchive, message: "ZIP local-file header is truncated")
        }
        let fixed = data[fixedRange]
        guard fixed.uint32LEUnchecked(atRelative: 0) == ZIPSignature.localFile else {
            throw error(.malformedArchive, message: "ZIP local-file signature is invalid")
        }
        let localFlags = fixed.uint16LEUnchecked(atRelative: 6)
        let localMethod = fixed.uint16LEUnchecked(atRelative: 8)
        try validateZIPFlags(localFlags, path: nil)
        guard localFlags == centralFlags, localMethod == centralMethod else {
            throw error(.malformedArchive, message: "ZIP local and central metadata disagree")
        }
        if localFlags & 0x0008 == 0 {
            guard fixed.uint32LEUnchecked(atRelative: 14) == centralCRC32,
                  fixed.uint32LEUnchecked(atRelative: 18) == UInt32(compressedSize),
                  fixed.uint32LEUnchecked(atRelative: 22) == UInt32(uncompressedSize)
            else {
                throw error(.malformedArchive, message: "ZIP local and central sizes or CRC disagree")
            }
        }

        let localNameLength = Int(fixed.uint16LEUnchecked(atRelative: 26))
        let localExtraLength = Int(fixed.uint16LEUnchecked(atRelative: 28))
        guard let localNameRange = checkedRange(start: localHeaderOffset + 30, count: localNameLength, upperBound: upperBound),
              let localExtraRange = checkedRange(start: localNameRange.upperBound, count: localExtraLength, upperBound: upperBound)
        else {
            throw error(.truncatedArchive, message: "ZIP local-file variable fields are truncated")
        }
        guard data[localNameRange].elementsEqual(centralName) else {
            throw error(.malformedArchive, message: "ZIP local and central member names disagree")
        }
        let localExtraFields = try parseZIPExtraFields(data[localExtraRange])
        if localExtraFields[0x0001] != nil {
            throw error(.unsupportedZIP64, message: "ZIP64 local extra fields are not supported")
        }
        guard let payloadRange = checkedRange(
            start: localExtraRange.upperBound,
            count: compressedSize,
            upperBound: upperBound
        ) else {
            throw error(.truncatedArchive, message: "ZIP member payload is truncated")
        }
        return payloadRange
    }

    private func zipDate(time: UInt16, date: UInt16) -> Date? {
        guard date != 0 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 1980 + Int((date >> 9) & 0x7f)
        components.month = Int((date >> 5) & 0x0f)
        components.day = Int(date & 0x1f)
        components.hour = Int((time >> 11) & 0x1f)
        components.minute = Int((time >> 5) & 0x3f)
        components.second = Int(time & 0x1f) * 2
        return components.date
    }

    private func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw error(.malformedArchive, message: "Archive integer arithmetic overflowed")
        }
        return result
    }

    private func optionalCheckedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    private func checkedRange(start: Int, count: Int, upperBound: Int) -> Range<Int>? {
        guard start >= 0, count >= 0, let end = optionalCheckedAdd(start, count), end <= upperBound else { return nil }
        return start..<end
    }

    private func error(
        _ code: ArchiveResourceError.Code,
        path: String? = nil,
        message: String
    ) -> ArchiveResourceError {
        ArchiveResourceError(code: code, path: path, message: message)
    }
}

private enum ArchiveCRC32 {
    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xedb8_8320 & mask)
            }
        }
        return ~crc
    }
}

private enum CP437 {
    private static let highScalars: [UInt32] = [
        0x00c7, 0x00fc, 0x00e9, 0x00e2, 0x00e4, 0x00e0, 0x00e5, 0x00e7,
        0x00ea, 0x00eb, 0x00e8, 0x00ef, 0x00ee, 0x00ec, 0x00c4, 0x00c5,
        0x00c9, 0x00e6, 0x00c6, 0x00f4, 0x00f6, 0x00f2, 0x00fb, 0x00f9,
        0x00ff, 0x00d6, 0x00dc, 0x00a2, 0x00a3, 0x00a5, 0x20a7, 0x0192,
        0x00e1, 0x00ed, 0x00f3, 0x00fa, 0x00f1, 0x00d1, 0x00aa, 0x00ba,
        0x00bf, 0x2310, 0x00ac, 0x00bd, 0x00bc, 0x00a1, 0x00ab, 0x00bb,
        0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
        0x2555, 0x2563, 0x2551, 0x2557, 0x255d, 0x255c, 0x255b, 0x2510,
        0x2514, 0x2534, 0x252c, 0x251c, 0x2500, 0x253c, 0x255e, 0x255f,
        0x255a, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256c, 0x2567,
        0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256b,
        0x256a, 0x2518, 0x250c, 0x2588, 0x2584, 0x258c, 0x2590, 0x2580,
        0x03b1, 0x00df, 0x0393, 0x03c0, 0x03a3, 0x03c3, 0x00b5, 0x03c4,
        0x03a6, 0x0398, 0x03a9, 0x03b4, 0x221e, 0x03c6, 0x03b5, 0x2229,
        0x2261, 0x00b1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00f7, 0x2248,
        0x00b0, 0x2219, 0x00b7, 0x221a, 0x207f, 0x00b2, 0x25a0, 0x00a0,
    ]

    static func decode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var result = String.UnicodeScalarView()
        for byte in bytes {
            let value = byte < 0x80 ? UInt32(byte) : highScalars[Int(byte) - 0x80]
            if let scalar = UnicodeScalar(value) {
                result.append(scalar)
            }
        }
        return String(result)
    }
}

private extension Data {
    func uint16LEUnchecked(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LEUnchecked(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

private extension Data.SubSequence {
    func uint16LEUnchecked(atRelative offset: Int) -> UInt16 {
        let index = index(startIndex, offsetBy: offset)
        return UInt16(self[index]) | (UInt16(self[self.index(after: index)]) << 8)
    }

    func uint32LEUnchecked(atRelative offset: Int) -> UInt32 {
        let index0 = index(startIndex, offsetBy: offset)
        let index1 = index(after: index0)
        let index2 = index(after: index1)
        let index3 = index(after: index2)
        return UInt32(self[index0])
            | (UInt32(self[index1]) << 8)
            | (UInt32(self[index2]) << 16)
            | (UInt32(self[index3]) << 24)
    }
}
