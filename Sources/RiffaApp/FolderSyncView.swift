import AppKit
import Foundation
import RiffaCore
import SwiftUI

@MainActor
private final class FolderSyncModel: ObservableObject {
    enum Side { case left, right }

    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var plan: FolderSyncPlan?
    @Published private(set) var isLoading = false
    @Published var showNoOperations = false
    @Published var mode: FolderSyncMode = .updateRight {
        didSet {
            guard !isApplyingInitialState, mode != oldValue else { return }
            planningConfigurationDidChange()
        }
    }
    @Published var detectRenames = false {
        didSet {
            guard !isApplyingInitialState, detectRenames != oldValue else { return }
            planningConfigurationDidChange()
        }
    }
    @Published var errorMessage: String?
    @Published private(set) var isApplying = false
    @Published private(set) var lastExecutionMessage: String?
    @Published private(set) var isDetectingRenames = false
    @Published private(set) var renameDetectionWarning: String?

    private var nodes: [PairNode] = []
    private var comparisonTask: Task<Void, Never>?
    private var renameDetectionTask: Task<Void, Never>?
    private var comparisonGeneration = UUID()
    private var renameDetectionGeneration = UUID()
    private var renameDetectionResultGeneration: UUID?
    private var renameDetectionResult: FolderRenameDetectionResult?
    private var isApplyingInitialState = false

    deinit {
        comparisonTask?.cancel()
        renameDetectionTask?.cancel()
    }

    var visibleActions: [FolderSyncAction] {
        guard let plan else { return [] }
        return showNoOperations ? plan.actions : plan.actions.filter { $0.kind != .noOp }
    }

