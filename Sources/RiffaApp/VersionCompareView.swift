import AppKit
import Foundation
import RiffaCore
import SwiftUI

private actor VersionComparisonWorker {
    func compare(leftURL: URL, rightURL: URL) throws -> VersionComparisonResult {
        try VersionComparisonEngine().compare(leftURL: leftURL, rightURL: rightURL)
    }
}

private let versionComparisonWorker = VersionComparisonWorker()

@MainActor
private final class VersionCompareModel: ObservableObject {
    enum Side {
        case left
        case right
    }

    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var result: VersionComparisonResult?
    @Published private(set) var isLoading = false
    @Published var showDifferencesOnly = false
    @Published var errorMessage: String?

    private var comparisonTask: Task<Void, Never>?

    var visibleFields: [VersionComparisonListItem] {
        guard let result else { return [] }
        let fields = showDifferencesOnly
            ? result.fields.filter { $0.status == .different }
            : result.fields
        return fields.map(VersionComparisonListItem.init)
    }

    func chooseResource(for side: Side) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        // Packages must remain selectable as single version resources. With
        // this disabled, Finder-style panels would navigate into an .app or
        // .framework instead of returning the bundle root.
        panel.treatsFilePackagesAsDirectories = false
        panel.title = switch side {
        case .left: RiffaLocalization.string("Choose Left File or Bundle")
        case .right: RiffaLocalization.string("Choose Right File or Bundle")
        }
        panel.message = RiffaLocalization.string(
            "Choose a regular file, application, framework, or bundle. Riffa never launches the selected code."
        )
        panel.prompt = RiffaLocalization.string("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        replaceInput(with: url, for: side)
    }

    func replaceInput(with url: URL, for side: Side) {
        setURL(url, for: side)
    }

    func openInitial(_ urls: [URL], options: [String: String] = [:]) {
        comparisonTask?.cancel()
        if let value = options.riffaBoolean(for: "showDifferencesOnly") {
            showDifferencesOnly = value
        }
        leftURL = urls.first?.standardizedFileURL
        rightURL = urls.count > 1 ? urls[1].standardizedFileURL : nil
        compareIfReady()
    }

