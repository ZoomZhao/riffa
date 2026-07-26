import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum WebDAVDepth: String, Codable, Sendable {
    case zero = "0"
    case one = "1"
}

public struct WebDAVResourceLimits: Hashable, Codable, Sendable {
    public let maximumPropertyResponseByteCount: Int
    public let maximumReadByteCount: Int
    public let maximumEntryCount: Int
    public let transferChunkByteCount: Int
    public let maximumRelativePathByteCount: Int
    public let maximumXMLDepth: Int
    public let requestTimeout: TimeInterval

    public init(
        maximumPropertyResponseByteCount: Int = 8 * 1_024 * 1_024,
        maximumReadByteCount: Int = 256 * 1_024 * 1_024,
        maximumEntryCount: Int = 100_000,
        transferChunkByteCount: Int = 64 * 1_024,
        maximumRelativePathByteCount: Int = 4_096,
        maximumXMLDepth: Int = 128,
        requestTimeout: TimeInterval = 30
    ) {
        self.maximumPropertyResponseByteCount = max(0, maximumPropertyResponseByteCount)
        self.maximumReadByteCount = max(0, maximumReadByteCount)
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.transferChunkByteCount = max(1, transferChunkByteCount)
        self.maximumRelativePathByteCount = max(1, maximumRelativePathByteCount)
        self.maximumXMLDepth = max(1, maximumXMLDepth)
        self.requestTimeout = requestTimeout.isFinite ? max(0.001, requestTimeout) : 30
    }

    public static let `default` = Self()

    private enum CodingKeys: String, CodingKey {
        case maximumPropertyResponseByteCount
        case maximumReadByteCount
        case maximumEntryCount
        case transferChunkByteCount
        case maximumRelativePathByteCount
        case maximumXMLDepth
        case requestTimeout
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let maximumPropertyResponseByteCount = try values.decode(
            Int.self,
            forKey: .maximumPropertyResponseByteCount
        )
        let maximumReadByteCount = try values.decode(Int.self, forKey: .maximumReadByteCount)
        let maximumEntryCount = try values.decode(Int.self, forKey: .maximumEntryCount)
        let transferChunkByteCount = try values.decode(Int.self, forKey: .transferChunkByteCount)
        let maximumRelativePathByteCount = try values.decode(
            Int.self,
            forKey: .maximumRelativePathByteCount
        )
        let maximumXMLDepth = try values.decode(Int.self, forKey: .maximumXMLDepth)
        let requestTimeout = try values.decode(TimeInterval.self, forKey: .requestTimeout)

        guard maximumPropertyResponseByteCount >= 0 else {
            throw Self.invalidLimit(.maximumPropertyResponseByteCount, in: values)
        }
        guard maximumReadByteCount >= 0 else {
            throw Self.invalidLimit(.maximumReadByteCount, in: values)
        }
        guard maximumEntryCount >= 0 else {
            throw Self.invalidLimit(.maximumEntryCount, in: values)
        }
        guard transferChunkByteCount > 0 else {
            throw Self.invalidLimit(.transferChunkByteCount, in: values)
        }
        guard maximumRelativePathByteCount > 0 else {
            throw Self.invalidLimit(.maximumRelativePathByteCount, in: values)
        }
        guard maximumXMLDepth > 0 else {
            throw Self.invalidLimit(.maximumXMLDepth, in: values)
        }
        guard requestTimeout.isFinite, requestTimeout > 0 else {
            throw Self.invalidLimit(.requestTimeout, in: values)
        }

        self.maximumPropertyResponseByteCount = maximumPropertyResponseByteCount
        self.maximumReadByteCount = maximumReadByteCount
        self.maximumEntryCount = maximumEntryCount
        self.transferChunkByteCount = transferChunkByteCount
        self.maximumRelativePathByteCount = maximumRelativePathByteCount
        self.maximumXMLDepth = maximumXMLDepth
        self.requestTimeout = requestTimeout
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(
            maximumPropertyResponseByteCount,
            forKey: .maximumPropertyResponseByteCount
        )
        try values.encode(maximumReadByteCount, forKey: .maximumReadByteCount)
        try values.encode(maximumEntryCount, forKey: .maximumEntryCount)
        try values.encode(transferChunkByteCount, forKey: .transferChunkByteCount)
        try values.encode(maximumRelativePathByteCount, forKey: .maximumRelativePathByteCount)
        try values.encode(maximumXMLDepth, forKey: .maximumXMLDepth)
        try values.encode(requestTimeout, forKey: .requestTimeout)
    }

    private static func invalidLimit(
        _ key: CodingKeys,
        in values: KeyedDecodingContainer<CodingKeys>
    ) -> DecodingError {
        DecodingError.dataCorruptedError(
            forKey: key,
            in: values,
            debugDescription: "WebDAV resource limits must remain within their documented bounds"
        )
    }
}

