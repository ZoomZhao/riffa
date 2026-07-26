import Foundation

public enum ComparisonSessionKind: String, CaseIterable, Codable, Sendable {
    case textComparison
    case folderComparison
    case folderSynchronization
    case folderMerge
    case textMerge
    case textPatch
    case tableComparison
    case hexadecimalComparison
    case imageComparison
    case pdfComparison
    case officeComparison
    case archiveComparison
    case metadataComparison
    case versionComparison
    case mediaComparison
}

/// A provider-neutral resource reference. `path` is opaque to the catalog and
/// is not assumed to be a local file URL.
public struct SessionResourceReference: Hashable, Codable, Sendable {
    public var providerID: String
    public var path: String
    /// An app-scoped macOS security bookmark for local resources. This stays
    /// provider-neutral at the catalog boundary: only the App target creates
    /// and resolves the opaque payload.
    public var bookmarkData: Data?

    public init(
        providerID: String,
        path: String,
        bookmarkData: Data? = nil
    ) {
        self.providerID = providerID
        self.path = path
        self.bookmarkData = bookmarkData
    }
}

public enum SessionOptionValue: Equatable, Codable, Sendable {
    case string(String)
    case integer(Int64)
    case decimal(Decimal)
    case boolean(Bool)
    case strings([String])

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Kind: String, Codable {
        case string
        case integer
        case decimal
        case boolean
        case strings
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
        case .strings:
            self = .strings(try container.decode([String].self, forKey: .value))
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
        case let .strings(value):
            try container.encode(Kind.strings, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct ComparisonSession: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var kind: ComparisonSessionKind
    public var name: String
    public var groupName: String?
    public var isLocked: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var resources: [SessionResourceReference]
    public var options: [String: SessionOptionValue]

    public init(
        id: UUID = UUID(),
        kind: ComparisonSessionKind,
        name: String,
        groupName: String? = nil,
        isLocked: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        resources: [SessionResourceReference] = [],
        options: [String: SessionOptionValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.groupName = groupName
        self.isLocked = isLocked
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resources = resources
        self.options = options
    }
}

public struct WorkspaceWindowFrame: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct WorkspaceTab: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var sessionID: UUID

    public init(id: UUID = UUID(), sessionID: UUID) {
        self.id = id
        self.sessionID = sessionID
    }
}

public struct WorkspaceWindow: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    /// A user-facing label for the window. This remains optional so schema 1
    /// catalogs written before workspace windows were exposed in the UI keep
    /// decoding without a migration.
    public var name: String?
    public var frame: WorkspaceWindowFrame?
    public var tabs: [WorkspaceTab]
    public var selectedSessionID: UUID?

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        frame: WorkspaceWindowFrame? = nil,
        tabs: [WorkspaceTab] = [],
        selectedSessionID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.tabs = tabs
        self.selectedSessionID = selectedSessionID
    }
}

public struct SessionWorkspace: Equatable, Codable, Sendable {
    public var windows: [WorkspaceWindow]
    public var selectedWindowID: UUID?

    public init(windows: [WorkspaceWindow] = [], selectedWindowID: UUID? = nil) {
        self.windows = windows
        self.selectedWindowID = selectedWindowID
    }

    public static let empty = SessionWorkspace()
}

public struct SessionCatalog: Equatable, Codable, Sendable {
    public var sessions: [ComparisonSession]
    public var workspace: SessionWorkspace

    public init(
        sessions: [ComparisonSession] = [],
        workspace: SessionWorkspace = .empty
    ) {
        self.sessions = sessions
        self.workspace = workspace
    }

    public static let empty = SessionCatalog()
}

public struct SessionCatalogEnvelope: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let catalog: SessionCatalog

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        catalog: SessionCatalog
    ) {
        self.schemaVersion = schemaVersion
        self.catalog = catalog
    }
}

public enum SessionCatalogError: Error, Equatable, Sendable {
    case corruptedJSON(path: String, reason: String)
    case ioFailure(path: String, reason: String)
    case futureSchemaVersion(found: Int, supported: Int)
    case migrationRequired(found: Int, current: Int)
    case duplicateSessionID(UUID)
    case duplicateWindowID(UUID)
    case duplicateTabID(UUID)
    case duplicateSessionInWindow(windowID: UUID, sessionID: UUID)
    case missingSessionReference(UUID)
    case missingSelectedWindow(UUID)
    case selectedSessionNotInWindow(windowID: UUID, sessionID: UUID)
    case invalidResourceReference(sessionID: UUID, occurrence: Int)
    case invalidResourceBookmark(sessionID: UUID, occurrence: Int)
    case invalidSessionName(UUID)
    case invalidSessionTimestamp(UUID)
    case invalidWindowName(UUID)
    case invalidWindowFrame(UUID)
    case sessionNotFound(UUID)
    case sessionLocked(UUID)
}

