import AppKit
import Foundation
import RiffaCore
import SwiftUI
import UniformTypeIdentifiers

/// Office package parsing can be CPU intensive. Keeping reads, ZIP validation,
/// XML parsing, and report rendering on one actor prevents those operations
/// from blocking SwiftUI and ensures superseded comparisons are serialized.
private actor OfficeComparisonWorker {
    private let limits = OpenXMLComparisonLimits.default

    func compare(leftURL: URL, rightURL: URL) throws -> OpenXMLComparisonResult {
        let reader = BoundedLocalFileReader(
            limits: BoundedLocalFileReadLimits(
                maximumByteCount: limits.maxArchiveByteCount
            )
        )
        let engine = OpenXMLComparisonEngine(limits: limits)

        // Snapshot each side in its own scope so the first compressed `Data`
        // can be released before the second package is read.
        let left = try snapshot(
            url: leftURL,
            side: .left,
            reader: reader,
            engine: engine
        )
        let right = try snapshot(
            url: rightURL,
            side: .right,
            reader: reader,
            engine: engine
        )
        try Task.checkCancellation()
        return engine.compare(left: left, right: right)
    }

    func export(
        result: OpenXMLComparisonResult,
        format: ComparisonReportFormat,
        leftLabel: String,
        rightLabel: String,
        destinationURL: URL
    ) throws {
        try Task.checkCancellation()
        let report: String
        do {
            report = try SpecializedComparisonReportGenerator().generate(
                openXML: result,
                format: format,
                leftLabel: leftLabel,
                rightLabel: rightLabel
            )
        } catch {
            throw OfficeComparisonFailure.reportGenerationFailed
        }

        try Task.checkCancellation()
        do {
            try Data(report.utf8).write(to: destinationURL, options: .atomic)
        } catch {
            // Do not forward Foundation's write error because it may embed the
            // user's absolute destination path.
            throw OfficeComparisonFailure.reportWriteFailed
        }
    }

    private func snapshot(
        url: URL,
        side: OfficeComparisonSide,
        reader: BoundedLocalFileReader,
        engine: OpenXMLComparisonEngine
    ) throws -> OpenXMLDocumentSnapshot {
        try Task.checkCancellation()
        let data: Data
        do {
            data = try reader.read(url: url)
        } catch let error as BoundedLocalFileReadError {
            throw OfficeComparisonFailure.readFailed(
                side: side,
                reason: error.localizedDescription
            )
        } catch {
            throw OfficeComparisonFailure.readFailed(
                side: side,
                reason: RiffaLocalization.string(
                    "The bounded local read failed."
                )
            )
        }

        try Task.checkCancellation()
        do {
            let snapshot = try engine.snapshot(data: data)
            try Task.checkCancellation()
            return snapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenXMLComparisonError {
            // OpenXML errors contain only normalized paths inside the package;
            // local absolute paths are never included in this message.
            throw OfficeComparisonFailure.packageRejected(
                side: side,
                reason: error.localizedDescription
            )
        } catch {
            throw OfficeComparisonFailure.packageRejected(
                side: side,
                reason: RiffaLocalization.string(
                    "The package could not be recognized safely."
                )
            )
        }
    }
}

private let officeComparisonWorker = OfficeComparisonWorker()

private enum OfficeComparisonSide: String, Sendable {
    case left = "left"
    case right = "right"
}

private enum OfficeComparisonFailure: Error, LocalizedError, Sendable {
    case readFailed(side: OfficeComparisonSide, reason: String)
    case packageRejected(side: OfficeComparisonSide, reason: String)
    case reportGenerationFailed
    case reportWriteFailed

    var errorDescription: String? {
        switch self {
        case let .readFailed(side, reason):
            switch side {
            case .left:
                String(
                    localized: "Could not read the left Office document: \(reason)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            case .right:
                String(
                    localized: "Could not read the right Office document: \(reason)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        case let .packageRejected(side, reason):
            switch side {
            case .left:
                String(
                    localized: "The left Office package was rejected: \(reason)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            case .right:
                String(
                    localized: "The right Office package was rejected: \(reason)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        case .reportGenerationFailed:
            RiffaLocalization.string(
                "The Office comparison report could not be generated."
            )
        case .reportWriteFailed:
            RiffaLocalization.string(
                "The Office comparison report could not be written to the selected destination."
            )
        }
    }
}

@MainActor
private final class OfficeCompareModel: ObservableObject {
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

        func includes(_ status: OpenXMLComparisonStatus) -> Bool {
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

    enum ItemFilter: String, CaseIterable, Identifiable {
        case all = "All items"
        case documentType = "Document type"
        case coreProperty = "Properties"
        case logicalSection = "Sections"
        case packagePart = "Package parts"

        var id: Self { self }

        func includes(_ kind: OpenXMLComparisonItemKind) -> Bool {
            switch self {
            case .all: true
            case .documentType: kind == .documentType
            case .coreProperty: kind == .coreProperty
            case .logicalSection: kind == .logicalSection
            case .packagePart: kind == .packagePart
            }
        }
    }

    /// A Table with hundreds of thousands of SwiftUI cells is not useful and
    /// can exhaust window memory. The engine result and exported report remain
    /// complete; only the on-screen matching prefix is bounded.
    nonisolated static let maximumPublishedRowCount = 20_000

    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var result: OpenXMLComparisonResult?
    @Published private(set) var isLoading = false
    @Published private(set) var isExporting = false
    @Published var searchText = ""
    @Published var statusFilter: StatusFilter = .all
    @Published var itemFilter: ItemFilter = .all
    @Published var errorMessage: String?

    private var comparisonTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

    var visibleRows: [OfficeComparisonListItem] {
        guard let result else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.rows.lazy
            .filter { row in
                guard self.statusFilter.includes(row.status),
                      self.itemFilter.includes(row.itemKind)
                else { return false }
                guard !query.isEmpty else { return true }
                return row.key.localizedStandardContains(query)
                    || row.status.rawValue.localizedStandardContains(query)
                    || RiffaLocalization.string(row.status.rawValue)
                        .localizedStandardContains(query)
                    || row.itemKind.rawValue.localizedStandardContains(query)
                    || officeItemKindTitle(row.itemKind)
                        .localizedStandardContains(query)
                    || (row.left?.displayText?.localizedStandardContains(query) ?? false)
                    || (row.right?.displayText?.localizedStandardContains(query) ?? false)
            }
            .prefix(Self.maximumPublishedRowCount)
            .map(OfficeComparisonListItem.init)
    }

    var mayHaveTruncatedVisibleRows: Bool {
        (result?.rows.count ?? 0) > Self.maximumPublishedRowCount
    }

    func chooseDocument(
        for side: Side,
        accessRegistry: SecurityScopedAccessRegistry
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = ["docx", "xlsx", "pptx", "ods"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.title = side == .left
            ? RiffaLocalization.string("Choose Left Office Document")
            : RiffaLocalization.string("Choose Right Office Document")
        panel.prompt = RiffaLocalization.string("Choose")
        panel.message = RiffaLocalization.string(
            "Choose a DOCX, XLSX, PPTX, or ODS package. Its contents and format declarations will be validated before comparison."
        )
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        do {
            let registeredURL = try accessRegistry.registerIncomingURL(selectedURL)
            setURL(registeredURL, for: side)
        } catch {
            errorMessage = RiffaLocalization.string(
                "macOS did not grant access to the selected Office document."
            )
        }
    }

    func openInitial(_ urls: [URL], options: [String: String] = [:]) {
        if let value = options["statusFilter"].flatMap(StatusFilter.init(rawValue:)) {
            statusFilter = value
        }
        if let value = options["itemFilter"].flatMap(ItemFilter.init(rawValue:)) {
            itemFilter = value
        }

        leftURL = urls.first?.standardizedFileURL
        rightURL = urls.count > 1 ? urls[1].standardizedFileURL : nil
        compareIfReady()
    }

    func swapSides() {
        (leftURL, rightURL) = (rightURL, leftURL)
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
        panel.title = RiffaLocalization.string("Export Office Comparison Report")
        panel.prompt = RiffaLocalization.string("Export")
        panel.nameFieldStringValue = "Riffa-Office-Report.\(fileExtension)"
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
                try await officeComparisonWorker.export(
                    result: result,
                    format: format,
                    leftLabel: leftLabel,
                    rightLabel: rightLabel,
                    destinationURL: destinationURL
                )
                try Task.checkCancellation()
                guard let self else { return }
                self.isExporting = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isExporting = false
                self.errorMessage = (error as? OfficeComparisonFailure)?.localizedDescription
                    ?? RiffaLocalization.string(
                        "The Office comparison report could not be exported."
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

        result = nil
        isLoading = true
        errorMessage = nil
        comparisonTask = Task { [weak self] in
            do {
                let comparison = try await officeComparisonWorker.compare(
                    leftURL: leftURL,
                    rightURL: rightURL
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
                self.errorMessage = (error as? OfficeComparisonFailure)?.localizedDescription
                    ?? RiffaLocalization.string(
                        "The Office package comparison failed safely."
                    )
            }
        }
    }
}

private struct OfficeComparisonListItem: Identifiable {
    let row: OpenXMLComparisonRow
    var id: String { row.key }

    init(_ row: OpenXMLComparisonRow) {
        self.row = row
    }
}

private extension OpenXMLComparisonRow {
    var itemKind: OpenXMLComparisonItemKind {
        left?.itemKind ?? right?.itemKind ?? .packagePart
    }
}

struct OfficeCompareView: View {
    @EnvironmentObject private var accessRegistry: SecurityScopedAccessRegistry
    @Environment(\.riffaTheme) private var theme
    @StateObject private var model = OfficeCompareModel()

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
                ProgressView("Validating and comparing bounded Office packages…")
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
        .navigationTitle("Office Compare")
        .background(theme.canvas)
        .alert(
            "Office comparison error",
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
            title: "Office Compare",
            subtitle: "Document structure, properties, sections, and package parts"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .officeComparison,
                    urls: [model.leftURL, model.rightURL].compactMap { $0 },
                    options: [
                        "statusFilter": .string(model.statusFilter.rawValue),
                        "itemFilter": .string(model.itemFilter.rawValue)
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
                        .accessibilityLabel("Exporting Office report")
                } else {
                    Label("Export Report", systemImage: "square.and.arrow.up")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Export Office comparison report")
            .accessibilityHint("Choose HTML, plain text, or JSON")
            .help("Export a portable Office comparison report")
            .disabled(model.result == nil || model.isLoading || model.isExporting)
        }
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            OfficePathButton(
                title: "Left Office document",
                url: model.leftURL
            ) {
                model.chooseDocument(for: .left, accessRegistry: accessRegistry)
            }
            Button { model.swapSides() } label: {
                Label("Swap Office documents", systemImage: "arrow.left.arrow.right")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Swap Office documents")
            .accessibilityHint("Exchanges the left and right documents")
            .help("Swap Office documents")
            .disabled(model.leftURL == nil && model.rightURL == nil)
            OfficePathButton(
                title: "Right Office document",
                url: model.rightURL
            ) {
                model.chooseDocument(for: .right, accessRegistry: accessRegistry)
            }
        }
    }

    private func resultContent(_ result: OpenXMLComparisonResult) -> some View {
        let visibleRows = model.visibleRows
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                OfficePackageSummary(
                    side: "Left",
                    snapshot: result.left
                )
                OfficePackageSummary(
                    side: "Right",
                    snapshot: result.right
                )
            }
            .padding(RiffaSpacing.sm)
            .background(theme.canvas)
            RiffaHairline()
            filterBar(shownCount: visibleRows.count)
            Table(visibleRows) {
                TableColumn("Status") { item in
                    OfficeStatusLabel(status: item.row.status)
                }
                .width(min: 90, ideal: 105, max: 125)
                TableColumn("Key") { item in
                    Text(item.row.key)
                        .riffaText(.mono)
                        .lineLimit(2)
                        .help(item.row.key)
                }
                .width(min: 210, ideal: 310)
                TableColumn("Kind") { item in
                    Text(verbatim: officeItemKindTitle(item.row.itemKind))
                        .foregroundStyle(theme.inkSubtle)
                }
                .width(min: 105, ideal: 125, max: 150)
                TableColumn("Left") { item in
                    OfficeValueSummary(value: item.row.left)
                }
                .width(min: 235, ideal: 340)
                TableColumn("Right") { item in
                    OfficeValueSummary(value: item.row.right)
                }
                .width(min: 235, ideal: 340)
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            statusBar(result)
        }
    }

    private func filterBar(shownCount: Int) -> some View {
        RiffaComparisonControlBar {
            RiffaSearchField(
                "Search keys and bounded previews",
                text: $model.searchText,
                accessibilityName: "Office comparison search"
            )
            Picker("Status", selection: $model.statusFilter) {
                ForEach(OfficeCompareModel.StatusFilter.allCases) { filter in
                    Text(LocalizedStringKey(filter.rawValue)).tag(filter)
                }
            }
            .frame(width: 150)

            Picker("Item", selection: $model.itemFilter) {
                ForEach(OfficeCompareModel.ItemFilter.allCases) { filter in
                    Text(LocalizedStringKey(filter.rawValue)).tag(filter)
                }
            }
            .frame(width: 145)

            Spacer()
            Text("\(shownCount) shown")
                .riffaText(.caption)
                .foregroundStyle(theme.inkSubtle)
        }
    }

    private func statusBar(_ result: OpenXMLComparisonResult) -> some View {
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
            if model.mayHaveTruncatedVisibleRows {
                Label(
                    "On-screen rows capped at \(OfficeCompareModel.maximumPublishedRowCount.formatted()); export remains complete",
                    systemImage: "info.circle"
                )
                .foregroundStyle(theme.warning)
            }
            Text("\(statistics.totalCount) total")
                .foregroundStyle(theme.inkSubtle)
        }
    }

    private var emptyState: some View {
        RiffaEmptyState(
            title: "Choose two Office documents",
            description: "Compare validated DOCX, XLSX, PPTX, and ODS properties, logical sections, and bounded part digests.",
            systemImage: SessionKind.officeCompare.symbol
        ) {
            HStack {
                Button("Choose Left…") {
                    model.chooseDocument(for: .left, accessRegistry: accessRegistry)
                }
                .buttonStyle(
                    RiffaButtonStyle(model.leftURL == nil ? .primary : .secondary)
                )
                Button("Choose Right…") {
                    model.chooseDocument(for: .right, accessRegistry: accessRegistry)
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

private struct OfficePathButton: View {
    let title: String
    let url: URL?
    let action: () -> Void

    var body: some View {
        RiffaResourcePathButton(
            title: title,
            url: url,
            emptyTitle: "Choose a DOCX, XLSX, PPTX, or ODS…",
            systemImage: "doc.on.doc",
            accessibilityHint: "Choose an Office document",
            action: action
        )
        .accessibilityValue(
            url?.path(percentEncoded: false)
                ?? RiffaLocalization.string("No Office document selected")
        )
    }
}

private struct OfficePackageSummary: View {
    let side: String
    let snapshot: OpenXMLDocumentSnapshot
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        RiffaPanel(level: .one, padding: RiffaSpacing.sm) {
            HStack(spacing: 12) {
                Image(systemName: officeDocumentSymbol(snapshot.documentType))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.inkMuted)
                    .frame(width: 38, height: 38)
                    .background(
                        theme.surface(.three),
                        in: RoundedRectangle(cornerRadius: RiffaRadius.md)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        verbatim: "\(RiffaLocalization.string(side)): "
                            + officeDocumentTitle(snapshot.documentType)
                    )
                        .riffaText(.body)
                        .foregroundStyle(theme.ink)
                    HStack(spacing: 12) {
                        Label("\(snapshot.sections.count) sections", systemImage: "list.bullet.rectangle")
                        Label("\(snapshot.parts.count) parts", systemImage: "shippingbox")
                    }
                    .riffaText(.caption)
                    .foregroundStyle(theme.inkSubtle)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct OfficeStatusLabel: View {
    let status: OpenXMLComparisonStatus
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

private struct OfficeValueSummary: View {
    let value: OpenXMLComparisonValue?
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        if let value {
            VStack(alignment: .leading, spacing: 2) {
                if let preview = value.displayText, !preview.isEmpty {
                    Text(preview)
                        .lineLimit(2)
                        .help(preview)
                }
                Text(metadata(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.inkSubtle)
                Text("SHA-256 \(value.sha256.prefix(12))…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.inkTertiary)
            }
            .padding(.vertical, 2)
        } else {
            Text("—").foregroundStyle(theme.inkTertiary)
        }
    }

    private func metadata(_ value: OpenXMLComparisonValue) -> String {
        let itemCount = value.itemCount
        var pieces = [
            itemCount == 1
                ? RiffaLocalization.string("1 item")
                : String(
                    localized: "\(itemCount) items",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
        ]
        if let byteCount = value.byteCount {
            pieces.append(
                ByteCountFormatter.string(
                    fromByteCount: Int64(byteCount),
                    countStyle: .file
                )
            )
        }
        return pieces.joined(separator: " • ")
    }
}

private func officeItemKindTitle(_ kind: OpenXMLComparisonItemKind) -> String {
    let key = switch kind {
    case .documentType: "Document type"
    case .coreProperty: "Property"
    case .logicalSection: "Section"
    case .packagePart: "Package part"
    }
    return RiffaLocalization.string(key)
}

private func officeDocumentTitle(_ type: OpenXMLDocumentType) -> String {
    let key = switch type {
    case .wordProcessingDocument: "Word document (DOCX)"
    case .spreadsheet: "Excel workbook (XLSX)"
    case .presentation: "PowerPoint presentation (PPTX)"
    case .openDocumentSpreadsheet: "OpenDocument spreadsheet (ODS)"
    }
    return RiffaLocalization.string(key)
}

private func officeDocumentSymbol(_ type: OpenXMLDocumentType) -> String {
    switch type {
    case .wordProcessingDocument: "doc.text"
    case .spreadsheet: "tablecells"
    case .presentation: "rectangle.on.rectangle"
    case .openDocumentSpreadsheet: "tablecells"
    }
}
