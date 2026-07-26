import CryptoKit
import Darwin
import Foundation
import Security

public enum VersionComparisonSide: String, Codable, Sendable {
    case left
    case right
}

public enum VersionComparisonResource: String, Codable, Sendable {
    case input
    case infoPlist
    case mainExecutable
}

/// Explicit limits for every file that Riffa reads while inspecting a version
/// resource. The main binary is hashed incrementally and is never loaded in
/// full; Info.plist and Mach-O load-command reads have their own smaller caps.
public struct VersionComparisonLimits: Equatable, Codable, Sendable {
    public static let defaultMaximumFileByteCount: Int64 = 1_024 * 1_024 * 1_024

    public var maximumFileByteCount: Int64
    public var maximumInfoPlistByteCount: Int
    public var maximumArchitectureCount: Int
    public var maximumMachOLoadCommandByteCount: Int
    public var maximumMachOInspectionByteCount: Int

    public init(
        maximumFileByteCount: Int64 = Self.defaultMaximumFileByteCount,
        maximumInfoPlistByteCount: Int = 2 * 1_024 * 1_024,
        maximumArchitectureCount: Int = 128,
        maximumMachOLoadCommandByteCount: Int = 1 * 1_024 * 1_024,
        maximumMachOInspectionByteCount: Int = 16 * 1_024 * 1_024
    ) {
        self.maximumFileByteCount = max(1, maximumFileByteCount)
        self.maximumInfoPlistByteCount = max(1, maximumInfoPlistByteCount)
        self.maximumArchitectureCount = min(max(1, maximumArchitectureCount), Int(UInt32.max))
        self.maximumMachOLoadCommandByteCount = min(
            max(1, maximumMachOLoadCommandByteCount),
            Int(UInt32.max)
        )
        self.maximumMachOInspectionByteCount = max(64, maximumMachOInspectionByteCount)
    }
}

public enum VersionMachOErrorReason: String, Error, Codable, Sendable {
    case truncatedHeader
    case tooManyArchitectures
    case invalidArchitectureTable
    case sliceOutOfBounds
    case overlappingSlices
    case invalidSlice
    case cpuTypeMismatch
    case loadCommandsOutOfBounds
    case loadCommandsTooLarge
    case malformedLoadCommands
    case inspectionLimitExceeded
}

/// Side-aware errors intentionally contain no URL, path, plist contents, or
/// Security.framework prose that might disclose a local locator.
public enum VersionComparisonError: Error, Equatable, Codable, Sendable {
    case nonLocalInput(side: VersionComparisonSide)
    case inputNotFound(side: VersionComparisonSide)
    case symbolicLinkNotAllowed(side: VersionComparisonSide)
    case unsupportedDirectory(side: VersionComparisonSide)
    case notRegularFile(side: VersionComparisonSide, resource: VersionComparisonResource)
    case permissionDenied(side: VersionComparisonSide, resource: VersionComparisonResource)
    case readFailed(side: VersionComparisonSide, resource: VersionComparisonResource, code: Int32)
    case fileTooLarge(
        side: VersionComparisonSide,
        resource: VersionComparisonResource,
        actualByteCount: Int64,
        limit: Int64
    )
    case inputChanged(side: VersionComparisonSide, resource: VersionComparisonResource)
    case invalidInfoPlist(side: VersionComparisonSide)
    case invalidBundleExecutableName(side: VersionComparisonSide)
    case bundleExecutableNotFound(side: VersionComparisonSide)
    case bundleBoundaryViolation(side: VersionComparisonSide, resource: VersionComparisonResource)
    case malformedMachO(side: VersionComparisonSide, reason: VersionMachOErrorReason)
}

extension VersionComparisonError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .nonLocalInput(side):
            "The \(side.rawValue) version input is not a local file."
        case let .inputNotFound(side):
            "The \(side.rawValue) version input does not exist."
        case let .symbolicLinkNotAllowed(side):
            "The \(side.rawValue) version input is a symbolic link. Select its target explicitly."
        case let .unsupportedDirectory(side):
            "The \(side.rawValue) directory is not a supported macOS bundle."
        case let .notRegularFile(side, resource):
            "The \(side.rawValue) \(resource.rawValue) is not a regular file."
        case let .permissionDenied(side, resource):
            "The \(side.rawValue) \(resource.rawValue) cannot be read."
        case let .readFailed(side, resource, code):
            "The \(side.rawValue) \(resource.rawValue) could not be read (error \(code))."
        case let .fileTooLarge(side, resource, actualByteCount, limit):
            "The \(side.rawValue) \(resource.rawValue) is \(actualByteCount) bytes, exceeding the \(limit)-byte limit."
        case let .inputChanged(side, resource):
            "The \(side.rawValue) \(resource.rawValue) changed while it was being inspected."
        case let .invalidInfoPlist(side):
            "The \(side.rawValue) bundle has an invalid Info.plist."
        case let .invalidBundleExecutableName(side):
            "The \(side.rawValue) bundle has an unsafe main-executable name."
        case let .bundleExecutableNotFound(side):
            "The \(side.rawValue) bundle main executable was not found."
        case let .bundleBoundaryViolation(side, resource):
            "The \(side.rawValue) bundle \(resource.rawValue) resolves outside the bundle."
        case let .malformedMachO(side, reason):
            "The \(side.rawValue) input has malformed Mach-O data (\(reason.rawValue))."
        }
    }
}

public enum VersionResourceKind: String, Codable, Sendable {
    case applicationBundle
    case framework
    case bundle
    case executable
    case dynamicLibrary
    case machO
    case regularFile
}

