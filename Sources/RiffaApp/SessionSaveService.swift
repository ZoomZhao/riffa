import AppKit
import Foundation
import RiffaCore
import SwiftUI

enum SessionCatalogLocation {
    static var defaultFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.riffa.Riffa", isDirectory: true)
            .appendingPathComponent("session-catalog.json", isDirectory: false)
    }

    /// All read-modify-write operations against the live catalog must share
    /// one actor. Separate `SessionCatalogStore` instances are independently
    /// isolated and could otherwise race while targeting the same JSON file.
    static let sharedStore = SessionCatalogStore(fileURL: defaultFileURL)
}

extension Notification.Name {
    static let riffaSessionCatalogDidChange = Notification.Name(
        "dev.riffa.Riffa.sessionCatalogDidChange"
    )
}

struct SessionSaveRequest: Sendable {
    let kind: ComparisonSessionKind
    let urls: [URL]
    let options: [String: SessionOptionValue]

    init(
        kind: ComparisonSessionKind,
        urls: [URL],
        options: [String: SessionOptionValue] = [:]
    ) {
        self.kind = kind
        self.urls = urls
        self.options = options
    }

    var isComplete: Bool {
        urls.count == requiredResourceCount
    }

    fileprivate var requiredResourceCount: Int {
        switch kind {
        case .folderMerge, .textMerge: 3
        case .textComparison, .folderComparison, .folderSynchronization,
             .textPatch, .tableComparison, .hexadecimalComparison, .imageComparison,
             .pdfComparison, .officeComparison, .archiveComparison, .metadataComparison, .versionComparison,
             .mediaComparison: 2
        }
    }

    var historyIdentity: Data {
        let identity = SessionHistoryIdentity(
            kind: kind,
            paths: urls.map { $0.standardizedFileURL.path },
            options: options
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(identity)) ?? Data()
    }
}

@MainActor
enum SessionSaveService {
    @discardableResult
    static func save(_ request: SessionSaveRequest) async throws -> Bool {
        guard request.isComplete else {
            throw SessionSaveError.incompleteResources(
                expected: request.requiredResourceCount,
                actual: request.urls.count
            )
        }

        let standardizedURLs = try request.urls.enumerated().map { index, url in
            guard url.isFileURL else {
                throw SessionSaveError.nonLocalURL(occurrence: index)
            }
            let standardized = url.standardizedFileURL
            guard NSString(string: standardized.path).isAbsolutePath else {
                throw SessionSaveError.relativePath(
                    occurrence: index,
                    path: standardized.path
                )
            }
            return standardized
        }

        guard let metadata = prompt(
            defaultName: standardizedURLs
                .map(\.lastPathComponent)
                .joined(separator: standardizedURLs.count == 2 ? " ↔ " : " • ")
        ) else {
            return false
        }
        guard !metadata.name.isEmpty else {
            throw SessionSaveError.emptyName
        }

        let resources = try localResources(for: standardizedURLs)

        let now = Date()
        let session = ComparisonSession(
            kind: request.kind,
            name: metadata.name,
            groupName: metadata.groupName,
            createdAt: now,
            updatedAt: now,
            resources: resources,
            options: request.options
        )
        _ = try await SessionCatalogLocation.sharedStore.upsert(session)
        NotificationCenter.default.post(name: .riffaSessionCatalogDidChange, object: nil)
        return true
    }

    static func localResources(
        for urls: [URL]
    ) throws -> [SessionResourceReference] {
        try urls.enumerated().map { index, url in
            guard url.isFileURL else {
                throw SessionSaveError.nonLocalURL(occurrence: index)
            }
            let standardized = url.standardizedFileURL
            guard NSString(string: standardized.path).isAbsolutePath else {
                throw SessionSaveError.relativePath(
                    occurrence: index,
                    path: standardized.path
                )
            }
            let bookmarkData: Data
            do {
                bookmarkData = try standardized.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                throw SessionSaveError.bookmarkCreationFailed(
                    occurrence: index,
                    path: standardized.path,
                    reason: error.localizedDescription
                )
            }
            guard !bookmarkData.isEmpty else {
                throw SessionSaveError.bookmarkCreationFailed(
                    occurrence: index,
                    path: standardized.path,
                    reason: RiffaLocalization.string(
                        "macOS returned an empty security bookmark."
                    )
                )
            }
            return SessionResourceReference(
                providerID: "local",
                path: standardized.path,
                bookmarkData: bookmarkData
            )
        }
    }

