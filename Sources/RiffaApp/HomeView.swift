import SwiftUI

struct RiffaRootView: View {
    @EnvironmentObject private var comparisonOpenBroker: ComparisonOpenBroker
    @Environment(\.riffaTheme) private var theme
    @State private var selection: SessionKind?
    @State private var externalRequest: ExternalOpenRequest?
    @State private var pendingExternalURLs: [URL] = []
    @State private var externalOpenTask: Task<Void, Never>?
    @State private var externalOpenError: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    sessionRow(.folderCompare)
                    sessionRow(.textCompare)
                    sessionRow(.textPatch)
                    sessionRow(.hexCompare)
                    sessionRow(.mediaCompare)
                    sessionRow(.imageCompare)
                    sessionRow(.pdfCompare)
                    sessionRow(.officeCompare)
                    sessionRow(.archiveCompare)
                    sessionRow(.metadataCompare)
                    sessionRow(.versionCompare)
                    sessionRow(.tableCompare)
                } header: {
                    sidebarSectionTitle("Compare")
                }

                Section {
                    sessionRow(.folderMerge)
                    sessionRow(.folderSync)
                    sessionRow(.textMerge)
                } header: {
                    sidebarSectionTitle("Merge & Sync")
                }
            }
            .navigationTitle("Riffa")
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(theme.surface(.one))
            .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 286)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    RiffaHairline()
                    HStack(spacing: RiffaSpacing.xs) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(theme.secure)
                        Text("Local by default")
                            .foregroundStyle(theme.inkSubtle)
                        Spacer()
                        Text("0.1")
                            .foregroundStyle(theme.inkTertiary)
                    }
                    .riffaText(.caption)
                    .padding(.horizontal, RiffaSpacing.sm)
                    .padding(.vertical, 10)
                    .background(theme.surface(.one))
                }
            }
        } detail: {
            ZStack(alignment: .topLeading) {
                theme.canvas
                    .ignoresSafeArea()
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .riffaCoordinatedWindowDrops(fallback: openDroppedResources)
        .background(ComparisonWindowRegistrationView())
        .focusedSceneValue(\.riffaSessionSelection, $selection)
        .onOpenURL { enqueueExternalURL($0) }
        .onChange(of: comparisonOpenBroker.request, initial: true) { _, request in
            guard let request,
                  comparisonOpenBroker.claimExternalOpen(request) else {
                return
            }
            acceptBrokerRequest(request)
        }
        .onChange(of: selection) { _, newValue in
            if let externalRequest, externalRequest.kind != newValue {
                self.externalRequest = nil
            }
        }
        .alert(
            "Could not open comparison",
            isPresented: Binding(
                get: { externalOpenError != nil },
                set: { if !$0 { externalOpenError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: {
                Text(
                    verbatim: externalOpenError
                        ?? RiffaLocalization.string("Unknown error")
                )
            }
        )
    }

    private func sidebarSectionTitle(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .textCase(.uppercase)
            .riffaText(.eyebrow)
            .foregroundStyle(theme.inkTertiary)
            .padding(.top, RiffaSpacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func sessionRow(_ kind: SessionKind) -> some View {
        let isSelected = selection == kind
        return HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isSelected ? theme.accentHover : theme.inkSubtle)
                .frame(width: 18)

            Text(kind.titleKey)
                .riffaText(.bodySmall)
                .foregroundStyle(isSelected ? theme.ink : theme.inkMuted)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, RiffaSpacing.xs)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .listRowInsets(
            EdgeInsets(
                top: 1,
                leading: RiffaSpacing.xxs,
                bottom: 1,
                trailing: RiffaSpacing.xxs
            )
        )
        .listRowBackground(
            RoundedRectangle(cornerRadius: RiffaRadius.sm)
                .fill(isSelected ? theme.accent.opacity(0.16) : .clear)
        )
        .tag(kind)
        .accessibilityLabel(Text(kind.titleKey))
        .accessibilityHint("Open this comparison type")
    }

    @ViewBuilder
    private var detail: some View {
        if let selection {
            ComparisonSessionContentView(
                kind: selection,
                initialURLs: initialURLs(for: selection),
                initialOptions: initialOptions(for: selection)
            )
            .id(viewID(for: selection))
        } else {
            HomeView(selection: $selection)
        }
    }

    private func openDroppedResources(_ urls: [URL]) throws {
        let request = try comparisonOpenBroker.prepareExternalOpen(urls: urls)
        acceptBrokerRequest(request)
    }

    private func initialURLs(for kind: SessionKind) -> [URL] {
        externalRequest?.kind == kind ? externalRequest?.urls ?? [] : []
    }

    private func initialOptions(for kind: SessionKind) -> [String: String] {
        externalRequest?.kind == kind ? externalRequest?.options ?? [:] : [:]
    }

    private func viewID(for kind: SessionKind) -> String {
        guard externalRequest?.kind == kind else { return "default-\(kind.rawValue)" }
        return externalRequest?.id.uuidString ?? "default-\(kind.rawValue)"
    }

    private func enqueueExternalURL(_ url: URL) {
        // Preserve a fourth URL as an overflow sentinel so a multi-item Finder
        // open reports the unsupported count instead of silently discarding an
        // input. Additional events in the same debounce window cannot change
        // that outcome and are intentionally not retained.
        if pendingExternalURLs.count < 4 {
            pendingExternalURLs.append(url)
        }
        externalOpenTask?.cancel()
        externalOpenTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let urls = pendingExternalURLs
            pendingExternalURLs.removeAll()
            do {
                let request = try comparisonOpenBroker.prepareExternalOpen(urls: urls)
                externalRequest = request
                selection = request.kind
            } catch {
                externalOpenError = error.localizedDescription
            }
        }
    }

    private func acceptBrokerRequest(_ request: ExternalOpenRequest) {
        externalOpenTask?.cancel()
        pendingExternalURLs.removeAll()
        externalRequest = request
        selection = request.kind
    }
}

struct HomeView: View {
    @Binding var selection: SessionKind?
    @Environment(\.riffaTheme) private var theme

    private let comparisonKinds: [SessionKind] = [
        .folderCompare,
        .textCompare,
        .textPatch,
        .hexCompare,
        .mediaCompare,
        .imageCompare,
        .pdfCompare,
        .officeCompare,
        .archiveCompare,
        .metadataCompare,
        .versionCompare,
        .tableCompare
    ]

    private let mergeKinds: [SessionKind] = [
        .folderMerge,
        .folderSync,
        .textMerge
    ]

    private let columns = [
        GridItem(.adaptive(minimum: 228, maximum: 320), spacing: RiffaSpacing.sm)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RiffaSpacing.xl) {
                HStack(alignment: .center, spacing: RiffaSpacing.lg) {
                    RiffaMark()
                        .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                        Text("NATIVE COMPARISON FOR MAC")
                            .riffaText(.eyebrow)
                            .foregroundStyle(theme.accentHover)
                        Text("See what changed.")
                            .riffaText(.headline)
                            .foregroundStyle(theme.ink)
                        Text("Compare, understand, and safely reconcile files on your Mac.")
                            .riffaText(.bodyLarge)
                            .foregroundStyle(theme.inkSubtle)
                    }
                }
                .accessibilityElement(children: .combine)

                sessionSection(
                    eyebrow: "START A SESSION",
                    title: "Compare",
                    description: "Inspect content, structure, metadata, and versions side by side.",
                    kinds: comparisonKinds
                )

                sessionSection(
                    eyebrow: "RECONCILE CHANGES",
                    title: "Merge & Sync",
                    description: "Preview the result first, then apply deliberate local changes.",
                    kinds: mergeKinds
                )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: RiffaSpacing.xs) {
                        platformBadges
                    }
                    VStack(alignment: .leading, spacing: RiffaSpacing.xs) {
                        platformBadges
                    }
                }
            }
            .padding(RiffaSpacing.xl)
            .frame(maxWidth: 1120, alignment: .leading)
        }
        .background(theme.canvas)
    }

    @ViewBuilder
    private var platformBadges: some View {
        RiffaStatusBadge("Apple Silicon Native", systemImage: "cpu")
        RiffaStatusBadge("Swift", systemImage: "swift")
        RiffaStatusBadge(
            "Files stay local",
            systemImage: "lock.shield.fill",
            tone: .secure
        )
    }

    private func sessionSection(
        eyebrow: String,
        title: String,
        description: String,
        kinds: [SessionKind]
    ) -> some View {
        VStack(alignment: .leading, spacing: RiffaSpacing.md) {
            VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                Text(LocalizedStringKey(eyebrow))
                    .riffaText(.eyebrow)
                    .foregroundStyle(theme.inkTertiary)
                Text(LocalizedStringKey(title))
                    .riffaText(.cardTitle)
                    .foregroundStyle(theme.ink)
                Text(LocalizedStringKey(description))
                    .riffaText(.bodySmall)
                    .foregroundStyle(theme.inkSubtle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            LazyVGrid(
                columns: columns,
                alignment: .leading,
                spacing: RiffaSpacing.sm
            ) {
                ForEach(kinds) { kind in
                    SessionCard(kind: kind) {
                        selection = kind
                    }
                }
            }
        }
    }
}

