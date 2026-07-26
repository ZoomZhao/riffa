import CryptoKit
import Darwin
import Foundation

/// Unicode encodings accepted by ``DecodedTextDocumentStore``.
public enum DecodedTextEncoding: String, CaseIterable, Hashable, Codable, Sendable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
}

/// Byte-order marks that can be preserved by a decoded text document.
public enum DecodedTextByteOrderMark: String, CaseIterable, Hashable, Codable, Sendable {
    case none
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
}

/// A supported on-disk text representation. Encoding and BOM are represented
/// as one enum so callers cannot construct mismatched combinations.
public enum DecodedTextDocumentFormat: String, CaseIterable, Hashable, Codable, Sendable {
    case utf8
    case utf8WithByteOrderMark
    case utf16LittleEndianWithByteOrderMark
    case utf16BigEndianWithByteOrderMark

    public var encoding: DecodedTextEncoding {
        switch self {
        case .utf8, .utf8WithByteOrderMark:
            .utf8
        case .utf16LittleEndianWithByteOrderMark:
            .utf16LittleEndian
        case .utf16BigEndianWithByteOrderMark:
            .utf16BigEndian
        }
    }

    public var byteOrderMark: DecodedTextByteOrderMark {
        switch self {
        case .utf8:
            .none
        case .utf8WithByteOrderMark:
            .utf8
        case .utf16LittleEndianWithByteOrderMark:
            .utf16LittleEndian
        case .utf16BigEndianWithByteOrderMark:
            .utf16BigEndian
        }
    }
}

/// A path-free fingerprint suitable for detecting edits made by another
/// process. Content identity deliberately ignores the optional timestamp.
public struct DecodedTextFileFingerprint: Hashable, Codable, Sendable {
    public let byteCount: UInt64
    public let sha256: String
    public let modificationTimeNanoseconds: Int64?

    public init(
        byteCount: UInt64,
        sha256: String,
        modificationTimeNanoseconds: Int64? = nil
    ) {
        self.byteCount = byteCount
        self.sha256 = sha256
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
    }

    public init(data: Data, modificationTimeNanoseconds: Int64? = nil) {
        byteCount = UInt64(data.count)
        sha256 = Self.hexDigest(SHA256.hash(data: data))
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
    }

    public func hasSameContents(as other: Self) -> Bool {
        byteCount == other.byteCount && sha256 == other.sha256
    }

    private static func hexDigest<Digest: Sequence>(_ digest: Digest) -> String
    where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Result of re-reading a file and comparing it with an earlier fingerprint.
public enum DecodedTextExternalModification: String, Hashable, Codable, Sendable {
    case unchanged
    case metadataOnly
    case contentsChanged

    public var hasExternalModification: Bool { self != .unchanged }
}

/// A decoded document plus the format and content fingerprint observed when it
/// was loaded. Replacing `text` retains the original fingerprint so it can be
/// used for a later conflict check.
public struct DecodedTextDocument: Hashable, Codable, Sendable {
    public let text: String
    public let format: DecodedTextDocumentFormat
    public let fingerprint: DecodedTextFileFingerprint

    public init(
        text: String,
        format: DecodedTextDocumentFormat,
        fingerprint: DecodedTextFileFingerprint
    ) {
        self.text = text
        self.format = format
        self.fingerprint = fingerprint
    }

    public func replacingText(with text: String) -> Self {
        Self(text: text, format: format, fingerprint: fingerprint)
    }

    /// Encodes strictly in the original representation, including its BOM.
    public func encodedData() throws -> Data {
        try DecodedTextCodec.encode(text, as: format)
    }
}

public struct DecodedTextDocumentLimits: Hashable, Codable, Sendable {
    public static let defaultMaximumByteCount: UInt64 = 64 * 1_024 * 1_024
    public static let defaultReadChunkByteCount = 64 * 1_024

    public let maximumByteCount: UInt64
    public let readChunkByteCount: Int

