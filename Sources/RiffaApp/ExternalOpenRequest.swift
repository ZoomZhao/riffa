import Combine
import Darwin
import Foundation
import RiffaCore
import UniformTypeIdentifiers

struct ExternalOpenRequest: Identifiable, Equatable {
    let id = UUID()
    let kind: SessionKind
    let urls: [URL]
    let options: [String: String]

    init(
        kind: SessionKind,
        urls: [URL],
        options: [String: String] = [:]
    ) {
        self.kind = kind
        self.urls = urls.map(\.standardizedFileURL)
        self.options = options
    }

    @MainActor
    init(
        urls: [URL],
        accessRegistry: SecurityScopedAccessRegistry
    ) throws {
        guard !urls.isEmpty else {
            throw ExternalOpenError.noResources
        }
        guard urls.count <= 3 else {
            throw ExternalOpenError.tooManyResources(actual: urls.count)
        }

        let candidates = try urls.map {
            try accessRegistry.registerIncomingURL($0)
        }

        let values = try candidates.map {
            try $0.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        }
        let directoryFlags = values.map { $0.isDirectory == true }
        if directoryFlags.contains(true) {
            guard directoryFlags.allSatisfy({ $0 }) else {
                throw ExternalOpenError.mixedFilesAndFolders
            }
            kind = candidates.count == 3 ? .folderMerge : .folderCompare
            self.urls = candidates
            options = [:]
            return
        }

        let types = values.compactMap(\.contentType)
        let extensions = candidates.map { $0.pathExtension.lowercased() }
        let allText = types.count == candidates.count
            && types.allSatisfy { $0.conforms(to: .text) }

        if candidates.count == 3 {
            guard allText else {
                throw ExternalOpenError.unsupportedThreeFileComparison
            }
            kind = .textMerge
            self.urls = candidates
            options = [:]
            return
        }

        let officeExtensions = Set(["docx", "xlsx", "pptx", "ods"])
        let archiveExtensions = Set(["zip", "tar"])
        if extensions.allSatisfy({ officeExtensions.contains($0) }) {
            // Finder routing is deliberately only a hint. The comparison
            // engine recognizes OPC or OpenDocument package declarations and
            // rejects an ordinary ZIP renamed with an Office extension.
            kind = .officeCompare
        } else if candidates.count == 2,
                  extensions.allSatisfy({ archiveExtensions.contains($0) }) {
            // This is only a Finder-routing hint. The archive engine detects
            // ZIP/TAR from bytes and rejects ordinary or renamed files.
            kind = .archiveCompare
        } else if extensions.allSatisfy({ $0 == "pdf" })
            || (types.count == candidates.count
                && types.allSatisfy({ $0.conforms(to: .pdf) })) {
            kind = .pdfCompare
        } else if types.count == candidates.count,
           types.allSatisfy({ $0.conforms(to: .image) }) {
            kind = .imageCompare
        } else if types.count == candidates.count,
                  types.allSatisfy({
                      $0.conforms(to: .audio)
                          || $0.conforms(to: .movie)
                          || $0.conforms(to: .audiovisualContent)
                  }) {
            kind = .mediaCompare
        } else if extensions.allSatisfy({ ["csv", "tsv", "tab", "psv"].contains($0) }) {
            kind = .tableCompare
        } else if allText {
            kind = .textCompare
        } else {
            kind = .hexCompare
        }
        self.urls = candidates
        options = [:]
    }

