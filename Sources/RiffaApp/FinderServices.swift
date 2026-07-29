import AppKit
import RiffaCore
import SwiftUI

/// Owns the process-lifetime objects shared by SwiftUI and the NSServices
/// entry point. In particular, the services provider is strongly retained for
/// the entire app process and pending paths are never persisted.
@MainActor
final class RiffaApplicationRuntime {
    static let shared = RiffaApplicationRuntime()

    let securityScopedAccessRegistry: SecurityScopedAccessRegistry
    let comparisonOpenBroker: ComparisonOpenBroker
    let comparisonWindowPresenter: FinderServiceComparisonWindowPresenter
    let finderServiceProvider: RiffaFinderServiceProvider

    private init() {
        let registry = SecurityScopedAccessRegistry()
        let broker = ComparisonOpenBroker(accessRegistry: registry)
        let presenter = FinderServiceComparisonWindowPresenter()
        securityScopedAccessRegistry = registry
        comparisonOpenBroker = broker
        comparisonWindowPresenter = presenter
        finderServiceProvider = RiffaFinderServiceProvider(
            accessRegistry: registry,
            broker: broker,
            windowPresenter: presenter
        )
    }
}

/// Installs the provider before launch completes, which also covers a service
/// invocation that cold-launches the application.
@MainActor
final class RiffaApplicationDelegate: NSObject, NSApplicationDelegate {
    private let runtime: RiffaApplicationRuntime
    private let serviceProvider: RiffaFinderServiceProvider

    override init() {
        let runtime = RiffaApplicationRuntime.shared
        self.runtime = runtime
        serviceProvider = runtime.finderServiceProvider
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = notification
        NSApplication.shared.servicesProvider = serviceProvider
    }

    /// Routes files opened by `open -a Riffa ...` (and by the CLI handoff)
    /// through the same classifier and security-scoped access path as Finder
    /// Services and drag-and-drop.
    func application(_ application: NSApplication, open urls: [URL]) {
        _ = application
        guard !urls.isEmpty else { return }
        do {
            let request = try runtime.comparisonOpenBroker.prepareExternalOpen(
                urls: urls
            )
            runtime.comparisonOpenBroker.publishExternalOpen(request) {
                self.runtime.comparisonWindowPresenter.revealComparisonWindow()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = RiffaLocalization.string("Could not open comparison")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: RiffaLocalization.string("OK"))
            alert.runModal()
        }
    }
}

@MainActor
final class RiffaFinderServiceProvider: NSObject {
    private enum Action {
        case selectLeft
        case compare
    }

    private let accessRegistry: SecurityScopedAccessRegistry
    private let broker: ComparisonOpenBroker
    private let windowPresenter: FinderServiceComparisonWindowPresenter
    private let classifier = LocalFinderServiceResourceClassifier()
    private var pairingState = FinderServicePairingStateMachine<URL>()

    init(
        accessRegistry: SecurityScopedAccessRegistry,
        broker: ComparisonOpenBroker,
        windowPresenter: FinderServiceComparisonWindowPresenter
    ) {
        self.accessRegistry = accessRegistry
        self.broker = broker
        self.windowPresenter = windowPresenter
        super.init()
    }

    @objc(riffaSelectLeftFile:userData:error:)
    func riffaSelectLeftFile(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        _ = userData
        perform(
            .selectLeft,
            expectedKind: .regularFile,
            pasteboard: pasteboard,
            errorPointer: errorPointer
        )
    }

    @objc(riffaCompareFiles:userData:error:)
    func riffaCompareFiles(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        _ = userData
        perform(
            .compare,
            expectedKind: .regularFile,
            pasteboard: pasteboard,
            errorPointer: errorPointer
        )
    }

