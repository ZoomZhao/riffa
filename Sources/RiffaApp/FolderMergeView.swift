import AppKit
import Foundation
import RiffaCore
import SwiftUI

@MainActor
private final class FolderMergeModel: ObservableObject {
    enum Side { case base, left, right }
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case changes = "Changes"
        case conflicts = "Conflicts"
        var id: Self { self }
    }
    enum Resolution: String, CaseIterable, Identifiable {
        case unresolved = "Unresolved"
        case left = "Left"
        case base = "Base"
        case right = "Right"
        case omit = "Omit"
        var id: Self { self }
    }

    @Published private(set) var baseURL: URL?
    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var result: FolderMergeResult?
    @Published private(set) var isLoading = false
    @Published var filter: Filter = .all
    @Published var resolutions: [String: Resolution] = [:]
    @Published var errorMessage: String?
    @Published private(set) var isMaterializing = false
    @Published private(set) var lastExecutionMessage: String?

    private var analysisTask: Task<Void, Never>?

    var visibleNodes: [FolderMergeNode] {
        guard let result else { return [] }
        return switch filter {
        case .all: result.nodes
        case .changes: result.nodes.filter { $0.status != .unchanged }
        case .conflicts: result.nodes.filter { isConflict($0.status) }
        }
    }

    var unresolvedCount: Int {
        guard let result else { return 0 }
        return result.nodes.count { node in
            isConflict(node.status) && resolutions[node.relativePath, default: .unresolved] == .unresolved
        }
    }

    func url(for side: Side) -> URL? {
        switch side {
        case .base: baseURL
        case .left: leftURL
        case .right: rightURL
        }
    }

    func chooseFolder(for side: Side) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "Choose \(side.title) Folder",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        panel.prompt = RiffaLocalization.string("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch side {
        case .base: baseURL = url
        case .left: leftURL = url
        case .right: rightURL = url
        }
        analyzeIfReady()
    }

    func loadDemo() {
        do {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "RiffaMergeDemo", directoryHint: .isDirectory)
            let base = root.appending(path: "base", directoryHint: .isDirectory)
            let left = root.appending(path: "left", directoryHint: .isDirectory)
            let right = root.appending(path: "right", directoryHint: .isDirectory)
            for directory in [base, left, right] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try write("Riffa\n", name: "README.txt", roots: [base, left, right])
            try write("navy\n", name: "theme.txt", roots: [base])
            try write("cyan\n", name: "theme.txt", roots: [left])
            try write("coral\n", name: "theme.txt", roots: [right])
            try write("manual\n", name: "updates.txt", roots: [base, right])
            try write("automatic\n", name: "updates.txt", roots: [left])
            try write("left addition\n", name: "left.txt", roots: [left])
            try write("right addition\n", name: "right.txt", roots: [right])
            try write("remove me\n", name: "retired.txt", roots: [base])
            baseURL = base
            leftURL = left
            rightURL = right
            errorMessage = nil
            analyzeIfReady()
        } catch {
            errorMessage = String(
                localized: "Could not create merge demo: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    func refresh() { analyzeIfReady() }

    func openInitial(_ urls: [URL], options: [String: String] = [:]) {
        if let value = options["resultFilter"].flatMap(Filter.init(rawValue:)) {
            filter = value
        }
        guard !urls.isEmpty else { return }
        guard urls.count == 3 else {
            errorMessage = RiffaLocalization.string(
                "Folder Merge requires exactly three folders in Base, Left, Right order."
            )
            return
        }

        baseURL = urls[0].standardizedFileURL
        leftURL = urls[1].standardizedFileURL
        rightURL = urls[2].standardizedFileURL
        errorMessage = nil
        analyzeIfReady()
    }

    func materializeOutput() {
        guard let result, let baseURL, let leftURL, let rightURL,
              unresolvedCount == 0, !isLoading, !isMaterializing
        else { return }

        guard let outputURL = chooseDirectory(
            title: RiffaLocalization.string(
                "Choose an Independent Output Folder"
            ),
            message: RiffaLocalization.string(
                "The output must not overlap Base, Left, or Right. Existing output items may be replaced after backup."
            ),
            prompt: RiffaLocalization.string("Use as Output")
        ) else { return }
        guard let backupURL = chooseDirectory(
            title: RiffaLocalization.string("Choose a Separate Backup Folder"),
            message: RiffaLocalization.string(
                "Choose a fresh folder outside Base, Left, Right, and Output. Replaced or omitted output items are moved here."
            ),
            prompt: RiffaLocalization.string("Use for Backups")
        ) else { return }

        let outputResolutions = resolutions.compactMapValues { resolution -> FolderMergeConflictResolution? in
            switch resolution {
            case .unresolved: nil
            case .left: .useLeft
            case .base: .useBase
            case .right: .useRight
            case .omit: .omit
            }
        }

        isMaterializing = true
        errorMessage = nil
        lastExecutionMessage = nil
        Task { [weak self] in
            let preflight = await Task.detached(priority: .userInitiated) {
                FolderMergeOutputExecutor().execute(
                    plan: result.plan,
                    resolutions: outputResolutions,
                    baseRoot: baseURL,
                    leftRoot: leftURL,
                    rightRoot: rightURL,
                    outputRoot: outputURL,
                    backupRoot: backupURL
                )
            }.value
            guard let self else { return }

            guard preflight.status == .dryRun else {
                isMaterializing = false
                errorMessage = Self.issueMessage(
                    preflight,
                    fallback: RiffaLocalization.string(
                        "The output plan did not pass preflight."
                    )
                )
                return
            }

            let confirmation = NSAlert()
            confirmation.alertStyle = .warning
            confirmation.messageText = RiffaLocalization.string(
                "Create or update the merge output?"
            )
            confirmation.informativeText = String(
                localized: "Preflight passed for \(result.plan.actions.count) planned items. Existing output items will first move to \(backupURL.path). Any execution failure triggers a best-effort rollback.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            confirmation.addButton(
                withTitle: RiffaLocalization.string("Create Output")
            )
            confirmation.addButton(
                withTitle: RiffaLocalization.string("Cancel")
            )
            guard confirmation.runModal() == .alertFirstButtonReturn else {
                isMaterializing = false
                return
            }

            do {
                let journalDirectoryURL = JournaledLocalFolderSyncExecutor
                    .defaultApplicationJournalDirectoryURL
                let log = try await Task.detached(priority: .userInitiated) {
                    try await JournaledFolderMergeOutputExecutor(
                        journalDirectoryURL: journalDirectoryURL
                    ).execute(
                        plan: result.plan,
                        resolutions: outputResolutions,
                        baseRoot: baseURL,
                        leftRoot: leftURL,
                        rightRoot: rightURL,
                        outputRoot: outputURL,
                        backupRoot: backupURL,
                        options: .init(dryRun: false)
                    )
                }.value
                isMaterializing = false
                switch log.status {
                case .completed:
                    lastExecutionMessage = String(
                        localized: "Output created at \(outputURL.path)",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                case .dryRun:
                    lastExecutionMessage = RiffaLocalization.string(
                        "Preflight passed; no files were written."
                    )
                case .refused, .failedRolledBack, .failedRollbackIncomplete:
                    errorMessage = Self.issueMessage(
                        log,
                        fallback: RiffaLocalization.string(
                            "The output could not be created safely."
                        )
                    )
                    if log.status == .failedRolledBack {
                        lastExecutionMessage = RiffaLocalization.string(
                            "Execution failed; completed changes were rolled back."
                        )
                    }
                }
            } catch {
                isMaterializing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func resolve(path: String, using resolution: Resolution) {
        resolutions[path] = resolution
    }

    func actionDescription(for node: FolderMergeNode) -> String {
        if isConflict(node.status) {
            switch resolutions[node.relativePath, default: .unresolved] {
            case .unresolved:
                return RiffaLocalization.string("Resolve before materializing")
            case .left:
                return RiffaLocalization.string("Copy from Left")
            case .base:
                return RiffaLocalization.string("Copy from Base")
            case .right:
                return RiffaLocalization.string("Copy from Right")
            case .omit:
                return RiffaLocalization.string("Omit from output")
            }
        }
        return result?.plan.actions.first { $0.outputRelativePath == node.relativePath }?.kind.displayName ?? "—"
    }

    private func analyzeIfReady() {
        analysisTask?.cancel()
        guard let baseURL, let leftURL, let rightURL else {
            result = nil
            resolutions = [:]
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        analysisTask = Task { [weak self] in
            let result = await FolderMerge().analyze(
                baseURL: baseURL,
                leftURL: leftURL,
                rightURL: rightURL
            )
            guard !Task.isCancelled, let self else { return }
            self.result = result
            self.resolutions = Dictionary(
                uniqueKeysWithValues: result.nodes
                    .filter { self.isConflict($0.status) }
                    .map { ($0.relativePath, Resolution.unresolved) }
            )
            self.isLoading = false
            if let issue = result.nodes.lazy.flatMap(\.issues).first {
                self.errorMessage = issue.errorDescription
            }
        }
    }

    private func isConflict(_ status: FolderMergeStatus) -> Bool {
        status == .conflict || status == .typeConflict || status == .error
    }

    private func write(_ text: String, name: String, roots: [URL]) throws {
        for root in roots {
            try Data(text.utf8).write(to: root.appending(path: name), options: .atomic)
        }
    }

    private func chooseDirectory(title: String, message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func issueMessage(
        _ log: FolderMergeOutputExecutionLog,
        fallback: String
    ) -> String {
        let details = log.issues.map(\.message).joined(separator: "\n")
        return details.isEmpty ? fallback : details
    }
}

struct FolderMergeView: View {
    @StateObject private var model = FolderMergeModel()
    @Environment(\.riffaTheme) private var theme
    private let initialURLs: [URL]
    private let initialOptions: [String: String]

    init(
        initialURLs: [URL] = [],
        initialOptions: [String: String] = [:]
    ) {
        self.initialURLs = initialURLs
        self.initialOptions = initialOptions
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            controlBar
            pathBar
            if model.baseURL == nil || model.leftURL == nil || model.rightURL == nil {
                emptyState
            } else if model.isLoading && model.result == nil {
                ProgressView("Comparing three folder trees by content…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.canvas)
            } else if let result = model.result {
                mergeContent(result)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Folder Merge")
        .background(theme.canvas)
        .task(id: ComparisonInitialLoad(urls: initialURLs, options: initialOptions)) {
            model.openInitial(initialURLs, options: initialOptions)
        }
        .alert(
            "Folder merge issue",
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

    private var header: some View {
        RiffaComparisonHeader(
            title: "Folder Merge",
            subtitle: "Base + Left + Right → independent output plan"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .folderMerge,
                    urls: [model.baseURL, model.leftURL, model.rightURL].compactMap { $0 },
                    options: [
                        "resultFilter": .string(model.filter.rawValue)
                    ]
                ),
                errorMessage: $model.errorMessage
            )

            Button { model.refresh() } label: {
                Label("Refresh folder merge", systemImage: "arrow.clockwise")
            }
                .labelStyle(.iconOnly)
                .buttonStyle(.riffaIcon)
                .accessibilityLabel("Refresh folder merge")
                .disabled(model.isLoading)

            Button {
                model.materializeOutput()
            } label: {
                Label(
                    model.isMaterializing
                        ? RiffaLocalization.string("Preparing…")
                        : RiffaLocalization.string("Create Output…"),
                    systemImage: "externaldrive.badge.plus"
                )
            }
            .buttonStyle(.riffaPrimary)
            .disabled(
                model.result == nil
                    || model.unresolvedCount > 0
                    || model.isLoading
                    || model.isMaterializing
            )
        }
    }

    private var controlBar: some View {
        RiffaComparisonControlBar {
            Picker("Filter", selection: $model.filter) {
                ForEach(FolderMergeModel.Filter.allCases) {
                    Text(LocalizedStringKey($0.rawValue)).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            if let result = model.result {
                RiffaStatusBadge(
                    verbatim: String(
                        localized: "\(model.unresolvedCount) unresolved",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    ),
                    systemImage: model.unresolvedCount == 0
                        ? "checkmark.circle"
                        : "exclamationmark.triangle",
                    tone: model.unresolvedCount == 0 ? .success : .warning
                )
                .help(
                    String(
                        localized: "\(result.summary.conflictCount) conflicts, \(result.summary.errorCount) errors",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                )
            }
        }
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            RiffaResourcePathButton(
                title: "Base folder",
                url: model.url(for: .base),
                emptyTitle: "Choose a folder…",
                systemImage: "folder",
                accessibilityHint: "Choose the common base folder"
            ) {
                model.chooseFolder(for: .base)
            }

            RiffaResourcePathButton(
                title: "Left folder",
                url: model.url(for: .left),
                emptyTitle: "Choose a folder…",
                systemImage: "folder",
                accessibilityHint: "Choose the left variant folder"
            ) {
                model.chooseFolder(for: .left)
            }

            RiffaResourcePathButton(
                title: "Right folder",
                url: model.url(for: .right),
                emptyTitle: "Choose a folder…",
                systemImage: "folder",
                accessibilityHint: "Choose the right variant folder"
            ) {
                model.chooseFolder(for: .right)
            }
        }
    }

    private func mergeContent(_ result: FolderMergeResult) -> some View {
        VStack(spacing: 0) {
            Table(model.visibleNodes) {
                TableColumn("Status") { node in FolderMergeStatusLabel(status: node.status) }
                    .width(110)
                TableColumn("Path") { node in
                    HStack(spacing: 7) {
                        Image(systemName: node.kind == .directory ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                        Text(node.relativePath).font(.system(.body, design: .monospaced)).lineLimit(1)
                    }
                }
                .width(min: 180, ideal: 220, max: 280)
                TableColumn("Base") { node in presence(node.base) }.width(68)
                TableColumn("Left") { node in presence(node.left) }.width(68)
                TableColumn("Right") { node in presence(node.right) }.width(68)
                TableColumn("Resolution / Plan") { node in
                    if isConflict(node.status) {
                        Picker(
                            "Resolution",
                            selection: Binding(
                                get: { model.resolutions[node.relativePath, default: .unresolved] },
                                set: { model.resolve(path: node.relativePath, using: $0) }
                            )
                        ) {
                            ForEach(FolderMergeModel.Resolution.allCases) {
                                Text(LocalizedStringKey($0.rawValue)).tag($0)
                            }
                        }
                        .labelsHidden()
                    } else {
                        Text(verbatim: model.actionDescription(for: node))
                        .foregroundStyle(.secondary)
                    }
                }
                .width(min: 145, ideal: 170, max: 190)
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)

            RiffaStatusBar {
                RiffaStatusBadge(
                    verbatim: String(
                        localized: "\(result.summary.automaticallyResolvedCount) automatic",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    ),
                    systemImage: "checkmark.circle",
                    tone: .success
                )
                RiffaStatusBadge(
                    verbatim: String(
                        localized: "\(result.summary.deletionCount) deletions",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    ),
                    systemImage: "minus.circle",
                    tone: .neutral
                )
                RiffaStatusBadge(
                    verbatim: String(
                        localized: "\(result.summary.conflictCount) conflicts",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    ),
                    systemImage: "exclamationmark.triangle",
                    tone: result.summary.hasConflicts ? .warning : .neutral
                )
                Spacer()
                if let message = model.lastExecutionMessage {
                    Text(message)
                        .foregroundStyle(theme.inkSubtle)
                        .lineLimit(1)
                        .help(message)
                }
            }
        }
    }

    private var emptyState: some View {
        RiffaEmptyState(
            title: "Choose Base, Left, and Right folders",
            description: "Riffa compares all three trees without modifying "
                + "them and builds an independent output plan.",
            systemImage: "arrow.triangle.merge"
        ) {
            HStack {
                Button("Choose Base") { model.chooseFolder(for: .base) }
                    .buttonStyle(.riffaSecondary)
                Button("Choose Left") { model.chooseFolder(for: .left) }
                    .buttonStyle(.riffaSecondary)
                Button("Choose Right") { model.chooseFolder(for: .right) }
                    .buttonStyle(.riffaSecondary)
                Button("Load Demo") { model.loadDemo() }
                    .buttonStyle(.riffaPrimary)
            }
        }
    }

    private func presence(_ entry: ResourceEntry?) -> some View {
        let title = entry == nil
            ? RiffaLocalization.string("Missing")
            : RiffaLocalization.string("Present")
        return Label(
            title,
            systemImage: entry == nil ? "minus" : "checkmark"
        )
            .riffaText(.caption)
            .foregroundStyle(entry == nil ? theme.inkTertiary : theme.inkMuted)
            .accessibilityLabel(title)
    }

    private func isConflict(_ status: FolderMergeStatus) -> Bool {
        status == .conflict || status == .typeConflict || status == .error
    }
}

private struct FolderMergeStatusLabel: View {
    let status: FolderMergeStatus
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: symbol)
        }
            .riffaText(.caption)
            .foregroundStyle(color)
            .accessibilityLabel(title)
    }
    private var title: String {
        switch status {
        case .unchanged: RiffaLocalization.string("Unchanged")
        case .leftChanged: RiffaLocalization.string("Left changed")
        case .rightChanged: RiffaLocalization.string("Right changed")
        case .bothChangedSame: RiffaLocalization.string("Both same")
        case .leftDeleted: RiffaLocalization.string("Left deleted")
        case .rightDeleted: RiffaLocalization.string("Right deleted")
        case .bothDeleted: RiffaLocalization.string("Both deleted")
        case .conflict: RiffaLocalization.string("Conflict")
        case .typeConflict: RiffaLocalization.string("Type conflict")
        case .error: RiffaLocalization.string("Error")
        }
    }
    private var symbol: String {
        switch status {
        case .unchanged: "checkmark"
        case .leftChanged: "arrow.left"
        case .rightChanged: "arrow.right"
        case .bothChangedSame: "checkmark.circle"
        case .leftDeleted, .rightDeleted, .bothDeleted: "minus.circle"
        case .conflict, .typeConflict, .error: "exclamationmark.triangle.fill"
        }
    }
    private var color: Color {
        switch status {
        case .unchanged:
            theme.inkSubtle
        case .leftChanged, .rightChanged:
            theme.warning
        case .bothChangedSame:
            theme.success
        case .leftDeleted, .rightDeleted, .bothDeleted:
            theme.inkMuted
        case .conflict, .typeConflict, .error:
            theme.danger
        }
    }
}

private extension FolderMergeModel.Side {
    var title: String {
        switch self {
        case .base: RiffaLocalization.string("Base")
        case .left: RiffaLocalization.string("Left")
        case .right: RiffaLocalization.string("Right")
        }
    }
}

private extension FolderMergeAction.Kind {
    var displayName: String {
        switch self {
        case .copyFromLeft: RiffaLocalization.string("Copy from Left")
        case .copyFromRight: RiffaLocalization.string("Copy from Right")
        case .copyFromBase: RiffaLocalization.string("Copy from Base")
        case .createDirectory: RiffaLocalization.string("Create directory")
        case .omit: RiffaLocalization.string("Omit from output")
        case .conflict: RiffaLocalization.string("Resolve conflict")
        }
    }
}