    @MainActor
    init(
        session: ComparisonSession,
        accessRegistry: SecurityScopedAccessRegistry
    ) throws {
        let kind = try SessionKind(savedKind: session.kind)
        let expectedCount = kind.savedResourceCount
        guard session.resources.isEmpty || session.resources.count == expectedCount else {
            throw SavedSessionOpenError.unsupportedResourceCount(
                kind: session.kind,
                expected: expectedCount,
                actual: session.resources.count
            )
        }

        let expectsDirectories = kind.usesDirectoryResources
        var localURLs: [URL] = []
        localURLs.reserveCapacity(session.resources.count)

        for (index, resource) in session.resources.enumerated() {
            guard resource.providerID == "local" else {
                throw SavedSessionOpenError.unsupportedProvider(
                    occurrence: index,
                    providerID: resource.providerID
                )
            }
            guard NSString(string: resource.path).isAbsolutePath else {
                throw SavedSessionOpenError.relativeLocalPath(
                    occurrence: index,
                    path: resource.path
                )
            }

            let url: URL
            if let bookmarkData = resource.bookmarkData {
                do {
                    url = try accessRegistry.resolveAndRegisterBookmark(bookmarkData)
                } catch let error as SecurityScopedAccessError {
                    throw SavedSessionOpenError.securityScopedBookmarkFailure(
                        occurrence: index,
                        path: resource.path,
                        reason: error.localizedDescription
                    )
                }
            } else {
                // Schema 1 catalogs created before security bookmarks remain
                // usable when their absolute path is already accessible.
                url = URL(fileURLWithPath: resource.path).standardizedFileURL
            }
            guard url.isFileURL,
                  NSString(string: url.path).isAbsolutePath
            else {
                throw SavedSessionOpenError.invalidResolvedLocalURL(
                    occurrence: index,
                    path: resource.path
                )
            }
            if kind == .metadataCompare {
                var entryInformation = stat()
                let status = url.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return Int32(-1) }
                    return Darwin.lstat(path, &entryInformation)
                }
                guard status == 0 else {
                    let code = errno
                    let reason = String(cString: strerror(code))
                    throw SavedSessionOpenError.unreadableLocalResource(
                        occurrence: index,
                        path: url.path,
                        reason: reason
                    )
                }
                localURLs.append(url)
                continue
            }
            if kind == .versionCompare {
                var entryInformation = stat()
                let status = url.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return Int32(-1) }
                    return Darwin.lstat(path, &entryInformation)
                }
                guard status == 0 else {
                    let code = errno
                    if code == ENOENT {
                        throw SavedSessionOpenError.missingLocalResource(
                            occurrence: index,
                            path: url.path
                        )
                    }
                    throw SavedSessionOpenError.unreadableLocalResource(
                        occurrence: index,
                        path: url.path,
                        reason: String(cString: strerror(code))
                    )
                }
                let entryKind = entryInformation.st_mode & S_IFMT
                guard entryKind != S_IFLNK,
                      entryKind == S_IFREG || entryKind == S_IFDIR else {
                    throw SavedSessionOpenError.expectedVersionInput(
                        occurrence: index,
                        path: url.path
                    )
                }
                localURLs.append(url)
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SavedSessionOpenError.missingLocalResource(
                    occurrence: index,
                    path: url.path
                )
            }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isReadableKey
                ])
            } catch {
                throw SavedSessionOpenError.unreadableLocalResource(
                    occurrence: index,
                    path: url.path,
                    reason: error.localizedDescription
                )
            }
            guard values.isReadable == true else {
                throw SavedSessionOpenError.unreadableLocalResource(
                    occurrence: index,
                    path: url.path,
                    reason: RiffaLocalization.string(
                        "The item is not readable."
                    )
                )
            }
            if expectsDirectories {
                guard values.isDirectory == true else {
                    throw SavedSessionOpenError.expectedDirectory(
                        occurrence: index,
                        path: url.path
                    )
                }
            } else {
                guard values.isRegularFile == true else {
                    throw SavedSessionOpenError.expectedFile(
                        occurrence: index,
                        path: url.path
                    )
                }
            }
            localURLs.append(url)
        }

        self.init(
            kind: kind,
            urls: localURLs,
            options: session.options.mapValues(\.externalOpenString)
        )
    }
}

/// The immutable payload used to initialize a comparison view. Including the
/// options in the task identity ensures reopening the same paths with different
/// saved settings still reapplies those settings.
struct ComparisonInitialLoad: Equatable {
    let urls: [URL]
    let options: [String: String]
}

