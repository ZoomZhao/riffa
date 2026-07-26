import CryptoKit
import Darwin
import Foundation
import Testing
@testable import RiffaCore

@Test("Verified move atomically renames an unchanged ordinary file")
func verifiedMoveUsesNoClobberRename() async throws {
    let fixture = try VerifiedMoveFixture()
    defer { fixture.remove() }
    try fixture.populate(Data("same-volume bytes".utf8))
    #expect(Darwin.chmod(fixture.targetURL("old/item.bin").path, mode_t(0o640)) == 0)

    let result = try await LocalVerifiedFileMove().execute(fixture.request())

    #expect(result.strategy == .atomicRename)
    #expect(result.byteCount == UInt64("same-volume bytes".utf8.count))
    #expect(!fixture.existsInTarget("old/item.bin"))
    #expect(try fixture.targetData("new/item.bin") == Data("same-volume bytes".utf8))
    #expect(try fixture.referenceData() == Data("same-volume bytes".utf8))
    #expect(filePermissions(fixture.targetURL("new/item.bin")) == mode_t(0o640))
    #expect(try fixture.temporaryNames().isEmpty)
}

@Test("Read-only verification fully checks proof and destination without writing")
func verifiedMovePreflightIsReadOnly() async throws {
    let fixture = try VerifiedMoveFixture()
    defer { fixture.remove() }
    try fixture.populate(Data("preflight".utf8))

    let receipt = try await LocalVerifiedFileMove().verify(fixture.request())

    #expect(receipt.byteCount == UInt64("preflight".utf8.count))
    #expect(receipt.sha256 == verifiedMoveSHA256(Data("preflight".utf8)))
    #expect(try fixture.targetData("old/item.bin") == Data("preflight".utf8))
    #expect(!fixture.existsInTarget("new/item.bin"))
    #expect(try fixture.temporaryNames().isEmpty)
}

@Test("Only EXDEV selects verified copy-delete and basic mode is retained")
func verifiedMoveForcedCrossDeviceFallback() async throws {
    let fixture = try VerifiedMoveFixture()
    defer { fixture.remove() }
    let bytes = Data(repeating: 0x5a, count: 700_000)
    try fixture.populate(bytes)
    #expect(Darwin.chmod(fixture.targetURL("old/item.bin").path, mode_t(0o604)) == 0)
    let expectedTime = timespec(tv_sec: 1_700_000_000, tv_nsec: 123_000_000)
    try setModificationTime(expectedTime, at: fixture.targetURL("old/item.bin"))
    try setUserXattr(Data("metadata-value".utf8), at: fixture.targetURL("old/item.bin"))

    let result = try await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
        point == .beforeRename ? .forceCrossDevice : .proceed
    }) {
        try await LocalVerifiedFileMove().execute(fixture.request())
    }

    #expect(result.strategy == .verifiedCopyThenDelete)
    #expect(!fixture.existsInTarget("old/item.bin"))
    #expect(try fixture.targetData("new/item.bin") == bytes)
    #expect(filePermissions(fixture.targetURL("new/item.bin")) == mode_t(0o604))
    #expect(fileModificationTime(fixture.targetURL("new/item.bin"))?.tv_sec == expectedTime.tv_sec)
    #expect(fileModificationTime(fixture.targetURL("new/item.bin"))?.tv_nsec == expectedTime.tv_nsec)
    #expect(try userXattr(at: fixture.targetURL("new/item.bin")) == Data("metadata-value".utf8))
    #expect(try fixture.temporaryNames().isEmpty)
}

@Test("Destination races never overwrite the winning entry")
func verifiedMoveDestinationRaceDoesNotClobber() async throws {
    let racingData = Data("racing destination".utf8)
    for forceFallback in [false, true] {
        let fixture = try VerifiedMoveFixture()
        defer { fixture.remove() }
        try fixture.populate(Data("source".utf8))
        let destination = fixture.targetURL("new/item.bin")

        await #expect(throws: LocalVerifiedFileMoveError.destinationExists) {
            try await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
                if point == .beforeRename, forceFallback {
                    return .forceCrossDevice
                }
                if (!forceFallback && point == .beforeRename) ||
                    (forceFallback && point.isCopyCheckpoint) {
                    try! racingData.write(to: destination)
                }
                return .proceed
            }) {
                try await LocalVerifiedFileMove().execute(fixture.request())
            }
        }

        #expect(try fixture.targetData("old/item.bin") == Data("source".utf8))
        #expect(try fixture.targetData("new/item.bin") == racingData)
        #expect(try fixture.temporaryNames().isEmpty)
    }
}

