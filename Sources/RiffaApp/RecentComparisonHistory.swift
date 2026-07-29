import Combine
import Foundation
import RiffaCore

enum RecentComparisonHistoryLocation {
    static var defaultFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.riffa.Riffa", isDirectory: true)
            .appendingPathComponent("recent-comparisons.json", isDirectory: false)
    }

    static let sharedStore = RecentComparisonHistoryStore(
        fileURL: defaultFileURL
    )
}

extension Notification.Name {
    static let riffaRecentComparisonHistoryDidChange = Notification.Name(
        "dev.riffa.Riffa.recentComparisonHistoryDidChange"
    )
}

struct RecentComparisonHistoryEnvelope: Equatable, Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sessions: [ComparisonSession]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessions: [ComparisonSession]
    ) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
    }
}

enum RecentComparisonHistoryError: Error, LocalizedError {
    case futureSchemaVersion(found: Int, supported: Int)
    case corrupted(path: String, reason: String)
    case ioFailure(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .futureSchemaVersion(found, supported):
            "The recent-session history uses schema \(found); this Riffa version supports up to \(supported)."
        case let .corrupted(path, reason):
            "The recent-session history at \(path) is corrupted and was not overwritten: \(reason)"
        case let .ioFailure(path, reason):
            "Could not update recent-session history at \(path): \(reason)"
        }
    }
}

actor RecentComparisonHistoryStore {
    static let defaultMaximumSessionCount = 20
    static let maximumFileByteCount = 4 * 1_024 * 1_024

    nonisolated let fileURL: URL
    private let maximumSessionCount: Int

    init(
        fileURL: URL,
        maximumSessionCount: Int = defaultMaximumSessionCount
    ) {
        self.fileURL = fileURL
        self.maximumSessionCount = max(1, maximumSessionCount)
    }

    func load() throws -> [ComparisonSession] {
        try readIfPresent()
            .map(normalized)
            ?? []
    }

    @discardableResult
    func record(
        kind: ComparisonSessionKind,
        name: String,
        resources: [SessionResourceReference],
        options: [String: SessionOptionValue],
        openedAt: Date = Date()
    ) throws -> [ComparisonSession] {
        var sessions = try readIfPresent() ?? []
        let matchingIndex = sessions.firstIndex {
            $0.kind == kind
                && $0.resources.map(\.providerID) == resources.map(\.providerID)
                && $0.resources.map(\.path) == resources.map(\.path)
        }
        let id = matchingIndex.map { sessions[$0].id } ?? UUID()
        let createdAt = matchingIndex.map { sessions[$0].createdAt } ?? openedAt
        if let matchingIndex {
            sessions.remove(at: matchingIndex)
        }
        sessions.append(
            ComparisonSession(
                id: id,
                kind: kind,
                name: name,
                createdAt: min(createdAt, openedAt),
                updatedAt: openedAt,
                resources: resources,
                options: options
            )
        )
        sessions = normalized(sessions)
        try write(sessions)
        return sessions
    }

    private func readIfPresent() throws -> [ComparisonSession]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data: Data
        do {
            data = try BoundedLocalFileReader(
                limits: .init(maximumByteCount: Self.maximumFileByteCount)
            ).read(url: fileURL)
        } catch {
            throw RecentComparisonHistoryError.ioFailure(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }

        let envelope: RecentComparisonHistoryEnvelope
        do {
            envelope = try JSONDecoder().decode(
                RecentComparisonHistoryEnvelope.self,
                from: data
            )
        } catch {
            throw RecentComparisonHistoryError.corrupted(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
        guard envelope.schemaVersion
            <= RecentComparisonHistoryEnvelope.currentSchemaVersion
        else {
            throw RecentComparisonHistoryError.futureSchemaVersion(
                found: envelope.schemaVersion,
                supported: RecentComparisonHistoryEnvelope.currentSchemaVersion
            )
        }
        guard envelope.schemaVersion
            == RecentComparisonHistoryEnvelope.currentSchemaVersion
        else {
            throw RecentComparisonHistoryError.corrupted(
                path: fileURL.path,
                reason: "unsupported older schema \(envelope.schemaVersion)"
            )
        }
        try validate(envelope.sessions)
        return envelope.sessions
    }

    private func write(_ sessions: [ComparisonSession]) throws {
        let envelope = RecentComparisonHistoryEnvelope(sessions: sessions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw RecentComparisonHistoryError.ioFailure(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
        guard data.count <= Self.maximumFileByteCount else {
            throw RecentComparisonHistoryError.ioFailure(
                path: fileURL.path,
                reason: "encoded history exceeds the \(Self.maximumFileByteCount)-byte limit"
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw RecentComparisonHistoryError.ioFailure(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private func normalized(
        _ sessions: [ComparisonSession]
    ) -> [ComparisonSession] {
        Array(
            sessions
                .sorted {
                    if $0.updatedAt != $1.updatedAt {
                        return $0.updatedAt > $1.updatedAt
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
                .prefix(maximumSessionCount)
        )
    }

    private func validate(_ sessions: [ComparisonSession]) throws {
        var identifiers: Set<UUID> = []
        for session in sessions {
            guard identifiers.insert(session.id).inserted,
                  !session.name.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  session.createdAt <= session.updatedAt,
                  !session.resources.isEmpty,
                  session.resources.allSatisfy({
                      $0.providerID == "local"
                          && NSString(string: $0.path).isAbsolutePath
                          && ($0.bookmarkData?.isEmpty == false)
                  })
            else {
                throw RecentComparisonHistoryError.corrupted(
                    path: fileURL.path,
                    reason: "one or more recent-session records are invalid"
                )
            }
        }
    }
}

@MainActor
final class RecentComparisonHistoryModel: ObservableObject {
    @Published private(set) var sessions: [ComparisonSession] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let store: RecentComparisonHistoryStore
    private var hasLoaded = false
    private var loadGeneration = 0

    init(store: RecentComparisonHistoryStore? = nil) {
        self.store = store ?? RecentComparisonHistoryLocation.sharedStore
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        reload()
    }

    func reload() {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        Task {
            do {
                let loaded = try await store.load()
                guard generation == loadGeneration else { return }
                sessions = loaded
                errorMessage = nil
                hasLoaded = true
            } catch {
                guard generation == loadGeneration else { return }
                errorMessage = error.localizedDescription
            }
            if generation == loadGeneration {
                isLoading = false
            }
        }
    }
}

@MainActor
enum RecentComparisonHistoryRecorder {
    static func record(_ request: SessionSaveRequest) async {
        guard request.isComplete else { return }
        do {
            let resources = try SessionSaveService.localResources(
                for: request.urls
            )
            let separator = request.urls.count == 2 ? " ↔ " : " • "
            let name = request.urls
                .map(\.lastPathComponent)
                .joined(separator: separator)
            _ = try await RecentComparisonHistoryLocation.sharedStore.record(
                kind: request.kind,
                name: name,
                resources: resources,
                options: request.options
            )
            NotificationCenter.default.post(
                name: .riffaRecentComparisonHistoryDidChange,
                object: nil
            )
        } catch {
            // History is best-effort. A comparison remains usable when a
            // bookmark or the bounded history file cannot be updated.
        }
    }
}
