import AppKit
import Combine
import Foundation
import RiffaCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class SessionLibraryModel: ObservableObject {
    @Published private(set) var catalog: SessionCatalog = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var selectedID: UUID?
    @Published var searchText = ""
    @Published var errorMessage: String?

    private let store: SessionCatalogStore

    init(store: SessionCatalogStore? = nil) {
        self.store = store ?? SessionCatalogLocation.sharedStore
    }

    var fileURL: URL { store.fileURL }

    var selectedSession: ComparisonSession? {
        guard let selectedID else { return nil }
        return catalog.sessions.first { $0.id == selectedID }
    }

    var groups: [SessionLibraryGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = catalog.sessions.filter { session in
            guard !query.isEmpty else { return true }
            return session.name.localizedStandardContains(query)
                || (session.groupName?.localizedStandardContains(query) ?? false)
                || session.kind.displayName.localizedStandardContains(query)
                || session.resources.contains {
                    $0.providerID.localizedStandardContains(query)
                        || $0.path.localizedStandardContains(query)
                }
        }

        let grouped = Dictionary(grouping: filtered) { session -> String in
            let value = session.groupName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? SessionLibraryGroup.ungroupedID : value
        }

        return grouped.map { key, sessions in
            SessionLibraryGroup(
                id: key,
                title: key == SessionLibraryGroup.ungroupedID ? "Ungrouped" : key,
                sessions: sessions.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            )
        }
        .sorted { left, right in
            if left.id == SessionLibraryGroup.ungroupedID { return false }
            if right.id == SessionLibraryGroup.ungroupedID { return true }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }

    func loadIfNeeded() {
        guard !hasLoaded, !isLoading else { return }
        reload()
    }

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            do {
                let loaded = try await store.load()
                apply(loaded)
                hasLoaded = true
            } catch {
                present(error)
            }
            isLoading = false
        }
    }

    func create(
        kind: ComparisonSessionKind,
        name: String,
        groupName: String?,
        resources: [SessionResourceReference]
    ) {
        let now = Date()
        let session = ComparisonSession(
            kind: kind,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            groupName: groupName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            createdAt: now,
            updatedAt: now,
            resources: resources
        )
        isLoading = true
        Task {
            do {
                let updated = try await store.upsert(session)
                apply(updated, preferredSelection: session.id)
                notifyCatalogChange()
                hasLoaded = true
            } catch {
                present(error)
            }
            isLoading = false
        }
    }

    func rename(_ session: ComparisonSession, to name: String) {
        isLoading = true
        Task {
            do {
                let updated = try await store.rename(
                    sessionID: session.id,
                    to: name.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                apply(updated, preferredSelection: session.id)
                notifyCatalogChange()
            } catch {
                present(error)
            }
            isLoading = false
        }
    }

    func toggleLock(_ session: ComparisonSession) {
        isLoading = true
        Task {
            do {
                let updated = try await store.setLocked(
                    sessionID: session.id,
                    !session.isLocked
                )
                apply(updated, preferredSelection: session.id)
                notifyCatalogChange()
            } catch {
                present(error)
            }
            isLoading = false
        }
    }

    func requestDelete(_ session: ComparisonSession) -> Bool {
        guard !session.isLocked else {
            errorMessage = String(
                localized: "“\(session.name)” is locked. Unlock it before deleting it.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return false
        }
        return true
    }

    func delete(_ session: ComparisonSession) {
        isLoading = true
        Task {
            do {
                let updated = try await store.remove(sessionID: session.id)
                apply(updated)
                notifyCatalogChange()
            } catch {
                present(error)
            }
            isLoading = false
        }
    }

    func importJSON() {
        let panel = NSOpenPanel()
        panel.title = RiffaLocalization.string("Import Session Catalog")
        panel.prompt = RiffaLocalization.string("Import")
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        isLoading = true
        Task {
            do {
                // Loading through a store validates schema, timestamps, IDs,
                // workspace references and provider-neutral resource fields.
                let importStore = SessionCatalogStore(fileURL: sourceURL)
                let imported = try await importStore.load()
                try await store.save(imported)
                let persisted = try await store.load()
                apply(persisted)
                notifyCatalogChange()
                hasLoaded = true
            } catch {
                present(error)
            }
            isLoading = false
        }
    }

    func exportJSON() {
        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string("Export Session Catalog")
        panel.prompt = RiffaLocalization.string("Export")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Riffa-Sessions.json"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        let snapshot = catalog
        isLoading = true
        Task {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(SessionCatalogEnvelope(catalog: snapshot))
                try data.write(to: destinationURL, options: .atomic)
            } catch {
                present(error)
            }
            isLoading = false
        }
    }

    private func apply(_ updated: SessionCatalog, preferredSelection: UUID? = nil) {
        catalog = updated
        if let preferredSelection,
           updated.sessions.contains(where: { $0.id == preferredSelection }) {
            selectedID = preferredSelection
        } else if let selectedID,
                  updated.sessions.contains(where: { $0.id == selectedID }) {
            self.selectedID = selectedID
        } else {
            selectedID = updated.sessions.first?.id
        }
    }

    private func present(_ error: any Error) {
        errorMessage = sessionCatalogMessage(for: error)
    }

    private func notifyCatalogChange() {
        NotificationCenter.default.post(
            name: .riffaSessionCatalogDidChange,
            object: self
        )
    }
}