@Test("A non-EXDEV rename failure is fail-closed and never copies")
func verifiedMoveDoesNotFallbackForOtherErrnos() async throws {
    let fixture = try VerifiedMoveFixture()
    defer { fixture.remove() }
    try fixture.populate(Data("no fallback".utf8))

    await #expect(throws: LocalVerifiedFileMoveError.operationFailed(stage: .rename, code: EACCES)) {
        try await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
            point == .beforeRename ? .fail(code: EACCES) : .proceed
        }) {
            try await LocalVerifiedFileMove().execute(fixture.request())
        }
    }

    #expect(fixture.existsInTarget("old/item.bin"))
    #expect(!fixture.existsInTarget("new/item.bin"))
    #expect(try fixture.temporaryNames().isEmpty)
}

@Test("Source and reference rebinding or mutation is detected before commit")
func verifiedMoveDetectsInputChanges() async throws {
    for operand in [LocalVerifiedFileMoveOperand.source, .reference] {
        let fixture = try VerifiedMoveFixture()
        defer { fixture.remove() }
        try fixture.populate(Data(repeating: 0x31, count: 16_384))
        let changingURL = operand == .source
            ? fixture.targetURL("old/item.bin")
            : fixture.referenceURL("reference.bin")

        await #expect(throws: LocalVerifiedFileMoveError.fileChanged(operand)) {
            try await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
                if case let .hashing(current, byteCount) = point,
                   current == operand,
                   byteCount > 0 {
                    try! Data(repeating: 0x32, count: 16_384).write(to: changingURL)
                }
                return .proceed
            }) {
                try await LocalVerifiedFileMove().execute(fixture.request())
            }
        }

        #expect(!fixture.existsInTarget("new/item.bin"))
        #expect(try fixture.temporaryNames().isEmpty)
    }

    let fallbackFixture = try VerifiedMoveFixture()
    defer { fallbackFixture.remove() }
    try fallbackFixture.populate(Data(repeating: 0x41, count: 600_000))
    let referenceURL = fallbackFixture.referenceURL("reference.bin")
    await #expect(throws: LocalVerifiedFileMoveError.fileChanged(.reference)) {
        try await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
            if point == .beforeRename { return .forceCrossDevice }
            if point.isCopyCheckpoint {
                try! Data(repeating: 0x42, count: 600_000).write(to: referenceURL)
            }
            return .proceed
        }) {
            try await LocalVerifiedFileMove().execute(fallbackFixture.request())
        }
    }
    #expect(fallbackFixture.existsInTarget("old/item.bin"))
    #expect(!fallbackFixture.existsInTarget("new/item.bin"))
    #expect(try fallbackFixture.temporaryNames().isEmpty)
}

