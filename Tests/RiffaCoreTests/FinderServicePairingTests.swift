import Darwin
import Foundation
import Testing
@testable import RiffaCore

@Suite("Finder Service pairing state")
struct FinderServicePairingTests {
    @Test("Two selected items pair directly and consume an older pending side")
    func directPair() throws {
        var state = FinderServicePairingStateMachine<String>()
        try state.selectLeft([file("pending")], expectedKind: .regularFile)

        let pair = try state.compare(
            [file("first"), file("second")],
            expectedKind: .regularFile
        )

        #expect(pair.left.value == "first")
        #expect(pair.right.value == "second")
        #expect(state.pendingLeft == nil)
    }

    @Test("One selected item pairs with and consumes the pending left side")
    func pendingPair() throws {
        var state = FinderServicePairingStateMachine<String>()
        try state.selectLeft([folder("left")], expectedKind: .directory)

        let pair = try state.compare([folder("right")], expectedKind: .directory)

        #expect(pair.left.value == "left")
        #expect(pair.right.value == "right")
        #expect(state.pendingLeft == nil)
    }

    @Test("Current kind mismatch preserves pending state")
    func currentKindMismatchPreservesPending() throws {
        var state = FinderServicePairingStateMachine<String>()
        try state.selectLeft([file("left")], expectedKind: .regularFile)

        #expect(throws: FinderServicePairingError.resourceKindMismatch(
            expected: .regularFile,
            actual: .directory
        )) {
            try state.compare([folder("wrong")], expectedKind: .regularFile)
        }
        #expect(state.pendingLeft?.value == "left")
    }

    @Test("Pending kind mismatch preserves the pending item")
    func pendingKindMismatchPreservesPending() throws {
        var state = FinderServicePairingStateMachine<String>()
        try state.selectLeft([folder("left-folder")], expectedKind: .directory)

        #expect(throws: FinderServicePairingError.pendingKindMismatch(
            expected: .regularFile,
            actual: .directory
        )) {
            try state.compare([file("right-file")], expectedKind: .regularFile)
        }
        #expect(state.pendingLeft?.value == "left-folder")
        #expect(state.pendingLeft?.kind == .directory)
    }

    @Test("Invalid counts and failed Select Left do not change pending state")
    func invalidTransitionsPreservePending() throws {
        var state = FinderServicePairingStateMachine<String>()
        try state.selectLeft([file("stable")], expectedKind: .regularFile)

        #expect(throws: FinderServicePairingError.compareRequiresOneOrTwo(actual: 0)) {
            try state.compare([], expectedKind: .regularFile)
        }
        #expect(throws: FinderServicePairingError.compareRequiresOneOrTwo(actual: 3)) {
            try state.compare(
                [file("a"), file("b"), file("c")],
                expectedKind: .regularFile
            )
        }
        #expect(throws: FinderServicePairingError.selectLeftRequiresOne(actual: 2)) {
            try state.selectLeft([file("a"), file("b")], expectedKind: .regularFile)
        }
        #expect(throws: FinderServicePairingError.resourceKindMismatch(
            expected: .regularFile,
            actual: .directory
        )) {
            try state.selectLeft([folder("wrong")], expectedKind: .regularFile)
        }
        #expect(state.pendingLeft?.value == "stable")
    }

    @Test("Missing pending side reports a path-free error")
    func missingPending() {
        var state = FinderServicePairingStateMachine<String>()
        #expect(throws: FinderServicePairingError.pendingLeftUnavailable(
            expected: .regularFile
        )) {
            try state.compare([file("right")], expectedKind: .regularFile)
        }
        #expect(
            !FinderServicePairingError.pendingLeftUnavailable(expected: .regularFile)
                .localizedDescription.contains("right")
        )
    }

    @Test("lstat classifier accepts real nodes and rejects symlinks and FIFOs")
    func strictLocalClassification() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Riffa-Finder-Service-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let regular = root.appending(path: "regular.bin")
        let directory = root.appending(path: "folder", directoryHint: .isDirectory)
        let link = root.appending(path: "link")
        let fifo = root.appending(path: "pipe")
        try Data([1, 2, 3]).write(to: regular)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        #expect(fifo.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)

        let classifier = LocalFinderServiceResourceClassifier()
        #expect(try classifier.classify(regular).kind == .regularFile)
        #expect(try classifier.classify(directory).kind == .directory)
        #expect(throws: FinderServiceInputError.unsupportedNodeType) {
            try classifier.classify(link)
        }
        #expect(throws: FinderServiceInputError.unsupportedNodeType) {
            try classifier.classify(fifo)
        }
        #expect(throws: FinderServiceInputError.nonLocalInput) {
            try classifier.classify(URL(string: "https://example.invalid/item")!)
        }
    }

    private func file(_ value: String) -> FinderServiceResource<String> {
        FinderServiceResource(value: value, kind: .regularFile)
    }

    private func folder(_ value: String) -> FinderServiceResource<String> {
        FinderServiceResource(value: value, kind: .directory)
    }
}