public struct VersionArchitecture: Equatable, Hashable, Codable, Sendable {
    public let cpuType: UInt32
    public let cpuSubtype: UInt32
    public let displayName: String

    public init(cpuType: UInt32, cpuSubtype: UInt32, displayName: String) {
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
        self.displayName = displayName
    }
}

public enum VersionCodeSignatureStatus: String, Codable, Sendable {
    case valid
    case invalid
    case unsigned
    case notApplicable
    case unavailable
}

/// A portable signing summary. `diagnosticCode` is an OSStatus number rather
/// than a framework error string because the latter may embed an absolute path.
public struct VersionCodeSignature: Equatable, Codable, Sendable {
    public let status: VersionCodeSignatureStatus
    public let teamIdentifier: String?
    public let signingIdentifier: String?
    public let diagnosticCode: Int32?

    public init(
        status: VersionCodeSignatureStatus,
        teamIdentifier: String? = nil,
        signingIdentifier: String? = nil,
        diagnosticCode: Int32? = nil
    ) {
        self.status = status
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.diagnosticCode = diagnosticCode
    }
}

/// Path-free version and binary-identity data. For a bundle, byte count and
/// SHA-256 describe its main executable, not a recursively serialized folder.
public struct VersionResourceSnapshot: Equatable, Codable, Sendable {
    public let displayName: String
    public let kind: VersionResourceKind
    public let bundleIdentifier: String?
    public let shortVersionString: String?
    public let bundleVersion: String?
    public let packageType: String?
    public let minimumSystemVersion: String?
    public let architectures: [VersionArchitecture]
    public let fileByteCount: Int64
    public let sha256: String
    public let codeSignature: VersionCodeSignature

    public init(
        displayName: String,
        kind: VersionResourceKind,
        bundleIdentifier: String? = nil,
        shortVersionString: String? = nil,
        bundleVersion: String? = nil,
        packageType: String? = nil,
        minimumSystemVersion: String? = nil,
        architectures: [VersionArchitecture] = [],
        fileByteCount: Int64,
        sha256: String,
        codeSignature: VersionCodeSignature = VersionCodeSignature(status: .notApplicable)
    ) {
        self.displayName = displayName
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.shortVersionString = shortVersionString
        self.bundleVersion = bundleVersion
        self.packageType = packageType
        self.minimumSystemVersion = minimumSystemVersion
        self.architectures = architectures
        self.fileByteCount = fileByteCount
        self.sha256 = sha256
        self.codeSignature = codeSignature
    }
}

public enum VersionComparisonField: String, CaseIterable, Codable, Sendable {
    case displayName
    case kind
    case bundleIdentifier
    case shortVersionString
    case bundleVersion
    case packageType
    case minimumSystemVersion
    case architectures
    case fileByteCount
    case sha256
    case signatureStatus
    case signingTeamIdentifier
    case signingIdentifier
    case signatureDiagnosticCode
}

public enum VersionComparisonValue: Equatable, Codable, Sendable {
    case string(String)
    case integer(Int64)
    case strings([String])
    case null

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Kind: String, Codable {
        case string
        case integer
        case strings
        case null
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .integer: self = .integer(try container.decode(Int64.self, forKey: .value))
        case .strings: self = .strings(try container.decode([String].self, forKey: .value))
        case .null: self = .null
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try container.encode(Kind.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .strings(value):
            try container.encode(Kind.strings, forKey: .type)
            try container.encode(value, forKey: .value)
        case .null:
            try container.encode(Kind.null, forKey: .type)
        }
    }
}

public enum VersionFieldComparisonStatus: String, Codable, Sendable {
    case same
    case different
}

public struct VersionFieldComparison: Equatable, Codable, Sendable {
    public let field: VersionComparisonField
    public let status: VersionFieldComparisonStatus
    public let left: VersionComparisonValue
    public let right: VersionComparisonValue

    public init(
        field: VersionComparisonField,
        status: VersionFieldComparisonStatus,
        left: VersionComparisonValue,
        right: VersionComparisonValue
    ) {
        self.field = field
        self.status = status
        self.left = left
        self.right = right
    }
}

public struct VersionComparisonStatistics: Equatable, Codable, Sendable {
    public let totalFieldCount: Int
    public let sameFieldCount: Int
    public let differentFieldCount: Int

    public init(totalFieldCount: Int, sameFieldCount: Int, differentFieldCount: Int) {
        self.totalFieldCount = totalFieldCount
        self.sameFieldCount = sameFieldCount
        self.differentFieldCount = differentFieldCount
    }
}

public struct VersionComparisonResult: Equatable, Codable, Sendable {
    public let left: VersionResourceSnapshot
    public let right: VersionResourceSnapshot
    public let fields: [VersionFieldComparison]
    public let statistics: VersionComparisonStatistics

    public init(
        left: VersionResourceSnapshot,
        right: VersionResourceSnapshot,
        fields: [VersionFieldComparison],
        statistics: VersionComparisonStatistics
    ) {
        self.left = left
        self.right = right
        self.fields = fields
        self.statistics = statistics
    }

    public var differingFields: [VersionComparisonField] {
        fields.compactMap { $0.status == .different ? $0.field : nil }
    }

    public var hasDifferences: Bool {
        statistics.differentFieldCount > 0
    }
}

/// Static, non-executing inspection of macOS files and bundles.
public struct VersionComparisonEngine: Sendable {
    public var limits: VersionComparisonLimits