@Test("Unsafe paths, symlinks, intermediate links, and special files are refused")
func verifiedMoveRejectsUnsafeFileSystemEntries() async throws {
    let unsafePaths = ["", "/item", "../item", "a/../item", "a//item", "a/./item", "item/"]
    for path in unsafePaths {
        let fixture = try VerifiedMoveFixture()
        defer { fixture.remove() }
        try fixture.populate(Data("safe".utf8))
        await #expect(throws: LocalVerifiedFileMoveError.invalidRelativePath(.source)) {
            try await LocalVerifiedFileMove().verify(
                fixture.request(source: path)
            )
        }
    }

    do {
        let fixture = try VerifiedMoveFixture()
        defer { fixture.remove() }
        try fixture.populate(Data("safe".utf8))
        try FileManager.default.removeItem(at: fixture.targetURL("old/item.bin"))
        try FileManager.default.createSymbolicLink(
            at: fixture.targetURL("old/item.bin"),
            withDestinationURL: fixture.referenceURL("reference.bin")
        )
        await #expect(throws: LocalVerifiedFileMoveError.symbolicLinkNotAllowed(.source)) {
            try await LocalVerifiedFileMove().verify(fixture.request())
        }
    }

    do {
        let fixture = try VerifiedMoveFixture()
        defer { fixture.remove() }
        try fixture.populate(Data("safe".utf8))
        try FileManager.default.removeItem(at: fixture.targetURL("old/item.bin"))
        #expect(Darwin.mkfifo(fixture.targetURL("old/item.bin").path, mode_t(0o600)) == 0)
        await #expect(throws: LocalVerifiedFileMoveError.notRegularFile(.source)) {
            try await LocalVerifiedFileMove().verify(fixture.request())
        }
    }

    do {
        let fixture = try VerifiedMoveFixture()
        defer { fixture.remove() }
        try fixture.populate(Data("safe".utf8))
        try FileManager.default.createSymbolicLink(
            at: fixture.targetURL("linked"),
            withDestinationURL: fixture.referenceRoot
        )
        do {
            _ = try await LocalVerifiedFileMove().verify(
                fixture.request(source: "linked/reference.bin")
            )
            Issue.record("Expected safe parent traversal to reject an intermediate symlink")
        } catch let error as LocalVerifiedFileMoveError {
            guard case .parentOpenFailed(operand: .source, code: _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(!error.localizedDescription.contains(fixture.base.path))
        }
    }
}

@Test("Root acquisition refuses a symlink in any root path component")
func verifiedMoveUsesNoFollowAnyForRoots() async throws {
    let fixture = try VerifiedMoveFixture()
    defer { fixture.remove() }
    try fixture.populate(Data("root capability".utf8))
    let alias = fixture.base.appending(path: "target-alias", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.targetRoot)

    do {
        _ = try await LocalVerifiedFileMove().verify(fixture.request(targetRoot: alias))
        Issue.record("Expected O_NOFOLLOW_ANY to reject the aliased root")
    } catch let error as LocalVerifiedFileMoveError {
        guard case .rootOpenFailed(root: .target, code: _) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(!error.localizedDescription.contains(fixture.base.path))
    }
}

@Test("EXDEV faults and cancellation recover source, remove destination, and clean temp files")
func verifiedMoveCrossDeviceFailureRecovery() async throws {
    for phase in VerifiedMoveFailurePhase.allCases {
        let fixture = try VerifiedMoveFixture()
        defer { fixture.remove() }
        let original = Data(repeating: 0x7b, count: 600_000)
        try fixture.populate(original)
        let rollbackTime = timespec(tv_sec: 1_650_000_000, tv_nsec: 456_000_000)
        if phase == .afterUnlinkFailure {
            try setModificationTime(rollbackTime, at: fixture.targetURL("old/item.bin"))
            try setUserXattr(Data("rollback-metadata".utf8), at: fixture.targetURL("old/item.bin"))
        }

        do {
            _ = try await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
                if point == .beforeRename, phase != .atomicAfterInstallFailure {
                    return .forceCrossDevice
                }
                switch (phase, point) {
                case (.copyFailure, .copying):
                    return .fail(code: EIO)
                case (.copyCancellation, .copying):
                    return .cancel
                case (.afterInstallFailure, .afterInstall):
                    return .fail(code: EIO)
                case (.atomicAfterInstallFailure, .afterInstall):
                    return .fail(code: EIO)
                case (.afterUnlinkFailure, .afterUnlink):
                    return .fail(code: EIO)
                default:
                    return .proceed
                }
            }) {
                try await LocalVerifiedFileMove().execute(fixture.request())
            }
            Issue.record("Expected injected \(phase) failure")
        } catch is CancellationError {
            #expect(phase == .copyCancellation)
        } catch let error as LocalVerifiedFileMoveError {
            #expect(phase != .copyCancellation)
            guard case .operationFailed = error else {
                Issue.record("Unexpected error: \(error)")
                continue
            }
        }

        #expect(try fixture.targetData("old/item.bin") == original)
        if phase == .afterUnlinkFailure {
            #expect(fileModificationTime(fixture.targetURL("old/item.bin"))?.tv_sec == rollbackTime.tv_sec)
            #expect(fileModificationTime(fixture.targetURL("old/item.bin"))?.tv_nsec == rollbackTime.tv_nsec)
            #expect(try userXattr(at: fixture.targetURL("old/item.bin")) == Data("rollback-metadata".utf8))
        }
        #expect(!fixture.existsInTarget("new/item.bin"))
        #expect(try fixture.temporaryNames().isEmpty)
    }
}

