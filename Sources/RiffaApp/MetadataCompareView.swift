import AppKit
import Foundation
import RiffaCore
import SwiftUI

private actor LocalMetadataComparisonWorker {
    func compare(
        leftURL: URL,
        rightURL: URL,
        ignoreModificationTime: Bool
    ) throws -> LocalMetadataComparisonResult {
        try LocalMetadataComparisonEngine().compare(
            leftURL: leftURL,
            rightURL: rightURL,
            options: MetadataComparisonOptions(
                ignoredKeys: ignoreModificationTime
                    ? ["file.modified", "file.modifiedNanoseconds"]
                    : []
            )
        )
    }
}

private let localMetadataComparisonWorker = LocalMetadataComparisonWorker()

@MainActor
private final class MetadataCompareModel: ObservableObject {
    enum Side { case left, right }

    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var result: LocalMetadataComparisonResult?
    @Published private(set) var isLoading = false
    @Published var showDifferencesOnly = false
    @Published var ignoreModificationTime = false {
        didSet {
            if result != nil {
                rebuildComparison()
            } else if leftURL != nil, rightURL != nil {
                compareIfReady()
            }
        }
    }
    @Published var errorMessage: String?

    private var comparisonTask: Task<Void, Never>?

    var visibleRows: [MetadataComparisonListItem] {
        guard let result else { return [] }
        let rows = showDifferencesOnly
            ? result.comparison.rows.filter { $0.status != .same }
            : result.comparison.rows
        return rows.map(MetadataComparisonListItem.init)
    }

    func chooseItem(for side: Side) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.title = side == .left
            ? RiffaLocalization.string("Choose Left File or Folder")
            : RiffaLocalization.string("Choose Right File or Folder")
        panel.prompt = RiffaLocalization.string("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        replaceInput(with: url, for: side)
    }

    func replaceInput(with url: URL, for side: Side) {
        setURL(url, for: side)
    }

    func openInitial(_ urls: [URL], options: [String: String] = [:]) {
        if let value = options.riffaBoolean(for: "showDifferencesOnly") {
            showDifferencesOnly = value
        }
        if let value = options.riffaBoolean(for: "ignoreModificationTime") {
            ignoreModificationTime = value
        }
        leftURL = urls.first?.standardizedFileURL
        rightURL = urls.count > 1 ? urls[1].standardizedFileURL : nil
        compareIfReady()
    }

    func swapSides() {
        (leftURL, rightURL) = (rightURL, leftURL)
        if let result {
            self.result = LocalMetadataComparisonResult(
                left: result.right,
                right: result.left,
                comparison: MetadataComparison().compare(
                    left: result.right.fields,
                    right: result.left.fields,
                    options: comparisonOptions
                )
            )
        } else {
            compareIfReady()
        }
    }