private struct SessionCard: View {
    let kind: SessionKind
    let action: () -> Void
    @Environment(\.riffaTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            RiffaCard(isInteractive: true) {
                VStack(alignment: .leading, spacing: RiffaSpacing.md) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 18, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(theme.accentHover)
                        .frame(width: 38, height: 38)
                        .background(
                            theme.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: RiffaRadius.md)
                        )

                    VStack(alignment: .leading, spacing: RiffaSpacing.xxs) {
                        HStack(spacing: RiffaSpacing.xs) {
                            Text(kind.titleKey)
                                .riffaText(.body)
                                .foregroundStyle(theme.ink)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .imageScale(.small)
                                .foregroundStyle(theme.inkTertiary)
                                .accessibilityHidden(true)
                        }
                        Text(kind.subtitleKey)
                            .riffaText(.bodySmall)
                            .foregroundStyle(theme.inkSubtle)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .riffaFocusRing(isFocused, cornerRadius: RiffaRadius.lg)
        .accessibilityLabel(Text(kind.titleKey))
        .accessibilityValue(Text(kind.subtitleKey))
        .accessibilityHint("Open this comparison type")
    }
}

struct RiffaMark: View {
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let outerRadius = side * RiffaRadius.lg / 64
            let documentRadius = side * RiffaRadius.xs / 64
            let outerStroke = max(1, side / 64)
            let markStroke = max(1, side / 32)

            ZStack {
                RoundedRectangle(cornerRadius: outerRadius)
                    .fill(theme.surface(.two))
                RoundedRectangle(cornerRadius: outerRadius)
                    .strokeBorder(theme.hairlineStrong, lineWidth: outerStroke)

                HStack(spacing: side * 7 / 64) {
                    RoundedRectangle(cornerRadius: documentRadius)
                        .strokeBorder(theme.accentHover, lineWidth: markStroke)
                        .frame(width: side * 14 / 64, height: side * 29 / 64)
                        .offset(y: -side * 3 / 64)

                    RiffaSplitMark()
                        .stroke(
                            theme.accent,
                            style: StrokeStyle(
                                lineWidth: markStroke,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .frame(width: side * 7 / 64, height: side * 28 / 64)

                    RoundedRectangle(cornerRadius: documentRadius)
                        .fill(theme.accent)
                        .frame(width: side * 14 / 64, height: side * 29 / 64)
                        .offset(y: side * 3 / 64)
                }
            }
            .frame(width: side, height: side)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Riffa")
    }
}

private struct RiffaSplitMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.34))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.66))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