    public init(limits: VersionComparisonLimits = VersionComparisonLimits()) {
        self.limits = limits
    }

    public func compare(leftURL: URL, rightURL: URL) throws -> VersionComparisonResult {
        compare(
            left: try inspect(url: leftURL, side: .left),
            right: try inspect(url: rightURL, side: .right)
        )
    }

    public func inspect(url: URL, side: VersionComparisonSide) throws -> VersionResourceSnapshot {
        guard url.isFileURL else {
            throw VersionComparisonError.nonLocalInput(side: side)
        }

        var inputStatus = stat()
        guard lstat(url.path, &inputStatus) == 0 else {
            if errno == ENOENT {
                throw VersionComparisonError.inputNotFound(side: side)
            }
            throw classifiedPOSIXError(errno, side: side, resource: .input)
        }
        let inputKind = inputStatus.st_mode & S_IFMT
        if inputKind == S_IFLNK {
            throw VersionComparisonError.symbolicLinkNotAllowed(side: side)
        }
        if inputKind == S_IFDIR {
            return try inspectBundle(url: url, initialStatus: inputStatus, side: side)
        }
        guard inputKind == S_IFREG else {
            throw VersionComparisonError.notRegularFile(side: side, resource: .input)
        }
        return try inspectFile(url: url, side: side)
    }

    /// Compares already-portable snapshots in a fixed field order. This is also
    /// useful to callers that persist snapshots and compare them later.
    public func compare(
        left: VersionResourceSnapshot,
        right: VersionResourceSnapshot
    ) -> VersionComparisonResult {
        let fields = VersionComparisonField.allCases.map { field in
            let leftValue = value(for: field, in: left)
            let rightValue = value(for: field, in: right)
            return VersionFieldComparison(
                field: field,
                status: leftValue == rightValue ? .same : .different,
                left: leftValue,
                right: rightValue
            )
        }
        let differentCount = fields.count { $0.status == .different }
        return VersionComparisonResult(
            left: left,
            right: right,
            fields: fields,
            statistics: VersionComparisonStatistics(
                totalFieldCount: fields.count,
                sameFieldCount: fields.count - differentCount,
                differentFieldCount: differentCount
            )
        )
    }

    private func inspectFile(
        url: URL,
        side: VersionComparisonSide
    ) throws -> VersionResourceSnapshot {
        let binary = try readBinary(url: url, side: side, resource: .input)
        let machO = binary.machO
        let kind = fileKind(machO: machO, mode: binary.mode)
        let signature = try validatedCodeSignature(
            at: url,
            applicable: machO != nil,
            isBundle: false,
            checks: [
                IdentityCheck(url: url, identity: binary.identity, resource: .input)
            ],
            side: side
        )
        return VersionResourceSnapshot(
            displayName: url.lastPathComponent,
            kind: kind,
            minimumSystemVersion: machO?.minimumSystemVersion,
            architectures: machO?.architectures ?? [],
            fileByteCount: binary.byteCount,
            sha256: binary.sha256,
            codeSignature: signature
        )
    }

    private func inspectBundle(
        url: URL,
        initialStatus: stat,
        side: VersionComparisonSide
    ) throws -> VersionResourceSnapshot {
        let rootIdentity = FileIdentity(status: initialStatus)
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        try validateIdentity(
            at: url,
            expected: rootIdentity,
            side: side,
            resource: .input
        )
        guard let infoCandidate = firstExistingURL(infoPlistCandidates(root: root)) else {
            throw VersionComparisonError.unsupportedDirectory(side: side)
        }
        let infoURL = try containedResolvedURL(
            infoCandidate,
            root: root,
            side: side,
            resource: .infoPlist
        )
        let infoRead = try readSmallFile(
            url: infoURL,
            limit: limits.maximumInfoPlistByteCount,
            side: side,
            resource: .infoPlist
        )
        let info = try parseInfoPlist(infoRead.data, side: side)
        guard let executableName = stringValue(info["CFBundleExecutable"]),
              isSafeExecutableName(executableName) else {
            throw VersionComparisonError.invalidBundleExecutableName(side: side)
        }
        guard let executableCandidate = firstExistingURL(
            executableCandidates(
                root: root,
                resolvedInfoURL: infoURL,
                executableName: executableName
            )
        ) else {
            throw VersionComparisonError.bundleExecutableNotFound(side: side)
        }
        let executableURL = try containedResolvedURL(
            executableCandidate,
            root: root,
            side: side,
            resource: .mainExecutable
        )
        let binary = try readBinary(
            url: executableURL,
            side: side,
            resource: .mainExecutable
        )
        let machO = binary.machO
        let packageType = stringValue(info["CFBundlePackageType"])
        let signature = try validatedCodeSignature(
            at: url,
            applicable: true,
            isBundle: true,
            checks: [
                IdentityCheck(url: url, identity: rootIdentity, resource: .input),
                IdentityCheck(
                    url: infoURL,
                    identity: infoRead.identity,
                    resource: .infoPlist
                ),
                IdentityCheck(
                    url: executableURL,
                    identity: binary.identity,
                    resource: .mainExecutable
                )
            ],
            side: side
        )

        return VersionResourceSnapshot(
            displayName: url.lastPathComponent,
            kind: bundleKind(url: url, packageType: packageType),
            bundleIdentifier: stringValue(info["CFBundleIdentifier"]),
            shortVersionString: stringValue(info["CFBundleShortVersionString"]),
            bundleVersion: stringValue(info["CFBundleVersion"]),
            packageType: packageType,
            minimumSystemVersion: stringValue(info["LSMinimumSystemVersion"])
                ?? stringValue(info["MinimumOSVersion"])
                ?? machO?.minimumSystemVersion,
            architectures: machO?.architectures ?? [],
            fileByteCount: binary.byteCount,
            sha256: binary.sha256,
            codeSignature: signature
        )
    }

