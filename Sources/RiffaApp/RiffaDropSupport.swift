import AppKit
import Darwin
import Foundation
import SwiftUI

enum RiffaDropRole: String, CaseIterable, Hashable {
    case base
    case left
    case right
    case patch
    case target

    var title: String {
        switch self {
        case .base: RiffaLocalization.string("Base")
        case .left: RiffaLocalization.string("Left")
        case .right: RiffaLocalization.string("Right")
        case .patch: RiffaLocalization.string("Patch")
        case .target: RiffaLocalization.string("Target")
        }
    }

    var systemImage: String {
        switch self {
        case .base: "circle.dotted"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .patch: "doc.badge.arrow.up"
        case .target: "scope"
        }
    }
}

/// Matches the final-component behavior of each local comparison engine.
///
/// Some readers intentionally follow a final symbolic link and then require a
/// regular file, while folder, hex, and version comparisons explicitly use
/// no-follow semantics. Metadata comparison is the one mode that preserves any
/// existing vnode as the value being inspected.
enum RiffaDroppedResourceKind: Equatable {
    case realDirectory
    case realRegularFile
    case regularFileFollowingFinalSymbolicLink
    case realFileOrDirectory
    case anyExistingEntry

    var instruction: String {
        switch self {
        case .realDirectory:
            RiffaLocalization.string("Drop one local folder here.")
        case .realRegularFile, .regularFileFollowingFinalSymbolicLink:
            RiffaLocalization.string("Drop one local file here.")
        case .realFileOrDirectory, .anyExistingEntry:
            RiffaLocalization.string("Drop one local file or folder here.")
        }
    }
}

struct RiffaDropZone {
    let role: RiffaDropRole
    let acceptedKind: RiffaDroppedResourceKind
    let onDrop: @MainActor (URL) -> Void

    init(
        role: RiffaDropRole,
        acceptedKind: RiffaDroppedResourceKind,
        onDrop: @escaping @MainActor (URL) -> Void
    ) {
        self.role = role
        self.acceptedKind = acceptedKind
        self.onDrop = onDrop
    }
}

struct RiffaWindowDropRegistrar {
    let install: @MainActor (UUID, [RiffaDropZone]) -> Void
    let remove: @MainActor (UUID) -> Void
    let handleGroupDrop: @MainActor ([URL]) -> Bool
}

private struct RiffaWindowDropRegistrarKey: EnvironmentKey {
    static let defaultValue: RiffaWindowDropRegistrar? = nil
}

extension EnvironmentValues {
    var riffaWindowDropRegistrar: RiffaWindowDropRegistrar? {
        get { self[RiffaWindowDropRegistrarKey.self] }
        set { self[RiffaWindowDropRegistrarKey.self] = newValue }
    }
}

enum RiffaDropAssignment {
    static func zoneIndices(
        resourceCount: Int,
        roles: [RiffaDropRole],
        dropX: CGFloat,
        availableWidth: CGFloat
    ) throws -> [Int] {
        guard resourceCount > 0 else {
            throw RiffaDropError.noResources
        }
        guard !roles.isEmpty else {
            throw RiffaDropError.noDropZones
        }
        guard resourceCount <= roles.count else {
            throw RiffaDropError.tooManyResources(maximum: roles.count)
        }

        if resourceCount == 1 {
            let normalizedWidth = max(availableWidth, 1)
            let normalizedX = min(max(dropX, 0), normalizedWidth.nextDown)
            let index = min(
                Int(normalizedX / normalizedWidth * CGFloat(roles.count)),
                roles.count - 1
            )
            return [index]
        }

        if resourceCount == 2,
           let left = roles.firstIndex(of: .left),
           let right = roles.firstIndex(of: .right) {
            return [left, right]
        }

        guard resourceCount == roles.count else {
            throw RiffaDropError.unsupportedResourceCount(
                actual: resourceCount,
                expected: roles.count
            )
        }
        return Array(roles.indices)
    }
}

enum RiffaResourceDropRouting: Equatable {
    case local(URL)
    case coordinated([URL])

