import Combine
import Foundation
import RiffaCore
import SwiftUI

/// The single in-process coordinator for workspace mutations. Every queued
/// edit reloads the newest catalog and persists the complete workspace through
/// `SessionCatalogStore.updateWorkspace`, so windows cannot overwrite each
/// other with snapshots captured before a previous tab selection was saved.
@MainActor
final class WorkspaceCatalogCoordinator: ObservableObject {
    @Published private(set) var catalog: SessionCatalog = .empty
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var pendingMutationCount = 0
    @Published var errorMessage: String?

    private let store: SessionCatalogStore
    private var mutationTail: Task<Void, Never>?
    private var reloadRequested = false

    init(store: SessionCatalogStore? = nil) {
        self.store = store ?? SessionCatalogLocation.sharedStore
    }

    var isMutating: Bool { pendingMutationCount > 0 }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        reload()
    }

    func reload() {
        guard !isLoading, pendingMutationCount == 0 else {
            reloadRequested = true
            return
        }
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                isLoading = false
                if reloadRequested {
                    reloadRequested = false
                    reload()
                }
            }
            do {
                catalog = try await store.load()
                hasLoaded = true
            } catch {
                present(error)
            }
        }
    }

    func createWindow(
        name: String? = nil,
        initialSessionID: UUID? = nil,
        onSuccess: ((UUID) -> Void)? = nil
    ) {
        let windowID = UUID()
        enqueue(
            .createWindow(
                id: windowID,
                name: name?.trimmingCharacters(in: .whitespacesAndNewlines),
                initialSessionID: initialSessionID
            )
        ) {
            onSuccess?(windowID)
        }
    }

    func renameWindow(id: UUID, to name: String) {
        enqueue(
            .renameWindow(
                id: id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }

    func deleteWindow(id: UUID) {
        enqueue(.deleteWindow(id: id))
    }

    func addSession(_ sessionID: UUID, to windowID: UUID) {
        enqueue(.addSession(sessionID: sessionID, windowID: windowID))
    }

    func removeTab(_ tabID: UUID, from windowID: UUID) {
        enqueue(.removeTab(tabID: tabID, windowID: windowID))
    }

    func moveTab(_ tabID: UUID, in windowID: UUID, offset: Int) {
        guard offset != 0 else { return }
        enqueue(.moveTab(tabID: tabID, windowID: windowID, offset: offset))
    }

    func activateWindow(_ windowID: UUID, sessionID: UUID?) {
        enqueue(.activateWindow(id: windowID, sessionID: sessionID))
    }

    private func enqueue(
        _ mutation: WorkspaceMutation,
        onSuccess: (() -> Void)? = nil
    ) {
        let predecessor = mutationTail
        pendingMutationCount += 1

        let operation = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            defer {
                pendingMutationCount -= 1
                if pendingMutationCount == 0, reloadRequested {
                    reloadRequested = false
                    reload()
                }
            }

            do {
                let latest = try await store.load()
                var workspace = latest.workspace
                let changed = try apply(mutation, to: &workspace, catalog: latest)
                if changed {
                    catalog = try await store.updateWorkspace(workspace)
                    NotificationCenter.default.post(
                        name: .riffaSessionCatalogDidChange,
                        object: self
                    )
                } else {
                    catalog = latest
                }
                hasLoaded = true
                errorMessage = nil
                onSuccess?()
            } catch {
                present(error)
            }
        }
        mutationTail = operation
    }

    private func apply(
        _ mutation: WorkspaceMutation,
        to workspace: inout SessionWorkspace,
        catalog: SessionCatalog
    ) throws -> Bool {
        switch mutation {
        case let .createWindow(id, proposedName, initialSessionID):
            if let initialSessionID,
               !catalog.sessions.contains(where: { $0.id == initialSessionID }) {
                throw WorkspaceEditError.sessionNotFound(initialSessionID)
            }
            let trimmedName = proposedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmedName, trimmedName.isEmpty {
                throw WorkspaceEditError.emptyWindowName
            }
            let name = trimmedName ?? String(
                localized: "Window \(workspace.windows.count + 1)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            let tabs = initialSessionID.map { [WorkspaceTab(sessionID: $0)] } ?? []
            workspace.windows.append(
                WorkspaceWindow(
                    id: id,
                    name: name,
                    tabs: tabs,
                    selectedSessionID: initialSessionID
                )
            )
            workspace.selectedWindowID = id
            return true

        case let .renameWindow(id, name):
            guard !name.isEmpty else { throw WorkspaceEditError.emptyWindowName }
            guard let index = workspace.windows.firstIndex(where: { $0.id == id }) else {
                throw WorkspaceEditError.windowNotFound(id)
            }
            guard workspace.windows[index].name != name else { return false }
            workspace.windows[index].name = name
            return true

        case let .deleteWindow(id):
            guard let index = workspace.windows.firstIndex(where: { $0.id == id }) else {
                throw WorkspaceEditError.windowNotFound(id)
            }
            workspace.windows.remove(at: index)
            if workspace.selectedWindowID == id {
                workspace.selectedWindowID = workspace.windows.first?.id
            }
            return true

        case let .addSession(sessionID, windowID):
            guard catalog.sessions.contains(where: { $0.id == sessionID }) else {
                throw WorkspaceEditError.sessionNotFound(sessionID)
            }
            guard let index = workspace.windows.firstIndex(where: { $0.id == windowID }) else {
                throw WorkspaceEditError.windowNotFound(windowID)
            }
            guard !workspace.windows[index].tabs.contains(where: { $0.sessionID == sessionID }) else {
                throw WorkspaceEditError.sessionAlreadyInWindow(
                    windowID: windowID,
                    sessionID: sessionID
                )
            }
            workspace.windows[index].tabs.append(WorkspaceTab(sessionID: sessionID))
            if workspace.windows[index].selectedSessionID == nil {
                workspace.windows[index].selectedSessionID = sessionID
            }
            workspace.selectedWindowID = windowID
            return true

        case let .removeTab(tabID, windowID):
            guard let windowIndex = workspace.windows.firstIndex(where: { $0.id == windowID }) else {
                throw WorkspaceEditError.windowNotFound(windowID)
            }
            guard let tabIndex = workspace.windows[windowIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceEditError.tabNotFound(tabID)
            }
            let removedSessionID = workspace.windows[windowIndex].tabs[tabIndex].sessionID
            workspace.windows[windowIndex].tabs.remove(at: tabIndex)
            if workspace.windows[windowIndex].selectedSessionID == removedSessionID {
                let remainingTabs = workspace.windows[windowIndex].tabs
                let nextIndex = min(tabIndex, max(remainingTabs.count - 1, 0))
                workspace.windows[windowIndex].selectedSessionID =
                    remainingTabs.isEmpty ? nil : remainingTabs[nextIndex].sessionID
            }
            return true

        case let .moveTab(tabID, windowID, offset):
            guard let windowIndex = workspace.windows.firstIndex(where: { $0.id == windowID }) else {
                throw WorkspaceEditError.windowNotFound(windowID)
            }
            guard let sourceIndex = workspace.windows[windowIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceEditError.tabNotFound(tabID)
            }
            let destinationIndex = sourceIndex + offset
            guard workspace.windows[windowIndex].tabs.indices.contains(destinationIndex) else {
                return false
            }
            workspace.windows[windowIndex].tabs.swapAt(sourceIndex, destinationIndex)
            return true

        case let .activateWindow(id, sessionID):
            guard let index = workspace.windows.firstIndex(where: { $0.id == id }) else {
                throw WorkspaceEditError.windowNotFound(id)
            }
            if let sessionID,
               !workspace.windows[index].tabs.contains(where: { $0.sessionID == sessionID }) {
                throw WorkspaceEditError.sessionNotInWindow(
                    windowID: id,
                    sessionID: sessionID
                )
            }
            let changed = workspace.selectedWindowID != id
                || workspace.windows[index].selectedSessionID != sessionID
            workspace.selectedWindowID = id
            workspace.windows[index].selectedSessionID = sessionID
            return changed
        }
    }

    private func present(_ error: any Error) {
        errorMessage = workspaceCatalogMessage(for: error)
    }
}

private enum WorkspaceMutation: Sendable {
    case createWindow(id: UUID, name: String?, initialSessionID: UUID?)
    case renameWindow(id: UUID, name: String)
    case deleteWindow(id: UUID)
    case addSession(sessionID: UUID, windowID: UUID)
    case removeTab(tabID: UUID, windowID: UUID)
    case moveTab(tabID: UUID, windowID: UUID, offset: Int)
    case activateWindow(id: UUID, sessionID: UUID?)
}

private enum WorkspaceEditError: Error, LocalizedError {
    case emptyWindowName
    case windowNotFound(UUID)
    case sessionNotFound(UUID)
    case tabNotFound(UUID)
    case sessionAlreadyInWindow(windowID: UUID, sessionID: UUID)
    case sessionNotInWindow(windowID: UUID, sessionID: UUID)

    var errorDescription: String? {
        switch self {
        case .emptyWindowName:
            RiffaLocalization.string(
                "A workspace window needs a non-empty name."
            )
        case let .windowNotFound(id):
            String(
                localized: "Workspace window \(id.uuidString) no longer exists. Reload the Session Library and try again.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .sessionNotFound(id):
            String(
                localized: "Saved session \(id.uuidString) no longer exists. Reload the Session Library and try again.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .tabNotFound(id):
            String(
                localized: "Workspace tab \(id.uuidString) no longer exists.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .sessionAlreadyInWindow(windowID, sessionID):
            String(
                localized: "Session \(sessionID.uuidString) is already in window \(windowID.uuidString).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .sessionNotInWindow(windowID, sessionID):
            String(
                localized: "Session \(sessionID.uuidString) is not a tab in window \(windowID.uuidString).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }
}

struct WorkspaceWindowView: View {
    let windowID: UUID

    @EnvironmentObject private var coordinator: WorkspaceCatalogCoordinator
    @Environment(\.riffaTheme) private var theme
    @State private var selectedSessionID: UUID?

    private var workspaceWindow: WorkspaceWindow? {
        coordinator.catalog.workspace.windows.first { $0.id == windowID }
    }

    var body: some View {
        Group {
            if !coordinator.hasLoaded && coordinator.isLoading {
                ProgressView("Restoring workspace…")
                    .riffaText(.body)
                    .foregroundStyle(theme.inkMuted)
                    .tint(theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let workspaceWindow {
                windowContent(workspaceWindow)
            } else {
                ContentUnavailableView {
                    Label("Workspace Window Unavailable", systemImage: "rectangle.on.rectangle.slash")
                        .riffaText(.cardTitle)
                        .foregroundStyle(theme.ink)
                } description: {
                    Text("This window was deleted or the session catalog could not be loaded. Other workspace windows are unaffected.")
                        .riffaText(.body)
                        .foregroundStyle(theme.inkSubtle)
                } actions: {
                    Button("Reload Catalog") { coordinator.reload() }
                        .buttonStyle(.riffaPrimary)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(theme.canvas)
        .task { coordinator.loadIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .riffaSessionCatalogDidChange)) { _ in
            coordinator.reload()
        }
        .onChange(of: workspaceSignature, initial: true) { _, _ in
            synchronizeSelection()
        }
        .alert(
            "Workspace issue",
            isPresented: Binding(
                get: { coordinator.errorMessage != nil },
                set: { if !$0 { coordinator.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                verbatim: coordinator.errorMessage
                    ?? RiffaLocalization.string("Unknown error")
            )
        }
    }

    @ViewBuilder
    private func windowContent(_ window: WorkspaceWindow) -> some View {
        let tabs = window.tabs.compactMap { tab -> WorkspaceResolvedTab? in
            guard let session = coordinator.catalog.sessions.first(where: { $0.id == tab.sessionID }) else {
                return nil
            }
            return WorkspaceResolvedTab(tab: tab, session: session)
        }

        if tabs.isEmpty {
            ContentUnavailableView {
                Label("No Sessions in \(window.displayName)", systemImage: "rectangle.stack.badge.plus")
                    .riffaText(.cardTitle)
                    .foregroundStyle(theme.ink)
            } description: {
                Text("Use Session Library → Workspace Windows to add a saved session to this window.")
                    .riffaText(.body)
                    .foregroundStyle(theme.inkSubtle)
            }
            .navigationTitle(window.displayName)
        } else {
            let activeID = selectedSessionID.flatMap { selected in
                tabs.contains(where: { $0.session.id == selected }) ? selected : nil
            } ?? tabs[0].session.id
            let activeTab = tabs.first { $0.session.id == activeID } ?? tabs[0]

            VStack(spacing: 0) {
                // SwiftUI's TabView may construct more than the visible child.
                // Keep the native-looking ordered strip lightweight and mount
                // exactly one comparison so inactive large files stay unread.
                ScrollView(.horizontal) {
                    HStack(spacing: RiffaSpacing.xxs) {
                        ForEach(tabs) { item in
                            let isActive = item.session.id == activeID
                            Button {
                                selectedSessionID = item.session.id
                                coordinator.activateWindow(
                                    windowID,
                                    sessionID: item.session.id
                                )
                            } label: {
                                HStack(spacing: RiffaSpacing.xs) {
                                    Image(systemName: item.session.kind.symbol)
                                        .foregroundStyle(
                                            isActive ? theme.accent : theme.inkSubtle
                                        )
                                    Text(item.session.name)
                                        .lineLimit(1)
                                        .foregroundStyle(
                                            isActive ? theme.ink : theme.inkMuted
                                        )
                                }
                            }
                            .buttonStyle(WorkspaceTabButtonStyle(isSelected: isActive))
                            .accessibilityAddTraits(
                                isActive ? .isSelected : []
                            )
                        }
                    }
                    .padding(.horizontal, RiffaSpacing.sm)
                    .padding(.vertical, RiffaSpacing.xs)
                }
                .scrollIndicators(.hidden)
                .background(theme.surface(.one))

                RiffaHairline()

                WorkspaceResolvedSessionView(session: activeTab.session)
                    .id(activeTab.tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(window.displayName)
        }
    }

    private var workspaceSignature: WorkspaceSelectionSignature {
        WorkspaceSelectionSignature(
            hasLoaded: coordinator.hasLoaded,
            persistedSelection: workspaceWindow?.selectedSessionID,
            sessionIDs: workspaceWindow?.tabs.map(\.sessionID) ?? []
        )
    }

    private func synchronizeSelection() {
        guard coordinator.hasLoaded, let window = workspaceWindow else { return }
        let sessionIDs = window.tabs.map(\.sessionID)
        let desiredSelection: UUID?
        if let persisted = window.selectedSessionID, sessionIDs.contains(persisted) {
            desiredSelection = persisted
        } else {
            desiredSelection = sessionIDs.first
        }
        if selectedSessionID != desiredSelection {
            selectedSessionID = desiredSelection
        }
        // Do not persist merely because another open window became the global
        // selected window. Doing so would make two live windows continually
        // claim selectedWindowID from one another after every notification.
        if window.selectedSessionID != desiredSelection {
            coordinator.activateWindow(windowID, sessionID: desiredSelection)
        }
    }
}

private struct WorkspaceSelectionSignature: Equatable {
    let hasLoaded: Bool
    let persistedSelection: UUID?
    let sessionIDs: [UUID]
}

private struct WorkspaceResolvedTab: Identifiable {
    let tab: WorkspaceTab
    let session: ComparisonSession
    var id: UUID { tab.id }
}

private struct WorkspaceResolvedSessionView: View {
    let session: ComparisonSession

    @EnvironmentObject private var accessRegistry: SecurityScopedAccessRegistry
    @Environment(\.openWindow) private var openWindow
    @Environment(\.riffaTheme) private var theme
    @State private var request: ExternalOpenRequest?
    @State private var errorMessage: String?
    @State private var retryID = UUID()

    var body: some View {
        Group {
            if let request {
                ComparisonSessionContentView(
                    kind: request.kind,
                    initialURLs: request.urls,
                    initialOptions: request.options
                )
                    .id(request.id)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Could Not Restore \(session.name)", systemImage: "exclamationmark.triangle")
                        .riffaText(.cardTitle)
                        .foregroundStyle(theme.ink)
                } description: {
                    Text(errorMessage)
                        .riffaText(.body)
                        .foregroundStyle(theme.inkSubtle)
                } actions: {
                    Button("Retry") { retryID = UUID() }
                        .buttonStyle(.riffaPrimary)
                    Button("Open Session Library") { openWindow(id: "session-library") }
                        .buttonStyle(.riffaSecondary)
                }
            } else {
                ProgressView("Restoring \(session.name)…")
                    .riffaText(.body)
                    .foregroundStyle(theme.inkMuted)
                    .tint(theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.canvas)
        .task(id: WorkspaceResolutionID(updatedAt: session.updatedAt, retryID: retryID)) {
            resolve()
        }
    }

    private func resolve() {
        request = nil
        errorMessage = nil
        do {
            request = try ExternalOpenRequest(
                session: session,
                accessRegistry: accessRegistry
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct WorkspaceResolutionID: Hashable {
    let updatedAt: Date
    let retryID: UUID
}

struct ComparisonSessionContentView: View {
    let kind: SessionKind
    let initialURLs: [URL]
    let initialOptions: [String: String]

    @ViewBuilder
    var body: some View {
        switch kind {
        case .folderCompare:
            FolderCompareView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .folderMerge:
            FolderMergeView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .folderSync:
            FolderSyncView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .textCompare:
            TextCompareView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .textMerge:
            TextMergeView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .textPatch:
            TextPatchView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .hexCompare:
            HexCompareView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .mediaCompare:
            MediaCompareView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .imageCompare:
            ImageCompareView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .pdfCompare:
            PDFCompareView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .officeCompare:
            OfficeCompareView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .archiveCompare:
            ArchiveCompareView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .metadataCompare:
            MetadataCompareView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .versionCompare:
            VersionCompareView(initialURLs: initialURLs, initialOptions: initialOptions)
        case .tableCompare:
            TableCompareView(initialURLs: initialURLs, initialOptions: initialOptions)
        }
    }
}

struct WorkspaceLibrarySection: View {
    @EnvironmentObject private var coordinator: WorkspaceCatalogCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.riffaTheme) private var theme
    @State private var isManaging = false

    var body: some View {
        VStack(alignment: .leading, spacing: RiffaSpacing.sm) {
            HStack(spacing: RiffaSpacing.xs) {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(theme.inkSubtle)
                Text("Workspace Windows")
                    .riffaText(.eyebrow)
                    .foregroundStyle(theme.inkMuted)
                Spacer()

                Button {
                    coordinator.createWindow(onSuccess: openWorkspace)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(WorkspaceIconButtonStyle())
                .accessibilityLabel("Create workspace window")
                .help("Create workspace window")
                .disabled(!coordinator.hasLoaded || coordinator.isMutating)

                Button {
                    isManaging = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(WorkspaceIconButtonStyle())
                .accessibilityLabel("Manage workspace windows and tabs")
                .help("Manage workspace windows and tabs")
                .disabled(!coordinator.hasLoaded)
            }

            if coordinator.isLoading && !coordinator.hasLoaded {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else if coordinator.catalog.workspace.windows.isEmpty {
                HStack(spacing: RiffaSpacing.xs) {
                    Image(systemName: "macwindow")
                    Text("No workspace windows")
                }
                    .riffaText(.caption)
                    .foregroundStyle(theme.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, RiffaSpacing.xs)
            } else {
                ScrollView {
                    VStack(spacing: RiffaSpacing.xxs) {
                        ForEach(coordinator.catalog.workspace.windows) { window in
                            Button {
                                openWorkspace(window.id)
                            } label: {
                                HStack(spacing: RiffaSpacing.xs) {
                                    Image(systemName: "macwindow")
                                        .foregroundStyle(theme.inkSubtle)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(window.displayName)
                                            .riffaText(.bodySmall)
                                            .foregroundStyle(theme.ink)
                                            .lineLimit(1)
                                        Text(
                                            verbatim: workspaceTabCountDescription(
                                                window.tabs.count
                                            )
                                        )
                                            .riffaText(.caption)
                                            .foregroundStyle(theme.inkSubtle)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.forward.app")
                                        .imageScale(.small)
                                        .foregroundStyle(theme.inkTertiary)
                                }
                            }
                            .buttonStyle(WorkspaceLibraryRowButtonStyle())
                            .accessibilityHint("Opens this workspace window")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 148)
            }

            Button {
                isManaging = true
            } label: {
                HStack(spacing: RiffaSpacing.xs) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Manage Windows and Tabs…")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
                .buttonStyle(.riffaTertiary)
                .disabled(!coordinator.hasLoaded)
        }
        .padding(RiffaSpacing.sm)
        .background(theme.surface(.one))
        .task { coordinator.loadIfNeeded() }
        .sheet(isPresented: $isManaging) {
            WorkspaceManagerView()
                .environmentObject(coordinator)
        }
    }

    private func openWorkspace(_ id: UUID) {
        openWindow(id: "workspace", value: id)
    }
}

struct AddSessionToWorkspaceMenu: View {
    let session: ComparisonSession

    @EnvironmentObject private var coordinator: WorkspaceCatalogCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Menu {
            if coordinator.catalog.workspace.windows.isEmpty {
                Button("Create Window with Session") {
                    coordinator.createWindow(initialSessionID: session.id) { id in
                        openWindow(id: "workspace", value: id)
                    }
                }
            } else {
                ForEach(coordinator.catalog.workspace.windows) { window in
                    let alreadyAdded = window.tabs.contains { $0.sessionID == session.id }
                    Button {
                        coordinator.addSession(session.id, to: window.id)
                    } label: {
                        Label(
                            window.displayName,
                            systemImage: alreadyAdded ? "checkmark" : "macwindow.badge.plus"
                        )
                    }
                    .disabled(alreadyAdded)
                }
                Divider()
                Button("New Window with Session") {
                    coordinator.createWindow(initialSessionID: session.id) { id in
                        openWindow(id: "workspace", value: id)
                    }
                }
            }
        } label: {
            Label("Add to Workspace", systemImage: "rectangle.stack.badge.plus")
        }
        .foregroundStyle(theme.ink)
        .disabled(!coordinator.hasLoaded || coordinator.isMutating)
    }
}

private struct WorkspaceManagerView: View {
    @EnvironmentObject private var coordinator: WorkspaceCatalogCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.riffaTheme) private var theme
    @State private var selectedWindowID: UUID?
    @State private var renameWindow: WorkspaceWindow?
    @State private var deleteWindow: WorkspaceWindow?

    private var selectedWindow: WorkspaceWindow? {
        guard let selectedWindowID else { return nil }
        return coordinator.catalog.workspace.windows.first { $0.id == selectedWindowID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: RiffaSpacing.md) {
                VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                    Text("WORKSPACE")
                        .riffaText(.eyebrow)
                        .foregroundStyle(theme.inkSubtle)
                    Text("Workspace Windows")
                        .riffaText(.cardTitle)
                        .foregroundStyle(theme.ink)
                }
                Spacer()
                if coordinator.isMutating {
                    HStack(spacing: RiffaSpacing.xs) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(theme.accent)
                        Text("Saving changes")
                            .riffaText(.caption)
                            .foregroundStyle(theme.inkSubtle)
                    }
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.riffaPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, RiffaSpacing.lg)
            .padding(.vertical, RiffaSpacing.md)
            .background(theme.surface(.one))

            RiffaHairline()

            NavigationSplitView {
                VStack(spacing: 0) {
                    List(selection: $selectedWindowID) {
                        ForEach(coordinator.catalog.workspace.windows) { window in
                            let isSelected = window.id == selectedWindowID
                            HStack(spacing: RiffaSpacing.xs) {
                                Image(systemName: "macwindow")
                                    .foregroundStyle(
                                        isSelected ? theme.accent : theme.inkSubtle
                                    )
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(window.displayName)
                                        .riffaText(.bodySmall)
                                        .foregroundStyle(theme.ink)
                                        .lineLimit(1)
                                    Text(
                                        verbatim: workspaceTabCountDescription(
                                            window.tabs.count
                                        )
                                    )
                                        .riffaText(.caption)
                                        .foregroundStyle(theme.inkSubtle)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, RiffaSpacing.xs)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .tag(window.id)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .listRowInsets(
                                EdgeInsets(
                                    top: 2,
                                    leading: RiffaSpacing.xxs,
                                    bottom: 2,
                                    trailing: RiffaSpacing.xxs
                                )
                            )
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: RiffaRadius.sm)
                                    .fill(
                                        isSelected
                                            ? (
                                                theme.reducesTransparency
                                                    ? theme.surface(.two)
                                                    : theme.accent.opacity(0.16)
                                            )
                                            : Color.clear
                                    )
                            )
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .background(theme.surface(.one))

                    RiffaHairline()

                    HStack(spacing: RiffaSpacing.xxs) {
                        Button {
                            coordinator.createWindow { id in
                                selectedWindowID = id
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(WorkspaceIconButtonStyle())
                        .accessibilityLabel("Create window")
                        .help("Create window")

                        Button {
                            if let selectedWindow { renameWindow = selectedWindow }
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(WorkspaceIconButtonStyle())
                        .accessibilityLabel("Rename window")
                        .help("Rename window")
                        .disabled(selectedWindow == nil)

                        Button(role: .destructive) {
                            deleteWindow = selectedWindow
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(WorkspaceIconButtonStyle(tone: .danger))
                        .accessibilityLabel("Delete window")
                        .help("Delete window")
                        .disabled(selectedWindow == nil)

                        Spacer()
                    }
                    .padding(RiffaSpacing.xs)
                    .background(theme.surface(.one))
                    .disabled(coordinator.isMutating)
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                .background(theme.surface(.one))
            } detail: {
                if let selectedWindow {
                    WorkspaceWindowEditor(window: selectedWindow) {
                        openWindow(id: "workspace", value: selectedWindow.id)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Select a Window", systemImage: "macwindow")
                            .riffaText(.cardTitle)
                            .foregroundStyle(theme.ink)
                    } description: {
                        Text("Create or select a workspace window to manage its saved-session tabs.")
                            .riffaText(.body)
                            .foregroundStyle(theme.inkSubtle)
                    }
                    .background(theme.canvas)
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(width: 900, height: 590)
        .background(theme.canvas)
        .onChange(of: coordinator.catalog.workspace.windows.map(\.id), initial: true) { _, ids in
            if let selectedWindowID, ids.contains(selectedWindowID) { return }
            selectedWindowID = coordinator.catalog.workspace.selectedWindowID.flatMap {
                ids.contains($0) ? $0 : nil
            } ?? ids.first
        }
        .sheet(item: $renameWindow) { window in
            RenameWorkspaceWindowSheet(window: window) { name in
                coordinator.renameWindow(id: window.id, to: name)
            }
        }
        .confirmationDialog(
            String(
                localized: "Delete \(deleteWindow?.displayName ?? RiffaLocalization.string("workspace window"))?",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            ),
            isPresented: Binding(
                get: { deleteWindow != nil },
                set: { if !$0 { deleteWindow = nil } }
            )
        ) {
            Button("Delete Window", role: .destructive) {
                if let deleteWindow {
                    coordinator.deleteWindow(id: deleteWindow.id)
                }
                deleteWindow = nil
            }
            Button("Cancel", role: .cancel) { deleteWindow = nil }
        } message: {
            Text("This removes only the workspace window and its tab layout. Saved sessions and compared files are not deleted.")
        }
    }
}

private struct WorkspaceWindowEditor: View {
    let window: WorkspaceWindow
    let open: () -> Void

    @EnvironmentObject private var coordinator: WorkspaceCatalogCoordinator
    @Environment(\.riffaTheme) private var theme

    private var availableSessions: [ComparisonSession] {
        coordinator.catalog.sessions.filter { session in
            !window.tabs.contains(where: { $0.sessionID == session.id })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: RiffaSpacing.sm) {
                VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                    Text(window.displayName)
                        .riffaText(.cardTitle)
                        .foregroundStyle(theme.ink)
                    Text("The active tab and order are restored the next time this window opens.")
                        .riffaText(.caption)
                        .foregroundStyle(theme.inkSubtle)
                }
                Spacer()
                Menu {
                    if availableSessions.isEmpty {
                        Text(
                            verbatim: RiffaLocalization.string(
                                coordinator.catalog.sessions.isEmpty
                                    ? "No saved sessions"
                                    : "All sessions are already added"
                            )
                        )
                    } else {
                        ForEach(availableSessions) { session in
                            Button {
                                coordinator.addSession(session.id, to: window.id)
                            } label: {
                                Label(session.name, systemImage: session.kind.symbol)
                            }
                        }
                    }
                } label: {
                    Label("Add Session", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.riffaSecondary)
                .disabled(availableSessions.isEmpty || coordinator.isMutating)

                Button(action: open) {
                    Label("Open Window", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.riffaPrimary)
            }
            .padding(RiffaSpacing.md)
            .background(theme.surface(.one))

            RiffaHairline()

            if window.tabs.isEmpty {
                ContentUnavailableView {
                    Label("No Tabs", systemImage: "rectangle.stack.badge.plus")
                        .riffaText(.cardTitle)
                        .foregroundStyle(theme.ink)
                } description: {
                    Text("Add a saved session to create this window’s first tab.")
                        .riffaText(.body)
                        .foregroundStyle(theme.inkSubtle)
                }
                .background(theme.canvas)
            } else {
                List {
                    ForEach(Array(window.tabs.enumerated()), id: \.element.id) { index, tab in
                        if let session = coordinator.catalog.sessions.first(where: { $0.id == tab.sessionID }) {
                            let isActive = window.selectedSessionID == session.id
                            HStack(spacing: RiffaSpacing.sm) {
                                Image(systemName: session.kind.symbol)
                                    .foregroundStyle(
                                        isActive ? theme.accent : theme.inkSubtle
                                    )
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                                    Text(session.name)
                                        .riffaText(.bodySmall)
                                        .foregroundStyle(theme.ink)
                                        .lineLimit(1)
                                    Text(verbatim: session.kind.displayName)
                                        .riffaText(.caption)
                                        .foregroundStyle(theme.inkSubtle)
                                }
                                Spacer()

                                Button {
                                    coordinator.activateWindow(window.id, sessionID: session.id)
                                } label: {
                                    Image(systemName: window.selectedSessionID == session.id ? "checkmark.circle.fill" : "circle")
                                }
                                .buttonStyle(
                                    WorkspaceIconButtonStyle(
                                        tone: isActive ? .accent : .normal
                                    )
                                )
                                .accessibilityLabel(
                                    Text(
                                        verbatim: RiffaLocalization.string(
                                            isActive
                                                ? "Active tab"
                                                : "Make active tab"
                                        )
                                    )
                                )
                                .help(
                                    Text(
                                        verbatim: RiffaLocalization.string(
                                            isActive
                                                ? "Active tab"
                                                : "Make active tab"
                                        )
                                    )
                                )

                                Button {
                                    coordinator.moveTab(tab.id, in: window.id, offset: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .buttonStyle(WorkspaceIconButtonStyle())
                                .accessibilityLabel("Move tab earlier")
                                .help("Move tab earlier")
                                .disabled(index == 0)

                                Button {
                                    coordinator.moveTab(tab.id, in: window.id, offset: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .buttonStyle(WorkspaceIconButtonStyle())
                                .accessibilityLabel("Move tab later")
                                .help("Move tab later")
                                .disabled(index == window.tabs.count - 1)

                                Button(role: .destructive) {
                                    coordinator.removeTab(tab.id, from: window.id)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(WorkspaceIconButtonStyle(tone: .danger))
                                .accessibilityLabel("Remove tab from this window")
                                .help("Remove tab from this window")
                            }
                            .padding(.horizontal, RiffaSpacing.sm)
                            .padding(.vertical, RiffaSpacing.xs)
                            .listRowInsets(
                                EdgeInsets(
                                    top: RiffaSpacing.xxs,
                                    leading: RiffaSpacing.sm,
                                    bottom: RiffaSpacing.xxs,
                                    trailing: RiffaSpacing.sm
                                )
                            )
                            .listRowSeparator(.hidden)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: RiffaRadius.md)
                                    .fill(theme.surface(.one))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: RiffaRadius.md)
                                            .strokeBorder(theme.hairline, lineWidth: 1)
                                    }
                            )
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(theme.canvas)
                .disabled(coordinator.isMutating)
            }
        }
        .background(theme.canvas)
    }
}

private struct RenameWorkspaceWindowSheet: View {
    let window: WorkspaceWindow
    let rename: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.riffaTheme) private var theme
    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(window: WorkspaceWindow, rename: @escaping (String) -> Void) {
        self.window = window
        self.rename = rename
        _name = State(initialValue: window.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RiffaSpacing.lg) {
            VStack(alignment: .leading, spacing: RiffaSpacing.xs) {
                Text("Rename Workspace Window")
                    .riffaText(.cardTitle)
                    .foregroundStyle(theme.ink)
                Text("Choose a concise name that identifies this saved tab layout.")
                    .riffaText(.body)
                    .foregroundStyle(theme.inkSubtle)
            }

            TextField("Window name", text: $name)
                .textFieldStyle(.plain)
                .riffaText(.body)
                .foregroundStyle(theme.ink)
                .padding(.horizontal, RiffaSpacing.sm)
                .frame(minHeight: 44)
                .background(
                    theme.surface(.one),
                    in: RoundedRectangle(cornerRadius: RiffaRadius.md)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: RiffaRadius.md)
                        .strokeBorder(theme.hairline, lineWidth: 1)
                }
                .focused($isNameFocused)
                .riffaFocusRing(isNameFocused)
                .accessibilityLabel("Workspace window name")

            HStack(spacing: RiffaSpacing.xs) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.riffaSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    rename(name)
                    dismiss()
                }
                .buttonStyle(.riffaPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(RiffaSpacing.lg)
        .frame(width: 460)
        .background(theme.canvas)
        .onAppear {
            isNameFocused = true
        }
    }
}

private enum WorkspaceIconButtonTone: Sendable {
    case normal
    case accent
    case danger
}

private struct WorkspaceIconButtonStyle: ButtonStyle {
    let tone: WorkspaceIconButtonTone

    init(tone: WorkspaceIconButtonTone = .normal) {
        self.tone = tone
    }

    func makeBody(configuration: Configuration) -> some View {
        WorkspaceIconButtonStyleBody(tone: tone, configuration: configuration)
    }
}

private struct WorkspaceIconButtonStyleBody: View {
    let tone: WorkspaceIconButtonTone
    let configuration: ButtonStyle.Configuration

    @Environment(\.riffaTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var foreground: Color {
        guard isEnabled else { return theme.inkTertiary }
        return switch tone {
        case .normal: theme.inkMuted
        case .accent: theme.accent
        case .danger: theme.danger
        }
    }

    private var background: Color {
        guard isEnabled else { return theme.surface(.one) }
        return isHovering || configuration.isPressed
            ? theme.surface(.two)
            : theme.surface(.one)
    }

    var body: some View {
        configuration.label
            .riffaText(.button)
            .foregroundStyle(foreground)
            .frame(minWidth: 40, minHeight: 40)
            .background(
                background,
                in: RoundedRectangle(cornerRadius: RiffaRadius.md)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RiffaRadius.md)
                    .strokeBorder(
                        isFocused ? theme.focusRing : theme.hairline,
                        lineWidth: isFocused ? theme.focusRingWidth : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: RiffaRadius.md))
            .onHover { isHovering = isEnabled && $0 }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovering
            )
    }
}

private struct WorkspaceTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        WorkspaceTabButtonStyleBody(
            isSelected: isSelected,
            configuration: configuration
        )
    }
}

private struct WorkspaceTabButtonStyleBody: View {
    let isSelected: Bool
    let configuration: ButtonStyle.Configuration

    @Environment(\.riffaTheme) private var theme
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var background: Color {
        isSelected || isHovering || configuration.isPressed
            ? theme.surface(.two)
            : theme.surface(.one)
    }

    private var border: Color {
        if isFocused {
            return theme.focusRing
        }
        if isSelected || isHovering {
            return theme.hairlineStrong
        }
        return .clear
    }

    var body: some View {
        configuration.label
            .riffaText(.bodySmall)
            .padding(.horizontal, RiffaSpacing.sm)
            .frame(minHeight: 40)
            .background(
                background,
                in: RoundedRectangle(cornerRadius: RiffaRadius.md)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RiffaRadius.md)
                    .strokeBorder(
                        border,
                        lineWidth: isFocused ? theme.focusRingWidth : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: RiffaRadius.md))
            .onHover { isHovering = $0 }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovering
            )
    }
}

private struct WorkspaceLibraryRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkspaceLibraryRowButtonStyleBody(configuration: configuration)
    }
}

private struct WorkspaceLibraryRowButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration

    @Environment(\.riffaTheme) private var theme
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .padding(.horizontal, RiffaSpacing.xs)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                isHovering || configuration.isPressed
                    ? theme.surface(.two)
                    : theme.surface(.one),
                in: RoundedRectangle(cornerRadius: RiffaRadius.md)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RiffaRadius.md)
                    .strokeBorder(
                        isFocused
                            ? theme.focusRing
                            : (isHovering ? theme.hairlineStrong : theme.hairline),
                        lineWidth: isFocused ? theme.focusRingWidth : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: RiffaRadius.md))
            .onHover { isHovering = $0 }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovering
            )
    }
}

extension WorkspaceWindow {
    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty
            ? RiffaLocalization.string("Workspace Window")
            : trimmed
    }
}

private func workspaceTabCountDescription(_ count: Int) -> String {
    if count == 1 {
        return RiffaLocalization.string("1 tab")
    }
    return String(
        localized: "\(count) tabs",
        bundle: RiffaLocalization.localizedBundle,
        locale: RiffaLocalization.locale
    )
}

private func workspaceCatalogMessage(for error: any Error) -> String {
    if let error = error as? WorkspaceEditError {
        return error.errorDescription
            ?? RiffaLocalization.string("The workspace could not be updated.")
    }
    if let error = error as? SessionCatalogError {
        return switch error {
        case let .corruptedJSON(path, reason):
            String(
                localized: "The catalog at \(path) is not valid JSON: \(reason)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .ioFailure(path, reason):
            String(
                localized: "Could not read or write \(path): \(reason)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .futureSchemaVersion(found, supported):
            String(
                localized: "This catalog uses schema \(found), but this Riffa version supports up to \(supported).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .migrationRequired(found, current):
            String(
                localized: "This catalog uses schema \(found) and must be migrated to schema \(current).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .duplicateSessionID(id):
            String(
                localized: "The catalog contains duplicate session ID \(id.uuidString).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .duplicateWindowID(id):
            String(
                localized: "The catalog contains duplicate window ID \(id.uuidString).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .duplicateTabID(id):
            String(
                localized: "The catalog contains duplicate tab ID \(id.uuidString).",
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
                localized: "The workspace references missing session \(id.uuidString).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .missingSelectedWindow(id):
            String(
                localized: "The workspace selects missing window \(id.uuidString).",
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
                localized: "Resource \(occurrence + 1) in session \(sessionID.uuidString) has an invalid security bookmark.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .invalidSessionName(id):
            String(
                localized: "Session \(id.uuidString) needs a non-empty name.",
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
                localized: "Window \(id.uuidString) needs a non-empty name.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .invalidWindowFrame(id):
            String(
                localized: "Window \(id.uuidString) has an invalid frame.",
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
    return error.localizedDescription
}