    @objc(riffaSelectLeftFolder:userData:error:)
    func riffaSelectLeftFolder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        _ = userData
        perform(
            .selectLeft,
            expectedKind: .directory,
            pasteboard: pasteboard,
            errorPointer: errorPointer
        )
    }

    @objc(riffaCompareFolders:userData:error:)
    func riffaCompareFolders(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        _ = userData
        perform(
            .compare,
            expectedKind: .directory,
            pasteboard: pasteboard,
            errorPointer: errorPointer
        )
    }

    private func perform(
        _ action: Action,
        expectedKind: FinderServiceResourceKind,
        pasteboard: NSPasteboard,
        errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        errorPointer.pointee = nil
        do {
            let urls = try localFileURLs(from: pasteboard)
            try validateCount(urls.count, for: action)
            let resources = try urls.map(registerAndClassify)

            switch action {
            case .selectLeft:
                try pairingState.selectLeft(resources, expectedKind: expectedKind)
            case .compare:
                // Work on a value copy. Preparation or publication failures
                // therefore cannot consume a valid pending left side.
                var proposedState = pairingState
                let pair = try proposedState.compare(
                    resources,
                    expectedKind: expectedKind
                )
                let freshPair = try reclassify(pair, expectedKind: expectedKind)
                let request: ExternalOpenRequest
                do {
                    request = try broker.prepareExternalOpen(
                        urls: [freshPair.left.value, freshPair.right.value]
                    )
                } catch {
                    throw FinderServiceProviderError.couldNotPrepareComparison
                }

                pairingState = proposedState
                broker.publishExternalOpen(request) { [windowPresenter] in
                    windowPresenter.revealComparisonWindow()
                }
            }
        } catch {
            errorPointer.pointee = safeMessage(for: error) as NSString
        }
    }

    private func validateCount(_ count: Int, for action: Action) throws {
        switch action {
        case .selectLeft:
            guard count == 1 else {
                throw FinderServicePairingError.selectLeftRequiresOne(actual: count)
            }
        case .compare:
            guard count == 1 || count == 2 else {
                throw FinderServicePairingError.compareRequiresOneOrTwo(actual: count)
            }
        }
    }

    private func registerAndClassify(
        _ url: URL
    ) throws -> FinderServiceResource<URL> {
        let registered: URL
        do {
            registered = try accessRegistry.registerIncomingURL(url)
        } catch {
            throw FinderServiceProviderError.securityScopedAccessUnavailable
        }
        return try classifier.classify(registered)
    }

    private func reclassify(
        _ pair: FinderServicePair<URL>,
        expectedKind: FinderServiceResourceKind
    ) throws -> FinderServicePair<URL> {
        let left = try classifier.classify(pair.left.value)
        let right = try classifier.classify(pair.right.value)
        for resource in [left, right] where resource.kind != expectedKind {
            throw FinderServicePairingError.resourceKindMismatch(
                expected: expectedKind,
                actual: resource.kind
            )
        }
        return FinderServicePair(left: left, right: right)
    }

    private func localFileURLs(from pasteboard: NSPasteboard) throws -> [URL] {
        if let items = pasteboard.pasteboardItems, !items.isEmpty {
            let fileURLStrings = items.compactMap { item in
                item.string(forType: .fileURL)
            }
            if !fileURLStrings.isEmpty {
                guard fileURLStrings.count == items.count else {
                    throw FinderServiceProviderError.invalidPasteboard
                }
                return try fileURLStrings.map(parseLocalFileURL)
            }
        }

        // Compatibility with older Services pasteboards. Finder on current
        // macOS normally supplies one public.file-url item per selection.
        let legacyType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: legacyType) as? [String] {
            return try paths.map { path in
                guard NSString(string: path).isAbsolutePath else {
                    throw FinderServiceInputError.nonLocalInput
                }
                return URL(fileURLWithPath: path)
            }
        }
        throw FinderServiceProviderError.invalidPasteboard
    }

    private func parseLocalFileURL(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              url.isFileURL,
              NSString(string: url.path).isAbsolutePath else {
            throw FinderServiceInputError.nonLocalInput
        }
        return url
    }

    private func safeMessage(for error: any Error) -> String {
        if let error = error as? FinderServicePairingError {
            return localizedPairingMessage(error)
        }
        if let error = error as? FinderServiceInputError {
            return localizedInputMessage(error)
        }
        if let error = error as? FinderServiceProviderError {
            return error.localizedDescription
        }
        return FinderServiceProviderError.couldNotPrepareComparison.localizedDescription
    }

    private func localizedPairingMessage(
        _ error: FinderServicePairingError
    ) -> String {
        switch error {
        case let .selectLeftRequiresOne(actual):
            return String(
                localized: "Select Left requires exactly one item; \(actual) were supplied.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .compareRequiresOneOrTwo(actual):
            return String(
                localized: "Compare requires one item with a pending left side, or exactly two items; \(actual) were supplied.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .resourceKindMismatch(expected, actual):
            let expectedKind = localizedResourceKind(expected, plural: true)
            let actualKind = localizedResourceKind(actual, plural: false)
            return String(
                localized: "This service accepts \(expectedKind), but a \(actualKind) was supplied.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .pendingLeftUnavailable(expected):
            let expectedKind = localizedResourceKind(expected, plural: false)
            return String(
                localized: "No pending left \(expectedKind) is available. Use Select Left first, or select two items.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .pendingKindMismatch(expected, actual):
            let expectedKind = localizedResourceKind(expected, plural: false)
            let actualKind = localizedResourceKind(actual, plural: false)
            return String(
                localized: "The pending left item is a \(actualKind), not a \(expectedKind). Select a matching left item first.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        }
    }

    private func localizedInputMessage(
        _ error: FinderServiceInputError
    ) -> String {
        switch error {
        case .nonLocalInput:
            return RiffaLocalization.string(
                "Finder Services accept only absolute local file URLs."
            )
        case let .inspectionFailed(code):
            return String(
                localized: "A selected item could not be inspected safely (error \(code)).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .unsupportedNodeType:
            return RiffaLocalization.string(
                "Finder Services accept only regular files or real folders; links and special filesystem nodes are not supported."
            )
        }
    }

    private func localizedResourceKind(
        _ kind: FinderServiceResourceKind,
        plural: Bool
    ) -> String {
        switch (kind, plural) {
        case (.regularFile, false):
            RiffaLocalization.string("file")
        case (.regularFile, true):
            RiffaLocalization.string("files")
        case (.directory, false):
            RiffaLocalization.string("folder")
        case (.directory, true):
            RiffaLocalization.string("folders")
        }
    }
}

private enum FinderServiceProviderError: Error, LocalizedError {
    case invalidPasteboard
    case securityScopedAccessUnavailable
    case couldNotPrepareComparison

    var errorDescription: String? {
        switch self {
        case .invalidPasteboard:
            RiffaLocalization.string(
                "The service received an invalid selection. Choose local files or folders in Finder."
            )
        case .securityScopedAccessUnavailable:
            RiffaLocalization.string(
                "macOS did not grant access to one of the selected items. Select the items in Finder and try again."
            )
        case .couldNotPrepareComparison:
            RiffaLocalization.string(
                "Riffa could not prepare the selected comparison safely. The pending left item was not consumed."
            )
        }
    }
}

/// Tracks real SwiftUI comparison windows without persisting their inputs.
/// When a service cold-launches the app, SwiftUI normally creates the default
/// WindowGroup first. A delayed AppKit-hosted fallback covers the case where no
/// comparison scene exists (for example, after all windows were closed).
@MainActor
final class FinderServiceComparisonWindowPresenter {
    private let comparisonWindows = NSHashTable<NSWindow>.weakObjects()
    private var fallbackWindowController: NSWindowController?
    private var revealTask: Task<Void, Never>?

    func register(_ window: NSWindow) {
        comparisonWindows.add(window)
    }

    func revealComparisonWindow() {
        revealTask?.cancel()
        NSApplication.shared.activate(ignoringOtherApps: true)
        if bringExistingWindowForward() {
            return
        }

        // Give a cold-started WindowGroup one run-loop interval to mount and
        // register before constructing a fallback window.
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            if !self.bringExistingWindowForward() {
                self.showFallbackWindow()
            }
        }
    }

    private func bringExistingWindowForward() -> Bool {
        let windows = comparisonWindows.allObjects
        guard let window = windows.first(where: \.isKeyWindow)
            ?? windows.first(where: \.isVisible)
            ?? windows.last else {
            return false
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func showFallbackWindow() {
        if let window = fallbackWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let runtime = RiffaApplicationRuntime.shared
        let root = RiffaRootView()
            .environmentObject(runtime.comparisonOpenBroker)
            .environmentObject(runtime.securityScopedAccessRegistry)
            .frame(minWidth: 980, minHeight: 640)
            .riffaAppTheme()
        let hostingController = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Riffa"
        window.contentMinSize = NSSize(width: 980, height: 640)
        window.contentViewController = hostingController
        window.center()

        let controller = NSWindowController(window: window)
        fallbackWindowController = controller
        register(window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

struct ComparisonWindowRegistrationView: NSViewRepresentable {
    func makeNSView(context: Context) -> ComparisonWindowRegistrationNSView {
        ComparisonWindowRegistrationNSView()
    }

    func updateNSView(
        _ nsView: ComparisonWindowRegistrationNSView,
        context: Context
    ) {
        _ = nsView
        _ = context
    }
}

final class ComparisonWindowRegistrationNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        RiffaApplicationRuntime.shared.comparisonWindowPresenter.register(window)
    }
}
