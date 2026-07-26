import AppKit
import Foundation
import RiffaCore
import SwiftUI

private enum FolderSelectionCopyDirection: Sendable {
    case leftToRight
    case rightToLeft

    var sourceSide: FolderSyncSide {
        switch self {
        case .leftToRight: .left
        case .rightToLeft: .right
        }
    }

    var targetSide: FolderSyncSide {
        switch self {
        case .leftToRight: .right
        case .rightToLeft: .left
        }
    }

    var mode: FolderSyncMode {
        switch self {
        case .leftToRight: .updateRight
        case .rightToLeft: .updateLeft
        }
    }

    var title: String {
        switch self {
        case .leftToRight: RiffaLocalization.string("Left → Right")
        case .rightToLeft: RiffaLocalization.string("Right → Left")
        }
    }

    var sourceTitle: String {
        switch self {
        case .leftToRight: RiffaLocalization.string("Left")
        case .rightToLeft: RiffaLocalization.string("Right")
        }
    }
}

private typealias FolderSelectionCopyPlan = FolderSelectionCopyPlanningResult

@MainActor
final class FolderCompareModel: ObservableObject {
    enum Side {
        case left
        case right
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case differences = "Differences"
        case same = "Same"
        case unique = "Unique"
        case leftNewer = "Left newer"
        case rightNewer = "Right newer"
        case leftChanges = "Left newer + unique"
        case rightChanges = "Right newer + unique"

        var id: Self { self }

        var localizedTitle: String {
            switch self {
            case .all: RiffaLocalization.string("All")
            case .differences: RiffaLocalization.string("Differences")
            case .same: RiffaLocalization.string("Same")
            case .unique: RiffaLocalization.string("Unique")
            case .leftNewer: RiffaLocalization.string("Left newer")
            case .rightNewer: RiffaLocalization.string("Right newer")
            case .leftChanges:
                RiffaLocalization.string("Left newer + unique")
            case .rightChanges:
                RiffaLocalization.string("Right newer + unique")
            }
        }
    }

    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var nodes: [PairNode] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isApplyingSelection = false
    @Published private(set) var isApplyingVerifiedMoves = false
    @Published private(set) var isApplyingExplicitRename = false
    @Published private(set) var lastExecutionMessage: String?
    @Published var errorMessage: String?
    @Published var filter: Filter = .all
    @Published var pathSearch = ""
    @Published var compareContents = false {
        didSet {
            guard !isApplyingInitialState else { return }
            compareIfReady()
        }
    }
    @Published var compareModificationDates = true {
        didSet {
            guard !isApplyingInitialState else { return }
            compareIfReady()
        }
    }
    @Published var detectRenames = false {
        didSet {
            guard !isApplyingInitialState, detectRenames != oldValue else { return }
            if detectRenames {
                startRenameDetectionIfReady()
            } else {
                cancelRenameDetection(clearResults: true)
            }
        }
    }
    @Published private(set) var renameDetectionResult: FolderRenameDetectionResult?
    @Published private(set) var isDetectingRenames = false
    @Published private(set) var renameDetectionWarning: String?
    @Published private(set) var renameCounterparts: [String: String] = [:]
    @Published private(set) var pathRules: FolderPathRules = .all

    var isPerformingFileOperation: Bool {
        isApplyingSelection
            || isApplyingVerifiedMoves
            || isApplyingExplicitRename
    }

    private var comparisonTask: Task<Void, Never>?
    private var renameDetectionTask: Task<Void, Never>?
    private var verifiedMoveTask: Task<Void, Never>?
    private var explicitRenameTask: Task<Void, Never>?
    private var comparisonGeneration = UUID()
    private var renameDetectionGeneration = UUID()
    private var isApplyingInitialState = false
    private var pathRulesAreValid = true
    private var pathRuleRestoreFailureMessage: String?
    private var operationSupportNodes: [PairNode] = []

    deinit {
        comparisonTask?.cancel()
        renameDetectionTask?.cancel()
        verifiedMoveTask?.cancel()
        explicitRenameTask?.cancel()
    }