    static func route(
        _ urls: [URL],
        hasWindowCoordinator: Bool
    ) throws -> RiffaResourceDropRouting {
        if urls.count == 1, let url = urls.first {
            return .local(url)
        }
        if urls.count > 1, hasWindowCoordinator {
            return .coordinated(urls)
        }
        throw RiffaDropError.requiresExactlyOneResource
    }
}

enum RiffaDropError: Error, LocalizedError {
    case noResources
    case noDropZones
    case requiresExactlyOneResource
    case tooManyResources(maximum: Int)
    case unsupportedResourceCount(actual: Int, expected: Int)
    case notLocalFile
    case unavailable
    case expectedFolder
    case expectedFile
    case expectedFileOrFolder

    var errorDescription: String? {
        switch self {
        case .noResources:
            RiffaLocalization.string("The drop does not contain a local item.")
        case .noDropZones:
            RiffaLocalization.string("This view has no available drop target.")
        case .requiresExactlyOneResource:
            RiffaLocalization.string("Drop exactly one item on a specific input.")
        case let .tooManyResources(maximum):
            String(
                localized: "Drop no more than \(maximum) items at once.",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case let .unsupportedResourceCount(actual, expected):
            String(
                localized: "This workflow needs either one item for a specific side or exactly \(expected) items; the drop contains \(actual).",
                bundle: RiffaLocalization.localizedBundle,
                locale: RiffaLocalization.locale
            )
        case .notLocalFile:
            RiffaLocalization.string("Only local files and folders can be dropped.")
        case .unavailable:
            RiffaLocalization.string("The dropped item is unavailable.")
        case .expectedFolder:
            RiffaLocalization.string("This input requires a folder.")
        case .expectedFile:
            RiffaLocalization.string("This input requires a file.")
        case .expectedFileOrFolder:
            RiffaLocalization.string("This input requires a regular file or folder.")
        }
    }
}

struct RiffaDroppedResourceValidator {
    static func validateLocalFileURL(_ url: URL) throws {
        guard url.isFileURL,
              NSString(string: url.path).isAbsolutePath else {
            throw RiffaDropError.notLocalFile
        }
    }

    static func validate(
        _ url: URL,
        as kind: RiffaDroppedResourceKind
    ) throws {
        try validateLocalFileURL(url)

        var information = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &information)
        }
        guard status == 0 else {
            throw RiffaDropError.unavailable
        }

        let entryKind = information.st_mode & S_IFMT
        switch kind {
        case .realDirectory:
            guard entryKind == S_IFDIR else {
                throw RiffaDropError.expectedFolder
            }
        case .realRegularFile:
            guard entryKind == S_IFREG else {
                throw RiffaDropError.expectedFile
            }
        case .regularFileFollowingFinalSymbolicLink:
            var targetInformation = stat()
            let targetStatus: Int32 = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                let descriptor = Darwin.open(
                    path,
                    O_RDONLY | O_CLOEXEC | O_NONBLOCK
                )
                guard descriptor >= 0 else { return Int32(-1) }
                defer { Darwin.close(descriptor) }
                return Darwin.fstat(descriptor, &targetInformation)
            }
            guard targetStatus == 0, targetInformation.st_mode & S_IFMT == S_IFREG else {
                throw RiffaDropError.expectedFile
            }
        case .realFileOrDirectory:
            guard entryKind == S_IFREG || entryKind == S_IFDIR else {
                throw RiffaDropError.expectedFileOrFolder
            }
        case .anyExistingEntry:
            break
        }
    }
}

/// Registers the containing `NSWindow` itself as the fallback drag
/// destination. SwiftUI drop destinations remain available for precise path
/// controls, while AppKit covers the rest of the content plus title bars,
/// unified toolbars, split-view dividers, and window chrome.
@MainActor
private struct RiffaWindowDropBridge: NSViewRepresentable {
    let onTargeted: @MainActor (Bool) -> Void
    let onDrop: @MainActor ([URL], CGPoint, CGSize) -> Bool

    func makeNSView(context: Context) -> RiffaWindowDropAttachmentView {
        let view = RiffaWindowDropAttachmentView()
        view.update(onTargeted: onTargeted, onDrop: onDrop)
        return view
    }

