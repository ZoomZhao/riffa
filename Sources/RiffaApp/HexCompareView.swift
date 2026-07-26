import AppKit
import Foundation
import RiffaCore
import SwiftUI

@MainActor
private final class HexCompareModel: ObservableObject {
    enum Side { case left, right }

    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var summary: LocalHexComparisonSummary?
    @Published private(set) var page: LocalHexComparisonPage?
    @Published private(set) var isComparing = false
    @Published private(set) var isLoadingPage = false
    @Published var currentDifferenceIndex: Int?
    @Published var errorMessage: String?

    private let engine = LocalHexComparisonEngine()
    private var comparisonTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var comparisonGeneration = 0
    private var pageGeneration = 0
    private var demoDirectory: URL?

    var selectedRowOffset: UInt64? {
        guard let currentDifferenceIndex,
              let summary,
              let page,
              summary.publishedDifferenceRanges.indices.contains(currentDifferenceIndex)
        else { return nil }
        let offset = summary.publishedDifferenceRanges[currentDifferenceIndex].startOffset
        guard offset >= page.offset, offset < page.endOffset else { return nil }
        return page.rows.last(where: { $0.offset <= offset })?.offset
    }

    var hasAnyURL: Bool { leftURL != nil || rightURL != nil }
    var canCompare: Bool { leftURL != nil && rightURL != nil && !isComparing }

    deinit {
        comparisonTask?.cancel()
        pageTask?.cancel()
        if let demoDirectory {
            try? FileManager.default.removeItem(at: demoDirectory)
        }
    }

