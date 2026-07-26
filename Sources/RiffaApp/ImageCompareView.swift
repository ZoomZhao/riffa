import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RiffaCore
import SwiftUI

private enum ImageCompareLoadError: Error, LocalizedError {
    case missingImage
    case invalidDimensions
    case dimensionsTooLarge(width: Int, height: Int, pixelLimit: Int)

    var errorDescription: String? {
        switch self {
        case .missingImage:
            RiffaLocalization.string(
                "The file does not contain a decodable image."
            )
        case .invalidDimensions:
            RiffaLocalization.string(
                "The image declares invalid pixel dimensions."
            )
        case let .dimensionsTooLarge(width, height, pixelLimit):
            String(
                localized: "The image is \(width)×\(height) pixels; Riffa limits this in-memory comparison to \(pixelLimit) pixels per side.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }
}

@MainActor
private final class ImageCompareModel: ObservableObject {
    enum Side { case left, right }
    enum DisplayMode: String, CaseIterable, Identifiable {
        case sideBySide = "Side by Side"
        case blend = "Blend"
        case difference = "Difference"
        var id: Self { self }
    }
    enum ZoomMode: String, CaseIterable, Identifiable {
        case fit = "Fit"
        case fixed = "Fixed"

        var id: Self { self }
    }

    nonisolated private static let maximumEncodedByteCount = 128 * 1_024 * 1_024
    nonisolated private static let maximumPixelCount = 16 * 1_024 * 1_024
    nonisolated private static let maximumDimension = 32_768

    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var leftImage: NSImage?
    @Published private(set) var rightImage: NSImage?
    @Published private(set) var result: ImageComparisonResult?
    @Published private(set) var maskImage: NSImage?
    @Published var displayMode: DisplayMode = .sideBySide
    @Published var blendAmount = 0.5
    @Published var zoomMode: ZoomMode = .fit
    @Published private(set) var zoomScale = 1.0
    @Published var showsCheckerboard = true
    @Published var tolerance = 0.0 { didSet { compareIfReady() } }
    @Published var compareAlpha = true { didSet { compareIfReady() } }
    @Published var xOffset = 0 { didSet { compareIfReady() } }
    @Published var yOffset = 0 { didSet { compareIfReady() } }
    @Published var errorMessage: String?

    private var leftBuffer: RGBAPixelBuffer?
    private var rightBuffer: RGBAPixelBuffer?

    func chooseImage(for side: Side) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = side == .left
            ? RiffaLocalization.string("Choose Left Image")
            : RiffaLocalization.string("Choose Right Image")
        panel.prompt = RiffaLocalization.string("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        replaceInput(with: url, for: side)
    }

    func replaceInput(with url: URL, for side: Side) {
        load(url: url, for: side)
    }

    func openInitial(_ urls: [URL], options: [String: String] = [:]) {
        if let value = options["displayMode"].flatMap(DisplayMode.init(rawValue:)) {
            displayMode = value
        }
        if let value = options.riffaDouble(for: "blendAmount"), (0...1).contains(value) {
            blendAmount = value
        }
        if let value = options["zoomMode"].flatMap(ZoomMode.init(rawValue:)) {
            zoomMode = value
        }
        if let value = options.riffaDouble(for: "zoomScale"), value.isFinite {
            let restoredMode = zoomMode
            setZoom(value)
            zoomMode = restoredMode
        }
        if let value = options.riffaBoolean(for: "showsCheckerboard") {
            showsCheckerboard = value
        }
        if let value = options.riffaDouble(for: "tolerance"), (0...255).contains(value) {
            tolerance = value
        }
        if let value = options.riffaBoolean(for: "compareAlpha") {
            compareAlpha = value
        }
        if let value = options.riffaInteger(for: "xOffset"),
           (-999...999).contains(value),
           let exact = Int(exactly: value) {
            xOffset = exact
        }
        if let value = options.riffaInteger(for: "yOffset"),
           (-999...999).contains(value),
           let exact = Int(exactly: value) {
            yOffset = exact
        }
        if let left = urls.first { load(url: left, for: .left) }
        if urls.count > 1 { load(url: urls[1], for: .right) }
    }

    func loadDemo() {
        do {
            let left = Self.demoImage(accent: .systemBlue, shifted: false)
            let right = Self.demoImage(accent: .systemOrange, shifted: true)
            leftURL = URL(fileURLWithPath: "/Demo/riffa-blue.png")
            rightURL = URL(fileURLWithPath: "/Demo/riffa-coral.png")
            leftImage = left
            rightImage = right
            leftBuffer = try Self.pixelBuffer(from: left)
            rightBuffer = try Self.pixelBuffer(from: right)
            tolerance = 0
            xOffset = 0
            yOffset = 0
            errorMessage = nil
            compareIfReady()
        } catch {
            errorMessage = String(
                localized: "Could not create image demo: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    func swapSides() {
        (leftURL, rightURL) = (rightURL, leftURL)
        (leftImage, rightImage) = (rightImage, leftImage)
        (leftBuffer, rightBuffer) = (rightBuffer, leftBuffer)
        xOffset = -xOffset
        yOffset = -yOffset
        compareIfReady()
    }

    func useFitZoom() {
        zoomMode = .fit
    }

    func useActualSize() {
        setZoom(1)
    }

    func zoomIn() {
        let base = zoomMode == .fit ? 1 : zoomScale
        setZoom(base * 1.25)
    }

    func zoomOut() {
        let base = zoomMode == .fit ? 1 : zoomScale
        setZoom(base / 1.25)
    }

    func setZoom(_ proposedScale: Double) {
        guard proposedScale.isFinite else { return }
        zoomScale = min(max(proposedScale, 0.05), 8)
        zoomMode = .fixed
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
        panel.title = RiffaLocalization.string("Export Image Comparison Report")
        panel.prompt = RiffaLocalization.string("Export")
        panel.nameFieldStringValue = "Riffa-Image-Report.\(fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let report = try SpecializedComparisonReportGenerator().generate(
                image: result,
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
        do {
            let (image, buffer) = try Self.decodeImage(at: url)
            switch side {
            case .left:
                leftURL = url
                leftImage = image
                leftBuffer = buffer
            case .right:
                rightURL = url
                rightImage = image
                rightBuffer = buffer
            }
            errorMessage = nil
            compareIfReady()
        } catch {
            errorMessage = String(
                localized: "Could not decode \(url.lastPathComponent): \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private func compareIfReady() {
        guard let leftBuffer, let rightBuffer else {
            result = nil
            maskImage = nil
            return
        }
        let comparison = ImageComparison().compare(
            leftBuffer,
            to: rightBuffer,
            options: ImageComparisonOptions(
                channelTolerance: UInt8(clamping: Int(tolerance.rounded())),
                compareAlpha: compareAlpha,
                xOffset: xOffset,
                yOffset: yOffset
            )
        )
        result = comparison
        maskImage = Self.heatMap(from: comparison.mismatchMask)
    }

    private static func pixelBuffer(from image: NSImage) throws -> RGBAPixelBuffer {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw ImageCompareLoadError.missingImage
        }
        return try pixelBuffer(from: source)
    }

    private static func decodeImage(
        at url: URL
    ) throws -> (NSImage, RGBAPixelBuffer) {
        let data = try BoundedLocalFileReader(
            limits: .init(maximumByteCount: maximumEncodedByteCount)
        ).read(url: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageCompareLoadError.missingImage
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as NSDictionary?,
              let width = (properties.object(forKey: kCGImagePropertyPixelWidth) as? NSNumber)?.intValue,
              let height = (properties.object(forKey: kCGImagePropertyPixelHeight) as? NSNumber)?.intValue else {
            throw ImageCompareLoadError.invalidDimensions
        }
        try validateDimensions(width: width, height: height)

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw ImageCompareLoadError.missingImage
        }
        // Re-check decoded dimensions rather than trusting container metadata.
        try validateDimensions(width: image.width, height: image.height)
        let buffer = try pixelBuffer(from: image)
        return (
            NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            ),
            buffer
        )
    }

    private static func pixelBuffer(
        from source: CGImage
    ) throws -> RGBAPixelBuffer {
        let width = source.width
        let height = source.height
        try validateDimensions(width: width, height: height)
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(
            by: RGBAPixelBuffer.bytesPerPixel
        )
        let (byteCount, byteCountOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !byteCountOverflow else {
            throw ImageCompareLoadError.invalidDimensions
        }
        var bytes = Array(repeating: UInt8(0), count: byteCount)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        context.interpolationQuality = .none
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try RGBAPixelBuffer(width: width, height: height, bytes: bytes)
    }

    private static func validateDimensions(
        width: Int,
        height: Int
    ) throws {
        guard width > 0, height > 0,
              width <= maximumDimension,
              height <= maximumDimension else {
            throw ImageCompareLoadError.invalidDimensions
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= maximumPixelCount else {
            throw ImageCompareLoadError.dimensionsTooLarge(
                width: width,
                height: height,
                pixelLimit: maximumPixelCount
            )
        }
    }

    private static func heatMap(from mask: ImageMismatchMask) -> NSImage? {
        guard mask.width > 0, mask.height > 0 else { return nil }
        var rgba = Array(repeating: UInt8(0), count: mask.values.count * 4)
        for (index, value) in mask.values.enumerated() {
            rgba[index * 4] = value
            rgba[index * 4 + 1] = value == 0 ? 22 : 72
            rgba[index * 4 + 2] = value == 0 ? 32 : 42
            rgba[index * 4 + 3] = 255
        }
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: mask.width,
                height: mask.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: mask.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: mask.width, height: mask.height))
    }

    private static func demoImage(accent: NSColor, shifted: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 480, height: 300), flipped: false) { rect in
            NSColor(calibratedRed: 0.03, green: 0.06, blue: 0.13, alpha: 1).setFill()
            rect.fill()
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 34, dy: 34), xRadius: 26, yRadius: 26)
            NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
            card.fill()
            accent.setFill()
            NSBezierPath(ovalIn: CGRect(x: shifted ? 292 : 278, y: 122, width: 92, height: 92)).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 40, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            NSString(string: shifted ? "Riffa 2" : "Riffa 1").draw(at: CGPoint(x: 70, y: 143), withAttributes: attributes)
            return true
        }
        return image
    }
}

struct ImageCompareView: View {
    @StateObject private var model = ImageCompareModel()
    private let initialURLs: [URL]
    private let initialOptions: [String: String]