    private func parseInfoPlist(
        _ data: Data,
        side: VersionComparisonSide
    ) throws -> [String: Any] {
        do {
            let value = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
            guard let dictionary = value as? [String: Any] else {
                throw VersionComparisonError.invalidInfoPlist(side: side)
            }
            return dictionary
        } catch let error as VersionComparisonError {
            throw error
        } catch {
            throw VersionComparisonError.invalidInfoPlist(side: side)
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private func isSafeExecutableName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
    }

    private func bundleKind(url: URL, packageType: String?) -> VersionResourceKind {
        switch url.pathExtension.lowercased() {
        case "app": return .applicationBundle
        case "framework": return .framework
        default:
            if packageType == "APPL" { return .applicationBundle }
            if packageType == "FMWK" { return .framework }
            return .bundle
        }
    }

    private func infoPlistCandidates(root: URL) -> [URL] {
        let common = [
            root.appendingPathComponent("Contents/Info.plist"),
            root.appendingPathComponent("Resources/Info.plist"),
            root.appendingPathComponent("Versions/Current/Resources/Info.plist"),
            root.appendingPathComponent("Info.plist")
        ]
        if root.pathExtension.lowercased() == "framework" {
            return [common[2], common[1], common[3], common[0]]
        }
        return common
    }

    private func executableCandidates(
        root: URL,
        resolvedInfoURL: URL,
        executableName: String
    ) -> [URL] {
        var candidates: [URL] = []
        let infoParent = resolvedInfoURL.deletingLastPathComponent()
        if infoParent.lastPathComponent == "Resources" {
            candidates.append(
                infoParent.deletingLastPathComponent().appendingPathComponent(executableName)
            )
        }
        candidates += [
            root.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName),
            root.appendingPathComponent("Versions/Current").appendingPathComponent(executableName),
            root.appendingPathComponent("MacOS").appendingPathComponent(executableName),
            root.appendingPathComponent(executableName)
        ]
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.path).inserted }
    }

    private func firstExistingURL(_ candidates: [URL]) -> URL? {
        candidates.first { candidate in
            var status = stat()
            return lstat(candidate.path, &status) == 0
        }
    }

    private func containedResolvedURL(
        _ candidate: URL,
        root: URL,
        side: VersionComparisonSide,
        resource: VersionComparisonResource
    ) throws -> URL {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = resolvedRoot.pathComponents
        let candidateComponents = resolvedCandidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              candidateComponents.starts(with: rootComponents) else {
            throw VersionComparisonError.bundleBoundaryViolation(
                side: side,
                resource: resource
            )
        }
        return resolvedCandidate
    }

    private func readSmallFile(
        url: URL,
        limit: Int,
        side: VersionComparisonSide,
        resource: VersionComparisonResource
    ) throws -> SmallFileRead {
        let descriptor = try openRegularFile(url: url, side: side, resource: resource)
        defer { close(descriptor) }
        let before = try fileStatus(
            descriptor: descriptor,
            side: side,
            resource: resource
        )
        guard before.st_size >= 0 else {
            throw VersionComparisonError.notRegularFile(side: side, resource: resource)
        }
        guard before.st_size <= Int64(limit) else {
            throw VersionComparisonError.fileTooLarge(
                side: side,
                resource: resource,
                actualByteCount: before.st_size,
                limit: Int64(limit)
            )
        }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw classifiedPOSIXError(errno, side: side, resource: resource)
            }
            data.append(contentsOf: buffer[0..<count])
            if data.count > limit {
                throw VersionComparisonError.fileTooLarge(
                    side: side,
                    resource: resource,
                    actualByteCount: Int64(data.count),
                    limit: Int64(limit)
                )
            }
        }
        let after = try fileStatus(descriptor: descriptor, side: side, resource: resource)
        guard stable(before: before, after: after), data.count == Int(before.st_size) else {
            throw VersionComparisonError.inputChanged(side: side, resource: resource)
        }
        return SmallFileRead(data: data, identity: FileIdentity(status: after))
    }

    private func readBinary(
        url: URL,
        side: VersionComparisonSide,
        resource: VersionComparisonResource
    ) throws -> BinaryRead {
        let descriptor = try openRegularFile(url: url, side: side, resource: resource)
        defer { close(descriptor) }
        let before = try fileStatus(
            descriptor: descriptor,
            side: side,
            resource: resource
        )
        guard before.st_size >= 0 else {
            throw VersionComparisonError.notRegularFile(side: side, resource: resource)
        }
        guard before.st_size <= limits.maximumFileByteCount else {
            throw VersionComparisonError.fileTooLarge(
                side: side,
                resource: resource,
                actualByteCount: before.st_size,
                limit: limits.maximumFileByteCount
            )
        }

        var hasher = SHA256()
        var readByteCount: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw classifiedPOSIXError(errno, side: side, resource: resource)
            }
            readByteCount += Int64(count)
            guard readByteCount <= limits.maximumFileByteCount else {
                throw VersionComparisonError.fileTooLarge(
                    side: side,
                    resource: resource,
                    actualByteCount: readByteCount,
                    limit: limits.maximumFileByteCount
                )
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        let after = try fileStatus(descriptor: descriptor, side: side, resource: resource)
        guard stable(before: before, after: after), readByteCount == before.st_size else {
            throw VersionComparisonError.inputChanged(side: side, resource: resource)
        }

        var parser = MachOParser(
            fileByteCount: UInt64(readByteCount),
            maximumArchitectureCount: limits.maximumArchitectureCount,
            maximumLoadCommandByteCount: limits.maximumMachOLoadCommandByteCount,
            maximumInspectionByteCount: limits.maximumMachOInspectionByteCount,
            readAt: { offset, count in
                try exactRead(
                    descriptor: descriptor,
                    offset: offset,
                    count: count,
                    side: side,
                    resource: resource
                )
            }
        )
        let machO: MachODescriptor?
        do {
            machO = try parser.parse()
        } catch let reason as VersionMachOErrorReason {
            throw VersionComparisonError.malformedMachO(side: side, reason: reason)
        }
        let finalStatus = try fileStatus(
            descriptor: descriptor,
            side: side,
            resource: resource
        )
        guard stable(before: before, after: finalStatus) else {
            throw VersionComparisonError.inputChanged(side: side, resource: resource)
        }

        return BinaryRead(
            byteCount: readByteCount,
            mode: before.st_mode,
            identity: FileIdentity(status: finalStatus),
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            machO: machO
        )
    }

    private func openRegularFile(
        url: URL,
        side: VersionComparisonSide,
        resource: VersionComparisonResource
    ) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw VersionComparisonError.symbolicLinkNotAllowed(side: side)
            }
            throw classifiedPOSIXError(errno, side: side, resource: resource)
        }
        do {
            let status = try fileStatus(
                descriptor: descriptor,
                side: side,
                resource: resource
            )
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw VersionComparisonError.notRegularFile(side: side, resource: resource)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func fileStatus(
        descriptor: Int32,
        side: VersionComparisonSide,
        resource: VersionComparisonResource
    ) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw classifiedPOSIXError(errno, side: side, resource: resource)
        }
        return status
    }

    private func stable(before: stat, after: stat) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private func exactRead(
        descriptor: Int32,
        offset: UInt64,
        count: Int,
        side: VersionComparisonSide,
        resource: VersionComparisonResource
    ) throws -> Data {
        guard offset <= UInt64(Int64.max), count >= 0 else {
            throw VersionComparisonError.malformedMachO(side: side, reason: .sliceOutOfBounds)
        }
        if count == 0 { return Data() }
        var data = Data(count: count)
        var completed = 0
        while completed < count {
            let result = data.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.pread(
                    descriptor,
                    base.advanced(by: completed),
                    count - completed,
                    off_t(offset) + off_t(completed)
                )
            }
            if result == 0 {
                throw VersionComparisonError.malformedMachO(
                    side: side,
                    reason: .truncatedHeader
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw classifiedPOSIXError(errno, side: side, resource: resource)
            }
            completed += result
        }
        return data
    }

    private func classifiedPOSIXError(
        _ code: Int32,
        side: VersionComparisonSide,
        resource: VersionComparisonResource
    ) -> VersionComparisonError {
        if code == EACCES || code == EPERM {
            return .permissionDenied(side: side, resource: resource)
        }
        return .readFailed(side: side, resource: resource, code: code)
    }

    private func fileKind(machO: MachODescriptor?, mode: mode_t) -> VersionResourceKind {
        guard let machO else {
            return mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 ? .executable : .regularFile
        }
        switch machO.fileType {
        case 2: return .executable
        case 6: return .dynamicLibrary
        case 8: return .bundle
        default: return .machO
        }
    }

    private func validatedCodeSignature(
        at url: URL,
        applicable: Bool,
        isBundle: Bool,
        checks: [IdentityCheck],
        side: VersionComparisonSide
    ) throws -> VersionCodeSignature {
        for check in checks {
            try validateIdentity(
                at: check.url,
                expected: check.identity,
                side: side,
                resource: check.resource
            )
        }
        let signature = codeSignature(at: url, applicable: applicable, isBundle: isBundle)
        for check in checks {
            try validateIdentity(
                at: check.url,
                expected: check.identity,
                side: side,
                resource: check.resource
            )
        }
        return signature
    }

    private func validateIdentity(
        at url: URL,
        expected: FileIdentity,
        side: VersionComparisonSide,
        resource: VersionComparisonResource
    ) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw VersionComparisonError.inputChanged(side: side, resource: resource)
        }
        guard FileIdentity(status: status) == expected else {
            throw VersionComparisonError.inputChanged(side: side, resource: resource)
        }
    }

    private func codeSignature(
        at url: URL,
        applicable: Bool,
        isBundle: Bool
    ) -> VersionCodeSignature {
        guard applicable else {
            return VersionCodeSignature(status: .notApplicable)
        }
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            if createStatus == errSecCSUnsigned {
                return VersionCodeSignature(
                    status: .unsigned,
                    diagnosticCode: createStatus
                )
            }
            return VersionCodeSignature(
                status: .unavailable,
                diagnosticCode: createStatus
            )
        }

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        let dictionary = signingInformation as NSDictionary?
        let teamIdentifier = dictionary?.object(forKey: kSecCodeInfoTeamIdentifier) as? String
        let signingIdentifier = dictionary?.object(forKey: kSecCodeInfoIdentifier) as? String

        var validityFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        if isBundle {
            validityFlags.insert(SecCSFlags(rawValue: kSecCSDoNotValidateResources))
            validityFlags.insert(SecCSFlags(rawValue: kSecCSRestrictSymlinks))
        }
        let validityStatus = SecStaticCodeCheckValidity(staticCode, validityFlags, nil)
        let status: VersionCodeSignatureStatus
        if validityStatus == errSecSuccess {
            status = .valid
        } else if validityStatus == errSecCSUnsigned {
            status = .unsigned
        } else {
            status = .invalid
        }
        return VersionCodeSignature(
            status: status,
            teamIdentifier: informationStatus == errSecSuccess ? teamIdentifier : nil,
            signingIdentifier: informationStatus == errSecSuccess ? signingIdentifier : nil,
            diagnosticCode: validityStatus == errSecSuccess ? nil : validityStatus
        )
    }

    private func value(
        for field: VersionComparisonField,
        in snapshot: VersionResourceSnapshot
    ) -> VersionComparisonValue {
        switch field {
        case .displayName: .string(snapshot.displayName)
        case .kind: .string(snapshot.kind.rawValue)
        case .bundleIdentifier: optionalString(snapshot.bundleIdentifier)
        case .shortVersionString: optionalString(snapshot.shortVersionString)
        case .bundleVersion: optionalString(snapshot.bundleVersion)
        case .packageType: optionalString(snapshot.packageType)
        case .minimumSystemVersion: optionalString(snapshot.minimumSystemVersion)
        case .architectures: .strings(snapshot.architectures.map(\.displayName))
        case .fileByteCount: .integer(snapshot.fileByteCount)
        case .sha256: .string(snapshot.sha256)
        case .signatureStatus: .string(snapshot.codeSignature.status.rawValue)
        case .signingTeamIdentifier: optionalString(snapshot.codeSignature.teamIdentifier)
        case .signingIdentifier: optionalString(snapshot.codeSignature.signingIdentifier)
        case .signatureDiagnosticCode:
            snapshot.codeSignature.diagnosticCode.map { .integer(Int64($0)) } ?? .null
        }
    }

    private func optionalString(_ value: String?) -> VersionComparisonValue {
        value.map(VersionComparisonValue.string) ?? .null
    }
}