    func saveReport(format: ComparisonReportFormat) {
        guard let result else { return }
        let fileExtension = switch format {
        case .plainText: "txt"
        case .html: "html"
        case .json: "json"
        }
        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string(
            "Export Metadata Comparison Report"
        )
        panel.prompt = RiffaLocalization.string("Export")
        panel.nameFieldStringValue = "Riffa-Metadata-Report.\(fileExtension)"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            let report = try SpecializedComparisonReportGenerator().generate(
                metadata: result,
                format: format,
                leftLabel: result.left.itemName,
                rightLabel: result.right.itemName
            )
            try report.write(to: destinationURL, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = String(
                localized: "Could not export the metadata report: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private var comparisonOptions: MetadataComparisonOptions {
        MetadataComparisonOptions(
            ignoredKeys: ignoreModificationTime
                ? ["file.modified", "file.modifiedNanoseconds"]
                : []
        )
    }

    private func setURL(_ url: URL, for side: Side) {
        switch side {
        case .left: leftURL = url.standardizedFileURL
        case .right: rightURL = url.standardizedFileURL
        }
        compareIfReady()
    }

    private func rebuildComparison() {
        guard let result else { return }
        self.result = LocalMetadataComparisonResult(
            left: result.left,
            right: result.right,
            comparison: MetadataComparison().compare(
                left: result.left.fields,
                right: result.right.fields,
                options: comparisonOptions
            )
        )
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
        let ignoresModificationTime = ignoreModificationTime
        comparisonTask = Task { [weak self] in
            do {
                let comparison = try await localMetadataComparisonWorker.compare(
                    leftURL: leftURL,
                    rightURL: rightURL,
                    ignoreModificationTime: ignoresModificationTime
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
                self.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct MetadataComparisonListItem: Identifiable {
    let row: MetadataComparisonRow
    var id: String { "\(row.key)#\(row.occurrenceIndex)" }
}

struct MetadataCompareView: View {
    @Environment(\.riffaTheme) private var theme
    @StateObject private var model = MetadataCompareModel()
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
                ProgressView("Reading bounded file-system metadata…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = model.result {
                results(result)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Metadata Compare")
        .background(theme.canvas)
        .riffaWindowDropZones([
            RiffaDropZone(role: .left, acceptedKind: .anyExistingEntry) {
                model.replaceInput(with: $0, for: .left)
            },
            RiffaDropZone(role: .right, acceptedKind: .anyExistingEntry) {
                model.replaceInput(with: $0, for: .right)
            },
        ])
        .alert(
            "Metadata comparison error",
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
            title: "Metadata Compare",
            subtitle: "Stable inode attributes, ACLs, and bounded xattr digests"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .metadataComparison,
                    urls: [model.leftURL, model.rightURL].compactMap { $0 },
                    options: [
                        "ignoreModificationTime": .boolean(model.ignoreModificationTime),
                        "showDifferencesOnly": .boolean(model.showDifferencesOnly)
                    ]
                ),
                errorMessage: $model.errorMessage
            )
            Toggle("Ignore modified time", isOn: $model.ignoreModificationTime)
                .toggleStyle(.checkbox)
            Toggle("Differences", isOn: $model.showDifferencesOnly)
                .toggleStyle(.checkbox)
            Menu {
                Button("HTML…") { model.saveReport(format: .html) }
                Button("Plain Text…") { model.saveReport(format: .plainText) }
                Button("JSON…") { model.saveReport(format: .json) }
            } label: {
                Label("Export Report", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Export metadata report")
            .accessibilityHint("Opens a menu of report formats")
            .help("Export metadata comparison report")
            .disabled(model.result == nil || model.isLoading)
        }
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            MetadataPathButton(
                title: "Left item",
                url: model.leftURL
            ) { model.chooseItem(for: .left) }
            .riffaResourceDropTarget(
                role: .left,
                acceptedKind: .anyExistingEntry
            ) {
                model.replaceInput(with: $0, for: .left)
            }
            Button { model.swapSides() } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.riffaTertiary)
            .accessibilityLabel("Swap items")
            .accessibilityHint("Exchanges the left and right items")
            .help("Swap left and right")
            .disabled(model.leftURL == nil && model.rightURL == nil)
            MetadataPathButton(
                title: "Right item",
                url: model.rightURL
            ) { model.chooseItem(for: .right) }
            .riffaResourceDropTarget(
                role: .right,
                acceptedKind: .anyExistingEntry
            ) {
                model.replaceInput(with: $0, for: .right)
            }
        }
    }

    private func results(_ result: LocalMetadataComparisonResult) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                MetadataItemSummary(side: "Left", snapshot: result.left)
                MetadataItemSummary(side: "Right", snapshot: result.right)
            }
            .padding(10)
            RiffaHairline()
            Table(model.visibleRows) {
                TableColumn("Status") { item in
                    LocalMetadataStatusLabel(status: item.row.status)
                }
                .width(min: 85, ideal: 100, max: 125)
                TableColumn("Field") { item in
                    if item.row.key.hasPrefix("xattr.") {
                        let attributeName = String(
                            item.row.key.dropFirst("xattr.".count)
                        )
                        Text("Extended attribute: \(attributeName)")
                            .help(item.row.key)
                    } else {
                        Text(LocalizedStringKey(item.row.displayName))
                            .help(item.row.key)
                    }
                }
                .width(min: 200, ideal: 290)
                TableColumn("Left") { item in
                    Text(localMetadataValueText(item.row.left?.value))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .width(min: 240, ideal: 370)
                TableColumn("Right") { item in
                    Text(localMetadataValueText(item.row.right?.value))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .width(min: 240, ideal: 370)
            }
            let statistics = result.comparison.statistics
            HStack(spacing: 16) {
                Label(
                    "\(statistics.differentCount) different",
                    systemImage: RiffaIcon.notEqual
                )
                    .foregroundStyle(theme.warning)
                Label("\(statistics.leftOnlyCount) left only", systemImage: "arrow.left")
                    .foregroundStyle(theme.inkMuted)
                Label("\(statistics.rightOnlyCount) right only", systemImage: "arrow.right")
                    .foregroundStyle(theme.inkMuted)
                Spacer()
                Text("\(model.visibleRows.count) of \(statistics.totalCount) fields")
                    .foregroundStyle(theme.inkSubtle)
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
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Choose two files or folders", systemImage: "list.bullet.rectangle")
        } description: {
            Text("Riffa compares each selected directory entry without reading file bodies, recursing into folders, or following symbolic links.")
        } actions: {
            HStack {
                Button("Choose Left") { model.chooseItem(for: .left) }
                    .buttonStyle(
                        RiffaButtonStyle(model.leftURL == nil ? .primary : .secondary)
                    )
                Button("Choose Right") { model.chooseItem(for: .right) }
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

private struct MetadataPathButton: View {
    let title: String
    let url: URL?
    let action: () -> Void

    var body: some View {
        RiffaResourcePathButton(
            title: title,
            url: url,
            emptyTitle: "Choose a file or folder…",
            systemImage: "doc.badge.gearshape",
            accessibilityHint: "Choose a file or folder",
            action: action
        )
        .accessibilityValue(
            url?.path(percentEncoded: false)
                ?? RiffaLocalization.string("No item selected")
        )
    }
}

private struct MetadataItemSummary: View {
    let side: String
    let snapshot: LocalMetadataSnapshot
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(theme.inkMuted)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    verbatim: "\(RiffaLocalization.string(side)): \(snapshot.itemName)"
                )
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: "\(typeTitle) · \(summaryText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.surface(.one),
            in: RoundedRectangle(cornerRadius: RiffaRadius.lg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RiffaRadius.lg)
                .strokeBorder(theme.hairline, lineWidth: 1)
        }
    }

    private var typeTitle: String {
        let key = switch snapshot.itemType {
        case .regularFile: "File"
        case .directory: "Folder"
        case .symbolicLink: "Symbolic link"
        case .characterDevice: "Character device"
        case .blockDevice: "Block device"
        case .fifo: "FIFO"
        case .socket: "Socket"
        case .unknown: "Unknown type"
        }
        return RiffaLocalization.string(key)
    }

    private var summaryText: String {
        let byteCount = snapshot.byteCount.formatted(.byteCount(style: .file))
        let extendedAttributeCount = snapshot.extendedAttributes.count
        let accessControlEntryCount = snapshot.accessControlList?.entryCount ?? 0
        return String(
            localized: "\(byteCount) · \(extendedAttributeCount) extended attributes · \(accessControlEntryCount) ACL entries",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private var symbol: String {
        switch snapshot.itemType {
        case .directory: "folder.fill"
        case .symbolicLink: "link"
        default: "doc.fill"
        }
    }
}

private struct LocalMetadataStatusLabel: View {
    let status: MetadataComparisonStatus
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
        case .same: "checkmark"
        case .different: RiffaIcon.notEqual
        case .leftOnly: "arrow.left"
        case .rightOnly: "arrow.right"
        }
    }

    private var color: Color {
        switch status {
        case .same: theme.inkMuted
        case .different: theme.warning
        case .leftOnly, .rightOnly: theme.inkMuted
        }
    }
}

private func localMetadataValueText(_ value: MetadataValue?) -> String {
    guard let value else { return "—" }
    return switch value {
    case let .string(value): value
    case let .integer(value): String(value)
    case let .decimal(value): NSDecimalNumber(decimal: value).stringValue
    case let .boolean(value):
        RiffaLocalization.string(value ? "Yes" : "No")
    case let .date(value): value.formatted(date: .abbreviated, time: .standard)
    case let .data(summary):
        String(
            localized: "\(summary.byteCount) bytes · SHA-256 \(summary.sha256)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    case .null: RiffaLocalization.string("Null")
    }
}