public struct WebDAVResourceEntry: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file
        case collection
    }

    public var id: String { relativePath }

    /// NFC-normalized, slash-separated path relative to the provider's base URL.
    /// The base collection itself has an empty relative path.
    public let relativePath: String
    public let kind: Kind
    public let contentLength: Int64?
    public let modificationDate: Date?
    public let etag: String?

    public init(
        relativePath: String,
        kind: Kind,
        contentLength: Int64? = nil,
        modificationDate: Date? = nil,
        etag: String? = nil
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.contentLength = contentLength
        self.modificationDate = modificationDate
        self.etag = etag
    }
}

/// A bounded GET result that keeps the final, normalized resource identity
/// beside its bytes. Callers doing optimistic consistency checks must compare
/// this path with their metadata observations.
public struct WebDAVResourceReadResult: Sendable {
    public let data: Data
    public let finalRelativePath: String
}

/// The equivalent identity result for a streamed GET.
public struct WebDAVResourceChunkReadResult: Hashable, Codable, Sendable {
    public let byteCount: Int
    public let finalRelativePath: String
}

/// Ephemeral credentials supplied to one operation. Descriptions are always redacted.
public enum WebDAVCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case basic(username: String, password: String)
    case bearer(token: String)

    public var description: String { "<redacted WebDAV credential>" }
    public var debugDescription: String { description }
}

/// Resolves a credential immediately before each request. A provider never stores
/// this value, the resolved credential, or an Authorization header.
public struct WebDAVAuthentication: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let resolver: @Sendable () async throws -> WebDAVCredential?

    public init(value: WebDAVCredential?) {
        resolver = { value }
    }

    public init(
        provider: @escaping @Sendable () async throws -> WebDAVCredential?
    ) {
        resolver = provider
    }

    public static func basic(username: String, password: String) -> Self {
        Self(value: .basic(username: username, password: password))
    }

    public static func bearer(token: String) -> Self {
        Self(value: .bearer(token: token))
    }

    public var description: String { "<redacted WebDAV authentication>" }
    public var debugDescription: String { description }

    fileprivate func resolve() async throws -> WebDAVCredential? {
        try await resolver()
    }
}

public struct WebDAVResourceError: Error, Hashable, Codable, Sendable, LocalizedError {
    public enum Code: String, Codable, Sendable {
        case invalidBaseURL
        case invalidPath
        case unsafeURL
        case unsafeRedirect
        case invalidCredential
        case credentialUnavailable
        case unauthorized
        case forbidden
        case notFound
        case preconditionFailed
        case serverError
        case unexpectedStatus
        case invalidResponse
        case invalidXML
        case invalidMultistatus
        case invalidMetadata
        case responseTooLarge
        case entryLimitExceeded
        case timeout
        case transportFailure
    }

    public let code: Code
    public let relativePath: String?
    public let statusCode: Int?
    public let limit: Int?
    public let transportCode: Int?

    public init(
        code: Code,
        relativePath: String? = nil,
        statusCode: Int? = nil,
        limit: Int? = nil,
        transportCode: Int? = nil
    ) {
        self.code = code
        self.relativePath = relativePath
        self.statusCode = statusCode
        self.limit = limit
        self.transportCode = transportCode
    }

    public var errorDescription: String? {
        let pathSuffix = relativePath.map { " at \($0)" } ?? ""
        return switch code {
        case .invalidBaseURL: "The WebDAV base URL is invalid"
        case .invalidPath: "The relative WebDAV path is invalid"
        case .unsafeURL: "The server returned a URL outside the configured WebDAV base"
        case .unsafeRedirect: "The WebDAV request attempted an unsafe redirect"
        case .invalidCredential: "The WebDAV credential is invalid"
        case .credentialUnavailable: "A WebDAV credential could not be obtained"
        case .unauthorized: "WebDAV authentication is required"
        case .forbidden: "The WebDAV resource is forbidden\(pathSuffix)"
        case .notFound: "The WebDAV resource was not found\(pathSuffix)"
        case .preconditionFailed: "The WebDAV resource changed before the conditional request completed\(pathSuffix)"
        case .serverError: "The WebDAV server returned an error"
        case .unexpectedStatus: "The WebDAV server returned an unexpected status"
        case .invalidResponse: "The WebDAV response is invalid"
        case .invalidXML: "The WebDAV XML response is invalid"
        case .invalidMultistatus: "The WebDAV multistatus response is invalid"
        case .invalidMetadata: "The WebDAV metadata is invalid\(pathSuffix)"
        case .responseTooLarge: "The WebDAV response exceeded its configured limit"
        case .entryLimitExceeded: "The WebDAV response contained too many entries"
        case .timeout: "The WebDAV request timed out"
        case .transportFailure: "The WebDAV transport failed"
        }
    }
}