private struct BinaryRead {
    let byteCount: Int64
    let mode: mode_t
    let identity: FileIdentity
    let sha256: String
    let machO: MachODescriptor?
}

private struct SmallFileRead {
    let data: Data
    let identity: FileIdentity
}

private struct IdentityCheck {
    let url: URL
    let identity: FileIdentity
    let resource: VersionComparisonResource
}

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int

    init(status: stat) {
        device = status.st_dev
        inode = status.st_ino
        mode = status.st_mode
        size = status.st_size
        modificationSeconds = status.st_mtimespec.tv_sec
        modificationNanoseconds = status.st_mtimespec.tv_nsec
        changeSeconds = status.st_ctimespec.tv_sec
        changeNanoseconds = status.st_ctimespec.tv_nsec
    }
}

private enum MachOEndian {
    case little
    case big
}

private struct ThinMachODescriptor {
    let architecture: VersionArchitecture
    let fileType: UInt32
    let minimumSystemVersion: UInt32?
}

private struct MachODescriptor {
    let architectures: [VersionArchitecture]
    let fileType: UInt32?
    let minimumSystemVersion: String?
}

private struct MachOParser {
    let fileByteCount: UInt64
    let maximumArchitectureCount: Int
    let maximumLoadCommandByteCount: Int
    let maximumInspectionByteCount: Int
    let readAt: (UInt64, Int) throws -> Data
    private var inspectedByteCount = 0