/// A serialized, actor-isolated catalog. Every mutation reloads and validates
/// the current on-disk envelope before applying its change. This both prevents
/// stale concurrent updates and refuses to overwrite corrupted data.
public actor SessionCatalogStore {
    public nonisolated let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> SessionCatalog {
        try readCatalogIfPresent() ?? .empty
    }

    public func save(_ catalog: SessionCatalog) throws {
        // A malformed or unsupported existing file is never silently replaced.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try readCatalogIfPresent()
        }
        let normalized = try validatedAndNormalized(catalog)
        try write(normalized)
    }

    @discardableResult
    public func upsert(_ session: ComparisonSession) throws -> SessionCatalog {
        var catalog = try readCatalogIfPresent() ?? .empty
        if let index = catalog.sessions.firstIndex(where: { $0.id == session.id }) {
            guard !catalog.sessions[index].isLocked else {
                throw SessionCatalogError.sessionLocked(session.id)
            }
            catalog.sessions[index] = session
        } else {
            catalog.sessions.append(session)
        }
        return try validateWriteAndReturn(catalog)
    }

    @discardableResult
    public func remove(sessionID: UUID) throws -> SessionCatalog {
        var catalog = try readCatalogIfPresent() ?? .empty
        guard let index = catalog.sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw SessionCatalogError.sessionNotFound(sessionID)
        }
        guard !catalog.sessions[index].isLocked else {
            throw SessionCatalogError.sessionLocked(sessionID)
        }
        catalog.sessions.remove(at: index)

        for windowIndex in catalog.workspace.windows.indices {
            catalog.workspace.windows[windowIndex].tabs.removeAll { $0.sessionID == sessionID }
            if catalog.workspace.windows[windowIndex].selectedSessionID == sessionID {
                catalog.workspace.windows[windowIndex].selectedSessionID =
                    catalog.workspace.windows[windowIndex].tabs.first?.sessionID
            }
        }
        return try validateWriteAndReturn(catalog)
    }

    @discardableResult
    public func rename(
        sessionID: UUID,
        to name: String,
        modifiedAt: Date = Date()
    ) throws -> SessionCatalog {
        var catalog = try readCatalogIfPresent() ?? .empty
        guard let index = catalog.sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw SessionCatalogError.sessionNotFound(sessionID)
        }
        guard !catalog.sessions[index].isLocked else {
            throw SessionCatalogError.sessionLocked(sessionID)
        }
        catalog.sessions[index].name = name
        catalog.sessions[index].updatedAt = modifiedAt
        return try validateWriteAndReturn(catalog)
    }

    @discardableResult
    public func setLocked(
        sessionID: UUID,
        _ isLocked: Bool,
        modifiedAt: Date = Date()
    ) throws -> SessionCatalog {
        var catalog = try readCatalogIfPresent() ?? .empty
        guard let index = catalog.sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw SessionCatalogError.sessionNotFound(sessionID)
        }
        catalog.sessions[index].isLocked = isLocked
        catalog.sessions[index].updatedAt = modifiedAt
        return try validateWriteAndReturn(catalog)
    }

    @discardableResult
    public func updateWorkspace(_ workspace: SessionWorkspace) throws -> SessionCatalog {
        var catalog = try readCatalogIfPresent() ?? .empty
        catalog.workspace = workspace
        return try validateWriteAndReturn(catalog)
    }

    private func validateWriteAndReturn(_ catalog: SessionCatalog) throws -> SessionCatalog {
        let normalized = try validatedAndNormalized(catalog)
        try write(normalized)
        return normalized
    }

    private func readCatalogIfPresent() throws -> SessionCatalog? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let data: Data
        do {
            data = try BoundedLocalFileReader(
                limits: .init(maximumByteCount: 64 * 1_024 * 1_024)
            ).read(url: fileURL)
        } catch {
            throw SessionCatalogError.ioFailure(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }

        let header: SchemaHeader
        do {
            header = try JSONDecoder().decode(SchemaHeader.self, from: data)
        } catch {
            throw SessionCatalogError.corruptedJSON(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }

        if header.schemaVersion > SessionCatalogEnvelope.currentSchemaVersion {
            throw SessionCatalogError.futureSchemaVersion(
                found: header.schemaVersion,
                supported: SessionCatalogEnvelope.currentSchemaVersion
            )
        }
        if header.schemaVersion < SessionCatalogEnvelope.currentSchemaVersion {
            throw SessionCatalogError.migrationRequired(
                found: header.schemaVersion,
                current: SessionCatalogEnvelope.currentSchemaVersion
            )
        }

        let envelope: SessionCatalogEnvelope
        do {
            envelope = try JSONDecoder().decode(SessionCatalogEnvelope.self, from: data)
        } catch {
            throw SessionCatalogError.corruptedJSON(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
        return try validatedAndNormalized(envelope.catalog)
    }

    private func write(_ catalog: SessionCatalog) throws {
        let envelope = SessionCatalogEnvelope(catalog: catalog)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let encoded: Data
        do {
            encoded = try encoder.encode(envelope)
        } catch {
            throw SessionCatalogError.ioFailure(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            throw SessionCatalogError.ioFailure(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private func validatedAndNormalized(_ catalog: SessionCatalog) throws -> SessionCatalog {
        try validate(catalog)
        var normalized = catalog
        normalized.sessions.sort(by: sessionSort)
        return normalized
    }

    private func validate(_ catalog: SessionCatalog) throws {
        var sessionIDs: Set<UUID> = []
        for session in catalog.sessions {
            guard sessionIDs.insert(session.id).inserted else {
                throw SessionCatalogError.duplicateSessionID(session.id)
            }
            guard !session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SessionCatalogError.invalidSessionName(session.id)
            }
            guard session.createdAt <= session.updatedAt else {
                throw SessionCatalogError.invalidSessionTimestamp(session.id)
            }
            for (occurrence, resource) in session.resources.enumerated() {
                if resource.providerID.isEmpty || resource.path.isEmpty {
                    throw SessionCatalogError.invalidResourceReference(
                        sessionID: session.id,
                        occurrence: occurrence
                    )
                }
                if let bookmarkData = resource.bookmarkData,
                   bookmarkData.isEmpty || resource.providerID != "local" {
                    throw SessionCatalogError.invalidResourceBookmark(
                        sessionID: session.id,
                        occurrence: occurrence
                    )
                }
            }
        }

        var windowIDs: Set<UUID> = []
        var tabIDs: Set<UUID> = []
        for window in catalog.workspace.windows {
            guard windowIDs.insert(window.id).inserted else {
                throw SessionCatalogError.duplicateWindowID(window.id)
            }
            if let name = window.name,
               name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SessionCatalogError.invalidWindowName(window.id)
            }
            if let frame = window.frame,
               !frame.x.isFinite || !frame.y.isFinite || !frame.width.isFinite
                || !frame.height.isFinite || frame.width < 0 || frame.height < 0 {
                throw SessionCatalogError.invalidWindowFrame(window.id)
            }

            var windowSessionIDs: Set<UUID> = []
            for tab in window.tabs {
                guard tabIDs.insert(tab.id).inserted else {
                    throw SessionCatalogError.duplicateTabID(tab.id)
                }
                guard windowSessionIDs.insert(tab.sessionID).inserted else {
                    throw SessionCatalogError.duplicateSessionInWindow(
                        windowID: window.id,
                        sessionID: tab.sessionID
                    )
                }
                guard sessionIDs.contains(tab.sessionID) else {
                    throw SessionCatalogError.missingSessionReference(tab.sessionID)
                }
            }

            if let selectedSessionID = window.selectedSessionID,
               !window.tabs.contains(where: { $0.sessionID == selectedSessionID }) {
                throw SessionCatalogError.selectedSessionNotInWindow(
                    windowID: window.id,
                    sessionID: selectedSessionID
                )
            }
        }

        if let selectedWindowID = catalog.workspace.selectedWindowID,
           !windowIDs.contains(selectedWindowID) {
            throw SessionCatalogError.missingSelectedWindow(selectedWindowID)
        }
    }

    private func sessionSort(_ left: ComparisonSession, _ right: ComparisonSession) -> Bool {
        let leftGroup = left.groupName ?? ""
        let rightGroup = right.groupName ?? ""
        if leftGroup != rightGroup { return leftGroup < rightGroup }
        if left.name != right.name { return left.name < right.name }
        return left.id.uuidString < right.id.uuidString
    }
}

private struct SchemaHeader: Decodable {
    let schemaVersion: Int
}
