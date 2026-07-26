import AppKit
import Foundation
import RiffaCore
import SwiftUI
import UniformTypeIdentifiers

struct ResourceToolsView: View {
    private enum Tool: String, CaseIterable, Identifiable {
        case snapshots = "Folder Snapshots"
        case archives = "Archive Browser"
        case webDAV = "WebDAV"
        case operations = "Operations"

        var id: Self { self }
        var titleKey: LocalizedStringKey {
            LocalizedStringKey(rawValue)
        }

        var symbol: String {
            switch self {
            case .snapshots: "camera.viewfinder"
            case .archives: "archivebox"
            case .webDAV: "network"
            case .operations: "clock.arrow.circlepath"
            }
        }
    }

    @State private var tool: Tool = .snapshots
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            RiffaComparisonHeader(
                title: "Resource Tools",
                subtitle: "Snapshots, safe archives, read-only WebDAV, and operation history"
            ) {
                HStack(spacing: 2) {
                    ForEach(Tool.allCases) { item in
                        ResourceToolTab(
                            title: item.titleKey,
                            systemImage: item.symbol,
                            isSelected: tool == item
                        ) {
                            tool = item
                        }
                    }
                }
                .padding(2)
                .background(
                    theme.canvas,
                    in: RoundedRectangle(cornerRadius: RiffaRadius.md)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: RiffaRadius.md)
                        .strokeBorder(theme.hairline, lineWidth: 1)
                }
            }

            switch tool {
            case .snapshots:
                FolderSnapshotToolView()
            case .archives:
                ArchiveBrowserToolView()
            case .webDAV:
                WebDAVBrowserToolView()
            case .operations:
                OperationHistoryToolView()
            }
        }
        .background(theme.canvas)
        .frame(minWidth: 900, minHeight: 580)
    }
}

private struct ResourceToolTab: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.riffaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
                .labelStyle(.titleAndIcon)
                .riffaText(.button)
                .foregroundStyle(
                    isSelected || isHovering ? theme.ink : theme.inkSubtle
                )
                .padding(.horizontal, RiffaSpacing.sm)
                .frame(minHeight: 36)
                .background(
                    isSelected
                        ? theme.surface(.three)
                        : (isHovering ? theme.surface(.two) : theme.canvas),
                    in: RoundedRectangle(cornerRadius: RiffaRadius.sm)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: RiffaRadius.sm)
                        .strokeBorder(
                            isFocused ? theme.focusRing : .clear,
                            lineWidth: isFocused ? theme.focusRingWidth : 1
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: RiffaRadius.sm))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: isHovering
        )
        .accessibilityLabel(Text(title))
        .accessibilityValue(
            isSelected ? Text("Selected") : Text("Not selected")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ResourceToolSearchField: View {
    let placeholder: LocalizedStringKey
    let accessibilityName: LocalizedStringKey
    @Binding var text: String

    @Environment(\.riffaTheme) private var theme
    @FocusState private var isFocused: Bool

    init(
        placeholder: String,
        accessibilityName: String,
        text: Binding<String>
    ) {
        self.placeholder = LocalizedStringKey(placeholder)
        self.accessibilityName = LocalizedStringKey(accessibilityName)
        self._text = text
    }

    var body: some View {
        HStack(spacing: RiffaSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.inkTertiary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .riffaText(.bodySmall)
                .foregroundStyle(theme.ink)
                .focused($isFocused)
                .accessibilityLabel(Text(accessibilityName))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    Text("Clear \(Text(accessibilityName))")
                )
                .accessibilityHint("Removes the current filter")
            }
        }
        .padding(.horizontal, RiffaSpacing.sm)
        .frame(minWidth: 160, idealWidth: 220, maxWidth: 300, minHeight: 36)
        .background(
            theme.surface(.two),
            in: RoundedRectangle(cornerRadius: RiffaRadius.md)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RiffaRadius.md)
                .strokeBorder(
                    isFocused ? theme.focusRing : theme.hairline,
                    lineWidth: isFocused ? theme.focusRingWidth : 1
                )
        }
    }
}

private struct ResourceToolActivity: View {
    let message: String

    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(spacing: RiffaSpacing.xs) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text("Working")
                .riffaText(.caption)
                .foregroundStyle(theme.inkMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: message))
        .accessibilityValue("In progress")
    }
}