    func updateNSView(
        _ nsView: RiffaWindowDropAttachmentView,
        context: Context
    ) {
        _ = context
        nsView.update(onTargeted: onTargeted, onDrop: onDrop)
    }

    static func dismantleNSView(
        _ nsView: RiffaWindowDropAttachmentView,
        coordinator: ()
    ) {
        _ = coordinator
        nsView.detach()
    }
}

@MainActor
private final class RiffaWindowDropAttachmentView: NSView {
    private let registrationID = UUID()
    private weak var attachedWindow: NSWindow?
    private var onTargeted: @MainActor (Bool) -> Void = { _ in }
    private var onDrop: @MainActor ([URL], CGPoint, CGSize) -> Bool = {
        _, _, _ in false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    func update(
        onTargeted: @escaping @MainActor (Bool) -> Void,
        onDrop: @escaping @MainActor ([URL], CGPoint, CGSize) -> Bool
    ) {
        self.onTargeted = onTargeted
        self.onDrop = onDrop
        attachIfNeeded()
        guard let attachedWindow else { return }
        RiffaWindowDropRegistry.shared.update(
            window: attachedWindow,
            registrationID: registrationID,
            onTargeted: onTargeted,
            onDrop: onDrop
        )
    }

    func detach() {
        guard let attachedWindow else { return }
        RiffaWindowDropRegistry.shared.remove(
            window: attachedWindow,
            registrationID: registrationID
        )
        self.attachedWindow = nil
    }

    private func attachIfNeeded() {
        guard let window, window !== attachedWindow else { return }
        detach()
        attachedWindow = window
        RiffaWindowDropRegistry.shared.install(
            window: window,
            registrationID: registrationID,
            onTargeted: onTargeted,
            onDrop: onDrop
        )
    }
}

@MainActor
private final class RiffaWindowDropRegistry {
    static let shared = RiffaWindowDropRegistry()

    private let proxies = NSMapTable<
        NSWindow,
        RiffaWindowDropDelegateProxy
    >(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    func install(
        window: NSWindow,
        registrationID: UUID,
        onTargeted: @escaping @MainActor (Bool) -> Void,
        onDrop: @escaping @MainActor ([URL], CGPoint, CGSize) -> Bool
    ) {
        let proxy = proxy(for: window)
        proxy.install(
            registrationID: registrationID,
            onTargeted: onTargeted,
            onDrop: onDrop
        )
    }

    func update(
        window: NSWindow,
        registrationID: UUID,
        onTargeted: @escaping @MainActor (Bool) -> Void,
        onDrop: @escaping @MainActor ([URL], CGPoint, CGSize) -> Bool
    ) {
        let proxy = proxy(for: window)
        proxy.update(
            registrationID: registrationID,
            onTargeted: onTargeted,
            onDrop: onDrop
        )
    }

    func remove(window: NSWindow, registrationID: UUID) {
        guard let proxy = proxies.object(forKey: window) else { return }
        proxy.remove(registrationID: registrationID)
        guard proxy.isEmpty else { return }
        proxy.restoreForwardedDelegate()
        proxies.removeObject(forKey: window)
    }

    private func proxy(for window: NSWindow) -> RiffaWindowDropDelegateProxy {
        if let existing = proxies.object(forKey: window) {
            existing.ensureInstalled()
            return existing
        }

        let proxy = RiffaWindowDropDelegateProxy(window: window)
        proxies.setObject(proxy, forKey: window)
        proxy.ensureInstalled()
        return proxy
    }
}

@MainActor
private final class RiffaWindowDropDelegateProxy:
    NSObject,
    NSWindowDelegate,
    NSDraggingDestination
{
    private struct Registration {
        let onTargeted: @MainActor (Bool) -> Void
        let onDrop: @MainActor ([URL], CGPoint, CGSize) -> Bool
    }

    private weak var window: NSWindow?
    nonisolated(unsafe) private weak var forwardedDelegate:
        (any NSWindowDelegate)?
    private var registrations: [UUID: Registration] = [:]
    private var registrationOrder: [UUID] = []

    init(window: NSWindow) {
        self.window = window
        forwardedDelegate = window.delegate
        super.init()
    }

    var isEmpty: Bool {
        registrations.isEmpty
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector)
            || forwardedDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedDelegate?.responds(to: selector) == true {
            return forwardedDelegate
        }
        return super.forwardingTarget(for: selector)
    }

