import CryptoKit
import Foundation
import Testing
@testable import RiffaCore

@Suite("macOS version and binary comparison")
struct VersionComparisonTests {
    @Test("Ordinary files produce path-free bounded identity snapshots")
    func ordinaryFile() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("notes<1>.txt")
            let bytes = Data("version identity".utf8)
            try bytes.write(to: file)

            let snapshot = try VersionComparisonEngine().inspect(url: file, side: .left)

            #expect(snapshot.displayName == "notes<1>.txt")
            #expect(snapshot.kind == .regularFile)
            #expect(snapshot.fileByteCount == Int64(bytes.count))
            #expect(snapshot.sha256 == hexDigest(bytes))
            #expect(snapshot.architectures.isEmpty)
            #expect(snapshot.codeSignature.status == .notApplicable)
            let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
            #expect(!encoded.contains(directory.path))
        }
    }

    @Test("A thin arm64 Mach-O header exposes architecture kind and deployment target")
    func thinMachO() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("Runner")
            let bytes = makeThinMachOData(
                cpuType: 0x0100_000C,
                cpuSubtype: 0,
                fileType: 2,
                minimumSystemVersion: (14, 2, 1)
            )
            try bytes.write(to: file)

            let snapshot = try VersionComparisonEngine().inspect(url: file, side: .left)

            #expect(snapshot.kind == .executable)
            #expect(snapshot.architectures.map(\.displayName) == ["arm64"])
            #expect(snapshot.minimumSystemVersion == "14.2.1")
            #expect(snapshot.fileByteCount == Int64(bytes.count))
        }
    }

    @Test("A fat Mach-O validates slices and sorts universal architectures")
    func fatMachO() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("Universal")
            let bytes = makeFatMachOData(
                slices: [
                    (cpuType: 0x0100_0007, cpuSubtype: 3),
                    (cpuType: 0x0100_000C, cpuSubtype: 0)
                ]
            )
            try bytes.write(to: file)

            let snapshot = try VersionComparisonEngine().inspect(url: file, side: .left)

            #expect(snapshot.kind == .executable)
            #expect(snapshot.architectures.map(\.displayName) == ["arm64", "x86_64"])
            #expect(snapshot.architectures.count == 2)
        }
    }

    @Test("App bundle Info.plist and main executable form one portable snapshot")
    func appBundle() throws {
        try withTemporaryDirectory { directory in
            let app = try makeApp(
                root: directory,
                name: "Riffa Demo.app",
                identifier: "dev.riffa.demo",
                shortVersion: "2.4.1",
                buildVersion: "20401",
                minimumSystemVersion: "14.0"
            )

            let snapshot = try VersionComparisonEngine().inspect(url: app, side: .left)

            #expect(snapshot.displayName == "Riffa Demo.app")
            #expect(snapshot.kind == .applicationBundle)
            #expect(snapshot.bundleIdentifier == "dev.riffa.demo")
            #expect(snapshot.shortVersionString == "2.4.1")
            #expect(snapshot.bundleVersion == "20401")
            #expect(snapshot.packageType == "APPL")
            #expect(snapshot.minimumSystemVersion == "14.0")
            #expect(snapshot.architectures.map(\.displayName) == ["arm64"])
            #expect(snapshot.sha256 == hexDigest(makeThinMachOData(
                cpuType: 0x0100_000C,
                cpuSubtype: 0,
                fileType: 2
            )))
        }
    }

    @Test("Frameworks generic bundles and Mach-O dylibs retain native kinds")
    func nativeResourceKinds() throws {
        try withTemporaryDirectory { directory in
            let framework = directory.appendingPathComponent("Kit.framework", isDirectory: true)
            let versionRoot = framework.appendingPathComponent("Versions/A", isDirectory: true)
            let resources = versionRoot.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try writeInfoPlist(
                [
                    "CFBundleExecutable": "Kit",
                    "CFBundleIdentifier": "dev.riffa.kit",
                    "CFBundlePackageType": "FMWK",
                    "CFBundleVersion": "7"
                ],
                to: resources.appendingPathComponent("Info.plist")
            )
            try makeThinMachOData(
                cpuType: 0x0100_000C,
                cpuSubtype: 0,
                fileType: 6
            ).write(to: versionRoot.appendingPathComponent("Kit"))
            try FileManager.default.createSymbolicLink(
                atPath: framework.appendingPathComponent("Versions/Current").path,
                withDestinationPath: "A"
            )

            let bundle = directory.appendingPathComponent("Plugin.bundle", isDirectory: true)
            let bundleMacOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(
                at: bundleMacOS,
                withIntermediateDirectories: true
            )
            try writeInfoPlist(
                [
                    "CFBundleExecutable": "Plugin",
                    "CFBundleIdentifier": "dev.riffa.plugin",
                    "CFBundlePackageType": "BNDL"
                ],
                to: bundle.appendingPathComponent("Contents/Info.plist")
            )
            try makeThinMachOData(
                cpuType: 0x0100_000C,
                cpuSubtype: 0,
                fileType: 8
            ).write(to: bundleMacOS.appendingPathComponent("Plugin"))

            let dylib = directory.appendingPathComponent("libRiffa.dylib")
            try makeThinMachOData(
                cpuType: 0x0100_000C,
                cpuSubtype: 0,
                fileType: 6
            ).write(to: dylib)

            let engine = VersionComparisonEngine()
            let frameworkSnapshot = try engine.inspect(url: framework, side: .left)
            let bundleSnapshot = try engine.inspect(url: bundle, side: .left)
            let dylibSnapshot = try engine.inspect(url: dylib, side: .right)

            #expect(frameworkSnapshot.kind == .framework)
            #expect(frameworkSnapshot.bundleIdentifier == "dev.riffa.kit")
            #expect(frameworkSnapshot.architectures.map(\.displayName) == ["arm64"])
            #expect(bundleSnapshot.kind == .bundle)
            #expect(bundleSnapshot.bundleIdentifier == "dev.riffa.plugin")
            #expect(dylibSnapshot.kind == .dynamicLibrary)
        }
    }

    @Test("Version field differences are complete and deterministically ordered")
    func stableDifferences() {
        let left = fixtureSnapshot(name: "Old.app", shortVersion: "1.0", hash: "aaa")
        let right = fixtureSnapshot(name: "New.app", shortVersion: "2.0", hash: "bbb")
        let engine = VersionComparisonEngine()

        let first = engine.compare(left: left, right: right)
        let second = engine.compare(left: left, right: right)

        #expect(first == second)
        #expect(first.fields.map(\.field) == VersionComparisonField.allCases)
        #expect(first.differingFields == [.displayName, .shortVersionString, .sha256])
        #expect(first.statistics.totalFieldCount == VersionComparisonField.allCases.count)
        #expect(first.statistics.differentFieldCount == 3)
        #expect(first.hasDifferences)
    }

    @Test("Malformed fat counts offsets and slices fail with structured reasons", arguments: [
        MalformedFixture.tooManyArchitectures,
        MalformedFixture.outOfBoundsSlice,
        MalformedFixture.invalidSlice
    ])
    func malformedFatMachO(fixture: MalformedFixture) throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("broken.bin")
            try fixture.data.write(to: file)
            let limits = VersionComparisonLimits(maximumArchitectureCount: 2)

            #expect(throws: fixture.expectedError) {
                _ = try VersionComparisonEngine(limits: limits).inspect(url: file, side: .right)
            }
        }
    }

    @Test("Main binaries and Info.plist files enforce independent byte limits")
    func resourceLimits() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("large.bin")
            try Data(repeating: 0x41, count: 9).write(to: file)
            let binaryLimits = VersionComparisonLimits(maximumFileByteCount: 8)
            #expect(throws: VersionComparisonError.fileTooLarge(
                side: .left,
                resource: .input,
                actualByteCount: 9,
                limit: 8
            )) {
                _ = try VersionComparisonEngine(limits: binaryLimits).inspect(
                    url: file,
                    side: .left
                )
            }

            let app = try makeApp(root: directory, name: "Limited.app")
            let infoURL = app.appendingPathComponent("Contents/Info.plist")
            let infoCount = try Data(contentsOf: infoURL).count
            let plistLimits = VersionComparisonLimits(
                maximumInfoPlistByteCount: infoCount - 1
            )
            #expect(throws: VersionComparisonError.fileTooLarge(
                side: .right,
                resource: .infoPlist,
                actualByteCount: Int64(infoCount),
                limit: Int64(infoCount - 1)
            )) {
                _ = try VersionComparisonEngine(limits: plistLimits).inspect(
                    url: app,
                    side: .right
                )
            }
        }
    }

    @Test("Direct symlinks are rejected and bundle-internal links cannot escape")
    func symbolicLinkBoundary() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("target")
            try Data("target".utf8).write(to: target)
            let link = directory.appendingPathComponent("selected-link")
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: target
            )
            #expect(throws: VersionComparisonError.symbolicLinkNotAllowed(side: .left)) {
                _ = try VersionComparisonEngine().inspect(url: link, side: .left)
            }

            let app = directory.appendingPathComponent("Escape.app", isDirectory: true)
            let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(
                at: macOS,
                withIntermediateDirectories: true
            )
            try writeInfoPlist(
                [
                    "CFBundleExecutable": "Runner",
                    "CFBundleIdentifier": "dev.riffa.escape",
                    "CFBundlePackageType": "APPL"
                ],
                to: app.appendingPathComponent("Contents/Info.plist")
            )
            try FileManager.default.createSymbolicLink(
                at: macOS.appendingPathComponent("Runner"),
                withDestinationURL: target
            )
            #expect(throws: VersionComparisonError.bundleBoundaryViolation(
                side: .right,
                resource: .mainExecutable
            )) {
                _ = try VersionComparisonEngine().inspect(url: app, side: .right)
            }
        }
    }

    @Test("Errors and results never serialize source directory locators")
    func locatorPrivacy() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("Secret/Absent.app")
            let error: VersionComparisonError
            do {
                _ = try VersionComparisonEngine().inspect(url: missing, side: .left)
                Issue.record("Expected inspection to fail")
                return
            } catch let caught as VersionComparisonError {
                error = caught
            }

            let encoded = String(decoding: try JSONEncoder().encode(error), as: UTF8.self)
            #expect(!encoded.contains(directory.path))
            #expect(!(error.errorDescription ?? "").contains(directory.path))

            let result = VersionComparisonEngine().compare(
                left: fixtureSnapshot(name: "left.bin", shortVersion: "1", hash: "a"),
                right: fixtureSnapshot(name: "right.bin", shortVersion: "2", hash: "b")
            )
            let resultJSON = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            #expect(!resultJSON.contains(directory.path))
            #expect(!resultJSON.contains("sourceURL"))
            #expect(!resultJSON.contains("locator"))
        }
    }

    private func fixtureSnapshot(
        name: String,
        shortVersion: String,
        hash: String
    ) -> VersionResourceSnapshot {
        VersionResourceSnapshot(
            displayName: name,
            kind: .applicationBundle,
            bundleIdentifier: "dev.riffa.fixture",
            shortVersionString: shortVersion,
            bundleVersion: "1",
            packageType: "APPL",
            minimumSystemVersion: "14.0",
            architectures: [
                VersionArchitecture(
                    cpuType: 0x0100_000C,
                    cpuSubtype: 0,
                    displayName: "arm64"
                )
            ],
            fileByteCount: 32,
            sha256: hash,
            codeSignature: VersionCodeSignature(status: .unsigned, diagnosticCode: -67062)
        )
    }

    private func makeApp(
        root: URL,
        name: String,
        identifier: String = "dev.riffa.limited",
        shortVersion: String = "1.0",
        buildVersion: String = "1",
        minimumSystemVersion: String = "14.0"
    ) throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try writeInfoPlist(
            [
                "CFBundleExecutable": "Runner",
                "CFBundleIdentifier": identifier,
                "CFBundleShortVersionString": shortVersion,
                "CFBundleVersion": buildVersion,
                "CFBundlePackageType": "APPL",
                "LSMinimumSystemVersion": minimumSystemVersion
            ],
            to: app.appendingPathComponent("Contents/Info.plist")
        )
        try makeThinMachOData(
            cpuType: 0x0100_000C,
            cpuSubtype: 0,
            fileType: 2
        ).write(to: macOS.appendingPathComponent("Runner"))
        return app
    }

    private func writeInfoPlist(_ value: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RiffaVersionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum MalformedFixture: CaseIterable, Sendable {
    case tooManyArchitectures
    case outOfBoundsSlice
    case invalidSlice

    var data: Data {
        switch self {
        case .tooManyArchitectures:
            var data = Data([0xCA, 0xFE, 0xBA, 0xBE])
            appendUInt32(3, endian: .big, to: &data)
            return data
        case .outOfBoundsSlice:
            var data = Data([0xCA, 0xFE, 0xBA, 0xBE])
            appendUInt32(1, endian: .big, to: &data)
            appendUInt32(0x0100_000C, endian: .big, to: &data)
            appendUInt32(0, endian: .big, to: &data)
            appendUInt32(4_096, endian: .big, to: &data)
            appendUInt32(32, endian: .big, to: &data)
            appendUInt32(12, endian: .big, to: &data)
            return data
        case .invalidSlice:
            var data = Data([0xCA, 0xFE, 0xBA, 0xBE])
            appendUInt32(1, endian: .big, to: &data)
            appendUInt32(0x0100_000C, endian: .big, to: &data)
            appendUInt32(0, endian: .big, to: &data)
            appendUInt32(32, endian: .big, to: &data)
            appendUInt32(32, endian: .big, to: &data)
            appendUInt32(5, endian: .big, to: &data)
            data.append(Data(repeating: 0, count: 40))
            return data
        }
    }

    var expectedError: VersionComparisonError {
        switch self {
        case .tooManyArchitectures:
            .malformedMachO(side: .right, reason: .tooManyArchitectures)
        case .outOfBoundsSlice:
            .malformedMachO(side: .right, reason: .sliceOutOfBounds)
        case .invalidSlice:
            .malformedMachO(side: .right, reason: .invalidSlice)
        }
    }
}

private enum TestEndian {
    case little
    case big
}

private func makeThinMachOData(
    cpuType: UInt32,
    cpuSubtype: UInt32,
    fileType: UInt32,
    minimumSystemVersion: (UInt32, UInt32, UInt32)? = nil
) -> Data {
    var data = Data([0xCF, 0xFA, 0xED, 0xFE])
    appendUInt32(cpuType, endian: .little, to: &data)
    appendUInt32(cpuSubtype, endian: .little, to: &data)
    appendUInt32(fileType, endian: .little, to: &data)
    appendUInt32(minimumSystemVersion == nil ? 0 : 1, endian: .little, to: &data)
    appendUInt32(minimumSystemVersion == nil ? 0 : 24, endian: .little, to: &data)
    appendUInt32(0, endian: .little, to: &data)
    appendUInt32(0, endian: .little, to: &data)
    if let minimumSystemVersion {
        appendUInt32(0x32, endian: .little, to: &data)
        appendUInt32(24, endian: .little, to: &data)
        appendUInt32(1, endian: .little, to: &data)
        let encoded = minimumSystemVersion.0 << 16
            | minimumSystemVersion.1 << 8
            | minimumSystemVersion.2
        appendUInt32(encoded, endian: .little, to: &data)
        appendUInt32(encoded, endian: .little, to: &data)
        appendUInt32(0, endian: .little, to: &data)
    }
    return data
}

private func makeFatMachOData(slices: [(cpuType: UInt32, cpuSubtype: UInt32)]) -> Data {
    let firstOffset = 4_096
    let stride = 4_096
    var data = Data([0xCA, 0xFE, 0xBA, 0xBE])
    appendUInt32(UInt32(slices.count), endian: .big, to: &data)
    for (index, slice) in slices.enumerated() {
        appendUInt32(slice.cpuType, endian: .big, to: &data)
        appendUInt32(slice.cpuSubtype, endian: .big, to: &data)
        appendUInt32(UInt32(firstOffset + index * stride), endian: .big, to: &data)
        appendUInt32(32, endian: .big, to: &data)
        appendUInt32(12, endian: .big, to: &data)
    }
    if data.count < firstOffset {
        data.append(Data(repeating: 0, count: firstOffset - data.count))
    }
    for (index, slice) in slices.enumerated() {
        let desiredOffset = firstOffset + index * stride
        if data.count < desiredOffset {
            data.append(Data(repeating: 0, count: desiredOffset - data.count))
        }
        data.append(makeThinMachOData(
            cpuType: slice.cpuType,
            cpuSubtype: slice.cpuSubtype,
            fileType: 2
        ))
    }
    return data
}

private func appendUInt32(
    _ value: UInt32,
    endian: TestEndian,
    to data: inout Data
) {
    let bytes: [UInt8]
    switch endian {
    case .little:
        bytes = [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24)
        ]
    case .big:
        bytes = [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
    }
    data.append(contentsOf: bytes)
}