    init(
        fileByteCount: UInt64,
        maximumArchitectureCount: Int,
        maximumLoadCommandByteCount: Int,
        maximumInspectionByteCount: Int,
        readAt: @escaping (UInt64, Int) throws -> Data
    ) {
        self.fileByteCount = fileByteCount
        self.maximumArchitectureCount = maximumArchitectureCount
        self.maximumLoadCommandByteCount = maximumLoadCommandByteCount
        self.maximumInspectionByteCount = maximumInspectionByteCount
        self.readAt = readAt
    }

    mutating func parse() throws -> MachODescriptor? {
        guard fileByteCount >= 4 else { return nil }
        let magicData = try boundedRead(offset: 0, count: 4)
        let bytes = Array(magicData)
        if let thinMagic = thinMagic(bytes) {
            let thin = try parseThin(
                offset: 0,
                declaredByteCount: fileByteCount,
                endian: thinMagic.endian,
                is64Bit: thinMagic.is64Bit,
                expectedCPUType: nil
            )
            return MachODescriptor(
                architectures: [thin.architecture],
                fileType: thin.fileType,
                minimumSystemVersion: thin.minimumSystemVersion.map(versionString)
            )
        }
        guard let fatMagic = fatMagic(bytes) else { return nil }
        return try parseFat(endian: fatMagic.endian, is64Bit: fatMagic.is64Bit)
    }

