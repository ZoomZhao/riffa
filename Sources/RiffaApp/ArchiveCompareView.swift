import AppKit
import Foundation
import RiffaCore
import SwiftUI
import UniformTypeIdentifiers

/// Archive indexing, bounded member reads, hashing, and report generation stay
/// off the main actor. The worker returns only the engine's report-safe rows;
/// archive bytes and member bodies never enter SwiftUI state.
private actor ArchiveComparisonWorker {
    private let limits = ArchiveComparisonLimits.default

    func compare(
        leftURL: URL,
        rightURL: URL,
        options: ArchiveComparisonOptions
    ) throws -> ArchiveComparisonResult {
        let reader = BoundedLocalFileReader(
            limits: BoundedLocalFileReadLimits(
                maximumByteCount: limits.archiveLimits.maxArchiveByteCount
            )
        )

        try Task.checkCancellation()
        let leftData = try read(leftURL, side: .left, reader: reader)
        try Task.checkCancellation()
        let rightData = try read(rightURL, side: .right, reader: reader)
        try Task.checkCancellation()

        do {
            let result = try ArchiveComparisonEngine().compare(
                left: leftData,
                right: rightData,
                options: options
            )
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArchiveResourceError {
            // ArchiveResourceError paths are normalized member paths, never
            // the local archive URL.
            throw ArchiveComparisonFailure.archiveRejected(
                reason: error.localizedDescription
            )
        } catch let error as ArchiveComparisonError {
            throw ArchiveComparisonFailure.archiveRejected(
                reason: error.localizedDescription
            )
        } catch {
            throw ArchiveComparisonFailure.archiveRejected(
                reason: RiffaLocalization.string(
                    "The inputs could not be recognized as safe ZIP or TAR archives."
                )
            )
        }
    }

    func export(
        result: ArchiveComparisonResult,
        format: ComparisonReportFormat,
        leftLabel: String,
        rightLabel: String,
        destinationURL: URL
    ) throws {
        try Task.checkCancellation()
        let report: String
        do {
            report = try SpecializedComparisonReportGenerator().generate(
                archive: result,
                format: format,
                leftLabel: leftLabel,
                rightLabel: rightLabel
            )
        } catch {
            throw ArchiveComparisonFailure.reportGenerationFailed
        }

        try Task.checkCancellation()
        do {
            try Data(report.utf8).write(to: destinationURL, options: .atomic)
        } catch {
            throw ArchiveComparisonFailure.reportWriteFailed
        }
    }

    private func read(
        _ url: URL,
        side: ArchiveComparisonSide,
        reader: BoundedLocalFileReader
    ) throws -> Data {
        do {
            return try reader.read(url: url)
        } catch let error as BoundedLocalFileReadError {
            throw ArchiveComparisonFailure.readFailed(
                side: side,
                reason: error.localizedDescription
            )
        } catch {
            throw ArchiveComparisonFailure.readFailed(
                side: side,
                reason: RiffaLocalization.string(
                    "The bounded local read failed."
                )
            )
        }
    }
}

private let archiveComparisonWorker = ArchiveComparisonWorker()

private enum ArchiveComparisonSide: String, Sendable {
    case left
    case right
}

private enum ArchiveComparisonFailure: Error, LocalizedError, Sendable {
    case readFailed(side: ArchiveComparisonSide, reason: String)
    case archiveRejected(reason: String)
    case reportGenerationFailed
    case reportWriteFailed

    var errorDescription: String? {
        switch self {
        case let .readFailed(side, reason):
            switch side {
            case .left:
                String(
                    localized: "Could not read the left archive: \(reason)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            case .right:
                String(
                    localized: "Could not read the right archive: \(reason)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        case let .archiveRejected(reason):
            String(
                localized: "Archive comparison was rejected safely: \(reason)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .reportGenerationFailed:
            RiffaLocalization.string(
                "The archive comparison report could not be generated."
            )
        case .reportWriteFailed:
            RiffaLocalization.string(
                "The archive comparison report could not be written to the selected destination."
            )
        }
    }
}

@MainActor
private final class ArchiveCompareModel: ObservableObject {
    enum Side {
        case left
        case right
    }

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All statuses"
        case differences = "All differences"
        case same = "Same"
        case different = "Different"
        case leftOnly = "Left only"
        case rightOnly = "Right only"

        var id: Self { self }

        func includes(_ status: ArchiveComparisonStatus) -> Bool {
            switch self {
            case .all: true
            case .differences: status != .same
            case .same: status == .same
            case .different: status == .different
            case .leftOnly: status == .leftOnly
            case .rightOnly: status == .rightOnly
            }
        }
    }

    nonisolated static let maximumPublishedRowCount = 20_000

    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var result: ArchiveComparisonResult?
    @Published private(set) var isLoading = false
    @Published private(set) var isExporting = false
    @Published private(set) var compareContent = true
    @Published private(set) var compareModificationDate = false
    @Published private(set) var comparePermissions = false
    @Published private(set) var compareCompression = false
    @Published var searchText = ""
    @Published var statusFilter: StatusFilter = .all
    @Published var errorMessage: String?

    private var comparisonTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

    var visibleRows: [ArchiveComparisonListItem] {
        guard let result else { return [] }
        return matchingRows(in: result)
            .prefix(Self.maximumPublishedRowCount)
            .map(ArchiveComparisonListItem.init)
    }

    var visibleRowsAreTruncated: Bool {
        guard let result else { return false }
        return matchingRows(in: result)
            .dropFirst(Self.maximumPublishedRowCount)
            .first != nil
    }

    func chooseArchive(
        for side: Side,
        accessRegistry: SecurityScopedAccessRegistry
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        let types = ["zip", "tar"].compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        panel.title = side == .left
            ? RiffaLocalization.string("Choose Left Archive")
            : RiffaLocalization.string("Choose Right Archive")
        panel.prompt = RiffaLocalization.string("Choose")
        panel.message = RiffaLocalization.string(
            "Choose a ZIP or TAR archive. Riffa validates its contents without extracting them."
        )
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        do {
            replaceInput(
                with: try accessRegistry.registerIncomingURL(selectedURL),
                for: side
            )
        } catch {
            errorMessage = RiffaLocalization.string(
                "macOS did not grant access to the selected archive."
            )
        }
    }

    func replaceInput(with url: URL, for side: Side) {
        setURL(url, for: side)
    }

    func openInitial(_ urls: [URL], options: [String: String] = [:]) {
        statusFilter = options["statusFilter"].flatMap(StatusFilter.init(rawValue:)) ?? .all
        compareContent = Self.booleanOption(options["compareContent"], default: true)
        compareModificationDate = Self.booleanOption(
            options["compareModificationDate"],
            default: false
        )
        comparePermissions = Self.booleanOption(options["comparePermissions"], default: false)
        compareCompression = Self.booleanOption(options["compareCompression"], default: false)
        leftURL = urls.first?.standardizedFileURL
        rightURL = urls.count > 1 ? urls[1].standardizedFileURL : nil
        compareIfReady()
    }

    func swapSides() {
        (leftURL, rightURL) = (rightURL, leftURL)
        compareIfReady()
    }

    func setCompareContent(_ value: Bool) {
        guard value != compareContent else { return }
        compareContent = value
        compareIfReady()
    }

    func setCompareModificationDate(_ value: Bool) {
        guard value != compareModificationDate else { return }
        compareModificationDate = value
        compareIfReady()
    }

    func setComparePermissions(_ value: Bool) {
        guard value != comparePermissions else { return }
        comparePermissions = value
        compareIfReady()
    }

    func setCompareCompression(_ value: Bool) {
        guard value != compareCompression else { return }
        compareCompression = value
        compareIfReady()
    }

    func saveReport(format: ComparisonReportFormat) {
        guard let result, !isLoading, !isExporting else { return }
        let fileExtension = switch format {
        case .plainText: "txt"
        case .html: "html"
        case .json: "json"
        }
        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string("Export Archive Comparison Report")
        panel.prompt = RiffaLocalization.string("Export")
        panel.nameFieldStringValue = "Riffa-Archive-Report.\(fileExtension)"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        exportTask?.cancel()
        isExporting = true
        errorMessage = nil
        let leftLabel = leftURL?.lastPathComponent
            ?? RiffaLocalization.string("Left")
        let rightLabel = rightURL?.lastPathComponent
            ?? RiffaLocalization.string("Right")
        exportTask = Task { [weak self] in
            do {
                try await archiveComparisonWorker.export(
                    result: result,
                    format: format,
                    leftLabel: leftLabel,
                    rightLabel: rightLabel,
                    destinationURL: destinationURL
                )
                try Task.checkCancellation()
                self?.isExporting = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isExporting = false
                self.errorMessage = (error as? ArchiveComparisonFailure)?.localizedDescription
                    ?? RiffaLocalization.string(
                        "The archive comparison report could not be exported."
                    )
            }
        }
    }

    private func setURL(_ url: URL, for side: Side) {
        switch side {
        case .left: leftURL = url.standardizedFileURL
        case .right: rightURL = url.standardizedFileURL
        }
        compareIfReady()
    }

    private func compareIfReady() {
        comparisonTask?.cancel()
        guard let leftURL, let rightURL else {
            result = nil
            isLoading = false
            return
        }

        let options: ArchiveComparisonOptions
        do {
            options = try ArchiveComparisonOptions(
                compareContent: compareContent,
                compareModificationDate: compareModificationDate,
                comparePermissions: comparePermissions,
                compareCompression: compareCompression
            )
        } catch {
            result = nil
            isLoading = false
            errorMessage = RiffaLocalization.string(
                "The archive comparison options are invalid."
            )
            return
        }

        result = nil
        isLoading = true
        errorMessage = nil
        comparisonTask = Task { [weak self] in
            do {
                let comparison = try await archiveComparisonWorker.compare(
                    leftURL: leftURL,
                    rightURL: rightURL,
                    options: options
                )
                try Task.checkCancellation()
                guard let self else { return }
                self.result = comparison
                self.isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.result = nil
                self.isLoading = false
                self.errorMessage = (error as? ArchiveComparisonFailure)?.localizedDescription
                    ?? RiffaLocalization.string(
                        "The archive comparison failed safely."
                    )
            }
        }
    }

    private func matchingRows(
        in result: ArchiveComparisonResult
    ) -> LazyFilterSequence<[ArchiveComparisonRow]> {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.rows.lazy.filter { row in
            guard self.statusFilter.includes(row.status) else { return false }
            guard !query.isEmpty else { return true }
            return row.path.localizedStandardContains(query)
                || row.status.rawValue.localizedStandardContains(query)
                || RiffaLocalization.string(row.status.rawValue)
                    .localizedStandardContains(query)
                || row.differenceFields.contains {
                    $0.rawValue.localizedStandardContains(query)
                        || RiffaLocalization.string($0.rawValue)
                            .localizedStandardContains(query)
                }
                || Self.entry(row.left, matches: query)
                || Self.entry(row.right, matches: query)
        }
    }

    private static func entry(
        _ entry: ArchiveComparisonEntrySummary?,
        matches query: String
    ) -> Bool {
        guard let entry else { return false }
        return entry.kind.rawValue.localizedStandardContains(query)
            || entry.compression.rawValue.localizedStandardContains(query)
            || (entry.contentSHA256?.localizedStandardContains(query) ?? false)
            || (entry.symbolicLinkDestination?.localizedStandardContains(query) ?? false)
    }

    private static func booleanOption(_ value: String?, default fallback: Bool) -> Bool {
        guard let value else { return fallback }
        return switch value.lowercased() {
        case "true", "1", "yes": true
        case "false", "0", "no": false
        default: fallback
        }
    }
}

private struct ArchiveComparisonListItem: Identifiable {
    let row: ArchiveComparisonRow
    var id: String { row.path }

    init(_ row: ArchiveComparisonRow) {
        self.row = row
    }
}

struct ArchiveCompareView: View {
    @EnvironmentObject private var accessRegistry: SecurityScopedAccessRegistry
    @Environment(\.riffaTheme) private var theme
    @StateObject private var model = ArchiveCompareModel()

    private let initialURLs: [URL]
    private let initialOptions: [String: String]

    init(initialURLs: [URL] = [], initialOptions: [String: String] = [:]) {
        self.initialURLs = initialURLs
        self.initialOptions = initialOptions
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            pathBar
            if model.isLoading {
                ProgressView("Validating and comparing bounded archives…")
                    .controlSize(.large)
                    .tint(theme.accent)
                    .foregroundStyle(theme.inkSubtle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = model.result {
                resultContent(result)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Archive Compare")
        .background(theme.canvas)
        .riffaWindowDropZones([
            RiffaDropZone(
                role: .left,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .left)
            },
            RiffaDropZone(
                role: .right,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .right)
            },
        ])
        .alert(
            "Archive comparison error",
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
        .task(id: ComparisonInitialLoad(urls: initialURLs, options: initialOptions)) {
            model.openInitial(initialURLs, options: initialOptions)
        }
    }

    private var header: some View {
        RiffaComparisonHeader(
            title: "Archive Compare",
            subtitle: "ZIP and TAR contents without extraction"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .archiveComparison,
                    urls: [model.leftURL, model.rightURL].compactMap { $0 },
                    options: [
                        "statusFilter": .string(model.statusFilter.rawValue),
                        "compareContent": .boolean(model.compareContent),
                        "compareModificationDate": .boolean(model.compareModificationDate),
                        "comparePermissions": .boolean(model.comparePermissions),
                        "compareCompression": .boolean(model.compareCompression),
                    ]
                ),
                errorMessage: $model.errorMessage
            )
            Menu {
                Button("HTML…") { model.saveReport(format: .html) }
                Button("Plain Text…") { model.saveReport(format: .plainText) }
                Button("JSON…") { model.saveReport(format: .json) }
            } label: {
                if model.isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .accessibilityLabel("Exporting archive report")
                } else {
                    Label("Export Report", systemImage: "square.and.arrow.up")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Export archive comparison report")
            .accessibilityHint("Choose HTML, plain text, or JSON")
            .help("Export a complete portable archive comparison report")
            .disabled(model.result == nil || model.isLoading || model.isExporting)
        }
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            ArchivePathButton(title: "Left archive", url: model.leftURL) {
                model.chooseArchive(for: .left, accessRegistry: accessRegistry)
            }
            .riffaResourceDropTarget(
                role: .left,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .left)
            }
            Button { model.swapSides() } label: {
                Label("Swap archives", systemImage: "arrow.left.arrow.right")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Swap archives")
            .accessibilityHint("Exchanges the left and right archives")
            .help("Swap archives")
            .disabled(model.leftURL == nil && model.rightURL == nil)
            ArchivePathButton(title: "Right archive", url: model.rightURL) {
                model.chooseArchive(for: .right, accessRegistry: accessRegistry)
            }
            .riffaResourceDropTarget(
                role: .right,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .right)
            }
        }
    }

    private func resultContent(_ result: ArchiveComparisonResult) -> some View {
        let rows = model.visibleRows
        return VStack(spacing: 0) {
            archiveSummary(result)
            RiffaHairline()
            optionBar
            filterBar(shownCount: rows.count)
            Table(rows) {
                TableColumn("Status") { item in
                    ArchiveStatusLabel(status: item.row.status)
                }
                .width(min: 88, ideal: 105, max: 125)
                TableColumn("Path") { item in
                    Text(item.row.path)
                        .riffaText(.mono)
                        .lineLimit(2)
                        .help(item.row.path)
                }
                .width(min: 220, ideal: 340)
                TableColumn("Kind") { item in
                    Text(archivePairText(item.row.left?.kind, item.row.right?.kind))
                        .foregroundStyle(theme.inkSubtle)
                }
                .width(min: 95, ideal: 120)
                TableColumn("Size") { item in
                    Text(archiveSizePair(item.row.left, item.row.right))
                        .font(.caption.monospacedDigit())
                }
                .width(min: 135, ideal: 165)
                TableColumn("Compression") { item in
                    Text(archivePairText(
                        item.row.left?.compression,
                        item.row.right?.compression
                    ))
                    .font(.caption)
                }
                .width(min: 100, ideal: 130)
                TableColumn("Digest") { item in
                    ArchiveDigestPair(left: item.row.left, right: item.row.right)
                }
                .width(min: 145, ideal: 185)
                TableColumn("Differences") { item in
                    if item.row.differenceFields.isEmpty {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(theme.inkTertiary)
                    } else {
                        Label(
                            archiveDifferenceText(item.row.differenceFields),
                            systemImage: RiffaIcon.notEqual
                        )
                        .font(.caption)
                        .foregroundStyle(theme.warning)
                        .lineLimit(2)
                        .help(archiveDifferenceText(item.row.differenceFields))
                    }
                }
                .width(min: 145, ideal: 210)
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            statusBar(result)
        }
    }

    private func archiveSummary(_ result: ArchiveComparisonResult) -> some View {
        let readByteCount = ByteCountFormatter.string(
            fromByteCount: Int64(result.statistics.readAndHashedByteCount),
            countStyle: .file
        )
        return HStack(spacing: 10) {
            ArchiveFormatSummary(side: "Left", format: result.leftFormat)
            ArchiveFormatSummary(side: "Right", format: result.rightFormat)
            RiffaPanel(level: .one, padding: RiffaSpacing.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Work", systemImage: "gauge.with.dots.needle.33percent")
                        .riffaText(.body)
                        .foregroundStyle(theme.ink)
                    Label(
                        "\(result.statistics.hashedFileCount.formatted()) files hashed",
                        systemImage: "number"
                    )
                    Label(
                        String(
                            localized: "\(readByteCount) read",
                            bundle: RiffaLocalization.localizedBundle,
                            locale: RiffaLocalization.locale
                        ),
                        systemImage: "arrow.down.doc"
                    )
                }
                .riffaText(.caption)
                .foregroundStyle(theme.inkSubtle)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
        .padding(RiffaSpacing.sm)
        .background(theme.canvas)
    }

    private var optionBar: some View {
        RiffaComparisonControlBar {
            Text("Compare")
                .riffaText(.caption)
                .foregroundStyle(theme.inkSubtle)
            Toggle("Content", isOn: Binding(
                get: { model.compareContent },
                set: { model.setCompareContent($0) }
            ))
            Toggle("Modified date", isOn: Binding(
                get: { model.compareModificationDate },
                set: { model.setCompareModificationDate($0) }
            ))
            Toggle("Permissions", isOn: Binding(
                get: { model.comparePermissions },
                set: { model.setComparePermissions($0) }
            ))
            Toggle("Compression", isOn: Binding(
                get: { model.compareCompression },
                set: { model.setCompareCompression($0) }
            ))
            Spacer()
            Text("Changing an option reruns the bounded comparison")
                .riffaText(.caption)
                .foregroundStyle(theme.inkTertiary)
        }
        .toggleStyle(.checkbox)
    }

    private func filterBar(shownCount: Int) -> some View {
        RiffaComparisonControlBar {
            RiffaSearchField(
                "Search paths, kinds, digests, and differences",
                text: $model.searchText,
                accessibilityName: "Archive comparison search"
            )
            Picker("Status", selection: $model.statusFilter) {
                ForEach(ArchiveCompareModel.StatusFilter.allCases) { filter in
                    Text(LocalizedStringKey(filter.rawValue)).tag(filter)
                }
            }
            .frame(width: 155)
            Spacer()
            Text("\(shownCount.formatted()) shown")
                .riffaText(.caption)
                .foregroundStyle(theme.inkSubtle)
        }
    }

    private func statusBar(_ result: ArchiveComparisonResult) -> some View {
        let statistics = result.statistics
        return RiffaStatusBar {
            RiffaStatusBadge(
                "\(statistics.sameCount) same",
                systemImage: "equal.circle"
            )
            RiffaStatusBadge(
                "\(statistics.differentCount) different",
                systemImage: RiffaIcon.notEqual,
                tone: .warning
            )
            RiffaStatusBadge(
                "\(statistics.leftOnlyCount) left only",
                systemImage: "arrow.left"
            )
            RiffaStatusBadge(
                "\(statistics.rightOnlyCount) right only",
                systemImage: "arrow.right"
            )
            Spacer()
            if model.visibleRowsAreTruncated {
                Label(
                    "On-screen rows capped at \(ArchiveCompareModel.maximumPublishedRowCount.formatted()); export remains complete",
                    systemImage: "info.circle"
                )
                .foregroundStyle(theme.warning)
            }
            Text("\(statistics.totalCount.formatted()) total")
                .foregroundStyle(theme.inkSubtle)
        }
    }

    private var emptyState: some View {
        RiffaEmptyState(
            title: "Choose two archives",
            description: "Compare validated ZIP and TAR members without extracting to disk or following links.",
            systemImage: SessionKind.archiveCompare.symbol
        ) {
            HStack {
                Button("Choose Left…") {
                    model.chooseArchive(for: .left, accessRegistry: accessRegistry)
                }
                .buttonStyle(
                    RiffaButtonStyle(model.leftURL == nil ? .primary : .secondary)
                )
                Button("Choose Right…") {
                    model.chooseArchive(for: .right, accessRegistry: accessRegistry)
                }
                .buttonStyle(
                    RiffaButtonStyle(
                        model.leftURL != nil && model.rightURL == nil
                            ? .primary
                            : .secondary
                    )
                )
            }
        }
    }
}

private struct ArchivePathButton: View {
    let title: String
    let url: URL?
    let action: () -> Void

    var body: some View {
        RiffaResourcePathButton(
            title: title,
            url: url,
            emptyTitle: "Choose a ZIP or TAR…",
            systemImage: "archivebox",
            accessibilityHint: "Choose an archive",
            action: action
        )
        .accessibilityValue(
            url?.path(percentEncoded: false)
                ?? RiffaLocalization.string("No archive selected")
        )
    }
}

private struct ArchiveFormatSummary: View {
    let side: String
    let format: ArchiveResourceFormat
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        RiffaPanel(level: .one, padding: RiffaSpacing.sm) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.inkMuted)
                    .frame(width: 38, height: 38)
                    .background(
                        theme.surface(.three),
                        in: RoundedRectangle(cornerRadius: RiffaRadius.md)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        verbatim: "\(RiffaLocalization.string(side)): "
                            + format.rawValue.uppercased()
                    )
                        .riffaText(.body)
                        .foregroundStyle(theme.ink)
                    Text("Detected from archive bytes")
                        .riffaText(.caption)
                        .foregroundStyle(theme.inkSubtle)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(RiffaLocalization.string(side)) "
                + RiffaLocalization.string("Archive")
                + ", \(format.rawValue.uppercased()), "
                + RiffaLocalization.string("Detected from archive bytes")
        )
    }
}

private struct ArchiveStatusLabel: View {
    let status: ArchiveComparisonStatus
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Label {
            Text(LocalizedStringKey(title))
        } icon: {
            Image(systemName: symbol)
        }
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }

    private var title: String {
        switch status {
        case .same: "Same"
        case .different: "Different"
        case .leftOnly: "Left only"
        case .rightOnly: "Right only"
        }
    }

    private var symbol: String {
        switch status {
        case .same: "equal.circle"
        case .different: RiffaIcon.notEqual
        case .leftOnly: "arrow.left.circle"
        case .rightOnly: "arrow.right.circle"
        }
    }

    private var color: Color {
        switch status {
        case .same: theme.inkSubtle
        case .different: theme.warning
        case .leftOnly, .rightOnly: theme.inkMuted
        }
    }
}

private struct ArchiveDigestPair: View {
    let left: ArchiveComparisonEntrySummary?
    let right: ArchiveComparisonEntrySummary?
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        let leftDigest = left?.contentSHA256
        let rightDigest = right?.contentSHA256
        if leftDigest == nil, rightDigest == nil {
            Text("Not hashed")
                .font(.caption)
                .foregroundStyle(theme.inkTertiary)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("L \(digestPreview(leftDigest))")
                Text("R \(digestPreview(rightDigest))")
            }
            .font(.caption2.monospaced())
            .foregroundStyle(theme.inkSubtle)
            .help(
                String(
                    localized: "Left: \(leftDigest ?? RiffaLocalization.string("not hashed"))\nRight: \(rightDigest ?? RiffaLocalization.string("not hashed"))",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            )
        }
    }
}

private func digestPreview(_ digest: String?) -> String {
    guard let digest else { return "—" }
    return "\(digest.prefix(12))…"
}

private func archiveSizePair(
    _ left: ArchiveComparisonEntrySummary?,
    _ right: ArchiveComparisonEntrySummary?
) -> String {
    let leftText = left.map { archiveByteCount($0.uncompressedByteCount) } ?? "—"
    let rightText = right.map { archiveByteCount($0.uncompressedByteCount) } ?? "—"
    return leftText == rightText ? leftText : "\(leftText) → \(rightText)"
}

private func archiveByteCount(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}

private func archivePairText<Value: RawRepresentable>(
    _ left: Value?,
    _ right: Value?
) -> String where Value.RawValue == String {
    let leftText = left.map { RiffaLocalization.string($0.rawValue) } ?? "—"
    let rightText = right.map { RiffaLocalization.string($0.rawValue) } ?? "—"
    return leftText == rightText ? leftText : "\(leftText) → \(rightText)"
}

private func archiveDifferenceText(
    _ fields: [ArchiveComparisonDifferenceField]
) -> String {
    fields.isEmpty
        ? "—"
        : fields.map { RiffaLocalization.string($0.rawValue) }.joined(separator: ", ")
}