private struct SessionLibraryGroup: Identifiable {
    static let ungroupedID = "\u{0}riffa-ungrouped"

    let id: String
    let title: String
    let sessions: [ComparisonSession]
}

struct SessionLibraryView: View {
    @EnvironmentObject private var comparisonOpenBroker: ComparisonOpenBroker
    @EnvironmentObject private var workspaceCoordinator: WorkspaceCatalogCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.riffaTheme) private var theme
    @StateObject private var model = SessionLibraryModel()
    @State private var isCreating = false
    @State private var renameSession: ComparisonSession?
    @State private var deleteSession: ComparisonSession?
    @State private var isConfirmingDelete = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 420)
        } detail: {
            ZStack(alignment: .topLeading) {
                theme.canvas
                    .ignoresSafeArea()
                detail
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle("Session Library")
        .task {
            model.loadIfNeeded()
            workspaceCoordinator.loadIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .riffaSessionCatalogDidChange)) { _ in
            model.reload()
            workspaceCoordinator.reload()
        }
        .sheet(isPresented: $isCreating) {
            NewSessionSheet { kind, name, groupName, resources in
                model.create(
                    kind: kind,
                    name: name,
                    groupName: groupName,
                    resources: resources
                )
            }
        }
        .sheet(item: $renameSession) { session in
            RenameSessionSheet(session: session) { newName in
                model.rename(session, to: newName)
            }
        }
        .confirmationDialog(
            String(
                localized: "Delete \(deleteSession?.name ?? RiffaLocalization.string("session"))?",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            ),
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete", role: .destructive) {
                if let deleteSession {
                    model.delete(deleteSession)
                }
                deleteSession = nil
            }
            Button("Cancel", role: .cancel) {
                deleteSession = nil
            }
        } message: {
            Text("This removes the saved metadata. It does not delete any compared files.")
        }
        .alert(
            "Session library issue",
            isPresented: Binding(
                get: {
                    model.errorMessage != nil || workspaceCoordinator.errorMessage != nil
                },
                set: {
                    if !$0 {
                        model.errorMessage = nil
                        workspaceCoordinator.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                verbatim: model.errorMessage
                    ?? workspaceCoordinator.errorMessage
                    ?? RiffaLocalization.string("Unknown error")
            )
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: RiffaSpacing.xs) {
                Button {
                    isCreating = true
                } label: {
                    Label("New Session", systemImage: "plus")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.riffaPrimary)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(model.isLoading)

                Spacer()

                Menu {
                    Button("Import JSON…") { model.importJSON() }
                    Button("Export JSON…") { model.exportJSON() }
                        .disabled(!model.hasLoaded)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(theme.inkMuted)
                .accessibilityLabel("Catalog actions")
                .disabled(model.isLoading)

                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.riffaTertiary)
                .help("Reload catalog from disk")
                .disabled(model.isLoading)
            }
            .padding(RiffaSpacing.sm)

            sessionSearchField
                .padding(.horizontal, RiffaSpacing.sm)
                .padding(.bottom, RiffaSpacing.sm)

            RiffaHairline()

            WorkspaceLibrarySection()

            RiffaHairline()

            if model.isLoading && !model.hasLoaded {
                ProgressView("Loading sessions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.groups.isEmpty {
                ContentUnavailableView(
                    RiffaLocalization.string(
                        model.searchText.isEmpty
                            ? "No Saved Sessions"
                            : "No Results"
                    ),
                    systemImage: model.searchText.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(
                        verbatim: RiffaLocalization.string(
                            model.searchText.isEmpty
                                ? "Create a session to save provider-neutral comparison metadata."
                                : "Try a different name, group, kind, provider, or path."
                        )
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedID) {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                SessionLibraryRow(
                                    session: session,
                                    isSelected: model.selectedID == session.id
                                )
                                    .tag(session.id)
                            }
                        } header: {
                            Text(
                                verbatim: (
                                    group.title == "Ungrouped"
                                        ? RiffaLocalization.string("Ungrouped")
                                        : group.title
                                ).uppercased()
                            )
                                .riffaText(.eyebrow)
                                .foregroundStyle(theme.inkTertiary)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(theme.surface(.one))
            }

            RiffaHairline()

            Text(model.fileURL.path(percentEncoded: false))
                .riffaText(.mono)
                .foregroundStyle(theme.inkTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.fileURL.path(percentEncoded: false))
                .padding(.horizontal, RiffaSpacing.sm)
                .padding(.vertical, RiffaSpacing.xs)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top
        )
        .background {
            theme.surface(.one)
                .ignoresSafeArea()
        }
    }

    private var sessionSearchField: some View {
        HStack(spacing: RiffaSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.inkTertiary)
                .accessibilityHidden(true)

            TextField("Search sessions", text: $model.searchText)
                .textFieldStyle(.plain)
                .riffaText(.bodySmall)
                .foregroundStyle(theme.inkMuted)

            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear session search")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background(
            theme.surface(.two),
            in: RoundedRectangle(cornerRadius: RiffaRadius.md)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RiffaRadius.md)
                .strokeBorder(theme.hairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session = model.selectedSession {
            SessionDetailView(
                session: session,
                isBusy: model.isLoading,
                open: { openSession(session) },
                rename: {
                    if session.isLocked {
                        model.errorMessage = String(
                            localized: "“\(session.name)” is locked. Unlock it before renaming it.",
                            bundle: RiffaLocalization.localizedBundle,
                            locale: RiffaLocalization.locale
                        )
                    } else {
                        renameSession = session
                    }
                },
                toggleLock: { model.toggleLock(session) },
                delete: {
                    guard model.requestDelete(session) else { return }
                    deleteSession = session
                    isConfirmingDelete = true
                }
            )
        } else {
            ContentUnavailableView(
                "Select a Session",
                systemImage: "rectangle.stack",
                description: Text("Choose a saved session to inspect its metadata.")
            )
            .foregroundStyle(theme.inkMuted)
        }
    }

    private func openSession(_ session: ComparisonSession) {
        do {
            try comparisonOpenBroker.open(session) {
                openWindow(id: "comparison")
                NSApp.activate(ignoringOtherApps: true)
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private struct SessionLibraryRow: View {
    let session: ComparisonSession
    let isSelected: Bool
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.kind.symbol)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isSelected ? theme.accentHover : theme.inkSubtle)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .riffaText(.bodySmall)
                    .foregroundStyle(isSelected ? theme.ink : theme.inkMuted)
                    .lineLimit(1)
                Text(session.kind.displayNameKey)
                    .riffaText(.caption)
                    .foregroundStyle(theme.inkSubtle)
            }
            Spacer(minLength: 4)
            if session.isLocked {
                Image(systemName: "lock.fill")
                    .imageScale(.small)
                    .foregroundStyle(theme.secure)
                    .accessibilityLabel("Locked")
            }
        }
        .padding(.horizontal, RiffaSpacing.xs)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .listRowInsets(
            EdgeInsets(
                top: 1,
                leading: RiffaSpacing.xxs,
                bottom: 1,
                trailing: RiffaSpacing.xxs
            )
        )
        .listRowBackground(
            RoundedRectangle(cornerRadius: RiffaRadius.sm)
                .fill(isSelected ? theme.accent.opacity(0.16) : .clear)
        )
    }
}