@Test("Rollback failure is reported explicitly and never misreported as success")
func verifiedMoveReportsRollbackIncomplete() async throws {
    let fixture = try VerifiedMoveFixture()
    defer { fixture.remove() }
    let bytes = Data("rollback receipt".utf8)
    try fixture.populate(bytes)

    await #expect(throws: LocalVerifiedFileMoveError.rollbackIncomplete(
        originalStage: .sourceRemoval,
        originalCode: EIO,
        rollbackStage: .rollback,
        rollbackCode: ENOSPC
    )) {
        try await LocalVerifiedFileMoveFaultInjection.$handler.withValue({ point in
            switch point {
            case .beforeRename:
                .forceCrossDevice
            case .afterUnlink:
                .fail(code: EIO)
            case .beforeRollback:
                .fail(code: ENOSPC)
            default:
                .proceed
            }
        }) {
            try await LocalVerifiedFileMove().execute(fixture.request())
        }
    }

    #expect(!fixture.existsInTarget("old/item.bin"))
    #expect(try fixture.targetData("new/item.bin") == bytes)
    #expect(try fixture.temporaryNames().isEmpty)
}

@Test("Pre-cancellation is preserved and performs no file-system mutation")
func verifiedMovePreservesCancellation() async throws {
    let fixture = try VerifiedMoveFixture()
    defer { fixture.remove() }
    try fixture.populate(Data(repeating: 0x44, count: 1_000_000))
    let request = fixture.request()

    let task = Task {
        try await LocalVerifiedFileMove().execute(request)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    #expect(fixture.existsInTarget("old/item.bin"))
    #expect(!fixture.existsInTarget("new/item.bin"))
    #expect(try fixture.temporaryNames().isEmpty)
}

@Test("Move limits validate construction, Codable input, and exact boundaries")
func verifiedMoveLimitsAreFiniteAndExact() async throws {
    #expect(throws: LocalVerifiedFileMoveLimitProblem.maximumFileByteCountMustBePositive) {
        try LocalVerifiedFileMoveLimits(maximumFileByteCount: 0)
    }
    #expect(throws: LocalVerifiedFileMoveLimitProblem.chunkByteCountMustBePositive) {
        try LocalVerifiedFileMoveLimits(chunkByteCount: 0)
    }
    #expect(throws: LocalVerifiedFileMoveLimitProblem.maximumRelativePathUTF8ByteCountMustBePositive) {
        try LocalVerifiedFileMoveLimits(maximumRelativePathUTF8ByteCount: 0)
    }
    #expect(throws: LocalVerifiedFileMoveLimitProblem.maximumRelativePathDepthMustBePositive) {
        try LocalVerifiedFileMoveLimits(maximumRelativePathDepth: 0)
    }
    #expect(throws: LocalVerifiedFileMoveLimitProblem.chunkByteCountTooLarge) {
        try LocalVerifiedFileMoveLimits(chunkByteCount: 16 * 1_024 * 1_024 + 1)
    }

    let malformedProofFixture = try VerifiedMoveFixture()
    defer { malformedProofFixture.remove() }
    try malformedProofFixture.populate(Data("proof".utf8))
    await #expect(throws: LocalVerifiedFileMoveError.invalidProof(.malformedSHA256)) {
        try await LocalVerifiedFileMove().verify(
            malformedProofFixture.request(
                proof: LocalVerifiedFileMoveProof(
                    expectedByteCount: 5,
                    expectedSHA256: String(repeating: "A", count: 64)
                )
            )
        )
    }

    let invalidJSON = Data("""
        {"maximumFileByteCount":4,"chunkByteCount":0,"maximumRelativePathUTF8ByteCount":3,"maximumRelativePathDepth":1}
        """.utf8)
    #expect(throws: LocalVerifiedFileMoveLimitProblem.chunkByteCountMustBePositive) {
        try JSONDecoder().decode(LocalVerifiedFileMoveLimits.self, from: invalidJSON)
    }

    let exactFixture = try VerifiedMoveFixture(
        sourcePath: "src",
        destinationPath: "dst",
        referencePath: "ref"
    )
    defer { exactFixture.remove() }
    try exactFixture.populate(Data("1234".utf8))
    let exactLimits = try LocalVerifiedFileMoveLimits(
        maximumFileByteCount: 4,
        chunkByteCount: 2,
        maximumRelativePathUTF8ByteCount: 3,
        maximumRelativePathDepth: 1
    )
    let receipt = try await LocalVerifiedFileMove(limits: exactLimits).verify(exactFixture.request())
    #expect(receipt.byteCount == 4)

    let pathLimits = try LocalVerifiedFileMoveLimits(
        maximumFileByteCount: 4,
        chunkByteCount: 2,
        maximumRelativePathUTF8ByteCount: 3,
        maximumRelativePathDepth: 2
    )
    await #expect(throws: LocalVerifiedFileMoveError.relativePathTooLong(
        operand: .destination,
        actualUTF8ByteCount: 4,
        limit: 3
    )) {
        try await LocalVerifiedFileMove(limits: pathLimits).verify(
            exactFixture.request(destination: "long")
        )
    }

    let depthLimits = try LocalVerifiedFileMoveLimits(
        maximumFileByteCount: 4,
        chunkByteCount: 2,
        maximumRelativePathUTF8ByteCount: 64,
        maximumRelativePathDepth: 2
    )
    await #expect(throws: LocalVerifiedFileMoveError.relativePathTooDeep(
        operand: .source,
        actualDepth: 3,
        limit: 2
    )) {
        try await LocalVerifiedFileMove(limits: depthLimits).verify(
            exactFixture.request(source: "a/b/src")
        )
    }

    let oversizedFixture = try VerifiedMoveFixture()
    defer { oversizedFixture.remove() }
    try oversizedFixture.populate(Data("12345".utf8))
    let fileLimits = try LocalVerifiedFileMoveLimits(
        maximumFileByteCount: 4,
        chunkByteCount: 2,
        maximumRelativePathUTF8ByteCount: 64,
        maximumRelativePathDepth: 4
    )
    await #expect(throws: LocalVerifiedFileMoveError.proofExceedsFileLimit(
        actualByteCount: 5,
        limit: 4
    )) {
        try await LocalVerifiedFileMove(limits: fileLimits).verify(oversizedFixture.request())
    }

    let forgedProof = LocalVerifiedFileMoveProof(
        expectedByteCount: 4,
        expectedSHA256: String(repeating: "0", count: 64)
    )
    await #expect(throws: LocalVerifiedFileMoveError.fileTooLarge(
        operand: .source,
        actualByteCount: 5,
        limit: 4
    )) {
        try await LocalVerifiedFileMove(limits: fileLimits).verify(
            oversizedFixture.request(proof: forgedProof)
        )
    }
}