    private mutating func parseFat(
        endian: MachOEndian,
        is64Bit: Bool
    ) throws -> MachODescriptor {
        guard fileByteCount >= 8 else { throw VersionMachOErrorReason.truncatedHeader }
        let header = try boundedRead(offset: 0, count: 8)
        guard let countValue = uint32(header, at: 4, endian: endian),
              countValue > 0 else {
            throw VersionMachOErrorReason.invalidArchitectureTable
        }
        guard maximumArchitectureCount > 0,
              Int(countValue) <= maximumArchitectureCount else {
            throw VersionMachOErrorReason.tooManyArchitectures
        }
        let architectureCount = Int(countValue)
        let entrySize = is64Bit ? 32 : 20
        let (entriesByteCount, entriesOverflow) = architectureCount.multipliedReportingOverflow(by: entrySize)
        let (tableByteCount, tableOverflow) = 8.addingReportingOverflow(entriesByteCount)
        guard !entriesOverflow,
              !tableOverflow,
              UInt64(tableByteCount) <= fileByteCount else {
            throw VersionMachOErrorReason.invalidArchitectureTable
        }
        let table = try boundedRead(offset: 0, count: tableByteCount)
        var entries: [FatEntry] = []
        entries.reserveCapacity(architectureCount)
        for index in 0..<architectureCount {
            let base = 8 + index * entrySize
            guard let cpuType = uint32(table, at: base, endian: endian),
                  let cpuSubtype = uint32(table, at: base + 4, endian: endian),
                  let offset = is64Bit
                    ? uint64(table, at: base + 8, endian: endian)
                    : uint32(table, at: base + 8, endian: endian).map(UInt64.init),
                  let size = is64Bit
                    ? uint64(table, at: base + 16, endian: endian)
                    : uint32(table, at: base + 12, endian: endian).map(UInt64.init),
                  let alignment = uint32(
                    table,
                    at: base + (is64Bit ? 24 : 16),
                    endian: endian
                  ),
                  size >= 28,
                  offset >= UInt64(tableByteCount),
                  offset <= fileByteCount,
                  size <= fileByteCount - offset,
                  alignment < 64,
                  offset % (UInt64(1) << UInt64(alignment)) == 0 else {
                throw VersionMachOErrorReason.sliceOutOfBounds
            }
            entries.append(
                FatEntry(
                    cpuType: cpuType,
                    cpuSubtype: cpuSubtype,
                    offset: offset,
                    size: size
                )
            )
        }
        let orderedByOffset = entries.sorted { lhs, rhs in
            lhs.offset == rhs.offset ? lhs.size < rhs.size : lhs.offset < rhs.offset
        }
        for pair in zip(orderedByOffset, orderedByOffset.dropFirst()) {
            guard pair.0.offset + pair.0.size <= pair.1.offset else {
                throw VersionMachOErrorReason.overlappingSlices
            }
        }

        var thinDescriptors: [ThinMachODescriptor] = []
        thinDescriptors.reserveCapacity(entries.count)
        for entry in entries {
            let magic = Array(try boundedRead(offset: entry.offset, count: 4))
            guard let thinMagic = thinMagic(magic) else {
                throw VersionMachOErrorReason.invalidSlice
            }
            thinDescriptors.append(
                try parseThin(
                    offset: entry.offset,
                    declaredByteCount: entry.size,
                    endian: thinMagic.endian,
                    is64Bit: thinMagic.is64Bit,
                    expectedCPUType: entry.cpuType
                )
            )
        }

        let architectures = Array(Set(thinDescriptors.map(\.architecture))).sorted {
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            if $0.cpuType != $1.cpuType { return $0.cpuType < $1.cpuType }
            return $0.cpuSubtype < $1.cpuSubtype
        }
        let fileTypes = Set(thinDescriptors.map(\.fileType))
        let minimum = thinDescriptors.compactMap(\.minimumSystemVersion).max()
        return MachODescriptor(
            architectures: architectures,
            fileType: fileTypes.count == 1 ? fileTypes.first : nil,
            minimumSystemVersion: minimum.map(versionString)
        )
    }

    private mutating func parseThin(
        offset: UInt64,
        declaredByteCount: UInt64,
        endian: MachOEndian,
        is64Bit: Bool,
        expectedCPUType: UInt32?
    ) throws -> ThinMachODescriptor {
        let headerByteCount = is64Bit ? 32 : 28
        guard declaredByteCount >= UInt64(headerByteCount) else {
            throw VersionMachOErrorReason.truncatedHeader
        }
        let header = try boundedRead(offset: offset, count: headerByteCount)
        guard let cpuType = uint32(header, at: 4, endian: endian),
              let cpuSubtype = uint32(header, at: 8, endian: endian),
              let fileType = uint32(header, at: 12, endian: endian),
              let commandCount = uint32(header, at: 16, endian: endian),
              let commandByteCountValue = uint32(header, at: 20, endian: endian) else {
            throw VersionMachOErrorReason.truncatedHeader
        }
        if let expectedCPUType, expectedCPUType != cpuType {
            throw VersionMachOErrorReason.cpuTypeMismatch
        }
        guard maximumLoadCommandByteCount > 0,
              Int(commandByteCountValue) <= maximumLoadCommandByteCount else {
            throw VersionMachOErrorReason.loadCommandsTooLarge
        }
        let commandByteCount = Int(commandByteCountValue)
        guard UInt64(headerByteCount) + UInt64(commandByteCount) <= declaredByteCount else {
            throw VersionMachOErrorReason.loadCommandsOutOfBounds
        }
        if commandCount == 0, commandByteCount != 0 {
            throw VersionMachOErrorReason.malformedLoadCommands
        }
        if commandCount > 0, commandByteCount < 8 {
            throw VersionMachOErrorReason.malformedLoadCommands
        }

        let commands = commandByteCount == 0
            ? Data()
            : try boundedRead(
                offset: offset + UInt64(headerByteCount),
                count: commandByteCount
            )
        let minimum = try parseMinimumSystemVersion(
            commands: commands,
            commandCount: Int(commandCount),
            endian: endian
        )
        return ThinMachODescriptor(
            architecture: architecture(cpuType: cpuType, cpuSubtype: cpuSubtype),
            fileType: fileType,
            minimumSystemVersion: minimum
        )
    }

