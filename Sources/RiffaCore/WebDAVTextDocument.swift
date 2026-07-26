import CryptoKit
import Foundation

/// The bounded, path-free content version captured for one WebDAV text resource.
public struct WebDAVTextDocumentVersion: Hashable, Sendable {
    public let contentLength: Int64?
    public let modificationDate: Date?
    public let etag: String?
    public let fingerprint: DecodedTextFileFingerprint

    public init(
        contentLength: Int64?,
        modificationDate: Date?,
        etag: String?,
        fingerprint: DecodedTextFileFingerprint
    ) {
        self.contentLength = contentLength
        self.modificationDate = modificationDate
        self.etag = etag
        self.fingerprint = fingerprint
    }
}

/// A decoded remote document whose bytes were proven stable for the duration
/// of the load. The provider base URL and credentials are deliberately absent.
public struct WebDAVTextDocumentSnapshot: Hashable, Sendable {
    public let relativePath: String
    public let document: DecodedTextDocument
    public let version: WebDAVTextDocumentVersion

    public init(
        relativePath: String,
        document: DecodedTextDocument,
        version: WebDAVTextDocumentVersion
    ) {
        self.relativePath = relativePath
        self.document = document
        self.version = version
    }
}

public struct WebDAVTextDocumentError: Error, Hashable, Codable, Sendable, LocalizedError {
    public enum Code: String, Hashable, Codable, Sendable {
        case notFile
        case byteLimitExceeded
        case resourceChangedDuringRead
        case responseLengthMismatch
    }

    public let code: Code
    public let byteCount: UInt64?
    public let byteLimit: UInt64?

    public init(
        code: Code,
        byteCount: UInt64? = nil,
        byteLimit: UInt64? = nil
    ) {
        self.code = code
        self.byteCount = byteCount
        self.byteLimit = byteLimit
    }

    public var errorDescription: String? {
        switch code {
        case .notFile:
            "The WebDAV text resource is not a regular file."
        case .byteLimitExceeded:
            "The WebDAV text resource exceeds the configured byte limit."
        case .resourceChangedDuringRead:
            "The WebDAV text resource changed while it was being read."
        case .responseLengthMismatch:
            "The WebDAV response length does not match its metadata."
        }
    }
}

/// Loads a WebDAV text file without trusting one unversioned GET response.
///
/// A stable ETag permits one bounded GET. When the server does not provide a
/// transport-safe strong ETag, the bytes are read a second time through the
/// provider's bounded stream and their SHA-256 digest is compared before
/// decoding succeeds.
public struct WebDAVTextDocumentLoader: Sendable {
    public let limits: DecodedTextDocumentLimits

    public init(limits: DecodedTextDocumentLimits = .init()) {
        self.limits = limits
    }

    public func load(
        _ relativePath: String,
        from provider: WebDAVResourceProvider,
        authentication: WebDAVAuthentication? = nil
    ) async throws -> WebDAVTextDocumentSnapshot {
        try Task.checkCancellation()
        let effectiveLimit = Self.effectiveByteLimit(
            documentLimit: limits.maximumByteCount,
            providerLimit: provider.limits.maximumReadByteCount
        )
        let before = try await provider.stat(
            relativePath,
            authentication: authentication
        )
        try Self.requireFile(before)
        try Self.enforceDeclaredLength(
            before.contentLength,
            maximumByteCount: limits.maximumByteCount
        )
        let conditionalETag = Self.strongETag(before.etag)

        let readResult: WebDAVResourceReadResult
        do {
            readResult = try await provider.readResult(
                relativePath,
                maximumByteCount: effectiveLimit,
                ifMatchETag: conditionalETag,
                authentication: authentication
            )
        } catch let error as WebDAVResourceError where error.code == .preconditionFailed {
            throw WebDAVTextDocumentError(code: .resourceChangedDuringRead)
        }
        guard readResult.finalRelativePath == before.relativePath else {
            throw WebDAVTextDocumentError(code: .resourceChangedDuringRead)
        }
        let data = readResult.data
        try Task.checkCancellation()
        try Self.enforceActualLength(
            data.count,
            declaredLength: before.contentLength,
            maximumByteCount: limits.maximumByteCount
        )

        let after = try await provider.stat(
            relativePath,
            authentication: authentication
        )
        try Self.requireStableMetadata(before, after)
        try Self.enforceActualLength(
            data.count,
            declaredLength: after.contentLength,
            maximumByteCount: limits.maximumByteCount
        )

        let fingerprint = DecodedTextFileFingerprint(data: data)
        if conditionalETag == nil {
            let accumulator = WebDAVTextDigestAccumulator()
            let reread = try await provider.readChunksResult(
                relativePath,
                maximumByteCount: effectiveLimit,
                authentication: authentication
            ) { chunk in
                try await accumulator.append(chunk)
            }
            let rereadFingerprint = try await accumulator.finish()
            guard reread.finalRelativePath == after.relativePath,
                  reread.byteCount == data.count,
                  rereadFingerprint.hasSameContents(as: fingerprint) else {
                throw WebDAVTextDocumentError(code: .resourceChangedDuringRead)
            }

            let final = try await provider.stat(
                relativePath,
                authentication: authentication
            )
            try Self.requireStableMetadata(after, final)
            try Self.enforceActualLength(
                reread.byteCount,
                declaredLength: final.contentLength,
                maximumByteCount: limits.maximumByteCount
            )
        }

        try Task.checkCancellation()
        let document = try DecodedTextDocumentStore(limits: limits).decode(data)
        return WebDAVTextDocumentSnapshot(
            relativePath: after.relativePath,
            document: document,
            version: WebDAVTextDocumentVersion(
                contentLength: after.contentLength,
                modificationDate: after.modificationDate,
                etag: conditionalETag,
                fingerprint: fingerprint
            )
        )
    }
}