    func ensureInstalled() {
        guard let window, window.delegate !== self else { return }
        if let current = window.delegate, current !== self {
            forwardedDelegate = current
        }
        window.delegate = self
        window.registerForDraggedTypes([.fileURL])
    }

    func install(
        registrationID: UUID,
        onTargeted: @escaping @MainActor (Bool) -> Void,
        onDrop: @escaping @MainActor ([URL], CGPoint, CGSize) -> Bool
    ) {
        if registrations[registrationID] == nil {
            registrationOrder.append(registrationID)
        }
        registrations[registrationID] = Registration(
            onTargeted: onTargeted,
            onDrop: onDrop
        )
        ensureInstalled()
    }

    func update(
        registrationID: UUID,
        onTargeted: @escaping @MainActor (Bool) -> Void,
        onDrop: @escaping @MainActor ([URL], CGPoint, CGSize) -> Bool
    ) {
        install(
            registrationID: registrationID,
            onTargeted: onTargeted,
            onDrop: onDrop
        )
    }

    func remove(registrationID: UUID) {
        registrations.removeValue(forKey: registrationID)
        registrationOrder.removeAll { $0 == registrationID }
    }

    func restoreForwardedDelegate() {
        guard let window, window.delegate === self else { return }
        window.delegate = forwardedDelegate
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard canCopyLocalFiles(from: sender),
              let registration = activeRegistration else {
            return []
        }
        registration.onTargeted(true)
        return .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard canCopyLocalFiles(from: sender),
              activeRegistration != nil else {
            return []
        }
        return .copy
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        _ = sender
        activeRegistration?.onTargeted(false)
    }

    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        canCopyLocalFiles(from: sender) && activeRegistration != nil
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let window,
              let registration = activeRegistration else {
            return false
        }
        registration.onTargeted(false)
        let location = sender.draggingLocation
        return registration.onDrop(
            localFileURLs(from: sender),
            CGPoint(x: location.x, y: location.y),
            CGSize(width: window.frame.width, height: window.frame.height)
        )
    }

    func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        _ = sender
        activeRegistration?.onTargeted(false)
    }

    private var activeRegistration: Registration? {
        registrationOrder.last.flatMap { registrations[$0] }
    }

    private func canCopyLocalFiles(from sender: any NSDraggingInfo) -> Bool {
        sender.draggingSourceOperationMask.contains(.copy)
            && !localFileURLs(from: sender).isEmpty
    }

    private func localFileURLs(from sender: any NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        return objects.compactMap { object in
            guard let url = object as? NSURL else { return nil }
            return url as URL
        }
    }
}

extension View {
    func riffaWindowDropZones(_ zones: [RiffaDropZone]) -> some View {
        modifier(RiffaWindowDropZonesModifier(zones: zones))
    }

    /// Makes one outer window surface own every active session drop zone.
    /// Nested comparison views register their model-bound actions through the
    /// environment, while the fallback handles home/empty-window drops.
    func riffaCoordinatedWindowDrops(
        fallback: @escaping @MainActor ([URL]) throws -> Void
    ) -> some View {
        modifier(
            RiffaCoordinatedWindowDropModifier(fallback: fallback)
        )
    }

    func riffaResourceDropTarget(
        role: RiffaDropRole,
        acceptedKind: RiffaDroppedResourceKind,
        onDrop: @escaping @MainActor (URL) -> Void
    ) -> some View {
        modifier(
            RiffaResourceDropTargetModifier(
                zone: RiffaDropZone(
                    role: role,
                    acceptedKind: acceptedKind,
                    onDrop: onDrop
                )
            )
        )
    }

    func riffaAutomaticDropDestination(
        onDrop: @escaping @MainActor ([URL]) throws -> Void
    ) -> some View {
        modifier(RiffaAutomaticDropDestinationModifier(onDrop: onDrop))
    }