private struct ResourceToolEmptyState<Actions: View>: View {
    let title: String
    let description: String
    let systemImage: String
    @ViewBuilder let actions: () -> Actions

    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack {
            Spacer(minLength: RiffaSpacing.lg)
            RiffaPanel(
                level: .one,
                cornerRadius: RiffaRadius.xl,
                padding: RiffaSpacing.lg
            ) {
                VStack(spacing: RiffaSpacing.md) {
                    Image(systemName: systemImage)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(theme.accentHover)
                        .accessibilityHidden(true)

                    VStack(spacing: RiffaSpacing.xs) {
                        Text(LocalizedStringKey(title))
                            .riffaText(.cardTitle)
                            .foregroundStyle(theme.ink)
                        Text(LocalizedStringKey(description))
                            .riffaText(.bodySmall)
                            .foregroundStyle(theme.inkSubtle)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 440)
                    }

                    actions()
                }
            }
            .frame(maxWidth: 540)
            Spacer(minLength: RiffaSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(RiffaSpacing.lg)
        .background(theme.canvas)
    }
}

private struct ResourceToolStatusBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(spacing: RiffaSpacing.sm) {
            content()
        }
        .riffaText(.caption)
        .padding(.horizontal, RiffaSpacing.sm)
        .frame(minHeight: 34)
        .background(theme.surface(.one))
        .overlay(alignment: .top) {
            RiffaHairline()
        }
    }
}

private extension UTType {
    static let riffaFolderSnapshot = UTType(
        exportedAs: "dev.riffa.folder-snapshot",
        conformingTo: .json
    )
}

private struct SnapshotDisplayRow: Identifiable, Sendable {
    let comparison: FolderSnapshotComparisonRow

    // Swift String equality is normalization-insensitive. Preserve the exact
    // UTF-8 bytes so canonically equivalent collision rows remain distinct.
    var id: Data { Data(comparison.relativePath.utf8) }
}