    static func message(for error: any Error) -> String {
        if let error = error as? SessionSaveError {
            return error.errorDescription
                ?? RiffaLocalization.string("The session could not be saved.")
        }
        guard let error = error as? SessionCatalogError else {
            return error.localizedDescription
        }

        return switch error {
        case let .corruptedJSON(path, reason):
            String(
                localized: "The session catalog at \(path) is corrupted and was not overwritten: \(reason)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .ioFailure(path, reason):
            String(
                localized: "Could not update the session catalog at \(path): \(reason)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .futureSchemaVersion(found, supported):
            String(
                localized: "The session catalog uses schema \(found); this Riffa version supports up to \(supported).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .migrationRequired(found, current):
            String(
                localized: "The session catalog uses schema \(found) and requires migration to schema \(current).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .duplicateSessionID(id):
            String(
                localized: "The session catalog contains duplicate session ID \(id.uuidString).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .duplicateWindowID(id):
            String(
                localized: "The session catalog contains duplicate window ID \(id.uuidString).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .duplicateTabID(id):
            String(
                localized: "The session catalog contains duplicate tab ID \(id.uuidString).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .duplicateSessionInWindow(windowID, sessionID):
            String(
                localized: "Window \(windowID.uuidString) contains session \(sessionID.uuidString) more than once.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .missingSessionReference(id):
            String(
                localized: "The session catalog references missing session \(id.uuidString).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .missingSelectedWindow(id):
            String(
                localized: "The session catalog selects missing window \(id.uuidString).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .selectedSessionNotInWindow(windowID, sessionID):
            String(
                localized: "Window \(windowID.uuidString) selects session \(sessionID.uuidString), but that session is not in the window.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .invalidResourceReference(sessionID, occurrence):
            String(
                localized: "Resource \(occurrence + 1) in session \(sessionID.uuidString) is invalid.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .invalidResourceBookmark(sessionID, occurrence):
            String(
                localized: "Resource \(occurrence + 1) in session \(sessionID.uuidString) has an invalid local security bookmark.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .invalidSessionName(id):
            String(
                localized: "Session \(id.uuidString) has an invalid name.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .invalidSessionTimestamp(id):
            String(
                localized: "Session \(id.uuidString) has invalid timestamps.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .invalidWindowName(id):
            String(
                localized: "Window \(id.uuidString) has an invalid name.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .invalidWindowFrame(id):
            String(
                localized: "Window \(id.uuidString) has an invalid saved frame.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .sessionNotFound(id):
            String(
                localized: "Session \(id.uuidString) no longer exists.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .sessionLocked(id):
            String(
                localized: "Session \(id.uuidString) is locked.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private static func prompt(defaultName: String) -> SaveMetadata? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = RiffaLocalization.string("Save Comparison Session")
        alert.informativeText = RiffaLocalization.string(
            "Save the current local resources and comparison settings to the Session Library."
        )
        alert.addButton(withTitle: RiffaLocalization.string("Save"))
        alert.addButton(withTitle: RiffaLocalization.string("Cancel"))

        let nameField = NSTextField(string: defaultName)
        nameField.placeholderString = RiffaLocalization.string("Session name")
        let groupField = NSTextField(string: "")
        groupField.placeholderString = RiffaLocalization.string("Optional group")

        let grid = NSGridView(views: [
            [
                NSTextField(
                    labelWithString: RiffaLocalization.string("Name:")
                ),
                nameField
            ],
            [
                NSTextField(
                    labelWithString: RiffaLocalization.string("Group:")
                ),
                groupField
            ]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 330
        grid.frame = NSRect(x: 0, y: 0, width: 405, height: 58)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let name = nameField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return SaveMetadata(name: "", groupName: nil)
        }
        let group = groupField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SaveMetadata(name: name, groupName: group.isEmpty ? nil : group)
    }
}

struct SessionSaveButton: View {
    let request: SessionSaveRequest
    @Binding var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        Button {
            beginSave()
        } label: {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Saving session")
            } else {
                Label("Save Session…", systemImage: "bookmark.badge.plus")
                    .labelStyle(.iconOnly)
            }
        }
        .help(
            request.isComplete
                ? RiffaLocalization.string(
                    "Save this comparison to the Session Library"
                )
                : String(
                    localized: "Choose all \(request.requiredResourceCount) resources before saving a session",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
        )
        .disabled(!request.isComplete || isSaving)
        .task(id: request.historyIdentity) {
            await RecentComparisonHistoryRecorder.record(request)
        }
    }

    private func beginSave() {
        guard request.isComplete, !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                let saved = try await SessionSaveService.save(request)
                if saved { errorMessage = nil }
            } catch {
                errorMessage = SessionSaveService.message(for: error)
            }
        }
    }
}

private struct SessionHistoryIdentity: Encodable {
    let kind: ComparisonSessionKind
    let paths: [String]
    let options: [String: SessionOptionValue]
}

private struct SaveMetadata {
    let name: String
    let groupName: String?
}

private enum SessionSaveError: Error, LocalizedError {
    case incompleteResources(expected: Int, actual: Int)
    case nonLocalURL(occurrence: Int)
    case relativePath(occurrence: Int, path: String)
    case bookmarkCreationFailed(occurrence: Int, path: String, reason: String)
    case emptyName

    var errorDescription: String? {
        switch self {
        case let .incompleteResources(expected, actual):
            String(
                localized: "This comparison needs \(expected) resources before it can be saved; only \(actual) are available.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .nonLocalURL(occurrence):
            String(
                localized: "Resource \(occurrence + 1) is not a local file URL.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .relativePath(occurrence, path):
            String(
                localized: "Resource \(occurrence + 1) does not have an absolute path: \(path)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .bookmarkCreationFailed(occurrence, path, reason):
            String(
                localized: "Could not preserve access to resource \(occurrence + 1) at \(path): \(reason) The session was not saved.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .emptyName:
            RiffaLocalization.string("Enter a non-empty session name.")
        }
    }
}