    var filteredNodes: [PairNode] {
        let statusFiltered = switch filter {
        case .all:
            nodes
        case .differences:
            nodes.filter { $0.status != .same }
        case .same:
            nodes.filter { $0.status == .same }
        case .unique:
            nodes.filter { $0.status == .leftOnly || $0.status == .rightOnly }
        case .leftNewer:
            nodes.filter { Self.recency(of: $0) == .left }
        case .rightNewer:
            nodes.filter { Self.recency(of: $0) == .right }
        case .leftChanges:
            nodes.filter {
                $0.status == .leftOnly || Self.recency(of: $0) == .left
            }
        case .rightChanges:
            nodes.filter {
                $0.status == .rightOnly || Self.recency(of: $0) == .right
            }
        }
        let query = pathSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return statusFiltered }
        return statusFiltered.filter { $0.relativePath.localizedStandardContains(query) }
    }

    private enum Recency: Equatable {
        case left
        case right
    }

    private static func recency(of node: PairNode) -> Recency? {
        guard node.issues.isEmpty,
              let left = node.left,
              let right = node.right,
              left.kind == right.kind,
              let leftDate = left.modificationDate,
              let rightDate = right.modificationDate else {
            return nil
        }
        let difference = leftDate.timeIntervalSince(rightDate)
        guard abs(difference) > 1 else { return nil }
        return difference > 0 ? .left : .right
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
        guard !isPerformingFileOperation else {
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

    func openInitial(_ urls: [URL], options: [String: String] = [:]) {
        comparisonTask?.cancel()
        operationSupportNodes = []
        comparisonGeneration = UUID()
        cancelRenameDetection(clearResults: true)
        isApplyingInitialState = true

        if let value = options.riffaBoolean(for: "compareContents") {
            compareContents = value
        }
        if let value = options.riffaBoolean(for: "compareModificationDates") {
            compareModificationDates = value
        }
        if let value = options.riffaBoolean(for: "detectRenames") {
            detectRenames = value
        }
        if let value = options["resultFilter"].flatMap(Filter.init(rawValue:)) {
            filter = value
        }
        leftURL = urls.first
        rightURL = urls.count > 1 ? urls[1] : nil

        do {
            pathRules = try Self.restoredPathRules(from: options)
            pathRulesAreValid = true
            pathRuleRestoreFailureMessage = nil
        } catch {
            isApplyingInitialState = false
            isLoading = false
            let message = String(
                localized: "Saved folder path rules are invalid. \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            pathRulesAreValid = false
            pathRuleRestoreFailureMessage = message
            nodes = [Self.pathRuleErrorNode(message)]
            errorMessage = message
            return
        }

        isApplyingInitialState = false
        compareIfReady()
    }

    func applyPathRules(_ rules: FolderPathRules) {
        pathRules = rules
        pathRulesAreValid = true
        pathRuleRestoreFailureMessage = nil
        compareIfReady()
    }

    func swapSides() {
        (leftURL, rightURL) = (rightURL, leftURL)
        compareIfReady()
    }

    func refresh() {
        compareIfReady()
    }

    func canRenameVisibleSelection(
        on side: FolderSyncSide,
        selectedPaths: Set<PairNode.ID>
    ) -> Bool {
        guard !isLoading, !isApplyingSelection else { return false }
        return (try? FolderCompareExplicitRenamePlanner().eligibility(
            visibleNodes: filteredNodes,
            selectedIDs: selectedPaths,
            side: side
        )) != nil
    }

    fileprivate func renameVisibleSelection(
        on side: FolderSyncSide,
        selectedPaths: Set<PairNode.ID>
    ) {
        guard !isLoading, !isApplyingSelection else { return }
        guard let leftURL, let rightURL else {
            errorMessage = RiffaLocalization.string(
                "Choose both folders before renaming a file."
            )
            return
        }

        let visibleNodes = filteredNodes
        let eligibility: FolderCompareExplicitRenameEligibility
        do {
            eligibility = try FolderCompareExplicitRenamePlanner().eligibility(
                visibleNodes: visibleNodes,
                selectedIDs: selectedPaths,
                side: side
            )
        } catch {
            errorMessage = String(
                localized: "The selected file cannot be renamed. \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }

        let sideTitle = Self.sideTitle(side)
        let nameField = NSTextField(string: eligibility.currentLeafName)
        nameField.placeholderString = RiffaLocalization.string("New file name")
        nameField.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        let prompt = NSAlert()
        prompt.messageText = String(
            localized: "Rename File on \(sideTitle)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        prompt.informativeText = RiffaLocalization.string(
            "Enter a new leaf name. The file stays in its current parent folder. Directory and symbolic-link rename is not supported."
        )
        prompt.accessoryView = nameField
        prompt.addButton(withTitle: RiffaLocalization.string("Continue"))
        prompt.addButton(withTitle: RiffaLocalization.string("Cancel"))
        prompt.window.initialFirstResponder = nameField
        guard prompt.runModal() == .alertFirstButtonReturn else { return }

        let newLeafName = nameField.stringValue
        do {
            try FolderCompareExplicitRenamePlanner.validateLeaf(newLeafName)
            _ = try FolderCompareExplicitRenamePlanner.renameKind(
                currentLeafName: eligibility.currentLeafName,
                newLeafName: newLeafName
            )
        } catch {
            errorMessage = String(
                localized: "The new file name is not valid. \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }

        let selectedRoot = side == .left ? leftURL : rightURL
        let journalDirectoryURL = JournaledLocalFolderSyncExecutor
            .defaultApplicationJournalDirectoryURL
        let supportRoot = Self.verifiedMoveSupportRoot(
            leftRoot: leftURL,
            rightRoot: rightURL,
            journalDirectoryURL: journalDirectoryURL
        )

        isApplyingSelection = true
        isApplyingExplicitRename = true
        errorMessage = nil
        lastExecutionMessage = String(
            localized: "Capturing an exact source proof for the \(sideTitle) side rename…",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )

        explicitRenameTask = Task { [weak self] in
            var formalExecutionStarted = false
            do {
                let result = try await Self.makeExplicitRenamePlan(
                    visibleNodes: visibleNodes,
                    selectedPaths: selectedPaths,
                    side: side,
                    newLeafName: newLeafName,
                    root: selectedRoot
                )
                let preflight = try await Self.executeVerifiedMovePlan(
                    result.plan,
                    leftRoot: leftURL,
                    rightRoot: rightURL,
                    supportRoot: supportRoot,
                    journalDirectoryURL: journalDirectoryURL,
                    dryRun: true
                )
                try Task.checkCancellation()
                guard let self else { return }
                guard preflight.status == .dryRun else {
                    finishExplicitRenameTask()
                    lastExecutionMessage = nil
                    errorMessage = Self.executionIssueMessage(
                        preflight,
                        fallback: RiffaLocalization.string(
                            "The rename did not pass descriptor-backed dry-run preflight. No files were changed."
                        )
                    )
                    return
                }

                let confirmation = NSAlert()
                confirmation.alertStyle = .warning
                confirmation.messageText = String(
                    localized: "Rename this file on \(sideTitle)?",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                confirmation.informativeText = Self.explicitRenameConfirmationSummary(
                    result,
                    sideTitle: sideTitle
                )
                confirmation.addButton(
                    withTitle: String(
                        localized: "Rename on \(sideTitle)",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                )
                confirmation.addButton(
                    withTitle: RiffaLocalization.string("Cancel")
                )
                guard confirmation.runModal() == .alertFirstButtonReturn else {
                    finishExplicitRenameTask()
                    lastExecutionMessage = RiffaLocalization.string(
                        "Rename cancelled after dry-run; no files were changed and no journal was created."
                    )
                    return
                }

                lastExecutionMessage = String(
                    localized: "Renaming on \(sideTitle) with journaled rollback protection…",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                formalExecutionStarted = true
                let execution = try await Self.executeVerifiedMovePlan(
                    result.plan,
                    leftRoot: leftURL,
                    rightRoot: rightURL,
                    supportRoot: supportRoot,
                    journalDirectoryURL: journalDirectoryURL,
                    dryRun: false
                )
                finishExplicitRenameTask()

                let wasCancelled = execution.issues.contains { $0.code == .cancelled }
                switch execution.status {
                case .completed:
                    lastExecutionMessage = String(
                        localized: "Renamed \(result.sourceRelativePath) to \(result.destinationRelativePath) on \(sideTitle).",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                    compareIfReady()
                case .failedRolledBack:
                    lastExecutionMessage = wasCancelled
                        ? RiffaLocalization.string(
                            "Rename cancelled; the original name was restored."
                        )
                        : RiffaLocalization.string(
                            "Rename failed; the original name was restored."
                        )
                    errorMessage = wasCancelled ? nil : Self.executionIssueMessage(
                        execution,
                        fallback: RiffaLocalization.string(
                            "The rename failed and the original name was restored."
                        )
                    )
                    compareIfReady()
                case .failedRollbackIncomplete:
                    lastExecutionMessage = nil
                    errorMessage = Self.executionIssueMessage(
                        execution,
                        fallback: RiffaLocalization.string(
                            "The rename stopped and rollback was incomplete. Inspect both names and Operation History before retrying."
                        )
                    )
                    compareIfReady()
                case .refused:
                    lastExecutionMessage = nil
                    errorMessage = Self.executionIssueMessage(
                        execution,
                        fallback: RiffaLocalization.string(
                            "The source, parent, root, or destination changed after confirmation. Nothing was renamed."
                        )
                    )
                    compareIfReady()
                case .dryRun:
                    lastExecutionMessage = RiffaLocalization.string(
                        "The rename was not applied; only dry-run preflight completed."
                    )
                }
            } catch is CancellationError {
                guard let self else { return }
                finishExplicitRenameTask()
                lastExecutionMessage = formalExecutionStarted
                    ? RiffaLocalization.string(
                        "Rename cancellation was requested before a terminal result. Inspect Operation History before retrying."
                    )
                    : RiffaLocalization.string(
                        "Rename cancelled before execution; no files were changed and no journal was created."
                    )
                compareIfReady()
            } catch let journalError as JournaledLocalFolderSyncError {
                guard let self else { return }
                finishExplicitRenameTask()
                lastExecutionMessage = nil
                errorMessage = Self.explicitRenameJournalFailureMessage(journalError)
                compareIfReady()
            } catch {
                guard let self else { return }
                finishExplicitRenameTask()
                lastExecutionMessage = nil
                errorMessage = String(
                    localized: "The rename was refused safely. \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                compareIfReady()
            }
        }
    }

    func cancelExplicitRename() {
        guard isApplyingExplicitRename else { return }
        lastExecutionMessage = RiffaLocalization.string(
            "Cancelling rename and restoring the original name if needed…"
        )
        explicitRenameTask?.cancel()
    }

    func renameCounterpart(for node: PairNode) -> String? {
        guard node.status == .leftOnly || node.status == .rightOnly else { return nil }
        return renameCounterparts[node.relativePath]
    }

    func canMoveVerifiedSelection(
        within _: FolderSyncSide,
        selectedPaths: Set<PairNode.ID>
    ) -> Bool {
        guard !isLoading,
              !isApplyingSelection,
              !isDetectingRenames,
              renameDetectionResult != nil,
              !selectedPaths.isEmpty else {
            return false
        }
        // Keep SwiftUI validation O(selection), not O(all comparison rows).
        // The strict planner still revalidates every public detector field when
        // the user invokes the command.
        return selectedPaths.allSatisfy { renameCounterparts[$0] != nil }
    }

    fileprivate func moveVerifiedSelection(
        within targetSide: FolderSyncSide,
        selectedPaths: Set<PairNode.ID>
    ) {
        guard !isLoading, !isApplyingSelection else { return }
        guard let leftURL, let rightURL else {
            errorMessage = RiffaLocalization.string(
                "Choose both folders before moving verified matches."
            )
            return
        }

        let movePlan: FolderCompareVerifiedMovePlanningResult
        do {
            movePlan = try makeVerifiedMovePlan(
                targetSide: targetSide,
                selectedPaths: selectedPaths
            )
        } catch {
            errorMessage = String(
                localized: "The verified move plan could not be created. \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }

        let targetTitle = Self.sideTitle(targetSide)
        let referenceTitle = Self.sideTitle(targetSide == .left ? .right : .left)
        let journalDirectoryURL = JournaledLocalFolderSyncExecutor
            .defaultApplicationJournalDirectoryURL
        let supportRoot = Self.verifiedMoveSupportRoot(
            leftRoot: leftURL,
            rightRoot: rightURL,
            journalDirectoryURL: journalDirectoryURL
        )

        isApplyingSelection = true
        isApplyingVerifiedMoves = true
        errorMessage = nil
        lastExecutionMessage = if movePlan.selectedMatchCount == 1 {
            String(
                localized: "Preflighting \(movePlan.selectedMatchCount) verified move within \(targetTitle)…",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        } else {
            String(
                localized: "Preflighting \(movePlan.selectedMatchCount) verified moves within \(targetTitle)…",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }

        verifiedMoveTask = Task { [weak self] in
            var formalExecutionStarted = false
            do {
                let preflight = try await Self.executeVerifiedMovePlan(
                    movePlan.plan,
                    leftRoot: leftURL,
                    rightRoot: rightURL,
                    supportRoot: supportRoot,
                    journalDirectoryURL: journalDirectoryURL,
                    dryRun: true
                )
                try Task.checkCancellation()
                guard let self else { return }
                guard preflight.status == .dryRun else {
                    finishVerifiedMoveTask()
                    lastExecutionMessage = nil
                    errorMessage = Self.executionIssueMessage(
                        preflight,
                        fallback: RiffaLocalization.string(
                            "The verified move plan did not pass whole-plan preflight. No files were changed."
                        )
                    )
                    return
                }

                let confirmation = NSAlert()
                confirmation.alertStyle = .warning
                confirmation.messageText = if movePlan.selectedMatchCount == 1 {
                    String(
                        localized: "Move \(movePlan.selectedMatchCount) verified match within \(targetTitle)?",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                } else {
                    String(
                        localized: "Move \(movePlan.selectedMatchCount) verified matches within \(targetTitle)?",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                }
                confirmation.informativeText = Self.verifiedMoveConfirmationSummary(
                    movePlan,
                    targetTitle: targetTitle,
                    referenceTitle: referenceTitle
                )
                confirmation.addButton(
                    withTitle: String(
                        localized: "Move Within \(targetTitle)",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                )
                confirmation.addButton(
                    withTitle: RiffaLocalization.string("Cancel")
                )
                guard confirmation.runModal() == .alertFirstButtonReturn else {
                    finishVerifiedMoveTask()
                    lastExecutionMessage = RiffaLocalization.string(
                        "Verified move cancelled after preflight; no files were changed and no journal was created."
                    )
                    return
                }

                lastExecutionMessage = String(
                    localized: "Moving verified matches within \(targetTitle) with journaled rollback protection…",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                formalExecutionStarted = true
                let execution = try await Self.executeVerifiedMovePlan(
                    movePlan.plan,
                    leftRoot: leftURL,
                    rightRoot: rightURL,
                    supportRoot: supportRoot,
                    journalDirectoryURL: journalDirectoryURL,
                    dryRun: false
                )
                finishVerifiedMoveTask()

                let wasCancelled = execution.issues.contains { $0.code == .cancelled }
                switch execution.status {
                case .completed:
                    lastExecutionMessage = if movePlan.selectedMatchCount == 1 {
                        String(
                            localized: "Moved \(movePlan.selectedMatchCount) verified match within \(targetTitle).",
                            bundle: RiffaLocalization.localizedBundle,
                            locale: RiffaLocalization.locale
                        )
                    } else {
                        String(
                            localized: "Moved \(movePlan.selectedMatchCount) verified matches within \(targetTitle).",
                            bundle: RiffaLocalization.localizedBundle,
                            locale: RiffaLocalization.locale
                        )
                    }
                    compareIfReady()
                case .failedRolledBack:
                    lastExecutionMessage = wasCancelled
                        ? RiffaLocalization.string(
                            "Move cancelled; every completed change was rolled back."
                        )
                        : RiffaLocalization.string(
                            "The verified move failed; every completed change was rolled back."
                        )
                    errorMessage = wasCancelled ? nil : Self.executionIssueMessage(
                        execution,
                        fallback: RiffaLocalization.string(
                            "The verified move failed and completed changes were rolled back."
                        )
                    )
                    compareIfReady()
                case .failedRollbackIncomplete:
                    lastExecutionMessage = nil
                    errorMessage = Self.executionIssueMessage(
                        execution,
                        fallback: RiffaLocalization.string(
                            "The verified move stopped and rollback was incomplete. Inspect both paths and Operation History before retrying."
                        )
                    )
                    compareIfReady()
                case .refused:
                    lastExecutionMessage = nil
                    errorMessage = Self.executionIssueMessage(
                        execution,
                        fallback: RiffaLocalization.string(
                            "A source, reference, destination, or parent changed after confirmation. The whole plan was refused before writing."
                        )
                    )
                    compareIfReady()
                case .dryRun:
                    lastExecutionMessage = RiffaLocalization.string(
                        "The verified move was not applied; only preflight completed."
                    )
                }
            } catch is CancellationError {
                guard let self else { return }
                finishVerifiedMoveTask()
                lastExecutionMessage = formalExecutionStarted
                    ? RiffaLocalization.string(
                        "Move cancellation was requested before a terminal result. Inspect Operation History before retrying."
                    )
                    : RiffaLocalization.string(
                        "Verified move cancelled before execution; no files were changed and no journal was created."
                    )
                compareIfReady()
            } catch let journalError as JournaledLocalFolderSyncError {
                guard let self else { return }
                finishVerifiedMoveTask()
                lastExecutionMessage = nil
                errorMessage = Self.verifiedMoveJournalFailureMessage(journalError)
                compareIfReady()
            } catch {
                guard let self else { return }
                finishVerifiedMoveTask()
                lastExecutionMessage = nil
                errorMessage = String(
                    localized: "The verified move could not be finalized. \(error.localizedDescription) Inspect Operation History before retrying.",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                compareIfReady()
            }
        }
    }

    func cancelVerifiedMove() {
        guard isApplyingVerifiedMoves else { return }
        lastExecutionMessage = RiffaLocalization.string(
            "Cancelling verified move and rolling back any completed changes…"
        )
        verifiedMoveTask?.cancel()
    }

    fileprivate func copySelection(
        _ direction: FolderSelectionCopyDirection,
        selectedPaths: Set<PairNode.ID>
    ) {
        guard !isLoading, !isApplyingSelection else { return }
        guard let leftURL, let rightURL else {
            errorMessage = RiffaLocalization.string(
                "Choose both folders before copying selected items."
            )
            return
        }

        let copyPlan: FolderSelectionCopyPlan
        do {
            copyPlan = try makeSelectionCopyPlan(
                direction: direction,
                selectedPaths: selectedPaths
            )
        } catch {
            errorMessage = String(
                localized: "The selected copy plan could not be created. \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }

        let backupPanel = NSOpenPanel()
        backupPanel.canChooseFiles = false
        backupPanel.canChooseDirectories = true
        backupPanel.canCreateDirectories = true
        backupPanel.allowsMultipleSelection = false
        backupPanel.title = RiffaLocalization.string(
            "Choose an Independent Backup Folder"
        )
        backupPanel.message = RiffaLocalization.string(
            "Choose a folder outside both compared roots. Existing replacement targets will be moved here before the copy commits."
        )
        backupPanel.prompt = RiffaLocalization.string("Use for Backups")
        guard backupPanel.runModal() == .OK, let backupURL = backupPanel.url else { return }

        isApplyingSelection = true
        lastExecutionMessage = String(
            localized: "Preflighting selected \(direction.title) actions…",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        errorMessage = nil
        let journalDirectoryURL = JournaledLocalFolderSyncExecutor
            .defaultApplicationJournalDirectoryURL

        Task { [weak self] in
            let preflight: LocalFolderSyncExecutionLog
            do {
                preflight = try await Task.detached(priority: .userInitiated) {
                    try await JournaledLocalFolderSyncExecutor(
                        journalDirectoryURL: journalDirectoryURL
                    ).execute(
                        plan: copyPlan.plan,
                        leftRoot: leftURL,
                        rightRoot: rightURL,
                        backupRoot: backupURL,
                        options: .init(dryRun: true, allowHighRisk: false)
                    )
                }.value
            } catch {
                guard let self else { return }
                isApplyingSelection = false
                lastExecutionMessage = nil
                errorMessage = String(
                    localized: "The selected copy preflight could not complete. \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                return
            }

            guard let self else { return }
            guard preflight.status == .dryRun else {
                isApplyingSelection = false
                lastExecutionMessage = nil
                errorMessage = Self.executionIssueMessage(
                    preflight,
                    fallback: RiffaLocalization.string(
                        "The selected copy plan did not pass preflight. No files were changed."
                    )
                )
                return
            }

            let confirmation = NSAlert()
            confirmation.alertStyle = .warning
            let directionTitle = direction.title
            confirmation.messageText = String(
                localized: "Copy selected items \(directionTitle)?",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            confirmation.informativeText = Self.confirmationSummary(
                copyPlan,
                direction: direction,
                backupURL: backupURL
            )
            confirmation.addButton(
                withTitle: RiffaLocalization.string("Copy with Backup")
            )
            confirmation.addButton(
                withTitle: RiffaLocalization.string("Cancel")
            )
            guard confirmation.runModal() == .alertFirstButtonReturn else {
                isApplyingSelection = false
                lastExecutionMessage = nil
                return
            }

            lastExecutionMessage = String(
                localized: "Copying selected \(direction.title) items with rollback protection…",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            let execution: LocalFolderSyncExecutionLog
            do {
                execution = try await Task.detached(priority: .userInitiated) {
                    try await JournaledLocalFolderSyncExecutor(
                        journalDirectoryURL: journalDirectoryURL
                    ).execute(
                        plan: copyPlan.plan,
                        leftRoot: leftURL,
                        rightRoot: rightURL,
                        backupRoot: backupURL,
                        options: .init(dryRun: false, allowHighRisk: false)
                    )
                }.value
            } catch is CancellationError {
                self.isApplyingSelection = false
                self.lastExecutionMessage = RiffaLocalization.string(
                    "The copy was interrupted. Its unfinished operation journal is available for recovery."
                )
                return
            } catch {
                self.isApplyingSelection = false
                self.lastExecutionMessage = nil
                self.errorMessage = String(
                    localized: "The selected copy could not be finalized. \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                return
            }

            self.isApplyingSelection = false
            switch execution.status {
            case .completed:
                self.lastExecutionMessage = if copyPlan.plan.summary.actionableCount == 1 {
                    String(
                        localized: "Copied \(copyPlan.plan.summary.actionableCount) action \(direction.title). Backup: \(backupURL.path)",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                } else {
                    String(
                        localized: "Copied \(copyPlan.plan.summary.actionableCount) actions \(direction.title). Backups: \(backupURL.path)",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                }
                self.compareIfReady()
            case .failedRolledBack:
                self.lastExecutionMessage = RiffaLocalization.string(
                    "The copy failed; completed changes were rolled back."
                )
                self.errorMessage = Self.executionIssueMessage(
                    execution,
                    fallback: RiffaLocalization.string(
                        "The selected copy failed and completed changes were rolled back."
                    )
                )
            case .failedRollbackIncomplete:
                self.lastExecutionMessage = nil
                self.errorMessage = Self.executionIssueMessage(
                    execution,
                    fallback: RiffaLocalization.string(
                        "The selected copy failed and rollback was incomplete. Inspect both roots and the backup folder."
                    )
                )
            case .refused:
                self.lastExecutionMessage = nil
                self.errorMessage = Self.executionIssueMessage(
                    execution,
                    fallback: RiffaLocalization.string(
                        "The folders changed after confirmation, so the copy was refused before writing."
                    )
                )
            case .dryRun:
                self.lastExecutionMessage = RiffaLocalization.string(
                    "Dry-run completed; no files were changed."
                )
            }
        }
    }

    fileprivate func deleteSelection(
        from targetSide: FolderSyncSide,
        selectedPaths: Set<PairNode.ID>
    ) {
        guard !isLoading, !isApplyingSelection else { return }
        guard let leftURL, let rightURL else {
            errorMessage = RiffaLocalization.string(
                "Choose both folders before deleting selected items."
            )
            return
        }

        let plan: FolderSyncPlan
        do {
            plan = try FolderSelectionDeletePlanner().plan(
                nodes: nodes,
                selectedIDs: selectedPaths,
                targetSide: targetSide,
                allowsDirectoryTargets: !pathRules.isEnabled
            )
        } catch {
            errorMessage = String(
                localized: "The selected deletion plan could not be created. \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
            return
        }

        let sideTitle = Self.sideTitle(targetSide)
        let backupPanel = NSOpenPanel()
        backupPanel.canChooseFiles = false
        backupPanel.canChooseDirectories = true
        backupPanel.canCreateDirectories = true
        backupPanel.allowsMultipleSelection = false
        backupPanel.title = RiffaLocalization.string(
            "Choose an Independent Backup Folder"
        )
        backupPanel.message = String(
            localized: "Choose a folder outside both compared roots. Every selected target on the \(sideTitle) side will be moved here instead of being erased.",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        backupPanel.prompt = RiffaLocalization.string("Use for Backups")
        guard backupPanel.runModal() == .OK, let backupURL = backupPanel.url else {
            lastExecutionMessage = RiffaLocalization.string(
                "Deletion cancelled; no files were changed."
            )
            return
        }

        isApplyingSelection = true
        errorMessage = nil
        lastExecutionMessage = if plan.summary.deleteCount == 1 {
            String(
                localized: "Preflighting \(plan.summary.deleteCount) selected deletion action on the \(sideTitle) side…",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        } else {
            String(
                localized: "Preflighting \(plan.summary.deleteCount) selected deletion actions on the \(sideTitle) side…",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        let journalDirectoryURL = JournaledLocalFolderSyncExecutor
            .defaultApplicationJournalDirectoryURL

        Task { [weak self] in
            let preflight: LocalFolderSyncExecutionLog
            do {
                preflight = try await Task.detached(priority: .userInitiated) {
                    try await JournaledLocalFolderSyncExecutor(
                        journalDirectoryURL: journalDirectoryURL
                    ).execute(
                        plan: plan,
                        leftRoot: leftURL,
                        rightRoot: rightURL,
                        backupRoot: backupURL,
                        options: .init(dryRun: true, allowHighRisk: true)
                    )
                }.value
            } catch {
                guard let self else { return }
                isApplyingSelection = false
                lastExecutionMessage = nil
                errorMessage = String(
                    localized: "Deletion preflight could not complete; no files were changed. \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                return
            }

            guard let self else { return }
            guard preflight.status == .dryRun else {
                isApplyingSelection = false
                lastExecutionMessage = nil
                errorMessage = Self.executionIssueMessage(
                    preflight,
                    fallback: RiffaLocalization.string(
                        "The exact selected-side deletion plan did not pass preflight. No files were changed."
                    )
                )
                return
            }

            let confirmation = NSAlert()
            confirmation.alertStyle = .critical
            confirmation.messageText = if plan.summary.deleteCount == 1 {
                String(
                    localized: "Delete \(plan.summary.deleteCount) selected item from \(sideTitle)?",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            } else {
                String(
                    localized: "Delete \(plan.summary.deleteCount) selected items from \(sideTitle)?",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
            confirmation.informativeText = Self.deletionConfirmationSummary(
                plan,
                selectedCount: selectedPaths.count,
                targetSide: targetSide,
                backupURL: backupURL
            )
            confirmation.addButton(
                withTitle: RiffaLocalization.string("Delete with Backup")
            )
            confirmation.addButton(
                withTitle: RiffaLocalization.string("Cancel")
            )
            guard confirmation.runModal() == .alertFirstButtonReturn else {
                isApplyingSelection = false
                lastExecutionMessage = RiffaLocalization.string(
                    "Deletion cancelled after preflight; no files were changed and no journal was created."
                )
                return
            }

            lastExecutionMessage = if plan.summary.deleteCount == 1 {
                String(
                    localized: "Deleting \(plan.summary.deleteCount) selected item from the \(sideTitle) side with journaled rollback protection…",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            } else {
                String(
                    localized: "Deleting \(plan.summary.deleteCount) selected items from the \(sideTitle) side with journaled rollback protection…",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
            let execution: LocalFolderSyncExecutionLog
            do {
                execution = try await Task.detached(priority: .userInitiated) {
                    try await JournaledLocalFolderSyncExecutor(
                        journalDirectoryURL: journalDirectoryURL
                    ).execute(
                        plan: plan,
                        leftRoot: leftURL,
                        rightRoot: rightURL,
                        backupRoot: backupURL,
                        options: .init(dryRun: false, allowHighRisk: true)
                    )
                }.value
            } catch is CancellationError {
                self.isApplyingSelection = false
                self.lastExecutionMessage = RiffaLocalization.string(
                    "Deletion was interrupted. Inspect the unfinished operation journal, target root, and backup folder before retrying."
                )
                self.compareIfReady()
                return
            } catch let journalError as JournaledLocalFolderSyncError {
                self.isApplyingSelection = false
                self.lastExecutionMessage = nil
                self.errorMessage = Self.journalFailureMessage(
                    journalError,
                    targetSide: targetSide,
                    backupURL: backupURL
                )
                self.compareIfReady()
                return
            } catch {
                self.isApplyingSelection = false
                self.lastExecutionMessage = nil
                self.errorMessage = String(
                    localized: "Deletion could not be finalized. \(error.localizedDescription) Inspect the target and backup folder before retrying.",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                self.compareIfReady()
                return
            }

            self.isApplyingSelection = false
            switch execution.status {
            case .completed:
                self.lastExecutionMessage = if plan.summary.deleteCount == 1 {
                    String(
                        localized: "Deleted \(plan.summary.deleteCount) selected item from the \(sideTitle) side. Backup: \(backupURL.path)",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                } else {
                    String(
                        localized: "Deleted \(plan.summary.deleteCount) selected items from the \(sideTitle) side. Backup: \(backupURL.path)",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                }
                self.compareIfReady()
            case .failedRolledBack:
                self.lastExecutionMessage = RiffaLocalization.string(
                    "The deletion failed; every completed change was rolled back."
                )
                self.errorMessage = Self.executionIssueMessage(
                    execution,
                    fallback: RiffaLocalization.string(
                        "The selected deletion failed and completed changes were rolled back."
                    )
                )
                self.compareIfReady()
            case .failedRollbackIncomplete:
                self.lastExecutionMessage = nil
                self.errorMessage = Self.executionIssueMessage(
                    execution,
                    fallback: RiffaLocalization.string(
                        "The selected deletion failed and rollback was incomplete. Inspect both roots, the backup folder, and Operation History."
                    )
                )
                self.compareIfReady()
            case .refused:
                self.lastExecutionMessage = nil
                self.errorMessage = Self.executionIssueMessage(
                    execution,
                    fallback: RiffaLocalization.string(
                        "The selected targets changed after confirmation, so the deletion was refused before writing."
                    )
                )
                self.compareIfReady()
            case .dryRun:
                self.lastExecutionMessage = RiffaLocalization.string(
                    "Deletion was not applied; the executor completed only a dry-run."
                )
            }
        }
    }

    func saveReport(format: ComparisonReportFormat) {
        guard leftURL != nil, rightURL != nil, !isLoading else { return }
        let fileExtension: String
        switch format {
        case .plainText: fileExtension = "txt"
        case .html: fileExtension = "html"
        case .json: fileExtension = "json"
        }

        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string(
            "Export Folder Comparison Report"
        )
        panel.prompt = RiffaLocalization.string("Export")
        panel.nameFieldStringValue = String(
            localized: "Riffa-Folder-Report.\(fileExtension)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let report = try ComparisonReportGenerator().generate(
                folder: nodes,
                format: format,
                leftLabel: leftURL?.lastPathComponent
                    ?? RiffaLocalization.string("Left"),
                rightLabel: rightURL?.lastPathComponent
                    ?? RiffaLocalization.string("Right")
            )
            try report.write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = String(
                localized: "Could not export report: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    func loadDemo() {
        do {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "RiffaDemo", directoryHint: .isDirectory)
            let left = root.appending(path: "left", directoryHint: .isDirectory)
            let right = root.appending(path: "right", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)

            try Data("same\n".utf8).write(to: left.appending(path: "README.txt"), options: .atomic)
            try Data("same\n".utf8).write(to: right.appending(path: "README.txt"), options: .atomic)
            try Data("blue\n".utf8).write(to: left.appending(path: "theme.txt"), options: .atomic)
            try Data("coral\n".utf8).write(to: right.appending(path: "theme.txt"), options: .atomic)
            try Data("left only\n".utf8).write(to: left.appending(path: "draft.txt"), options: .atomic)
            try Data("right only\n".utf8).write(to: right.appending(path: "release.txt"), options: .atomic)

            let sharedDate = Date(timeIntervalSince1970: 1_700_000_000)
            for name in ["README.txt", "theme.txt"] {
                try FileManager.default.setAttributes(
                    [.modificationDate: sharedDate],
                    ofItemAtPath: left.appending(path: name).path
                )
                try FileManager.default.setAttributes(
                    [.modificationDate: sharedDate],
                    ofItemAtPath: right.appending(path: name).path
                )
            }

            leftURL = left
            rightURL = right
            compareContents = true
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
        operationSupportNodes = []
        comparisonGeneration = UUID()
        let generation = comparisonGeneration
        cancelRenameDetection(clearResults: true)
        guard let leftURL, let rightURL else {
            nodes = []
            isLoading = false
            return
        }
        guard pathRulesAreValid else {
            let message = pathRuleRestoreFailureMessage
                ?? RiffaLocalization.string(
                    "Saved folder path rules are invalid. No comparison was started."
                )
            nodes = [Self.pathRuleErrorNode(message)]
            isLoading = false
            errorMessage = message
            return
        }

        let options = FolderComparisonOptions(
            compareModificationDates: compareModificationDates,
            compareFileContents: compareContents,
            pathRules: pathRules
        )
        isLoading = true
        errorMessage = nil

        comparisonTask = Task { [weak self] in
            let publication = await FolderComparison().comparePublication(
                leftURL: leftURL,
                rightURL: rightURL,
                options: options
            )
            guard !Task.isCancelled,
                  let self,
                  comparisonGeneration == generation else { return }
            nodes = publication.visibleNodes
            operationSupportNodes = publication.operationSupportNodes
            isLoading = false
            if let issue = publication.visibleNodes.lazy.flatMap(\.issues).first,
               let description = issue.errorDescription {
                errorMessage = String(
                    localized: "Folder comparison reported an issue. \(description)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
            startRenameDetectionIfReady()
        }
    }

    private func startRenameDetectionIfReady() {
        guard detectRenames,
              !isLoading,
              leftURL != nil,
              rightURL != nil else { return }
        cancelRenameDetection(clearResults: true)
        let nodeSnapshot = nodes
        let generation = UUID()
        renameDetectionGeneration = generation
        isDetectingRenames = true

        renameDetectionTask = Task { [weak self] in
            do {
                let result = try await LocalFolderRenameDetector().detect(nodes: nodeSnapshot)
                guard !Task.isCancelled,
                      let self,
                      detectRenames,
                      renameDetectionGeneration == generation else { return }
                var counterparts: [String: String] = [:]
                counterparts.reserveCapacity(result.matches.count * 2)
                for match in result.matches {
                    counterparts[match.leftRelativePath] = match.rightRelativePath
                    counterparts[match.rightRelativePath] = match.leftRelativePath
                }
                renameDetectionResult = result
                renameCounterparts = counterparts
                isDetectingRenames = false
            } catch is CancellationError {
                guard let self,
                      renameDetectionGeneration == generation else { return }
                isDetectingRenames = false
            } catch let detectionError as FolderRenameDetectionError {
                guard let self,
                      detectRenames,
                      renameDetectionGeneration == generation else { return }
                renameDetectionWarning = String(
                    localized: "Move detection could not finish. \(detectionError.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                isDetectingRenames = false
            } catch {
                guard let self,
                      detectRenames,
                      renameDetectionGeneration == generation else { return }
                // Unknown localized errors can embed absolute paths. Keep the
                // UI warning deliberately generic instead.
                renameDetectionWarning = RiffaLocalization.string(
                    "A candidate could not be safely verified."
                )
                isDetectingRenames = false
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
            renameCounterparts = [:]
            renameDetectionWarning = nil
        }
    }

    private static func restoredPathRules(
        from options: [String: String]
    ) throws -> FolderPathRules {
        let keys = [
            "pathRulesEnabled",
            "pathRulesCaseSensitive",
            "pathRuleIncludes",
            "pathRuleExcludes"
        ]
        guard keys.contains(where: { options[$0] != nil }) else { return .all }
        guard let isEnabled = options.riffaBoolean(for: "pathRulesEnabled"),
              let isCaseSensitive = options.riffaBoolean(for: "pathRulesCaseSensitive"),
              let includePatterns = options.riffaStrings(for: "pathRuleIncludes"),
              let excludePatterns = options.riffaStrings(for: "pathRuleExcludes") else {
            throw FolderPathRuleSessionError.malformedOptions
        }
        return try FolderPathRules(
            isEnabled: isEnabled,
            includePatterns: includePatterns,
            excludePatterns: excludePatterns,
            isCaseSensitive: isCaseSensitive
        )
    }

    private static func pathRuleErrorNode(_ message: String) -> PairNode {
        PairNode(
            relativePath: ".",
            left: nil,
            right: nil,
            status: .error,
            issues: [
                ResourceIssue(
                    path: ".",
                    message: message,
                    domain: "RiffaApp.FolderPathRules",
                    code: 1
                )
            ]
        )
    }

    private func makeSelectionCopyPlan(
        direction: FolderSelectionCopyDirection,
        selectedPaths: Set<PairNode.ID>
    ) throws -> FolderSelectionCopyPlan {
        try FolderSelectionCopyPlanner().plan(
            visibleNodes: nodes,
            operationSupportNodes: operationSupportNodes,
            selectedIDs: selectedPaths,
            sourceSide: direction.sourceSide
        )
    }

    private func makeVerifiedMovePlan(
        targetSide: FolderSyncSide,
        selectedPaths: Set<PairNode.ID>
    ) throws -> FolderCompareVerifiedMovePlanningResult {
        guard let renameDetectionResult else {
            throw FolderCompareVerifiedMovePlanningError.selectionContainsUnverifiedPath
        }
        return try FolderCompareVerifiedMovePlanner().plan(
            visibleNodes: nodes,
            operationSupportNodes: operationSupportNodes,
            renameDetectionResult: renameDetectionResult,
            selectedIDs: selectedPaths,
            targetSide: targetSide
        )
    }

    private func finishVerifiedMoveTask() {
        isApplyingSelection = false
        isApplyingVerifiedMoves = false
        verifiedMoveTask = nil
    }

    private func finishExplicitRenameTask() {
        isApplyingSelection = false
        isApplyingExplicitRename = false
        explicitRenameTask = nil
    }

    private nonisolated static func makeExplicitRenamePlan(
        visibleNodes: [PairNode],
        selectedPaths: Set<PairNode.ID>,
        side: FolderSyncSide,
        newLeafName: String,
        root: URL
    ) async throws -> FolderCompareExplicitRenamePlanningResult {
        let worker = Task.detached(priority: .userInitiated) {
            try await FolderCompareExplicitRenamePlanner().plan(
                visibleNodes: visibleNodes,
                selectedIDs: selectedPaths,
                side: side,
                newLeafName: newLeafName,
                root: root
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func executeVerifiedMovePlan(
        _ plan: FolderSyncPlan,
        leftRoot: URL,
        rightRoot: URL,
        supportRoot: URL,
        journalDirectoryURL: URL,
        dryRun: Bool
    ) async throws -> LocalFolderSyncExecutionLog {
        let worker = Task.detached(priority: .userInitiated) {
            try await JournaledLocalFolderSyncExecutor(
                journalDirectoryURL: journalDirectoryURL
            ).execute(
                plan: plan,
                leftRoot: leftRoot,
                rightRoot: rightRoot,
                backupRoot: supportRoot,
                options: .init(dryRun: dryRun, allowHighRisk: true)
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func verifiedMoveConfirmationSummary(
        _ result: FolderCompareVerifiedMovePlanningResult,
        targetTitle: String,
        referenceTitle: String
    ) -> String {
        let preflightSummary = if result.selectedMatchCount == 1 {
            String(
                localized: "High-risk file operation: \(result.selectedMatchCount) unique same-content match passed whole-plan preflight.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        } else {
            String(
                localized: "High-risk file operation: \(result.selectedMatchCount) unique same-content matches passed whole-plan preflight.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        var lines = [
            preflightSummary,
            String(
                localized: "Only \(targetTitle.lowercased())-side paths will change. The \(referenceTitle.lowercased()) side is a read-only byte reference.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            ),
            RiffaLocalization.string(
                "Each source and reference will be rehashed immediately before a no-clobber move; an existing destination is never replaced."
            )
        ]
        let moveActions = result.plan.actions.filter { $0.kind == .move }
        lines.append("")
        lines.append(contentsOf: moveActions.prefix(10).map { action in
            let source = action.sourceRelativePath
                ?? RiffaLocalization.string("Unknown source")
            let destination = action.targetRelativePath
                ?? RiffaLocalization.string("Unknown destination")
            return String(
                localized: "• \(targetTitle): \(source) → \(destination)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        })
        if moveActions.count > 10 {
            lines.append(
                String(
                    localized: "• …and \(moveActions.count - 10) more",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            )
        }
        lines.append("")
        lines.append(
            RiffaLocalization.string(
                "The exact plan will be preflighted again after confirmation and recorded in Operation History. Cancellation or any later failure triggers transaction-wide rollback."
            )
        )
        return lines.joined(separator: "\n")
    }

    private static func explicitRenameConfirmationSummary(
        _ result: FolderCompareExplicitRenamePlanningResult,
        sideTitle: String
    ) -> String {
        let byteCount = Int64(result.sourceSnapshot.byteCount).formatted(
            .byteCount(style: .file).locale(RiffaLocalization.locale)
        )
        let digestPrefix = String(result.sourceSnapshot.sha256.prefix(12))
        var lines = [
            RiffaLocalization.string(
                "Dry-run passed for one ordinary local file:"
            ),
            "",
            String(
                localized: "• \(sideTitle): \(result.sourceRelativePath) → \(result.destinationRelativePath)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            ),
            String(
                localized: "• \(byteCount); SHA-256 \(digestPrefix)…",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            ),
            "",
            RiffaLocalization.string(
                "The source inode, size, mtime, ctime, metadata, and digest will be checked again through no-follow descriptors. An existing third-party destination is never replaced."
            )
        ]
        if result.kind == .caseOnly {
            lines.append(
                RiffaLocalization.string(
                    "This is a case-only rename. Riffa uses a hidden, unguessable same-directory intermediate name and two exclusive atomic renames so both case-sensitive and case-insensitive volumes fail closed."
                )
            )
        } else {
            lines.append(
                RiffaLocalization.string(
                    "Only an atomic same-parent no-clobber rename is allowed; there is no copy fallback, no directory creation, and no change to the other side."
                )
            )
        }
        lines.append(
            RiffaLocalization.string(
                "The operation will be recorded in Operation History. Cancellation or a later transaction failure restores the original name; an interrupted hidden-name crash scene is reported for manual recovery review."
            )
        )
        return lines.joined(separator: "\n")
    }

    private static func verifiedMoveJournalFailureMessage(
        _ error: JournaledLocalFolderSyncError
    ) -> String {
        let base = error.localizedDescription
        switch error {
        case .unrepresentableAction,
             .journalPersistenceFailed(stage: .create, journalID: _, underlying: _),
             .journalPersistenceFailed(stage: .markExecuting, journalID: _, underlying: _):
            return String(
                localized: "\(base) No verified move was started.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .inconsistentExecutionLog,
             .journalPersistenceFailed(stage: .recordResult, journalID: _, underlying: _),
             .journalPersistenceFailed(stage: .markTerminal, journalID: _, underlying: _):
            return String(
                localized: "\(base) The file transaction may already have moved or restored paths. Inspect Operation History and both compared roots before retrying.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private static func explicitRenameJournalFailureMessage(
        _ error: JournaledLocalFolderSyncError
    ) -> String {
        let base = error.localizedDescription
        switch error {
        case .unrepresentableAction,
             .journalPersistenceFailed(stage: .create, journalID: _, underlying: _),
             .journalPersistenceFailed(stage: .markExecuting, journalID: _, underlying: _):
            return String(
                localized: "\(base) No rename was started.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .inconsistentExecutionLog,
             .journalPersistenceFailed(stage: .recordResult, journalID: _, underlying: _),
             .journalPersistenceFailed(stage: .markTerminal, journalID: _, underlying: _):
            return String(
                localized: "\(base) The file may already have been renamed or restored. Inspect Operation History and both names before retrying.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private static func sideTitle(_ side: FolderSyncSide) -> String {
        switch side {
        case .left: RiffaLocalization.string("Left")
        case .right: RiffaLocalization.string("Right")
        }
    }

    private static func verifiedMoveSupportRoot(
        leftRoot: URL,
        rightRoot: URL,
        journalDirectoryURL: URL
    ) -> URL {
        // The shared executor requires an independent backup capability even
        // though pure moves never write to it. Prefer temporary storage so a
        // comparison of the user's home folder does not overlap App Support;
        // retain an App Support fallback for comparisons rooted in /private/tmp.
        let candidates = [
            FileManager.default.temporaryDirectory.appending(
                path: "dev.riffa.Riffa-folder-compare-move-support",
                directoryHint: .isDirectory
            ),
            journalDirectoryURL.deletingLastPathComponent().appending(
                path: "folder-compare-move-support",
                directoryHint: .isDirectory
            )
        ]
        return candidates.first {
            !pathsOverlap($0, leftRoot) && !pathsOverlap($0, rightRoot)
        } ?? candidates[1]
    }

    private static func pathsOverlap(_ first: URL, _ second: URL) -> Bool {
        let firstComponents = first.standardizedFileURL.pathComponents
        let secondComponents = second.standardizedFileURL.pathComponents
        return firstComponents.starts(with: secondComponents)
            || secondComponents.starts(with: firstComponents)
    }

    private static func confirmationSummary(
        _ copyPlan: FolderSelectionCopyPlan,
        direction: FolderSelectionCopyDirection,
        backupURL: URL
    ) -> String {
        let summary = copyPlan.plan.summary
        let sourceTitle = direction.sourceTitle
        var lines = [
            String(
                localized: "Source items found: \(copyPlan.sourceAvailableCount) of \(copyPlan.selectedCount) selected paths on the \(sourceTitle) side.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            ),
            String(
                localized: "Preflight passed for \(summary.actionableCount) actions: \(summary.copyCount) copies, \(summary.replaceCount) replacements, and \(summary.createDirectoryCount) directory creations.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            ),
            RiffaLocalization.string("Deletion actions: 0."),
            String(
                localized: "Backup folder: \(backupURL.path)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        ]

        if summary.noOpCount > 0 {
            if summary.noOpCount == 1 {
                lines.append(
                    RiffaLocalization.string(
                        "1 selected path already matches and needs no action."
                    )
                )
            } else {
                lines.append(
                    String(
                        localized: "\(summary.noOpCount) selected paths already match and need no action.",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                )
            }
        }

        if copyPlan.automaticallyAddedParentCount == 1 {
            lines.append(
                RiffaLocalization.string(
                    "Riffa added 1 required parent directory; no unselected files are included."
                )
            )
        } else if copyPlan.automaticallyAddedParentCount > 1 {
            lines.append(
                String(
                    localized: "Riffa added \(copyPlan.automaticallyAddedParentCount) required parent directories; no unselected files are included.",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            )
        } else {
            lines.append(
                RiffaLocalization.string("No unselected files are included.")
            )
        }
        if copyPlan.skippedMissingSourceCount > 0 {
            if copyPlan.skippedMissingSourceCount == 1 {
                lines.append(
                    String(
                        localized: "\(copyPlan.skippedMissingSourceCount) selected path was skipped because no source item exists on the \(sourceTitle) side.",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                )
            } else {
                lines.append(
                    String(
                        localized: "\(copyPlan.skippedMissingSourceCount) selected paths were skipped because no source item exists on the \(sourceTitle) side.",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                )
            }
        }

        let actionLines = copyPlan.plan.actions
            .filter { $0.kind == .copy || $0.kind == .replace || $0.kind == .createDirectory }
            .prefix(8)
            .map { action in
                let title = actionTitle(action.kind)
                let path = action.targetRelativePath
                    ?? action.sourceRelativePath
                    ?? RiffaLocalization.string("Unknown path")
                return String(
                    localized: "• \(title): \(path)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        if !actionLines.isEmpty {
            lines.append("")
            lines.append(contentsOf: actionLines)
            let remaining = summary.actionableCount - actionLines.count
            if remaining > 0 {
                lines.append(
                    String(
                        localized: "• …and \(remaining) more",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    )
                )
            }
        }
        lines.append("")
        lines.append(
            RiffaLocalization.string(
                "The executor will preflight the exact plan again before writing. Any later failure triggers best-effort rollback."
            )
        )
        return lines.joined(separator: "\n")
    }

    private static func deletionConfirmationSummary(
        _ plan: FolderSyncPlan,
        selectedCount: Int,
        targetSide: FolderSyncSide,
        backupURL: URL
    ) -> String {
        let sideTitle = Self.sideTitle(targetSide)
        let deletionSummary = switch (
            plan.summary.deleteCount == 1,
            selectedCount == 1
        ) {
        case (true, true):
            String(
                localized: "Critical action: preflight passed for exactly \(plan.summary.deleteCount) \(sideTitle)-side deletion action from \(selectedCount) selected row.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case (true, false):
            String(
                localized: "Critical action: preflight passed for exactly \(plan.summary.deleteCount) \(sideTitle)-side deletion action from \(selectedCount) selected rows.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case (false, true):
            String(
                localized: "Critical action: preflight passed for exactly \(plan.summary.deleteCount) \(sideTitle)-side deletion actions from \(selectedCount) selected row.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case (false, false):
            String(
                localized: "Critical action: preflight passed for exactly \(plan.summary.deleteCount) \(sideTitle)-side deletion actions from \(selectedCount) selected rows.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        var lines = [
            deletionSummary,
            String(
                localized: "Each target will first be moved to this independent backup folder:\n\(backupURL.path)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            ),
            "",
            RiffaLocalization.string(
                "Only the selected leaf paths and selected directory trees listed below are included. Selecting a directory includes everything currently inside that directory."
            )
        ]

        let paths = plan.actions.compactMap(\.targetRelativePath)
        lines.append(contentsOf: paths.prefix(12).map { path in
            String(
                localized: "• \(path)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        })
        if paths.count > 12 {
            lines.append(
                String(
                    localized: "• …and \(paths.count - 12) more",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            )
        }
        lines.append("")
        lines.append(
            RiffaLocalization.string(
                "Riffa will preflight this exact immutable plan again, require the high-risk execution gate, and record the formal attempt in Operation History. Any later failure triggers best-effort rollback."
            )
        )
        return lines.joined(separator: "\n")
    }

    private static func journalFailureMessage(
        _ error: JournaledLocalFolderSyncError,
        targetSide: FolderSyncSide,
        backupURL: URL
    ) -> String {
        let base = error.localizedDescription
        switch error {
        case .unrepresentableAction,
             .journalPersistenceFailed(stage: .create, journalID: _, underlying: _),
             .journalPersistenceFailed(stage: .markExecuting, journalID: _, underlying: _):
            return String(
                localized: "\(base) No selected item was deleted.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .inconsistentExecutionLog,
             .journalPersistenceFailed(stage: .recordResult, journalID: _, underlying: _),
             .journalPersistenceFailed(stage: .markTerminal, journalID: _, underlying: _):
            let sideTitle = Self.sideTitle(targetSide)
            return String(
                localized: "\(base) The file transaction may already have changed the \(sideTitle) side. Inspect Operation History and the backup at \(backupURL.path) before retrying.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private static func actionTitle(_ kind: FolderSyncAction.Kind) -> String {
        switch kind {
        case .copy: RiffaLocalization.string("Copy")
        case .createDirectory: RiffaLocalization.string("Create directory")
        case .move: RiffaLocalization.string("Move")
        case .replace: RiffaLocalization.string("Replace")
        case .delete: RiffaLocalization.string("Delete")
        case .conflict: RiffaLocalization.string("Conflict")
        case .noOp: RiffaLocalization.string("No change")
        }
    }

    private static func executionIssueMessage(
        _ log: LocalFolderSyncExecutionLog,
        fallback: String
    ) -> String {
        let details = log.issues.map { issue in
            String(
                localized: "Operation issue: \(issue.message)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        guard !details.isEmpty else { return fallback }
        return ([fallback] + details).joined(separator: "\n")
    }
}

private enum FolderPathRuleSessionError: LocalizedError {
    case malformedOptions

    var errorDescription: String? {
        RiffaLocalization.string(
            "The saved rule fields are missing or malformed. No unfiltered comparison was started."
        )
    }
}

struct FolderCompareView: View {
    @Environment(\.riffaTheme) private var theme
    @StateObject private var model = FolderCompareModel()
    @State private var selection = Set<PairNode.ID>()
    @State private var isShowingPathRules = false
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
            pathBar

            if model.leftURL == nil || model.rightURL == nil {
                emptyState
            } else if model.isLoading && model.nodes.isEmpty {
                ProgressView("Scanning folders…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsTable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Folder Compare")
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
        .alert(
            "Folder comparison issue",
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
        .sheet(isPresented: $isShowingPathRules) {
            FolderPathRulesEditor(rules: model.pathRules) { rules in
                model.applyPathRules(rules)
            }
        }
        .task(id: ComparisonInitialLoad(urls: initialURLs, options: initialOptions)) {
            model.openInitial(initialURLs, options: initialOptions)
        }
        .onChange(of: model.nodes.map(\.id)) { _, currentIDs in
            selection.formIntersection(currentIDs)
        }
        .onChange(of: model.filter) { _, _ in
            selection.removeAll()
        }
        .onChange(of: model.pathSearch) { _, _ in
            selection.removeAll()
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            RiffaComparisonHeader(
                title: RiffaLocalization.string("Folder Compare"),
                subtitle: RiffaLocalization.string(
                    "Stable recursive path matching"
                )
            ) {
                SessionSaveButton(
                    request: SessionSaveRequest(
                        kind: .folderComparison,
                        urls: [model.leftURL, model.rightURL].compactMap { $0 },
                        options: [
                            "compareContents": .boolean(model.compareContents),
                            "compareModificationDates": .boolean(model.compareModificationDates),
                            "detectRenames": .boolean(model.detectRenames),
                            "resultFilter": .string(model.filter.rawValue),
                            "pathRulesEnabled": .boolean(model.pathRules.isEnabled),
                            "pathRulesCaseSensitive": .boolean(model.pathRules.isCaseSensitive),
                            "pathRuleIncludes": .strings(model.pathRules.includePatterns),
                            "pathRuleExcludes": .strings(model.pathRules.excludePatterns)
                        ]
                    ),
                    errorMessage: $model.errorMessage
                )

                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Refresh folder comparison")
                .accessibilityHint("Scans both folders again")
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh comparison")
                .disabled(
                    model.leftURL == nil
                        || model.rightURL == nil
                        || model.isLoading
                        || model.isApplyingSelection
                )

                Menu {
                    Menu("Export Report") {
                        Button("HTML…") { model.saveReport(format: .html) }
                        Button("Plain Text…") { model.saveReport(format: .plainText) }
                        Button("JSON…") { model.saveReport(format: .json) }
                    }
                    .disabled(
                        model.leftURL == nil
                            || model.rightURL == nil
                            || model.isLoading
                            || model.isApplyingSelection
                    )

                    Divider()
                    Button("Copy Left → Right") {
                        model.copySelection(.leftToRight, selectedPaths: selection)
                    }
                    .disabled(selectionCopyControlsDisabled)
                    Button("Copy Right → Left") {
                        model.copySelection(.rightToLeft, selectedPaths: selection)
                    }
                    .disabled(selectionCopyControlsDisabled)

                    Menu("Rename Selected File") {
                        Button("Rename File on Left…") {
                            model.renameVisibleSelection(
                                on: .left,
                                selectedPaths: selection
                            )
                        }
                        .disabled(
                            !model.canRenameVisibleSelection(
                                on: .left,
                                selectedPaths: selection
                            )
                        )
                        Button("Rename File on Right…") {
                            model.renameVisibleSelection(
                                on: .right,
                                selectedPaths: selection
                            )
                        }
                        .disabled(
                            !model.canRenameVisibleSelection(
                                on: .right,
                                selectedPaths: selection
                            )
                        )
                    }
                    .disabled(explicitRenameControlsDisabled)

                    Menu("Move Verified Match") {
                        Button("Move Within Right to Match Left…") {
                            model.moveVerifiedSelection(
                                within: .right,
                                selectedPaths: selection
                            )
                        }
                        .disabled(
                            !model.canMoveVerifiedSelection(
                                within: .right,
                                selectedPaths: selection
                            )
                        )
                        Button("Move Within Left to Match Right…") {
                            model.moveVerifiedSelection(
                                within: .left,
                                selectedPaths: selection
                            )
                        }
                        .disabled(
                            !model.canMoveVerifiedSelection(
                                within: .left,
                                selectedPaths: selection
                            )
                        )
                    }
                    .disabled(verifiedMoveControlsDisabled)

                    Divider()
                    Button("Delete from Left…", role: .destructive) {
                        model.deleteSelection(
                            from: .left,
                            selectedPaths: selection
                        )
                    }
                    .disabled(selectionMutationControlsDisabled)
                    Button("Delete from Right…", role: .destructive) {
                        model.deleteSelection(
                            from: .right,
                            selectedPaths: selection
                        )
                    }
                    .disabled(selectionMutationControlsDisabled)
                } label: {
                    Label(
                        "File actions",
                        systemImage: "ellipsis.circle"
                    )
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("File actions")
                .accessibilityHint("Opens export, copy, rename, move, and delete actions")
                .help("Export, copy, rename, move, or delete the visible selection")

                if model.isApplyingSelection {
                    ProgressView()
                        .controlSize(.small)
                        .help("Preflighting or applying the selected file-operation plan")
                    if model.isApplyingVerifiedMoves {
                        Button("Cancel Move") {
                            model.cancelVerifiedMove()
                        }
                        .controlSize(.small)
                        .help("Request cancellation; any completed move in this transaction will be rolled back")
                    } else if model.isApplyingExplicitRename {
                        Button("Cancel Rename") {
                            model.cancelExplicitRename()
                        }
                        .controlSize(.small)
                        .help("Request cancellation; an installed new name will be rolled back to the original name")
                    }
                }
            }

            RiffaComparisonControlBar {
                TextField("Filter paths", text: $model.pathSearch)
                    .riffaInputSurface(minHeight: 36)
                    .frame(minWidth: 140, idealWidth: 220, maxWidth: 320)

                Picker("Show", selection: $model.filter) {
                    ForEach(FolderCompareModel.Filter.allCases) { filter in
                        Text(verbatim: filter.localizedTitle).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
                .help("Filter by comparison status, modification recency, or side-specific synchronization candidates")

                Button {
                    isShowingPathRules = true
                } label: {
                    Label(pathRuleButtonTitle, systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Edit persistent include and exclude path rules")

                Menu {
                    Toggle("Compare File Contents", isOn: $model.compareContents)
                    Toggle("Compare Modified Date", isOn: $model.compareModificationDates)
                    Toggle("Detect Moves", isOn: $model.detectRenames)
                } label: {
                    Label("Compare Options", systemImage: "slider.horizontal.3")
                }
                .help("Choose content, modified-date, and verified move-detection options")
                .accessibilityValue(folderComparisonOptionsSummary)
            }
            .disabled(model.isApplyingSelection)
        }
    }

    private var pathRuleButtonTitle: String {
        guard model.pathRules.isEnabled else {
            return RiffaLocalization.string("Rules Off")
        }
        return String(
            localized: "Rules \(model.pathRules.includePatterns.count)/\(model.pathRules.excludePatterns.count)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private var folderComparisonOptionsSummary: String {
        let values = [
            model.compareContents
                ? RiffaLocalization.string("contents on")
                : RiffaLocalization.string("contents off"),
            model.compareModificationDates
                ? RiffaLocalization.string("modified date on")
                : RiffaLocalization.string("modified date off"),
            model.detectRenames
                ? RiffaLocalization.string("move detection on")
                : RiffaLocalization.string("move detection off")
        ]
        let formatter = ListFormatter()
        formatter.locale = RiffaLocalization.locale
        return formatter.string(from: values) ?? values.joined(separator: ", ")
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            FolderPathButton(
                title: RiffaLocalization.string("Left folder"),
                url: model.leftURL
            ) {
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
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.riffaTertiary)
            .accessibilityLabel("Swap folders")
            .accessibilityHint("Exchanges the left and right folders")
            .help("Swap left and right")
            .disabled(model.leftURL == nil && model.rightURL == nil)

            FolderPathButton(
                title: RiffaLocalization.string("Right folder"),
                url: model.rightURL
            ) {
                model.chooseFolder(for: .right)
            }
            .riffaResourceDropTarget(
                role: .right,
                acceptedKind: .realDirectory
            ) {
                model.setFolder($0, for: .right)
            }
        }
        .disabled(model.isPerformingFileOperation)
    }

    private var resultsTable: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Table(model.filteredNodes, selection: $selection) {
                    TableColumn("Status") { node in
                        StatusLabel(status: node.status)
                    }
                    .width(min: 94, ideal: 112, max: 130)

                    TableColumn("Relative path") { node in
                        HStack(spacing: 7) {
                            Image(systemName: symbol(for: node))
                                .foregroundStyle(.secondary)
                            Text(node.relativePath)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                    .width(min: 260, ideal: 420)

                    TableColumn("Left size") { node in
                        Text(Self.fileSize(node.left?.byteCount))
                            .foregroundStyle(node.left == nil ? .tertiary : .secondary)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Right size") { node in
                        Text(Self.fileSize(node.right?.byteCount))
                            .foregroundStyle(node.right == nil ? .tertiary : .secondary)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Modified") { node in
                        Text(Self.modifiedSummary(node))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 130, ideal: 160)

                    TableColumn("Move match") { node in
                        if let counterpart = model.renameCounterpart(for: node) {
                            HStack(spacing: 5) {
                                Image(systemName: node.status == .leftOnly ? "arrow.right" : "arrow.left")
                                    .foregroundStyle(theme.inkMuted)
                                Text(counterpart)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .help(counterpart)
                        } else {
                            Text("—")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 140, ideal: 220)
                }
                .contextMenu(forSelectionType: PairNode.ID.self) { selectedPaths in
                    Button("Copy Left → Right") {
                        model.copySelection(.leftToRight, selectedPaths: selectedPaths)
                    }
                    .disabled(selectedPaths.isEmpty || model.isLoading || model.isApplyingSelection)

                    Button("Copy Right → Left") {
                        model.copySelection(.rightToLeft, selectedPaths: selectedPaths)
                    }
                    .disabled(selectedPaths.isEmpty || model.isLoading || model.isApplyingSelection)

                    Divider()

                    Button("Rename File on Left…") {
                        model.renameVisibleSelection(on: .left, selectedPaths: selectedPaths)
                    }
                    .disabled(!model.canRenameVisibleSelection(
                        on: .left,
                        selectedPaths: selectedPaths
                    ))

                    Button("Rename File on Right…") {
                        model.renameVisibleSelection(on: .right, selectedPaths: selectedPaths)
                    }
                    .disabled(!model.canRenameVisibleSelection(
                        on: .right,
                        selectedPaths: selectedPaths
                    ))

                    Divider()

                    Button("Move Within Right to Match Left…") {
                        model.moveVerifiedSelection(within: .right, selectedPaths: selectedPaths)
                    }
                    .disabled(!model.canMoveVerifiedSelection(
                        within: .right,
                        selectedPaths: selectedPaths
                    ))

                    Button("Move Within Left to Match Right…") {
                        model.moveVerifiedSelection(within: .left, selectedPaths: selectedPaths)
                    }
                    .disabled(!model.canMoveVerifiedSelection(
                        within: .left,
                        selectedPaths: selectedPaths
                    ))

                    Divider()

                    Button("Delete from Left…", role: .destructive) {
                        model.deleteSelection(from: .left, selectedPaths: selectedPaths)
                    }
                    .disabled(selectedPaths.isEmpty || model.isLoading || model.isApplyingSelection)

                    Button("Delete from Right…", role: .destructive) {
                        model.deleteSelection(from: .right, selectedPaths: selectedPaths)
                    }
                    .disabled(selectedPaths.isEmpty || model.isLoading || model.isApplyingSelection)
                }

                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(theme.surface(.three), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(theme.hairline, lineWidth: 1)
                        }
                }
            }

            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            FolderCountBadge(
                title: differentCountTitle,
                systemImage: RiffaIcon.notEqual,
                isEmphasized: true
            )
            FolderCountBadge(
                title: leftOnlyCountTitle,
                systemImage: "arrow.left"
            )
            FolderCountBadge(
                title: rightOnlyCountTitle,
                systemImage: "arrow.right"
            )
            if model.isDetectingRenames {
                ProgressView()
                    .controlSize(.small)
                Text("Checking moves…")
                    .foregroundStyle(.secondary)
            } else if let detection = model.renameDetectionResult {
                FolderCountBadge(
                    title: moveMatchCountTitle(detection.matches.count),
                    systemImage: "arrow.left.arrow.right"
                )
                FolderCountBadge(
                    title: ambiguousGroupCountTitle(
                        detection.ambiguousGroups.count
                    ),
                    systemImage: "questionmark.diamond"
                )
            }
            if let warning = model.renameDetectionWarning {
                Label("Move detection warning", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.warning)
                    .lineLimit(1)
                    .help(warning)
            }
            if !selection.isEmpty {
                Text(verbatim: selectedCountTitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let message = model.lastExecutionMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(message)
            }
            Text(verbatim: visibleItemCountTitle)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(theme.surface(.one))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
        }
    }

    private var differentCountTitle: String {
        String(
            localized: "\(model.nodes.count { $0.status == .different }) different",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private var leftOnlyCountTitle: String {
        String(
            localized: "\(model.nodes.count { $0.status == .leftOnly }) left only",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private var rightOnlyCountTitle: String {
        String(
            localized: "\(model.nodes.count { $0.status == .rightOnly }) right only",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func moveMatchCountTitle(_ count: Int) -> String {
        if count == 1 {
            return String(
                localized: "\(count) move match",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "\(count) move matches",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func ambiguousGroupCountTitle(_ count: Int) -> String {
        if count == 1 {
            return String(
                localized: "\(count) ambiguous group",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "\(count) ambiguous groups",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private var selectedCountTitle: String {
        if selection.count == 1 {
            return String(
                localized: "\(selection.count) selected item",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "\(selection.count) selected items",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private var visibleItemCountTitle: String {
        if model.nodes.count == 1 {
            return String(
                localized: "\(model.filteredNodes.count) of \(model.nodes.count) item",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "\(model.filteredNodes.count) of \(model.nodes.count) items",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Choose two folders", systemImage: "folder.badge.questionmark")
        } description: {
            Text("Riffa pairs relative paths and keeps symbolic links bounded by default.")
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

    private var selectionCopyControlsDisabled: Bool {
        selectionMutationControlsDisabled
    }

    private var selectionMutationControlsDisabled: Bool {
        selection.isEmpty ||
            model.leftURL == nil ||
            model.rightURL == nil ||
            model.isLoading ||
            model.isApplyingSelection
    }

    private var verifiedMoveControlsDisabled: Bool {
        !model.canMoveVerifiedSelection(within: .left, selectedPaths: selection)
            && !model.canMoveVerifiedSelection(within: .right, selectedPaths: selection)
    }

    private var explicitRenameControlsDisabled: Bool {
        !model.canRenameVisibleSelection(on: .left, selectedPaths: selection)
            && !model.canRenameVisibleSelection(on: .right, selectedPaths: selection)
    }

    private func symbol(for node: PairNode) -> String {
        let kind = node.left?.kind ?? node.right?.kind
        return switch kind {
        case .directory: "folder"
        case .symbolicLink: "link"
        case .file: "doc"
        case .inaccessible: "exclamationmark.triangle"
        case .other, nil: "questionmark.square.dashed"
        }
    }

    private static func fileSize(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return bytes.formatted(
            .byteCount(style: .file).locale(RiffaLocalization.locale)
        )
    }

    private static func modifiedSummary(_ node: PairNode) -> String {
        switch (node.left?.modificationDate, node.right?.modificationDate) {
        case let (left?, right?):
            if abs(left.timeIntervalSince(right)) <= 1 {
                return RiffaLocalization.string("Same time")
            }
            return left > right
                ? RiffaLocalization.string("Left newer")
                : RiffaLocalization.string("Right newer")
        case (.some, nil):
            return RiffaLocalization.string("Left only")
        case (nil, .some):
            return RiffaLocalization.string("Right only")
        case (nil, nil): return "—"
        }
    }
}

private struct FolderPathButton: View {
    let title: String
    let url: URL?
    let action: () -> Void

    var body: some View {
        RiffaResourcePathButton(
            title: title,
            url: url,
            emptyTitle: RiffaLocalization.string("Choose a folder…"),
            systemImage: "folder",
            accessibilityHint: RiffaLocalization.string("Choose a folder"),
            action: action
        )
        .accessibilityValue(
            url?.path(percentEncoded: false)
                ?? RiffaLocalization.string("No folder selected")
        )
    }
}

private struct StatusLabel: View {
    let status: PairNode.Status
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: symbol)
        }
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .accessibilityLabel(Text(verbatim: title))
    }

    private var title: String {
        switch status {
        case .same: RiffaLocalization.string("Same")
        case .different: RiffaLocalization.string("Different")
        case .leftOnly: RiffaLocalization.string("Left only")
        case .rightOnly: RiffaLocalization.string("Right only")
        case .typeMismatch: RiffaLocalization.string("Type mismatch")
        case .error: RiffaLocalization.string("Error")
        }
    }

    private var symbol: String {
        switch status {
        case .same: "checkmark"
        case .different: RiffaIcon.notEqual
        case .leftOnly: "arrow.left"
        case .rightOnly: "arrow.right"
        case .typeMismatch: "square.stack.3d.up.slash"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .same: theme.inkMuted
        case .different: theme.warning
        case .leftOnly, .rightOnly: theme.inkMuted
        case .typeMismatch, .error: theme.danger
        }
    }
}

private struct FolderCountBadge: View {
    let title: String
    let systemImage: String
    var isEmphasized = false
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: systemImage)
        }
            .foregroundStyle(isEmphasized ? theme.ink : theme.inkMuted)
            .accessibilityLabel(Text(verbatim: title))
    }
}

private struct FolderPathRulesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.riffaTheme) private var theme

    @State private var isEnabled: Bool
    @State private var isCaseSensitive: Bool
    @State private var includeText: String
    @State private var excludeText: String
    @State private var validationMessage: String?

    private let onApply: (FolderPathRules) -> Void

    init(
        rules: FolderPathRules,
        onApply: @escaping (FolderPathRules) -> Void
    ) {
        _isEnabled = State(initialValue: rules.isEnabled)
        _isCaseSensitive = State(initialValue: rules.isCaseSensitive)
        _includeText = State(initialValue: rules.includePatterns.joined(separator: "\n"))
        _excludeText = State(initialValue: rules.excludePatterns.joined(separator: "\n"))
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Folder Path Rules")
                        .font(.title2.weight(.semibold))
                    Text("Rules match complete slash-separated relative paths.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: $isEnabled)
                    .toggleStyle(.switch)
            }

            HStack(spacing: 12) {
                Label("\(includePatterns.count) include", systemImage: "checkmark.circle")
                Label("\(excludePatterns.count) exclude", systemImage: "nosign")
                Spacer()
                Toggle("Case-sensitive", isOn: $isCaseSensitive)
                    .toggleStyle(.checkbox)
                Button("Clear All") {
                    includeText = ""
                    excludeText = ""
                    validationMessage = nil
                }
            }
            .font(.callout)

            HStack(alignment: .top, spacing: 14) {
                ruleEditor(
                    title: RiffaLocalization.string("Include patterns"),
                    detail: RiffaLocalization.string(
                        "One glob per line. Empty means include every path."
                    ),
                    text: $includeText
                )
                ruleEditor(
                    title: RiffaLocalization.string("Exclude patterns"),
                    detail: RiffaLocalization.string(
                        "One glob per line. Exclusions always win."
                    ),
                    text: $excludeText
                )
            }

            Text("* and ? do not cross /. ** may cross /. A backslash escapes the next character; an unfinished escape or blank rule line is rejected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Changes take effect only when you choose Apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.riffaSecondary)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.riffaPrimary)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 510)
        .background(theme.canvas)
    }

    private func ruleEditor(
        title: String,
        detail: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.headline)
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    theme.surface(.one),
                    in: RoundedRectangle(cornerRadius: RiffaRadius.md)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: RiffaRadius.md)
                        .stroke(theme.hairline, lineWidth: 1)
                }
                .frame(minHeight: 260)
        }
        .frame(maxWidth: .infinity)
    }

    private var includePatterns: [String] { patterns(from: includeText) }
    private var excludePatterns: [String] { patterns(from: excludeText) }

    private func patterns(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private func apply() {
        do {
            let rules = try FolderPathRules(
                isEnabled: isEnabled,
                includePatterns: includePatterns,
                excludePatterns: excludePatterns,
                isCaseSensitive: isCaseSensitive
            )
            validationMessage = nil
            onApply(rules)
            dismiss()
        } catch let error as PathFilterError {
            validationMessage = String(
                localized: "The path rules could not be validated. \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        } catch {
            validationMessage = RiffaLocalization.string(
                "The path rules could not be validated safely."
            )
        }
    }
}
