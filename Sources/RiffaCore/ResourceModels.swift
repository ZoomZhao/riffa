import Foundation

/// Identifies a resource without tying comparison models to a concrete provider.
public struct ResourceLocator: Hashable, Codable, Sendable {
    public static let localProviderID = "local"

    public let providerID: String
    public let path: String

    public init(providerID: String, path: String) {
        self.providerID = providerID
        self.path = path
    }

    public init(fileURL: URL) {
        self.init(
            providerID: Self.localProviderID,
            path: fileURL.standardizedFileURL.path
        )
    }

    /// Returns a file URL when this locator belongs to the local provider.
    public var localFileURL: URL? {
        guard providerID == Self.localProviderID else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// Operations a resource provider can perform.
public struct ResourceCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let enumerate = Self(rawValue: 1 << 0)
    public static let recursiveEnumeration = Self(rawValue: 1 << 1)
    public static let read = Self(rawValue: 1 << 2)
    public static let write = Self(rawValue: 1 << 3)
    public static let createDirectory = Self(rawValue: 1 << 4)
    public static let remove = Self(rawValue: 1 << 5)
    public static let move = Self(rawValue: 1 << 6)
    public static let readMetadata = Self(rawValue: 1 << 7)
    public static let symbolicLinks = Self(rawValue: 1 << 8)
}

/// Describes how names from a provider are normalized and compared.
public struct PathSemantics: Hashable, Codable, Sendable {
    public enum UnicodeNormalization: String, Codable, Sendable {
        case none
        case precomposed
        case decomposed
    }

    public let isCaseSensitive: Bool
    public let unicodeNormalization: UnicodeNormalization

    public init(
        isCaseSensitive: Bool,
        unicodeNormalization: UnicodeNormalization = .precomposed
    ) {
        self.isCaseSensitive = isCaseSensitive
        self.unicodeNormalization = unicodeNormalization
    }

    /// A practical default for the case-insensitive APFS configuration used by most Macs.
    public static let macOSDefault = Self(
        isCaseSensitive: false,
        unicodeNormalization: .precomposed
    )

    public static let caseSensitive = Self(
        isCaseSensitive: true,
        unicodeNormalization: .precomposed
    )

    public func comparisonKey(for path: String) -> String {
        let normalized: String
        switch unicodeNormalization {
        case .none:
            normalized = path
        case .precomposed:
            normalized = path.precomposedStringWithCanonicalMapping
        case .decomposed:
            normalized = path.decomposedStringWithCanonicalMapping
        }

        if isCaseSensitive {
            return normalized
        }
        return normalized.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

/// A stable, serializable description of a resource access failure.
public struct ResourceIssue: Error, Hashable, Codable, Sendable, LocalizedError {
    public let path: String
    public let message: String
    public let domain: String
    public let code: Int

    public init(path: String, message: String, domain: String = "RiffaCore", code: Int = 0) {
        self.path = path
        self.message = message
        self.domain = domain
        self.code = code
    }

    public init(path: String, underlying error: any Error) {
        let error = error as NSError
        self.init(
            path: path,
            message: error.localizedDescription,
            domain: error.domain,
            code: error.code
        )
    }

    public var errorDescription: String? {
        "\(path): \(message)"
    }
}

/// Metadata for one item below a provider root.
public struct ResourceEntry: Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file
        case directory
        case symbolicLink
        case other
        case inaccessible
    }

    public let locator: ResourceLocator
    public let relativePath: String
    public let kind: Kind
    public let byteCount: Int64?
    public let modificationDate: Date?
    public let permissions: UInt16?
    public let fileIdentifier: String?
    public let symbolicLinkDestination: String?
    public let issue: ResourceIssue?

    public init(
        locator: ResourceLocator,
        relativePath: String,
        kind: Kind,
        byteCount: Int64? = nil,
        modificationDate: Date? = nil,
        permissions: UInt16? = nil,
        fileIdentifier: String? = nil,
        symbolicLinkDestination: String? = nil,
        issue: ResourceIssue? = nil
    ) {
        self.locator = locator
        self.relativePath = relativePath
        self.kind = kind
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.permissions = permissions
        self.fileIdentifier = fileIdentifier
        self.symbolicLinkDestination = symbolicLinkDestination
        self.issue = issue
    }

    func recording(issue: ResourceIssue) -> Self {
        Self(
            locator: locator,
            relativePath: relativePath,
            kind: kind,
            byteCount: byteCount,
            modificationDate: modificationDate,
            permissions: permissions,
            fileIdentifier: fileIdentifier,
            symbolicLinkDestination: symbolicLinkDestination,
            issue: issue
        )
    }
}

/// One aligned row in a folder comparison.
public struct PairNode: Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case same
        case different
        case leftOnly
        case rightOnly
        case typeMismatch
        case error
    }

    public var id: String { relativePath }

    public let relativePath: String
    public let left: ResourceEntry?
    public let right: ResourceEntry?
    public let status: Status
    public let issues: [ResourceIssue]

    public init(
        relativePath: String,
        left: ResourceEntry?,
        right: ResourceEntry?,
        status: Status,
        issues: [ResourceIssue] = []
    ) {
        self.relativePath = relativePath
        self.left = left
        self.right = right
        self.status = status
        self.issues = issues
    }
}