    func swapSides() {
        comparisonTask?.cancel()
        (leftURL, rightURL) = (rightURL, leftURL)
        if let result {
            self.result = VersionComparisonEngine().compare(
                left: result.right,
                right: result.left
            )
            isLoading = false
            errorMessage = nil
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
        panel.title = RiffaLocalization.string("Export Version Comparison Report")
        panel.prompt = RiffaLocalization.string("Export")
        panel.nameFieldStringValue = "Riffa-Version-Report.\(fileExtension)"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            let report = try SpecializedComparisonReportGenerator().generate(
                version: result,
                format: format,
                leftLabel: result.left.displayName,
                rightLabel: result.right.displayName
            )
            try report.write(to: destinationURL, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = String(
                localized: "Could not export the version report: \(error.localizedDescription)",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private func setURL(_ url: URL, for side: Side) {
        switch side {
        case .left:
            leftURL = url.standardizedFileURL
        case .right:
            rightURL = url.standardizedFileURL
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
                let comparison = try await versionComparisonWorker.compare(
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
                self.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct VersionComparisonListItem: Identifiable {
    let comparison: VersionFieldComparison
    var id: String { comparison.field.rawValue }
}

struct VersionCompareView: View {
    @Environment(\.riffaTheme) private var theme
    @StateObject private var model = VersionCompareModel()
    private let initialURLs: [URL]
    private let initialOptions: [String: String]

    init(initialURLs: [URL] = [], initialOptions: [String: String] = [:]) {
        self.initialURLs = initialURLs
        self.initialOptions = initialOptions
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            controlBar
            pathBar
            if model.isLoading {
                ProgressView("Inspecting bounded version and signing metadata…")
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
        .navigationTitle("Version Compare")
        .background(theme.canvas)
        .riffaWindowDropZones([
            RiffaDropZone(role: .left, acceptedKind: .realFileOrDirectory) {
                model.replaceInput(with: $0, for: .left)
            },
            RiffaDropZone(role: .right, acceptedKind: .realFileOrDirectory) {
                model.replaceInput(with: $0, for: .right)
            },
        ])
        .alert(
            "Version comparison error",
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
            title: "Version Compare",
            subtitle: "Versions, architectures, digests, and code signatures"
        ) {
            SessionSaveButton(
                request: SessionSaveRequest(
                    kind: .versionComparison,
                    urls: [model.leftURL, model.rightURL].compactMap { $0 },
                    options: [
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
            .accessibilityLabel("Export version comparison report")
            .accessibilityHint("Choose HTML, plain text, or JSON")
            .help("Export version comparison report")
            .disabled(model.result == nil || model.isLoading)
        }
    }

    private var controlBar: some View {
        RiffaComparisonControlBar {
            Toggle("Differences only", isOn: $model.showDifferencesOnly)
                .toggleStyle(.checkbox)
            Spacer(minLength: RiffaSpacing.xs)
            RiffaStatusBadge(
                "Static inspection",
                systemImage: "lock.shield",
                tone: .secure
            )
        }
    }

    private var pathBar: some View {
        RiffaComparisonPathBar {
            VersionPathButton(
                title: "Left file or bundle",
                url: model.leftURL
            ) { model.chooseResource(for: .left) }
            .riffaResourceDropTarget(
                role: .left,
                acceptedKind: .realFileOrDirectory
            ) {
                model.replaceInput(with: $0, for: .left)
            }
            Button { model.swapSides() } label: {
                Label("Swap resources", systemImage: "arrow.left.arrow.right")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.riffaIcon)
            .accessibilityLabel("Swap version resources")
            .accessibilityHint("Exchanges the left and right files or bundles")
            .help("Swap left and right")
            .disabled(model.leftURL == nil && model.rightURL == nil)
            VersionPathButton(
                title: "Right file or bundle",
                url: model.rightURL
            ) { model.chooseResource(for: .right) }
            .riffaResourceDropTarget(
                role: .right,
                acceptedKind: .realFileOrDirectory
            ) {
                model.replaceInput(with: $0, for: .right)
            }
        }
    }

    private func results(_ result: VersionComparisonResult) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VersionResourceSummary(side: "Left", snapshot: result.left)
                VersionResourceSummary(side: "Right", snapshot: result.right)
            }
            .padding(RiffaSpacing.sm)
            .background(theme.canvas)
            RiffaHairline()
            Table(model.visibleFields) {
                TableColumn("Status") { item in
                    VersionFieldStatusLabel(status: item.comparison.status)
                }
                .width(min: 85, ideal: 100, max: 120)
                TableColumn("Field") { item in
                    Text(verbatim: versionFieldLabel(item.comparison.field))
                        .help(item.comparison.field.rawValue)
                }
                .width(min: 170, ideal: 230, max: 300)
                TableColumn("Left") { item in
                    Text(versionValueText(item.comparison.left, field: item.comparison.field))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .width(min: 240, ideal: 360)
                TableColumn("Right") { item in
                    Text(versionValueText(item.comparison.right, field: item.comparison.field))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .width(min: 240, ideal: 360)
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            RiffaStatusBar {
                RiffaStatusBadge(
                    "\(result.statistics.differentFieldCount) different",
                    systemImage: RiffaIcon.notEqual,
                    tone: result.hasDifferences ? .warning : .success
                )
                RiffaStatusBadge(
                    "\(result.statistics.sameFieldCount) same",
                    systemImage: "equal"
                )
                Spacer()
                Text(
                    "\(model.visibleFields.count) of \(result.statistics.totalFieldCount) fields"
                )
                .foregroundStyle(theme.inkSubtle)
            }
        }
    }

    private var emptyState: some View {
        RiffaEmptyState(
            title: "Choose two files or bundles",
            description: "Compare version fields, Mach-O architectures, executable digests, and code-signature summaries without launching either input.",
            systemImage: "clock.arrow.circlepath"
        ) {
            HStack {
                Button("Choose Left") { model.chooseResource(for: .left) }
                    .buttonStyle(
                        RiffaButtonStyle(model.leftURL == nil ? .primary : .secondary)
                    )
                Button("Choose Right") { model.chooseResource(for: .right) }
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

private struct VersionPathButton: View {
    let title: String
    let url: URL?
    let action: () -> Void

    var body: some View {
        RiffaResourcePathButton(
            title: title,
            url: url,
            emptyTitle: "Choose a file or bundle…",
            systemImage: "shippingbox",
            accessibilityHint: "Choose a file or bundle",
            action: action
        )
        .accessibilityValue(
            url?.path(percentEncoded: false)
                ?? RiffaLocalization.string("No file or bundle selected")
        )
    }
}

private struct VersionResourceSummary: View {
    let side: String
    let snapshot: VersionResourceSnapshot
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        RiffaPanel(level: .one, padding: RiffaSpacing.sm) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Image(systemName: versionResourceSymbol(snapshot.kind))
                        .font(.title3)
                        .foregroundStyle(theme.inkMuted)
                        .frame(width: 38, height: 38)
                        .background(
                            theme.surface(.three),
                            in: RoundedRectangle(cornerRadius: RiffaRadius.md)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            verbatim: "\(RiffaLocalization.string(side)): "
                                + snapshot.displayName
                        )
                            .riffaText(.body)
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Text(verbatim: versionResourceKindTitle(snapshot.kind))
                            .riffaText(.caption)
                            .foregroundStyle(theme.inkSubtle)
                    }
                    Spacer()
                    RiffaStatusBadge(
                        verbatim: versionSignatureTitle(snapshot.codeSignature.status),
                        systemImage: versionSignatureSymbol(snapshot.codeSignature.status),
                        tone: versionSignatureTone(snapshot.codeSignature.status)
                    )
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    VersionSummaryRow(
                        label: "Version",
                        value: versionDisplay(snapshot)
                    )
                    VersionSummaryRow(
                        label: "Architectures",
                        value: architectureDisplay(snapshot.architectures)
                    )
                    VersionSummaryRow(
                        label: "Identifier",
                        value: snapshot.bundleIdentifier ?? "—"
                    )
                    VersionSummaryRow(
                        label: "Signing team",
                        value: snapshot.codeSignature.teamIdentifier ?? "—"
                    )
                    VersionSummaryRow(
                        label: "Signing ID",
                        value: snapshot.codeSignature.signingIdentifier ?? "—"
                    )
                    VersionSummaryRow(
                        label: "Main binary",
                        value: snapshot.fileByteCount.formatted(.byteCount(style: .file))
                    )
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("SHA-256")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.inkSubtle)
                    Text(snapshot.sha256)
                        .font(.caption2.monospaced())
                        .foregroundStyle(theme.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

private struct VersionSummaryRow: View {
    let label: String
    let value: String
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        GridRow {
            Text(LocalizedStringKey(label))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.inkSubtle)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.caption)
                .foregroundStyle(theme.inkMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }
}

private struct VersionFieldStatusLabel: View {
    let status: VersionFieldComparisonStatus
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        Label {
            Text(
                verbatim: RiffaLocalization.string(
                    status == .same ? "Same" : "Different"
                )
            )
        } icon: {
            Image(
                systemName: status == .same
                    ? "equal.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(status == .same ? theme.inkSubtle : theme.warning)
    }
}

private func versionDisplay(_ snapshot: VersionResourceSnapshot) -> String {
    let short = snapshot.shortVersionString ?? "—"
    guard let build = snapshot.bundleVersion, !build.isEmpty else { return short }
    return "\(short) (\(build))"
}

private func architectureDisplay(_ architectures: [VersionArchitecture]) -> String {
    guard !architectures.isEmpty else {
        return RiffaLocalization.string("No Mach-O architectures")
    }
    return architectures.map(\.displayName).joined(separator: ", ")
}

private func versionValueText(
    _ value: VersionComparisonValue,
    field: VersionComparisonField
) -> String {
    switch value {
    case let .string(value):
        return field == .kind || field == .signatureStatus
            ? RiffaLocalization.string(value)
            : value
    case let .integer(value):
        if field == .fileByteCount {
            return value.formatted(.byteCount(style: .file))
        }
        return String(value)
    case let .strings(values):
        return values.isEmpty ? "—" : values.joined(separator: ", ")
    case .null:
        return "—"
    }
}

private func versionFieldLabel(_ field: VersionComparisonField) -> String {
    let key = switch field {
    case .displayName: "Display name"
    case .kind: "Resource kind"
    case .bundleIdentifier: "Bundle identifier"
    case .shortVersionString: "Short version"
    case .bundleVersion: "Bundle version"
    case .packageType: "Package type"
    case .minimumSystemVersion: "Minimum system version"
    case .architectures: "Architectures"
    case .fileByteCount: "Main binary bytes"
    case .sha256: "Main binary SHA-256"
    case .signatureStatus: "Signature status"
    case .signingTeamIdentifier: "Signing team identifier"
    case .signingIdentifier: "Signing identifier"
    case .signatureDiagnosticCode: "Signature diagnostic code"
    }
    return RiffaLocalization.string(key)
}

private func versionResourceKindTitle(_ kind: VersionResourceKind) -> String {
    let key = switch kind {
    case .applicationBundle: "Application bundle"
    case .framework: "Framework"
    case .bundle: "Bundle"
    case .executable: "Mach-O executable"
    case .dynamicLibrary: "Dynamic library"
    case .machO: "Mach-O binary"
    case .regularFile: "Regular file"
    }
    return RiffaLocalization.string(key)
}

private func versionResourceSymbol(_ kind: VersionResourceKind) -> String {
    switch kind {
    case .applicationBundle: "app"
    case .framework, .bundle: "shippingbox.fill"
    case .executable, .dynamicLibrary, .machO: "cpu"
    case .regularFile: "doc.fill"
    }
}

private func versionSignatureTitle(_ status: VersionCodeSignatureStatus) -> String {
    let key = switch status {
    case .valid: "Signature valid"
    case .invalid: "Signature invalid"
    case .unsigned: "Unsigned"
    case .notApplicable: "Not applicable"
    case .unavailable: "Unavailable"
    }
    return RiffaLocalization.string(key)
}

private func versionSignatureTone(_ status: VersionCodeSignatureStatus) -> RiffaStatusTone {
    switch status {
    case .valid: .success
    case .invalid: .danger
    case .unsigned: .warning
    case .notApplicable, .unavailable: .neutral
    }
}

private func versionSignatureSymbol(_ status: VersionCodeSignatureStatus) -> String {
    switch status {
    case .valid: "checkmark.shield"
    case .invalid: "xmark.shield"
    case .unsigned: "exclamationmark.triangle"
    case .notApplicable: "minus.circle"
    case .unavailable: "questionmark.circle"
    }
}