    @Environment(\.riffaTheme) private var theme

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
            if let result = model.result {
                comparison(result)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Image Compare")
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
            "Image comparison error",
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
            title: "Image Compare",
            subtitle: "Pixel-level overlay and difference analysis"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .imageComparison,
                    urls: [model.leftURL, model.rightURL].compactMap { $0 },
                    options: [
                        "displayMode": .string(model.displayMode.rawValue),
                        "blendAmount": .decimal(Decimal(model.blendAmount)),
                        "zoomMode": .string(model.zoomMode.rawValue),
                        "zoomScale": .decimal(Decimal(model.zoomScale)),
                        "showsCheckerboard": .boolean(model.showsCheckerboard),
                        "tolerance": .decimal(Decimal(model.tolerance)),
                        "compareAlpha": .boolean(model.compareAlpha),
                        "xOffset": .integer(Int64(model.xOffset)),
                        "yOffset": .integer(Int64(model.yOffset))
                    ]
                ),
                errorMessage: $model.errorMessage
            )
            Picker("View", selection: $model.displayMode) {
                ForEach(ImageCompareModel.DisplayMode.allCases) {
                    Text(LocalizedStringKey($0.rawValue)).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 276)
            .accessibilityLabel("Image display mode")
            .accessibilityHint("Choose side by side, blend, or difference analysis")

            Menu {
                Button("HTML…") { model.saveReport(format: .html) }
                Button("Plain Text…") { model.saveReport(format: .plainText) }
                Button("JSON…") { model.saveReport(format: .json) }
            } label: {
                Label("Export Report", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .buttonStyle(.riffaSecondary)
            .accessibilityLabel("Export image comparison report")
            .accessibilityHint("Choose HTML, plain text, or JSON")
            .help("Export comparison report")
            .disabled(model.result == nil)
        }
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            RiffaResourcePathButton(
                title: "Left image",
                url: model.leftURL,
                emptyTitle: "Choose an image…",
                systemImage: "photo",
                accessibilityHint: "Opens a local image picker for the left side"
            ) {
                model.chooseImage(for: .left)
            }
            .riffaResourceDropTarget(
                role: .left,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .left)
            }

            Button { model.swapSides() } label: {
                Label("Swap images", systemImage: "arrow.left.arrow.right")
            }
                .labelStyle(.iconOnly)
                .buttonStyle(.riffaIcon)
                .disabled(model.leftImage == nil && model.rightImage == nil)
                .accessibilityLabel("Swap compared images")
                .accessibilityHint("Exchanges the left and right images and reverses both offsets")

            RiffaResourcePathButton(
                title: "Right image",
                url: model.rightURL,
                emptyTitle: "Choose an image…",
                systemImage: "photo",
                accessibilityHint: "Opens a local image picker for the right side"
            ) {
                model.chooseImage(for: .right)
            }
            .riffaResourceDropTarget(
                role: .right,
                acceptedKind: .regularFileFollowingFinalSymbolicLink
            ) {
                model.replaceInput(with: $0, for: .right)
            }
        }
    }

    private func comparison(_ result: ImageComparisonResult) -> some View {
        VStack(spacing: 0) {
            controls

            HStack(spacing: 0) {
                ZStack {
                    if model.showsCheckerboard {
                        checkerboard
                    } else {
                        theme.canvas
                    }
                    imageViewport(result)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                RiffaHairline(.vertical)
                differenceInspector(result)
                    .frame(width: 224)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statistics(result)
        }
    }

    private var controls: some View {
        RiffaComparisonControlBar {
            Text("Tolerance")
                .riffaText(.caption)
                .foregroundStyle(theme.inkSubtle)
            Text("\(Int(model.tolerance))")
                .riffaText(.mono)
                .foregroundStyle(theme.ink)
                .frame(width: 28, alignment: .trailing)
            Slider(value: $model.tolerance, in: 0...255, step: 1)
                .frame(width: 132)
                .accessibilityLabel("Pixel channel tolerance")
                .accessibilityValue("\(Int(model.tolerance)) of 255")
                .accessibilityHint("Higher values ignore larger channel differences")

            Toggle("Compare Alpha", isOn: $model.compareAlpha)
                .toggleStyle(.checkbox)
                .accessibilityHint("Includes or ignores the alpha channel during comparison")

            Stepper("X \(model.xOffset)", value: $model.xOffset, in: -999...999)
                .fixedSize()
                .accessibilityLabel("Horizontal image offset")
                .accessibilityValue("\(model.xOffset) pixels")
            Stepper("Y \(model.yOffset)", value: $model.yOffset, in: -999...999)
                .fixedSize()
                .accessibilityLabel("Vertical image offset")
                .accessibilityValue("\(model.yOffset) pixels")

            if model.displayMode == .blend {
                RiffaHairline(.vertical)
                    .frame(height: 24)
                Text("Blend")
                    .riffaText(.caption)
                    .foregroundStyle(theme.inkSubtle)
                Text("\(Int(model.blendAmount * 100))%")
                    .riffaText(.mono)
                    .foregroundStyle(theme.ink)
                    .frame(width: 42, alignment: .trailing)
                Slider(value: $model.blendAmount)
                    .frame(width: 116)
                    .accessibilityLabel("Right image blend")
                    .accessibilityValue("\(Int(model.blendAmount * 100)) percent")
            }

            RiffaHairline(.vertical)
                .frame(height: 24)

            Button {
                model.showsCheckerboard.toggle()
            } label: {
                Label(
                    "Transparency Grid",
                    systemImage: model.showsCheckerboard
                        ? "checkerboard.rectangle"
                        : "rectangle"
                )
            }
            .buttonStyle(.riffaSecondary)
            .accessibilityLabel("Transparency grid")
            .accessibilityValue(
                Text(
                    verbatim: RiffaLocalization.string(
                        model.showsCheckerboard ? "Shown" : "Hidden"
                    )
                )
            )
            .accessibilityHint("Shows or hides the transparency checkerboard")

            Button("Fit") {
                model.useFitZoom()
            }
            .buttonStyle(.riffaSecondary)
            .help("Fit every visible image using one shared scale")
            .accessibilityLabel("Fit compared images")
            .accessibilityHint("Fits all visible panes with one shared scale")

            Button { model.zoomOut() } label: {
                Label("Zoom out", systemImage: "minus.magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .keyboardShortcut("-", modifiers: .command)
            .accessibilityLabel("Zoom out")
            .accessibilityHint("Decreases the shared image scale")

            Slider(
                value: Binding(
                    get: { model.zoomScale },
                    set: { model.setZoom($0) }
                ),
                in: 0.05...8
            )
            .frame(width: 132)
            .accessibilityLabel("Image zoom")
            .accessibilityValue(
                Text(
                    verbatim: model.zoomMode == .fit
                        ? RiffaLocalization.string("Fit")
                        : zoomPercentage
                )
            )
            .accessibilityHint("Changes the scale shared by every visible pane")

            Button { model.zoomIn() } label: {
                Label("Zoom in", systemImage: "plus.magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .keyboardShortcut("+", modifiers: .command)
            .accessibilityLabel("Zoom in")
            .accessibilityHint("Increases the shared image scale")

            Button {
                model.useActualSize()
            } label: {
                Text(
                    verbatim: model.zoomMode == .fit
                        ? RiffaLocalization.string("Fit")
                        : zoomPercentage
                )
            }
            .buttonStyle(.riffaTertiary)
            .help("Show at 100%")
            .keyboardShortcut("0", modifiers: .command)
            .accessibilityLabel("Show actual image size")
            .accessibilityValue(
                Text(
                    verbatim: model.zoomMode == .fit
                        ? RiffaLocalization.string("Currently fit")
                        : zoomPercentage
                )
            )
        }
    }

    private var checkerboard: some View {
        Canvas { context, size in
            let cell: CGFloat = 16
            for y in stride(from: CGFloat(0), to: size.height, by: cell) {
                for x in stride(from: CGFloat(0), to: size.width, by: cell) {
                    let even = (Int(x / cell) + Int(y / cell)).isMultiple(of: 2)
                    context.fill(
                        Path(CGRect(x: x, y: y, width: cell, height: cell)),
                        with: .color(
                            even
                                ? theme.surface(.one)
                                : theme.surface(.two)
                        )
                    )
                }
            }
        }
    }

    private var zoomPercentage: String {
        String(format: "%.0f%%", model.zoomScale * 100)
    }

    private func imageViewport(_ result: ImageComparisonResult) -> some View {
        GeometryReader { proxy in
            let scale = viewportScale(for: proxy.size)
            ScrollView([.horizontal, .vertical]) {
                viewportContent(result: result, scale: scale)
                    .frame(
                        minWidth: proxy.size.width,
                        minHeight: proxy.size.height,
                        alignment: .center
                    )
            }
            .scrollIndicators(.visible)
            .accessibilityLabel("Synchronized image viewport")
            .accessibilityValue(
                Text(
                    verbatim: imageViewportAccessibilityValue
                )
            )
            .accessibilityHint("Scrolls every visible image pane together")
        }
    }

    @ViewBuilder
    private func viewportContent(
        result: ImageComparisonResult,
        scale: CGFloat
    ) -> some View {
        switch model.displayMode {
        case .sideBySide:
            HStack(spacing: 0) {
                imagePane(
                    model.leftImage,
                    title: "LEFT",
                    scale: scale,
                    annotation: result.mismatchBounds,
                    annotationOriginX: 0,
                    annotationOriginY: 0
                )
                RiffaHairline(.vertical)
                imagePane(
                    model.rightImage,
                    title: "RIGHT",
                    scale: scale,
                    annotation: result.mismatchBounds,
                    annotationOriginX: model.xOffset,
                    annotationOriginY: model.yOffset
                )
            }
        case .blend:
            VStack(spacing: 0) {
                RiffaPaneHeader(
                    "BLEND",
                    subtitle: String(
                        localized: "\(Int(model.blendAmount * 100))% right image",
                        bundle: RiffaLocalization.localizedBundle,
                        locale: RiffaLocalization.locale
                    ),
                    systemImage: "square.on.square"
                )
                annotatedOverlayCanvas(
                    left: model.leftImage,
                    right: model.rightImage,
                    rightOpacity: model.blendAmount,
                    scale: scale,
                    annotation: result.mismatchBounds
                )
                .padding(RiffaSpacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .difference:
            HStack(spacing: 0) {
                imagePane(
                    model.leftImage,
                    title: "LEFT",
                    scale: scale,
                    annotation: result.mismatchBounds,
                    annotationOriginX: 0,
                    annotationOriginY: 0
                )
                RiffaHairline(.vertical)
                imagePane(
                    model.maskImage,
                    title: "DIFFERENCE",
                    subtitle: result.hasPixelDifferences
                        ? "Outlined region #1"
                        : "No changed pixels",
                    scale: scale,
                    annotation: result.mismatchBounds,
                    annotationOriginX: result.mismatchMask.originX,
                    annotationOriginY: result.mismatchMask.originY
                )
                RiffaHairline(.vertical)
                imagePane(
                    model.rightImage,
                    title: "RIGHT",
                    scale: scale,
                    annotation: result.mismatchBounds,
                    annotationOriginX: model.xOffset,
                    annotationOriginY: model.yOffset
                )
            }
        }
    }

    private func imagePane(
        _ image: NSImage?,
        title: String,
        subtitle: String? = nil,
        scale: CGFloat,
        annotation: PixelBounds?,
        annotationOriginX: Int,
        annotationOriginY: Int
    ) -> some View {
        VStack(spacing: 0) {
            RiffaPaneHeader(
                title,
                subtitle: subtitle ?? imageDimensions(image),
                systemImage: title == "DIFFERENCE"
                    ? "square.dashed.inset.filled"
                    : "photo"
            )
            annotatedImage(
                image,
                scale: scale,
                accessibilityLabel: imagePaneAccessibilityLabel(title),
                annotation: annotation,
                annotationOriginX: annotationOriginX,
                annotationOriginY: annotationOriginY
            )
            .padding(RiffaSpacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 248)
        .background(theme.canvas)
    }

    @ViewBuilder
    private func fixedImage(
        _ image: NSImage?,
        scale: CGFloat,
        accessibilityLabel: String
    ) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(scale >= 1 ? .none : .medium)
                .frame(
                    width: max(1, image.size.width * scale),
                    height: max(1, image.size.height * scale)
                )
                .accessibilityLabel(accessibilityLabel)
        } else {
            Color.clear
                .frame(width: 1, height: 1)
        }
    }

    @ViewBuilder
    private func annotatedImage(
        _ image: NSImage?,
        scale: CGFloat,
        accessibilityLabel: String,
        annotation: PixelBounds?,
        annotationOriginX: Int,
        annotationOriginY: Int
    ) -> some View {
        if let image {
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(scale >= 1 ? .none : .medium)
                    .frame(
                        width: max(1, image.size.width * scale),
                        height: max(1, image.size.height * scale)
                    )

                if let annotation {
                    differenceAnnotation(
                        annotation,
                        originX: annotationOriginX,
                        originY: annotationOriginY,
                        scale: scale
                    )
                }
            }
            .frame(
                width: max(1, image.size.width * scale),
                height: max(1, image.size.height * scale),
                alignment: .topLeading
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                imageAccessibilityLabel(
                    accessibilityLabel,
                    annotation: annotation
                )
            )
        } else {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
    }

    private func annotatedOverlayCanvas(
        left: NSImage?,
        right: NSImage?,
        rightOpacity: Double,
        scale: CGFloat,
        annotation: PixelBounds?
    ) -> some View {
        let width = max(left?.size.width ?? 0, right?.size.width ?? 0)
        let height = max(left?.size.height ?? 0, right?.size.height ?? 0)
        return ZStack(alignment: .topLeading) {
            fixedImage(
                left,
                scale: scale,
                accessibilityLabel: RiffaLocalization.string(
                    "Left compared image"
                )
            )
            fixedImage(
                right,
                scale: scale,
                accessibilityLabel: RiffaLocalization.string(
                    "Right compared image"
                )
            )
                .opacity(rightOpacity)
            if let annotation {
                differenceAnnotation(
                    annotation,
                    originX: 0,
                    originY: 0,
                    scale: scale
                )
            }
        }
        .frame(
            width: max(1, width * scale),
            height: max(1, height * scale),
            alignment: .topLeading
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            imageAccessibilityLabel(
                RiffaLocalization.string("Blended comparison image"),
                annotation: annotation
            )
        )
    }

    private func differenceAnnotation(
        _ bounds: PixelBounds,
        originX: Int,
        originY: Int,
        scale: CGFloat
    ) -> some View {
        let localX = max(0, CGFloat(bounds.x - originX) * scale)
        let localY = max(0, CGFloat(bounds.y - originY) * scale)
        let width = max(6, CGFloat(bounds.width) * scale)
        let height = max(6, CGFloat(bounds.height) * scale)

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: RiffaRadius.xs)
                .fill(theme.danger.opacity(theme.reducesTransparency ? 0.12 : 0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: RiffaRadius.xs)
                        .strokeBorder(
                            theme.danger,
                            style: StrokeStyle(
                                lineWidth: theme.usesIncreasedContrast ? 3 : 2,
                                dash: [6, 4]
                            )
                        )
                }

            Canvas { context, size in
                var startX = -size.height
                while startX < size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: startX, y: size.height))
                    path.addLine(
                        to: CGPoint(
                            x: startX + size.height,
                            y: 0
                        )
                    )
                    context.stroke(
                        path,
                        with: .color(theme.danger.opacity(0.42)),
                        lineWidth: 1
                    )
                    startX += 10
                }
            }
            .clipShape(
                RoundedRectangle(cornerRadius: RiffaRadius.xs)
            )
            .accessibilityHidden(true)

            Text("1")
                .riffaText(.caption)
                .foregroundStyle(theme.ink)
                .frame(width: 20, height: 20)
                .background(theme.canvas)
                .overlay {
                    RoundedRectangle(cornerRadius: RiffaRadius.xs)
                        .strokeBorder(theme.danger, lineWidth: 2)
                }
                .padding(RiffaSpacing.xxs)
        }
        .frame(width: width, height: height)
        .offset(x: localX, y: localY)
        .accessibilityHidden(true)
    }

    private func viewportScale(for availableSize: CGSize) -> CGFloat {
        guard model.zoomMode == .fit else {
            return CGFloat(model.zoomScale)
        }

        let imageSizes: [CGSize]
        switch model.displayMode {
        case .sideBySide:
            imageSizes = [model.leftImage?.size, model.rightImage?.size].compactMap { $0 }
        case .blend:
            imageSizes = [model.leftImage?.size, model.rightImage?.size].compactMap { $0 }
        case .difference:
            imageSizes = [
                model.leftImage?.size,
                model.maskImage?.size,
                model.rightImage?.size
            ].compactMap { $0 }
        }
        guard let maximumWidth = imageSizes.map(\.width).max(), maximumWidth > 0,
              let maximumHeight = imageSizes.map(\.height).max(), maximumHeight > 0 else {
            return 1
        }

        let paneCount: CGFloat = switch model.displayMode {
        case .sideBySide: 2
        case .blend: 1
        case .difference: 3
        }
        let horizontalPadding = RiffaSpacing.md * 2
        let verticalPadding: CGFloat = 40 + (RiffaSpacing.md * 2)
        let availableWidth: CGFloat
        availableWidth = max(
            1,
            (availableSize.width - max(0, paneCount - 1)) / paneCount
                - horizontalPadding
        )
        let availableHeight = max(1, availableSize.height - verticalPadding)
        let scale = min(availableWidth / maximumWidth, availableHeight / maximumHeight)
        guard scale.isFinite, scale > 0 else { return 1 }
        return scale
    }

    private func differenceInspector(
        _ result: ImageComparisonResult
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RiffaSpacing.md) {
                VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                    Text("Image Difference")
                        .riffaText(.body)
                        .foregroundStyle(theme.ink)
                    Text(
                        LocalizedStringKey(
                            result.hasPixelDifferences
                                ? "Mismatch bounds are marked as region #1."
                                : "No pixels exceed the current tolerance."
                        )
                    )
                    .riffaText(.caption)
                    .foregroundStyle(theme.inkSubtle)
                    .fixedSize(horizontal: false, vertical: true)
                }

                RiffaHairline()

                VStack(spacing: RiffaSpacing.sm) {
                    inspectorValue(
                        "Left dimensions",
                        imageDimensions(model.leftImage)
                    )
                    inspectorValue(
                        "Right dimensions",
                        imageDimensions(model.rightImage)
                    )
                    inspectorValue(
                        "Dimension status",
                        RiffaLocalization.string(
                            result.dimensionStatus == .equal
                                ? "Same"
                                : "Different"
                        )
                    )
                    inspectorValue(
                        "Differing pixels",
                        "\(result.mismatchedPixelCount)"
                    )
                    inspectorValue(
                        "Mismatch ratio",
                        String(format: "%.2f%%", result.mismatchRatio * 100)
                    )
                    inspectorValue(
                        "Maximum delta",
                        "\(result.maximumChannelDifference)"
                    )
                    inspectorValue(
                        "Mean delta",
                        String(format: "%.2f", result.averageChannelDifference)
                    )
                    inspectorValue(
                        "Alpha",
                        RiffaLocalization.string(
                            model.compareAlpha ? "Compared" : "Ignored"
                        )
                    )
                    inspectorValue(
                        "Offset",
                        "x \(model.xOffset), y \(model.yOffset)"
                    )
                }

                if let bounds = result.mismatchBounds {
                    RiffaHairline()
                    VStack(alignment: .leading, spacing: RiffaSpacing.xs) {
                        Text("Legend")
                            .riffaText(.caption)
                            .foregroundStyle(theme.inkSubtle)

                        HStack(spacing: RiffaSpacing.xs) {
                            Text("1")
                                .riffaText(.caption)
                                .foregroundStyle(theme.ink)
                                .frame(width: 22, height: 22)
                                .background(theme.canvas)
                                .overlay {
                                    RoundedRectangle(cornerRadius: RiffaRadius.xs)
                                        .strokeBorder(theme.danger, lineWidth: 2)
                                }

                            VStack(alignment: .leading, spacing: 1) {
                                Text("Mismatch bounds")
                                    .riffaText(.bodySmall)
                                    .foregroundStyle(theme.ink)
                                Text(
                                    "\(bounds.x),\(bounds.y) · \(bounds.width)×\(bounds.height)"
                                )
                                .riffaText(.mono)
                                .foregroundStyle(theme.inkSubtle)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "Difference region 1, mismatch bounds x \(bounds.x), y \(bounds.y), width \(bounds.width), height \(bounds.height)"
                        )
                    }
                }
            }
            .padding(RiffaSpacing.md)
        }
        .background(theme.surface(.one))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image difference inspector")
    }

    private func inspectorValue(
        _ title: String,
        _ value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: RiffaSpacing.xs) {
            Text(LocalizedStringKey(title))
                .riffaText(.caption)
                .foregroundStyle(theme.inkSubtle)
            Spacer(minLength: RiffaSpacing.xs)
            Text(value)
                .riffaText(.mono)
                .foregroundStyle(theme.inkMuted)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func statistics(_ result: ImageComparisonResult) -> some View {
        let mismatch = String(
            localized: "\(result.mismatchRatio * 100, format: .number.precision(.fractionLength(2)))% mismatch",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        return RiffaStatusBar {
            if result.hasPixelDifferences {
                RiffaStatusBadge(
                    verbatim: mismatch,
                    systemImage: RiffaIcon.notEqual,
                    tone: .warning
                )
            } else {
                RiffaStatusBadge(
                    "Images match",
                    systemImage: "checkmark.circle.fill",
                    tone: .success
                )
            }

            Text("\(result.mismatchedPixelCount) of \(result.comparedPixelCount) pixels")
                .riffaText(.mono)

            if let bounds = result.mismatchBounds {
                Text(
                    "Region #1 · \(bounds.x),\(bounds.y) · \(bounds.width)×\(bounds.height)"
                )
                .riffaText(.mono)
            }

            Spacer()

            if result.dimensionStatus == .different {
                RiffaStatusBadge(
                    "Dimensions differ",
                    systemImage: "rectangle.on.rectangle.slash",
                    tone: .danger
                )
            }

            Text(
                verbatim: model.zoomMode == .fit
                    ? RiffaLocalization.string("Fit")
                    : zoomPercentage
            )
                .riffaText(.mono)
            Text("Shared scroll")
                .foregroundStyle(theme.inkTertiary)
        }
    }

    private var emptyState: some View {
        RiffaEmptyState(
            title: "Choose two images",
            description: "Riffa normalizes both images to RGBA pixels and compares them locally.",
            systemImage: "photo.on.rectangle.angled"
        ) {
            HStack(spacing: RiffaSpacing.xs) {
                Button("Choose Left") {
                    model.chooseImage(for: .left)
                }
                .buttonStyle(.riffaSecondary)
                .accessibilityLabel("Choose left image")
                .accessibilityHint("Opens a local image picker")

                Button("Choose Right") {
                    model.chooseImage(for: .right)
                }
                .buttonStyle(.riffaSecondary)
                .accessibilityLabel("Choose right image")
                .accessibilityHint("Opens a local image picker")

                Button("Load Demo") {
                    model.loadDemo()
                }
                .buttonStyle(.riffaPrimary)
                .accessibilityHint("Loads two local sample images for comparison")
            }
        }
    }

    private func imageDimensions(_ image: NSImage?) -> String {
        guard let image else {
            return RiffaLocalization.string("No image")
        }
        return "\(Int(image.size.width)) × \(Int(image.size.height))"
    }

    private func imageAccessibilityLabel(
        _ base: String,
        annotation: PixelBounds?
    ) -> String {
        guard let annotation else {
            return String(
                localized: "\(base). No pixels exceed the current tolerance.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "\(base). Difference region 1 at x \(annotation.x), y \(annotation.y), width \(annotation.width), height \(annotation.height).",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private var imageViewportAccessibilityValue: String {
        let mode = RiffaLocalization.string(model.displayMode.rawValue)
        if model.zoomMode == .fit {
            return String(
                localized: "\(mode), fit using a shared scale",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
        return String(
            localized: "\(mode), \(zoomPercentage)",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
    }

    private func imagePaneAccessibilityLabel(_ title: String) -> String {
        switch title {
        case "LEFT":
            return RiffaLocalization.string("Left compared image")
        case "RIGHT":
            return RiffaLocalization.string("Right compared image")
        case "DIFFERENCE":
            return RiffaLocalization.string("Difference image")
        default:
            return String(
                localized: "\(title) compared image",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }
}