extension Dictionary where Key == String, Value == String {
    func riffaBoolean(for key: String) -> Bool? {
        guard let value = self[key]?.lowercased() else { return nil }
        return switch value {
        case "true": true
        case "false": false
        default: nil
        }
    }

    func riffaInteger(for key: String) -> Int64? {
        guard let value = self[key] else { return nil }
        return Int64(value)
    }

    func riffaDouble(for key: String) -> Double? {
        guard let value = self[key], let number = Double(value), number.isFinite else {
            return nil
        }
        return number
    }

    func riffaStrings(for key: String) -> [String]? {
        guard let value = self[key], let data = value.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}

/// A short-lived, app-wide handoff between the session library scene and the
/// comparison scene. The exact saved kind has already been resolved before a
/// request is published; the receiving window never guesses from file types.
@MainActor
final class ComparisonOpenBroker: ObservableObject {
    @Published private(set) var request: ExternalOpenRequest?

    private var expirationTask: Task<Void, Never>?
    private var claimedRequestID: UUID?
    private let accessRegistry: SecurityScopedAccessRegistry

    init(accessRegistry: SecurityScopedAccessRegistry) {
        self.accessRegistry = accessRegistry
    }

    func prepareExternalOpen(urls: [URL]) throws -> ExternalOpenRequest {
        try ExternalOpenRequest(urls: urls, accessRegistry: accessRegistry)
    }

    func publishExternalOpen(
        _ prepared: ExternalOpenRequest,
        revealComparisonWindow: () -> Void
    ) {
        publish(prepared, revealComparisonWindow: revealComparisonWindow)
    }

    /// Claims the current request for exactly one comparison window.
    ///
    /// `ComparisonOpenBroker` is shared by every scene, so every live
    /// `RiffaRootView` observes the same publication. Requiring a claim keeps a
    /// drop in an auxiliary window from replacing every comparison window.
    func claimExternalOpen(_ candidate: ExternalOpenRequest) -> Bool {
        guard request?.id == candidate.id,
              claimedRequestID != candidate.id else {
            return false
        }
        claimedRequestID = candidate.id
        return true
    }

    func open(
        _ session: ComparisonSession,
        revealComparisonWindow: () -> Void
    ) throws {
        let prepared = try ExternalOpenRequest(
            session: session,
            accessRegistry: accessRegistry
        )

        publish(prepared, revealComparisonWindow: revealComparisonWindow)
    }

    private func publish(
        _ prepared: ExternalOpenRequest,
        revealComparisonWindow: () -> Void
    ) {
        expirationTask?.cancel()
        claimedRequestID = nil
        request = prepared
        revealComparisonWindow()

        expirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled,
                  self?.request?.id == prepared.id
            else { return }
            self?.request = nil
        }
    }
}