/// A read-only RFC 4918 provider constrained to one HTTP(S) base collection.
///
/// Authentication is operation-scoped and is never retained by the provider.
/// Redirects and multistatus href values must remain on the exact configured
/// origin and below the configured base path.
public struct WebDAVResourceProvider: Sendable {
    public static let providerID = "webdav"

    public let baseURL: URL
    public let limits: WebDAVResourceLimits
    public let capabilities: ResourceCapabilities = [
        .enumerate,
        .read,
        .readMetadata,
    ]

    private let policy: WebDAVURLPolicy
    private let session: URLSession

    public init(
        baseURL: URL,
        configuration suppliedConfiguration: URLSessionConfiguration = .ephemeral,
        limits: WebDAVResourceLimits = .default
    ) throws {
        // Reconstruct the value at the trust boundary. This preserves the
        // documented source-compatible normalization even if a future caller
        // obtains a value through a nonstandard decoder.
        let normalizedLimits = WebDAVResourceLimits(
            maximumPropertyResponseByteCount: limits.maximumPropertyResponseByteCount,
            maximumReadByteCount: limits.maximumReadByteCount,
            maximumEntryCount: limits.maximumEntryCount,
            transferChunkByteCount: limits.transferChunkByteCount,
            maximumRelativePathByteCount: limits.maximumRelativePathByteCount,
            maximumXMLDepth: limits.maximumXMLDepth,
            requestTimeout: limits.requestTimeout
        )
        let policy = try WebDAVURLPolicy(
            baseURL: baseURL,
            maximumRelativePathByteCount: normalizedLimits.maximumRelativePathByteCount
        )
        let configuration = suppliedConfiguration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = normalizedLimits.requestTimeout
        configuration.timeoutIntervalForResource = normalizedLimits.requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // Request-specific authentication must not be supplied or retained via
        // the session configuration.
        configuration.httpAdditionalHeaders = nil

        let redirectDelegate = WebDAVRedirectDelegate(policy: policy)
        self.policy = policy
        self.baseURL = policy.baseURL
        self.limits = normalizedLimits
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    /// Executes RFC 4918 PROPFIND with a strict Depth of 0 or 1.
    public func propfind(
        _ relativePath: String = "",
        depth: WebDAVDepth,
        authentication: WebDAVAuthentication? = nil
    ) async throws -> [WebDAVResourceEntry] {
        let normalizedPath = try policy.normalizeRelativePath(relativePath)
        let requestURL = try policy.url(for: normalizedPath)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = limits.requestTimeout
        request.setValue(depth.rawValue, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propertyRequestXML.utf8)
        try await authorize(&request, using: authentication)

        let (data, _) = try await collect(
            request,
            acceptedStatusCodes: [207],
            maximumByteCount: limits.maximumPropertyResponseByteCount,
            enforceContentLength: true
        )
        let rawResponses = try parseMultistatus(data)
        var result: [WebDAVResourceEntry] = []
        var seenPaths: Set<WebDAVPathBytes> = []
        let requestedComponents = normalizedPath.isEmpty
            ? []
            : normalizedPath.split(separator: "/").map(String.init)

        for response in rawResponses {
            guard let href = response.href else {
                throw WebDAVResourceError(code: .invalidMultistatus)
            }
            let responseURL = try policy.resolve(href: href, relativeTo: requestURL)
            let responsePath = try policy.relativePath(for: responseURL)
            let responseComponents = responsePath.isEmpty
                ? []
                : responsePath.split(separator: "/").map(String.init)
            guard Self.isAllowedResponsePath(
                responseComponents,
                requestedComponents: requestedComponents,
                depth: depth
            ) else {
                throw WebDAVResourceError(code: .unsafeURL)
            }

            if let status = response.responseStatus, !(200...299).contains(status) {
                throw Self.statusError(status, relativePath: responsePath)
            }
            guard response.hasSuccessfulProperties || response.responseStatus.map({
                (200...299).contains($0)
            }) == true else {
                throw WebDAVResourceError(
                    code: .invalidMultistatus,
                    relativePath: responsePath
                )
            }

            let entry = try Self.makeEntry(from: response, relativePath: responsePath)
            guard seenPaths.insert(WebDAVPathBytes(responsePath)).inserted else {
                throw WebDAVResourceError(
                    code: .invalidMultistatus,
                    relativePath: responsePath
                )
            }
            result.append(entry)
        }

        return result.sorted {
            $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
        }
    }

    /// Lists direct children and excludes the collection's own Depth-1 response.
    public func list(
        _ relativePath: String = "",
        authentication: WebDAVAuthentication? = nil
    ) async throws -> [WebDAVResourceEntry] {
        let normalizedPath = try policy.normalizeRelativePath(relativePath)
        return try await propfind(
            normalizedPath,
            depth: .one,
            authentication: authentication
        ).filter { $0.relativePath != normalizedPath }
    }

    /// Reads metadata using HEAD. For authoritative collection typing, callers
    /// may use `propfind(_:depth:.zero)`.
    public func stat(
        _ relativePath: String,
        authentication: WebDAVAuthentication? = nil
    ) async throws -> WebDAVResourceEntry {
        let normalizedPath = try policy.normalizeRelativePath(relativePath)
        let requestURL = try policy.url(for: normalizedPath)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = limits.requestTimeout
        try await authorize(&request, using: authentication)

        let (_, response) = try await collect(
            request,
            acceptedStatusCodes: [200, 204],
            maximumByteCount: 0,
            enforceContentLength: false
        )
        let finalPath = try policy.relativePath(for: response.url ?? requestURL)
        let contentLength = try Self.parseContentLength(
            response.value(forHTTPHeaderField: "Content-Length"),
            relativePath: finalPath
        )
        let modificationDate = try Self.parseHTTPDate(
            response.value(forHTTPHeaderField: "Last-Modified"),
            relativePath: finalPath
        )
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let isCollection = (response.url ?? requestURL).path.hasSuffix("/")
            || contentType.contains("directory")
            || contentType.contains("collection")

        return WebDAVResourceEntry(
            relativePath: finalPath,
            kind: isCollection ? .collection : .file,
            contentLength: contentLength,
            modificationDate: modificationDate,
            etag: Self.trimmedOrNil(response.value(forHTTPHeaderField: "ETag"))
        )
    }

    /// Reads a complete resource while enforcing the configured aggregate limit.
    public func read(
        _ relativePath: String,
        maximumByteCount: Int? = nil,
        ifMatchETag: String? = nil,
        authentication: WebDAVAuthentication? = nil
    ) async throws -> Data {
        try await readResult(
            relativePath,
            maximumByteCount: maximumByteCount,
            ifMatchETag: ifMatchETag,
            authentication: authentication
        ).data
    }

    /// Reads a complete resource and preserves the final URL identity after
    /// any allowed same-root redirect.
    public func readResult(
        _ relativePath: String,
        maximumByteCount: Int? = nil,
        ifMatchETag: String? = nil,
        authentication: WebDAVAuthentication? = nil
    ) async throws -> WebDAVResourceReadResult {
        let requestedLimit = maximumByteCount.map { max(0, $0) }
            ?? limits.maximumReadByteCount
        let effectiveLimit = min(requestedLimit, limits.maximumReadByteCount)
        let normalizedPath = try policy.normalizeRelativePath(relativePath)
        let requestURL = try policy.url(for: normalizedPath)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = limits.requestTimeout
        try Self.applyIfMatch(ifMatchETag, to: &request, relativePath: normalizedPath)
        try await authorize(&request, using: authentication)

        let (data, response) = try await collect(
            request,
            acceptedStatusCodes: [200],
            maximumByteCount: effectiveLimit,
            enforceContentLength: true
        )
        return WebDAVResourceReadResult(
            data: data,
            finalRelativePath: try policy.relativePath(for: response.url ?? requestURL)
        )
    }

    /// Streams a GET response in bounded chunks and returns its aggregate byte count.
    @discardableResult
    public func readChunks(
        _ relativePath: String,
        maximumByteCount: Int? = nil,
        ifMatchETag: String? = nil,
        authentication: WebDAVAuthentication? = nil,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> Int {
        try await readChunksResult(
            relativePath,
            maximumByteCount: maximumByteCount,
            ifMatchETag: ifMatchETag,
            authentication: authentication,
            receive: receive
        ).byteCount
    }

    /// Streams a GET while preserving the normalized identity of the final
    /// response URL.
    public func readChunksResult(
        _ relativePath: String,
        maximumByteCount: Int? = nil,
        ifMatchETag: String? = nil,
        authentication: WebDAVAuthentication? = nil,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> WebDAVResourceChunkReadResult {
        let requestedLimit = maximumByteCount.map { max(0, $0) }
            ?? limits.maximumReadByteCount
        let effectiveLimit = min(requestedLimit, limits.maximumReadByteCount)
        let normalizedPath = try policy.normalizeRelativePath(relativePath)
        let requestURL = try policy.url(for: normalizedPath)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = limits.requestTimeout
        try Self.applyIfMatch(ifMatchETag, to: &request, relativePath: normalizedPath)
        try await authorize(&request, using: authentication)

        let (bytes, response) = try await begin(
            request,
            acceptedStatusCodes: [200],
            maximumByteCount: effectiveLimit,
            enforceContentLength: true
        )
        let finalRelativePath = try policy.relativePath(for: response.url ?? requestURL)
        var total = 0
        var chunk = Data()
        chunk.reserveCapacity(limits.transferChunkByteCount)

        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard total < effectiveLimit else {
                    throw WebDAVResourceError(
                        code: .responseTooLarge,
                        relativePath: normalizedPath,
                        limit: effectiveLimit
                    )
                }
                total += 1
                chunk.append(byte)
                if chunk.count == limits.transferChunkByteCount {
                    try await receive(chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty {
                try await receive(chunk)
            }
            try Task.checkCancellation()
            return WebDAVResourceChunkReadResult(
                byteCount: total,
                finalRelativePath: finalRelativePath
            )
        } catch {
            throw Self.normalizedTransportError(error)
        }
    }

    private func collect(
        _ request: URLRequest,
        acceptedStatusCodes: Set<Int>,
        maximumByteCount: Int,
        enforceContentLength: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await begin(
            request,
            acceptedStatusCodes: acceptedStatusCodes,
            maximumByteCount: maximumByteCount,
            enforceContentLength: enforceContentLength
        )
        var data = Data()
        data.reserveCapacity(min(maximumByteCount, 64 * 1_024))

        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumByteCount else {
                    throw WebDAVResourceError(
                        code: .responseTooLarge,
                        limit: maximumByteCount
                    )
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            return (data, response)
        } catch {
            throw Self.normalizedTransportError(error)
        }
    }

    private func begin(
        _ request: URLRequest,
        acceptedStatusCodes: Set<Int>,
        maximumByteCount: Int,
        enforceContentLength: Bool
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        try Task.checkCancellation()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  let responseURL = response.url else {
                throw WebDAVResourceError(code: .invalidResponse)
            }
            guard policy.allows(responseURL) else {
                throw WebDAVResourceError(code: .unsafeURL)
            }

            let statusCode = response.statusCode
            guard acceptedStatusCodes.contains(statusCode) else {
                throw Self.statusError(statusCode, relativePath: nil)
            }
            if enforceContentLength,
               let contentLength = try Self.parseContentLength(
                   response.value(forHTTPHeaderField: "Content-Length"),
                   relativePath: nil
               ),
               contentLength > Int64(maximumByteCount) {
                throw WebDAVResourceError(
                    code: .responseTooLarge,
                    limit: maximumByteCount
                )
            }
            return (bytes, response)
        } catch {
            throw Self.normalizedTransportError(error)
        }
    }

    private func authorize(
        _ request: inout URLRequest,
        using authentication: WebDAVAuthentication?
    ) async throws {
        guard let authentication else { return }
        let credential: WebDAVCredential?
        do {
            credential = try await authentication.resolve()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WebDAVResourceError(code: .credentialUnavailable)
        }
        guard let credential else { return }

        let header: String
        switch credential {
        case let .basic(username, password):
            guard !username.contains(":"),
                  !Self.containsHeaderNewline(username),
                  !Self.containsHeaderNewline(password) else {
                throw WebDAVResourceError(code: .invalidCredential)
            }
            let payload = Data("\(username):\(password)".utf8).base64EncodedString()
            header = "Basic \(payload)"
        case let .bearer(token):
            guard !token.isEmpty, !Self.containsHeaderNewline(token) else {
                throw WebDAVResourceError(code: .invalidCredential)
            }
            header = "Bearer \(token)"
        }
        request.setValue(header, forHTTPHeaderField: "Authorization")
    }

    private func parseMultistatus(_ data: Data) throws -> [DAVRawResponse] {
        if Self.containsUnsafeXMLDeclaration(data) {
            throw WebDAVResourceError(code: .invalidXML)
        }
        let parser = XMLParser(data: data)
        let delegate = DAVMultistatusParserDelegate(
            maximumEntryCount: limits.maximumEntryCount,
            maximumDepth: limits.maximumXMLDepth
        )
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let succeeded = parser.parse()
        if let failure = delegate.failure {
            throw failure
        }
        guard succeeded, parser.parserError == nil, delegate.sawMultistatus else {
            throw WebDAVResourceError(code: .invalidXML)
        }
        return delegate.responses
    }

    private static func makeEntry(
        from response: DAVRawResponse,
        relativePath: String
    ) throws -> WebDAVResourceEntry {
        let properties = response.properties
        let length = try parseContentLength(
            properties.contentLength,
            relativePath: relativePath
        )
        let date = try parseHTTPDate(
            properties.lastModified,
            relativePath: relativePath
        )
        return WebDAVResourceEntry(
            relativePath: relativePath,
            kind: properties.isCollection == true ? .collection : .file,
            contentLength: length,
            modificationDate: date,
            etag: trimmedOrNil(properties.etag)
        )
    }

    private static func parseContentLength(
        _ value: String?,
        relativePath: String?
    ) throws -> Int64? {
        guard let value = trimmedOrNil(value) else { return nil }
        guard value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let result = Int64(value), result >= 0 else {
            throw WebDAVResourceError(
                code: .invalidMetadata,
                relativePath: relativePath
            )
        }
        return result
    }

    private static func parseHTTPDate(
        _ value: String?,
        relativePath: String?
    ) throws -> Date? {
        guard let value = trimmedOrNil(value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: value) else {
            throw WebDAVResourceError(
                code: .invalidMetadata,
                relativePath: relativePath
            )
        }
        return date
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isAllowedResponsePath(
        _ components: [String],
        requestedComponents: [String],
        depth: WebDAVDepth
    ) -> Bool {
        guard components.starts(with: requestedComponents) else { return false }
        switch depth {
        case .zero:
            return components.count == requestedComponents.count
        case .one:
            return components.count == requestedComponents.count
                || components.count == requestedComponents.count + 1
        }
    }

    private static func statusError(
        _ statusCode: Int,
        relativePath: String?
    ) -> WebDAVResourceError {
        switch statusCode {
        case 300...399:
            WebDAVResourceError(
                code: .unsafeRedirect,
                relativePath: relativePath,
                statusCode: statusCode
            )
        case 401:
            WebDAVResourceError(code: .unauthorized, statusCode: statusCode)
        case 403:
            WebDAVResourceError(
                code: .forbidden,
                relativePath: relativePath,
                statusCode: statusCode
            )
        case 404:
            WebDAVResourceError(
                code: .notFound,
                relativePath: relativePath,
                statusCode: statusCode
            )
        case 412:
            WebDAVResourceError(
                code: .preconditionFailed,
                relativePath: relativePath,
                statusCode: statusCode
            )
        case 500...599:
            WebDAVResourceError(code: .serverError, statusCode: statusCode)
        default:
            WebDAVResourceError(code: .unexpectedStatus, statusCode: statusCode)
        }
    }

    private static func normalizedTransportError(_ error: any Error) -> any Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let error = error as? WebDAVResourceError {
            return error
        }
        if let error = error as? URLError {
            if error.code == .cancelled {
                return CancellationError()
            }
            if error.code == .timedOut {
                return WebDAVResourceError(code: .timeout)
            }
            return WebDAVResourceError(
                code: .transportFailure,
                transportCode: error.errorCode
            )
        }
        let cocoaError = error as NSError
        if cocoaError.domain == NSURLErrorDomain {
            if cocoaError.code == URLError.cancelled.rawValue {
                return CancellationError()
            }
            if cocoaError.code == URLError.timedOut.rawValue {
                return WebDAVResourceError(code: .timeout)
            }
            return WebDAVResourceError(
                code: .transportFailure,
                transportCode: cocoaError.code
            )
        }
        return WebDAVResourceError(code: .transportFailure)
    }

    private static func containsHeaderNewline(_ value: String) -> Bool {
        // CRLF is one extended grapheme cluster, so Character-based
        // `String.contains("\r")`/`contains("\n")` can miss the pair.
        // Header injection is byte-oriented; reject either control byte.
        value.utf8.contains(0x0D) || value.utf8.contains(0x0A)
    }

    private static func applyIfMatch(
        _ etag: String?,
        to request: inout URLRequest,
        relativePath: String
    ) throws {
        guard let etag else { return }
        guard isTransportSafeStrongWebDAVETag(etag) else {
            throw WebDAVResourceError(
                code: .invalidMetadata,
                relativePath: relativePath
            )
        }
        request.setValue(etag, forHTTPHeaderField: "If-Match")
    }

    private static func containsUnsafeXMLDeclaration(_ data: Data) -> Bool {
        let upper = Data(data.map { byte -> UInt8 in
            if byte >= 97 && byte <= 122 { return byte - 32 }
            return byte
        })
        return upper.range(of: Data("<!DOCTYPE".utf8)) != nil
            || upper.range(of: Data("<!ENTITY".utf8)) != nil
    }

    private static let propertyRequestXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:resourcetype/>
            <d:getcontentlength/>
            <d:getlastmodified/>
            <d:getetag/>
          </d:prop>
        </d:propfind>
        """
}

/// A caller supplies exactly one strong entity-tag, never an If-Match list or
/// wildcard. Restricting the opaque tag to visible ASCII avoids Foundation
/// re-encoding `obs-text` and rejects quotes, controls, and header separators.
/// Servers using a weak or non-transport-safe tag remain usable through the
/// loader's double-read SHA-256 fallback.
func isTransportSafeStrongWebDAVETag(_ value: String) -> Bool {
    let bytes = value.utf8
    guard bytes.count >= 2,
          bytes.count <= 8_192,
          bytes.first == 0x22,
          bytes.last == 0x22 else {
        return false
    }
    return bytes.dropFirst().dropLast().allSatisfy { byte in
        byte == 0x21 || (byte >= 0x23 && byte <= 0x7E)
    }
}

private struct WebDAVURLPolicy: Sendable {
    let baseURL: URL
    private let scheme: String
    private let host: String
    private let port: Int
    private let baseComponents: [String]
    private let maximumRelativePathByteCount: Int

    init(baseURL: URL, maximumRelativePathByteCount: Int) throws {
        guard var components = URLComponents(
            url: baseURL.absoluteURL,
            resolvingAgainstBaseURL: false
        ), let scheme = components.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let host = components.host?.lowercased(), !host.isEmpty,
           components.user == nil, components.password == nil,
           components.query == nil, components.fragment == nil else {
            throw WebDAVResourceError(code: .invalidBaseURL)
        }

        let decodedComponents = try Self.decodedPathComponents(
            components.percentEncodedPath,
            errorCode: .invalidBaseURL
        )
        components.scheme = scheme
        components.host = host
        if !components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "/"
        }
        guard let normalizedBase = components.url else {
            throw WebDAVResourceError(code: .invalidBaseURL)
        }

        self.baseURL = normalizedBase
        self.scheme = scheme
        self.host = host
        port = components.port ?? Self.defaultPort(for: scheme)
        baseComponents = decodedComponents
        self.maximumRelativePathByteCount = max(1, maximumRelativePathByteCount)
    }

    func normalizeRelativePath(_ path: String) throws -> String {
        guard !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else {
            throw WebDAVResourceError(code: .invalidPath)
        }
        if path.isEmpty { return "" }

        var result: [String] = []
        let rawComponents = path.split(separator: "/", omittingEmptySubsequences: false)
        for (index, rawComponent) in rawComponents.enumerated() {
            if rawComponent.isEmpty {
                if index == rawComponents.count - 1 {
                    continue
                }
                throw WebDAVResourceError(code: .invalidPath)
            }
            let component = String(rawComponent)
            let decoded = component.removingPercentEncoding ?? component
            guard component != ".", component != "..",
                  decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\\") else {
                throw WebDAVResourceError(code: .invalidPath)
            }
            result.append(component.precomposedStringWithCanonicalMapping)
        }
        let normalized = result.joined(separator: "/")
        guard normalized.utf8.count <= maximumRelativePathByteCount else {
            throw WebDAVResourceError(
                code: .invalidPath,
                limit: maximumRelativePathByteCount
            )
        }
        return normalized
    }

    func url(for relativePath: String) throws -> URL {
        let normalized = try normalizeRelativePath(relativePath)
        var result = baseURL
        for component in normalized.split(separator: "/") {
            result.appendPathComponent(String(component), isDirectory: false)
        }
        guard allows(result) else {
            throw WebDAVResourceError(code: .unsafeURL)
        }
        return result
    }

    func resolve(href: String, relativeTo requestURL: URL) throws -> URL {
        guard let components = URLComponents(string: href),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let resolved = components.url(relativeTo: requestURL)?.absoluteURL,
              allows(resolved) else {
            throw WebDAVResourceError(code: .unsafeURL)
        }
        return resolved
    }

    func allows(_ url: URL) -> Bool {
        guard let components = URLComponents(
            url: url.absoluteURL,
            resolvingAgainstBaseURL: false
        ), components.scheme?.lowercased() == scheme,
           components.host?.lowercased() == host,
           (components.port ?? Self.defaultPort(for: scheme)) == port,
           components.user == nil, components.password == nil,
           components.query == nil, components.fragment == nil,
           let pathComponents = try? Self.decodedPathComponents(
               components.percentEncodedPath,
               errorCode: .unsafeURL
           ), pathComponents.starts(with: baseComponents) else {
            return false
        }
        return true
    }

    func relativePath(for url: URL) throws -> String {
        guard allows(url),
              let components = URLComponents(
                  url: url.absoluteURL,
                  resolvingAgainstBaseURL: false
              ) else {
            throw WebDAVResourceError(code: .unsafeURL)
        }
        let componentsInPath = try Self.decodedPathComponents(
            components.percentEncodedPath,
            errorCode: .unsafeURL
        )
        let relative = componentsInPath.dropFirst(baseComponents.count)
            .map { $0.precomposedStringWithCanonicalMapping }
            .joined(separator: "/")
        guard relative.utf8.count <= maximumRelativePathByteCount else {
            throw WebDAVResourceError(
                code: .unsafeURL,
                limit: maximumRelativePathByteCount
            )
        }
        return relative
    }

    private static func decodedPathComponents(
        _ path: String,
        errorCode: WebDAVResourceError.Code
    ) throws -> [String] {
        var result: [String] = []
        for encoded in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !encoded.isEmpty else { continue }
            guard let decoded = String(encoded).removingPercentEncoding,
                  decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\\"),
                  !decoded.contains("\0") else {
                throw WebDAVResourceError(code: errorCode)
            }
            result.append(decoded.precomposedStringWithCanonicalMapping)
        }
        return result
    }

    private static func defaultPort(for scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }
}

private final class WebDAVRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: WebDAVURLPolicy

    init(policy: WebDAVURLPolicy) {
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, policy.allows(url) else {
            completionHandler(nil)
            return
        }
        guard request.httpMethod == task.originalRequest?.httpMethod else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private struct WebDAVPathBytes: Hashable {
    let bytes: [UInt8]

    init(_ path: String) {
        bytes = Array(path.utf8)
    }
}

private struct DAVRawResponse {
    var href: String?
    var responseStatus: Int?
    var properties = DAVRawProperties()
    var hasSuccessfulProperties = false
}

private struct DAVRawProperties {
    var isCollection: Bool?
    var contentLength: String?
    var lastModified: String?
    var etag: String?

    mutating func merge(_ other: Self) {
        if let value = other.isCollection { isCollection = value }
        if let value = other.contentLength { contentLength = value }
        if let value = other.lastModified { lastModified = value }
        if let value = other.etag { etag = value }
    }
}

private final class DAVMultistatusParserDelegate: NSObject, XMLParserDelegate {
    let maximumEntryCount: Int
    let maximumDepth: Int
    var responses: [DAVRawResponse] = []
    var failure: WebDAVResourceError?
    var sawMultistatus = false

    private var stack: [(namespace: String, local: String)] = []
    private var currentResponse: DAVRawResponse?
    private var currentProperties: DAVRawProperties?
    private var currentPropertyStatus: Int?
    private var currentText = ""
    private var sawResourceType = false

    init(maximumEntryCount: Int, maximumDepth: Int) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumDepth = maximumDepth
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        let element = (namespaceURI ?? "", elementName.lowercased())
        stack.append(element)
        guard stack.count <= maximumDepth else {
            fail(parser, WebDAVResourceError(code: .invalidXML))
            return
        }

        if stack.count == 1 {
            guard element.0 == "DAV:", element.1 == "multistatus" else {
                fail(parser, WebDAVResourceError(code: .invalidMultistatus))
                return
            }
            sawMultistatus = true
        }
        guard element.0 == "DAV:" else { return }

        switch element.1 {
        case "response":
            guard currentResponse == nil else {
                fail(parser, WebDAVResourceError(code: .invalidMultistatus))
                return
            }
            guard responses.count < maximumEntryCount else {
                fail(
                    parser,
                    WebDAVResourceError(
                        code: .entryLimitExceeded,
                        limit: maximumEntryCount
                    )
                )
                return
            }
            currentResponse = DAVRawResponse()
        case "propstat":
            guard currentResponse != nil, currentProperties == nil else {
                fail(parser, WebDAVResourceError(code: .invalidMultistatus))
                return
            }
            currentProperties = DAVRawProperties()
            currentPropertyStatus = nil
        case "resourcetype":
            if currentProperties != nil { sawResourceType = true }
        case "collection":
            if currentProperties != nil { currentProperties?.isCollection = true }
        case "href", "status", "getcontentlength", "getlastmodified", "getetag":
            currentText = ""
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        foundCDATA CDATABlock: Data
    ) {
        currentText += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard !stack.isEmpty else { return }
        let element = (namespaceURI ?? "", elementName.lowercased())
        defer { stack.removeLast() }
        guard failure == nil, element.0 == "DAV:" else { return }

        switch element.1 {
        case "href":
            currentResponse?.href = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        case "getcontentlength":
            currentProperties?.contentLength = currentText
        case "getlastmodified":
            currentProperties?.lastModified = currentText
        case "getetag":
            currentProperties?.etag = currentText
        case "resourcetype":
            if sawResourceType, currentProperties?.isCollection == nil {
                currentProperties?.isCollection = false
            }
            sawResourceType = false
        case "status":
            guard let status = Self.statusCode(from: currentText) else {
                fail(parser, WebDAVResourceError(code: .invalidMultistatus))
                return
            }
            let parent = stack.dropLast().last
            if parent?.namespace == "DAV:", parent?.local == "propstat" {
                currentPropertyStatus = status
            } else if parent?.namespace == "DAV:", parent?.local == "response" {
                currentResponse?.responseStatus = status
            }
        case "propstat":
            guard let properties = currentProperties,
                  let status = currentPropertyStatus else {
                fail(parser, WebDAVResourceError(code: .invalidMultistatus))
                return
            }
            if (200...299).contains(status) {
                currentResponse?.properties.merge(properties)
                currentResponse?.hasSuccessfulProperties = true
            }
            currentProperties = nil
            currentPropertyStatus = nil
        case "response":
            guard let response = currentResponse else {
                fail(parser, WebDAVResourceError(code: .invalidMultistatus))
                return
            }
            responses.append(response)
            currentResponse = nil
        default:
            break
        }
    }

    private func fail(_ parser: XMLParser, _ error: WebDAVResourceError) {
        failure = error
        parser.abortParsing()
    }

    private static func statusCode(from string: String) -> Int? {
        string.split(whereSeparator: { $0.isWhitespace })
            .compactMap { Int($0) }
            .first { (100...599).contains($0) }
    }
}