    public init(
        maximumByteCount: UInt64 = Self.defaultMaximumByteCount,
        readChunkByteCount: Int = Self.defaultReadChunkByteCount
    ) {
        self.maximumByteCount = maximumByteCount
        self.readChunkByteCount = readChunkByteCount
    }
}

public enum DecodedTextDocumentOperation: String, Hashable, Codable, Sendable {
    case decode
    case encode
    case read
    case write
    case fingerprint
}

public struct DecodedTextDocumentError: Error, Hashable, Codable, Sendable, LocalizedError {
    public enum Code: String, Hashable, Codable, Sendable {
        case nonFileURL
        case notRegularFile
        case invalidLimits
        case byteLimitExceeded
        case unsupportedEncoding
        case invalidEncoding
        case unrepresentableCharacter
        case fileChangedDuringRead
        case externalModification
        case ioFailure
    }

    public let code: Code
    public let operation: DecodedTextDocumentOperation
    public let byteOffset: UInt64?
    public let byteCount: UInt64?
    public let byteLimit: UInt64?

    public init(
        code: Code,
        operation: DecodedTextDocumentOperation,
        byteOffset: UInt64? = nil,
        byteCount: UInt64? = nil,
        byteLimit: UInt64? = nil
    ) {
        self.code = code
        self.operation = operation
        self.byteOffset = byteOffset
        self.byteCount = byteCount
        self.byteLimit = byteLimit
    }

    public var errorDescription: String? {
        switch code {
        case .nonFileURL:
            "The text resource is not a local file URL."
        case .notRegularFile:
            "The text resource is not a regular file."
        case .invalidLimits:
            "The text document limits are invalid."
        case .byteLimitExceeded:
            "The text document exceeds the configured byte limit."
        case .unsupportedEncoding:
            "The text document uses an unsupported encoding."
        case .invalidEncoding:
            "The text document contains an invalid Unicode byte sequence."
        case .unrepresentableCharacter:
            "The text contains a character that cannot be represented in the original encoding."
        case .fileChangedDuringRead:
            "The text document changed while it was being read."
        case .externalModification:
            "The text document was modified by another process."
        case .ioFailure:
            "The text document operation failed."
        }
    }
}

/// Strict decoder, encoder, bounded file loader, and external-change checker.
public struct DecodedTextDocumentStore: Sendable {
    public let limits: DecodedTextDocumentLimits

    public init(limits: DecodedTextDocumentLimits = .init()) {
        self.limits = limits
    }

    public func decode(
        _ data: Data,
        modificationTimeNanoseconds: Int64? = nil
    ) throws -> DecodedTextDocument {
        try validateLimits()
        try Task.checkCancellation()
        try enforceLimit(byteCount: UInt64(data.count), operation: .decode)

        let decoded = try DecodedTextCodec.decode(data)
        try Task.checkCancellation()
        return DecodedTextDocument(
            text: decoded.text,
            format: decoded.format,
            fingerprint: DecodedTextFileFingerprint(
                data: data,
                modificationTimeNanoseconds: modificationTimeNanoseconds
            )
        )
    }

    public func load(from fileURL: URL) async throws -> DecodedTextDocument {
        let loaded = try readFile(fileURL, operation: .read)
        return try decode(
            loaded.data,
            modificationTimeNanoseconds: Self.modificationTimeNanoseconds(loaded.fileStatus)
        )
    }

    public func fingerprint(of fileURL: URL) async throws -> DecodedTextFileFingerprint {
        let loaded = try readFile(fileURL, operation: .fingerprint)
        try Task.checkCancellation()
        return DecodedTextFileFingerprint(
            data: loaded.data,
            modificationTimeNanoseconds: Self.modificationTimeNanoseconds(loaded.fileStatus)
        )
    }