    /// Enables automatic comparison routing in secondary Riffa windows. A
    /// comparison workspace installs more specific role zones inside this
    /// fallback, so drops over its content still replace the intended input.
    func riffaOpensComparisonOnDrop() -> some View {
        modifier(RiffaOpenComparisonDropModifier())
    }

    func riffaCoordinatesAndOpensComparisonOnDrop() -> some View {
        modifier(RiffaCoordinateAndOpenComparisonDropModifier())
    }
}

private struct RiffaOpenComparisonDropModifier: ViewModifier {
    @EnvironmentObject private var broker: ComparisonOpenBroker

    func body(content: Content) -> some View {
        content.riffaAutomaticDropDestination { urls in
            let request = try broker.prepareExternalOpen(urls: urls)
            broker.publishExternalOpen(request) {
                RiffaApplicationRuntime.shared
                    .comparisonWindowPresenter
                    .revealComparisonWindow()
            }
        }
    }
}

private struct RiffaCoordinateAndOpenComparisonDropModifier: ViewModifier {
    @EnvironmentObject private var broker: ComparisonOpenBroker

    func body(content: Content) -> some View {
        content.riffaCoordinatedWindowDrops { urls in
            let request = try broker.prepareExternalOpen(urls: urls)
            broker.publishExternalOpen(request) {
                RiffaApplicationRuntime.shared
                    .comparisonWindowPresenter
                    .revealComparisonWindow()
            }
        }
    }
}

private struct RiffaCoordinatedWindowDropModifier: ViewModifier {
    let fallback: @MainActor ([URL]) throws -> Void

    @State private var activeOwnerID: UUID?
    @State private var activeZones: [RiffaDropZone] = []

    func body(content: Content) -> some View {
        content
            .modifier(
                RiffaRootWindowDropModifier(
                    zones: activeZones,
                    fallback: fallback,
                    install: install,
                    remove: remove
                )
            )
    }

    private func install(_ ownerID: UUID, zones: [RiffaDropZone]) {
        activeOwnerID = ownerID
        activeZones = zones
    }

    private func remove(_ ownerID: UUID) {
        guard activeOwnerID == ownerID else { return }
        activeOwnerID = nil
        activeZones = []
    }
}

private struct RiffaRootWindowDropModifier: ViewModifier {
    let zones: [RiffaDropZone]
    let fallback: @MainActor ([URL]) throws -> Void
    let install: @MainActor (UUID, [RiffaDropZone]) -> Void
    let remove: @MainActor (UUID) -> Void