private enum VerifiedMoveFailurePhase: CaseIterable, Equatable {
    case copyFailure
    case copyCancellation
    case atomicAfterInstallFailure
    case afterInstallFailure
    case afterUnlinkFailure
}

private extension LocalVerifiedFileMoveCheckpoint {
    var isCopyCheckpoint: Bool {
        if case .copying = self { return true }
        return false
    }
}

private final class VerifiedMoveFixture {
    let base: URL
    let targetRoot: URL
    let referenceRoot: URL
    let sourcePath: String
    let destinationPath: String
    let referencePath: String
    private var proof: LocalVerifiedFileMoveProof?

    init(
        sourcePath: String = "old/item.bin",
        destinationPath: String = "new/item.bin",
        referencePath: String = "reference.bin"
    ) throws {
        let unresolved = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(path: "riffa-verified-move-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        // Keep the real `/private/tmp` spelling. Foundation's symlink resolver
        // may cosmetically shorten it back to `/tmp`, which is itself a link
        // and is intentionally rejected by O_NOFOLLOW_ANY.
        base = unresolved
        targetRoot = base.appending(path: "target", directoryHint: .isDirectory)
        referenceRoot = base.appending(path: "reference", directoryHint: .isDirectory)
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.referencePath = referencePath
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: referenceRoot, withIntermediateDirectories: true)
    }