    public func externalModification(
        of fileURL: URL,
        comparedTo original: DecodedTextFileFingerprint
    ) async throws -> DecodedTextExternalModification {
        let current = try await fingerprint(of: fileURL)
        guard original.hasSameContents(as: current) else {
            return .contentsChanged
        }
        if let originalTime = original.modificationTimeNanoseconds,
           let currentTime = current.modificationTimeNanoseconds,
           originalTime != currentTime {
            return .metadataOnly
        }
        return .unchanged
    }

    /// Saves atomically in the document's original encoding and returns a new
    /// path-free fingerprint for the bytes written.
    public func save(
        _ document: DecodedTextDocument,
        to fileURL: URL
    ) async throws -> DecodedTextFileFingerprint {
        try validateFileURL(fileURL, operation: .write)
        try validateLimits()
        try Task.checkCancellation()

        let data: Data
        do {
            data = try document.encodedData()
        } catch let error as DecodedTextDocumentError {
            throw error
        } catch {
            throw DecodedTextDocumentError(code: .unrepresentableCharacter, operation: .encode)
        }
        try enforceLimit(byteCount: UInt64(data.count), operation: .write)
        try Task.checkCancellation()

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw DecodedTextDocumentError(code: .ioFailure, operation: .write)
        }
        try Task.checkCancellation()

        let fileStatus = try Self.pathStatus(fileURL, operation: .write)
        return DecodedTextFileFingerprint(
            data: data,
            modificationTimeNanoseconds: Self.modificationTimeNanoseconds(fileStatus)
        )
    }

    /// Performs a content-aware optimistic save. Timestamp-only changes are
    /// reported to the caller but do not block writing identical file content.
    public func save(
        _ document: DecodedTextDocument,
        to fileURL: URL,
        ifContentsMatch expected: DecodedTextFileFingerprint
    ) async throws -> DecodedTextFileFingerprint {
        let change = try await externalModification(of: fileURL, comparedTo: expected)
        guard change != .contentsChanged else {
            throw DecodedTextDocumentError(code: .externalModification, operation: .write)
        }
        return try await save(document, to: fileURL)
    }

    private func validateLimits() throws {
        guard limits.maximumByteCount > 0, limits.readChunkByteCount > 0 else {
            throw DecodedTextDocumentError(code: .invalidLimits, operation: .read)
        }
    }

    private func validateFileURL(
        _ fileURL: URL,
        operation: DecodedTextDocumentOperation
    ) throws {
        guard fileURL.isFileURL else {
            throw DecodedTextDocumentError(code: .nonFileURL, operation: operation)
        }
    }

    private func enforceLimit(
        byteCount: UInt64,
        operation: DecodedTextDocumentOperation
    ) throws {
        guard byteCount <= limits.maximumByteCount else {
            throw DecodedTextDocumentError(
                code: .byteLimitExceeded,
                operation: operation,
                byteCount: byteCount,
                byteLimit: limits.maximumByteCount
            )
        }
    }

    private func readFile(
        _ fileURL: URL,
        operation: DecodedTextDocumentOperation
    ) throws -> (data: Data, fileStatus: stat) {
        try validateFileURL(fileURL, operation: operation)
        try validateLimits()
        try Task.checkCancellation()

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw DecodedTextDocumentError(code: .ioFailure, operation: operation)
        }
        defer { try? handle.close() }

        var before = stat()
        guard Darwin.fstat(handle.fileDescriptor, &before) == 0 else {
            throw DecodedTextDocumentError(code: .ioFailure, operation: operation)
        }
        guard (before.st_mode & S_IFMT) == S_IFREG else {
            throw DecodedTextDocumentError(code: .notRegularFile, operation: operation)
        }
        guard before.st_size >= 0 else {
            throw DecodedTextDocumentError(code: .ioFailure, operation: operation)
        }
        try enforceLimit(byteCount: UInt64(before.st_size), operation: operation)

        var data = Data()
        if before.st_size <= Int.max {
            data.reserveCapacity(Int(before.st_size))
        }