    @EnvironmentObject private var accessRegistry: SecurityScopedAccessRegistry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            ZStack {
                content
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                    .environment(
                        \.riffaWindowDropRegistrar,
                        RiffaWindowDropRegistrar(
                            install: install,
                            remove: remove,
                            handleGroupDrop: { urls in
                                handle(
                                    urls: urls,
                                    location: CGPoint(
                                        x: geometry.size.width / 2,
                                        y: geometry.size.height / 2
                                    ),
                                    size: geometry.size
                                )
                            }
                        )
                    )

                if isTargeted {
                    if zones.isEmpty {
                        RiffaAutomaticDropOverlay()
                            .transition(.opacity)
                            .allowsHitTesting(false)
                            .zIndex(20)
                    } else {
                        RiffaWindowDropOverlay(zones: zones)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                            .zIndex(20)
                    }
                }

                if let errorMessage {
                    RiffaDropErrorBanner(message: errorMessage) {
                        self.errorMessage = nil
                    }
                    .padding(.top, RiffaSpacing.md)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(21)
                }
            }
            .dropDestination(for: URL.self) { urls, location in
                handle(
                    urls: urls,
                    location: location,
                    size: geometry.size
                )
            } isTargeted: { targeted in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    isTargeted = targeted
                }
            }
            .background {
                RiffaWindowDropBridge(
                    onTargeted: { targeted in
                        withAnimation(
                            reduceMotion ? nil : .easeOut(duration: 0.12)
                        ) {
                            isTargeted = targeted
                        }
                    },
                    onDrop: { urls, location, size in
                        handle(
                            urls: urls,
                            location: location,
                            size: size
                        )
                    }
                )
                .frame(width: 0, height: 0)
            }
        }
    }

    private func handle(
        urls: [URL],
        location: CGPoint,
        size: CGSize
    ) -> Bool {
        isTargeted = false
        do {
            if zones.isEmpty {
                guard !urls.isEmpty else {
                    throw RiffaDropError.noResources
                }
                guard urls.count <= 3 else {
                    throw RiffaDropError.tooManyResources(maximum: 3)
                }
                let registered = try urls.map { url in
                    try RiffaDroppedResourceValidator.validateLocalFileURL(url)
                    return try accessRegistry.registerIncomingURL(url)
                }
                for url in registered {
                    try RiffaDroppedResourceValidator.validate(
                        url,
                        as: .anyExistingEntry
                    )
                }
                try fallback(registered)
            } else {
                let zoneIndices = try RiffaDropAssignment.zoneIndices(
                    resourceCount: urls.count,
                    roles: zones.map(\.role),
                    dropX: location.x,
                    availableWidth: size.width
                )
                var prepared: [(RiffaDropZone, URL)] = []
                prepared.reserveCapacity(urls.count)
                for (url, zoneIndex) in zip(urls, zoneIndices) {
                    let zone = zones[zoneIndex]
                    try RiffaDroppedResourceValidator.validateLocalFileURL(url)
                    let registered = try accessRegistry.registerIncomingURL(url)
                    try RiffaDroppedResourceValidator.validate(
                        registered,
                        as: zone.acceptedKind
                    )
                    prepared.append((zone, registered))
                }
                for (zone, url) in prepared {
                    zone.onDrop(url)
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        return true
    }
}

private struct RiffaWindowDropZonesModifier: ViewModifier {
    let zones: [RiffaDropZone]

    @Environment(\.riffaWindowDropRegistrar) private var registrar
    @State private var registrationID = UUID()

    @ViewBuilder
    func body(content: Content) -> some View {
        if let registrar {
            content
                .onAppear {
                    registrar.install(registrationID, zones)
                }
                .onDisappear {
                    registrar.remove(registrationID)
                }
        } else {
            content.modifier(RiffaRawWindowDropZonesModifier(zones: zones))
        }
    }
}

private struct RiffaRawWindowDropZonesModifier: ViewModifier {
    let zones: [RiffaDropZone]

    @EnvironmentObject private var accessRegistry: SecurityScopedAccessRegistry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            ZStack {
                content
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )

                if isTargeted {
                    RiffaWindowDropOverlay(zones: zones)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(20)
                }

                if let errorMessage {
                    RiffaDropErrorBanner(message: errorMessage) {
                        self.errorMessage = nil
                    }
                    .padding(.top, RiffaSpacing.md)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(21)
                }
            }
            .dropDestination(for: URL.self) { urls, location in
                handle(
                    urls: urls,
                    location: location,
                    size: geometry.size
                )
            } isTargeted: { targeted in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    isTargeted = targeted
                }
            }
            .background {
                RiffaWindowDropBridge(
                    onTargeted: { targeted in
                        withAnimation(
                            reduceMotion ? nil : .easeOut(duration: 0.12)
                        ) {
                            isTargeted = targeted
                        }
                    },
                    onDrop: { urls, location, size in
                        handle(
                            urls: urls,
                            location: location,
                            size: size
                        )
                    }
                )
                .frame(width: 0, height: 0)
            }
        }
    }

    private func handle(
        urls: [URL],
        location: CGPoint,
        size: CGSize
    ) -> Bool {
        isTargeted = false
        do {
            let zoneIndices = try RiffaDropAssignment.zoneIndices(
                resourceCount: urls.count,
                roles: zones.map(\.role),
                dropX: location.x,
                availableWidth: size.width
            )

            var prepared: [(RiffaDropZone, URL)] = []
            prepared.reserveCapacity(urls.count)
            for (url, zoneIndex) in zip(urls, zoneIndices) {
                let zone = zones[zoneIndex]
                try RiffaDroppedResourceValidator.validateLocalFileURL(url)
                let registered = try accessRegistry.registerIncomingURL(url)
                try RiffaDroppedResourceValidator.validate(
                    registered,
                    as: zone.acceptedKind
                )
                prepared.append((zone, registered))
            }

            // Validate the complete group before replacing any live input.
            for (zone, url) in prepared {
                zone.onDrop(url)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        return true
    }
}

private struct RiffaResourceDropTargetModifier: ViewModifier {
    let zone: RiffaDropZone

    @EnvironmentObject private var accessRegistry: SecurityScopedAccessRegistry
    @Environment(\.riffaTheme) private var theme
    @Environment(\.riffaWindowDropRegistrar) private var windowDropRegistrar
    @State private var isTargeted = false
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: RiffaRadius.md)
                        .fill(
                            theme.surface(.three).opacity(
                                theme.reducesTransparency ? 1 : 0.96
                            )
                        )
                        .overlay {
                            VStack(spacing: RiffaSpacing.xxs) {
                                Image(systemName: zone.role.systemImage)
                                    .foregroundStyle(theme.accentHover)
                                Text(verbatim: zone.role.title)
                                    .riffaText(.caption)
                                    .foregroundStyle(theme.ink)
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: RiffaRadius.md)
                                .strokeBorder(
                                    theme.focusRing,
                                    lineWidth: theme.focusRingWidth
                                )
                        }
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                handle(urls)
            } isTargeted: {
                isTargeted = $0
            }
            .alert(
                "Could not use dropped item",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                ),
                actions: {
                    Button("OK", role: .cancel) {}
                },
                message: {
                    Text(verbatim: errorMessage ?? RiffaLocalization.string("Unknown error"))
                }
            )
            .accessibilityHint(accessibilityHint)
            .accessibilityDropPoint(
                .center,
                description: dropAccessibilityDescription
            )
            .accessibilityIdentifier("riffa.drop.\(zone.role.rawValue)")
    }

    private func handle(_ urls: [URL]) -> Bool {
        isTargeted = false
        do {
            switch try RiffaResourceDropRouting.route(
                urls,
                hasWindowCoordinator: windowDropRegistrar != nil
            ) {
            case let .coordinated(urls):
                guard let windowDropRegistrar else {
                    throw RiffaDropError.requiresExactlyOneResource
                }
                errorMessage = nil
                return windowDropRegistrar.handleGroupDrop(urls)
            case let .local(url):
                try RiffaDroppedResourceValidator.validateLocalFileURL(url)
                let registered = try accessRegistry.registerIncomingURL(url)
                try RiffaDroppedResourceValidator.validate(
                    registered,
                    as: zone.acceptedKind
                )
                zone.onDrop(registered)
                errorMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        return true
    }

    private var dropAccessibilityDescription: String {
        let replacement = String(
            localized: "It will replace the \(zone.role.title.lowercased()) input.",
            bundle: RiffaLocalization.localizedBundle,
            locale: RiffaLocalization.locale
        )
        return "\(zone.acceptedKind.instruction) \(replacement)"
    }

    private var accessibilityHint: String {
        "\(RiffaLocalization.string("Activate to choose a resource.")) \(dropAccessibilityDescription)"
    }
}

private struct RiffaAutomaticDropDestinationModifier: ViewModifier {
    let onDrop: @MainActor ([URL]) throws -> Void

    @EnvironmentObject private var accessRegistry: SecurityScopedAccessRegistry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        ZStack {
            content

            if isTargeted {
                RiffaAutomaticDropOverlay()
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .zIndex(20)
            }

            if let errorMessage {
                RiffaDropErrorBanner(message: errorMessage) {
                    self.errorMessage = nil
                }
                .padding(.top, RiffaSpacing.md)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(21)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handle(urls)
        } isTargeted: { targeted in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isTargeted = targeted
            }
        }
        .background {
            RiffaWindowDropBridge(
                onTargeted: { targeted in
                    withAnimation(
                        reduceMotion ? nil : .easeOut(duration: 0.12)
                    ) {
                        isTargeted = targeted
                    }
                },
                onDrop: { urls, _, _ in
                    handle(urls)
                }
            )
            .frame(width: 0, height: 0)
        }
    }

    private func handle(_ urls: [URL]) -> Bool {
        isTargeted = false
        do {
            guard !urls.isEmpty else {
                throw RiffaDropError.noResources
            }
            guard urls.count <= 3 else {
                throw RiffaDropError.tooManyResources(maximum: 3)
            }
            let registered = try urls.map { url in
                try RiffaDroppedResourceValidator.validateLocalFileURL(url)
                return try accessRegistry.registerIncomingURL(url)
            }
            for url in registered {
                try RiffaDroppedResourceValidator.validate(
                    url,
                    as: .anyExistingEntry
                )
            }
            try onDrop(registered)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        return true
    }
}

private struct RiffaWindowDropOverlay: View {
    let zones: [RiffaDropZone]

    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(spacing: RiffaSpacing.xs) {
            ForEach(Array(zones.enumerated()), id: \.offset) { _, zone in
                VStack(spacing: RiffaSpacing.sm) {
                    Image(systemName: zone.role.systemImage)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(theme.accentHover)

                    VStack(spacing: RiffaSpacing.xxs) {
                        Text("DROP AS")
                            .riffaText(.eyebrow)
                            .foregroundStyle(theme.inkTertiary)
                        Text(verbatim: zone.role.title)
                            .riffaText(.cardTitle)
                            .foregroundStyle(theme.ink)
                        Text(verbatim: zone.acceptedKind.instruction)
                            .riffaText(.caption)
                            .foregroundStyle(theme.inkSubtle)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    theme.surface(.one).opacity(
                        theme.reducesTransparency ? 1 : 0.97
                    ),
                    in: RoundedRectangle(cornerRadius: RiffaRadius.xl)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: RiffaRadius.xl)
                        .strokeBorder(
                            theme.focusRing,
                            lineWidth: theme.focusRingWidth
                        )
                }
            }
        }
        .padding(RiffaSpacing.md)
        .background(
            theme.canvas.opacity(theme.reducesTransparency ? 1 : 0.92)
        )
        .accessibilityElement(children: .contain)
    }
}