    func chooseFile(for side: Side) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = side == .left
            ? RiffaLocalization.string("Choose Left Binary File")
            : RiffaLocalization.string("Choose Right Binary File")
        panel.prompt = RiffaLocalization.string("Choose")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        set(url: url, for: side)
        compareIfReady()
    }

    func openInitial(_ urls: [URL], options _: [String: String] = [:]) {
        if let left = urls.first { leftURL = left }
        if urls.count > 1 { rightURL = urls[1] }
        compareIfReady()
    }

    func loadDemo() {
        do {
            if let demoDirectory {
                try? FileManager.default.removeItem(at: demoDirectory)
            }
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "Riffa-Hex-Demo-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let left = directory.appending(path: "header-v1.bin")
            let right = directory.appending(path: "header-v2.bin")
            try Data((0..<96).map(UInt8.init)).write(to: left)
            var changed = (0..<96).map(UInt8.init)
            changed[7] = 0xFA
            changed[8] = 0xCE
            changed[48] = 0x52
            changed.append(contentsOf: [0x52, 0x49, 0x46, 0x46, 0x41])
            try Data(changed).write(to: right)
            demoDirectory = directory
            leftURL = left
            rightURL = right
            errorMessage = nil
            compareIfReady()
        } catch {
            errorMessage = String(
                localized: "Could not create the temporary demo: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    func swapSides() {
        (leftURL, rightURL) = (rightURL, leftURL)
        compareIfReady()
    }

    func cancelComparison() {
        comparisonGeneration &+= 1
        pageGeneration &+= 1
        comparisonTask?.cancel()
        pageTask?.cancel()
        isComparing = false
        isLoadingPage = false
        summary = nil
        page = nil
        currentDifferenceIndex = nil
    }

    func compareSelectedFiles() {
        compareIfReady()
    }

    func nextDifference() {
        guard let ranges = summary?.publishedDifferenceRanges, !ranges.isEmpty else { return }
        let index = ((currentDifferenceIndex ?? -1) + 1) % ranges.count
        currentDifferenceIndex = index
        loadPage(containing: ranges[index].startOffset)
    }

    func previousDifference() {
        guard let ranges = summary?.publishedDifferenceRanges, !ranges.isEmpty else { return }
        let index = ((currentDifferenceIndex ?? 0) - 1 + ranges.count) % ranges.count
        currentDifferenceIndex = index
        loadPage(containing: ranges[index].startOffset)
    }

    func nextPage() {
        guard let page, page.hasNextPage else { return }
        currentDifferenceIndex = nil
        loadPage(offset: page.endOffset)
    }

    func previousPage() {
        guard let page, page.hasPreviousPage else { return }
        currentDifferenceIndex = nil
        let pageByteCount = UInt64(engine.limits.pageByteCount)
        loadPage(offset: page.offset >= pageByteCount ? page.offset - pageByteCount : 0)
    }

    func saveReport(format: ComparisonReportFormat) {
        guard let summary else { return }
        let fileExtension: String
        switch format {
        case .plainText: fileExtension = "txt"
        case .html: fileExtension = "html"
        case .json: fileExtension = "json"
        }

        let panel = NSSavePanel()
        panel.title = RiffaLocalization.string("Export Hex Comparison Report")
        panel.prompt = RiffaLocalization.string("Export")
        panel.nameFieldStringValue = "Riffa-Hex-Report.\(fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let report = try SpecializedComparisonReportGenerator().generate(
                hex: summary,
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

    private func set(url: URL, for side: Side) {
        switch side {
        case .left: leftURL = url
        case .right: rightURL = url
        }
    }

    private func compareIfReady() {
        comparisonTask?.cancel()
        pageTask?.cancel()
        comparisonGeneration &+= 1
        pageGeneration &+= 1
        let generation = comparisonGeneration
        guard let leftURL, let rightURL else {
            summary = nil
            page = nil
            currentDifferenceIndex = nil
            isComparing = false
            isLoadingPage = false
            return
        }
        summary = nil
        page = nil
        currentDifferenceIndex = nil
        errorMessage = nil
        isComparing = true
        isLoadingPage = false
        comparisonTask = Task { [weak self, engine] in
            do {
                let summary = try await engine.compare(leftURL: leftURL, rightURL: rightURL)
                let page = try await engine.page(
                    leftURL: leftURL,
                    rightURL: rightURL,
                    matching: summary,
                    offset: 0
                )
                guard let self,
                      !Task.isCancelled,
                      self.comparisonGeneration == generation else { return }
                self.summary = summary
                self.page = page
                self.currentDifferenceIndex = nil
                self.isComparing = false
            } catch is CancellationError {
                guard let self, self.comparisonGeneration == generation else { return }
                self.isComparing = false
            } catch {
                guard let self, self.comparisonGeneration == generation else { return }
                self.isComparing = false
                self.errorMessage = String(
                    localized: "Could not compare the files: \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        }
    }

    private func loadPage(containing offset: UInt64) {
        let pageByteCount = UInt64(engine.limits.pageByteCount)
        loadPage(offset: (offset / pageByteCount) * pageByteCount)
    }

    private func loadPage(offset: UInt64) {
        guard let leftURL, let rightURL, let summary else { return }
        pageTask?.cancel()
        pageGeneration &+= 1
        let generation = pageGeneration
        isLoadingPage = true
        pageTask = Task { [weak self, engine] in
            do {
                let page = try await engine.page(
                    leftURL: leftURL,
                    rightURL: rightURL,
                    matching: summary,
                    offset: offset
                )
                guard let self,
                      !Task.isCancelled,
                      self.pageGeneration == generation else { return }
                self.page = page
                self.isLoadingPage = false
            } catch is CancellationError {
                guard let self, self.pageGeneration == generation else { return }
                self.isLoadingPage = false
            } catch {
                guard let self, self.pageGeneration == generation else { return }
                self.isLoadingPage = false
                self.errorMessage = String(
                    localized: "Could not read that page: \(error.localizedDescription)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            }
        }
    }
}

struct HexCompareView: View {
    @StateObject private var model = HexCompareModel()
    @Environment(\.riffaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

            if let summary = model.summary, let page = model.page {
                comparison(summary, page: page)
            } else if model.isComparing {
                VStack(spacing: RiffaSpacing.md) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(theme.accent)
                        .accessibilityLabel("Comparing binary files")
                    Text("Comparing binary files…")
                        .riffaText(.body)
                        .foregroundStyle(theme.inkMuted)
                    Button("Cancel") {
                        model.cancelComparison()
                    }
                    .buttonStyle(.riffaSecondary)
                    .accessibilityHint("Stops the current binary comparison")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.canvas)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Hex Compare")
        .background(theme.canvas)
        .alert(
            "Hex comparison error",
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
            title: "Hex Compare",
            subtitle: "Streamed same-offset binary comparison"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .hexadecimalComparison,
                    urls: [model.leftURL, model.rightURL].compactMap { $0 }
                ),
                errorMessage: $model.errorMessage
            )
            Button { model.previousDifference() } label: {
                Label("Previous difference", systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Previous byte difference")
            .accessibilityHint("Moves to the preceding published difference range")
            .help("Previous byte difference")
            .disabled(model.summary?.publishedDifferenceRanges.isEmpty != false)
            Button { model.nextDifference() } label: {
                Label("Next difference", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Next byte difference")
            .accessibilityHint("Moves to the following published difference range")
            .help("Next byte difference")
            .disabled(model.summary?.publishedDifferenceRanges.isEmpty != false)
            Menu {
                Button("HTML…") { model.saveReport(format: .html) }
                Button("Plain Text…") { model.saveReport(format: .plainText) }
                Button("JSON…") { model.saveReport(format: .json) }
            } label: {
                Label("Export Report", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Export hex comparison report")
            .accessibilityHint("Choose HTML, plain text, or JSON")
            .help("Export comparison report")
            .disabled(model.summary == nil)
        }
    }

    private var controlBar: some View {
        RiffaComparisonControlBar {
            Button {
                model.previousPage()
            } label: {
                Label("Previous page", systemImage: "chevron.left")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Previous byte page")
            .accessibilityHint("Loads the preceding bounded page")
            .disabled(model.page?.hasPreviousPage != true || model.isLoadingPage)

            Text(
                verbatim: model.page.map(pageDescription)
                    ?? RiffaLocalization.string(
                        "16 bytes per row · offset / hex / ASCII"
                    )
            )
                .riffaText(.mono)
                .foregroundStyle(theme.inkMuted)
                .lineLimit(1)

            Button {
                model.nextPage()
            } label: {
                Label("Next page", systemImage: "chevron.right")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Next byte page")
            .accessibilityHint("Loads the following bounded page")
            .disabled(model.page?.hasNextPage != true || model.isLoadingPage)

            if model.isLoadingPage {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accent)
                    .accessibilityLabel("Loading byte page")
            }

            Spacer(minLength: RiffaSpacing.xs)

            RiffaStatusBadge(
                "16-byte rows",
                systemImage: "rectangle.split.3x1"
            )
            RiffaStatusBadge(
                "HEX + ASCII",
                systemImage: "textformat.123"
            )
        }
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            HexPathButton(title: "Left file", url: model.leftURL) {
                model.chooseFile(for: .left)
            }
            Button { model.swapSides() } label: {
                Label("Swap files", systemImage: "arrow.left.arrow.right")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Swap binary files")
            .accessibilityHint("Exchanges the left and right inputs")
            .help("Swap left and right")
            .disabled(!model.hasAnyURL)
            HexPathButton(title: "Right file", url: model.rightURL) {
                model.chooseFile(for: .right)
            }
        }
    }

    private func comparison(
        _ summary: LocalHexComparisonSummary,
        page: LocalHexComparisonPage
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                paneTitle("LEFT", name: model.leftURL?.lastPathComponent)
                RiffaHairline(.vertical)
                paneTitle("RIGHT", name: model.rightURL?.lastPathComponent)
            }

            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0) {
                        ForEach(page.rows) { row in
                            HexRowView(row: row)
                                .id(row.offset)
                        }
                    }
                }
                .onChange(of: model.selectedRowOffset) { _, offset in
                    guard let offset else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        proxy.scrollTo(offset, anchor: .center)
                    }
                }
            }
            .background(theme.canvas)

            RiffaStatusBar {
                if summary.hasDifferences {
                    RiffaStatusBadge(
                        "Δ \(summary.differingBytePositionCount) differing positions",
                        systemImage: RiffaIcon.notEqual,
                        tone: .warning
                    )
                } else {
                    RiffaStatusBadge(
                        "Files match",
                        systemImage: "checkmark.circle.fill",
                        tone: .success
                    )
                }
                Text("Left \(ByteCountFormatter.string(fromByteCount: Int64(summary.leftByteCount), countStyle: .file))")
                Text("Right \(ByteCountFormatter.string(fromByteCount: Int64(summary.rightByteCount), countStyle: .file))")
                Spacer()
                if summary.hasDifferences {
                    if let currentDifferenceIndex = model.currentDifferenceIndex {
                        Text("Published range \(currentDifferenceIndex + 1) of \(summary.publishedDifferenceRanges.count)")
                    }
                    Text("\(summary.differenceRangeCount) ranges total")
                    if summary.differenceRangesTruncated {
                        RiffaStatusBadge(
                            "Navigation truncated",
                            systemImage: "exclamationmark.triangle",
                            tone: .warning
                        )
                            .help("Navigation covers only the first \(summary.publishedDifferenceRanges.count) ranges; totals remain exact.")
                    }
                }
                Text("Bounded page")
                    .foregroundStyle(theme.inkTertiary)
            }
        }
    }

    private var emptyState: some View {
        RiffaEmptyState(
            title: "Choose two binary files",
            description: "Riffa shows same-offset byte differences without changing either file.",
            systemImage: "number.square"
        ) {
            HStack(spacing: RiffaSpacing.xs) {
                Button("Choose Left") {
                    model.chooseFile(for: .left)
                }
                .buttonStyle(.riffaSecondary)
                .accessibilityLabel("Choose left binary file")
                .accessibilityHint("Opens a local file picker")

                Button("Choose Right") {
                    model.chooseFile(for: .right)
                }
                .buttonStyle(.riffaSecondary)
                .accessibilityLabel("Choose right binary file")
                .accessibilityHint("Opens a local file picker")

                if model.canCompare {
                    Button("Compare Selected Files") {
                        model.compareSelectedFiles()
                    }
                    .buttonStyle(.riffaPrimary)
                    .accessibilityHint("Starts a bounded binary comparison")
                }

                Button("Load Demo") {
                    model.loadDemo()
                }
                .buttonStyle(model.canCompare ? .riffaTertiary : .riffaPrimary)
                .accessibilityHint("Creates two temporary sample binary files")
            }
        }
    }

    private func paneTitle(_ title: String, name: String?) -> some View {
        RiffaPaneHeader(
            title,
            subtitle: name ?? RiffaLocalization.string("No file"),
            systemImage: "number.square"
        )
        .frame(maxWidth: .infinity)
    }

    private func pageDescription(_ page: LocalHexComparisonPage) -> String {
        guard page.displayedByteCount > 0 else {
            return String(
                localized: "Empty files · offset 0x\(hexOffset(page.offset))",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "0x\(hexOffset(page.offset))–0x\(hexOffset(page.endOffset - 1)) of \(page.maximumByteCount) bytes",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func hexOffset(_ offset: UInt64) -> String {
        String(format: "%016llX", offset)
    }
}

private struct HexRowView: View {
    let row: LocalHexComparisonRow
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Text(String(format: "%016llX", row.offset))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.inkTertiary)
                .frame(width: 132, alignment: .trailing)
                .padding(.trailing, 10)
            bytePane(row.leftBytes, marker: "−", semanticColor: theme.danger)
            RiffaHairline(.vertical)
            Text(row.differingColumns.isEmpty ? "" : "Δ")
                .riffaText(.caption)
                .foregroundStyle(theme.warning)
                .frame(width: 28)
                .accessibilityHidden(true)
            RiffaHairline(.vertical)
            bytePane(row.rightBytes, marker: "+", semanticColor: theme.success)
        }
        .frame(height: 28)
        .background(theme.canvas)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline.opacity(0.7))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Offset \(row.offset), delta \(row.differingColumns.count) differing bytes"
        )
    }

    private func bytePane(
        _ bytes: [UInt8],
        marker: String,
        semanticColor: Color
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<16, id: \.self) { column in
                let isDifferent = row.differingColumns.contains(column)
                let value = column < bytes.count
                    ? String(format: "%02X", bytes[column])
                    : "··"
                Text(isDifferent ? "\(marker)\(value)" : value)
                    .font(.system(size: isDifferent ? 9.5 : 11.5, design: .monospaced))
                    .foregroundStyle(isDifferent ? semanticColor : theme.inkMuted)
                    .frame(width: 25)
                    .padding(.vertical, 3)
                    .background(
                        isDifferent ? semanticColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 3)
                    )
                    .overlay {
                        if isDifferent {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(semanticColor.opacity(0.55), lineWidth: 1)
                        }
                    }
                    .accessibilityLabel(
                        Text(
                            verbatim: byteAccessibilityLabel(
                                marker: marker,
                                value: value,
                                isDifferent: isDifferent
                            )
                        )
                    )
            }
            RiffaHairline(.vertical)
                .frame(height: 16)
                .padding(.horizontal, 6)
            Text(ascii(bytes))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(theme.inkSubtle)
                .frame(width: 122, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(width: 594, alignment: .leading)
    }

    private func ascii(_ bytes: [UInt8]) -> String {
        String(bytes.map { byte in
            (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : Character("·")
        })
    }

    private func byteAccessibilityLabel(
        marker: String,
        value: String,
        isDifferent: Bool
    ) -> String {
        guard isDifferent else {
            return String(
                localized: "byte \(value)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        if marker == "−" {
            return String(
                localized: "left byte \(value), changed",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "right byte \(value), changed",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }
}

private struct HexPathButton: View {
    let title: String
    let url: URL?
    let action: () -> Void

    var body: some View {
        RiffaResourcePathButton(
            title: title,
            url: url,
            emptyTitle: "Choose a binary file…",
            systemImage: "number.square",
            accessibilityHint: "Choose a local binary file",
            action: action
        )
        .accessibilityValue(
            url?.path(percentEncoded: false)
                ?? RiffaLocalization.string("No binary file selected")
        )
    }
}