private struct SessionDetailView: View {
    let session: ComparisonSession
    let isBusy: Bool
    let open: () -> Void
    let rename: () -> Void
    let toggleLock: () -> Void
    let delete: () -> Void
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RiffaSpacing.lg) {
                HStack(alignment: .top, spacing: RiffaSpacing.md) {
                    Image(systemName: session.kind.symbol)
                        .font(.system(size: 23, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(theme.accentHover)
                        .frame(width: 48, height: 48)
                        .background(
                            theme.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: RiffaRadius.md)
                        )
                    VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                        HStack(spacing: RiffaSpacing.xs) {
                            Text(session.name)
                                .riffaText(.cardTitle)
                                .foregroundStyle(theme.ink)
                            if session.isLocked {
                                RiffaStatusBadge(
                                    "Locked",
                                    systemImage: "lock.fill",
                                    tone: .secure
                                )
                            }
                        }
                        Text(session.kind.displayNameKey)
                            .riffaText(.bodySmall)
                            .foregroundStyle(theme.inkSubtle)
                    }
                    Spacer()
                    Button(action: open) {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.riffaPrimary)
                    .disabled(isBusy)
                    AddSessionToWorkspaceMenu(session: session)
                    Menu {
                        Button("Rename", systemImage: "pencil", action: rename)
                        Button(
                            session.isLocked
                                ? RiffaLocalization.string("Unlock")
                                : RiffaLocalization.string("Lock"),
                            systemImage: session.isLocked ? "lock.open" : "lock",
                            action: toggleLock
                        )
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .menuStyle(.button)
                    .disabled(isBusy)
                }

                SessionDetailSection(
                    title: RiffaLocalization.string("Session")
                ) {
                    VStack(spacing: 0) {
                        DetailLine(
                            label: RiffaLocalization.string("Kind"),
                            value: session.kind.displayName
                        )
                        RiffaHairline()
                        DetailLine(
                            label: RiffaLocalization.string("Group"),
                            value: session.groupName
                                ?? RiffaLocalization.string("Ungrouped")
                        )
                        RiffaHairline()
                        DetailLine(
                            label: RiffaLocalization.string("Created"),
                            value: session.createdAt.formatted(date: .abbreviated, time: .shortened)
                        )
                        RiffaHairline()
                        DetailLine(
                            label: RiffaLocalization.string("Updated"),
                            value: session.updatedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                }

                SessionDetailSection(
                    title: String(
                        localized: "Resources (\(session.resources.count))",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                ) {
                    if session.resources.isEmpty {
                        Text("No resource references")
                            .riffaText(.bodySmall)
                            .foregroundStyle(theme.inkSubtle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(session.resources.enumerated()), id: \.offset) { index, resource in
                                VStack(alignment: .leading, spacing: RiffaSpacing.xs) {
                                    Text("Resource \(index + 1)")
                                        .riffaText(.eyebrow)
                                        .foregroundStyle(theme.inkTertiary)
                                    LabeledContent("Provider", value: resource.providerID)
                                    LabeledContent("Opaque path") {
                                        Text(resource.path)
                                            .riffaText(.mono)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(.vertical, RiffaSpacing.xs)
                                if index < session.resources.count - 1 {
                                    RiffaHairline()
                                }
                            }
                        }
                    }
                }

                SessionDetailSection(
                    title: String(
                        localized: "Options (\(session.options.count))",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                ) {
                    if session.options.isEmpty {
                        Text("No saved options")
                            .riffaText(.bodySmall)
                            .foregroundStyle(theme.inkSubtle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(session.options.keys.sorted(), id: \.self) { key in
                                DetailLine(
                                    label: key,
                                    value: session.options[key]?.displayValue ?? ""
                                )
                                if key != session.options.keys.sorted().last {
                                    RiffaHairline()
                                }
                            }
                        }
                    }
                }

                Label(
                    "Open restores supported local resources using the exact saved comparison type. Other providers remain metadata-only.",
                    systemImage: "info.circle"
                )
                .riffaText(.bodySmall)
                .foregroundStyle(theme.inkSubtle)
            }
            .padding(RiffaSpacing.lg)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.canvas)
    }
}

private struct DetailLine: View {
    let label: String
    let value: String
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        LabeledContent {
            Text(verbatim: value)
                .foregroundStyle(theme.inkMuted)
                .textSelection(.enabled)
        } label: {
            Text(verbatim: label)
        }
        .riffaText(.bodySmall)
        .foregroundStyle(theme.inkSubtle)
        .padding(.vertical, RiffaSpacing.xs)
    }
}

private struct SessionDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RiffaSpacing.sm) {
            Text(verbatim: title)
                .textCase(.uppercase)
                .riffaText(.eyebrow)
                .foregroundStyle(theme.inkTertiary)
                .accessibilityAddTraits(.isHeader)

            content()
                .riffaPanel(
                    level: .one,
                    cornerRadius: RiffaRadius.lg,
                    padding: RiffaSpacing.md
                )
        }
    }
}

