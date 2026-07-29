@preconcurrency import AVFoundation
import AppKit
import Foundation
import RiffaCore
import SwiftUI

@MainActor
private final class MediaCompareModel: ObservableObject {
    enum Side: Hashable { case left, right }

    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var result: MetadataComparisonResult?
    @Published private(set) var isLoading = false
    @Published var showDifferencesOnly = false
    @Published var ignoreCase = false { didSet { compareIfReady() } }
    @Published var ignoreWhitespace = false { didSet { compareIfReady() } }
    @Published var numericTolerance = 0.0 { didSet { compareIfReady() } }
    @Published var errorMessage: String?

    private var leftFields: [MetadataField]?
    private var rightFields: [MetadataField]?
    private var initialLoadingTask: Task<Void, Never>?
    private var initialLoadToken: UUID?
    private var sideLoadingTasks: [Side: Task<Void, Never>] = [:]
    private var sideLoadTokens: [Side: UUID] = [:]
    private var sideLoadBatchToken = UUID()
    private var stagedSideLoads: [Side: (url: URL, fields: [MetadataField])] = [:]
    private var failedSideLoads: Set<Side> = []

    var visibleRows: [IdentifiedMetadataRow] {
        guard let result else { return [] }
        let rows = showDifferencesOnly ? result.rows.filter { $0.status != .same } : result.rows
        return rows.map(IdentifiedMetadataRow.init)
    }

    func chooseFile(for side: Side) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = RiffaLocalization.string(
            side == .left ? "Choose Left Media File" : "Choose Right Media File"
        )
        panel.prompt = RiffaLocalization.string("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        replaceInput(with: url, for: side)
    }

    func replaceInput(with url: URL, for side: Side) {
        cancelInitialLoad()
        load(url: url, for: side)
    }

