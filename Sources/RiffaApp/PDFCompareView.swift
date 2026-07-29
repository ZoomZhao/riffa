import AppKit
import Foundation
@preconcurrency import PDFKit
import RiffaCore
import SwiftUI
import UniformTypeIdentifiers

/// PDFKit is not reliably re-entrant across independent documents on every
/// supported macOS build. A single actor keeps superseded and current parses
/// serialized while the UI remains responsive.
private actor PDFComparisonWorker {
    func compare(leftURL: URL, rightURL: URL) throws -> PDFComparisonResult {
        try PDFComparisonEngine().compare(leftURL: leftURL, rightURL: rightURL)
    }

    /// All PDFKit parsing, including preview parsing, stays on this one actor.
    /// The source is re-read with the Core byte limit and fingerprint check;
    /// only then is that exact `Data` parsed and rendered to a bounded PNG.
    func renderPreviewPage(
        url: URL,
        side: PDFComparisonSide,
        matching snapshot: PDFDocumentSnapshot,
        pageNumber: Int
    ) throws -> Data {
        try Task.checkCancellation()
        let sourceData = try PDFComparisonEngine().verifiedPreviewData(
            url: url,
            side: side,
            matching: snapshot
        )
        try Task.checkCancellation()

        guard let document = PDFDocument(data: sourceData),
              document.pageCount >= pageNumber,
              let page = document.page(at: pageNumber - 1) else {
            throw PDFComparisonError.corrupted(side: side)
        }

        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else {
            throw PDFComparisonError.corrupted(side: side)
        }

        // Keep each decoded preview under roughly 10 MiB before compression.
        let maximumDimension = 1_600.0
        let scale = maximumDimension / max(bounds.width, bounds.height)
        let targetSize = CGSize(
            width: max(1, (bounds.width * scale).rounded()),
            height: max(1, (bounds.height * scale).rounded())
        )
        let image = page.thumbnail(of: targetSize, for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PDFComparisonError.corrupted(side: side)
        }
        try Task.checkCancellation()
        return png
    }

    /// Reads and renders only the selected page. Each source `Data` and its
    /// CGPDF objects live in a separate autorelease-pool scope, so the two
    /// bounded document buffers are never retained together. Both sources are
    /// verified against the original comparison snapshots again after the
    /// sequential renders, failing closed if either input changed meanwhile.
    func compareVisualPage(
        leftURL: URL,
        rightURL: URL,
        leftDocument: PDFDocumentSnapshot,
        rightDocument: PDFDocumentSnapshot,
        leftPage: PDFPageSnapshot,
        rightPage: PDFPageSnapshot,
        pageNumber: Int,
        channelTolerance: UInt8,
        limits: PDFVisualComparisonLimits = .standard
    ) throws -> PDFVisualPageComparisonResult {
        try Task.checkCancellation()
        let comparator = PDFVisualPageComparator(limits: limits)
        let canvas = try comparator.makeCanvasPlan(
            left: leftPage.dimensions,
            right: rightPage.dimensions
        )
        try Task.checkCancellation()

        let leftRaster = try renderVisualSide(
            url: leftURL,
            side: .left,
            documentSnapshot: leftDocument,
            pageSnapshot: leftPage,
            pageNumber: pageNumber,
            canvas: canvas,
            limits: limits
        )
        try Task.checkCancellation()
        let rightRaster = try renderVisualSide(
            url: rightURL,
            side: .right,
            documentSnapshot: rightDocument,
            pageSnapshot: rightPage,
            pageNumber: pageNumber,
            canvas: canvas,
            limits: limits
        )
        try Task.checkCancellation()

        // Close the interval between the sequential renders. These reads are
        // bounded and discarded immediately; no PDF parser is constructed.
        try verifyVisualSource(
            url: leftURL,
            side: .left,
            matching: leftDocument
        )
        try Task.checkCancellation()
        try verifyVisualSource(
            url: rightURL,
            side: .right,
            matching: rightDocument
        )
        try Task.checkCancellation()

        // ImageComparison is synchronous, but the canvas is strictly capped at
        // 1.44M pixels by default. Cancellation is checked immediately before
        // and after that bounded loop.
        let result = try comparator.compareCheckingCancellation(
            left: leftRaster,
            right: rightRaster,
            pageNumber: pageNumber,
            canvas: canvas,
            channelTolerance: channelTolerance
        )
        try Task.checkCancellation()
        return result
    }

    private func renderVisualSide(
        url: URL,
        side: PDFComparisonSide,
        documentSnapshot: PDFDocumentSnapshot,
        pageSnapshot: PDFPageSnapshot,
        pageNumber: Int,
        canvas: PDFVisualCanvasPlan,
        limits: PDFVisualComparisonLimits
    ) throws -> PDFVisualRaster {
        try autoreleasepool {
            try Task.checkCancellation()
            let sourceData = try PDFComparisonEngine().verifiedPreviewData(
                url: url,
                side: side,
                matching: documentSnapshot
            )
            try Task.checkCancellation()
            let raster = try PDFVisualPageRasterizer(limits: limits).render(
                documentData: sourceData,
                side: side,
                pageNumber: pageNumber,
                expectedDimensions: pageSnapshot.dimensions,
                expectedRotationDegrees: pageSnapshot.rotationDegrees,
                canvas: canvas
            )
            try Task.checkCancellation()
            return raster
        }
    }

    private func verifyVisualSource(
        url: URL,
        side: PDFComparisonSide,
        matching snapshot: PDFDocumentSnapshot
    ) throws {
        try autoreleasepool {
            try Task.checkCancellation()
            _ = try PDFComparisonEngine().verifiedPreviewData(
                url: url,
                side: side,
                matching: snapshot
            )
            try Task.checkCancellation()
        }
    }
}

/// Shared by every PDF comparison window so PDFKit work is serialized across
/// comparisons and previews rather than merely within one view model.
private let pdfComparisonWorker = PDFComparisonWorker()

@MainActor
private final class PDFCompareModel: ObservableObject {
    enum Side {
        case left
        case right
    }

    enum DetailMode: String, CaseIterable, Identifiable {
        case pages = "Pages"
        case text = "Text"
        case visual = "Visual"
        case metadata = "Metadata"

        var id: Self { self }
    }

    enum VisualZoomMode: String, CaseIterable, Identifiable {
        case fit = "Fit"
        case fixed = "Fixed"

