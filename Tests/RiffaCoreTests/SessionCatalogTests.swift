import Foundation
import Testing
@testable import RiffaCore

@Suite("Versioned session catalog")
struct SessionCatalogTests {
    @Test("Catalog and workspace round-trip with stable session ordering")
    func roundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let alpha = session(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Alpha",
            group: "Work"
        )
        let zeta = session(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Zeta",
            group: "Work"
        )
        let windowID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let workspace = SessionWorkspace(
            windows: [
                WorkspaceWindow(
                    id: windowID,
                    name: "Review Window",
                    frame: WorkspaceWindowFrame(x: 10, y: 20, width: 900, height: 600),
                    tabs: [WorkspaceTab(sessionID: alpha.id), WorkspaceTab(sessionID: zeta.id)],
                    selectedSessionID: zeta.id
                )
            ],
            selectedWindowID: windowID
        )
        let store = SessionCatalogStore(fileURL: fixture.fileURL)

        try await store.save(SessionCatalog(sessions: [zeta, alpha], workspace: workspace))
        let loaded = try await store.load()
        let data = try Data(contentsOf: fixture.fileURL)
        let envelope = try JSONDecoder().decode(SessionCatalogEnvelope.self, from: data)

        #expect(loaded.sessions.map(\.name) == ["Alpha", "Zeta"])
        #expect(loaded.workspace == workspace)
        #expect(envelope.schemaVersion == SessionCatalogEnvelope.currentSchemaVersion)
        #expect(envelope.catalog == loaded)
        #expect(!String(decoding: data, as: UTF8.self).lowercased().contains("license"))
    }

    @Test("Schema 1 workspace windows decode without a name and named windows round-trip")
    func workspaceWindowNameCompatibility() throws {
        let legacyData = Data(
            """
            {
              "id": "00000000-0000-0000-0000-000000000010",
              "tabs": [],
              "selectedSessionID": null
            }
            """.utf8
        )
        let legacy = try JSONDecoder().decode(WorkspaceWindow.self, from: legacyData)
        #expect(legacy.name == nil)

        let named = WorkspaceWindow(id: legacy.id, name: "Release Review")
        let decoded = try JSONDecoder().decode(
            WorkspaceWindow.self,
            from: JSONEncoder().encode(named)
        )
        #expect(decoded == named)
        #expect(decoded.name == "Release Review")
    }

    @Test("The same session can be selected independently in different windows")
    func multiWindowSelectionsRemainScoped() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let item = session(name: "Shared Review")
        let firstWindow = WorkspaceWindow(
            name: "First",
            tabs: [WorkspaceTab(sessionID: item.id)],
            selectedSessionID: item.id
        )
        let secondWindow = WorkspaceWindow(
            name: "Second",
            tabs: [WorkspaceTab(sessionID: item.id)],
            selectedSessionID: item.id
        )
        let workspace = SessionWorkspace(
            windows: [firstWindow, secondWindow],
            selectedWindowID: secondWindow.id
        )
        let store = SessionCatalogStore(fileURL: fixture.fileURL)

        try await store.save(SessionCatalog(sessions: [item], workspace: workspace))
        let loaded = try await store.load()

        #expect(loaded.workspace == workspace)
        #expect(loaded.workspace.windows[0].selectedSessionID == item.id)
        #expect(loaded.workspace.windows[1].selectedSessionID == item.id)
        #expect(loaded.workspace.selectedWindowID == secondWindow.id)
    }

    @Test("Older schemas reserve migration and future schemas are rejected")
    func schemaGates() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = SessionCatalogStore(fileURL: fixture.fileURL)

        try Data("{\"schemaVersion\":0,\"catalog\":{}}".utf8).write(to: fixture.fileURL)
        do {
            _ = try await store.load()
            Issue.record("Expected a migration requirement")
        } catch let error as SessionCatalogError {
            #expect(error == .migrationRequired(found: 0, current: 1))
        }

        try Data("{\"schemaVersion\":99,\"catalog\":{}}".utf8).write(to: fixture.fileURL)
        do {
            _ = try await store.load()
            Issue.record("Expected a future-schema rejection")
        } catch let error as SessionCatalogError {
            #expect(error == .futureSchemaVersion(found: 99, supported: 1))
        }
    }

    @Test("Folder Merge remains compatible with schema 1 catalogs")
    func folderMergeSchemaOneCompatibility() throws {
        #expect(SessionCatalogEnvelope.currentSchemaVersion == 1)

        let legacyData = Data(
            """
            {
              "schemaVersion": 1,
              "catalog": {
                "sessions": [],
                "workspace": { "windows": [] }
              }
            }
            """.utf8
        )
        let legacy = try JSONDecoder().decode(SessionCatalogEnvelope.self, from: legacyData)
        #expect(legacy.catalog == .empty)

        let timestamp = Date(timeIntervalSinceReferenceDate: 100)
        let folderMerge = ComparisonSession(
            kind: .folderMerge,
            name: "Three folders",
            createdAt: timestamp,
            updatedAt: timestamp,
            resources: [
                SessionResourceReference(providerID: "local", path: "/base"),
                SessionResourceReference(providerID: "local", path: "/left"),
                SessionResourceReference(providerID: "local", path: "/right")
            ]
        )
        let encoded = try JSONEncoder().encode(
            SessionCatalogEnvelope(catalog: SessionCatalog(sessions: [folderMerge]))
        )
        let decoded = try JSONDecoder().decode(SessionCatalogEnvelope.self, from: encoded)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.catalog.sessions.first?.kind == .folderMerge)
    }

    @Test("Text Patch round-trips without changing the schema 1 wire format")
    func textPatchSchemaOneCompatibility() throws {
        #expect(SessionCatalogEnvelope.currentSchemaVersion == 1)

        let timestamp = Date(timeIntervalSinceReferenceDate: 100)
        let textPatch = ComparisonSession(
            kind: .textPatch,
            name: "Review one patch record",
            createdAt: timestamp,
            updatedAt: timestamp,
            resources: [
                SessionResourceReference(providerID: "local", path: "/change.patch"),
                SessionResourceReference(providerID: "local", path: "/target.txt")
            ],
            options: ["selectedFileIndex": .integer(2)]
        )
        let encoded = try JSONEncoder().encode(
            SessionCatalogEnvelope(catalog: SessionCatalog(sessions: [textPatch]))
        )
        let decoded = try JSONDecoder().decode(SessionCatalogEnvelope.self, from: encoded)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.catalog.sessions.first == textPatch)
        #expect(decoded.catalog.sessions.first?.kind == .textPatch)
    }

    @Test("Office Comparison round-trips ODS resources in schema 1")
    func officeComparisonSchemaOneCompatibility() throws {
        #expect(SessionCatalogEnvelope.currentSchemaVersion == 1)

        let timestamp = Date(timeIntervalSinceReferenceDate: 200)
        let officeComparison = ComparisonSession(
            kind: .officeComparison,
            name: "OpenDocument workbook review",
            createdAt: timestamp,
            updatedAt: timestamp,
            resources: [
                SessionResourceReference(providerID: "local", path: "/left.ods"),
                SessionResourceReference(providerID: "local", path: "/right-renamed.bin")
            ],
            options: [
                "statusFilter": .string("All differences"),
                "itemFilter": .string("Sections")
            ]
        )
        let encoded = try JSONEncoder().encode(
            SessionCatalogEnvelope(catalog: SessionCatalog(sessions: [officeComparison]))
        )
        let decoded = try JSONDecoder().decode(SessionCatalogEnvelope.self, from: encoded)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.catalog.sessions.first == officeComparison)
        #expect(decoded.catalog.sessions.first?.kind == .officeComparison)
        #expect(decoded.catalog.sessions.first?.resources.count == 2)
    }

    @Test("Archive Comparison round-trips in schema 1 with options and two resources")
    func archiveComparisonSchemaOneCompatibility() throws {
        #expect(SessionCatalogEnvelope.currentSchemaVersion == 1)

        let timestamp = Date(timeIntervalSinceReferenceDate: 250)
        let archiveComparison = ComparisonSession(
            kind: .archiveComparison,
            name: "Release bundle review",
            createdAt: timestamp,
            updatedAt: timestamp,
            resources: [
                SessionResourceReference(providerID: "local", path: "/left.zip"),
                SessionResourceReference(providerID: "local", path: "/right.tar")
            ],
            options: [
                "statusFilter": .string("All differences"),
                "compareContent": .boolean(true),
                "compareModificationDate": .boolean(false),
                "comparePermissions": .boolean(true),
                "compareCompression": .boolean(false),
            ]
        )
        let encoded = try JSONEncoder().encode(
            SessionCatalogEnvelope(catalog: SessionCatalog(sessions: [archiveComparison]))
        )
        let decoded = try JSONDecoder().decode(SessionCatalogEnvelope.self, from: encoded)

        #expect(decoded.catalog.sessions.first == archiveComparison)
        #expect(decoded.catalog.sessions.first?.kind == .archiveComparison)
        #expect(decoded.catalog.sessions.first?.resources.count == 2)
        #expect(decoded.catalog.sessions.first?.options["comparePermissions"] == .boolean(true))
    }

    @Test("Schema 1 resources decode without bookmarks and bookmark data round-trips")
    func securityBookmarkCodableCompatibility() throws {
        let legacyData = Data(
            """
            {
              "schemaVersion": 1,
              "catalog": {
                "sessions": [{
                  "id": "00000000-0000-0000-0000-000000000101",
                  "kind": "textComparison",
                  "name": "Legacy",
                  "isLocked": false,
                  "createdAt": 0,
                  "updatedAt": 0,
                  "resources": [
                    {"providerID": "local", "path": "/tmp/left"},
                    {"providerID": "local", "path": "/tmp/right"}
                  ],
                  "options": {}
                }],
                "workspace": {"windows": []}
              }
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let legacy = try decoder.decode(SessionCatalogEnvelope.self, from: legacyData)
        #expect(legacy.catalog.sessions[0].resources.allSatisfy { $0.bookmarkData == nil })

        let payload = Data([0x00, 0x7f, 0xff, 0x42])
        let reference = SessionResourceReference(
            providerID: "local",
            path: "/tmp/bookmarked",
            bookmarkData: payload
        )
        let encoded = try JSONEncoder().encode(reference)
        let decoded = try JSONDecoder().decode(SessionResourceReference.self, from: encoded)

        #expect(decoded == reference)
        #expect(decoded.bookmarkData == payload)
    }

    @Test("Corrupted JSON blocks mutation and is never overwritten")
    func corruptedFileProtection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data("{ definitely not JSON".utf8)
        try original.write(to: fixture.fileURL)
        let store = SessionCatalogStore(fileURL: fixture.fileURL)

        do {
            _ = try await store.upsert(session(name: "Must not save"))
            Issue.record("Expected corrupted JSON to block upsert")
        } catch let error as SessionCatalogError {
            guard case .corruptedJSON = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: fixture.fileURL) == original)
    }

    @Test("Duplicate IDs and missing references fail validation")
    func validation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = SessionCatalogStore(fileURL: fixture.fileURL)
        let duplicateID = UUID()
        let duplicateCatalog = SessionCatalog(sessions: [
            session(id: duplicateID, name: "One"),
            session(id: duplicateID, name: "Two")
        ])

        do {
            try await store.save(duplicateCatalog)
            Issue.record("Expected duplicate session validation")
        } catch let error as SessionCatalogError {
            #expect(error == .duplicateSessionID(duplicateID))
        }

        let valid = session(name: "Valid")
        let missingID = UUID()
        let dangling = SessionCatalog(
            sessions: [valid],
            workspace: SessionWorkspace(
                windows: [WorkspaceWindow(tabs: [WorkspaceTab(sessionID: missingID)])]
            )
        )
        do {
            try await store.save(dangling)
            Issue.record("Expected missing session reference validation")
        } catch let error as SessionCatalogError {
            #expect(error == .missingSessionReference(missingID))
        }

        let duplicateWindowSession = SessionCatalog(
            sessions: [valid],
            workspace: SessionWorkspace(
                windows: [
                    WorkspaceWindow(
                        tabs: [
                            WorkspaceTab(sessionID: valid.id),
                            WorkspaceTab(sessionID: valid.id)
                        ]
                    )
                ]
            )
        )
        do {
            try await store.save(duplicateWindowSession)
            Issue.record("Expected duplicate session-in-window validation")
        } catch let error as SessionCatalogError {
            guard case let .duplicateSessionInWindow(_, sessionID) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(sessionID == valid.id)
        }

        let invalidWindowID = UUID()
        let invalidWindowName = SessionCatalog(
            sessions: [valid],
            workspace: SessionWorkspace(
                windows: [WorkspaceWindow(id: invalidWindowID, name: "   ")]
            )
        )
        do {
            try await store.save(invalidWindowName)
            Issue.record("Expected empty window-name validation")
        } catch let error as SessionCatalogError {
            #expect(error == .invalidWindowName(invalidWindowID))
        }

        var invalidResource = valid
        invalidResource.resources = [SessionResourceReference(providerID: "", path: "item")]
        do {
            try await store.save(SessionCatalog(sessions: [invalidResource]))
            Issue.record("Expected invalid resource validation")
        } catch let error as SessionCatalogError {
            #expect(error == .invalidResourceReference(sessionID: valid.id, occurrence: 0))
        }

        var emptyBookmark = valid
        emptyBookmark.resources = [
            SessionResourceReference(providerID: "local", path: "/item", bookmarkData: Data())
        ]
        do {
            try await store.save(SessionCatalog(sessions: [emptyBookmark]))
            Issue.record("Expected empty security bookmark validation")
        } catch let error as SessionCatalogError {
            #expect(error == .invalidResourceBookmark(sessionID: valid.id, occurrence: 0))
        }

        var nonLocalBookmark = valid
        nonLocalBookmark.resources = [
            SessionResourceReference(
                providerID: "memory",
                path: "item",
                bookmarkData: Data([0x01])
            )
        ]
        do {
            try await store.save(SessionCatalog(sessions: [nonLocalBookmark]))
            Issue.record("Expected non-local security bookmark validation")
        } catch let error as SessionCatalogError {
            #expect(error == .invalidResourceBookmark(sessionID: valid.id, occurrence: 0))
        }
    }

    @Test("Concurrent upserts are serialized without lost sessions")
    func concurrentUpdates() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = SessionCatalogStore(fileURL: fixture.fileURL)
        let sessions = (0..<24).map { index in
            session(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                name: String(format: "Session %02d", index)
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in sessions {
                group.addTask {
                    _ = try await store.upsert(item)
                }
            }
            try await group.waitForAll()
        }

        let loaded = try await store.load()
        #expect(loaded.sessions.count == sessions.count)
        #expect(Set(loaded.sessions.map(\.id)) == Set(sessions.map(\.id)))
    }

    @Test("Rename, lock, unlock, and remove preserve catalog validity")
    func catalogMutations() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let item = session(name: "Original")
        let window = WorkspaceWindow(
            tabs: [WorkspaceTab(sessionID: item.id)],
            selectedSessionID: item.id
        )
        let store = SessionCatalogStore(fileURL: fixture.fileURL)
        try await store.save(
            SessionCatalog(
                sessions: [item],
                workspace: SessionWorkspace(windows: [window])
            )
        )

        _ = try await store.rename(
            sessionID: item.id,
            to: "Renamed",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        _ = try await store.setLocked(
            sessionID: item.id,
            true,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 201)
        )
        do {
            _ = try await store.remove(sessionID: item.id)
            Issue.record("Locked session should not be removed")
        } catch let error as SessionCatalogError {
            #expect(error == .sessionLocked(item.id))
        }

        _ = try await store.setLocked(
            sessionID: item.id,
            false,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 202)
        )
        let removed = try await store.remove(sessionID: item.id)

        #expect(removed.sessions.isEmpty)
        #expect(removed.workspace.windows[0].tabs.isEmpty)
        #expect(removed.workspace.windows[0].selectedSessionID == nil)
    }

    @Test("Repeated saves atomically replace the complete envelope")
    func atomicReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = SessionCatalogStore(fileURL: fixture.fileURL)
        let first = SessionCatalog(sessions: [session(name: "First")])
        let second = SessionCatalog(sessions: [session(name: "Second")])

        try await store.save(first)
        try await store.save(second)

        let data = try Data(contentsOf: fixture.fileURL)
        let decoded = try JSONDecoder().decode(SessionCatalogEnvelope.self, from: data)
        let directoryEntries = try FileManager.default.contentsOfDirectory(
            at: fixture.directoryURL,
            includingPropertiesForKeys: nil
        )

        #expect(decoded.catalog.sessions.map(\.name) == ["Second"])
        #expect(directoryEntries.map(\.lastPathComponent) == [fixture.fileURL.lastPathComponent])
    }

    private func session(
        id: UUID = UUID(),
        name: String,
        group: String? = nil
    ) -> ComparisonSession {
        let timestamp = Date(timeIntervalSinceReferenceDate: 100)
        return ComparisonSession(
            id: id,
            kind: .textComparison,
            name: name,
            groupName: group,
            createdAt: timestamp,
            updatedAt: timestamp,
            resources: [
                SessionResourceReference(providerID: "memory", path: "left"),
                SessionResourceReference(providerID: "memory", path: "right")
            ],
            options: [
                "ignoreCase": .boolean(true),
                "labels": .strings(["左", "右"])
            ]
        )
    }
}

private struct Fixture {
    let directoryURL: URL
    let fileURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RiffaSessionCatalogTests-\(UUID().uuidString)")
        fileURL = directoryURL.appendingPathComponent("catalog.json")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
