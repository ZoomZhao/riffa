import AppKit
import Foundation
import RiffaCore
import SwiftUI
import UniformTypeIdentifiers

private struct ConnectedWebDAVSession: Sendable {
    let provider: WebDAVResourceProvider
    let authentication: WebDAVAuthentication?
}

private struct WebDAVTextComparisonPresentation: Identifiable, Sendable {
    let id = UUID()
    let leftPath: String
    let rightPath: String
    let leftVersion: WebDAVTextDocumentVersion
    let rightVersion: WebDAVTextDocumentVersion
    let result: TextDiffResult
}

private enum WebDAVCredentialResolutionError: Error, LocalizedError {
    case missingPassword
    case missingBearerToken

    var errorDescription: String? {
        switch self {
        case .missingPassword:
            RiffaLocalization.string(
                "Enter a password or save one in Keychain for this server and username."
            )
        case .missingBearerToken:
            RiffaLocalization.string(
                "Enter a Bearer token or save one in Keychain for this server."
            )
        }
    }
}

private func webDAVErrorMessage(_ error: any Error) -> String {
    if let error = error as? WebDAVCredentialIdentityError {
        return switch error.code {
        case .invalidBaseURL:
            RiffaLocalization.string(
                "The WebDAV credential URL is invalid."
            )
        case .insecureTransport:
            RiffaLocalization.string(
                "Stored WebDAV credentials require HTTPS."
            )
        case .usernameRequired:
            RiffaLocalization.string(
                "A username is required for Basic authentication."
            )
        case .usernameNotAllowed:
            RiffaLocalization.string(
                "Bearer authentication does not use a username."
            )
        }
    }

    if let error = error as? WebDAVTextDocumentError {
        return switch error.code {
        case .notFile:
            RiffaLocalization.string(
                "The WebDAV text resource is not a regular file."
            )
        case .byteLimitExceeded:
            RiffaLocalization.string(
                "The WebDAV text resource exceeds the configured byte limit."
            )
        case .resourceChangedDuringRead:
            RiffaLocalization.string(
                "The WebDAV text resource changed while it was being read."
            )
        case .responseLengthMismatch:
            RiffaLocalization.string(
                "The WebDAV response length does not match its metadata."
            )
        }
    }

    if let error = error as? WebDAVTextComparisonError {
        return switch error.code {
        case .invalidLimits:
            RiffaLocalization.string(
                "The WebDAV text comparison limits are invalid."
            )
        case .byteLimitExceeded:
            RiffaLocalization.string(
                "A WebDAV text document exceeds the comparison byte limit."
            )
        case .lineCountExceeded:
            RiffaLocalization.string(
                "A WebDAV text document exceeds the logical line limit."
            )
        case .lineByteLimitExceeded:
            RiffaLocalization.string(
                "A WebDAV text document contains a line that exceeds the UTF-8 byte limit."
            )
        case .lineCharacterLimitExceeded:
            RiffaLocalization.string(
                "A WebDAV text document contains a line that exceeds the character limit."
            )
        case .publishedLineLimitExceeded:
            RiffaLocalization.string(
                "The WebDAV text comparison exceeds the published line limit."
            )
        }
    }

    if let error = error as? WebDAVTextHTMLReportError {
        return switch error.code {
        case .invalidLimits:
            RiffaLocalization.string(
                "The WebDAV text report limits are invalid."
            )
        case .rowLimitExceeded:
            RiffaLocalization.string(
                "The WebDAV text report exceeds the row limit."
            )
        case .outputByteLimitExceeded:
            RiffaLocalization.string(
                "The WebDAV text report exceeds the UTF-8 output limit."
            )
        }
    }

    if let error = error as? WebDAVResourceError {
        return webDAVResourceErrorMessage(error)
    }

    return error.localizedDescription
}

