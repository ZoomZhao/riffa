import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RiffaCore

@Suite("Read-only WebDAV resources", .serialized)
struct WebDAVResourceProviderTests {
    @Test("Depth 0 and 1 multistatus responses parse namespaces and Unicode hrefs")
    func propfindParsing() async throws {
        let requests = LockedBox<[URLRequest]>([])
        MockWebDAVURLProtocol.install { request in
            requests.withValue { $0.append(request) }
            let depth = request.value(forHTTPHeaderField: "Depth")
            let body = depth == "0" ? Self.depthZeroXML : Self.depthOneXML
            return .response(
                statusCode: 207,
                headers: [
                    "Content-Type": "application/xml; charset=utf-8",
                    "Content-Length": "\(body.utf8.count)",
                ],
                chunks: [Data(body.utf8)]
            )
        }
        let provider = try makeProvider()

        let root = try await provider.propfind("", depth: .zero)
        #expect(root.count == 1)
        #expect(root[0].relativePath == "")
        #expect(root[0].kind == .collection)

        let children = try await provider.list()
        #expect(children.map(\.relativePath) == ["Folder", "文件 name.txt"])
        let file = try #require(children.first { $0.relativePath == "文件 name.txt" })
        #expect(file.kind == .file)
        #expect(file.contentLength == 5)
        #expect(file.etag == "\"unicode-etag\"")
        #expect(file.modificationDate != nil)
        let folder = try #require(children.first { $0.relativePath == "Folder" })
        #expect(folder.kind == .collection)
        #expect(folder.contentLength == nil)

        let captured = requests.read()
        #expect(captured.count == 2)
        #expect(captured.allSatisfy { $0.httpMethod == "PROPFIND" })
        #expect(captured.map { $0.value(forHTTPHeaderField: "Depth") } == ["0", "1"])
        #expect(captured.allSatisfy {
            $0.value(forHTTPHeaderField: "Content-Type") == "application/xml; charset=utf-8"
        })
    }

    @Test("HEAD metadata and GET data are parsed and streamed in configured chunks")
    func headAndGET() async throws {
        let requests = LockedBox<[URLRequest]>([])
        MockWebDAVURLProtocol.install { request in
            requests.withValue { $0.append(request) }
            switch request.httpMethod {
            case "HEAD":
                return .response(
                    statusCode: 200,
                    headers: [
                        "Content-Length": "6",
                        "Last-Modified": "Tue, 15 Nov 1994 12:45:26 GMT",
                        "ETag": "\"head-etag\"",
                        "Content-Type": "application/octet-stream",
                    ]
                )
            case "GET":
                return .response(
                    statusCode: 200,
                    headers: ["Content-Length": "6"],
                    chunks: [Data("ab".utf8), Data("cd".utf8), Data("ef".utf8)]
                )
            default:
                return .response(statusCode: 405)
            }
        }
        let provider = try makeProvider(
            limits: WebDAVResourceLimits(transferChunkByteCount: 2)
        )

        let metadata = try await provider.stat("report.txt")
        #expect(metadata.relativePath == "report.txt")
        #expect(metadata.kind == .file)
        #expect(metadata.contentLength == 6)
        #expect(metadata.etag == "\"head-etag\"")
        #expect(metadata.modificationDate != nil)
        let read = try await provider.readResult("report.txt")
        #expect(read.data == Data("abcdef".utf8))
        #expect(read.finalRelativePath == "report.txt")

        let collector = DAVChunkCollector()
        let streamed = try await provider.readChunksResult("report.txt") { chunk in
            await collector.append(chunk)
        }
        let chunks = await collector.values()
        #expect(streamed.byteCount == 6)
        #expect(streamed.finalRelativePath == "report.txt")
        #expect(chunks == [Data("ab".utf8), Data("cd".utf8), Data("ef".utf8)])
        #expect(requests.read().map(\.httpMethod) == ["HEAD", "GET", "GET"])
    }

    @Test("Decoded WebDAV limits cannot bypass memory and traversal invariants")
    func decodedLimitsRemainValid() throws {
        let valid: [String: Any] = [
            "maximumPropertyResponseByteCount": 8_192,
            "maximumReadByteCount": 16_384,
            "maximumEntryCount": 100,
            "transferChunkByteCount": 1_024,
            "maximumRelativePathByteCount": 512,
            "maximumXMLDepth": 16,
            "requestTimeout": 2.5,
        ]
        let validData = try JSONSerialization.data(withJSONObject: valid, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(WebDAVResourceLimits.self, from: validData)
        #expect(decoded.transferChunkByteCount == 1_024)
        #expect(try JSONDecoder().decode(
            WebDAVResourceLimits.self,
            from: JSONEncoder().encode(decoded)
        ) == decoded)

        for (key, invalidValue) in [
            ("maximumPropertyResponseByteCount", -1),
            ("maximumReadByteCount", -1),
            ("maximumEntryCount", -1),
            ("transferChunkByteCount", 0),
            ("maximumRelativePathByteCount", 0),
            ("maximumXMLDepth", 0),
            ("requestTimeout", 0),
        ] {
            var candidate = valid
            candidate[key] = invalidValue
            let data = try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys])
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(WebDAVResourceLimits.self, from: data)
            }
        }

        let normalized = WebDAVResourceLimits(
            maximumPropertyResponseByteCount: -1,
            maximumReadByteCount: -1,
            maximumEntryCount: -1,
            transferChunkByteCount: 0,
            maximumRelativePathByteCount: 0,
            maximumXMLDepth: 0,
            requestTimeout: -Double.infinity
        )
        #expect(normalized.maximumPropertyResponseByteCount == 0)
        #expect(normalized.maximumReadByteCount == 0)
        #expect(normalized.maximumEntryCount == 0)
        #expect(normalized.transferChunkByteCount == 1)
        #expect(normalized.maximumRelativePathByteCount == 1)
        #expect(normalized.maximumXMLDepth == 1)
        #expect(normalized.requestTimeout == 30)
    }

    @Test("Basic and Bearer credentials are request-scoped and never appear in errors")
    func authenticationIsEphemeralAndRedacted() async throws {
        let headers = LockedBox<[String?]>([])
        MockWebDAVURLProtocol.install { request in
            headers.withValue {
                $0.append(request.value(forHTTPHeaderField: "Authorization"))
            }
            return .response(statusCode: 401)
        }
        let configuration = mockConfiguration()
        configuration.httpAdditionalHeaders = [
            "Authorization": "Bearer persisted-secret-must-be-removed",
        ]
        let provider = try WebDAVResourceProvider(
            baseURL: baseURL,
            configuration: configuration
        )
        let password = "s3cr3t-\(UUID().uuidString)"
        let basic = WebDAVCredential.basic(username: "reader", password: password)
        let authentication = WebDAVAuthentication(value: basic)

        await expectWebDAVError(.unauthorized) {
            _ = try await provider.read("private.txt", authentication: authentication)
        }
        await expectWebDAVError(.unauthorized) {
            _ = try await provider.read(
                "private.txt",
                authentication: .bearer(token: password)
            )
        }
        await expectWebDAVError(.unauthorized) {
            _ = try await provider.read("private.txt")
        }

        let captured = headers.read()
        let expectedBasic = Data("reader:\(password)".utf8).base64EncodedString()
        #expect(captured == ["Basic \(expectedBasic)", "Bearer \(password)", nil])
        let error = WebDAVResourceError(code: .unauthorized, statusCode: 401)
        for description in [
            String(describing: basic),
            String(reflecting: basic),
            String(describing: authentication),
            String(reflecting: authentication),
            String(describing: error),
            error.localizedDescription,
        ] {
            #expect(!description.contains(password))
            #expect(!description.contains(expectedBasic))
        }

        let injectionRequestCount = LockedBox(0)
        MockWebDAVURLProtocol.install { _ in
            injectionRequestCount.withValue { $0 += 1 }
            return .response(statusCode: 200, chunks: [Data()])
        }
        await expectWebDAVError(.invalidCredential) {
            _ = try await provider.read(
                "private.txt",
                authentication: .basic(
                    username: "reader\r\nX-Injected: value",
                    password: "password"
                )
            )
        }
        await expectWebDAVError(.invalidCredential) {
            _ = try await provider.read(
                "private.txt",
                authentication: .bearer(token: "token\r\nX-Injected: value")
            )
        }
        #expect(injectionRequestCount.read() == 0)
    }

    @Test("A Sendable credential closure resolves once per operation and failures are redacted")
    func credentialClosure() async throws {
        let calls = LockedBox(0)
        let seenHeaders = LockedBox<[String?]>([])
        MockWebDAVURLProtocol.install { request in
            seenHeaders.withValue {
                $0.append(request.value(forHTTPHeaderField: "Authorization"))
            }
            return .response(statusCode: 404)
        }
        let authentication = WebDAVAuthentication(provider: {
            calls.withValue { $0 += 1 }
            return .bearer(token: "ephemeral-token")
        })
        let provider = try makeProvider()

        await expectWebDAVError(.notFound) {
            _ = try await provider.stat("missing", authentication: authentication)
        }
        await expectWebDAVError(.notFound) {
            _ = try await provider.read("missing", authentication: authentication)
        }
        #expect(calls.read() == 2)
        #expect(seenHeaders.read() == [
            "Bearer ephemeral-token", "Bearer ephemeral-token",
        ])

        let secret = "provider-error-secret"
        let failing = WebDAVAuthentication(provider: {
            throw SecretCredentialError(text: secret)
        })
        do {
            _ = try await provider.read("missing", authentication: failing)
            Issue.record("Expected credential resolution to fail")
        } catch let error as WebDAVResourceError {
            #expect(error.code == .credentialUnavailable)
            #expect(!String(describing: error).contains(secret))
            #expect(!error.localizedDescription.contains(secret))
        }
    }

    @Test("Cross-origin, escaping, over-deep, and queried href values are rejected")
    func unsafeHrefs() async throws {
        let hrefs = [
            "https://evil.test/dav/root/stolen",
            "/dav/root/%2e%2e/secret",
            "/dav/sibling/secret",
            "/dav/root/a/b",
            "/dav/root/file?credential=leak",
        ]
        let provider = try makeProvider()

        for href in hrefs {
            let xml = multistatus(responses: [responseXML(href: href)])
            MockWebDAVURLProtocol.install { _ in
                .response(statusCode: 207, chunks: [Data(xml.utf8)])
            }
            await expectWebDAVError(.unsafeURL) {
                _ = try await provider.list()
            }
        }
    }

    @Test("Base paths, request paths, final URLs, and redirects stay inside the configured root")
    func URLConfinement() async throws {
        #expect(throws: WebDAVResourceError.self) {
            try WebDAVResourceProvider(baseURL: URL(string: "ftp://example.test/dav/")!)
        }
        #expect(throws: WebDAVResourceError.self) {
            try WebDAVResourceProvider(
                baseURL: URL(string: "https://user:password@example.test/dav/")!
            )
        }

        let requestCount = LockedBox(0)
        MockWebDAVURLProtocol.install { _ in
            requestCount.withValue { $0 += 1 }
            return .response(statusCode: 200, chunks: [Data("unexpected".utf8)])
        }
        let provider = try makeProvider()
        for path in ["../secret", "%2e%2e/secret", "a//b", "a/%2f/b", "/absolute"] {
            await expectWebDAVError(.invalidPath) {
                _ = try await provider.read(path)
            }
        }
        #expect(requestCount.read() == 0)

        MockWebDAVURLProtocol.install { _ in
            .response(
                statusCode: 302,
                headers: ["Location": "https://evil.test/steal"]
            )
        }
        await expectWebDAVError(.unsafeRedirect) {
            _ = try await provider.read("redirect")
        }

        MockWebDAVURLProtocol.install { request in
            .response(
                statusCode: 200,
                responseURL: URL(string: "https://evil.test/data")!,
                chunks: [Data("secret".utf8)]
            )
        }
        await expectWebDAVError(.unsafeURL) {
            _ = try await provider.read("final-url")
        }

        let conditionalRequestCount = LockedBox(0)
        MockWebDAVURLProtocol.install { _ in
            conditionalRequestCount.withValue { $0 += 1 }
            return .response(statusCode: 200, chunks: [Data()])
        }
        await expectWebDAVError(.invalidMetadata) {
            _ = try await provider.read(
                "file",
                ifMatchETag: "\"value\"\r\nX-Injected: secret"
            )
        }

        for invalidValidator in [
            "W/\"weak\"",
            "*",
            "\"one\", \"two\"",
            "\"embedded\"quote\"",
            "\"tab\tvalue\"",
            "\"delete\u{7F}value\"",
            "unterminated",
        ] {
            await expectWebDAVError(.invalidMetadata) {
                _ = try await provider.read(
                    "file",
                    ifMatchETag: invalidValidator
                )
            }
        }
        #expect(conditionalRequestCount.read() == 0)
    }

    @Test("Property, entry, XML-depth, and GET size limits are enforced")
    func limits() async throws {
        let oversizedProperties = try makeProvider(
            limits: WebDAVResourceLimits(maximumPropertyResponseByteCount: 4)
        )
        MockWebDAVURLProtocol.install { _ in
            .response(
                statusCode: 207,
                headers: ["Content-Length": "100"],
                chunks: [Data("tiny".utf8)]
            )
        }
        await expectWebDAVError(.responseTooLarge) {
            _ = try await oversizedProperties.list()
        }

        let twoResponses = multistatus(responses: [
            responseXML(href: "/dav/root/"),
            responseXML(href: "/dav/root/child"),
        ])
        let oneEntry = try makeProvider(
            limits: WebDAVResourceLimits(maximumEntryCount: 1)
        )
        MockWebDAVURLProtocol.install { _ in
            .response(statusCode: 207, chunks: [Data(twoResponses.utf8)])
        }
        await expectWebDAVError(.entryLimitExceeded) {
            _ = try await oneEntry.list()
        }

        let shallow = try makeProvider(
            limits: WebDAVResourceLimits(maximumXMLDepth: 3)
        )
        MockWebDAVURLProtocol.install { _ in
            .response(statusCode: 207, chunks: [Data(Self.depthZeroXML.utf8)])
        }
        await expectWebDAVError(.invalidXML) {
            _ = try await shallow.list()
        }

        let smallRead = try makeProvider(
            limits: WebDAVResourceLimits(maximumReadByteCount: 4)
        )
        MockWebDAVURLProtocol.install { _ in
            .response(statusCode: 200, chunks: [Data("12345".utf8)])
        }
        await expectWebDAVError(.responseTooLarge) {
            _ = try await smallRead.read("large")
        }
    }

    @Test("401, 403, 404, 412, and 5xx statuses remain distinct")
    func typedHTTPStatuses() async throws {
        let provider = try makeProvider()
        for (status, expected) in [
            (401, WebDAVResourceError.Code.unauthorized),
            (403, .forbidden),
            (404, .notFound),
            (412, .preconditionFailed),
            (503, .serverError),
        ] {
            MockWebDAVURLProtocol.install { _ in .response(statusCode: status) }
            do {
                _ = try await provider.read("status")
                Issue.record("Expected HTTP \(status) to fail")
            } catch let error as WebDAVResourceError {
                #expect(error.code == expected)
                #expect(error.statusCode == status)
            }
        }
    }

    @Test("Cancellation and timeout terminate in-flight transfers without response leakage")
    func cancellationAndTimeout() async throws {
        let provider = try makeProvider()
        MockWebDAVURLProtocol.install { _ in
            .response(statusCode: 200, neverCompletes: true)
        }
        let task = Task { try await provider.read("waiting") }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected cancellation result: \(error)")
        }

        MockWebDAVURLProtocol.install { _ in .failure(.timedOut) }
        await expectWebDAVError(.timeout) {
            _ = try await provider.read("timeout")
        }

        MockWebDAVURLProtocol.install { _ in
            .response(statusCode: 200, chunks: [Data("last".utf8)])
        }
        do {
            _ = try await provider.readChunks("cancel-at-final-callback") { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
            Issue.record("Expected final-callback cancellation")
        } catch is CancellationError {
            // Expected: a receiver cannot turn a cancelled transfer into success.
        } catch {
            Issue.record("Unexpected final-callback cancellation result: \(error)")
        }
    }

    @Test("Malformed XML and entity declarations are rejected without expansion")
    func XMLSafety() async throws {
        let provider = try makeProvider()
        for xml in [
            "<not-multistatus/>",
            "<!DOCTYPE x [<!ENTITY secret 'expanded'>]><d:multistatus xmlns:d='DAV:'/>",
            "<d:multistatus xmlns:d='DAV:'><d:response></d:multistatus>",
        ] {
            MockWebDAVURLProtocol.install { _ in
                .response(statusCode: 207, chunks: [Data(xml.utf8)])
            }
            do {
                _ = try await provider.list()
                Issue.record("Expected malformed XML to fail")
            } catch let error as WebDAVResourceError {
                #expect(error.code == .invalidXML || error.code == .invalidMultistatus)
                #expect(!String(describing: error).contains("expanded"))
            }
        }
    }

    @Test("Remote text loading trusts only a stable ETag around one bounded GET")
    func textDocumentStableETag() async throws {
        let methods = LockedBox<[String]>([])
        let validators = LockedBox<[String?]>([])
        MockWebDAVURLProtocol.install { request in
            methods.withValue { $0.append(request.httpMethod ?? "") }
            validators.withValue {
                $0.append(request.value(forHTTPHeaderField: "If-Match"))
            }
            if request.httpMethod == "HEAD" {
                return .response(
                    statusCode: 200,
                    headers: [
                        "Content-Length": "6",
                        "Last-Modified": "Tue, 15 Nov 1994 12:45:26 GMT",
                        "ETag": "\"stable-v1\"",
                        "Content-Type": "text/plain",
                    ]
                )
            }
            return .response(
                statusCode: 200,
                headers: ["Content-Length": "6"],
                chunks: [Data("hello\n".utf8)]
            )
        }

        let snapshot = try await WebDAVTextDocumentLoader().load(
            "notes.txt",
            from: makeProvider()
        )
        #expect(snapshot.relativePath == "notes.txt")
        #expect(snapshot.document.text == "hello\n")
        #expect(snapshot.document.format == .utf8)
        #expect(snapshot.version.etag == "\"stable-v1\"")
        #expect(snapshot.version.fingerprint.byteCount == 6)
        #expect(methods.read() == ["HEAD", "GET", "HEAD"])
        #expect(validators.read() == [nil, "\"stable-v1\"", nil])
    }

    @Test("Remote text loading binds HEAD and GET to one final resource path")
    func textDocumentFinalResourceIdentity() async throws {
        let methods = LockedBox<[String]>([])
        MockWebDAVURLProtocol.install { request in
            methods.withValue { $0.append(request.httpMethod ?? "") }
            if request.httpMethod == "HEAD" {
                return .response(
                    statusCode: 200,
                    headers: [
                        "Content-Length": "5",
                        "ETag": "\"stable\"",
                        "Content-Type": "text/plain",
                    ],
                    responseURL: URL(string: "https://example.test/dav/root/head-target.txt")!
                )
            }
            return .response(
                statusCode: 200,
                headers: ["Content-Length": "5"],
                responseURL: URL(string: "https://example.test/dav/root/get-target.txt")!,
                chunks: [Data("alpha".utf8)]
            )
        }

        await expectWebDAVTextError(.resourceChangedDuringRead) {
            _ = try await WebDAVTextDocumentLoader().load(
                "alias.txt",
                from: makeProvider()
            )
        }
        #expect(methods.read() == ["HEAD", "GET"])
    }

    @Test("Remote text loading double-hashes when the server lacks a strong ETag")
    func textDocumentFallbackDigest() async throws {
        let methods = LockedBox<[String]>([])
        MockWebDAVURLProtocol.install { request in
            methods.withValue { $0.append(request.httpMethod ?? "") }
            if request.httpMethod == "HEAD" {
                return .response(
                    statusCode: 200,
                    headers: [
                        "Content-Length": "5",
                        "Last-Modified": "Tue, 15 Nov 1994 12:45:26 GMT",
                        "ETag": "W/\"weak-v1\"",
                        "Content-Type": "text/plain",
                    ]
                )
            }
            return .response(
                statusCode: 200,
                headers: ["Content-Length": "5"],
                chunks: [Data("alpha".utf8)]
            )
        }

        let snapshot = try await WebDAVTextDocumentLoader().load(
            "notes.txt",
            from: makeProvider(
                limits: WebDAVResourceLimits(transferChunkByteCount: 2)
            )
        )
        #expect(snapshot.document.text == "alpha")
        #expect(snapshot.version.etag == nil)
        #expect(methods.read() == ["HEAD", "GET", "HEAD", "GET", "HEAD"])
    }

    @Test("Remote text loading treats malformed entity-tag metadata as untrusted")
    func textDocumentMalformedETagFallback() async throws {
        let methods = LockedBox<[String]>([])
        let validators = LockedBox<[String?]>([])
        MockWebDAVURLProtocol.install { request in
            methods.withValue { $0.append(request.httpMethod ?? "") }
            validators.withValue {
                $0.append(request.value(forHTTPHeaderField: "If-Match"))
            }
            if request.httpMethod == "HEAD" {
                return .response(
                    statusCode: 200,
                    headers: [
                        "Content-Length": "5",
                        "ETag": "\"one\", \"two\"",
                        "Content-Type": "text/plain",
                    ]
                )
            }
            return .response(
                statusCode: 200,
                headers: ["Content-Length": "5"],
                chunks: [Data("alpha".utf8)]
            )
        }

        let snapshot = try await WebDAVTextDocumentLoader().load(
            "notes.txt",
            from: makeProvider()
        )
        #expect(snapshot.document.text == "alpha")
        #expect(snapshot.version.etag == nil)
        #expect(methods.read() == ["HEAD", "GET", "HEAD", "GET", "HEAD"])
        #expect(validators.read().allSatisfy { $0 == nil })
    }

    @Test("Remote text loading fails closed when metadata or fallback bytes change")
    func textDocumentChangeDetection() async throws {
        let headCount = LockedBox(0)
        MockWebDAVURLProtocol.install { request in
            if request.httpMethod == "HEAD" {
                let count = headCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                return .response(
                    statusCode: 200,
                    headers: [
                        "Content-Length": "5",
                        "Last-Modified": "Tue, 15 Nov 1994 12:45:26 GMT",
                        "ETag": count == 1 ? "\"v1\"" : "\"v2\"",
                        "Content-Type": "text/plain",
                    ]
                )
            }
            return .response(
                statusCode: 200,
                headers: ["Content-Length": "5"],
                chunks: [Data("alpha".utf8)]
            )
        }
        await expectWebDAVTextError(.resourceChangedDuringRead) {
            _ = try await WebDAVTextDocumentLoader().load(
                "notes.txt",
                from: makeProvider()
            )
        }

        let getCount = LockedBox(0)
        MockWebDAVURLProtocol.install { request in
            if request.httpMethod == "HEAD" {
                return .response(
                    statusCode: 200,
                    headers: [
                        "Content-Length": "5",
                        "Last-Modified": "Tue, 15 Nov 1994 12:45:26 GMT",
                        "Content-Type": "text/plain",
                    ]
                )
            }
            let count = getCount.withValue { value -> Int in
                value += 1
                return value
            }
            return .response(
                statusCode: 200,
                headers: ["Content-Length": "5"],
                chunks: [Data((count == 1 ? "alpha" : "omega").utf8)]
            )
        }
        await expectWebDAVTextError(.resourceChangedDuringRead) {
            _ = try await WebDAVTextDocumentLoader().load(
                "notes.txt",
                from: makeProvider()
            )
        }
    }

    @Test("Remote text preflight rejects collections and declared oversize files before GET")
    func textDocumentPreflight() async throws {
        let methods = LockedBox<[String]>([])
        MockWebDAVURLProtocol.install { request in
            methods.withValue { $0.append(request.httpMethod ?? "") }
            return .response(
                statusCode: 200,
                headers: [
                    "Content-Length": "8",
                    "Content-Type": "text/plain",
                ]
            )
        }
        await expectWebDAVTextError(.byteLimitExceeded) {
            _ = try await WebDAVTextDocumentLoader(
                limits: DecodedTextDocumentLimits(maximumByteCount: 4)
            ).load("large.txt", from: makeProvider())
        }
        #expect(methods.read() == ["HEAD"])

        methods.withValue { $0.removeAll() }
        MockWebDAVURLProtocol.install { request in
            methods.withValue { $0.append(request.httpMethod ?? "") }
            return .response(
                statusCode: 200,
                headers: [
                    "Content-Length": "0",
                    "Content-Type": "httpd/unix-directory",
                ]
            )
        }
        await expectWebDAVTextError(.notFile) {
            _ = try await WebDAVTextDocumentLoader().load(
                "folder",
                from: makeProvider()
            )
        }
        #expect(methods.read() == ["HEAD"])
    }

    @Test("Remote text loading rejects a body that contradicts HEAD length")
    func textDocumentLengthMismatch() async throws {
        let methods = LockedBox<[String]>([])
        MockWebDAVURLProtocol.install { request in
            methods.withValue { $0.append(request.httpMethod ?? "") }
            if request.httpMethod == "HEAD" {
                return .response(
                    statusCode: 200,
                    headers: [
                        "Content-Length": "6",
                        "ETag": "\"stable-v1\"",
                        "Content-Type": "text/plain",
                    ]
                )
            }
            return .response(
                statusCode: 200,
                headers: ["Content-Length": "5"],
                chunks: [Data("short".utf8)]
            )
        }

        await expectWebDAVTextError(.responseLengthMismatch) {
            _ = try await WebDAVTextDocumentLoader().load(
                "notes.txt",
                from: makeProvider()
            )
        }
        #expect(methods.read() == ["HEAD", "GET"])
    }

    @Test("A failed WebDAV If-Match is reported as an in-flight text change")
    func textDocumentConditionalReadFailure() async throws {
        let methods = LockedBox<[String]>([])
        MockWebDAVURLProtocol.install { request in
            methods.withValue { $0.append(request.httpMethod ?? "") }
            if request.httpMethod == "HEAD" {
                return .response(
                    statusCode: 200,
                    headers: [
                        "Content-Length": "5",
                        "ETag": "\"v1\"",
                        "Content-Type": "text/plain",
                    ]
                )
            }
            #expect(request.value(forHTTPHeaderField: "If-Match") == "\"v1\"")
            return .response(statusCode: 412)
        }

        await expectWebDAVTextError(.resourceChangedDuringRead) {
            _ = try await WebDAVTextDocumentLoader().load(
                "notes.txt",
                from: makeProvider()
            )
        }
        #expect(methods.read() == ["HEAD", "GET"])
    }

    private static let depthZeroXML = multistatus(responses: [
        """
        <d:response>
          <d:href>/dav/root/</d:href>
          <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        </d:response>
        """,
    ])

    private static let depthOneXML = multistatus(responses: [
        """
        <d:response>
          <d:href>https://example.test/dav/root/Folder/</d:href>
          <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        </d:response>
        """,
        """
        <d:response>
          <d:href>/dav/root/</d:href>
          <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        </d:response>
        """,
        """
        <d:response>
          <d:href>/dav/root/%E6%96%87%E4%BB%B6%20name.txt</d:href>
          <d:propstat><d:prop>
            <d:resourcetype/>
            <d:getcontentlength>5</d:getcontentlength>
            <d:getlastmodified>Tue, 15 Nov 1994 12:45:26 GMT</d:getlastmodified>
            <x:getetag xmlns:x="urn:not-dav">ignored</x:getetag>
            <d:getetag>"unicode-etag"</d:getetag>
          </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        </d:response>
        """,
    ])
}