        while true {
            try Task.checkCancellation()
            let chunk: Data
            do {
                guard let value = try handle.read(upToCount: limits.readChunkByteCount),
                      !value.isEmpty else {
                    break
                }
                chunk = value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DecodedTextDocumentError(code: .ioFailure, operation: operation)
            }

            let (attempted, overflow) = UInt64(data.count).addingReportingOverflow(UInt64(chunk.count))
            guard !overflow, attempted <= limits.maximumByteCount else {
                throw DecodedTextDocumentError(
                    code: .byteLimitExceeded,
                    operation: operation,
                    byteCount: overflow ? nil : attempted,
                    byteLimit: limits.maximumByteCount
                )
            }
            data.append(chunk)
        }
        try Task.checkCancellation()

        var after = stat()
        guard Darwin.fstat(handle.fileDescriptor, &after) == 0 else {
            throw DecodedTextDocumentError(code: .ioFailure, operation: operation)
        }
        let pathAfter = try Self.pathStatus(fileURL, operation: operation)
        guard Self.sameFileState(before, after), Self.sameFileIdentity(after, pathAfter) else {
            throw DecodedTextDocumentError(code: .fileChangedDuringRead, operation: operation)
        }
        return (data, after)
    }

    private static func pathStatus(
        _ fileURL: URL,
        operation: DecodedTextDocumentOperation
    ) throws -> stat {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw DecodedTextDocumentError(code: .ioFailure, operation: operation)
        }
        defer { try? handle.close() }

        var value = stat()
        guard Darwin.fstat(handle.fileDescriptor, &value) == 0 else {
            throw DecodedTextDocumentError(code: .ioFailure, operation: operation)
        }
        return value
    }

    private static func sameFileIdentity(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    private static func sameFileState(_ left: stat, _ right: stat) -> Bool {
        sameFileIdentity(left, right)
            && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
    }

    private static func modificationTimeNanoseconds(_ value: stat) -> Int64? {
        let seconds = Int64(value.st_mtimespec.tv_sec)
        let nanoseconds = Int64(value.st_mtimespec.tv_nsec)
        let (scaledSeconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        let (result, additionOverflow) = scaledSeconds.addingReportingOverflow(nanoseconds)
        return additionOverflow ? nil : result
    }
}

private enum DecodedTextCodec {
    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16LittleEndianBOM: [UInt8] = [0xFF, 0xFE]
    private static let utf16BigEndianBOM: [UInt8] = [0xFE, 0xFF]

    static func decode(_ data: Data) throws -> (text: String, format: DecodedTextDocumentFormat) {
        let bytes = Array(data)

        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF])
            || bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            throw DecodedTextDocumentError(code: .unsupportedEncoding, operation: .decode)
        }
        if bytes.starts(with: utf8BOM) {
            let payload = Array(bytes.dropFirst(utf8BOM.count))
            return (try decodeUTF8(payload), .utf8WithByteOrderMark)
        }
        if bytes.starts(with: utf16LittleEndianBOM) {
            let payload = Array(bytes.dropFirst(utf16LittleEndianBOM.count))
            return (try decodeUTF16(payload, littleEndian: true), .utf16LittleEndianWithByteOrderMark)
        }
        if bytes.starts(with: utf16BigEndianBOM) {
            let payload = Array(bytes.dropFirst(utf16BigEndianBOM.count))
            return (try decodeUTF16(payload, littleEndian: false), .utf16BigEndianWithByteOrderMark)
        }
        return (try decodeUTF8(bytes), .utf8)
    }

    static func encode(_ text: String, as format: DecodedTextDocumentFormat) throws -> Data {
        try Task.checkCancellation()
        guard text.unicodeScalars.allSatisfy({ scalar in
            let value = scalar.value
            return value <= 0x10_FFFF && !(0xD800...0xDFFF).contains(value)
        }) else {
            throw DecodedTextDocumentError(code: .unrepresentableCharacter, operation: .encode)
        }

        var output = Data()
        switch format {
        case .utf8:
            output.append(contentsOf: text.utf8)
        case .utf8WithByteOrderMark:
            output.append(contentsOf: utf8BOM)
            output.append(contentsOf: text.utf8)
        case .utf16LittleEndianWithByteOrderMark:
            output.append(contentsOf: utf16LittleEndianBOM)
            appendUTF16(text, littleEndian: true, to: &output)
        case .utf16BigEndianWithByteOrderMark:
            output.append(contentsOf: utf16BigEndianBOM)
            appendUTF16(text, littleEndian: false, to: &output)
        }
        try Task.checkCancellation()
        return output
    }

    private static func decodeUTF8(_ bytes: [UInt8]) throws -> String {
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            let continuationCount: Int
            let secondRange: ClosedRange<UInt8>
            switch first {
            case 0x00...0x7F:
                index += 1
                continue
            case 0xC2...0xDF:
                continuationCount = 1
                secondRange = 0x80...0xBF
            case 0xE0:
                continuationCount = 2
                secondRange = 0xA0...0xBF
            case 0xE1...0xEC, 0xEE...0xEF:
                continuationCount = 2
                secondRange = 0x80...0xBF
            case 0xED:
                continuationCount = 2
                secondRange = 0x80...0x9F
            case 0xF0:
                continuationCount = 3
                secondRange = 0x90...0xBF
            case 0xF1...0xF3:
                continuationCount = 3
                secondRange = 0x80...0xBF
            case 0xF4:
                continuationCount = 3
                secondRange = 0x80...0x8F
            default:
                throw invalidEncoding(at: index)
            }

            guard index + continuationCount < bytes.count,
                  secondRange.contains(bytes[index + 1]) else {
                throw invalidEncoding(at: index)
            }
            if continuationCount > 1 {
                for continuationIndex in (index + 2)...(index + continuationCount) {
                    guard (0x80...0xBF).contains(bytes[continuationIndex]) else {
                        throw invalidEncoding(at: continuationIndex)
                    }
                }
            }
            index += continuationCount + 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func decodeUTF16(_ bytes: [UInt8], littleEndian: Bool) throws -> String {
        guard bytes.count.isMultiple(of: 2) else {
            throw invalidEncoding(at: bytes.count - 1)
        }
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(bytes.count / 2)
        var byteIndex = 0
        while byteIndex < bytes.count {
            let first = UInt16(bytes[byteIndex])
            let second = UInt16(bytes[byteIndex + 1])
            codeUnits.append(littleEndian ? first | (second << 8) : (first << 8) | second)
            byteIndex += 2
        }

        var unitIndex = 0
        while unitIndex < codeUnits.count {
            let unit = codeUnits[unitIndex]
            if (0xD800...0xDBFF).contains(unit) {
                guard unitIndex + 1 < codeUnits.count,
                      (0xDC00...0xDFFF).contains(codeUnits[unitIndex + 1]) else {
                    throw invalidEncoding(at: unitIndex * 2)
                }
                unitIndex += 2
            } else if (0xDC00...0xDFFF).contains(unit) {
                throw invalidEncoding(at: unitIndex * 2)
            } else {
                unitIndex += 1
            }
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    private static func appendUTF16(_ text: String, littleEndian: Bool, to output: inout Data) {
        for unit in text.utf16 {
            if littleEndian {
                output.append(UInt8(truncatingIfNeeded: unit))
                output.append(UInt8(truncatingIfNeeded: unit >> 8))
            } else {
                output.append(UInt8(truncatingIfNeeded: unit >> 8))
                output.append(UInt8(truncatingIfNeeded: unit))
            }
        }
    }

    private static func invalidEncoding(at byteOffset: Int) -> DecodedTextDocumentError {
        DecodedTextDocumentError(
            code: .invalidEncoding,
            operation: .decode,
            byteOffset: UInt64(max(0, byteOffset))
        )
    }
}