        var id: Self { self }
    }

    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var result: PDFComparisonResult?
    @Published private(set) var isLoading = false
    @Published var selectedPageNumber: Int? {
        didSet {
            if selectedPageNumber != oldValue {
                requestVisualComparisonIfNeeded()
            }
        }
    }
    @Published var detailMode: DetailMode = .pages {
        didSet {
            guard detailMode != oldValue else { return }
            if detailMode == .visual {
                requestVisualComparisonIfNeeded()
            } else {
                cancelVisualComparison(clearResult: true)
            }
        }
    }
    @Published var showDifferencesOnly = false {
        didSet { selectVisiblePageIfNeeded() }
    }
    @Published private(set) var visualResult: PDFVisualPageComparisonResult?
    @Published private(set) var visualLeftImage: NSImage?
    @Published private(set) var visualRightImage: NSImage?
    @Published private(set) var visualDifferenceImage: NSImage?
    @Published private(set) var isVisualLoading = false
    @Published private(set) var visualErrorMessage: String?
    @Published var visualTolerance = Double(PDFVisualPageComparator.defaultChannelTolerance) {
        didSet {
            if visualTolerance != oldValue {
                requestVisualComparisonIfNeeded()
            }
        }
    }
    @Published var visualZoomMode: VisualZoomMode = .fit
    @Published private(set) var visualZoomScale = 1.0
    @Published var errorMessage: String?

    private var comparisonTask: Task<Void, Never>?
    private var visualTask: Task<Void, Never>?
    private var visualGeneration = UUID()

    var visiblePages: [PDFPageComparison] {
        guard let result else { return [] }
        return showDifferencesOnly
            ? result.pages.filter { $0.status != .same }
            : result.pages
    }

    var selectedPage: PDFPageComparison? {
        guard let selectedPageNumber else { return nil }
        return result?.pages.first { $0.pageNumber == selectedPageNumber }
    }

    func choosePDF(for side: Side) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        panel.title = side == .left
            ? RiffaLocalization.string("Choose Left PDF")
            : RiffaLocalization.string("Choose Right PDF")
        panel.prompt = RiffaLocalization.string("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        replaceInput(with: url, for: side)
    }

    func replaceInput(with url: URL, for side: Side) {
        setURL(url, for: side)
    }

    func openInitial(_ urls: [URL], options: [String: String] = [:]) {
        if let value = options.riffaDouble(for: "visualTolerance"),
           value.isFinite,
           (0...255).contains(value) {
            visualTolerance = value.rounded()
        }
        if let value = options["visualZoomMode"].flatMap(VisualZoomMode.init(rawValue:)) {
            visualZoomMode = value
        }
        if let value = options.riffaDouble(for: "visualZoomScale"), value.isFinite {
            let restoredMode = visualZoomMode
            setVisualZoom(value)
            visualZoomMode = restoredMode
        }
        if let value = options["detailMode"].flatMap(DetailMode.init(rawValue:)) {
            detailMode = value
        }
        if let value = options.riffaBoolean(for: "showDifferencesOnly") {
            showDifferencesOnly = value
        }

        leftURL = urls.first
        rightURL = urls.count > 1 ? urls[1] : nil
        compareIfReady()
    }

    func swapSides() {
        let previousLeftURL = leftURL
        leftURL = rightURL
        rightURL = previousLeftURL
        compareIfReady()
    }

    func retryVisualComparison() {
        requestVisualComparisonIfNeeded()
    }

    func useVisualFitZoom() {
        visualZoomMode = .fit
    }

    func useVisualActualSize() {
        setVisualZoom(1)
    }

    func zoomVisualIn() {
        let base = visualZoomMode == .fit ? 1 : visualZoomScale
        setVisualZoom(base * 1.25)
    }

    func zoomVisualOut() {
        let base = visualZoomMode == .fit ? 1 : visualZoomScale
        setVisualZoom(base / 1.25)
    }