private struct RiffaAutomaticDropOverlay: View {
    @Environment(\.riffaTheme) private var theme

    var body: some View {
        VStack(spacing: RiffaSpacing.md) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(theme.accentHover)

            VStack(spacing: RiffaSpacing.xxs) {
                Text("Drop to compare")
                    .riffaText(.cardTitle)
                    .foregroundStyle(theme.ink)
                Text("Drop up to three local files or folders anywhere in this window.")
                    .riffaText(.bodySmall)
                    .foregroundStyle(theme.inkSubtle)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(RiffaSpacing.lg)
        .frame(maxWidth: 480)
        .background(
            theme.surface(.one),
            in: RoundedRectangle(cornerRadius: RiffaRadius.xl)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RiffaRadius.xl)
                .strokeBorder(
                    theme.focusRing,
                    lineWidth: theme.focusRingWidth
                )
        }
        .padding(RiffaSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            theme.canvas.opacity(theme.reducesTransparency ? 1 : 0.92)
        )
    }
}

private struct RiffaDropErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    @Environment(\.riffaTheme) private var theme

    var body: some View {
        HStack(spacing: RiffaSpacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.danger)
            Text(verbatim: message)
                .riffaText(.bodySmall)
                .foregroundStyle(theme.ink)
                .lineLimit(2)
            Button("Dismiss", action: dismiss)
                .buttonStyle(.riffaTertiary)
        }
        .padding(.leading, RiffaSpacing.sm)
        .padding(.trailing, RiffaSpacing.xxs)
        .padding(.vertical, RiffaSpacing.xxs)
        .background(
            theme.surface(.two),
            in: RoundedRectangle(cornerRadius: RiffaRadius.md)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RiffaRadius.md)
                .strokeBorder(theme.hairlineStrong, lineWidth: 1)
        }
        .padding(.horizontal, RiffaSpacing.md)
    }
}
