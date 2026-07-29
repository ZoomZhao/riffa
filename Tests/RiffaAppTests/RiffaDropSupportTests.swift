import AppKit
import Foundation
import SwiftUI
import Testing
@testable import RiffaApp

@Suite("Window-wide resource drops")
struct RiffaDropSupportTests {
    @Test("A two-file text comparison remains stable when its sides are swapped")
    @MainActor
    func twoFileTextComparisonCanSwapSides() async throws {
        let fixture = try TextComparisonFixture()
        let left = try fixture.file(named: "left.txt", contents: "left\n")
        let right = try fixture.file(named: "right.txt", contents: "right\n")
        defer { fixture.remove() }

        let model = TextCompareModel()
        model.openInitial([left, right])
        try await waitForTextInputs(in: model)

        model.swapSides()

        #expect(model.leftURL == right.standardizedFileURL)
        #expect(model.rightURL == left.standardizedFileURL)
        #expect(model.leftDocument?.text == "right\n")
        #expect(model.rightDocument?.text == "left\n")
    }

    @Test("A loaded text comparison can replace both dropped inputs")
    @MainActor
    func twoFileTextComparisonCanReplaceBothInputs() async throws {
        let fixture = try TextComparisonFixture()
        let initialLeft = try fixture.file(
            named: "initial-left.txt",
            contents: "initial left\n"
        )
        let initialRight = try fixture.file(
            named: "initial-right.txt",
            contents: "initial right\n"
        )
        let replacementLeft = try fixture.file(
            named: "replacement-left.txt",
            contents: "replacement left\n"
        )
        let replacementRight = try fixture.file(
            named: "replacement-right.txt",
            contents: "replacement right\n"
        )
        defer { fixture.remove() }

        let model = TextCompareModel()
        model.openInitial([initialLeft, initialRight])
        try await waitForTextInputs(in: model)

        model.replaceInput(with: replacementLeft, for: .left)
        model.replaceInput(with: replacementRight, for: .right)
        try await waitForTextInputs(
            in: model,
            leftURL: replacementLeft,
            rightURL: replacementRight
        )

        #expect(model.leftDocument?.text == "replacement left\n")
        #expect(model.rightDocument?.text == "replacement right\n")
    }