    private func parseMinimumSystemVersion(
        commands: Data,
        commandCount: Int,
        endian: MachOEndian
    ) throws -> UInt32? {
        var cursor = 0
        var versions: [UInt32] = []
        for _ in 0..<commandCount {
            guard cursor <= commands.count - 8,
                  let command = uint32(commands, at: cursor, endian: endian),
                  let sizeValue = uint32(commands, at: cursor + 4, endian: endian),
                  sizeValue >= 8,
                  sizeValue <= UInt32(commands.count - cursor) else {
                throw VersionMachOErrorReason.malformedLoadCommands
            }
            let size = Int(sizeValue)
            if command == 0x24 {
                guard size >= 16,
                      let version = uint32(commands, at: cursor + 8, endian: endian) else {
                    throw VersionMachOErrorReason.malformedLoadCommands
                }
                versions.append(version)
            } else if command == 0x32 {
                guard size >= 24,
                      let platform = uint32(commands, at: cursor + 8, endian: endian),
                      let minimum = uint32(commands, at: cursor + 12, endian: endian) else {
                    throw VersionMachOErrorReason.malformedLoadCommands
                }
                if platform == 1 { versions.append(minimum) }
            }
            cursor += size
        }
        guard cursor == commands.count else {
            throw VersionMachOErrorReason.malformedLoadCommands
        }
        return versions.max()
    }

    private mutating func boundedRead(offset: UInt64, count: Int) throws -> Data {
        let (next, overflow) = inspectedByteCount.addingReportingOverflow(count)
        guard !overflow, next <= maximumInspectionByteCount else {
            throw VersionMachOErrorReason.inspectionLimitExceeded
        }
        inspectedByteCount = next
        return try readAt(offset, count)
    }

    private func thinMagic(_ bytes: [UInt8]) -> (endian: MachOEndian, is64Bit: Bool)? {
        switch bytes {
        case [0xCE, 0xFA, 0xED, 0xFE]: (.little, false)
        case [0xCF, 0xFA, 0xED, 0xFE]: (.little, true)
        case [0xFE, 0xED, 0xFA, 0xCE]: (.big, false)
        case [0xFE, 0xED, 0xFA, 0xCF]: (.big, true)
        default: nil
        }
    }

    private func fatMagic(_ bytes: [UInt8]) -> (endian: MachOEndian, is64Bit: Bool)? {
        switch bytes {
        case [0xCA, 0xFE, 0xBA, 0xBE]: (.big, false)
        case [0xBE, 0xBA, 0xFE, 0xCA]: (.little, false)
        case [0xCA, 0xFE, 0xBA, 0xBF]: (.big, true)
        case [0xBF, 0xBA, 0xFE, 0xCA]: (.little, true)
        default: nil
        }
    }

    private func uint32(_ data: Data, at offset: Int, endian: MachOEndian) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let bytes = [
            UInt32(data[offset]),
            UInt32(data[offset + 1]),
            UInt32(data[offset + 2]),
            UInt32(data[offset + 3])
        ]
        switch endian {
        case .little:
            return bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24
        case .big:
            return bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
        }
    }

    private func uint64(_ data: Data, at offset: Int, endian: MachOEndian) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        switch endian {
        case .little:
            return (0..<8).reduce(UInt64(0)) { partial, index in
                partial | UInt64(data[offset + index]) << UInt64(index * 8)
            }
        case .big:
            return (0..<8).reduce(UInt64(0)) { partial, index in
                partial | UInt64(data[offset + index]) << UInt64((7 - index) * 8)
            }
        }
    }

    private func architecture(cpuType: UInt32, cpuSubtype: UInt32) -> VersionArchitecture {
        let subtype = cpuSubtype & 0x00ff_ffff
        let name: String
        switch cpuType {
        case 0x0100_000C:
            if subtype == 0 { name = "arm64" }
            else if subtype == 2 { name = "arm64e" }
            else { name = "arm64-subtype-\(subtype)" }
        case 0x0200_000C:
            name = subtype == 1 ? "arm64_32" : "arm64_32-subtype-\(subtype)"
        case 0x0000_000C:
            switch subtype {
            case 9: name = "armv7"
            case 11: name = "armv7s"
            default: name = "arm-subtype-\(subtype)"
            }
        case 0x0100_0007:
            if subtype == 3 { name = "x86_64" }
            else if subtype == 8 { name = "x86_64h" }
            else { name = "x86_64-subtype-\(subtype)" }
        case 0x0000_0007:
            name = subtype == 3 ? "i386" : "x86-subtype-\(subtype)"
        case 0x0100_0012:
            name = "ppc64-subtype-\(subtype)"
        case 0x0000_0012:
            name = "ppc-subtype-\(subtype)"
        default:
            name = String(format: "cpu-0x%08x-subtype-%u", cpuType, subtype)
        }
        return VersionArchitecture(
            cpuType: cpuType,
            cpuSubtype: cpuSubtype,
            displayName: name
        )
    }

    private func versionString(_ encoded: UInt32) -> String {
        let major = encoded >> 16
        let minor = (encoded >> 8) & 0xff
        let patch = encoded & 0xff
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }
}

private struct FatEntry {
    let cpuType: UInt32
    let cpuSubtype: UInt32
    let offset: UInt64
    let size: UInt64
}