    func chooseFolder(for side: Side) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = side == .left
            ? RiffaLocalization.string("Choose Left Folder")
            : RiffaLocalization.string("Choose Right Folder")
        panel.prompt = RiffaLocalization.string("Choose")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url, for: side)
    }

    func setFolder(_ url: URL, for side: Side) {
        guard !isApplying else {
            errorMessage = RiffaLocalization.string(
                "Wait for the current file operation to finish before replacing an input."
            )
            return
        }
        let standardizedURL = url.standardizedFileURL
        switch side {
        case .left: leftURL = standardizedURL
        case .right: rightURL = standardizedURL
        }
        compareIfReady()
    }

    func swapSides() {
        comparisonTask?.cancel()
        cancelRenameDetection(clearResults: true)
        nodes = []
        plan = nil
        (leftURL, rightURL) = (rightURL, leftURL)
        switch mode {
        case .updateLeft: mode = .updateRight
        case .updateRight: mode = .updateLeft
        case .mirrorLeftToRight: mode = .mirrorRightToLeft
        case .mirrorRightToLeft: mode = .mirrorLeftToRight
        case .updateBoth: break
        }
        compareIfReady()
    }

    func refresh() { compareIfReady() }

    func openInitial(_ urls: [URL], options: [String: String] = [:]) {
        comparisonTask?.cancel()
        cancelRenameDetection(clearResults: true)
        nodes = []
        plan = nil
        isLoading = false
        isApplyingInitialState = true
        if let value = options["mode"].flatMap(FolderSyncMode.init(rawValue:)) {
            mode = value
        }
        if let value = options.riffaBoolean(for: "showNoOperations") {
            showNoOperations = value
        }
        if let value = options.riffaBoolean(for: "detectRenames") {
            detectRenames = value
        }
        isApplyingInitialState = false
        guard !urls.isEmpty else { return }
        guard urls.count == 2 else {
            errorMessage = RiffaLocalization.string(
                "Folder Sync requires exactly two folders in Left, Right order."
            )
            return
        }

        leftURL = urls[0].standardizedFileURL
        rightURL = urls[1].standardizedFileURL
        errorMessage = nil
        compareIfReady()
    }

    func applyPlan() {
        guard let plan, let leftURL, let rightURL,
              plan.summary.actionableCount > 0,
              !plan.summary.hasConflicts,
              !isLoading,
              !isDetectingRenames,
              !isApplying
        else { return }

        let backupPanel = NSOpenPanel()
        backupPanel.canChooseFiles = false
        backupPanel.canChooseDirectories = true
        backupPanel.canCreateDirectories = true
        backupPanel.allowsMultipleSelection = false
        backupPanel.title = RiffaLocalization.string("Choose a Backup Folder")
        backupPanel.message = RiffaLocalization.string(
            "Replaced and deleted items are moved here before the plan is committed. Choose a folder outside both synchronized roots."
        )
        backupPanel.prompt = RiffaLocalization.string("Use for Backups")
        guard backupPanel.runModal() == .OK, let backupURL = backupPanel.url else { return }

        let confirmation = NSAlert()
        confirmation.alertStyle = plan.summary.hasHighRiskActions ? .critical : .warning
        confirmation.messageText = plan.summary.hasHighRiskActions
            ? RiffaLocalization.string(
                "Apply a plan containing high-risk changes?"
            )
            : String(
                localized: "Apply \(plan.summary.actionableCount) synchronization actions?",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        let moveNote = if plan.summary.moveCount == 1 {
            RiffaLocalization.string(
                " 1 verified internal move will be rechecked against the opposite side before writing."
            )
        } else if plan.summary.moveCount > 1 {
            String(
                localized: " \(plan.summary.moveCount) verified internal moves will be rechecked against the opposite side before writing.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        } else {
            ""
        }
        confirmation.informativeText = String(
            localized: "Riffa will preflight the whole plan again. Replaced and deleted targets will be moved to \(backupURL.path), and any failure will trigger a best-effort rollback.\(moveNote)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        confirmation.addButton(
            withTitle: plan.summary.hasHighRiskActions
                ? RiffaLocalization.string("Apply High-Risk Plan")
                : RiffaLocalization.string("Apply Plan")
        )
        confirmation.addButton(withTitle: RiffaLocalization.string("Cancel"))
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        isApplying = true
        lastExecutionMessage = nil
        let journalDirectoryURL = JournaledLocalFolderSyncExecutor
            .defaultApplicationJournalDirectoryURL
        Task { [weak self] in
            do {
                let log = try await Task.detached(priority: .userInitiated) {
                    try await JournaledLocalFolderSyncExecutor(
                        journalDirectoryURL: journalDirectoryURL
                    ).execute(
                        plan: plan,
                        leftRoot: leftURL,
                        rightRoot: rightURL,
                        backupRoot: backupURL,
                        options: .init(
                            dryRun: false,
                            allowHighRisk: plan.summary.hasHighRiskActions
                        )
                    )
                }.value
                guard let self else { return }
                isApplying = false
                switch log.status {
                case .completed:
                    lastExecutionMessage = String(
                        localized: "Applied \(plan.summary.actionableCount) actions. Backups: \(backupURL.path)",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                    compareIfReady()
                case .refused, .failedRolledBack, .failedRollbackIncomplete:
                    let detail = log.issues.map(\.message).joined(separator: "\n")
                    errorMessage = detail.isEmpty
                        ? RiffaLocalization.string(
                            "The synchronization plan could not be applied."
                        )
                        : detail
                    lastExecutionMessage = log.status == .failedRolledBack
                        ? RiffaLocalization.string(
                            "The operation failed and completed changes were rolled back."
                        )
                        : nil
                case .dryRun:
                    lastExecutionMessage = RiffaLocalization.string(
                        "Dry-run completed; no changes were made."
                    )
                }
            } catch is CancellationError {
                guard let self else { return }
                isApplying = false
                lastExecutionMessage = RiffaLocalization.string(
                    "Synchronization was interrupted. Its unfinished operation journal is available for recovery."
                )
            } catch {
                guard let self else { return }
                isApplying = false
                lastExecutionMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadDemo() {
        do {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "RiffaSyncDemo", directoryHint: .isDirectory)
            let left = root.appending(path: "left", directoryHint: .isDirectory)
            let right = root.appending(path: "right", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
            try Data("shared\n".utf8).write(to: left.appending(path: "shared.txt"), options: .atomic)
            try Data("shared\n".utf8).write(to: right.appending(path: "shared.txt"), options: .atomic)
            try Data("left version\n".utf8).write(to: left.appending(path: "changed.txt"), options: .atomic)
            try Data("right version\n".utf8).write(to: right.appending(path: "changed.txt"), options: .atomic)
            try Data("new on left\n".utf8).write(to: left.appending(path: "new.txt"), options: .atomic)
            try Data("target only\n".utf8).write(to: right.appending(path: "obsolete.txt"), options: .atomic)
            leftURL = left
            rightURL = right
            errorMessage = nil
            compareIfReady()
        } catch {
            errorMessage = String(
                localized: "Could not create demo folders: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private func compareIfReady() {
        comparisonTask?.cancel()
        cancelRenameDetection(clearResults: true)
        comparisonGeneration = UUID()
        let generation = comparisonGeneration
        nodes = []
        plan = nil
        guard let leftURL, let rightURL else {
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil
        comparisonTask = Task { [weak self] in
            let nodes = await FolderComparison().compare(
                leftURL: leftURL,
                rightURL: rightURL,
                options: FolderComparisonOptions(
                    compareModificationDates: false,
                    compareFileContents: true
                )
            )
            guard !Task.isCancelled,
                  let self,
                  comparisonGeneration == generation else { return }
            self.nodes = nodes
            self.isLoading = false
            self.rebuildPlan()
            if let issue = nodes.lazy.flatMap(\.issues).first {
                self.errorMessage = issue.errorDescription
            }
            self.startRenameDetectionIfReady()
        }
    }

    private func rebuildPlan() {
        guard leftURL != nil, rightURL != nil else {
            plan = nil
            return
        }
        guard !isLoading else {
            plan = nil
            return
        }
        let currentRenameResult = detectRenames
            && mode.supportsRenameDetection
            && renameDetectionResultGeneration == comparisonGeneration
            ? renameDetectionResult
            : nil
        plan = FolderSyncPlanner().plan(
            nodes: nodes,
            mode: mode,
            renameDetectionResult: currentRenameResult
        )
    }

    private func planningConfigurationDidChange() {
        cancelRenameDetection(clearResults: true)
        rebuildPlan()
        startRenameDetectionIfReady()
    }

    private func startRenameDetectionIfReady() {
        guard detectRenames,
              mode.supportsRenameDetection,
              !isLoading,
              leftURL != nil,
              rightURL != nil,
              !nodes.isEmpty else { return }

        cancelRenameDetection(clearResults: true)
        rebuildPlan()
        let nodeSnapshot = nodes
        let comparisonSnapshot = comparisonGeneration
        let modeSnapshot = mode
        let generation = UUID()
        renameDetectionGeneration = generation
        isDetectingRenames = true

        renameDetectionTask = Task { [weak self] in
            do {
                let result = try await LocalFolderRenameDetector().detect(nodes: nodeSnapshot)
                guard !Task.isCancelled,
                      let self,
                      detectRenames,
                      mode == modeSnapshot,
                      mode.supportsRenameDetection,
                      comparisonGeneration == comparisonSnapshot,
                      renameDetectionGeneration == generation else { return }
                renameDetectionResult = result
                renameDetectionResultGeneration = comparisonSnapshot
                renameDetectionWarning = nil
                isDetectingRenames = false
                renameDetectionTask = nil
                rebuildPlan()
            } catch is CancellationError {
                guard let self,
                      renameDetectionGeneration == generation else { return }
                isDetectingRenames = false
                renameDetectionTask = nil
            } catch let detectionError as FolderRenameDetectionError {
                guard let self,
                      detectRenames,
                      mode == modeSnapshot,
                      comparisonGeneration == comparisonSnapshot,
                      renameDetectionGeneration == generation else { return }
                renameDetectionResult = nil
                renameDetectionResultGeneration = nil
                renameDetectionWarning = Self.renameDetectionErrorMessage(
                    detectionError
                )
                isDetectingRenames = false
                renameDetectionTask = nil
                rebuildPlan()
            } catch {
                guard let self,
                      detectRenames,
                      mode == modeSnapshot,
                      comparisonGeneration == comparisonSnapshot,
                      renameDetectionGeneration == generation else { return }
                renameDetectionResult = nil
                renameDetectionResultGeneration = nil
                renameDetectionWarning = RiffaLocalization.string(
                    "A move candidate could not be safely verified."
                )
                isDetectingRenames = false
                renameDetectionTask = nil
                rebuildPlan()
            }
        }
    }

    private func cancelRenameDetection(clearResults: Bool) {
        renameDetectionTask?.cancel()
        renameDetectionTask = nil
        renameDetectionGeneration = UUID()
        isDetectingRenames = false
        if clearResults {
            renameDetectionResult = nil
            renameDetectionResultGeneration = nil
            renameDetectionWarning = nil
        }
    }

    private static func renameDetectionErrorMessage(
        _ error: FolderRenameDetectionError
    ) -> String {
        switch error {
        case .invalidLimits:
            return RiffaLocalization.string(
                "The rename-detection limits are invalid."
            )
        case let .candidateLimitExceeded(actual, limit):
            return String(
                localized: "Rename detection found \(actual) candidates, exceeding the \(limit)-candidate limit.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .fileByteLimitExceeded(side, actual, limit):
            let sideTitle = RiffaLocalization.string(side.rawValue.capitalized)
            return String(
                localized: "The \(sideTitle) candidate has \(actual) bytes, exceeding the \(limit)-byte per-file limit.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .totalHashedByteLimitExceeded(actual, limit):
            return String(
                localized: "Rename detection would hash \(actual) bytes, exceeding the \(limit)-byte total limit.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .nonLocalResource(side):
            let sideTitle = RiffaLocalization.string(side.rawValue.capitalized)
            return String(
                localized: "The \(sideTitle) candidate is not an absolute local file resource.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .operationFailed(side, operation, code):
            let sideTitle = RiffaLocalization.string(side.rawValue.capitalized)
            let operationTitle = RiffaLocalization.string(operation.rawValue)
            return String(
                localized: "The \(sideTitle) candidate \(operationTitle) operation failed (errno \(code)).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .notRegularFile(side):
            let sideTitle = RiffaLocalization.string(side.rawValue.capitalized)
            return String(
                localized: "The \(sideTitle) candidate is no longer a regular file.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .fileChangedDuringDetection(side):
            let sideTitle = RiffaLocalization.string(side.rawValue.capitalized)
            return String(
                localized: "The \(sideTitle) candidate changed during rename detection.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }
}

struct FolderSyncView: View {
    @StateObject private var model = FolderSyncModel()
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
            syncOptionsBar
            pathBar

            if model.leftURL == nil || model.rightURL == nil {
                emptyState
            } else if model.isLoading && model.plan == nil {
                ProgressView("Comparing contents and building a safe plan…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan = model.plan {
                planContent(plan)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Folder Sync")
        .background(theme.canvas)
        .riffaWindowDropZones([
            RiffaDropZone(
                role: .left,
                acceptedKind: .realDirectory
            ) {
                model.setFolder($0, for: .left)
            },
            RiffaDropZone(
                role: .right,
                acceptedKind: .realDirectory
            ) {
                model.setFolder($0, for: .right)
            }
        ])
        .task(id: ComparisonInitialLoad(urls: initialURLs, options: initialOptions)) {
            model.openInitial(initialURLs, options: initialOptions)
        }
        .alert(
            "Folder sync preview issue",
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
            title: "Folder Sync",
            subtitle: "Preview first — writes require backup and confirmation"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .folderSynchronization,
                    urls: [model.leftURL, model.rightURL].compactMap { $0 },
                    options: [
                        "mode": .string(model.mode.rawValue),
                        "showNoOperations": .boolean(model.showNoOperations),
                        "detectRenames": .boolean(model.detectRenames)
                    ]
                ),
                errorMessage: $model.errorMessage
            )
            Button {
                model.applyPlan()
            } label: {
                Label(
                    model.isApplying
                        ? RiffaLocalization.string("Applying…")
                        : RiffaLocalization.string("Apply…"),
                    systemImage: "checkmark.shield"
                )
            }
            .buttonStyle(.riffaPrimary)
            .disabled(
                model.plan == nil
                    || model.plan?.summary.actionableCount == 0
                    || model.plan?.summary.hasConflicts == true
                    || model.isLoading
                    || model.isDetectingRenames
                    || model.isApplying
            )
        }
    }

    private var syncOptionsBar: some View {
        RiffaComparisonControlBar {
            Picker("Mode", selection: $model.mode) {
                ForEach(FolderSyncMode.allCases, id: \.self) { mode in
                    Text(mode.displayNameKey).tag(mode)
                }
            }
            .frame(width: 190)

            Toggle("Detect moves", isOn: $model.detectRenames)
                .toggleStyle(.checkbox)
                .disabled(!model.mode.supportsRenameDetection)
                .help(
                    model.mode.supportsRenameDetection
                        ? RiffaLocalization.string(
                            "Verify matching unique files and plan same-folder moves."
                        )
                        : RiffaLocalization.string(
                            "Move detection is available in mirror modes."
                        )
                )

            if model.isDetectingRenames {
                ProgressView()
                    .controlSize(.small)
                    .help("Verifying unique-file move candidates")
            }

            Toggle("Show unchanged", isOn: $model.showNoOperations)
                .toggleStyle(.checkbox)

            Button {
                model.refresh()
            } label: {
                Label("Refresh comparison", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Refresh comparison")
            .disabled(model.leftURL == nil || model.rightURL == nil || model.isLoading)
        }
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            SyncFolderButton(title: "Left folder", url: model.leftURL) {
                model.chooseFolder(for: .left)
            }
            .riffaResourceDropTarget(
                role: .left,
                acceptedKind: .realDirectory
            ) {
                model.setFolder($0, for: .left)
            }
            Button {
                model.swapSides()
            } label: {
                Label("Swap folders", systemImage: "arrow.left.arrow.right")
            }
                .labelStyle(.iconOnly)
                .buttonStyle(.riffaTertiary)
                .help("Swap folders and reverse one-way modes")
                .accessibilityLabel("Swap left and right folders")
                .accessibilityHint("Also reverses one-way synchronization modes")
                .disabled(model.leftURL == nil && model.rightURL == nil)
            SyncFolderButton(title: "Right folder", url: model.rightURL) {
                model.chooseFolder(for: .right)
            }
            .riffaResourceDropTarget(
                role: .right,
                acceptedKind: .realDirectory
            ) {
                model.setFolder($0, for: .right)
            }
        }
        .disabled(model.isApplying)
    }

    private func planContent(_ plan: FolderSyncPlan) -> some View {
        VStack(spacing: 0) {
            if plan.summary.hasHighRiskActions || plan.summary.hasConflicts {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(theme.warning)
                    Text("Preview contains \(plan.summary.conflictCount) conflicts and \(plan.summary.highRiskCount) high-risk actions. Nothing has been written.")
                    Spacer()
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(theme.warning.opacity(0.1))
                Divider()
            }

            if let warning = model.renameDetectionWarning {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.warning)
                    Text("Move detection warning: \(warning)")
                        .lineLimit(1)
                        .help(warning)
                    Spacer()
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(theme.warning.opacity(0.1))
                Divider()
            }

            Table(model.visibleActions) {
                TableColumn("Action") { action in SyncActionLabel(action: action) }
                    .width(min: 100, ideal: 120, max: 140)
                TableColumn("Path") { action in
                    Text(displayedPath(action))
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                }
                .width(min: 220, ideal: 380)
                TableColumn("Route") { action in Text(route(action)).foregroundStyle(.secondary) }
                    .width(min: 110, ideal: 145)
                TableColumn("Risk") { action in
                    Text(LocalizedStringKey(action.risk.rawValue.capitalized))
                        .foregroundStyle(riskColor(action.risk))
                }
                .width(min: 70, ideal: 80)
                TableColumn("Reason") { action in
                    Text(LocalizedStringKey(action.reason.description))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .width(min: 260, ideal: 420)
            }

            Divider()
            HStack(spacing: 15) {
                Label("\(plan.summary.actionableCount) planned", systemImage: "list.bullet.clipboard")
                    .foregroundStyle(theme.inkMuted)
                Label("\(plan.summary.conflictCount) conflicts", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(
                        plan.summary.hasConflicts ? theme.warning : theme.inkSubtle
                    )
                Label("\(plan.summary.deleteCount) deletes", systemImage: "trash")
                    .foregroundStyle(
                        plan.summary.deleteCount > 0 ? theme.danger : theme.inkSubtle
                    )
                Label("\(plan.summary.moveCount) moves", systemImage: "arrow.right")
                    .foregroundStyle(
                        plan.summary.moveCount > 0 ? theme.warning : theme.inkSubtle
                    )
                if model.isDetectingRenames {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking moves…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let message = model.lastExecutionMessage {
                    Text(message).lineLimit(1).help(message)
                }
                Label(
                    model.isApplying
                        ? RiffaLocalization.string("Applying with backups")
                        : RiffaLocalization.string(
                            "Preflight required before write"
                        ),
                    systemImage: model.isApplying ? "externaldrive.badge.timemachine" : "checkmark.shield"
                )
                .foregroundStyle(model.isApplying ? theme.warning : theme.success)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(theme.surface(.one))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Choose two folders", systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text("Riffa compares content first, then creates a read-only synchronization plan.")
        } actions: {
            HStack {
                Button("Choose Left") { model.chooseFolder(for: .left) }
                    .buttonStyle(
                        RiffaButtonStyle(model.leftURL == nil ? .primary : .secondary)
                    )
                Button("Choose Right") { model.chooseFolder(for: .right) }
                    .buttonStyle(
                        RiffaButtonStyle(
                            model.leftURL != nil && model.rightURL == nil
                                ? .primary
                                : .secondary
                        )
                    )
                Button("Load Demo") { model.loadDemo() }
                    .buttonStyle(.riffaTertiary)
            }
        }
    }

    private func route(_ action: FolderSyncAction) -> String {
        if action.kind == .move, let target = action.targetSide {
            return String(
                localized: "Within \(target.shortName)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return switch (action.sourceSide, action.targetSide) {
        case let (source?, target?): "\(source.shortName) → \(target.shortName)"
        case let (nil, target?):
            String(
                localized: "Delete \(target.shortName)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        default: "—"
        }
    }

    private func displayedPath(_ action: FolderSyncAction) -> String {
        if action.kind == .move,
           let source = action.sourceRelativePath,
           let target = action.targetRelativePath {
            return "\(source) → \(target)"
        }
        return action.targetRelativePath ?? action.sourceRelativePath ?? "—"
    }

    private func riskColor(_ risk: FolderSyncRisk) -> Color {
        switch risk {
        case .none: theme.inkSubtle
        case .low: theme.success
        case .medium: theme.warning
        case .high: theme.danger
        }
    }
}

private struct SyncActionLabel: View {
    let action: FolderSyncAction
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Label {
            Text(titleKey)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
    }

    private var titleKey: LocalizedStringKey {
        switch action.kind {
        case .copy: "Copy"
        case .createDirectory: "Create folder"
        case .delete: "Delete"
        case .move: "Move"
        case .replace: "Replace"
        case .conflict: "Conflict"
        case .noOp: "No change"
        }
    }

    private var symbol: String {
        switch action.kind {
        case .copy: "doc.on.doc"
        case .createDirectory: "folder.badge.plus"
        case .delete: "trash"
        case .move: "arrow.right"
        case .replace: "arrow.triangle.2.circlepath"
        case .conflict: "exclamationmark.triangle.fill"
        case .noOp: "checkmark"
        }
    }

    private var color: Color {
        switch action.kind {
        case .copy, .createDirectory: theme.accent
        case .move, .replace: theme.warning
        case .delete, .conflict: theme.danger
        case .noOp: theme.inkSubtle
        }
    }
}

private struct SyncFolderButton: View {
    let title: String
    let url: URL?
    let action: () -> Void

    var body: some View {
        RiffaResourcePathButton(
            title: title,
            url: url,
            emptyTitle: "Choose a folder…",
            systemImage: "folder",
            accessibilityHint: "Choose a folder",
            action: action
        )
        .accessibilityValue(
            url?.path(percentEncoded: false)
                ?? RiffaLocalization.string("No folder selected")
        )
    }
}

private extension FolderSyncMode {
    var supportsRenameDetection: Bool {
        switch self {
        case .mirrorLeftToRight, .mirrorRightToLeft:
            true
        case .updateLeft, .updateRight, .updateBoth:
            false
        }
    }

    var displayNameKey: LocalizedStringKey {
        switch self {
        case .updateLeft: "Update Left"
        case .updateRight: "Update Right"
        case .updateBoth: "Update Both"
        case .mirrorLeftToRight:
            "Mirror Left → Right"
        case .mirrorRightToLeft:
            "Mirror Right → Left"
        }
    }
}

private extension FolderSyncSide {
    var shortName: String {
        switch self {
        case .left: RiffaLocalization.string("Left")
        case .right: RiffaLocalization.string("Right")
        }
    }
}