private struct NewSessionSheet: View {
    private enum FocusedField: Hashable {
        case name
        case kind
        case group
        case provider(UUID)
        case path(UUID)
    }

    private struct ResourceDraft: Identifiable {
        let id = UUID()
        var providerID = ""
        var path = ""
        var bookmarkData: Data?

        var isBookmarkedLocalResource: Bool {
            providerID == "local" && bookmarkData?.isEmpty == false
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.riffaTheme) private var theme
    @State private var kind: ComparisonSessionKind = .textComparison
    @State private var name = ""
    @State private var groupName = ""
    @State private var resources: [ResourceDraft] = []
    @State private var errorMessage: String?
    @FocusState private var focusedField: FocusedField?

    let create: (
        ComparisonSessionKind,
        String,
        String?,
        [SessionResourceReference]
    ) -> Void

    var body: some View {
        ZStack {
            theme.canvas
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: RiffaSpacing.md) {
                    RiffaMark()
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                        Text("NEW SESSION")
                            .riffaText(.eyebrow)
                            .foregroundStyle(theme.inkSubtle)
                        Text("Create a saved comparison")
                            .riffaText(.cardTitle)
                            .foregroundStyle(theme.ink)
                        Text("Save provider-neutral metadata and reopen it later.")
                            .riffaText(.caption)
                            .foregroundStyle(theme.inkSubtle)
                    }

                    Spacer()

                    RiffaStatusBadge(
                        "Local metadata",
                        systemImage: "lock.shield",
                        tone: .secure
                    )
                }
                .padding(.horizontal, RiffaSpacing.lg)
                .padding(.vertical, RiffaSpacing.md)
                .background(theme.surface(.one))