    @MainActor
    private func waitForTextInputs(
        in model: TextCompareModel,
        leftURL: URL? = nil,
        rightURL: URL? = nil
    ) async throws {
        for _ in 0..<100 {
            let hasExpectedURLs = (leftURL == nil
                || model.leftURL == leftURL?.standardizedFileURL)
                && (rightURL == nil
                    || model.rightURL == rightURL?.standardizedFileURL)
            if hasExpectedURLs,
               model.leftDocument != nil,
               model.rightDocument != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for both text inputs to load")
    }

    private struct TextComparisonFixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "RiffaDropSupportTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }

        func file(named name: String, contents: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("The AppKit bridge covers the containing window and forwards its delegate")
    @MainActor
    func appKitBridgeInstallsWithoutDiscardingWindowDelegate() async {
        let originalDelegate = RejectingWindowDelegate()
        let accessRegistry = SecurityScopedAccessRegistry()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let droppedFile = temporaryDirectory.appendingPathComponent("left.txt")
        _ = FileManager.default.createFile(
            atPath: droppedFile.path,
            contents: Data("left".utf8)
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        var receivedURLs: [URL] = []
        let root = Text("Drop target")
            .riffaAutomaticDropDestination { receivedURLs = $0 }
            .environmentObject(accessRegistry)
        let hostingView = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = originalDelegate
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        hostingView.layoutSubtreeIfNeeded()

        #expect(window.delegate !== originalDelegate)
        #expect(window.delegate is any NSDraggingDestination)
        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(originalDelegate.closeRequestCount == 1)

        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([droppedFile as NSURL]))
        let draggingInfo = TestDraggingInfo(
            destinationWindow: window,
            pasteboard: pasteboard,
            location: NSPoint(x: 160, y: window.frame.height - 4)
        )
        let dropDelegate = window.delegate as? any NSDraggingDestination
        #expect(dropDelegate?.draggingEntered?(draggingInfo) == .copy)
        #expect(dropDelegate?.prepareForDragOperation?(draggingInfo) == true)
        #expect(dropDelegate?.performDragOperation?(draggingInfo) == true)
        #expect(receivedURLs.map(\.standardizedFileURL) == [droppedFile.standardizedFileURL])

        window.contentView = nil
        window.delegate = nil
    }

    @Test("An external drop request is claimed by only one comparison window")
    @MainActor
    func externalDropRequestIsClaimedOnce() {
        let broker = ComparisonOpenBroker(
            accessRegistry: SecurityScopedAccessRegistry()
        )
        let request = ExternalOpenRequest(
            kind: .textCompare,
            urls: [
                URL(fileURLWithPath: "/tmp/left.txt"),
                URL(fileURLWithPath: "/tmp/right.txt")
            ]
        )

        broker.publishExternalOpen(request) {}

        #expect(broker.claimExternalOpen(request))
        #expect(!broker.claimExternalOpen(request))
    }

    @Test("A single resource uses the horizontal drop zone")
    func singleResourceUsesDropLocation() throws {
        let roles: [RiffaDropRole] = [.base, .left, .right]

        #expect(
            try RiffaDropAssignment.zoneIndices(
                resourceCount: 1,
                roles: roles,
                dropX: 10,
                availableWidth: 900
            ) == [0]
        )
        #expect(
            try RiffaDropAssignment.zoneIndices(
                resourceCount: 1,
                roles: roles,
                dropX: 450,
                availableWidth: 900
            ) == [1]
        )
        #expect(
            try RiffaDropAssignment.zoneIndices(
                resourceCount: 1,
                roles: roles,
                dropX: 899,
                availableWidth: 900
            ) == [2]
        )
    }

    @Test("Two resources always map to Left and Right")
    func twoResourcesPreferComparisonPair() throws {
        #expect(
            try RiffaDropAssignment.zoneIndices(
                resourceCount: 2,
                roles: [.base, .left, .right],
                dropX: 0,
                availableWidth: 900
            ) == [1, 2]
        )
        #expect(
            try RiffaDropAssignment.zoneIndices(
                resourceCount: 2,
                roles: [.left, .right],
                dropX: 899,
                availableWidth: 900
            ) == [0, 1]
        )
    }

    @Test("A precise target delegates multiple resources to the window coordinator")
    func multipleResourcesUseWindowCoordinator() throws {
        let left = URL(fileURLWithPath: "/tmp/left.txt")
        let right = URL(fileURLWithPath: "/tmp/right.txt")

        #expect(
            try RiffaResourceDropRouting.route(
                [left, right],
                hasWindowCoordinator: true
            ) == .coordinated([left, right])
        )
        #expect(
            try RiffaResourceDropRouting.route(
                [left],
                hasWindowCoordinator: true
            ) == .local(left)
        )
        #expect(throws: RiffaDropError.self) {
            try RiffaResourceDropRouting.route(
                [left, right],
                hasWindowCoordinator: false
            )
        }
    }

    @Test("A complete three-way group preserves Base, Left, Right order")
    func threeWayGroupPreservesOrder() throws {
        #expect(
            try RiffaDropAssignment.zoneIndices(
                resourceCount: 3,
                roles: [.base, .left, .right],
                dropX: 450,
                availableWidth: 900
            ) == [0, 1, 2]
        )
    }

    @Test("Unsupported partial groups are rejected")
    func unsupportedPartialGroupsAreRejected() {
        #expect(throws: RiffaDropError.self) {
            try RiffaDropAssignment.zoneIndices(
                resourceCount: 2,
                roles: [.base, .patch, .target],
                dropX: 0,
                availableWidth: 900
            )
        }
        #expect(throws: RiffaDropError.self) {
            try RiffaDropAssignment.zoneIndices(
                resourceCount: 3,
                roles: [.left, .right],
                dropX: 0,
                availableWidth: 900
            )
        }
    }

    @Test("Validation follows each comparison engine's final-link policy")
    func resourceValidationPolicies() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "RiffaDropSupportTests-\(UUID().uuidString)")
        let folder = root.appending(path: "folder", directoryHint: .isDirectory)
        let file = root.appending(path: "sample.txt")
        let link = root.appending(path: "sample-link")
        try fileManager.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try Data("sample".utf8).write(to: file)
        try fileManager.createSymbolicLink(
            at: link,
            withDestinationURL: file
        )
        defer { try? fileManager.removeItem(at: root) }

        try RiffaDroppedResourceValidator.validate(file, as: .realRegularFile)
        try RiffaDroppedResourceValidator.validate(folder, as: .realDirectory)
        try RiffaDroppedResourceValidator.validate(file, as: .realFileOrDirectory)
        try RiffaDroppedResourceValidator.validate(folder, as: .realFileOrDirectory)
        try RiffaDroppedResourceValidator.validate(
            link,
            as: .regularFileFollowingFinalSymbolicLink
        )
        try RiffaDroppedResourceValidator.validate(link, as: .anyExistingEntry)

        #expect(throws: RiffaDropError.self) {
            try RiffaDroppedResourceValidator.validate(link, as: .realRegularFile)
        }
        #expect(throws: RiffaDropError.self) {
            try RiffaDroppedResourceValidator.validate(link, as: .realFileOrDirectory)
        }
        #expect(throws: RiffaDropError.self) {
            try RiffaDroppedResourceValidator.validate(file, as: .realDirectory)
        }
        #expect(throws: RiffaDropError.self) {
            try RiffaDroppedResourceValidator.validate(
                URL(string: "https://example.com/file")!,
                as: .anyExistingEntry
            )
        }
    }
}

@MainActor
private final class RejectingWindowDelegate: NSObject, NSWindowDelegate {
    private(set) var closeRequestCount = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        _ = sender
        closeRequestCount += 1
        return false
    }
}

@MainActor
private final class TestDraggingInfo:
    NSObject,
    @preconcurrency NSDraggingInfo
{
    let destinationWindow: NSWindow
    let pasteboard: NSPasteboard
    let location: NSPoint

    init(
        destinationWindow: NSWindow,
        pasteboard: NSPasteboard,
        location: NSPoint
    ) {
        self.destinationWindow = destinationWindow
        self.pasteboard = pasteboard
        self.location = location
    }

    var draggingDestinationWindow: NSWindow? { destinationWindow }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {
        _ = screenPoint
    }

    override func namesOfPromisedFilesDropped(
        atDestination dropDestination: URL
    ) -> [String]? {
        _ = dropDestination
        return nil
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (
            NSDraggingItem,
            Int,
            UnsafeMutablePointer<ObjCBool>
        ) -> Void
    ) {
        _ = enumOpts
        _ = view
        _ = classArray
        _ = searchOptions
        _ = block
    }

    func resetSpringLoading() {}
}
