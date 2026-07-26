import Darwin
import Foundation

/// The two node kinds supported by Riffa's macOS Finder Services.
public enum FinderServiceResourceKind: String, Hashable, Sendable {
    case regularFile
    case directory
}

/// A classified service input. `Value` is deliberately generic so the pairing
/// state machine has no dependency on paths, pasteboards, AppKit, or storage.
public struct FinderServiceResource<Value: Hashable & Sendable>: Hashable, Sendable {
    public let value: Value
    public let kind: FinderServiceResourceKind

    public init(value: Value, kind: FinderServiceResourceKind) {
        self.value = value
        self.kind = kind
    }
}

public struct FinderServicePair<Value: Hashable & Sendable>: Hashable, Sendable {
    public let left: FinderServiceResource<Value>
    public let right: FinderServiceResource<Value>

    public init(
        left: FinderServiceResource<Value>,
        right: FinderServiceResource<Value>
    ) {
        self.left = left
        self.right = right
    }
}

/// Path-free state transition failures suitable for an NSServices error
/// pointer. No input value is retained in an error.
public enum FinderServicePairingError: Error, Equatable, Sendable {
    case selectLeftRequiresOne(actual: Int)
    case compareRequiresOneOrTwo(actual: Int)
    case resourceKindMismatch(
        expected: FinderServiceResourceKind,
        actual: FinderServiceResourceKind
    )
    case pendingLeftUnavailable(expected: FinderServiceResourceKind)
    case pendingKindMismatch(
        expected: FinderServiceResourceKind,
        actual: FinderServiceResourceKind
    )
}

extension FinderServicePairingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .selectLeftRequiresOne(actual):
            "Select Left requires exactly one item; \(actual) were supplied."
        case let .compareRequiresOneOrTwo(actual):
            "Compare requires one item with a pending left side, or exactly two items; \(actual) were supplied."
        case let .resourceKindMismatch(expected, actual):
            "This service accepts \(expected.serviceDescription)s, but a \(actual.serviceDescription) was supplied."
        case let .pendingLeftUnavailable(expected):
            "No pending left \(expected.serviceDescription) is available. Use Select Left first, or select two items."
        case let .pendingKindMismatch(expected, actual):
            "The pending left item is a \(actual.serviceDescription), not a \(expected.serviceDescription). Select a matching left item first."
        }
    }
}

private extension FinderServiceResourceKind {
    var serviceDescription: String {
        switch self {
        case .regularFile: "file"
        case .directory: "folder"
        }
    }
}

/// Process-local state for the four Finder Services. Failed transitions never
/// replace or consume the existing pending item. Every successful comparison,
/// including a direct two-item comparison, consumes pending state.
public struct FinderServicePairingStateMachine<Value: Hashable & Sendable>: Sendable {
    public private(set) var pendingLeft: FinderServiceResource<Value>?

    public init() {
        pendingLeft = nil
    }

    public mutating func selectLeft(
        _ resources: [FinderServiceResource<Value>],
        expectedKind: FinderServiceResourceKind
    ) throws {
        guard resources.count == 1 else {
            throw FinderServicePairingError.selectLeftRequiresOne(actual: resources.count)
        }
        let resource = resources[0]
        guard resource.kind == expectedKind else {
            throw FinderServicePairingError.resourceKindMismatch(
                expected: expectedKind,
                actual: resource.kind
            )
        }
        pendingLeft = resource
    }

    public mutating func compare(
        _ resources: [FinderServiceResource<Value>],
        expectedKind: FinderServiceResourceKind
    ) throws -> FinderServicePair<Value> {
        guard resources.count == 1 || resources.count == 2 else {
            throw FinderServicePairingError.compareRequiresOneOrTwo(actual: resources.count)
        }
        for resource in resources where resource.kind != expectedKind {
            throw FinderServicePairingError.resourceKindMismatch(
                expected: expectedKind,
                actual: resource.kind
            )
        }

        let pair: FinderServicePair<Value>
        if resources.count == 2 {
            pair = FinderServicePair(left: resources[0], right: resources[1])
        } else {
            guard let pendingLeft else {
                throw FinderServicePairingError.pendingLeftUnavailable(expected: expectedKind)
            }
            guard pendingLeft.kind == expectedKind else {
                throw FinderServicePairingError.pendingKindMismatch(
                    expected: expectedKind,
                    actual: pendingLeft.kind
                )
            }
            pair = FinderServicePair(left: pendingLeft, right: resources[0])
        }

        self.pendingLeft = nil
        return pair
    }
}

/// Strictly classifies the final filesystem node with `lstat`. Symlinks are
/// never followed, and sockets/devices/FIFOs are rejected rather than being
/// mistaken for ordinary files or folders.
public struct LocalFinderServiceResourceClassifier: Sendable {
    public init() {}

    public func classify(
        _ url: URL
    ) throws -> FinderServiceResource<URL> {
        guard url.isFileURL,
              NSString(string: url.path).isAbsolutePath else {
            throw FinderServiceInputError.nonLocalInput
        }

        var information = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &information)
        }
        guard status == 0 else {
            throw FinderServiceInputError.inspectionFailed(code: errno)
        }

        let nodeType = information.st_mode & S_IFMT
        let kind: FinderServiceResourceKind
        switch nodeType {
        case S_IFREG:
            kind = .regularFile
        case S_IFDIR:
            kind = .directory
        default:
            throw FinderServiceInputError.unsupportedNodeType
        }
        return FinderServiceResource(value: url, kind: kind)
    }
}

/// Input failures intentionally omit the URL and path.
public enum FinderServiceInputError: Error, Equatable, Sendable {
    case nonLocalInput
    case inspectionFailed(code: Int32)
    case unsupportedNodeType
}

extension FinderServiceInputError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nonLocalInput:
            "Finder Services accept only absolute local file URLs."
        case let .inspectionFailed(code):
            "A selected item could not be inspected safely (error \(code))."
        case .unsupportedNodeType:
            "Finder Services accept only regular files or real folders; links and special filesystem nodes are not supported."
        }
    }
}