    func openInitial(_ urls: [URL], options: [String: String] = [:]) {
        if let value = options.riffaBoolean(for: "ignoreCase") {
            ignoreCase = value
        }
        if let value = options.riffaBoolean(for: "ignoreWhitespace") {
            ignoreWhitespace = value
        }
        if let value = options.riffaDouble(for: "numericTolerance"), (0...1).contains(value) {
            numericTolerance = value
        }
        if let value = options.riffaBoolean(for: "showDifferencesOnly") {
            showDifferencesOnly = value
        }
        cancelAllLoads()
        guard let leftURL = urls.first else { return }
        guard urls.count > 1 else {
            load(url: leftURL, for: .left)
            return
        }
        let rightURL = urls[1]
        let token = UUID()
        initialLoadToken = token
        refreshLoadingState()
        errorMessage = nil
        initialLoadingTask = Task { [weak self] in
            do {
                async let left = Self.extractMetadata(from: leftURL)
                async let right = Self.extractMetadata(from: rightURL)
                let fields = try await (left, right)
                guard !Task.isCancelled,
                      let self,
                      self.initialLoadToken == token else { return }
                self.leftURL = leftURL
                self.rightURL = rightURL
                self.leftFields = fields.0
                self.rightFields = fields.1
                self.finishInitialLoad(token: token)
                self.compareIfReady()
            } catch is CancellationError {
                guard let self else { return }
                self.finishInitialLoad(token: token)
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.initialLoadToken == token else { return }
                self.finishInitialLoad(token: token)
                self.errorMessage = String(
                    localized: "Could not inspect the opened media: \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        }
    }

    func loadDemo() {
        cancelAllLoads()
        leftURL = URL(fileURLWithPath: "/Demo/episode-master.m4a")
        rightURL = URL(fileURLWithPath: "/Demo/episode-release.m4a")
        leftFields = [
            Self.field("file.size", "File Size", .integer(8_420_000), .informational),
            Self.field("asset.duration", "Duration", .decimal(Decimal(string: "181.250")!), .critical),
            Self.field("common.title", "Title", .string("Riffa — Episode 1"), .important),
            Self.field("common.artist", "Artist", .string("Riffa Studio"), .important),
            Self.field("common.comment", "Comment", .string("Master"), .normal),
        ]
        rightFields = [
            Self.field("file.size", "File Size", .integer(7_990_000), .informational),
            Self.field("asset.duration", "Duration", .decimal(Decimal(string: "181.251")!), .critical),
            Self.field("common.title", "Title", .string("Riffa — Episode 1"), .important),
            Self.field("common.artist", "Artist", .string("Riffa Studio"), .important),
            Self.field("common.comment", "Comment", .string("Release"), .normal),
            Self.field("common.copyright", "Copyright", .string("2026 Riffa"), .normal),
        ]
        errorMessage = nil
        compareIfReady()
    }

    func swapSides() {
        cancelAllLoads()
        let previousLeftURL = leftURL
        let previousLeftFields = leftFields
        leftURL = rightURL
        rightURL = previousLeftURL
        leftFields = rightFields
        rightFields = previousLeftFields
        compareIfReady()
    }

    func saveReport(format: ComparisonReportFormat) {
        guard let result else { return }
        let fileExtension: String
        switch format {
        case .plainText: fileExtension = "txt"
        case .html: fileExtension = "html"
        case .json: fileExtension = "json"
        }

        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string("Export Media Comparison Report")
        panel.prompt = RiffaLocalization.string("Export")
        panel.nameFieldStringValue = "Riffa-Media-Report.\(fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let report = try SpecializedComparisonReportGenerator().generate(
                metadata: result,
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

    private func load(url: URL, for side: Side) {
        if sideLoadTokens.isEmpty {
            sideLoadBatchToken = UUID()
            stagedSideLoads.removeAll()
            failedSideLoads.removeAll()
        }
        let batchToken = sideLoadBatchToken
        sideLoadingTasks[side]?.cancel()
        let token = UUID()
        sideLoadTokens[side] = token
        stagedSideLoads[side] = nil
        failedSideLoads.remove(side)
        refreshLoadingState()
        errorMessage = nil
        sideLoadingTasks[side] = Task { [weak self] in
            do {
                let fields = try await Self.extractMetadata(from: url)
                guard !Task.isCancelled,
                      let self,
                      self.sideLoadTokens[side] == token,
                      self.sideLoadBatchToken == batchToken else { return }
                self.stagedSideLoads[side] = (url: url, fields: fields)
                self.finishSideLoad(side, token: token)
                self.finishSideLoadBatchIfReady(token: batchToken)
            } catch is CancellationError {
                guard let self else { return }
                self.finishSideLoad(side, token: token)
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.sideLoadTokens[side] == token,
                      self.sideLoadBatchToken == batchToken else { return }
                self.failedSideLoads.insert(side)
                self.finishSideLoad(side, token: token)
                self.errorMessage = String(
                    localized: "Could not inspect \(url.lastPathComponent): \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
                self.finishSideLoadBatchIfReady(token: batchToken)
            }
        }
    }

    private func cancelInitialLoad() {
        initialLoadingTask?.cancel()
        initialLoadingTask = nil
        initialLoadToken = nil
        refreshLoadingState()
    }

    private func cancelAllLoads() {
        cancelInitialLoad()
        for task in sideLoadingTasks.values {
            task.cancel()
        }
        sideLoadingTasks.removeAll()
        sideLoadTokens.removeAll()
        sideLoadBatchToken = UUID()
        stagedSideLoads.removeAll()
        failedSideLoads.removeAll()
        refreshLoadingState()
    }

    private func finishInitialLoad(token: UUID) {
        guard initialLoadToken == token else { return }
        initialLoadingTask = nil
        initialLoadToken = nil
        refreshLoadingState()
    }

    private func finishSideLoad(_ side: Side, token: UUID) {
        guard sideLoadTokens[side] == token else { return }
        sideLoadingTasks[side] = nil
        sideLoadTokens[side] = nil
        refreshLoadingState()
    }

    private func refreshLoadingState() {
        isLoading = initialLoadToken != nil || !sideLoadTokens.isEmpty
    }

    private func finishSideLoadBatchIfReady(token: UUID) {
        guard sideLoadBatchToken == token, sideLoadTokens.isEmpty else { return }
        let stagedLoads = stagedSideLoads
        let shouldCommit = failedSideLoads.isEmpty
        sideLoadBatchToken = UUID()
        stagedSideLoads.removeAll()
        failedSideLoads.removeAll()
        guard shouldCommit else { return }

        if let loaded = stagedLoads[.left] {
            leftURL = loaded.url
            leftFields = loaded.fields
        }
        if let loaded = stagedLoads[.right] {
            rightURL = loaded.url
            rightFields = loaded.fields
        }
        compareIfReady()
    }

    private func compareIfReady() {
        guard let leftFields, let rightFields else {
            result = nil
            return
        }
        result = MetadataComparison().compare(
            left: leftFields,
            right: rightFields,
            options: MetadataComparisonOptions(
                ignoreStringCase: ignoreCase,
                ignoreStringWhitespace: ignoreWhitespace,
                numericTolerance: Decimal(numericTolerance),
                dateTolerance: 0
            )
        )
    }

    nonisolated private static func extractMetadata(from url: URL) async throws -> [MetadataField] {
        var fields: [MetadataField] = []
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .typeIdentifierKey,
        ])
        fields.append(field("file.name", "File Name", .string(url.lastPathComponent), .informational))
        if let size = values.fileSize {
            fields.append(field("file.size", "File Size", .integer(Int64(size)), .informational))
        }
        if let date = values.contentModificationDate {
            fields.append(field("file.modified", "Modified", .date(date), .informational))
        }
        if let type = values.typeIdentifier {
            fields.append(field("file.type", "Content Type", .string(type), .normal))
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        fields.append(
            field(
                "asset.duration",
                "Duration (seconds)",
                durationSeconds.isFinite ? .decimal(Decimal(durationSeconds)) : .null,
                .critical
            )
        )
        let playable = try await asset.load(.isPlayable)
        fields.append(field("asset.playable", "Playable", .boolean(playable), .important))
        let tracks = try await asset.load(.tracks)
        fields.append(field("asset.trackCount", "Track Count", .integer(Int64(tracks.count)), .important))

        let metadata = try await asset.load(.metadata)
        let commonMetadata = try await asset.load(.commonMetadata)
        for (scope, items) in [("metadata", metadata), ("common", commonMetadata)] {
            for item in items {
                let identifier = item.identifier?.rawValue
                    ?? item.commonKey?.rawValue
                    ?? item.key.map(String.init(describing:))
                    ?? "unknown"
                let displayName = item.commonKey.map {
                    commonMetadataDisplayName($0.rawValue)
                } ?? identifier
                let value = try await item.load(.value)
                fields.append(
                    field(
                        "\(scope).\(identifier)",
                        displayName,
                        metadataValue(value),
                        scope == "common" ? .important : .normal
                    )
                )
            }
        }
        return fields
    }

    nonisolated private static func commonMetadataDisplayName(
        _ rawValue: String
    ) -> String {
        switch rawValue {
        case "title": "Title"
        case "creator": "Creator"
        case "subject": "Subject"
        case "description": "Description"
        case "publisher": "Publisher"
        case "contributor": "Contributor"
        case "creationDate": "Creation Date"
        case "lastModifiedDate": "Last Modified Date"
        case "type": "Type"
        case "format": "Format"
        case "identifier": "Identifier"
        case "source": "Source"
        case "language": "Language"
        case "relation": "Relation"
        case "location": "Location"
        case "copyrights": "Copyright"
        case "albumName": "Album Name"
        case "author": "Author"
        case "artist": "Artist"
        case "artwork": "Artwork"
        case "make": "Make"
        case "model": "Model"
        case "software": "Software"
        case "accessibilityDescription": "Accessibility Description"
        default: rawValue
        }
    }

    nonisolated private static func metadataValue(_ value: (any NSCopying & NSObjectProtocol)?) -> MetadataValue {
        guard let value else { return .null }
        if let string = value as? String { return .string(string) }
        if let date = value as? Date { return .date(date) }
        if let data = value as? Data { return .data(MetadataDataSummary(data: data)) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            return .decimal(Decimal(string: number.stringValue) ?? 0)
        }
        return .string(String(describing: value))
    }

    nonisolated private static func field(
        _ key: String,
        _ name: String,
        _ value: MetadataValue,
        _ importance: MetadataImportance
    ) -> MetadataField {
        MetadataField(key: key, displayName: name, value: value, importance: importance)
    }
}

private struct IdentifiedMetadataRow: Identifiable {
    let row: MetadataComparisonRow

    var id: String {
        "\(row.key)#\(row.occurrenceIndex)"
    }
}

struct MediaCompareView: View {
    @Environment(\.riffaTheme) private var theme
    @StateObject private var model = MediaCompareModel()
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
            if model.isLoading && model.result == nil {
                ProgressView("Reading media metadata…")
                    .controlSize(.large)
                    .tint(theme.accent)
                    .foregroundStyle(theme.inkSubtle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = model.result {
                results(result)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Media Compare")
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
            "Media comparison error",
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
            title: "Media Compare",
            subtitle: "Technical metadata, tracks, and stream properties"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .mediaComparison,
                    urls: [model.leftURL, model.rightURL].compactMap { $0 },
                    options: [
                        "ignoreCase": .boolean(model.ignoreCase),
                        "ignoreWhitespace": .boolean(model.ignoreWhitespace),
                        "numericTolerance": .decimal(Decimal(model.numericTolerance)),
                        "showDifferencesOnly": .boolean(model.showDifferencesOnly)
                    ]
                ),
                errorMessage: $model.errorMessage
            )
            Menu {
                Button("HTML…") { model.saveReport(format: .html) }
                Button("Plain Text…") { model.saveReport(format: .plainText) }
                Button("JSON…") { model.saveReport(format: .json) }
            } label: {
                Label("Export Report", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Export media comparison report")
            .accessibilityHint("Choose HTML, plain text, or JSON")
            .help("Export comparison report")
            .disabled(model.result == nil || model.isLoading)
        }
    }

    private var controlBar: some View {
        RiffaComparisonControlBar {
            Toggle("Ignore case", isOn: $model.ignoreCase)
                .toggleStyle(.checkbox)
            Toggle("Ignore whitespace", isOn: $model.ignoreWhitespace)
                .toggleStyle(.checkbox)
            Text("Numeric tolerance ±\(model.numericTolerance, specifier: "%.3f")")
                .riffaText(.caption)
                .foregroundStyle(theme.inkSubtle)
            Slider(value: $model.numericTolerance, in: 0...1, step: 0.001)
                .frame(width: 130)
                .accessibilityLabel("Numeric tolerance")
                .accessibilityValue(
                    Text(model.numericTolerance, format: .number.precision(.fractionLength(3)))
                )
            Toggle("Differences only", isOn: $model.showDifferencesOnly)
                .toggleStyle(.checkbox)
        }
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            MediaPathButton(title: "Left media", url: model.leftURL) {
                model.chooseFile(for: .left)
            }
            .riffaResourceDropTarget(
                role: .left,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .left)
            }
            Button { model.swapSides() } label: {
                Label("Swap media files", systemImage: "arrow.left.arrow.right")
            }
                .labelStyle(.iconOnly)
                .buttonStyle(.riffaIcon)
                .accessibilityLabel("Swap media files")
                .accessibilityHint("Exchanges the left and right media files")
                .help("Swap media files")
                .disabled(model.leftURL == nil && model.rightURL == nil)
            MediaPathButton(title: "Right media", url: model.rightURL) {
                model.chooseFile(for: .right)
            }
            .riffaResourceDropTarget(
                role: .right,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .right)
            }
        }
    }

    private func results(_ result: MetadataComparisonResult) -> some View {
        VStack(spacing: 0) {
            Table(model.visibleRows) {
                TableColumn("Status") { item in MetadataStatusLabel(status: item.row.status) }
                    .width(min: 85, ideal: 100, max: 120)
                TableColumn("Field") { item in
                    let row = item.row
                    VStack(alignment: .leading, spacing: 2) {
                        mediaFieldName(row)
                        if row.occurrenceIndex > 0 {
                            Text("Occurrence \(row.occurrenceIndex + 1)")
                                .font(.caption2)
                                .foregroundStyle(theme.inkSubtle)
                        }
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("Left") { item in Text(item.row.left.map { display($0.value) } ?? "—").lineLimit(3) }
                    .width(min: 240, ideal: 360)
                TableColumn("Right") { item in Text(item.row.right.map { display($0.value) } ?? "—").lineLimit(3) }
                    .width(min: 240, ideal: 360)
                TableColumn("Importance") { item in
                    Text(LocalizedStringKey(item.row.importance.rawValue.capitalized))
                        .foregroundStyle(theme.inkSubtle)
                }
                    .width(min: 90, ideal: 110)
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            RiffaStatusBar {
                RiffaStatusBadge(
                    "\(result.statistics.differentCount) different",
                    systemImage: RiffaIcon.notEqual,
                    tone: .warning
                )
                RiffaStatusBadge(
                    "\(result.statistics.leftOnlyCount) left only",
                    systemImage: "arrow.left"
                )
                RiffaStatusBadge(
                    "\(result.statistics.rightOnlyCount) right only",
                    systemImage: "arrow.right"
                )
                Spacer()
                Text("\(model.visibleRows.count) of \(result.statistics.totalCount) fields")
                    .foregroundStyle(theme.inkSubtle)
            }
        }
    }

    private var emptyState: some View {
        RiffaEmptyState(
            title: "Choose two media files",
            description: "Compare duration, tracks, file attributes, and embedded metadata entirely on this Mac.",
            systemImage: "waveform"
        ) {
            HStack {
                Button("Choose Left…") { model.chooseFile(for: .left) }
                    .buttonStyle(
                        RiffaButtonStyle(model.leftURL == nil ? .primary : .secondary)
                    )
                Button("Choose Right…") { model.chooseFile(for: .right) }
                    .buttonStyle(
                        RiffaButtonStyle(
                            model.leftURL != nil && model.rightURL == nil
                                ? .primary
                                : .secondary
                        )
                    )
                Button("Load Demo") { model.loadDemo() }
                    .buttonStyle(.riffaTertiary)
                    .accessibilityHint("Loads sample metadata without choosing files")
            }
        }
    }

    private func display(_ value: MetadataValue) -> String {
        switch value {
        case let .string(value):
            return value
        case let .integer(value):
            return String(value)
        case let .decimal(value):
            return NSDecimalNumber(decimal: value).stringValue
        case let .boolean(value):
            return RiffaLocalization.string(value ? "Yes" : "No")
        case let .date(value):
            return value.formatted(date: .abbreviated, time: .standard)
        case let .data(value):
            let digestPrefix = String(value.sha256.prefix(12))
            return String(
                localized: "\(value.byteCount) bytes · SHA-256 \(digestPrefix)…",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .null:
            return RiffaLocalization.string("Null")
        }
    }

    private func mediaFieldName(_ row: MetadataComparisonRow) -> Text {
        let identifier = row.key.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).last.map(String.init) ?? row.key
        let isBuiltIn = row.key.hasPrefix("file.")
            || row.key.hasPrefix("asset.")
        if isBuiltIn || row.displayName != identifier {
            return Text(LocalizedStringKey(row.displayName))
        }
        return Text(verbatim: row.displayName)
    }
}

private struct MetadataStatusLabel: View {
    let status: MetadataComparisonStatus
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Label(
            LocalizedStringKey(status.rawValue.capitalized),
            systemImage: symbol
        )
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
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
        case .same: theme.inkSubtle
        case .different: theme.warning
        case .leftOnly, .rightOnly: theme.inkMuted
        }
    }
}

private struct MediaPathButton: View {
    let title: String
    let url: URL?
    let action: () -> Void

    var body: some View {
        RiffaResourcePathButton(
            title: title,
            url: url,
            emptyTitle: "Choose a media file…",
            systemImage: "waveform",
            accessibilityHint: "Choose a media file",
            action: action
        )
        .accessibilityValue(
            url?.path(percentEncoded: false)
                ?? RiffaLocalization.string("No media file selected")
        )
    }
}