    func setVisualZoom(_ proposedScale: Double) {
        guard proposedScale.isFinite else { return }
        visualZoomScale = min(max(proposedScale, 0.05), 8)
        visualZoomMode = .fixed
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
        panel.title = RiffaLocalization.string("Export PDF Comparison Report")
        panel.prompt = RiffaLocalization.string("Export")
        panel.nameFieldStringValue = "Riffa-PDF-Report.\(fileExtension)"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            let report = try SpecializedComparisonReportGenerator().generate(
                pdf: result,
                format: format,
                leftLabel: leftURL?.lastPathComponent
                    ?? RiffaLocalization.string("Left"),
                rightLabel: rightURL?.lastPathComponent
                    ?? RiffaLocalization.string("Right")
            )
            try report.write(to: destinationURL, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = String(
                localized: "Could not export the PDF report: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
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
        cancelVisualComparison(clearResult: true)
        guard let leftURL, let rightURL else {
            result = nil
            selectedPageNumber = nil
            isLoading = false
            return
        }

        result = nil
        selectedPageNumber = nil
        isLoading = true
        errorMessage = nil
        comparisonTask = Task { [weak self] in
            do {
                let comparison = try await pdfComparisonWorker.compare(
                    leftURL: leftURL,
                    rightURL: rightURL
                )
                guard !Task.isCancelled, let self else { return }
                self.result = comparison
                self.isLoading = false
                self.selectVisiblePageIfNeeded()
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

    private func selectVisiblePageIfNeeded() {
        let visible = visiblePages
        guard !visible.isEmpty else {
            selectedPageNumber = nil
            return
        }
        if let selectedPageNumber,
           visible.contains(where: { $0.pageNumber == selectedPageNumber }) {
            return
        }
        selectedPageNumber = visible[0].pageNumber
    }

    private func requestVisualComparisonIfNeeded() {
        guard detailMode == .visual else { return }
        visualTask?.cancel()
        visualGeneration = UUID()
        let generation = visualGeneration

        guard let leftURL,
              let rightURL,
              let result,
              let page = selectedPage,
              let leftPage = page.left,
              let rightPage = page.right else {
            clearVisualResult()
            isVisualLoading = false
            if selectedPage != nil {
                visualErrorMessage = RiffaLocalization.string(
                    "Visual comparison requires this page to exist on both sides."
                )
            } else {
                visualErrorMessage = nil
            }
            return
        }

        clearVisualResult()
        visualErrorMessage = nil
        isVisualLoading = true
        let tolerance = UInt8(clamping: Int(visualTolerance.rounded()))
        visualTask = Task { [weak self] in
            do {
                let comparison = try await pdfComparisonWorker.compareVisualPage(
                    leftURL: leftURL,
                    rightURL: rightURL,
                    leftDocument: result.leftDocument,
                    rightDocument: result.rightDocument,
                    leftPage: leftPage,
                    rightPage: rightPage,
                    pageNumber: page.pageNumber,
                    channelTolerance: tolerance
                )
                try Task.checkCancellation()
                guard let self, self.visualGeneration == generation else { return }
                guard let leftImage = Self.image(from: comparison.left),
                      let rightImage = Self.image(from: comparison.right),
                      let differenceImage = Self.heatMap(from: comparison.differenceMask) else {
                    throw PDFVisualDisplayError.imageCreationFailed
                }
                try Task.checkCancellation()
                guard self.visualGeneration == generation else { return }
                self.visualLeftImage = leftImage
                self.visualRightImage = rightImage
                self.visualDifferenceImage = differenceImage
                self.visualResult = comparison
                self.isVisualLoading = false
                self.visualErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.visualGeneration == generation else { return }
                self.clearVisualResult()
                self.isVisualLoading = false
                self.visualErrorMessage = error.localizedDescription
            }
        }
    }

    private func cancelVisualComparison(clearResult: Bool) {
        visualTask?.cancel()
        visualTask = nil
        visualGeneration = UUID()
        isVisualLoading = false
        visualErrorMessage = nil
        if clearResult {
            clearVisualResult()
        }
    }

    private func clearVisualResult() {
        visualResult = nil
        visualLeftImage = nil
        visualRightImage = nil
        visualDifferenceImage = nil
    }

    private static func image(from raster: PDFVisualRaster) -> NSImage? {
        image(width: raster.width, height: raster.height, rgba8: raster.rgba8)
    }

    private static func heatMap(from mask: PDFVisualDifferenceMask) -> NSImage? {
        let (byteCount, overflow) = mask.values.count.multipliedReportingOverflow(by: 4)
        guard !overflow else { return nil }
        var rgba = Array(repeating: UInt8(255), count: byteCount)
        for (index, value) in mask.values.enumerated() {
            let offset = index * 4
            if value == 0 {
                rgba[offset] = 245
                rgba[offset + 1] = 247
                rgba[offset + 2] = 250
            } else {
                rgba[offset] = 255
                rgba[offset + 1] = 72
                rgba[offset + 2] = 48
            }
            rgba[offset + 3] = 255
        }
        return image(width: mask.width, height: mask.height, rgba8: rgba)
    }

    private static func image(width: Int, height: Int, rgba8: [UInt8]) -> NSImage? {
        let data = Data(rgba8) as CFData
        guard let provider = CGDataProvider(data: data),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
}

private enum PDFVisualDisplayError: LocalizedError {
    case imageCreationFailed

    var errorDescription: String? {
        RiffaLocalization.string(
            "The bounded visual result could not be displayed."
        )
    }
}

private struct PDFPageListItem: Identifiable {
    let page: PDFPageComparison
    var id: Int { page.pageNumber }
}

private struct PDFMetadataListItem: Identifiable {
    let row: MetadataComparisonRow
    var id: String { "\(row.key)#\(row.occurrenceIndex)" }
}

struct PDFCompareView: View {
    @StateObject private var model = PDFCompareModel()
    @Environment(\.riffaTheme) private var theme
    @State private var visualPanOffset = CGSize.zero
    @GestureState private var visualDragTranslation = CGSize.zero
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
            if model.isLoading {
                VStack(spacing: RiffaSpacing.md) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(theme.accent)
                        .accessibilityHidden(true)
                    Text("Reading and comparing PDF pages…")
                        .riffaText(.body)
                        .foregroundStyle(theme.inkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.canvas)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Reading and comparing PDF pages")
            } else if let result = model.result {
                resultView(result)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("PDF Compare")
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
            "PDF comparison error",
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
        .onChange(of: model.selectedPageNumber) { _, _ in
            visualPanOffset = .zero
        }
        .onChange(of: model.visualTolerance) { _, _ in
            visualPanOffset = .zero
        }
        .onChange(of: model.visualZoomMode) { _, _ in
            visualPanOffset = .zero
        }
        .onChange(of: model.visualZoomScale) { _, _ in
            visualPanOffset = .zero
        }
    }

    private var header: some View {
        RiffaComparisonHeader(
            title: "PDF Compare",
            subtitle: "Pages, extracted text, visual raster, and metadata"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .pdfComparison,
                    urls: [model.leftURL, model.rightURL].compactMap { $0 },
                    options: [
                        "detailMode": .string(model.detailMode.rawValue),
                        "showDifferencesOnly": .boolean(model.showDifferencesOnly),
                        "visualTolerance": .decimal(Decimal(model.visualTolerance)),
                        "visualZoomMode": .string(model.visualZoomMode.rawValue),
                        "visualZoomScale": .decimal(Decimal(model.visualZoomScale))
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
            .accessibilityLabel("Export PDF comparison report")
            .accessibilityHint("Choose HTML, plain text, or JSON")
            .help("Export a self-contained PDF comparison report")
            .disabled(model.result == nil || model.isLoading)
        }
    }

    private var controlBar: some View {
        RiffaComparisonControlBar {
            Picker("Detail", selection: $model.detailMode) {
                ForEach(PDFCompareModel.DetailMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 390)
            .accessibilityLabel("PDF detail mode")
            .accessibilityHint("Choose pages, extracted text, visual raster, or metadata")

            Toggle("Differences", isOn: $model.showDifferencesOnly)
                .toggleStyle(.checkbox)
                .disabled(model.result == nil)
                .accessibilityLabel("Show PDF differences only")
                .accessibilityHint("Hides pages whose structural and text status is unchanged")

            if let page = model.selectedPage {
                RiffaStatusBadge(
                    "Page \(page.pageNumber) · \(pdfPageStatusTitle(page.status))",
                    systemImage: pdfPageStatusSymbol(page.status),
                    tone: pdfPageStatusTone(page.status)
                )
            } else if model.result != nil, model.detailMode == .metadata {
                RiffaStatusBadge(
                    "Document metadata",
                    systemImage: "list.bullet.rectangle"
                )
            }
        }
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            RiffaResourcePathButton(
                title: "Left PDF",
                url: model.leftURL,
                emptyTitle: "Choose a PDF…",
                systemImage: "doc.richtext",
                accessibilityHint: "Choose the left PDF document"
            ) {
                model.choosePDF(for: .left)
            }
            .riffaResourceDropTarget(
                role: .left,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .left)
            }
            Button {
                model.swapSides()
            } label: {
                Label("Swap PDFs", systemImage: "arrow.left.arrow.right")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Swap PDF documents")
            .accessibilityHint("Exchanges the left and right PDF inputs")
            .help("Swap PDFs")
            .disabled(model.leftURL == nil && model.rightURL == nil)

            RiffaResourcePathButton(
                title: "Right PDF",
                url: model.rightURL,
                emptyTitle: "Choose a PDF…",
                systemImage: "doc.richtext",
                accessibilityHint: "Choose the right PDF document"
            ) {
                model.choosePDF(for: .right)
            }
            .riffaResourceDropTarget(
                role: .right,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .right)
            }
        }
    }

    private func resultView(_ result: PDFComparisonResult) -> some View {
        VStack(spacing: 0) {
            HSplitView {
                pageNavigator(result)
                    .frame(minWidth: 205, idealWidth: 240, maxWidth: 310)
                VStack(spacing: 0) {
                    detailToolbar
                    detail(result)
                }
                .frame(minWidth: 560)
            }
            .background(theme.canvas)
            statusBar(result)
        }
    }

    private func pageNavigator(_ result: PDFComparisonResult) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pages")
                    .riffaText(.body)
                    .foregroundStyle(theme.ink)
                Spacer()
                Text("\(model.visiblePages.count)/\(result.pages.count)")
                    .riffaText(.caption)
                    .foregroundStyle(theme.inkSubtle)
            }
            .padding(.horizontal, RiffaSpacing.sm)
            .frame(minHeight: 40)
            .background(theme.surface(.one))
            .overlay(alignment: .bottom) {
                RiffaHairline()
            }

            List(selection: $model.selectedPageNumber) {
                ForEach(model.visiblePages.map(PDFPageListItem.init)) { item in
                    PDFPageRow(page: item.page)
                        .tag(item.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.surface(.one))
            .accessibilityLabel("PDF page comparison results")
            .accessibilityHint("Select a page to inspect it in the current detail mode")
        }
        .background(theme.surface(.one))
    }

    private var detailToolbar: some View {
        RiffaPaneHeader(
            detailTitle,
            subtitle: detailSubtitle,
            systemImage: detailSystemImage
        ) {
            if let page = model.selectedPage,
               model.detailMode != .metadata {
                RiffaStatusBadge(
                    verbatim: pdfPageStatusTitle(page.status),
                    systemImage: pdfPageStatusSymbol(page.status),
                    tone: pdfPageStatusTone(page.status)
                )
            }
        }
    }

    @ViewBuilder
    private func detail(_ result: PDFComparisonResult) -> some View {
        switch model.detailMode {
        case .pages:
            if let page = model.selectedPage {
                pagePreview(page)
            } else {
                noVisiblePages
            }
        case .text:
            if let page = model.selectedPage {
                pageText(page)
            } else {
                noVisiblePages
            }
        case .visual:
            if let page = model.selectedPage {
                visualDetail(page)
            } else {
                noVisiblePages
            }
        case .metadata:
            metadataTable(result.metadataComparison)
        }
    }

    private func pagePreview(_ page: PDFPageComparison) -> some View {
        HSplitView {
            PDFPreviewPane(
                title: model.leftURL?.lastPathComponent
                    ?? RiffaLocalization.string("Left"),
                url: model.leftURL,
                side: .left,
                documentSnapshot: resultDocumentSnapshot(for: .left),
                pageNumber: page.pageNumber,
                snapshot: page.left,
                paneNumber: 1
            )
            PDFPreviewPane(
                title: model.rightURL?.lastPathComponent
                    ?? RiffaLocalization.string("Right"),
                url: model.rightURL,
                side: .right,
                documentSnapshot: resultDocumentSnapshot(for: .right),
                pageNumber: page.pageNumber,
                snapshot: page.right,
                paneNumber: 2
            )
        }
        .background(theme.canvas)
    }

    private func resultDocumentSnapshot(for side: PDFComparisonSide) -> PDFDocumentSnapshot? {
        guard let result = model.result else { return nil }
        switch side {
        case .left: return result.leftDocument
        case .right: return result.rightDocument
        }
    }

    @ViewBuilder
    private func pageText(_ page: PDFPageComparison) -> some View {
        if let comparison = page.textComparison {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 1) {
                    ForEach(comparison.lines, id: \.offset) { line in
                        PDFTextComparisonRow(line: line)
                    }
                }
                .padding(8)
                .frame(minWidth: 760, alignment: .leading)
            }
            .background(theme.canvas)
            .accessibilityLabel("Aligned PDF extracted text differences")
        } else {
            HSplitView {
                PDFExtractedTextPane(
                    title: "Left extracted text",
                    text: page.left?.extractedText
                )
                PDFExtractedTextPane(
                    title: "Right extracted text",
                    text: page.right?.extractedText
                )
            }
            .background(theme.canvas)
        }
    }

    private func metadataTable(_ comparison: MetadataComparisonResult) -> some View {
        Table(comparison.rows.map(PDFMetadataListItem.init)) {
            TableColumn("Status") { item in
                PDFMetadataStatusLabel(status: item.row.status)
            }
            .width(min: 104, ideal: 118, max: 138)
            TableColumn("Field") { item in
                Text(LocalizedStringKey(item.row.displayName))
                    .riffaText(.bodySmall)
            }
            .width(min: 150, ideal: 210)
            TableColumn("Left") { item in
                Text(item.row.left.map { metadataValueText($0.value) } ?? "—")
                    .riffaText(.mono)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            .width(min: 190, ideal: 300)
            TableColumn("Right") { item in
                Text(item.row.right.map { metadataValueText($0.value) } ?? "—")
                    .riffaText(.mono)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            .width(min: 190, ideal: 300)
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .accessibilityLabel("PDF metadata comparison")
    }

    private func visualDetail(_ page: PDFPageComparison) -> some View {
        VStack(spacing: 0) {
            visualControls
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(theme.inkSubtle)
                    .accessibilityHidden(true)
                Text("On-demand visual comparison covers selected page \(page.pageNumber) only. It does not change page/text status and is not included in exported whole-document reports.")
                Spacer()
            }
            .riffaText(.caption)
            .foregroundStyle(theme.inkSubtle)
            .padding(.horizontal, RiffaSpacing.sm)
            .frame(minHeight: 36)
            .background(theme.surface(.two))
            .overlay(alignment: .bottom) {
                RiffaHairline()
            }
            .accessibilityElement(children: .combine)

            if model.isVisualLoading {
                VStack(spacing: RiffaSpacing.md) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(theme.accent)
                        .accessibilityHidden(true)
                    Text("Verifying and rendering selected page…")
                        .riffaText(.body)
                        .foregroundStyle(theme.inkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.canvas)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Verifying and rendering the selected PDF page")
            } else if let errorMessage = model.visualErrorMessage {
                RiffaEmptyState(
                    title: "Visual comparison unavailable",
                    description: errorMessage,
                    systemImage: "exclamationmark.triangle"
                ) {
                    Button("Try Again") { model.retryVisualComparison() }
                        .buttonStyle(.riffaPrimary)
                        .accessibilityHint("Verifies and renders the selected page again")
                }
            } else if let result = model.visualResult {
                visualComparison(result)
            } else {
                RiffaEmptyState(
                    title: "Visual comparison is on demand",
                    description: "Render this selected page on both sides using bounded local resources.",
                    systemImage: "viewfinder"
                ) {
                    Button("Compare This Page") { model.retryVisualComparison() }
                        .buttonStyle(.riffaPrimary)
                        .accessibilityHint("Renders and compares only the selected PDF page")
                }
            }
        }
        .background(theme.canvas)
    }

    private var visualControls: some View {
        RiffaComparisonControlBar {
            Text("Tolerance \(Int(model.visualTolerance))")
                .riffaText(.caption)
                .foregroundStyle(theme.inkMuted)
                .frame(width: 78, alignment: .leading)
            Slider(value: $model.visualTolerance, in: 0...255, step: 1)
                .frame(width: 145)
                .help("RGB channel tolerance; 8 is friendly to antialiasing noise")
                .accessibilityLabel("PDF visual comparison tolerance")
                .accessibilityValue("\(Int(model.visualTolerance))")

            RiffaHairline(.vertical)
                .frame(height: 20)

            Button("Fit") { model.useVisualFitZoom() }
                .buttonStyle(.riffaTertiary)
                .help("Fit all three panes using one shared scale")
                .accessibilityHint("Fits all three visual panes using one shared scale")

            Button { model.zoomVisualOut() } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Zoom visual comparison out")
            .accessibilityHint("Reduces the shared visual page scale")

            Slider(
                value: Binding(
                    get: { model.visualZoomScale },
                    set: { model.setVisualZoom($0) }
                ),
                in: 0.05...8
            )
            .frame(width: 125)
            .accessibilityLabel("Visual comparison zoom")
            .accessibilityValue(
                Text(
                    verbatim: model.visualZoomMode == .fit
                        ? RiffaLocalization.string("Fit")
                        : visualZoomPercentage
                )
            )

            Button { model.zoomVisualIn() } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Zoom visual comparison in")
            .accessibilityHint("Increases the shared visual page scale")

            Button {
                model.useVisualActualSize()
            } label: {
                Text(
                    verbatim: model.visualZoomMode == .fit
                        ? RiffaLocalization.string("Fit")
                        : visualZoomPercentage
                )
            }
            .buttonStyle(.riffaTertiary)
            .help("Show the bounded raster at 100%")
            .accessibilityHint("Uses one hundred percent scale")

            Spacer()
            Text("Shared scale + pan")
                .riffaText(.caption)
                .foregroundStyle(theme.inkSubtle)
        }
    }

    private var visualZoomPercentage: String {
        String(format: "%.0f%%", model.visualZoomScale * 100)
    }

    private var visualViewportAccessibilityValue: String {
        if model.visualZoomMode == .fit {
            return RiffaLocalization.string(
                "Three numbered panes, fit using one shared scale"
            )
        }
        return String(
            localized: "Three numbered panes, \(visualZoomPercentage), shared pan position",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func visualPaneAccessibilityLabel(
        paneNumber: Int,
        label: String
    ) -> String {
        let localizedLabel = RiffaLocalization.string(label)
        return String(
            localized: "\(paneNumber), \(localizedLabel) selected-page raster",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func visualComparison(_ result: PDFVisualPageComparisonResult) -> some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let scale = visualViewportScale(for: proxy.size)
                let paneWidth = max(1, (proxy.size.width - 2) / 3)
                let imageViewportSize = CGSize(
                    width: paneWidth,
                    height: max(1, proxy.size.height - 30)
                )
                let proposedPan = CGSize(
                    width: visualPanOffset.width + visualDragTranslation.width,
                    height: visualPanOffset.height + visualDragTranslation.height
                )
                let displayedPan = clampedVisualPan(
                    proposedPan,
                    imageSize: model.visualLeftImage?.size ?? .zero,
                    viewportSize: imageViewportSize,
                    scale: scale
                )

                HStack(spacing: 0) {
                    visualImagePane(
                        model.visualLeftImage,
                        label: "LEFT",
                        paneNumber: 1,
                        isDifference: false,
                        scale: scale,
                        panOffset: displayedPan
                    )
                    .frame(width: paneWidth)
                    RiffaHairline(.vertical)
                    visualImagePane(
                        model.visualRightImage,
                        label: "RIGHT",
                        paneNumber: 2,
                        isDifference: false,
                        scale: scale,
                        panOffset: displayedPan
                    )
                    .frame(width: paneWidth)
                    RiffaHairline(.vertical)
                    visualImagePane(
                        model.visualDifferenceImage,
                        label: "DIFFERENCE MASK",
                        paneNumber: 3,
                        isDifference: true,
                        scale: scale,
                        panOffset: displayedPan
                    )
                    .frame(width: paneWidth)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(theme.canvas)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .updating($visualDragTranslation) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            visualPanOffset = clampedVisualPan(
                                CGSize(
                                    width: visualPanOffset.width + value.translation.width,
                                    height: visualPanOffset.height + value.translation.height
                                ),
                                imageSize: model.visualLeftImage?.size ?? .zero,
                                viewportSize: imageViewportSize,
                                scale: scale
                            )
                        }
                )
                .accessibilityLabel("Synchronized PDF visual comparison viewport")
                .accessibilityValue(
                    Text(verbatim: visualViewportAccessibilityValue)
                )
            }
            visualStatistics(result)
        }
        .background(theme.canvas)
    }

    private func visualImagePane(
        _ image: NSImage?,
        label: String,
        paneNumber: Int,
        isDifference: Bool,
        scale: CGFloat,
        panOffset: CGSize
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("\(paneNumber)")
                    .riffaText(.caption)
                    .foregroundStyle(
                        isDifference ? theme.warning : theme.inkMuted
                    )
                    .frame(width: 20, height: 20)
                    .background(
                        theme.surface(.two),
                        in: RoundedRectangle(cornerRadius: RiffaRadius.xs)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: RiffaRadius.xs)
                            .strokeBorder(
                                isDifference ? theme.warning : theme.hairlineStrong,
                                lineWidth: 1
                            )
                    }
                Text(LocalizedStringKey(label))
                    .riffaText(.eyebrow)
                    .foregroundStyle(theme.inkMuted)
                if isDifference {
                    Text("Outlined changed pixels")
                        .riffaText(.caption)
                        .foregroundStyle(theme.inkSubtle)
                }
                Spacer()
            }
            .padding(.horizontal, RiffaSpacing.xs)
            .frame(minHeight: 34)
            .background(theme.surface(.one))
            .overlay(alignment: .bottom) {
                RiffaHairline()
            }

            GeometryReader { proxy in
                ZStack {
                    theme.canvas
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(scale >= 1 ? .none : .medium)
                            .frame(
                                width: max(1, image.size.width * scale),
                                height: max(1, image.size.height * scale)
                            )
                            .overlay {
                                Rectangle().stroke(
                                    isDifference ? theme.warning : theme.hairlineStrong,
                                    lineWidth: isDifference ? 2 : 1
                                )
                            }
                            .offset(x: panOffset.width, y: panOffset.height)
                            .accessibilityLabel(
                                Text(
                                    verbatim: visualPaneAccessibilityLabel(
                                        paneNumber: paneNumber,
                                        label: label
                                    )
                                )
                            )
                            .accessibilityHint(
                                Text(
                                    verbatim: isDifference
                                        ? RiffaLocalization.string(
                                            "Non-matching pixels are shown inside the numbered difference pane"
                                        )
                                        : RiffaLocalization.string(
                                            "Pan and zoom are synchronized with the other PDF visual panes"
                                        )
                                )
                            )
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
            }
        }
        .clipped()
        .accessibilityElement(children: .contain)
    }

    private func visualViewportScale(for availableSize: CGSize) -> CGFloat {
        guard model.visualZoomMode == .fit else {
            return CGFloat(model.visualZoomScale)
        }
        guard let size = model.visualLeftImage?.size,
              size.width > 0,
              size.height > 0 else {
            return 1
        }
        let paneWidth = max(1, (availableSize.width - 2) / 3 - 24)
        let paneHeight = max(1, availableSize.height - 54)
        let scale = min(paneWidth / size.width, paneHeight / size.height)
        guard scale.isFinite, scale > 0 else { return 1 }
        return scale
    }

    private func clampedVisualPan(
        _ proposed: CGSize,
        imageSize: CGSize,
        viewportSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard scale.isFinite,
              scale > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return .zero
        }
        let horizontalLimit = max(0, (imageSize.width * scale - viewportSize.width) / 2)
        let verticalLimit = max(0, (imageSize.height * scale - viewportSize.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -horizontalLimit), horizontalLimit),
            height: min(max(proposed.height, -verticalLimit), verticalLimit)
        )
    }

    private func visualStatistics(_ result: PDFVisualPageComparisonResult) -> some View {
        let mismatch = String(
            localized: "Δ \(result.mismatchRatio * 100, format: .number.precision(.fractionLength(2)))% mismatch",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        let statusTitle = result.hasPixelDifferences
            ? mismatch
            : RiffaLocalization.string("No visual differences")
        return RiffaStatusBar {
            RiffaStatusBadge(
                verbatim: statusTitle,
                systemImage: result.hasPixelDifferences
                    ? RiffaIcon.notEqual
                    : "checkmark.circle.fill",
                tone: result.hasPixelDifferences ? .warning : .success
            )
            Text("\(result.mismatchedPixelCount) of \(result.comparedPixelCount) pixels")
            Text("max Δ \(result.maximumChannelDifference)")
            Text(
                verbatim: String(
                    localized: "mean Δ \(result.averageChannelDifference, format: .number.precision(.fractionLength(2)))",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            )
            if let bounds = result.mismatchBounds {
                RiffaStatusBadge(
                    "Region 3 · \(bounds.x),\(bounds.y) \(bounds.width)×\(bounds.height)",
                    systemImage: "viewfinder",
                    tone: .warning
                )
            }
            Spacer()
            Text("\(result.canvas.width)×\(result.canvas.height) RGBA8")
                .riffaText(.mono)
                .foregroundStyle(theme.inkTertiary)
        }
    }

    private var noVisiblePages: some View {
        RiffaEmptyState(
            title: "No pages to show",
            description: model.showDifferencesOnly
                ? RiffaLocalization.string(
                    "The current filter hides unchanged pages."
                )
                : RiffaLocalization.string(
                    "This comparison has no page rows."
                ),
            systemImage: "doc.text.magnifyingglass"
        ) {
            if model.showDifferencesOnly {
                Button("Show All Pages") {
                    model.showDifferencesOnly = false
                }
                .buttonStyle(.riffaSecondary)
                .accessibilityHint("Includes unchanged pages in the page navigator")
            }
        }
    }

    private func statusBar(_ result: PDFComparisonResult) -> some View {
        RiffaStatusBar {
            RiffaStatusBadge(
                "= \(result.statistics.samePageCount) same",
                systemImage: "equal"
            )
            RiffaStatusBadge(
                "Δ \(result.statistics.changedPageCount) changed",
                systemImage: RiffaIcon.notEqual,
                tone: result.statistics.changedPageCount > 0 ? .warning : .neutral
            )
            RiffaStatusBadge(
                "− \(result.statistics.leftOnlyPageCount) left only",
                systemImage: "arrow.left",
                tone: result.statistics.leftOnlyPageCount > 0 ? .danger : .neutral
            )
            RiffaStatusBadge(
                "+ \(result.statistics.rightOnlyPageCount) right only",
                systemImage: "arrow.right",
                tone: result.statistics.rightOnlyPageCount > 0 ? .success : .neutral
            )
            Spacer()
            Text("\(result.leftDocument.pageCount) ↔ \(result.rightDocument.pageCount) pages")
                .riffaText(.mono)
                .foregroundStyle(theme.inkTertiary)
        }
    }

    private var emptyState: some View {
        RiffaEmptyState(
            title: "Choose two PDF documents",
            description: "Riffa compares page structure, extracted text, dimensions, rotation, labels, and public metadata locally.",
            systemImage: "doc.richtext"
        ) {
            HStack(spacing: RiffaSpacing.xs) {
                Button("Choose Left") {
                    model.choosePDF(for: .left)
                }
                .buttonStyle(.riffaSecondary)
                .accessibilityLabel("Choose left PDF")
                .accessibilityHint("Opens a local PDF file picker")

                Button("Choose Right") {
                    model.choosePDF(for: .right)
                }
                .buttonStyle(.riffaSecondary)
                .accessibilityLabel("Choose right PDF")
                .accessibilityHint("Opens a local PDF file picker")
            }
        }
    }

    private var detailTitle: String {
        switch model.detailMode {
        case .pages:
            if let pageNumber = model.selectedPage?.pageNumber {
                String(
                    localized: "Page \(pageNumber) preview",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            } else {
                RiffaLocalization.string("Page preview")
            }
        case .text:
            if let pageNumber = model.selectedPage?.pageNumber {
                String(
                    localized: "Page \(pageNumber) extracted text",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            } else {
                RiffaLocalization.string("Extracted text")
            }
        case .visual:
            if let pageNumber = model.selectedPage?.pageNumber {
                String(
                    localized: "Page \(pageNumber) visual comparison",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                )
            } else {
                RiffaLocalization.string("Visual comparison")
            }
        case .metadata:
            RiffaLocalization.string("Document metadata")
        }
    }

    private var detailSubtitle: String? {
        switch model.detailMode {
        case .pages:
            RiffaLocalization.string("Synchronized bounded previews")
        case .text:
            RiffaLocalization.string("Aligned lines use Δ, −, and + markers")
        case .visual:
            RiffaLocalization.string(
                "Numbered source and difference panes share scale and pan"
            )
        case .metadata:
            RiffaLocalization.string(
                "Public document properties compared field by field"
            )
        }
    }

    private var detailSystemImage: String {
        switch model.detailMode {
        case .pages: "doc.on.doc"
        case .text: "text.alignleft"
        case .visual: "viewfinder"
        case .metadata: "list.bullet.rectangle"
        }
    }
}

private struct PDFPageRow: View {
    let page: PDFPageComparison
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(spacing: RiffaSpacing.xs) {
            Image(systemName: pdfPageStatusSymbol(page.status))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(statusColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Page \(page.pageNumber)")
                    .riffaText(.bodySmall)
                    .foregroundStyle(theme.ink)
                Text(detailText)
                    .riffaText(.caption)
                    .foregroundStyle(theme.inkSubtle)
                    .lineLimit(1)
            }
            Spacer()
            Text(pdfPageStatusMarker(page.status))
                .riffaText(.mono)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
        }
        .padding(.vertical, RiffaSpacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Page \(page.pageNumber), \(pdfPageStatusTitle(page.status)), \(detailText)"
        )
        .accessibilityHint("Select to inspect this page")
    }

    private var detailText: String {
        if page.differences.isEmpty {
            return switch page.status {
            case .same: RiffaLocalization.string("Unchanged")
            case .leftOnly: RiffaLocalization.string("Left only")
            case .rightOnly: RiffaLocalization.string("Right only")
            case .changed: RiffaLocalization.string("Changed")
            }
        }
        return page.differences.map { difference in
            switch difference {
            case .dimensions: RiffaLocalization.string("size")
            case .rotation: RiffaLocalization.string("rotation")
            case .label: RiffaLocalization.string("label")
            case .text: RiffaLocalization.string("text")
            }
        }.joined(separator: ", ")
    }

    private var statusColor: Color {
        switch page.status {
        case .same: theme.inkSubtle
        case .changed: theme.warning
        case .leftOnly: theme.danger
        case .rightOnly: theme.success
        }
    }
}

private struct PDFPreviewPane: View {
    let title: String
    let url: URL?
    let side: PDFComparisonSide
    let documentSnapshot: PDFDocumentSnapshot?
    let pageNumber: Int
    let snapshot: PDFPageSnapshot?
    let paneNumber: Int
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            RiffaPaneHeader(
                String(
                    localized: "\(paneNumber) · \(sideTitle)",
                    bundle: RiffaLocalization.localizedBundle,
                    locale: RiffaLocalization.locale
                ),
                subtitle: title,
                systemImage: "doc.richtext"
            ) {
                if let snapshot {
                    Text("\(snapshot.dimensions.width, specifier: "%.0f") × \(snapshot.dimensions.height, specifier: "%.0f") pt")
                        .riffaText(.mono)
                        .foregroundStyle(theme.inkSubtle)
                }
            }

            if snapshot != nil, let url, let documentSnapshot {
                PDFPageView(
                    url: url,
                    side: side,
                    documentSnapshot: documentSnapshot,
                    pageNumber: pageNumber
                )
            } else {
                ContentUnavailableView(
                    "No page on this side",
                    systemImage: RiffaIcon.documentRemoved
                )
                .foregroundStyle(theme.inkMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.canvas)
            }
        }
        .background(theme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String(
                localized: "\(paneNumber), \(sideTitle) PDF page \(pageNumber)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        )
    }

    private var sideTitle: String {
        let key = switch side {
        case .left: "LEFT"
        case .right: "RIGHT"
        }
        return RiffaLocalization.string(key)
    }
}

private struct PDFPageView: View {
    let url: URL
    let side: PDFComparisonSide
    let documentSnapshot: PDFDocumentSnapshot
    let pageNumber: Int

    @Environment(\.riffaTheme) private var theme
    @State private var pngData: Data?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private struct RequestIdentity: Hashable {
        let url: URL
        let side: PDFComparisonSide
        let byteCount: Int
        let contentSHA256: String
        let pageNumber: Int
    }

    private var requestIdentity: RequestIdentity {
        RequestIdentity(
            url: url.standardizedFileURL,
            side: side,
            byteCount: documentSnapshot.fileByteCount,
            contentSHA256: documentSnapshot.contentSHA256,
            pageNumber: pageNumber
        )
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Verifying preview…")
                    .tint(theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pngData, let image = NSImage(data: pngData) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                        .overlay {
                            Rectangle()
                                .strokeBorder(theme.hairlineStrong, lineWidth: 1)
                                .padding(12)
                        }
                        .accessibilityLabel(
                            "\(sideAccessibilityTitle) PDF page \(pageNumber) preview"
                        )
                }
                .background(theme.canvas)
            } else {
                ProgressView()
                    .tint(theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.canvas)
        .task(id: requestIdentity) {
            // Drop the old compressed preview before allocating or reading the
            // next source. The actor drops source `Data` and `PDFDocument` as
            // soon as its bounded render returns.
            pngData = nil
            errorMessage = nil
            isLoading = true
            do {
                let rendered = try await pdfComparisonWorker.renderPreviewPage(
                    url: url,
                    side: side,
                    matching: documentSnapshot,
                    pageNumber: pageNumber
                )
                guard !Task.isCancelled else { return }
                pngData = rendered
                isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                pngData = nil
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private var sideAccessibilityTitle: String {
        switch side {
        case .left: RiffaLocalization.string("Left")
        case .right: RiffaLocalization.string("Right")
        }
    }
}

private struct PDFTextComparisonRow: View {
    let line: PDFTextLineComparison
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            textCell(line.left)

            RiffaHairline(.vertical)

            statusCell

            RiffaHairline(.vertical)

            textCell(line.right)
        }
        .riffaText(.mono)
        .foregroundStyle(theme.inkMuted)
        .padding(.vertical, 4)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if line.status != .same {
                Rectangle()
                    .fill(statusColor)
                    .frame(width: 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("The center marker \(statusMarker) identifies the difference without color")
    }

    private func textCell(_ value: PDFTextLineValue?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(value.map { String($0.lineNumber) } ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(theme.inkTertiary)
                .padding(.trailing, 7)
            Text(value?.content ?? "")
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCell: some View {
        VStack(spacing: 1) {
            Text(statusMarker)
                .riffaText(.mono)
            if line.status != .same {
                Text(verbatim: statusTitle.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(statusColor)
        .frame(width: 50)
        .frame(minHeight: 28)
        .background(theme.surface(.two))
        .accessibilityHidden(true)
    }

    private var accessibilitySummary: String {
        let missing = RiffaLocalization.string("missing")
        let leftLine = line.left.map { String($0.lineNumber) } ?? missing
        let leftText = line.left?.content ?? missing
        let rightLine = line.right.map { String($0.lineNumber) } ?? missing
        let rightText = line.right?.content ?? missing
        return String(
            localized: "\(statusTitle) PDF text row. Left line \(leftLine): \(leftText). Right line \(rightLine): \(rightText).",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private var rowBackground: Color {
        switch line.status {
        case .same: theme.canvas
        case .inserted: theme.success.opacity(0.10)
        case .deleted: theme.danger.opacity(0.10)
        case .modified: theme.warning.opacity(0.11)
        }
    }

    private var statusMarker: String {
        switch line.status {
        case .same: "="
        case .inserted: "+"
        case .deleted: "−"
        case .modified: "Δ"
        }
    }

    private var statusTitle: String {
        switch line.status {
        case .same: RiffaLocalization.string("Same")
        case .inserted: RiffaLocalization.string("Added")
        case .deleted: RiffaLocalization.string("Removed")
        case .modified: RiffaLocalization.string("Modified")
        }
    }

    private var statusColor: Color {
        switch line.status {
        case .same: theme.inkTertiary
        case .inserted: theme.success
        case .deleted: theme.danger
        case .modified: theme.warning
        }
    }
}

private struct PDFExtractedTextPane: View {
    let title: String
    let text: String?
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            RiffaPaneHeader(
                title,
                subtitle: "Read-only extracted text",
                systemImage: "text.alignleft"
            )
            ScrollView([.horizontal, .vertical]) {
                Text(
                    verbatim: text
                        ?? RiffaLocalization.string("No page on this side")
                )
                    .riffaText(.mono)
                    .foregroundStyle(theme.inkMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(RiffaSpacing.sm)
            }
            .background(theme.canvas)
        }
        .background(theme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(verbatim: RiffaLocalization.string(title))
        )
    }
}

private func metadataStatusTitle(_ status: MetadataComparisonStatus) -> String {
    switch status {
    case .same: RiffaLocalization.string("Same")
    case .different: RiffaLocalization.string("Different")
    case .leftOnly: RiffaLocalization.string("Left only")
    case .rightOnly: RiffaLocalization.string("Right only")
    }
}

private struct PDFMetadataStatusLabel: View {
    let status: MetadataComparisonStatus
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Label {
            Text(verbatim: metadataStatusTitle(status))
        } icon: {
            Image(systemName: symbol)
        }
            .riffaText(.caption)
            .foregroundStyle(color)
            .accessibilityLabel(metadataStatusTitle(status))
    }

    private var symbol: String {
        switch status {
        case .same: "equal"
        case .different: RiffaIcon.notEqual
        case .leftOnly: "arrow.left"
        case .rightOnly: "arrow.right"
        }
    }

    private var color: Color {
        switch status {
        case .same: theme.inkSubtle
        case .different: theme.warning
        case .leftOnly: theme.danger
        case .rightOnly: theme.success
        }
    }
}

private func pdfPageStatusTitle(_ status: PDFPageComparisonStatus) -> String {
    switch status {
    case .same: RiffaLocalization.string("Same")
    case .changed: RiffaLocalization.string("Changed")
    case .leftOnly: RiffaLocalization.string("Left only")
    case .rightOnly: RiffaLocalization.string("Right only")
    }
}

private func pdfPageStatusMarker(_ status: PDFPageComparisonStatus) -> String {
    switch status {
    case .same: "="
    case .changed: "Δ"
    case .leftOnly: "−"
    case .rightOnly: "+"
    }
}

private func pdfPageStatusSymbol(_ status: PDFPageComparisonStatus) -> String {
    switch status {
    case .same: "equal"
    case .changed: RiffaIcon.notEqual
    case .leftOnly: "arrow.left"
    case .rightOnly: "arrow.right"
    }
}

private func pdfPageStatusTone(_ status: PDFPageComparisonStatus) -> RiffaStatusTone {
    switch status {
    case .same: .neutral
    case .changed: .warning
    case .leftOnly: .danger
    case .rightOnly: .success
    }
}

private func metadataValueText(_ value: MetadataValue) -> String {
    switch value {
    case let .string(value): value
    case let .integer(value): String(value)
    case let .decimal(value): NSDecimalNumber(decimal: value).stringValue
    case let .boolean(value):
        RiffaLocalization.string(value ? "Yes" : "No")
    case let .date(value): value.formatted(date: .abbreviated, time: .standard)
    case let .data(value):
        String(
            localized: "\(value.byteCount) bytes · SHA-256 \(value.sha256)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    case .null: RiffaLocalization.string("Null")
    }
}