enum SavedSessionOpenError: Error, LocalizedError {
    case unsupportedKind(ComparisonSessionKind)
    case unsupportedResourceCount(kind: ComparisonSessionKind, expected: Int, actual: Int)
    case unsupportedProvider(occurrence: Int, providerID: String)
    case relativeLocalPath(occurrence: Int, path: String)
    case securityScopedBookmarkFailure(occurrence: Int, path: String, reason: String)
    case invalidResolvedLocalURL(occurrence: Int, path: String)
    case missingLocalResource(occurrence: Int, path: String)
    case unreadableLocalResource(occurrence: Int, path: String, reason: String)
    case expectedDirectory(occurrence: Int, path: String)
    case expectedFile(occurrence: Int, path: String)
    case expectedVersionInput(occurrence: Int, path: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedKind(kind):
            let localizedKind = RiffaLocalization.string(kind.rawValue)
            return String(
                localized: "Riffa does not yet have a live comparison view for saved kind “\(localizedKind)”.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .unsupportedResourceCount(kind, expected, actual):
            let localizedKind = RiffaLocalization.string(kind.rawValue)
            return String(
                localized: "A saved \(localizedKind) session must contain either no resources or exactly \(expected); this session contains \(actual).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .unsupportedProvider(occurrence, providerID):
            return String(
                localized: "Resource \(occurrence + 1) uses provider “\(providerID)”. Opening currently supports only providerID “local”.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .relativeLocalPath(occurrence, path):
            return String(
                localized: "Resource \(occurrence + 1) has relative local path “\(path)”. Save an absolute macOS path instead.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .securityScopedBookmarkFailure(occurrence, path, reason):
            return String(
                localized: "Could not restore access to resource \(occurrence + 1) saved at \(path): \(reason)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .invalidResolvedLocalURL(occurrence, path):
            return String(
                localized: "Resource \(occurrence + 1) saved at \(path) did not resolve to an absolute local file URL.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .missingLocalResource(occurrence, path):
            return String(
                localized: "Local resource \(occurrence + 1) no longer exists at \(path).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .unreadableLocalResource(occurrence, path, reason):
            return String(
                localized: "Local resource \(occurrence + 1) at \(path) cannot be read: \(reason)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .expectedDirectory(occurrence, path):
            return String(
                localized: "Resource \(occurrence + 1) must be a folder for this saved session, but \(path) is not a folder.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .expectedFile(occurrence, path):
            return String(
                localized: "Resource \(occurrence + 1) must be a regular file for this saved session, but \(path) is not a regular file.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .expectedVersionInput(occurrence, path):
            return String(
                localized: "Resource \(occurrence + 1) must be a regular file or supported macOS bundle for this saved version session, but \(path) is neither.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }
}

enum ExternalOpenError: Error, LocalizedError {
    case noResources
    case tooManyResources(actual: Int)
    case mixedFilesAndFolders
    case unsupportedThreeFileComparison

    var errorDescription: String? {
        switch self {
        case .noResources:
            RiffaLocalization.string("No resources were supplied.")
        case let .tooManyResources(actual):
            String(
                localized: "Riffa can open at most three resources together; \(actual) were supplied.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .mixedFilesAndFolders:
            RiffaLocalization.string(
                "Open files together or folders together. A file and folder cannot share one comparison."
            )
        case .unsupportedThreeFileComparison:
            RiffaLocalization.string(
                "Three-file opening is supported for text merge. Select three text files, or open two files for comparison."
            )
        }
    }
}

private extension SessionKind {
    init(savedKind: ComparisonSessionKind) throws {
        self = switch savedKind {
        case .textComparison: .textCompare
        case .folderComparison: .folderCompare
        case .folderSynchronization: .folderSync
        case .folderMerge: .folderMerge
        case .textMerge: .textMerge
        case .textPatch: .textPatch
        case .tableComparison: .tableCompare
        case .hexadecimalComparison: .hexCompare
        case .imageComparison: .imageCompare
        case .pdfComparison: .pdfCompare
        case .officeComparison: .officeCompare
        case .archiveComparison: .archiveCompare
        case .metadataComparison: .metadataCompare
        case .mediaComparison: .mediaCompare
        case .versionComparison: .versionCompare
        }
    }

    var savedResourceCount: Int {
        switch self {
        case .folderMerge, .textMerge: 3
        case .folderCompare, .folderSync, .textCompare, .hexCompare,
             .mediaCompare, .imageCompare, .pdfCompare, .metadataCompare,
             .officeCompare, .archiveCompare, .versionCompare, .tableCompare, .textPatch: 2
        }
    }

    var usesDirectoryResources: Bool {
        switch self {
        case .folderCompare, .folderMerge, .folderSync: true
        case .textCompare, .textMerge, .hexCompare, .mediaCompare,
             .imageCompare, .pdfCompare, .metadataCompare, .versionCompare,
             .officeCompare, .archiveCompare, .tableCompare, .textPatch: false
        }
    }
}

private extension SessionOptionValue {
    var externalOpenString: String {
        switch self {
        case let .string(value):
            value
        case let .integer(value):
            String(value)
        case let .decimal(value):
            NSDecimalNumber(decimal: value).stringValue
        case let .boolean(value):
            value ? "true" : "false"
        case let .strings(value):
            String(data: (try? JSONEncoder().encode(value)) ?? Data("[]".utf8), encoding: .utf8)
                ?? "[]"
        }
    }
}