                RiffaHairline()

                ScrollView {
                    VStack(alignment: .leading, spacing: RiffaSpacing.lg) {
                        SessionSheetSection(
                            title: "Session",
                            description: "Name and organize this comparison."
                        ) {
                            VStack(alignment: .leading, spacing: RiffaSpacing.md) {
                                SessionSheetField(title: "Name") {
                                    TextField("For example: Release notes", text: $name)
                                        .textFieldStyle(.plain)
                                        .focused($focusedField, equals: .name)
                                        .sessionSheetControl(
                                            isFocused: focusedField == .name
                                        )
                                        .accessibilityLabel("Session name")
                                }

                                SessionSheetField(title: "Type") {
                                    Picker("Type", selection: $kind) {
                                        ForEach(ComparisonSessionKind.allCases, id: \.rawValue) { kind in
                                            Label {
                                                Text(kind.displayNameKey)
                                            } icon: {
                                                Image(systemName: kind.symbol)
                                            }
                                                .tag(kind)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .tint(theme.accent)
                                    .focused($focusedField, equals: .kind)
                                    .sessionSheetControl(
                                        isFocused: focusedField == .kind
                                    )
                                    .accessibilityLabel("Session type")
                                }

                                SessionSheetField(title: "Group") {
                                    TextField("Optional", text: $groupName)
                                        .textFieldStyle(.plain)
                                        .focused($focusedField, equals: .group)
                                        .sessionSheetControl(
                                            isFocused: focusedField == .group
                                        )
                                        .accessibilityLabel("Session group")
                                }
                            }
                        }

                        SessionSheetSection(
                            title: "Resources",
                            description: "Add up to three provider-neutral references."
                        ) {
                            VStack(alignment: .leading, spacing: RiffaSpacing.sm) {
                                HStack {
                                    Text("Compared resources")
                                        .riffaText(.bodySmall)
                                        .foregroundStyle(theme.inkMuted)
                                    Spacer()
                                    RiffaStatusBadge(
                                        "\(resources.count) of 3",
                                        systemImage: "square.stack.3d.up",
                                        tone: .neutral
                                    )
                                }

                                if resources.isEmpty {
                                    HStack(spacing: RiffaSpacing.xs) {
                                        Image(systemName: "tray")
                                            .foregroundStyle(theme.inkTertiary)
                                        Text("No resources added. You can also choose them when the comparison opens.")
                                            .riffaText(.caption)
                                            .foregroundStyle(theme.inkSubtle)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }

                                ForEach($resources) { $resource in
                                    RiffaPanel(
                                        level: .two,
                                        cornerRadius: RiffaRadius.md,
                                        padding: RiffaSpacing.sm
                                    ) {
                                        VStack(alignment: .leading, spacing: RiffaSpacing.sm) {
                                            HStack {
                                                RiffaStatusBadge(
                                                    resource.isBookmarkedLocalResource
                                                        ? "Local resource"
                                                        : "Provider resource",
                                                    systemImage: resource.isBookmarkedLocalResource
                                                        ? "lock.shield"
                                                        : "network",
                                                    tone: resource.isBookmarkedLocalResource
                                                        ? .secure
                                                        : .neutral
                                                )
                                                Spacer()
                                                Button(role: .destructive) {
                                                    resources.removeAll { $0.id == resource.id }
                                                } label: {
                                                    Image(systemName: "trash")
                                                }
                                                .buttonStyle(SessionSheetDangerButtonStyle())
                                                .accessibilityLabel("Remove resource")
                                                .help("Remove resource")
                                            }

                                            if resource.isBookmarkedLocalResource {
                                                Text(resource.path)
                                                    .riffaText(.mono)
                                                    .foregroundStyle(theme.inkMuted)
                                                    .lineLimit(2)
                                                    .truncationMode(.middle)
                                                    .textSelection(.enabled)
                                                    .frame(
                                                        maxWidth: .infinity,
                                                        alignment: .leading
                                                    )
                                            } else {
                                                SessionSheetField(title: "Provider ID") {
                                                    TextField(
                                                        "For example: webdav",
                                                        text: $resource.providerID
                                                    )
                                                    .textFieldStyle(.plain)
                                                    .focused(
                                                        $focusedField,
                                                        equals: .provider(resource.id)
                                                    )
                                                    .sessionSheetControl(
                                                        isFocused: focusedField
                                                            == .provider(resource.id),
                                                        level: .three
                                                    )
                                                }

                                                SessionSheetField(title: "Opaque path or identifier") {
                                                    TextField(
                                                        "Provider-specific path",
                                                        text: $resource.path
                                                    )
                                                    .textFieldStyle(.plain)
                                                    .focused(
                                                        $focusedField,
                                                        equals: .path(resource.id)
                                                    )
                                                    .sessionSheetControl(
                                                        isFocused: focusedField
                                                            == .path(resource.id),
                                                        level: .three
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }

                                HStack(spacing: RiffaSpacing.xs) {
                                    Button {
                                        resources.append(ResourceDraft())
                                    } label: {
                                        Label("Add Provider Resource", systemImage: "plus")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.riffaSecondary)
                                    .disabled(resources.count >= 3)

                                    Button {
                                        addLocalResources()
                                    } label: {
                                        Label("Add Local Resource…", systemImage: "folder.badge.plus")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.riffaSecondary)
                                    .disabled(resources.count >= 3)
                                }

                                HStack(alignment: .top, spacing: RiffaSpacing.xs) {
                                    Image(systemName: "lock.shield")
                                        .foregroundStyle(theme.secure)
                                    Text("Local resources use the macOS file picker so Riffa can preserve sandbox access across launches.")
                                        .riffaText(.caption)
                                        .foregroundStyle(theme.inkSubtle)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .padding(RiffaSpacing.lg)
                }

                RiffaHairline()

                HStack(spacing: RiffaSpacing.xs) {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .buttonStyle(.riffaSecondary)
                        .keyboardShortcut(.cancelAction)
                    Button("Create") { submit() }
                        .buttonStyle(.riffaPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            name.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                }
                .padding(.horizontal, RiffaSpacing.lg)
                .padding(.vertical, RiffaSpacing.sm)
                .background(theme.surface(.one))
            }
        }
        .frame(width: 620, height: 600)
        .onAppear {
            focusedField = .name
        }
        .alert(
            "Cannot create session",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                verbatim: errorMessage
                    ?? RiffaLocalization.string("Unknown error")
            )
        }
    }

    private func submit() {
        var references: [SessionResourceReference] = []
        for (index, draft) in resources.enumerated() {
            let provider = draft.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = draft.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !provider.isEmpty, !path.isEmpty else {
                errorMessage = String(
                    localized: "Resource \(index + 1) needs both a provider ID and an opaque path.",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                return
            }

            if provider == "local" {
                guard NSString(string: path).isAbsolutePath,
                      let bookmarkData = draft.bookmarkData,
                      !bookmarkData.isEmpty
                else {
                    errorMessage = String(
                        localized: "Resource \(index + 1) is a local path without a security bookmark. Remove it and use “Add Local Resource…” so Riffa can preserve access.",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                    return
                }
                references.append(
                    SessionResourceReference(
                        providerID: provider,
                        path: path,
                        bookmarkData: bookmarkData
                    )
                )
            } else {
                guard draft.bookmarkData == nil else {
                    errorMessage = String(
                        localized: "Resource \(index + 1) has a local security bookmark but uses provider “\(provider)”. Remove it and add the resource again.",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                    return
                }
                references.append(
                    SessionResourceReference(providerID: provider, path: path)
                )
            }
        }

        create(
            kind,
            name,
            groupName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            references
        )
        dismiss()
    }

    private func addLocalResources() {
        let remainingCapacity = 3 - resources.count
        guard remainingCapacity > 0 else { return }

        let panel = NSOpenPanel()
        panel.title = RiffaLocalization.string("Add Local Resources")
        panel.prompt = RiffaLocalization.string("Add")
        panel.message = String(
            localized: "Choose up to \(remainingCapacity) more files or folders.",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else { return }
        guard panel.urls.count <= remainingCapacity else {
            errorMessage = String(
                localized: "You selected \(panel.urls.count) resources, but this session has room for only \(remainingCapacity) more. No resources were added.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }

        var additions: [ResourceDraft] = []
        additions.reserveCapacity(panel.urls.count)
        for (offset, selectedURL) in panel.urls.enumerated() {
            let url = selectedURL.standardizedFileURL
            let bookmarkData: Data
            do {
                bookmarkData = try selectedURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                errorMessage = String(
                    localized: "Could not preserve sandbox access for selected resource \(offset + 1) at \(url.path): \(error.localizedDescription) No resources were added.",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                return
            }
            guard !bookmarkData.isEmpty else {
                errorMessage = String(
                    localized: "macOS returned an empty security bookmark for selected resource \(offset + 1) at \(url.path). No resources were added.",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                return
            }
            additions.append(
                ResourceDraft(
                    providerID: "local",
                    path: url.path,
                    bookmarkData: bookmarkData
                )
            )
        }
        resources.append(contentsOf: additions)
        errorMessage = nil
    }
}

private struct RenameSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.riffaTheme) private var theme
    @State private var name: String
    @FocusState private var isNameFocused: Bool

    let session: ComparisonSession
    let rename: (String) -> Void

    init(session: ComparisonSession, rename: @escaping (String) -> Void) {
        self.session = session
        self.rename = rename
        _name = State(initialValue: session.name)
    }

    var body: some View {
        ZStack {
            theme.canvas
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: RiffaSpacing.md) {
                    RiffaMark()
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                        Text("SESSION LIBRARY")
                            .riffaText(.eyebrow)
                            .foregroundStyle(theme.inkSubtle)
                        Text("Rename Session")
                            .riffaText(.cardTitle)
                            .foregroundStyle(theme.ink)
                        Text("Update the label without changing resources or options.")
                            .riffaText(.caption)
                            .foregroundStyle(theme.inkSubtle)
                    }

                    Spacer()
                }
                .padding(RiffaSpacing.lg)
                .background(theme.surface(.one))

                RiffaHairline()

                SessionSheetSection(
                    title: "Session name",
                    description: "The new name appears in the library and workspace tabs."
                ) {
                    SessionSheetField(title: "Name") {
                        TextField("Session name", text: $name)
                            .textFieldStyle(.plain)
                            .focused($isNameFocused)
                            .sessionSheetControl(isFocused: isNameFocused)
                            .accessibilityLabel("Session name")
                    }
                }
                .padding(RiffaSpacing.lg)

                Spacer(minLength: 0)

                RiffaHairline()

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
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )
                }
                .padding(.horizontal, RiffaSpacing.lg)
                .padding(.vertical, RiffaSpacing.sm)
                .background(theme.surface(.one))
            }
        }
        .frame(width: 480, height: 340)
        .onAppear {
            isNameFocused = true
        }
    }
}

private struct SessionSheetSection<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: () -> Content

    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RiffaSpacing.sm) {
            VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                Text(LocalizedStringKey(title))
                    .textCase(.uppercase)
                    .riffaText(.eyebrow)
                    .foregroundStyle(theme.inkTertiary)
                    .accessibilityAddTraits(.isHeader)
                Text(LocalizedStringKey(description))
                    .riffaText(.caption)
                    .foregroundStyle(theme.inkSubtle)
            }

            content()
                .riffaPanel(
                    level: .one,
                    cornerRadius: RiffaRadius.lg,
                    padding: RiffaSpacing.md
                )
        }
    }
}

private struct SessionSheetField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
            Text(LocalizedStringKey(title))
                .riffaText(.caption)
                .foregroundStyle(theme.inkSubtle)
            content()
        }
    }
}

private struct SessionSheetControlModifier: ViewModifier {
    let isFocused: Bool
    let level: RiffaSurfaceLevel

    @Environment(\.riffaTheme) private var theme

    func body(content: Content) -> some View {
        content
            .riffaText(.body)
            .foregroundStyle(theme.ink)
            .padding(.horizontal, RiffaSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                theme.surface(level),
                in: RoundedRectangle(cornerRadius: RiffaRadius.md)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RiffaRadius.md)
                    .strokeBorder(theme.hairline, lineWidth: 1)
            }
            .riffaFocusRing(isFocused)
    }
}

private extension View {
    func sessionSheetControl(
        isFocused: Bool,
        level: RiffaSurfaceLevel = .two
    ) -> some View {
        modifier(
            SessionSheetControlModifier(
                isFocused: isFocused,
                level: level
            )
        )
    }
}

private struct SessionSheetDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SessionSheetDangerButtonStyleBody(configuration: configuration)
    }
}

private struct SessionSheetDangerButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration

    @Environment(\.riffaTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .riffaText(.button)
            .foregroundStyle(isEnabled ? theme.danger : theme.inkTertiary)
            .frame(minWidth: 40, minHeight: 40)
            .background(
                isHovering || configuration.isPressed
                    ? theme.surface(.four)
                    : theme.surface(.three),
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

extension ComparisonSessionKind {
    var displayNameKey: LocalizedStringKey {
        LocalizedStringKey(displayNameLocalizationKey)
    }

    var displayName: String {
        RiffaLocalization.string(displayNameLocalizationKey)
    }

    private var displayNameLocalizationKey: String {
        switch self {
        case .textComparison:
            "Text Comparison"
        case .folderComparison:
            "Folder Comparison"
        case .folderSynchronization:
            "Folder Synchronization"
        case .folderMerge:
            "Folder Merge"
        case .textMerge:
            "Text Merge"
        case .textPatch:
            "Text Patch"
        case .tableComparison:
            "Table Comparison"
        case .hexadecimalComparison:
            "Hexadecimal Comparison"
        case .imageComparison:
            "Image Comparison"
        case .pdfComparison:
            "PDF Comparison"
        case .officeComparison:
            "Office Comparison"
        case .archiveComparison:
            "Archive Comparison"
        case .metadataComparison:
            "Metadata Comparison"
        case .versionComparison:
            "Version Comparison"
        case .mediaComparison:
            "Media Comparison"
        }
    }

    var symbol: String {
        switch self {
        case .textComparison: "doc.text.magnifyingglass"
        case .folderComparison: "folder.badge.questionmark"
        case .folderSynchronization: "arrow.triangle.2.circlepath"
        case .folderMerge: "arrow.triangle.merge"
        case .textMerge: "arrow.triangle.merge"
        case .textPatch: "doc.badge.arrow.up"
        case .tableComparison: "tablecells"
        case .hexadecimalComparison: "number"
        case .imageComparison: "photo.on.rectangle"
        case .pdfComparison: "doc.richtext"
        case .officeComparison: "doc.on.doc"
        case .archiveComparison: "archivebox"
        case .metadataComparison: "list.bullet.rectangle"
        case .versionComparison: "clock.arrow.circlepath"
        case .mediaComparison: "waveform"
        }
    }
}

private extension SessionOptionValue {
    var displayValue: String {
        switch self {
        case let .string(value): value
        case let .integer(value): String(value)
        case let .decimal(value): NSDecimalNumber(decimal: value).stringValue
        case let .boolean(value):
            value
                ? RiffaLocalization.string("true")
                : RiffaLocalization.string("false")
        case let .strings(value): value.joined(separator: ", ")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private func sessionCatalogMessage(for error: any Error) -> String {
    guard let error = error as? SessionCatalogError else {
        return error.localizedDescription
    }

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
            localized: "Resource \(occurrence + 1) in session \(sessionID.uuidString) needs both a provider ID and a path.",
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
            localized: "Session \(id.uuidString) no longer exists. Reload the catalog and try again.",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    case let .sessionLocked(id):
        String(
            localized: "Session \(id.uuidString) is locked. Unlock it before changing or deleting it.",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }
}