    func populate(_ data: Data) throws {
        try write(data, to: targetURL(sourcePath))
        try write(data, to: referenceURL(referencePath))
        try FileManager.default.createDirectory(
            at: targetURL(destinationPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        proof = LocalVerifiedFileMoveProof(
            expectedByteCount: UInt64(data.count),
            expectedSHA256: verifiedMoveSHA256(data)
        )
    }

    func request(
        targetRoot explicitTargetRoot: URL? = nil,
        source: String? = nil,
        destination: String? = nil,
        reference: String? = nil,
        proof explicitProof: LocalVerifiedFileMoveProof? = nil
    ) -> LocalVerifiedFileMoveRequest {
        LocalVerifiedFileMoveRequest(
            targetRoot: explicitTargetRoot ?? targetRoot,
            sourceRelativePath: source ?? sourcePath,
            destinationRelativePath: destination ?? destinationPath,
            referenceRoot: referenceRoot,
            referenceRelativePath: reference ?? referencePath,
            proof: explicitProof ?? proof!
        )
    }

    func targetURL(_ path: String) -> URL {
        targetRoot.appending(path: path)
    }

    func referenceURL(_ path: String) -> URL {
        referenceRoot.appending(path: path)
    }

    func targetData(_ path: String) throws -> Data {
        try Data(contentsOf: targetURL(path))
    }

    func referenceData() throws -> Data {
        try Data(contentsOf: referenceURL(referencePath))
    }

    func existsInTarget(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: targetURL(path).path)
    }

    func temporaryNames() throws -> [String] {
        let enumerator = FileManager.default.enumerator(
            at: targetRoot,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: nil
        )
        return (enumerator?.allObjects as? [URL] ?? []).map(\.lastPathComponent).filter {
            $0.hasPrefix(".riffa-verified-move-")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}

private func verifiedMoveSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func filePermissions(_ url: URL) -> mode_t? {
    var status = stat()
    guard Darwin.lstat(url.path, &status) == 0 else { return nil }
    return status.st_mode & mode_t(0o7777)
}

private func setModificationTime(_ value: timespec, at url: URL) throws {
    let times = [value, value]
    let result = url.path.withCString { path in
        times.withUnsafeBufferPointer { values in
            Darwin.utimensat(AT_FDCWD, path, values.baseAddress, 0)
        }
    }
    if result != 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno)!)
    }
}

private func fileModificationTime(_ url: URL) -> timespec? {
    var status = stat()
    guard Darwin.lstat(url.path, &status) == 0 else { return nil }
    return status.st_mtimespec
}

private let verifiedMoveXattrName = "com.riffa.verified-move-test"

private func setUserXattr(_ value: Data, at url: URL) throws {
    let result = url.path.withCString { path in
        verifiedMoveXattrName.withCString { name in
            value.withUnsafeBytes { bytes in
                Darwin.setxattr(path, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
        }
    }
    if result != 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno)!)
    }
}

private func userXattr(at url: URL) throws -> Data {
    let count = url.path.withCString { path in
        verifiedMoveXattrName.withCString { name in
            Darwin.getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        }
    }
    guard count >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno)!)
    }
    var data = Data(count: count)
    let readCount = data.withUnsafeMutableBytes { bytes in
        url.path.withCString { path in
            verifiedMoveXattrName.withCString { name in
                Darwin.getxattr(path, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
        }
    }
    guard readCount == count else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return data
}