private func webDAVResourceErrorMessage(
    _ error: WebDAVResourceError
) -> String {
    switch error.code {
    case .invalidBaseURL:
        return RiffaLocalization.string("The WebDAV base URL is invalid")
    case .invalidPath:
        return RiffaLocalization.string(
            "The relative WebDAV path is invalid"
        )
    case .unsafeURL:
        return RiffaLocalization.string(
            "The server returned a URL outside the configured WebDAV base"
        )
    case .unsafeRedirect:
        return RiffaLocalization.string(
            "The WebDAV request attempted an unsafe redirect"
        )
    case .invalidCredential:
        return RiffaLocalization.string("The WebDAV credential is invalid")
    case .credentialUnavailable:
        return RiffaLocalization.string(
            "A WebDAV credential could not be obtained"
        )
    case .unauthorized:
        return RiffaLocalization.string(
            "WebDAV authentication is required"
        )
    case .forbidden:
        if let path = error.relativePath {
            return String(
                localized: "The WebDAV resource is forbidden at \(path)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return RiffaLocalization.string("The WebDAV resource is forbidden")
    case .notFound:
        if let path = error.relativePath {
            return String(
                localized: "The WebDAV resource was not found at \(path)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return RiffaLocalization.string("The WebDAV resource was not found")
    case .preconditionFailed:
        if let path = error.relativePath {
            return String(
                localized: "The WebDAV resource changed before the conditional request completed at \(path)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return RiffaLocalization.string(
            "The WebDAV resource changed before the conditional request completed"
        )
    case .serverError:
        return RiffaLocalization.string(
            "The WebDAV server returned an error"
        )
    case .unexpectedStatus:
        return RiffaLocalization.string(
            "The WebDAV server returned an unexpected status"
        )
    case .invalidResponse:
        return RiffaLocalization.string("The WebDAV response is invalid")
    case .invalidXML:
        return RiffaLocalization.string(
            "The WebDAV XML response is invalid"
        )
    case .invalidMultistatus:
        return RiffaLocalization.string(
            "The WebDAV multistatus response is invalid"
        )
    case .invalidMetadata:
        if let path = error.relativePath {
            return String(
                localized: "The WebDAV metadata is invalid at \(path)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return RiffaLocalization.string("The WebDAV metadata is invalid")
    case .responseTooLarge:
        return RiffaLocalization.string(
            "The WebDAV response exceeded its configured limit"
        )
    case .entryLimitExceeded:
        return RiffaLocalization.string(
            "The WebDAV response contained too many entries"
        )
    case .timeout:
        return RiffaLocalization.string("The WebDAV request timed out")
    case .transportFailure:
        return RiffaLocalization.string("The WebDAV transport failed")
    }
}

private actor AtomicWebDAVDownload {
    private let destinationURL: URL
    private let temporaryURL: URL
    private var fileHandle: FileHandle?

    init(destinationURL: URL) throws {
        self.destinationURL = destinationURL.standardizedFileURL
        temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".riffa-\(UUID().uuidString).download")
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            fileHandle = try FileHandle(forWritingTo: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func append(_ data: Data) throws {
        try Task.checkCancellation()
        guard let fileHandle else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileHandle.write(contentsOf: data)
    }

    func commit() throws {
        try Task.checkCancellation()
        guard let fileHandle else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileHandle.synchronize()
        // Synchronization may block long enough for the user to cancel. Check
        // again immediately before closing and publishing the temporary file.
        try Task.checkCancellation()
        try fileHandle.close()
        self.fileHandle = nil
        try Task.checkCancellation()

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL
            )
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    func discard() {
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager.default.removeItem(at: temporaryURL)
    }
}

@MainActor
private final class WebDAVBrowserToolModel: ObservableObject {
    enum TextComparisonSide: Sendable {
        case left
        case right
    }

    enum AuthenticationMode: String, CaseIterable, Identifiable {
        case none = "None"
        case basic = "Basic"
        case bearer = "Bearer"

        var id: Self { self }
    }

    nonisolated private static let previewLimit = 2 * 1_024 * 1_024
    nonisolated private static let hexLimit = 4 * 1_024

    @Published var baseURLText = "" {
        didSet {
            if baseURLText != oldValue, !oldValue.isEmpty {
                clearSecretFields()
            }
            if baseURLText != oldValue {
                isCredentialSaved = false
            }
        }
    }
    @Published var authenticationMode: AuthenticationMode = .none {
        didSet {
            if authenticationMode != oldValue {
                clearSecretFields()
                isCredentialSaved = false
            }
        }
    }
    @Published var username = "" {
        didSet {
            if username != oldValue, !oldValue.isEmpty {
                password = ""
            }
            if username != oldValue {
                isCredentialSaved = false
            }
        }
    }
    @Published var password = ""
    @Published var bearerToken = ""
    @Published var rememberInKeychain = false
    @Published var search = ""
    @Published var selection: String?
    @Published var errorMessage: String?

    @Published private(set) var entries: [WebDAVResourceEntry] = []
    @Published private(set) var currentPath = ""
    @Published private(set) var connectedURL: URL?
    @Published private(set) var preview = RiffaLocalization.string(
        "Connect to a WebDAV collection to browse it read-only."
    )
    @Published private(set) var isWorking = false
    @Published private(set) var isCredentialSaved = false
    @Published private(set) var comparisonLeftPath: String?
    @Published private(set) var comparisonRightPath: String?
    @Published var textComparison: WebDAVTextComparisonPresentation?

    private var connection: ConnectedWebDAVSession?
    private var operationGeneration = 0
    private var previewGeneration = 0
    private var activeOperationID: UUID?
    private var operationTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private let credentialStore = WebDAVCredentialStore()
    private let textComparisonEngine = WebDAVTextComparisonEngine()

    var visibleEntries: [WebDAVResourceEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter {
            $0.relativePath.localizedCaseInsensitiveContains(search)
        }
    }

    var selectedEntry: WebDAVResourceEntry? {
        guard let selection else { return nil }
        return visibleEntries.first { $0.id == selection }
    }

    var canConnect: Bool {
        guard !baseURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        switch authenticationMode {
        case .none:
            return true
        case .basic:
            return !username.isEmpty
        case .bearer:
            return true
        }
    }

    var canSaveCredential: Bool {
        guard rememberInKeychain, credentialTransportWarning == nil,
              (try? credentialIdentity()) != nil else {
            return false
        }
        return switch authenticationMode {
        case .none: false
        case .basic: !password.isEmpty
        case .bearer: !bearerToken.isEmpty
        }
    }

    var canForgetCredential: Bool {
        isCredentialSaved && (try? credentialIdentity()) != nil
    }

    var canMarkSelectedForTextComparison: Bool {
        selectedEntry?.kind == .file && !isWorking
    }

    var canCompareMarkedTextFiles: Bool {
        connection != nil
            && comparisonLeftPath != nil
            && comparisonRightPath != nil
            && comparisonLeftPath != comparisonRightPath
            && !isWorking
    }

    var credentialTransportWarning: String? {
        guard authenticationMode != .none else { return nil }
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            return RiffaLocalization.string(
                "Basic and Bearer credentials require HTTPS."
            )
        }
        return nil
    }

    func connect() {
        guard !isWorking, canConnect else { return }
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            errorMessage = RiffaLocalization.string(
                "Enter a valid absolute HTTP or HTTPS URL."
            )
            return
        }
        guard credentialTransportWarning == nil else {
            errorMessage = RiffaLocalization.string(
                "Riffa will not send Basic or Bearer credentials over a non-HTTPS WebDAV connection."
            )
            return
        }

        do {
            let provider = try WebDAVResourceProvider(baseURL: url)
            let candidate = ConnectedWebDAVSession(
                provider: provider,
                authentication: try makeAuthentication(for: provider.baseURL)
            )
            invalidatePreview(
                replacement: RiffaLocalization.string(
                    "Connecting to the WebDAV collection…"
                )
            )
            let operation = beginOperation()
            operationTask = Task { [weak self] in
                guard let self else { return }
                defer { finishOperation(operation.id) }
                do {
                    let loaded = try await candidate.provider.list(
                        "",
                        authentication: candidate.authentication
                    )
                    try Task.checkCancellation()
                    guard operation.generation == operationGeneration else { return }
                    connection = candidate
                    connectedURL = candidate.provider.baseURL
                    currentPath = ""
                    selection = nil
                    entries = loaded
                    clearTextComparisonSelection()
                    preview = loaded.isEmpty
                        ? RiffaLocalization.string(
                            "This collection is empty."
                        )
                        : RiffaLocalization.string(
                            "Select a remote file to preview it."
                        )
                } catch is CancellationError {
                    return
                } catch {
                    guard operation.generation == operationGeneration else { return }
                    errorMessage = webDAVErrorMessage(error)
                }
            }
        } catch {
            errorMessage = webDAVErrorMessage(error)
        }
    }

    func refresh() {
        guard !isWorking, let connection else { return }
        load(path: currentPath, connection: connection)
    }

    func openSelectedCollection() {
        guard let connection,
              let entry = selectedEntry,
              entry.kind == .collection
        else { return }
        load(path: entry.relativePath, connection: connection)
    }

    func goUp() {
        guard let connection, !currentPath.isEmpty else { return }
        var components = currentPath.split(separator: "/").map(String.init)
        components.removeLast()
        load(path: components.joined(separator: "/"), connection: connection)
    }

    func disconnect() {
        shutdown()
        preview = RiffaLocalization.string(
            "Connect to a WebDAV collection to browse it read-only."
        )
    }

    func shutdown() {
        cancelCurrentOperation()
        invalidatePreview()
        connection = nil
        connectedURL = nil
        currentPath = ""
        selection = nil
        entries = []
        clearTextComparisonSelection()
        clearSecretFields()
    }

    func markSelectedForTextComparison(_ side: TextComparisonSide) {
        guard canMarkSelectedForTextComparison,
              let path = selectedEntry?.relativePath else { return }
        switch side {
        case .left:
            comparisonLeftPath = path
        case .right:
            comparisonRightPath = path
        }
        textComparison = nil
    }

    func compareMarkedTextFiles() {
        guard canCompareMarkedTextFiles,
              let connection,
              let leftPath = comparisonLeftPath,
              let rightPath = comparisonRightPath else { return }

        invalidatePreview(
            replacement: RiffaLocalization.string(
                "Preview paused while comparing remote text…"
            )
        )
        let engine = textComparisonEngine
        let operation = beginOperation()
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                finishOperation(operation.id)
                if self.connection != nil {
                    refreshPreview()
                }
            }
            do {
                let loader = WebDAVTextDocumentLoader(limits: engine.documentLimits)

                // Read and validate each side sequentially. This prevents two
                // transport-scale Data/decoder peaks from growing in parallel.
                let leftSnapshot = try await loader.load(
                    leftPath,
                    from: connection.provider,
                    authentication: connection.authentication
                )
                let left = try await engine.validate(leftSnapshot)
                try Task.checkCancellation()

                let rightSnapshot = try await loader.load(
                    rightPath,
                    from: connection.provider,
                    authentication: connection.authentication
                )
                let right = try await engine.validate(rightSnapshot)
                try Task.checkCancellation()
                let result = try await engine.compare(left, to: right)
                try Task.checkCancellation()
                guard operation.generation == operationGeneration else { return }
                textComparison = WebDAVTextComparisonPresentation(
                    leftPath: left.snapshot.relativePath,
                    rightPath: right.snapshot.relativePath,
                    leftVersion: left.snapshot.version,
                    rightVersion: right.snapshot.version,
                    result: result
                )
            } catch is CancellationError {
                return
            } catch {
                guard operation.generation == operationGeneration else { return }
                let detail = webDAVErrorMessage(error)
                errorMessage = String(
                    localized: "Could not compare the remote text files: \(detail)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        }
    }

    func saveCredential() {
        guard canSaveCredential else { return }
        do {
            let identity = try credentialIdentity()
            let secret: String = switch authenticationMode {
            case .none: ""
            case .basic: password
            case .bearer: bearerToken
            }
            _ = try credentialStore.save(secret, for: identity)
            isCredentialSaved = true
        } catch {
            errorMessage = webDAVErrorMessage(error)
        }
    }

    func forgetCredential() {
        guard canForgetCredential else { return }
        do {
            let identity = try credentialIdentity()
            _ = try credentialStore.delete(for: identity)
            isCredentialSaved = false
        } catch {
            errorMessage = webDAVErrorMessage(error)
        }
    }

    func refreshCredentialAvailability() {
        guard authenticationMode != .none,
              let identity = try? credentialIdentity() else {
            isCredentialSaved = false
            return
        }
        isCredentialSaved = (try? credentialStore.availability(for: identity)) == .saved
    }

    func cancelCurrentOperation() {
        guard operationTask != nil else {
            activeOperationID = nil
            isWorking = false
            return
        }
        operationGeneration += 1
        operationTask?.cancel()
        // Keep isWorking true until the worker has observed cancellation and
        // completed its cleanup. This prevents overlapping replacement work.
    }

    func refreshPreview() {
        invalidatePreview()
        let generation = previewGeneration
        guard let entry = selectedEntry else {
            preview = RiffaLocalization.string(
                "Select a remote file to preview it."
            )
            return
        }
        guard entry.kind == .file else {
            preview = String(
                localized: """
                Collection

                Path: \(displayPath(entry.relativePath))
                Modified: \(Self.formatDate(entry.modificationDate))
                ETag: \(entry.etag ?? "—")
                """,
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }
        if let length = entry.contentLength, length > Int64(Self.previewLimit) {
            preview = String(
                localized: """
                Preview withheld

                This remote file is \(Self.formatSize(length)); the safe preview limit is 2 MB.
                Export remains an explicit action and uses the provider's bounded read limit.
                """,
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }
        guard let connection else { return }
        let path = entry.relativePath
        preview = RiffaLocalization.string("Downloading bounded preview…")

        previewTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == previewGeneration {
                    previewTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(120))
                let data = try await connection.provider.read(
                    path,
                    maximumByteCount: Self.previewLimit,
                    authentication: connection.authentication
                )
                let value = try await Self.renderPreview(for: data)
                try Task.checkCancellation()
                guard generation == previewGeneration else { return }
                preview = value
            } catch is CancellationError {
                return
            } catch {
                guard generation == previewGeneration else { return }
                let detail = webDAVErrorMessage(error)
                preview = String(
                    localized: "Preview failed: \(detail)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        }
    }

    func exportSelected() {
        guard !isWorking,
              let connection,
              let entry = selectedEntry,
              entry.kind == .file
        else { return }

        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string("Export WebDAV Resource")
        panel.prompt = RiffaLocalization.string("Export")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = URL(fileURLWithPath: entry.relativePath).lastPathComponent
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        let path = entry.relativePath
        let sink: AtomicWebDAVDownload
        do {
            sink = try AtomicWebDAVDownload(destinationURL: outputURL)
        } catch {
            errorMessage = String(
                localized: "Could not prepare the export destination: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }
        let operation = beginOperation()
        operationTask = Task { [weak self] in
            guard let self else {
                await sink.discard()
                return
            }
            defer { finishOperation(operation.id) }
            do {
                _ = try await connection.provider.readChunks(
                    path,
                    authentication: connection.authentication
                ) { chunk in
                    try await sink.append(chunk)
                }
                try Task.checkCancellation()
                try await sink.commit()
            } catch is CancellationError {
                await sink.discard()
            } catch {
                await sink.discard()
                guard operation.generation == operationGeneration else { return }
                let detail = webDAVErrorMessage(error)
                errorMessage = String(
                    localized: "Could not export remote resource: \(detail)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        }
    }

    func displayPath(_ path: String) -> String {
        path.isEmpty ? "/" : "/" + path
    }

    private func load(path: String, connection: ConnectedWebDAVSession) {
        guard !isWorking else { return }
        selection = nil
        invalidatePreview(
            replacement: String(
                localized: "Loading \(displayPath(path))…",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        )

        let operation = beginOperation()
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(operation.id) }
            do {
                let loaded = try await connection.provider.list(
                    path,
                    authentication: connection.authentication
                )
                try Task.checkCancellation()
                guard operation.generation == operationGeneration else { return }
                entries = loaded
                currentPath = path
                connectedURL = connection.provider.baseURL
                preview = loaded.isEmpty
                    ? RiffaLocalization.string("This collection is empty.")
                    : RiffaLocalization.string(
                        "Select a remote file to preview it."
                    )
            } catch is CancellationError {
                return
            } catch {
                guard operation.generation == operationGeneration else { return }
                errorMessage = webDAVErrorMessage(error)
                preview = connectedURL == nil
                    ? RiffaLocalization.string("Connection failed.")
                    : String(
                        localized: "Could not load \(displayPath(path)).",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
            }
        }
    }

    private func beginOperation() -> (id: UUID, generation: Int) {
        precondition(operationTask == nil && activeOperationID == nil && !isWorking)
        operationGeneration += 1
        let id = UUID()
        activeOperationID = id
        isWorking = true
        return (id, operationGeneration)
    }

    private func finishOperation(_ id: UUID) {
        guard activeOperationID == id else { return }
        activeOperationID = nil
        operationTask = nil
        isWorking = false
    }

    private func invalidatePreview(replacement: String? = nil) {
        previewTask?.cancel()
        previewTask = nil
        previewGeneration += 1
        if let replacement {
            preview = replacement
        }
    }

    private func makeAuthentication(for baseURL: URL) throws -> WebDAVAuthentication? {
        switch authenticationMode {
        case .none:
            nil
        case .basic:
            .basic(
                username: username,
                password: try resolveSecret(
                    enteredValue: password,
                    identity: WebDAVCredentialIdentity(
                        baseURL: baseURL,
                        authenticationMode: .basic,
                        username: username
                    ),
                    missingError: .missingPassword
                )
            )
        case .bearer:
            .bearer(
                token: try resolveSecret(
                    enteredValue: bearerToken,
                    identity: WebDAVCredentialIdentity(
                        baseURL: baseURL,
                        authenticationMode: .bearer
                    ),
                    missingError: .missingBearerToken
                )
            )
        }
    }

    private func credentialIdentity() throws -> WebDAVCredentialIdentity {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw WebDAVCredentialIdentityError(code: .invalidBaseURL)
        }
        return switch authenticationMode {
        case .none:
            throw WebDAVCredentialIdentityError(code: .invalidBaseURL)
        case .basic:
            try WebDAVCredentialIdentity(
                baseURL: url,
                authenticationMode: .basic,
                username: username
            )
        case .bearer:
            try WebDAVCredentialIdentity(
                baseURL: url,
                authenticationMode: .bearer
            )
        }
    }

    private func resolveSecret(
        enteredValue: String,
        identity: WebDAVCredentialIdentity,
        missingError: WebDAVCredentialResolutionError
    ) throws -> String {
        if !enteredValue.isEmpty {
            return enteredValue
        }
        switch try credentialStore.read(for: identity) {
        case let .found(secret):
            return secret.resolve()
        case .notFound:
            throw missingError
        }
    }

    private func clearSecretFields() {
        password = ""
        bearerToken = ""
    }

    private func clearTextComparisonSelection() {
        comparisonLeftPath = nil
        comparisonRightPath = nil
        textComparison = nil
    }

    nonisolated private static func formatSize(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    nonisolated private static func formatDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    nonisolated private static func previewText(for data: Data) -> String {
        if let string = String(data: data, encoding: .utf8), isMostlyText(string) {
            return string
        }
        let prefix = Data(data.prefix(hexLimit))
        let suffix = data.count > prefix.count
            ? String(
                localized: "\n\n… \(formatSize(Int64(data.count - prefix.count))) more not shown",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            : ""
        return String(
            localized: "Binary preview (\(formatSize(Int64(data.count))))\n\n",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
            + hexDump(prefix)
            + suffix
    }

    nonisolated private static func renderPreview(for data: Data) async throws -> String {
        try Task.checkCancellation()
        let value = previewText(for: data)
        try Task.checkCancellation()
        return value
    }

    nonisolated private static func isMostlyText(_ string: String) -> Bool {
        guard !string.isEmpty else { return true }
        let sample = string.unicodeScalars.prefix(8_192)
        let acceptable = sample.count { scalar in
            scalar == "\n" || scalar == "\r" || scalar == "\t"
                || !CharacterSet.controlCharacters.contains(scalar)
        }
        return Double(acceptable) / Double(max(sample.count, 1)) >= 0.97
    }

    nonisolated private static func hexDump(_ data: Data) -> String {
        var lines: [String] = []
        for offset in stride(from: 0, to: data.count, by: 16) {
            let end = min(offset + 16, data.count)
            let bytes = Array(data[offset..<end])
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = bytes.map { byte -> Character in
                (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
            }
            lines.append(String(format: "%08X  %@  |%@|", offset, padded, String(ascii)))
        }
        return lines.joined(separator: "\n")
    }
}

struct WebDAVBrowserToolView: View {
    @StateObject private var model = WebDAVBrowserToolModel()
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            RiffaHairline()

            if model.connectedURL == nil {
                ContentUnavailableView {
                    Label("Connect to WebDAV", systemImage: "network")
                } description: {
                    Text("Browse one HTTP(S) collection read-only. Credentials stay in memory unless you explicitly save them in Keychain.")
                } actions: {
                    Button("Connect") { model.connect() }
                        .disabled(!model.canConnect || model.isWorking)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.canvas)
            } else {
                browser
            }

            HStack(spacing: 12) {
                if let url = model.connectedURL {
                    Text(url.absoluteString)
                        .foregroundStyle(theme.inkMuted)
                        .lineLimit(1)
                    Text(model.displayPath(model.currentPath))
                        .riffaText(.mono)
                        .foregroundStyle(theme.inkSubtle)
                } else {
                    Text("Not connected")
                        .foregroundStyle(theme.inkMuted)
                }
                Spacer()
                Text("\(model.visibleEntries.count) of \(model.entries.count) entries")
                    .foregroundStyle(theme.inkSubtle)
                RiffaStatusBadge(
                    "Read-only",
                    systemImage: "lock.shield",
                    tone: .secure
                )
            }
            .riffaText(.caption)
            .padding(.horizontal, RiffaSpacing.sm)
            .frame(minHeight: 34)
            .background(theme.surface(.one))
            .overlay(alignment: .top) {
                RiffaHairline()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .alert(
            "WebDAV error",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: {
                Text(
                    verbatim: model.errorMessage
                        ?? RiffaLocalization.string("Unknown error")
                )
            }
        )
        .sheet(item: $model.textComparison) { comparison in
            WebDAVTextComparisonView(comparison: comparison)
        }
        .onDisappear {
            model.shutdown()
        }
    }

    private var connectionBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("https://server.example.com/dav/", text: $model.baseURLText)
                    .riffaInputSurface(minHeight: 36)
                    .textContentType(.URL)
                Picker("Authentication", selection: $model.authenticationMode) {
                    ForEach(WebDAVBrowserToolModel.AuthenticationMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                    }
                }
                .frame(width: 150)
                Button(
                    model.connectedURL == nil
                        ? RiffaLocalization.string("Connect")
                        : RiffaLocalization.string("Reconnect")
                ) {
                    model.connect()
                }
                .disabled(!model.canConnect || model.isWorking)
                if model.connectedURL != nil {
                    Button("Disconnect") {
                        model.disconnect()
                    }
                    .disabled(model.isWorking)
                }
                if model.isWorking {
                    ProgressView().controlSize(.small)
                    Button("Cancel") {
                        model.cancelCurrentOperation()
                    }
                }
            }

            if model.authenticationMode != .none {
                HStack(alignment: .center, spacing: 8) {
                    switch model.authenticationMode {
                    case .none:
                        EmptyView()
                    case .basic:
                        TextField("Username", text: $model.username)
                            .riffaInputSurface(minHeight: 36)
                        SecureField("Password", text: $model.password)
                            .riffaInputSurface(minHeight: 36)
                    case .bearer:
                        SecureField("Bearer token", text: $model.bearerToken)
                            .riffaInputSurface(minHeight: 36)
                    }

                    Toggle("Remember in Keychain", isOn: $model.rememberInKeychain)
                        .toggleStyle(.checkbox)
                        .help("This only enables the explicit Save button; connecting never writes to Keychain.")
                    Button("Save") {
                        model.saveCredential()
                    }
                    .disabled(!model.canSaveCredential || model.isWorking)
                    Label {
                        Text(
                            verbatim: RiffaLocalization.string(
                                model.isCredentialSaved
                                    ? "Saved"
                                    : "Not saved"
                            )
                        )
                    } icon: {
                        Image(
                            systemName: model.isCredentialSaved
                                ? "checkmark.shield"
                                : "lock.open"
                        )
                    }
                        .font(.caption)
                        .foregroundStyle(
                            model.isCredentialSaved ? theme.success : theme.inkSubtle
                        )
                    Button("Check") {
                        model.refreshCredentialAvailability()
                    }
                    .help("Check Keychain for this exact server and authentication identity")
                    .disabled(model.isWorking)
                    if model.isCredentialSaved {
                        Button("Forget", role: .destructive) {
                            model.forgetCredential()
                        }
                        .disabled(!model.canForgetCredential || model.isWorking)
                    }
                }
            }
            if let warning = model.credentialTransportWarning {
                Label(warning, systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(RiffaSpacing.sm)
        .background(theme.surface(.one))
        .onAppear {
            model.refreshCredentialAvailability()
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    model.goUp()
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .labelStyle(.iconOnly)
                .disabled(model.currentPath.isEmpty || model.isWorking)
                Button {
                    model.openSelectedCollection()
                } label: {
                    Label("Open Collection", systemImage: "folder")
                }
                .disabled(model.selectedEntry?.kind != .collection || model.isWorking)
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .disabled(model.isWorking)
                Text(model.displayPath(model.currentPath))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                RiffaSearchField(
                    "Filter paths",
                    text: $model.search,
                    accessibilityName: "WebDAV path filter"
                )
                    .frame(minWidth: 160, maxWidth: 260)
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
                Menu {
                    Button("Use Selected as Left") {
                        model.markSelectedForTextComparison(.left)
                    }
                    .disabled(!model.canMarkSelectedForTextComparison)
                    Button("Use Selected as Right") {
                        model.markSelectedForTextComparison(.right)
                    }
                    .disabled(!model.canMarkSelectedForTextComparison)
                    Divider()
                    Button("Compare Marked Text Files") {
                        model.compareMarkedTextFiles()
                    }
                    .disabled(!model.canCompareMarkedTextFiles)
                } label: {
                    Label("Compare Text", systemImage: "doc.text.magnifyingglass")
                }
                .help(textComparisonHelp)
                Button {
                    model.exportSelected()
                } label: {
                    Label("Export Selected…", systemImage: "square.and.arrow.up")
                }
                .disabled(model.selectedEntry?.kind != .file || model.isWorking)
            }
            .padding(RiffaSpacing.xs)
            .background(theme.surface(.one))
            .overlay(alignment: .bottom) {
                RiffaHairline()
            }
            if model.comparisonLeftPath != nil || model.comparisonRightPath != nil {
                HStack(spacing: 12) {
                    Label(
                        comparisonName(
                            model.comparisonLeftPath,
                            fallback: RiffaLocalization.string(
                                "Choose a left file"
                            )
                        ),
                        systemImage: "l.square"
                    )
                    .foregroundStyle(model.comparisonLeftPath == nil ? .secondary : .primary)
                    Label(
                        comparisonName(
                            model.comparisonRightPath,
                            fallback: RiffaLocalization.string(
                                "Choose a right file"
                            )
                        ),
                        systemImage: "r.square"
                    )
                    .foregroundStyle(model.comparisonRightPath == nil ? .secondary : .primary)
                    Spacer()
                    Button("Compare") {
                        model.compareMarkedTextFiles()
                    }
                    .disabled(!model.canCompareMarkedTextFiles)
                }
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .background(theme.surface(.two))
                .overlay(alignment: .bottom) {
                    RiffaHairline()
                }
            }

            HSplitView {
                Table(model.visibleEntries, selection: $model.selection) {
                    TableColumn("Kind") { entry in
                        Label {
                            Text(
                                verbatim: RiffaLocalization.string(
                                    entry.kind == .collection
                                        ? "Folder"
                                        : "File"
                                )
                            )
                        } icon: {
                            Image(
                                systemName: entry.kind == .collection
                                    ? "folder"
                                    : "doc"
                            )
                        }
                    }
                    .width(min: 90, ideal: 105, max: 125)
                    TableColumn("Name") { entry in
                        Text(URL(fileURLWithPath: entry.relativePath).lastPathComponent)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .onTapGesture(count: 2) {
                                if entry.kind == .collection {
                                    model.selection = entry.id
                                    model.openSelectedCollection()
                                }
                            }
                    }
                    TableColumn("Size") { entry in
                        Text(entry.contentLength.map {
                            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                        } ?? "—")
                        .foregroundStyle(.secondary)
                    }
                    .width(min: 75, ideal: 90, max: 110)
                    TableColumn("Modified") { entry in
                        Text(entry.modificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 115, ideal: 135, max: 170)
                }
                .scrollContentBackground(.hidden)
                .background(theme.canvas)
                .frame(minWidth: 500)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                verbatim: model.selectedEntry.map {
                                    URL(
                                        fileURLWithPath: $0.relativePath
                                    ).lastPathComponent
                                } ?? RiffaLocalization.string("Preview")
                            )
                            .font(.headline)
                            .lineLimit(1)
                            if let entry = model.selectedEntry {
                                Text(model.displayPath(entry.relativePath))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(RiffaSpacing.sm)
                    .background(theme.surface(.two))
                    .overlay(alignment: .bottom) {
                        RiffaHairline()
                    }
                    ScrollView([.vertical, .horizontal]) {
                        Text(model.preview)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                    }
                    .background(theme.canvas)
                }
                .frame(minWidth: 300, idealWidth: 390)
            }
            .onChange(of: model.selection) { _, _ in
                model.refreshPreview()
            }
            .onChange(of: model.search) { _, _ in
                model.selection = nil
                model.refreshPreview()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
    }

    private var textComparisonHelp: String {
        if let left = model.comparisonLeftPath,
           let right = model.comparisonRightPath {
            return String(
                localized: "Compare \(comparisonName(left, fallback: left)) with \(comparisonName(right, fallback: right)) after stable WebDAV reads",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return RiffaLocalization.string(
            "Mark two remote files as Left and Right for a bounded, read-only text comparison"
        )
    }

    private func comparisonName(_ path: String?, fallback: String) -> String {
        guard let path else { return fallback }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

private struct WebDAVTextComparisonView: View {
    let comparison: WebDAVTextComparisonPresentation

    @Environment(\.dismiss) private var dismiss
    @Environment(\.riffaTheme) private var theme
    @State private var errorMessage: String?
    @State private var reportTask: Task<Void, Never>?
    @State private var isExportingReport = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WebDAV Text Compare")
                        .font(.headline)
                    Text("Read-only · stable metadata and SHA-256 verified")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                comparisonBadge(
                    "\(comparison.result.statistics.modifiedLineCount) modified",
                    color: theme.warning
                )
                comparisonBadge(
                    "\(comparison.result.statistics.deletedLineCount) deleted",
                    color: theme.danger
                )
                comparisonBadge(
                    "\(comparison.result.statistics.insertedLineCount) inserted",
                    color: theme.success
                )
                if isExportingReport {
                    ProgressView().controlSize(.small)
                    Button("Cancel Export") {
                        reportTask?.cancel()
                    }
                } else {
                    Button {
                        exportReport()
                    } label: {
                        Label("Export Report…", systemImage: "square.and.arrow.up")
                    }
                }
                Button("Done") {
                    reportTask?.cancel()
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(RiffaSpacing.sm)
            .background(theme.surface(.one))

            RiffaHairline()

            HStack(spacing: 0) {
                remoteHeading(
                    side: "LEFT",
                    path: comparison.leftPath,
                    version: comparison.leftVersion,
                    color: theme.accent
                )
                RiffaHairline(.vertical)
                remoteHeading(
                    side: "RIGHT",
                    path: comparison.rightPath,
                    version: comparison.rightVersion,
                    color: theme.warning
                )
            }
            .frame(height: 54)
            .background(theme.surface(.two))

            RiffaHairline()

            if comparison.result.alignedLines.isEmpty {
                ContentUnavailableView(
                    "Both Files Are Empty",
                    systemImage: "doc.text",
                    description: Text("The verified remote resources contain no text lines.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.canvas)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0) {
                        ForEach(comparison.result.alignedLines, id: \.offset) { line in
                            WebDAVTextDiffRow(line: line)
                        }
                    }
                    .frame(minWidth: 1_140)
                }
                .background(theme.canvas)
            }

            HStack {
                if comparison.result.hasDifferences {
                    Label(
                        "\(comparison.result.hunks.count) difference groups",
                        systemImage: "arrow.left.arrow.right"
                    )
                } else {
                    Label("Remote files match", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(theme.success)
                }
                Spacer()
                Text("Server address and credentials are excluded from this result")
                    .foregroundStyle(theme.inkSubtle)
            }
            .riffaText(.caption)
            .padding(.horizontal, RiffaSpacing.sm)
            .frame(minHeight: 34)
            .background(theme.surface(.one))
            .overlay(alignment: .top) {
                RiffaHairline()
            }
        }
        .frame(minWidth: 980, idealWidth: 1_180, minHeight: 620, idealHeight: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .alert(
            "Could not export report",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: {
                Text(
                    verbatim: errorMessage
                        ?? RiffaLocalization.string("Unknown error")
                )
            }
        )
        .onDisappear {
            reportTask?.cancel()
        }
    }

    private func comparisonBadge(
        _ title: LocalizedStringKey,
        color: Color
    ) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func remoteHeading(
        side: String,
        path: String,
        version: WebDAVTextDocumentVersion,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(verbatim: RiffaLocalization.string(side))
                    .font(.caption.weight(.bold))
                Text("/" + path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(versionDescription(version))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func versionDescription(_ version: WebDAVTextDocumentVersion) -> String {
        let count = Int64(clamping: version.fingerprint.byteCount)
        let size = ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
        let validator = version.etag == nil
            ? RiffaLocalization.string("double SHA-256")
            : RiffaLocalization.string("ETag + SHA-256")
        return "\(size) · \(validator) · \(version.fingerprint.sha256.prefix(12))…"
    }

    private func exportReport() {
        guard !isExportingReport else { return }
        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string("Export WebDAV Text Comparison")
        panel.prompt = RiffaLocalization.string("Export")
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.html]
        let leftName = URL(fileURLWithPath: comparison.leftPath).lastPathComponent
        let rightName = URL(fileURLWithPath: comparison.rightPath).lastPathComponent
        panel.nameFieldStringValue = "\(leftName)-to-\(rightName).html"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let sink: AtomicWebDAVDownload
        do {
            sink = try AtomicWebDAVDownload(destinationURL: destination)
        } catch {
            errorMessage = String(
                localized: "Could not prepare the report destination: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }

        let result = comparison.result
        isExportingReport = true
        reportTask = Task {
            defer {
                isExportingReport = false
                reportTask = nil
            }
            do {
                let report = try await WebDAVTextHTMLReportGenerator().generate(
                    result,
                    leftLabel: leftName,
                    rightLabel: rightName
                )
                try Task.checkCancellation()
                try await sink.append(Data(report.utf8))
                try Task.checkCancellation()
                try await sink.commit()
            } catch is CancellationError {
                await sink.discard()
            } catch {
                await sink.discard()
                errorMessage = webDAVErrorMessage(error)
            }
        }
    }
}

private struct WebDAVTextDiffRow: View {
    let line: AlignedDiffLine
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            cell(line.left)
                .frame(width: 570)
                .background(leftColor)
            RiffaHairline(.vertical)
            cell(line.right)
                .frame(width: 570)
                .background(rightColor)
        }
        .frame(height: 25)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityDescription))
    }

    private func cell(_ value: DiffLineValue?) -> some View {
        HStack(spacing: 0) {
            Text(value.map { String($0.lineNumber) } ?? "")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 8)
            Rectangle()
                .fill(theme.hairline)
                .frame(width: 1)
            Text(value?.line.content ?? "")
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        }
    }

    private var leftColor: Color {
        switch line.kind {
        case .deleted: theme.danger.opacity(0.14)
        case .modified: theme.warning.opacity(0.12)
        case .inserted: theme.inkSubtle.opacity(0.035)
        case .unchanged: .clear
        }
    }

    private var rightColor: Color {
        switch line.kind {
        case .inserted: theme.success.opacity(0.14)
        case .modified: theme.warning.opacity(0.12)
        case .deleted: theme.inkSubtle.opacity(0.035)
        case .unchanged: .clear
        }
    }

    private var accessibilityDescription: String {
        let kind = switch line.kind {
        case .deleted:
            RiffaLocalization.string("deleted")
        case .modified:
            RiffaLocalization.string("modified")
        case .inserted:
            RiffaLocalization.string("inserted")
        case .unchanged:
            RiffaLocalization.string("unchanged")
        }
        let left = line.left.map {
            String(
                localized: "Left line \($0.lineNumber), \($0.line.content)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        } ?? RiffaLocalization.string("No left line")
        let right = line.right.map {
            String(
                localized: "Right line \($0.lineNumber), \($0.line.content)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        } ?? RiffaLocalization.string("No right line")
        return "\(kind), \(left), \(right)"
    }
}
