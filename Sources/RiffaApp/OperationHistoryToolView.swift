import AppKit
import Foundation
import RiffaCore
import SwiftUI

private struct OperationHistoryRecord: Identifiable {
    let journal: OperationJournal
    let location: OperationJournalStorageLocation

    var id: String {
        location.rawValue + ":" + journal.id.uuidString.lowercased()
    }

    var locationTitle: String {
        switch location {
        case .active:
            RiffaLocalization.string("Active")
        case .archive:
            RiffaLocalization.string("Archived")
        }
    }

    var locationSymbol: String {
        switch location {
        case .active: "tray.full"
        case .archive: "archivebox"
        }
    }

    var canArchive: Bool {
        switch location {
        case .active: journal.status.isFinished
        case .archive: false
        }
    }
}

private struct OperationHistoryFinalizationRequest {
    let journalID: UUID
    let plan: OperationJournalRecoveryPlan
}

@MainActor
private final class OperationHistoryToolModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case unfinished = "Unfinished"
        case finished = "Finished"

        var id: Self { self }
    }

    @Published private(set) var records: [OperationHistoryRecord] = []
    @Published private(set) var recoveryPlans: [UUID: OperationJournalRecoveryPlan] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage = RiffaLocalization.string(
        "No operation journal scan has run yet."
    )
    @Published var selection: OperationHistoryRecord.ID?
    @Published var filter: Filter = .all
    @Published var search = ""
    @Published var errorMessage: String?
    @Published private(set) var pendingFinalization: OperationHistoryFinalizationRequest?

    private let store: OperationJournalStore

    init() {
        store = OperationJournalStore(
            directoryURL: JournaledLocalFolderSyncExecutor.defaultApplicationJournalDirectoryURL
        )
    }

    var visibleRecords: [OperationHistoryRecord] {
        records.filter { record in
            let journal = record.journal
            let filterMatches = switch filter {
            case .all: true
            case .unfinished: !journal.status.isFinished
            case .finished: journal.status.isFinished
            }
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchMatches = query.isEmpty
                || journal.id.uuidString.localizedCaseInsensitiveContains(query)
                || journal.kind.rawValue.localizedCaseInsensitiveContains(query)
                || journal.roots.contains {
                    $0.absolutePath.localizedCaseInsensitiveContains(query)
                }
                || journal.steps.contains {
                    $0.relativePath.localizedCaseInsensitiveContains(query)
                        || ($0.sourceRelativePath?.localizedCaseInsensitiveContains(query) ?? false)
                }
            return filterMatches && searchMatches
        }
    }

    var selectedRecord: OperationHistoryRecord? {
        guard let selection else { return nil }
        return visibleRecords.first { $0.id == selection }
    }

    var selectedRecoveryPlan: OperationJournalRecoveryPlan? {
        guard let selectedRecord else { return nil }
        return recoveryPlans[selectedRecord.journal.id]
    }

    var unfinishedCount: Int {
        records.count { !$0.journal.status.isFinished }
    }

    var canArchiveSelection: Bool {
        selectedRecord?.canArchive == true
    }

    var isFinalizationConfirmationPresented: Bool {
        pendingFinalization != nil
    }

    var finalizationConfirmationTitle: String {
        switch pendingFinalization?.plan.disposition {
        case .canFinalizeCompleted:
            RiffaLocalization.string("Finalize this log as completed?")
        case .canFinalizeRolledBack:
            RiffaLocalization.string("Finalize this log as rolled back?")
        case .requiresUserDecision, .inconsistentScene,
             .notAutomaticallyRecoverable, nil:
            RiffaLocalization.string("Finalize operation log?")
        }
    }

    var finalizationActionTitle: String {
        switch pendingFinalization?.plan.disposition {
        case .canFinalizeCompleted:
            RiffaLocalization.string("Finalize Log as Completed")
        case .canFinalizeRolledBack:
            RiffaLocalization.string("Finalize Log as Rolled Back")
        case .requiresUserDecision, .inconsistentScene,
             .notAutomaticallyRecoverable, nil:
            RiffaLocalization.string("Finalize Log")
        }
    }

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            do {
                let active = try await store.listActive()
                let archived = try await store.listArchived()
                let plans = try await OperationJournalRecoveryAnalyzer(
                    journalStore: store
                ).plansForUnfinishedJournals()
                recoveryPlans = Dictionary(uniqueKeysWithValues: plans.map {
                    ($0.journalID, $0)
                })
                records = sortedRecords(active: active, archived: archived)
                if let selection,
                   !records.contains(where: { $0.id == selection }) {
                    self.selection = nil
                }
                let unfinished = records.count { !$0.journal.status.isFinished }
                statusMessage = String(
                    localized: "Loaded \(active.count) active · \(archived.count) archived · \(unfinished) unfinished.",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            } catch {
                recoveryPlans = [:]
                let detail = String(describing: error)
                errorMessage = String(
                    localized: "Could not scan operation journals: \(detail)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                statusMessage = RiffaLocalization.string(
                    "Journal scan failed closed."
                )
            }
            isLoading = false
        }
    }

    func archiveSelected() {
        guard !isLoading, let record = selectedRecord, record.canArchive else {
            return
        }
        let journal = record.journal
        isLoading = true
        Task {
            do {
                _ = try await store.archiveFinished(journal.id)
                let active = try await store.listActive()
                let archived = try await store.listArchived()
                let plans = try await OperationJournalRecoveryAnalyzer(
                    journalStore: store
                ).plansForUnfinishedJournals()
                recoveryPlans = Dictionary(uniqueKeysWithValues: plans.map {
                    ($0.journalID, $0)
                })
                records = sortedRecords(active: active, archived: archived)
                selection = OperationHistoryRecord(
                    journal: journal,
                    location: .archive
                ).id
                let journalID = journal.id.uuidString
                statusMessage = String(
                    localized: "Archived journal \(journalID); it remains available in history.",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            } catch {
                let detail = String(describing: error)
                errorMessage = String(
                    localized: "Could not archive journal: \(detail)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
            isLoading = false
        }
    }

    func requestFinalization() {
        guard !isLoading,
              let record = selectedRecord,
              record.location == .active,
              !record.journal.status.isFinished,
              let plan = selectedRecoveryPlan,
              plan.journalID == record.journal.id,
              plan.disposition == .canFinalizeCompleted
                || plan.disposition == .canFinalizeRolledBack else {
            return
        }
        pendingFinalization = OperationHistoryFinalizationRequest(
            journalID: record.journal.id,
            plan: plan
        )
    }

    func cancelFinalization() {
        pendingFinalization = nil
    }

    func confirmFinalization() {
        guard !isLoading, let request = pendingFinalization else { return }
        pendingFinalization = nil
        isLoading = true
        Task {
            do {
                let finalized = try await OperationJournalRecoveryFinalizer(
                    journalStore: store
                ).finalize(
                    journalID: request.journalID,
                    using: request.plan
                )
                let active = try await store.listActive()
                let archived = try await store.listArchived()
                let plans = try await OperationJournalRecoveryAnalyzer(
                    journalStore: store
                ).plansForUnfinishedJournals()
                recoveryPlans = Dictionary(uniqueKeysWithValues: plans.map {
                    ($0.journalID, $0)
                })
                records = sortedRecords(active: active, archived: archived)
                selection = OperationHistoryRecord(
                    journal: finalized,
                    location: .active
                ).id
                let status = RiffaLocalization.string(finalized.status.rawValue)
                statusMessage = String(
                    localized: "Finalized journal metadata as \(status). No files were changed.",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            } catch {
                let detail = String(describing: error)
                errorMessage = String(
                    localized: "Could not finalize journal metadata: \(detail)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                statusMessage = RiffaLocalization.string(
                    "Finalization refused; refresh and inspect the current evidence."
                )
            }
            isLoading = false
        }
    }

    private func sortedRecords(
        active: [OperationJournal],
        archived: [OperationJournal]
    ) -> [OperationHistoryRecord] {
        let records = active.map {
            OperationHistoryRecord(journal: $0, location: .active)
        } + archived.map {
            OperationHistoryRecord(journal: $0, location: .archive)
        }
        return records.sorted { left, right in
            if left.journal.createdAt != right.journal.createdAt {
                return left.journal.createdAt < right.journal.createdAt
            }
            if left.journal.id != right.journal.id {
                return left.journal.id.uuidString < right.journal.id.uuidString
            }
            return left.location.rawValue < right.location.rawValue
        }
    }

    func revealJournalFolder() {
        let url = store.directoryURL
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = String(
                localized: "Could not reveal the journal directory: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

}

struct OperationHistoryToolView: View {
    @StateObject private var model = OperationHistoryToolModel()
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    model.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)

                Picker("Show", selection: $model.filter) {
                    ForEach(OperationHistoryToolModel.Filter.allCases) { filter in
                        Text(LocalizedStringKey(filter.rawValue)).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                RiffaSearchField(
                    "Filter ID, kind, or root path",
                    text: $model.search,
                    accessibilityName: "Operation history filter"
                )
                    .frame(minWidth: 180, maxWidth: 300)

                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.revealJournalFolder()
                } label: {
                    Label("Reveal Logs", systemImage: "folder")
                }
                Button {
                    model.archiveSelected()
                } label: {
                    Label("Archive Finished", systemImage: "archivebox")
                }
                .disabled(!model.canArchiveSelection || model.isLoading)
            }
            .padding(RiffaSpacing.sm)
            .background(theme.surface(.one))
            .overlay(alignment: .bottom) {
                RiffaHairline()
            }

            if model.records.isEmpty && !model.isLoading {
                ContentUnavailableView {
                    Label("No Operation Journals", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Journaled folder writes will appear here. Interrupted operations are inspected read-only and remain visible until explicitly resolved.")
                } actions: {
                    Button("Scan Again") { model.reload() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.canvas)
            } else {
                HSplitView {
                    Table(model.visibleRecords, selection: $model.selection) {
                        TableColumn("Status") { record in
                            OperationJournalStatusLabel(status: record.journal.status)
                        }
                        .width(min: 100, ideal: 120, max: 145)
                        TableColumn("Stored") { record in
                            Label {
                                Text(verbatim: record.locationTitle)
                            } icon: {
                                Image(systemName: record.locationSymbol)
                            }
                                .foregroundStyle(record.location == .archive ? .secondary : .primary)
                        }
                        .width(min: 90, ideal: 105, max: 125)
                        TableColumn("Kind") { record in
                            Text(
                                verbatim: RiffaLocalization.string(
                                    record.journal.kind.rawValue.capitalized
                                )
                            )
                        }
                        .width(min: 70, ideal: 80, max: 95)
                        TableColumn("Recovery") { record in
                            if record.journal.status.isFinished {
                                Text("—").foregroundStyle(.tertiary)
                            } else if let plan = model.recoveryPlans[record.journal.id] {
                                OperationRecoveryDispositionLabel(disposition: plan.disposition)
                            } else {
                                Label("Unavailable", systemImage: "questionmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 130, ideal: 165, max: 210)
                        TableColumn("Updated") { record in
                            Text(record.journal.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        .width(min: 125, ideal: 145, max: 175)
                        TableColumn("ID") { record in
                            Text(String(record.journal.id.uuidString.prefix(8)))
                                .font(.system(.body, design: .monospaced))
                        }
                        .width(min: 80, ideal: 90, max: 110)
                    }
                    .scrollContentBackground(.hidden)
                    .background(theme.canvas)
                    .frame(minWidth: 610)

                    if let record = model.selectedRecord {
                        OperationJournalDetailView(
                            journal: record.journal,
                            location: record.location,
                            recoveryPlan: model.selectedRecoveryPlan,
                            onRequestFinalization: model.requestFinalization
                        )
                            .frame(minWidth: 360, idealWidth: 450)
                    } else {
                        ContentUnavailableView {
                            Label("Select an Operation", systemImage: "list.bullet.rectangle")
                        } description: {
                            Text("Inspect its roots, recovery status, and recorded steps.")
                        }
                        .frame(minWidth: 340)
                        .frame(maxHeight: .infinity)
                        .background(theme.canvas)
                    }
                }
                .background(theme.canvas)
            }

            HStack(spacing: 12) {
                if model.unfinishedCount > 0 {
                    Label {
                        Text(
                            verbatim: unfinishedOperationDescription(
                                model.unfinishedCount
                            )
                        )
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(theme.warning)
                } else {
                    Label("No unfinished operations", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.statusMessage)
                    .foregroundStyle(theme.inkSubtle)
                    .lineLimit(1)
            }
            .riffaText(.caption)
            .padding(.horizontal, RiffaSpacing.sm)
            .frame(minHeight: 34)
            .background(theme.surface(.one))
            .overlay(alignment: .top) {
                RiffaHairline()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .task {
            model.reload()
        }
        .onChange(of: model.filter) { _, _ in
            model.selection = nil
        }
        .onChange(of: model.search) { _, _ in
            model.selection = nil
        }
        .alert(
            "Operation history error",
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
        .confirmationDialog(
            model.finalizationConfirmationTitle,
            isPresented: Binding(
                get: { model.isFinalizationConfirmationPresented },
                set: { if !$0 { model.cancelFinalization() } }
            ),
            titleVisibility: .visible
        ) {
            Button(model.finalizationActionTitle) {
                model.confirmFinalization()
            }
            Button("Cancel", role: .cancel) {
                model.cancelFinalization()
            }
        } message: {
            Text("Riffa will reload the active journal, verify its status and revision, and inspect every recorded path again. If all evidence is unchanged, it will update only the journal metadata. It will not copy, move, delete, restore, or modify any file. Archiving remains a separate action.")
        }
    }
}

private func unfinishedOperationDescription(_ count: Int) -> String {
    if count == 1 {
        return RiffaLocalization.string("1 operation needs inspection")
    }
    return String(
        localized: "\(count) operations need inspection",
        bundle: RiffaLocalization.localizedBundle,
        locale: RiffaLocalization.locale
    )
}

private struct OperationJournalDetailView: View {
    let journal: OperationJournal
    let location: OperationJournalStorageLocation
    let recoveryPlan: OperationJournalRecoveryPlan?
    let onRequestFinalization: () -> Void
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            verbatim: String(
                                localized: "\(RiffaLocalization.string(journal.kind.rawValue.capitalized)) Operation",
                                bundle: RiffaLocalization.localizedBundle,
                                locale: RiffaLocalization.locale
                            )
                        )
                            .font(.title3.weight(.semibold))
                        Text(journal.id.uuidString)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        OperationJournalStatusLabel(status: journal.status)
                        Label {
                            Text(
                                verbatim: RiffaLocalization.string(
                                    location == .active
                                        ? "Active log"
                                        : "Archived log"
                                )
                            )
                        } icon: {
                            Image(
                                systemName: location == .active
                                    ? "tray.full"
                                    : "archivebox"
                            )
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if !journal.status.isFinished {
                    Label {
                        Text("Riffa found a non-terminal record. No automatic rollback is attempted from this viewer; inspect the roots and backup before changing files.")
                    } icon: {
                        Image(systemName: "exclamationmark.shield")
                    }
                    .foregroundStyle(theme.warning)
                    .padding(RiffaSpacing.sm)
                    .background(
                        theme.surface(.two),
                        in: RoundedRectangle(cornerRadius: RiffaRadius.md)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: RiffaRadius.md)
                            .strokeBorder(theme.hairlineStrong, lineWidth: 1)
                    }
                }

                if let recoveryPlan {
                    OperationRecoveryAssessmentView(
                        plan: recoveryPlan,
                        canFinalizeMetadata: location == .active,
                        onRequestFinalization: onRequestFinalization
                    )
                }

                GroupBox("Timeline") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Created").foregroundStyle(.secondary)
                            Text(journal.createdAt.formatted(date: .abbreviated, time: .standard))
                        }
                        GridRow {
                            Text("Updated").foregroundStyle(.secondary)
                            Text(journal.updatedAt.formatted(date: .abbreviated, time: .standard))
                        }
                        GridRow {
                            Text("Revision").foregroundStyle(.secondary)
                            Text("\(journal.revision)")
                        }
                        if let failure = journal.failure {
                            GridRow {
                                Text("Failure").foregroundStyle(.secondary)
                                Text(
                                    verbatim: RiffaLocalization.string(
                                        failure.code.rawValue
                                    )
                                )
                                    .foregroundStyle(theme.danger)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("Roots") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(journal.roots, id: \.role) { root in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(
                                    verbatim: RiffaLocalization.string(
                                        root.role.rawValue.uppercased()
                                    )
                                )
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 64, alignment: .leading)
                                Text(root.absolutePath)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("Steps (\(journal.steps.count))") {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(journal.steps.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26, alignment: .trailing)
                                Image(systemName: stepSymbol(step.status))
                                    .foregroundStyle(stepColor(step.status))
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stepTitle(step))
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    HStack(spacing: 8) {
                                        Text(
                                            verbatim: RiffaLocalization.string(
                                                step.status.rawValue
                                            )
                                        )
                                        Text(verbatim: stepRoute(step))
                                        if let failure = step.failure {
                                            Text(
                                                verbatim: RiffaLocalization.string(
                                                    failure.code.rawValue
                                                )
                                            )
                                                .foregroundStyle(theme.danger)
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    if step.actionKind == .move {
                                        Text(moveStateSummary(step))
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            if index + 1 < journal.steps.count {
                                RiffaHairline()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
            }
            .padding(RiffaSpacing.md)
        }
        .groupBoxStyle(OperationHistoryGroupBoxStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
    }

    private func stepSymbol(_ status: OperationJournalStepStatus) -> String {
        switch status {
        case .pending: "circle"
        case .executing: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .rolledBack: "arrow.uturn.backward.circle.fill"
        }
    }

    private func stepTitle(_ step: OperationJournalStep) -> String {
        let action = RiffaLocalization.string(step.actionKind.rawValue)
        if step.actionKind == .move, let source = step.sourceRelativePath {
            return "\(action) · \(source) → \(step.relativePath)"
        }
        return "\(action) · \(step.relativePath)"
    }

    private func stepRoute(_ step: OperationJournalStep) -> String {
        let role = RiffaLocalization.string(step.targetRootRole.rawValue.uppercased())
        if step.actionKind == .move {
            return String(
                localized: "within \(role)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return "→ \(role)"
    }

    private func moveStateSummary(_ step: OperationJournalStep) -> String {
        let sourceBefore = stateSummary(step.sourceBeforeState)
        let sourceAfter = stateSummary(step.sourceAfterState)
        let targetBefore = stateSummary(step.beforeState)
        let targetAfter = stateSummary(step.afterState)
        return String(
            localized: "source \(sourceBefore) → \(sourceAfter) · target \(targetBefore) → \(targetAfter)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func stateSummary(_ state: OperationJournalItemState?) -> String {
        guard let state else {
            return RiffaLocalization.string("unobserved")
        }
        let kind = RiffaLocalization.string(state.kind.rawValue)
        if let byteCount = state.byteCount {
            return "\(kind)(\(byteCount) B)"
        }
        return kind
    }

    private func stepColor(_ status: OperationJournalStepStatus) -> Color {
        switch status {
        case .pending: theme.inkSubtle
        case .executing: theme.accent
        case .completed: theme.success
        case .failed: theme.danger
        case .rolledBack: theme.warning
        }
    }
}

private struct OperationRecoveryAssessmentView: View {
    let plan: OperationJournalRecoveryPlan
    let canFinalizeMetadata: Bool
    let onRequestFinalization: () -> Void
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        GroupBox("Read-only Recovery Assessment") {
            VStack(alignment: .leading, spacing: 10) {
                OperationRecoveryDispositionLabel(disposition: plan.disposition)
                Text(verbatim: dispositionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if canFinalizeMetadata && isSafelyFinalizable {
                    RiffaHairline()
                    Text("This does not resume or roll back the operation. It only marks the active log terminal after the same evidence is checked again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: onRequestFinalization) {
                        Label {
                            Text(verbatim: finalizationButtonTitle)
                        } icon: {
                            Image(systemName: "checkmark.shield")
                        }
                    }
                    .help("A second confirmation explains the metadata-only boundary before anything is recorded.")
                }

                RiffaHairline()

                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(plan.steps.enumerated()), id: \.element.stepID) { index, step in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(
                                    "\(index + 1). "
                                        + RiffaLocalization.string(
                                            step.actionKind.rawValue
                                        )
                                )
                                    .font(.caption.weight(.semibold))
                                Text(
                                    verbatim: stepClassificationTitle(
                                        step.classification
                                    )
                                )
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(stepClassificationColor(step.classification))
                                Spacer()
                            }
                            Text(
                                verbatim: recoveryReasonDescription(step.reason)
                            )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            recoveryObservation("Target", step.target)
                            if let source = step.source {
                                recoveryObservation("Source", source)
                            }
                            if let backup = step.backup {
                                recoveryObservation("Backup", backup)
                            }
                        }
                        .padding(.vertical, 2)
                        if index + 1 < plan.steps.count {
                            RiffaHairline()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var isSafelyFinalizable: Bool {
        plan.disposition == .canFinalizeCompleted
            || plan.disposition == .canFinalizeRolledBack
    }

    private var finalizationButtonTitle: String {
        switch plan.disposition {
        case .canFinalizeCompleted:
            RiffaLocalization.string("Finalize Log as Completed…")
        case .canFinalizeRolledBack:
            RiffaLocalization.string("Finalize Log as Rolled Back…")
        case .requiresUserDecision, .inconsistentScene, .notAutomaticallyRecoverable:
            RiffaLocalization.string("Finalization Unavailable")
        }
    }

    private var dispositionDetail: String {
        switch plan.disposition {
        case .canFinalizeCompleted:
            RiffaLocalization.string(
                "Every step's current scene matches a safely completed outcome. This is a journal-metadata recommendation only; the analyzer made no file-system changes."
            )
        case .canFinalizeRolledBack:
            RiffaLocalization.string(
                "Every step appears never executed or already rolled back. This is a journal-metadata recommendation only; the analyzer made no file-system changes."
            )
        case .requiresUserDecision:
            RiffaLocalization.string(
                "The paths were observed safely, but persisted evidence cannot prove one transaction-wide outcome. Inspect the listed paths and backup before deciding."
            )
        case .inconsistentScene:
            RiffaLocalization.string(
                "At least one current path directly contradicts the journal. Do not retry or alter the backup until the scene has been inspected."
            )
        case .notAutomaticallyRecoverable:
            RiffaLocalization.string(
                "At least one root or path could not be observed with no-follow descriptor safety. Riffa refuses to infer an outcome."
            )
        }
    }

    private func recoveryObservation(
        _ label: String,
        _ observation: OperationJournalRecoveryItemObservation
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: RiffaLocalization.string(label))
                + Text(verbatim: ":")
                .foregroundStyle(.secondary)
            Text(
                verbatim: "\(RiffaLocalization.string(observation.rootRole.rawValue.uppercased())):"
                    + observation.relativePath
            )
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("· \(observationResultDescription(observation.result))")
                .foregroundStyle(
                    observation.result.state == nil ? theme.danger : theme.inkSubtle
                )
        }
        .font(.caption2)
        .textSelection(.enabled)
    }

    private func observationResultDescription(
        _ result: OperationJournalRecoveryObservationResult
    ) -> String {
        switch result {
        case let .observed(state):
            let kind = RiffaLocalization.string(state.kind.rawValue)
            if let byteCount = state.byteCount {
                return "\(kind), \(byteCount) B"
            }
            return kind
        case let .unavailable(failure):
            let unavailable = RiffaLocalization.string("unavailable")
            let reason = RiffaLocalization.string(failure.rawValue)
            return "\(unavailable) (\(reason))"
        }
    }

    private func stepClassificationTitle(
        _ classification: OperationJournalRecoveryStepClassification
    ) -> String {
        switch classification {
        case .safelyCompleted:
            RiffaLocalization.string("completed scene")
        case .safelyRolledBack:
            RiffaLocalization.string("rolled-back scene")
        case .requiresUserDecision:
            RiffaLocalization.string("review required")
        case .inconsistentScene:
            RiffaLocalization.string("inconsistent")
        case .notAutomaticallyRecoverable:
            RiffaLocalization.string("not observable")
        }
    }

    private func stepClassificationColor(
        _ classification: OperationJournalRecoveryStepClassification
    ) -> Color {
        switch classification {
        case .safelyCompleted: theme.success
        case .safelyRolledBack: theme.warning
        case .requiresUserDecision: theme.warning
        case .inconsistentScene, .notAutomaticallyRecoverable: theme.danger
        }
    }

    private func recoveryReasonDescription(_ reason: OperationJournalRecoveryReason) -> String {
        switch reason {
        case .recordedCompletedStateMatches:
            RiffaLocalization.string(
                "The current item matches the step's persisted completed state."
            )
        case .recordedRolledBackStateMatches:
            RiffaLocalization.string(
                "The current item matches the step's persisted rolled-back state."
            )
        case .preparationNeverExecuted:
            RiffaLocalization.string(
                "The journal remained in preparation and the pre-operation state is still present."
            )
        case .movePresentAtDestination:
            RiffaLocalization.string(
                "The verified move item is absent at its source and present at its destination."
            )
        case .movePresentAtSource:
            RiffaLocalization.string(
                "The verified move item is still present at its source and absent at its destination."
            )
        case .preMutationAbsencePresent:
            RiffaLocalization.string(
                "The target that was absent before the step remains absent."
            )
        case .destructivePostconditionPresent:
            RiffaLocalization.string(
                "The recorded destructive postcondition is present."
            )
        case .creationPostconditionPresent:
            RiffaLocalization.string(
                "The recorded creation postcondition is present."
            )
        case .insufficientPersistedEvidence:
            RiffaLocalization.string(
                "Schema 2 does not contain enough content identity to prove this outcome."
            )
        case .ambiguousNoOp:
            RiffaLocalization.string(
                "The current scene could represent either no execution or a completed no-op."
            )
        case .failedStepRequiresReview:
            RiffaLocalization.string(
                "The step recorded failure and requires human review."
            )
        case .caseOnlyRenameInterruptedAtTemporaryName:
            RiffaLocalization.string(
                "A case-only rename may have stopped at its hidden same-directory intermediate name. Neither public name is changed automatically; inspect the parent folder before retrying."
            )
        case .recordedStateMismatch:
            RiffaLocalization.string(
                "The current item does not match the state persisted by the journal."
            )
        case .moveSceneConflict:
            RiffaLocalization.string(
                "The move's source and destination form a conflicting scene."
            )
        case .observationUnavailable:
            RiffaLocalization.string(
                "Descriptor-safe observation could not be completed."
            )
        }
    }
}

private struct OperationHistoryGroupBoxStyle: GroupBoxStyle {
    @Environment(\.riffaTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: RiffaSpacing.sm) {
            configuration.label
                .riffaText(.eyebrow)
                .foregroundStyle(theme.inkMuted)

            configuration.content
        }
        .padding(RiffaSpacing.md)
        .background(
            theme.surface(.one),
            in: RoundedRectangle(cornerRadius: RiffaRadius.lg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RiffaRadius.lg)
                .strokeBorder(theme.hairline, lineWidth: 1)
        }
    }
}

private struct OperationRecoveryDispositionLabel: View {
    let disposition: OperationJournalRecoveryDisposition
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: symbol)
        }
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }

    private var title: String {
        switch disposition {
        case .canFinalizeCompleted:
            RiffaLocalization.string("Matches completed")
        case .canFinalizeRolledBack:
            RiffaLocalization.string("Matches rolled back")
        case .requiresUserDecision:
            RiffaLocalization.string("Review required")
        case .inconsistentScene:
            RiffaLocalization.string("Inconsistent scene")
        case .notAutomaticallyRecoverable:
            RiffaLocalization.string("Unsafe to infer")
        }
    }

    private var symbol: String {
        switch disposition {
        case .canFinalizeCompleted: "checkmark.shield.fill"
        case .canFinalizeRolledBack: "arrow.uturn.backward.circle.fill"
        case .requiresUserDecision: "person.crop.circle.badge.questionmark"
        case .inconsistentScene: "exclamationmark.octagon.fill"
        case .notAutomaticallyRecoverable: "lock.trianglebadge.exclamationmark"
        }
    }

    private var color: Color {
        switch disposition {
        case .canFinalizeCompleted: theme.success
        case .canFinalizeRolledBack: theme.warning
        case .requiresUserDecision: theme.warning
        case .inconsistentScene, .notAutomaticallyRecoverable: theme.danger
        }
    }
}

private struct OperationJournalStatusLabel: View {
    let status: OperationJournalStatus
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: symbol)
        }
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }

    private var title: String {
        switch status {
        case .preparing:
            RiffaLocalization.string("Preparing")
        case .executing:
            RiffaLocalization.string("Executing")
        case .rollingBack:
            RiffaLocalization.string("Rolling back")
        case .completed:
            RiffaLocalization.string("Completed")
        case .rolledBack:
            RiffaLocalization.string("Rolled back")
        case .failed:
            RiffaLocalization.string("Failed")
        }
    }

    private var symbol: String {
        switch status {
        case .preparing: "clock"
        case .executing: "arrow.triangle.2.circlepath"
        case .rollingBack: "arrow.uturn.backward"
        case .completed: "checkmark.circle.fill"
        case .rolledBack: "arrow.uturn.backward.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch status {
        case .preparing: theme.inkSubtle
        case .executing: theme.accent
        case .rollingBack, .rolledBack: theme.warning
        case .completed: theme.success
        case .failed: theme.danger
        }
    }
}