@MainActor
private final class FolderSnapshotToolModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case changes = "Changes"
        case errors = "Errors"

        var id: Self { self }
    }

    @Published private(set) var rows: [SnapshotDisplayRow] = []
    @Published private(set) var sourceDescription = RiffaLocalization.string(
        "No comparison loaded"
    )
    @Published private(set) var statusMessage = RiffaLocalization.string(
        "Create a portable folder snapshot or compare an existing one."
    )
    @Published private(set) var isWorking = false
    @Published var filter: Filter = .all
    @Published var search = ""
    @Published var errorMessage: String?

    var visibleRows: [SnapshotDisplayRow] {
        rows.filter { item in
            let statusMatches: Bool
            switch filter {
            case .all:
                statusMatches = true
            case .changes:
                statusMatches = item.comparison.status != .same
            case .errors:
                statusMatches = item.comparison.status == .error
            }
            return statusMatches && (
                search.isEmpty
                    || item.comparison.relativePath.localizedCaseInsensitiveContains(search)
            )
        }
    }

    var differenceCount: Int {
        rows.count { $0.comparison.status != .same }
    }

    func createSnapshot() {
        guard !isWorking,
              let folderURL = Self.chooseFolder(title: "Choose Folder to Snapshot")
        else { return }

        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string("Save Folder Snapshot")
        panel.prompt = RiffaLocalization.string("Save Snapshot")
        panel.allowedContentTypes = [.riffaFolderSnapshot]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = folderURL.lastPathComponent + ".riffasnapshot"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        guard !Self.isSameOrDescendant(outputURL, of: folderURL) else {
            errorMessage = RiffaLocalization.string(
                "Save the snapshot outside the folder being captured so the snapshot does not become one of its own future differences."
            )
            return
        }

        isWorking = true
        statusMessage = String(
            localized: "Hashing \(folderURL.lastPathComponent)…",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        Task {
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try await FolderSnapshotCapture().capture(folderAt: folderURL)
                }.value
                try await FolderSnapshotStore(fileURL: outputURL).save(snapshot)
                if snapshot.entries.count == 1 {
                    statusMessage = String(
                        localized: "Saved 1 entry to \(outputURL.lastPathComponent).",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                } else {
                    statusMessage = String(
                        localized: "Saved \(snapshot.entries.count) entries to \(outputURL.lastPathComponent).",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                }
            } catch {
                errorMessage = String(
                    localized: "Could not create snapshot: \(Self.describe(error))",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                statusMessage = RiffaLocalization.string(
                    "Snapshot creation failed."
                )
            }
            isWorking = false
        }
    }

    func compareSnapshotWithFolder() {
        guard !isWorking,
              let snapshotURL = Self.chooseSnapshot(title: "Choose Stored Snapshot"),
              let folderURL = Self.chooseFolder(title: "Choose Live Folder")
        else { return }

        isWorking = true
        statusMessage = String(
            localized: "Capturing and comparing \(folderURL.lastPathComponent)…",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let snapshot = try await FolderSnapshotStore(fileURL: snapshotURL).load()
                    return try await FolderSnapshotComparator().compare(
                        snapshot: snapshot,
                        toLiveFolderAt: folderURL
                    )
                }.value
                setResult(
                    result,
                    source: "\(snapshotURL.lastPathComponent) ↔ \(folderURL.lastPathComponent)"
                )
            } catch {
                errorMessage = String(
                    localized: "Could not compare snapshot: \(Self.describe(error))",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                statusMessage = RiffaLocalization.string(
                    "Snapshot comparison failed."
                )
            }
            isWorking = false
        }
    }

    func compareTwoSnapshots() {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.title = RiffaLocalization.string("Choose Two Folder Snapshots")
        panel.prompt = RiffaLocalization.string("Compare")
        panel.allowedContentTypes = [.riffaFolderSnapshot, .json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        guard panel.urls.count == 2 else {
            errorMessage = RiffaLocalization.string(
                "Choose exactly two snapshot files."
            )
            return
        }
        let leftURL = panel.urls[0]
        let rightURL = panel.urls[1]

        isWorking = true
        statusMessage = RiffaLocalization.string(
            "Comparing two stored snapshots…"
        )
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    async let left = FolderSnapshotStore(fileURL: leftURL).load()
                    async let right = FolderSnapshotStore(fileURL: rightURL).load()
                    return FolderSnapshotComparator().compare(
                        left: try await left,
                        right: try await right
                    )
                }.value
                setResult(
                    result,
                    source: "\(leftURL.lastPathComponent) ↔ \(rightURL.lastPathComponent)"
                )
            } catch {
                errorMessage = String(
                    localized: "Could not compare snapshots: \(Self.describe(error))",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                statusMessage = RiffaLocalization.string(
                    "Snapshot comparison failed."
                )
            }
            isWorking = false
        }
    }

    func exportResult() {
        guard !rows.isEmpty, !isWorking else { return }
        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string("Export Snapshot Comparison")
        panel.prompt = RiffaLocalization.string("Export")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Riffa-Snapshot-Comparison.json"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        let result = FolderSnapshotComparisonResult(rows: rows.map(\.comparison))
        isWorking = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    try encoder.encode(result).write(to: outputURL, options: .atomic)
                }.value
                statusMessage = String(
                    localized: "Exported comparison to \(outputURL.lastPathComponent).",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            } catch {
                errorMessage = String(
                    localized: "Could not export comparison: \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
            isWorking = false
        }
    }

    private func setResult(_ result: FolderSnapshotComparisonResult, source: String) {
        rows = result.rows.map(SnapshotDisplayRow.init(comparison:))
        sourceDescription = source
        let changes = result.rows.count { $0.status != .same }
        if changes == 1 {
            statusMessage = String(
                localized: "Compared \(result.rows.count) paths · 1 difference.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        } else {
            statusMessage = String(
                localized: "Compared \(result.rows.count) paths · \(changes) differences.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private static func chooseFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = RiffaLocalization.string(title)
        panel.prompt = RiffaLocalization.string("Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func chooseSnapshot(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = RiffaLocalization.string(title)
        panel.prompt = RiffaLocalization.string("Choose")
        panel.allowedContentTypes = [.riffaFolderSnapshot, .json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private static func isSameOrDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let output = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return output == root || output.hasPrefix(root + "/")
    }
}

private struct FolderSnapshotToolView: View {
    @StateObject private var model = FolderSnapshotToolModel()
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            RiffaComparisonControlBar {
                Button {
                    model.createSnapshot()
                } label: {
                    Label("Create Snapshot…", systemImage: "camera")
                }
                .buttonStyle(.riffaPrimary)

                Button {
                    model.compareSnapshotWithFolder()
                } label: {
                    Label("Snapshot vs Folder…", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.riffaSecondary)

                Button {
                    model.compareTwoSnapshots()
                } label: {
                    Label("Two Snapshots…", systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(.riffaSecondary)

                RiffaHairline(.vertical)
                    .frame(height: 24)

                Picker("Show", selection: $model.filter) {
                    ForEach(FolderSnapshotToolModel.Filter.allCases) { filter in
                        Text(LocalizedStringKey(filter.rawValue)).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 112)
                .accessibilityLabel("Snapshot result filter")
                .accessibilityValue(
                    RiffaLocalization.string(model.filter.rawValue)
                )

                ResourceToolSearchField(
                    placeholder: "Filter paths",
                    accessibilityName: "Snapshot path filter",
                    text: $model.search
                )

                if model.isWorking {
                    ResourceToolActivity(message: model.statusMessage)
                }

                Button {
                    model.exportResult()
                } label: {
                    Label("Export JSON…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.riffaSecondary)
                .disabled(model.rows.isEmpty || model.isWorking)
            }

            if model.rows.isEmpty {
                ResourceToolEmptyState(
                    title: "No Snapshot Comparison",
                    description: "Create a portable snapshot, compare it with a live folder, or compare two stored snapshots.",
                    systemImage: "camera.viewfinder"
                ) {
                    HStack(spacing: RiffaSpacing.xs) {
                        Button("Create Snapshot…") {
                            model.createSnapshot()
                        }
                        .buttonStyle(.riffaPrimary)

                        Button("Compare Existing…") {
                            model.compareSnapshotWithFolder()
                        }
                        .buttonStyle(.riffaSecondary)
                    }
                }
            } else {
                Table(model.visibleRows) {
                    TableColumn("Status") { item in
                        SnapshotStatusLabel(status: item.comparison.status)
                    }
                    .width(min: 100, ideal: 120, max: 150)
                    TableColumn("Relative Path") { item in
                        Text(item.comparison.relativePath)
                            .riffaText(.mono)
                            .foregroundStyle(theme.inkMuted)
                            .lineLimit(1)
                    }
                    TableColumn("Left Size") { item in
                        Text(Self.size(item.comparison.left))
                            .foregroundStyle(theme.inkSubtle)
                    }
                    .width(min: 80, ideal: 95, max: 120)
                    TableColumn("Right Size") { item in
                        Text(Self.size(item.comparison.right))
                            .foregroundStyle(theme.inkSubtle)
                    }
                    .width(min: 80, ideal: 95, max: 120)
                    TableColumn("Digest") { item in
                        Text(Self.digest(item.comparison))
                            .riffaText(.mono)
                            .foregroundStyle(theme.inkSubtle)
                    }
                    .width(min: 110, ideal: 140, max: 180)
                    TableColumn("Issues") { item in
                        Text(
                            verbatim: item.comparison.issues
                                .map { RiffaLocalization.string($0.kind.rawValue) }
                                .joined(separator: ", ")
                        )
                            .foregroundStyle(theme.danger)
                            .lineLimit(1)
                    }
                    .width(min: 80, ideal: 110, max: 150)
                }
                .scrollContentBackground(.hidden)
                .background(theme.canvas)
            }

            ResourceToolStatusBar {
                Text(model.sourceDescription)
                    .foregroundStyle(theme.inkMuted)
                    .lineLimit(1)
                Spacer()
                if !model.rows.isEmpty {
                    RiffaStatusBadge("\(model.visibleRows.count) shown")
                    RiffaStatusBadge(
                        "\(model.differenceCount) differences",
                        systemImage: "arrow.left.arrow.right",
                        tone: model.differenceCount == 0 ? .success : .secure
                    )
                }
                Text(model.statusMessage)
                    .foregroundStyle(theme.inkSubtle)
                    .lineLimit(1)
            }
        }
        .background(theme.canvas)
        .alert(
            "Folder snapshot error",
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
    }

    private static func size(_ entry: FolderSnapshotEntry?) -> String {
        guard let entry else { return "—" }
        guard entry.kind == .file else {
            return RiffaLocalization.string(entry.kind.rawValue)
        }
        guard entry.byteCount <= UInt64(Int64.max) else {
            return String(
                localized: "\(entry.byteCount) bytes",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file)
    }

    private static func digest(_ row: FolderSnapshotComparisonRow) -> String {
        let left = row.left?.sha256.map { String($0.prefix(8)) } ?? "—"
        let right = row.right?.sha256.map { String($0.prefix(8)) } ?? "—"
        return left == right ? left : "\(left) → \(right)"
    }
}

private struct SnapshotStatusLabel: View {
    let status: FolderSnapshotComparisonStatus
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: symbol)
        }
            .foregroundStyle(color)
            .riffaText(.caption)
            .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch status {
        case .same:
            RiffaLocalization.string("Same")
        case .changed:
            RiffaLocalization.string("Changed")
        case .leftOnly:
            RiffaLocalization.string("Left only")
        case .rightOnly:
            RiffaLocalization.string("Right only")
        case .typeMismatch:
            RiffaLocalization.string("Type mismatch")
        case .error:
            RiffaLocalization.string("Issue")
        }
    }

    private var symbol: String {
        switch status {
        case .same: "checkmark.circle"
        case .changed: "pencil.circle"
        case .leftOnly: "arrow.left.circle"
        case .rightOnly: "arrow.right.circle"
        case .typeMismatch: "exclamationmark.arrow.triangle.2.circlepath"
        case .error: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch status {
        case .same: theme.inkSubtle
        case .changed: theme.accentHover
        case .leftOnly, .rightOnly: theme.inkMuted
        case .typeMismatch, .error: theme.danger
        }
    }
}

private struct LoadedArchive: Sendable {
    let provider: ArchiveResourceProvider
    let entries: [ArchiveResourceEntry]
}

private actor ArchivePreviewWorker {
    func read(
        provider: ArchiveResourceProvider,
        path: String
    ) throws -> Data {
        try Task.checkCancellation()
        let data = try provider.read(path)
        try Task.checkCancellation()
        return data
    }
}

@MainActor
private final class ArchiveBrowserToolModel: ObservableObject {
    nonisolated private static let previewByteLimit = 2 * 1_024 * 1_024
    nonisolated private static let hexPreviewByteLimit = 4 * 1_024
    nonisolated private static let archiveByteLimit = 256 * 1_024 * 1_024

    @Published private(set) var archiveURL: URL?
    @Published private(set) var entries: [ArchiveResourceEntry] = []
    @Published private(set) var format: ArchiveResourceFormat?
    @Published private(set) var preview = RiffaLocalization.string(
        "Select a file to preview its contents."
    )
    @Published private(set) var statusMessage = RiffaLocalization.string(
        "No archive loaded."
    )
    @Published private(set) var isWorking = false
    @Published var search = ""
    @Published var selection: String?
    @Published var errorMessage: String?

    private var provider: ArchiveResourceProvider?
    private var previewGeneration = 0
    private var previewTask: Task<Void, Never>?
    private let previewWorker = ArchivePreviewWorker()

    var visibleEntries: [ArchiveResourceEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.path.localizedCaseInsensitiveContains(search) }
    }

    var selectedEntry: ArchiveResourceEntry? {
        guard let selection else { return nil }
        return visibleEntries.first { $0.id == selection }
    }

    func chooseArchive() {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.title = RiffaLocalization.string("Open ZIP or TAR Archive")
        panel.prompt = RiffaLocalization.string("Open Read-Only")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func refreshPreview() {
        previewTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        guard let entry = selectedEntry else {
            preview = RiffaLocalization.string(
                "Select a file to preview its contents."
            )
            return
        }

        switch entry.kind {
        case .directory:
            preview = String(
                localized: "Directory\n\nPath: \(entry.path)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        case .symbolicLink:
            preview = String(
                localized: "Symbolic link (metadata only; never followed)\n\nPath: \(entry.path)\nDestination: \(entry.symbolicLinkDestination ?? RiffaLocalization.string("Unknown"))",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        case .file:
            break
        }

        guard entry.uncompressedByteCount <= Self.previewByteLimit else {
            preview = String(
                localized: "Preview withheld\n\nThis member is \(Self.formattedSize(entry.uncompressedByteCount)); the safe preview limit is 2 MB. You can still export it explicitly.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }
        guard let provider else { return }
        preview = RiffaLocalization.string("Loading preview…")
        let path = entry.path
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let data = try await previewWorker.read(provider: provider, path: path)
                let value = await Task.detached(priority: .userInitiated) {
                    return Self.previewText(for: data)
                }.value
                try Task.checkCancellation()
                guard generation == previewGeneration else { return }
                preview = value
            } catch is CancellationError {
                return
            } catch {
                guard generation == previewGeneration else { return }
                preview = String(
                    localized: "Preview failed: \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        }
    }

    func exportSelected() {
        guard !isWorking,
              let entry = selectedEntry,
              entry.kind == .file,
              let provider
        else { return }

        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string("Export Archive Member")
        panel.prompt = RiffaLocalization.string("Export")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = URL(fileURLWithPath: entry.path).lastPathComponent
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        if let archiveURL,
           Self.urlsReferToSameItem(outputURL, archiveURL) {
            errorMessage = RiffaLocalization.string(
                "Choose a destination other than the source archive. Exporting over the open archive would destroy it."
            )
            return
        }

        isWorking = true
        let path = entry.path
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let data = try provider.read(path)
                    try data.write(to: outputURL, options: .atomic)
                }.value
                statusMessage = String(
                    localized: "Exported \(entry.path) to \(outputURL.lastPathComponent).",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            } catch {
                errorMessage = String(
                    localized: "Could not export archive member: \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
            isWorking = false
        }
    }

    private func open(_ url: URL) {
        previewTask?.cancel()
        previewGeneration += 1
        isWorking = true
        selection = nil
        preview = RiffaLocalization.string("Indexing archive…")
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let data = try BoundedLocalFileReader(
                        limits: .init(maximumByteCount: Self.archiveByteLimit)
                    ).read(url: url)
                    let provider = try ArchiveResourceProvider(data: data)
                    return LoadedArchive(provider: provider, entries: provider.list())
                }.value
                provider = loaded.provider
                archiveURL = url
                entries = loaded.entries
                format = loaded.provider.format
                if loaded.entries.count == 1 {
                    statusMessage = RiffaLocalization.string(
                        "Opened 1 validated entry."
                    )
                } else {
                    statusMessage = String(
                        localized: "Opened \(loaded.entries.count) validated entries.",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                }
                preview = loaded.entries.isEmpty
                    ? RiffaLocalization.string(
                        "This archive contains no entries."
                    )
                    : RiffaLocalization.string(
                        "Select a file to preview its contents."
                    )
            } catch {
                provider = nil
                archiveURL = nil
                entries = []
                format = nil
                preview = RiffaLocalization.string("No archive loaded.")
                statusMessage = RiffaLocalization.string(
                    "Archive open failed."
                )
                errorMessage = String(
                    localized: "Could not open archive: \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
            isWorking = false
        }
    }

    nonisolated private static func formattedSize(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private static func urlsReferToSameItem(_ left: URL, _ right: URL) -> Bool {
        left.standardizedFileURL.resolvingSymlinksInPath()
            == right.standardizedFileURL.resolvingSymlinksInPath()
    }

    nonisolated private static func previewText(for data: Data) -> String {
        if let string = String(data: data, encoding: .utf8), isMostlyText(string) {
            return string
        }
        let prefix = Data(data.prefix(hexPreviewByteLimit))
        let suffix = data.count > prefix.count
            ? String(
                localized: "\n\n… \(formattedSize(data.count - prefix.count)) more not shown",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            : ""
        return String(
            localized: "Binary preview (\(formattedSize(data.count)))\n\n",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        ) + hexDump(prefix) + suffix
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

private struct ArchiveBrowserToolView: View {
    @StateObject private var model = ArchiveBrowserToolModel()
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            RiffaComparisonControlBar {
                Button {
                    model.chooseArchive()
                } label: {
                    Label("Open Archive…", systemImage: "archivebox")
                }
                .buttonStyle(.riffaPrimary)

                ResourceToolSearchField(
                    placeholder: "Filter archive paths",
                    accessibilityName: "Archive path filter",
                    text: $model.search
                )

                if model.isWorking {
                    ResourceToolActivity(message: model.statusMessage)
                }

                Button {
                    model.exportSelected()
                } label: {
                    Label("Export Selected…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.riffaSecondary)
                .disabled(model.selectedEntry?.kind != .file || model.isWorking)
            }

            if model.archiveURL == nil {
                ResourceToolEmptyState(
                    title: "Open a ZIP or TAR Archive",
                    description: "Riffa indexes archives read-only, validates every path, and never follows stored links.",
                    systemImage: "archivebox"
                ) {
                    Button("Open Archive…") {
                        model.chooseArchive()
                    }
                    .buttonStyle(.riffaPrimary)
                }
            } else {
                HSplitView {
                    Table(model.visibleEntries, selection: $model.selection) {
                        TableColumn("Kind") { entry in
                            Label {
                                Text(verbatim: Self.kindTitle(entry.kind))
                            } icon: {
                                Image(systemName: Self.kindSymbol(entry.kind))
                            }
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(theme.inkMuted)
                        }
                        .width(min: 90, ideal: 110, max: 135)
                        TableColumn("Path") { entry in
                            Text(entry.path)
                                .riffaText(.mono)
                                .foregroundStyle(theme.inkMuted)
                                .lineLimit(1)
                        }
                        TableColumn("Size") { entry in
                            Text(ByteCountFormatter.string(
                                fromByteCount: Int64(entry.uncompressedByteCount),
                                countStyle: .file
                            ))
                            .foregroundStyle(theme.inkSubtle)
                        }
                        .width(min: 75, ideal: 90, max: 110)
                        TableColumn("Method") { entry in
                            Text(
                                verbatim: RiffaLocalization.string(
                                    entry.compression.rawValue
                                )
                            )
                                .foregroundStyle(theme.inkSubtle)
                        }
                        .width(min: 70, ideal: 80, max: 100)
                        TableColumn("Modified") { entry in
                            Text(entry.modificationDate?.formatted(
                                date: .abbreviated,
                                time: .shortened
                            ) ?? "—")
                            .foregroundStyle(theme.inkSubtle)
                        }
                        .width(min: 115, ideal: 135, max: 165)
                    }
                    .scrollContentBackground(.hidden)
                    .background(theme.canvas)
                    .frame(minWidth: 500)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    verbatim: model.selectedEntry?.path
                                        ?? RiffaLocalization.string("Preview")
                                )
                                    .riffaText(.body)
                                    .foregroundStyle(theme.ink)
                                    .lineLimit(1)
                                if let entry = model.selectedEntry {
                                    Text(
                                        verbatim: "\(Self.kindTitle(entry.kind)) · "
                                            + ByteCountFormatter.string(
                                                fromByteCount: Int64(entry.uncompressedByteCount),
                                                countStyle: .file
                                            )
                                    )
                                        .riffaText(.caption)
                                        .foregroundStyle(theme.inkSubtle)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, RiffaSpacing.sm)
                        .padding(.vertical, RiffaSpacing.xs)
                        .background(theme.surface(.two))
                        .overlay(alignment: .bottom) {
                            RiffaHairline()
                        }

                        ScrollView([.vertical, .horizontal]) {
                            Text(model.preview)
                                .riffaText(.mono)
                                .foregroundStyle(theme.inkMuted)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(RiffaSpacing.sm)
                                .accessibilityLabel("Archive preview")
                                .accessibilityValue(model.preview)
                        }
                        .background(theme.canvas)
                    }
                    .frame(minWidth: 300, idealWidth: 390)
                }
                .onChange(of: model.selection) { _, _ in
                    model.refreshPreview()
                }
            }

            ResourceToolStatusBar {
                Text(
                    verbatim: model.archiveURL?.path(percentEncoded: false)
                        ?? RiffaLocalization.string("No archive loaded")
                )
                    .riffaText(.mono)
                    .foregroundStyle(theme.inkMuted)
                    .lineLimit(1)
                Spacer()
                if let format = model.format {
                    RiffaStatusBadge(
                        verbatim: format.rawValue.uppercased(),
                        systemImage: "lock.shield",
                        tone: .secure
                    )
                }
                RiffaStatusBadge(
                    "\(model.visibleEntries.count) of \(model.entries.count) entries"
                )
                Text(model.statusMessage)
                    .foregroundStyle(theme.inkSubtle)
                    .lineLimit(1)
            }
        }
        .background(theme.canvas)
        .alert(
            "Archive browser error",
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
        .onChange(of: model.search) { _, _ in
            model.selection = nil
            model.refreshPreview()
        }
    }

    private static func kindTitle(_ kind: ArchiveResourceEntry.Kind) -> String {
        switch kind {
        case .file:
            RiffaLocalization.string("File")
        case .directory:
            RiffaLocalization.string("Folder")
        case .symbolicLink:
            RiffaLocalization.string("Link")
        }
    }

    private static func kindSymbol(_ kind: ArchiveResourceEntry.Kind) -> String {
        switch kind {
        case .file: "doc"
        case .directory: "folder"
        case .symbolicLink: "link"
        }
    }
}