private extension WebDAVTextDocumentLoader {
    static func effectiveByteLimit(documentLimit: UInt64, providerLimit: Int) -> Int {
        let boundedDocumentLimit = documentLimit > UInt64(Int.max)
            ? Int.max
            : Int(documentLimit)
        return min(boundedDocumentLimit, providerLimit)
    }

    static func strongETag(_ value: String?) -> String? {
        guard let value, isTransportSafeStrongWebDAVETag(value) else {
            return nil
        }
        return value
    }

    static func requireFile(_ entry: WebDAVResourceEntry) throws {
        guard entry.kind == .file else {
            throw WebDAVTextDocumentError(code: .notFile)
        }
    }

    static func enforceDeclaredLength(
        _ length: Int64?,
        maximumByteCount: UInt64
    ) throws {
        guard let length else { return }
        guard UInt64(length) <= maximumByteCount else {
            throw WebDAVTextDocumentError(
                code: .byteLimitExceeded,
                byteCount: UInt64(length),
                byteLimit: maximumByteCount
            )
        }
    }

    static func enforceActualLength(
        _ actualLength: Int,
        declaredLength: Int64?,
        maximumByteCount: UInt64
    ) throws {
        let actual = UInt64(actualLength)
        guard actual <= maximumByteCount else {
            throw WebDAVTextDocumentError(
                code: .byteLimitExceeded,
                byteCount: actual,
                byteLimit: maximumByteCount
            )
        }
        guard declaredLength == nil || UInt64(declaredLength!) == actual else {
            throw WebDAVTextDocumentError(
                code: .responseLengthMismatch,
                byteCount: actual
            )
        }
    }

    static func requireStableMetadata(
        _ before: WebDAVResourceEntry,
        _ after: WebDAVResourceEntry
    ) throws {
        try requireFile(after)
        guard before.relativePath == after.relativePath,
              before.contentLength == after.contentLength,
              before.modificationDate == after.modificationDate,
              before.etag == after.etag,
              (before.etag == nil || !(before.etag?.isEmpty ?? true)) else {
            throw WebDAVTextDocumentError(code: .resourceChangedDuringRead)
        }
    }
}

private actor WebDAVTextDigestAccumulator {
    private var hasher = SHA256()
    private var byteCount: UInt64 = 0
    private var isFinished = false

    func append(_ data: Data) throws {
        guard !isFinished else {
            throw WebDAVTextDocumentError(code: .resourceChangedDuringRead)
        }
        let next = byteCount.addingReportingOverflow(UInt64(data.count))
        guard !next.overflow else {
            throw WebDAVTextDocumentError(code: .byteLimitExceeded)
        }
        byteCount = next.partialValue
        hasher.update(data: data)
    }

    func finish() throws -> DecodedTextFileFingerprint {
        guard !isFinished else {
            throw WebDAVTextDocumentError(code: .resourceChangedDuringRead)
        }
        isFinished = true
        let digest = hasher.finalize()
        return DecodedTextFileFingerprint(
            byteCount: byteCount,
            sha256: digest.map { String(format: "%02x", $0) }.joined()
        )
    }
}