private let baseURL = URL(string: "https://example.test/dav/root/")!

private func makeProvider(
    limits: WebDAVResourceLimits = .default
) throws -> WebDAVResourceProvider {
    try WebDAVResourceProvider(
        baseURL: baseURL,
        configuration: mockConfiguration(),
        limits: limits
    )
}

private func mockConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockWebDAVURLProtocol.self]
    return configuration
}

private func multistatus(responses: [String]) -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:">
    \(responses.joined(separator: "\n"))
    </d:multistatus>
    """
}

private func responseXML(href: String) -> String {
    """
    <d:response>
      <d:href>\(href.replacingOccurrences(of: "&", with: "&amp;"))</d:href>
      <d:propstat><d:prop><d:resourcetype/></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
    </d:response>
    """
}

private func expectWebDAVError(
    _ expected: WebDAVResourceError.Code,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected WebDAV error \(expected)")
    } catch let error as WebDAVResourceError {
        #expect(error.code == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func expectWebDAVTextError(
    _ expected: WebDAVTextDocumentError.Code,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected WebDAV text error \(expected)")
    } catch let error as WebDAVTextDocumentError {
        #expect(error.code == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private actor DAVChunkCollector {
    private var chunks: [Data] = []

    func append(_ chunk: Data) {
        chunks.append(chunk)
    }

    func values() -> [Data] {
        chunks
    }
}

private struct SecretCredentialError: Error, CustomStringConvertible {
    let text: String
    var description: String { text }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct MockWebDAVStub: Sendable {
    let statusCode: Int?
    let headers: [String: String]
    let chunks: [Data]
    let responseURL: URL?
    let neverCompletes: Bool
    let failureCode: URLError.Code?

    static func response(
        statusCode: Int,
        headers: [String: String] = [:],
        responseURL: URL? = nil,
        chunks: [Data] = [],
        neverCompletes: Bool = false
    ) -> Self {
        Self(
            statusCode: statusCode,
            headers: headers,
            chunks: chunks,
            responseURL: responseURL,
            neverCompletes: neverCompletes,
            failureCode: nil
        )
    }

    static func failure(_ code: URLError.Code) -> Self {
        Self(
            statusCode: nil,
            headers: [:],
            chunks: [],
            responseURL: nil,
            neverCompletes: false,
            failureCode: code
        )
    }
}

private final class MockWebDAVURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> MockWebDAVStub

    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var handler: Handler = { _ in
        .failure(.badServerResponse)
    }

    private let stateLock = NSLock()
    private var finished = false

    static func install(_ newHandler: @escaping Handler) {
        handlerLock.lock()
        handler = newHandler
        handlerLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.handlerLock.lock()
        let handler = Self.handler
        Self.handlerLock.unlock()
        let stub = handler(request)

        if let failureCode = stub.failureCode {
            finish { client in
                client.urlProtocol(self, didFailWithError: URLError(failureCode))
            }
            return
        }
        guard let url = stub.responseURL ?? request.url,
              let statusCode = stub.statusCode,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: stub.headers
              ) else {
            finish { client in
                client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            }
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if stub.neverCompletes { return }
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        finish { client in client.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        finish { client in
            client.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
    }

    private func finish(_ body: (URLProtocolClient) -> Void) {
        stateLock.lock()
        guard !finished else {
            stateLock.unlock()
            return
        }
        finished = true
        let client = client
        stateLock.unlock()
        if let client { body(client) }
    }
}
