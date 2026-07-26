import Foundation
import Testing
import zlib
@testable import RiffaCore

@Suite("Bounded archive comparison")
struct ArchiveComparisonTests {
    private let engine = ArchiveComparisonEngine()

    @Test("TAR and ZIP with the same tree and bytes compare equal by default")
    func crossFormatSameContent() throws {
        let contents = Data(repeating: 0x41, count: 256)
        let tar = archiveTestTAR([
            .init(name: "docs/", kind: .directory, permissions: 0o755, modificationTime: 1_000),
            .init(name: "docs/readme.txt", contents: contents, permissions: 0o600, modificationTime: 2_000),
        ])
        let zip = try archiveTestZIP([
            .init(name: "docs/readme.txt", contents: contents, deflated: true),
        ])

        let result = try engine.compare(left: tar, right: zip)

        #expect(result.leftFormat == .tar)
        #expect(result.rightFormat == .zip)
        #expect(result.rows.map(\.path) == ["docs", "docs/readme.txt"])
        #expect(result.rows.allSatisfy { $0.status == .same })
        #expect(result.statistics.sameCount == 2)
        #expect(result.statistics.hashedFileCount == 2)
        #expect(result.statistics.readAndHashedByteCount == 512)
        #expect(result.rows.last?.left?.contentSHA256 == result.rows.last?.right?.contentSHA256)
        #expect(result.hasDifferences == false)
    }

    @Test("Same-size file content differences publish only digests and summaries")
    func contentDifference() throws {
        let left = try archiveTestZIP([.init(name: "value.bin", contents: Data("left".utf8))])
        let right = try archiveTestZIP([.init(name: "value.bin", contents: Data("right".utf8))])

        let result = try engine.compare(left: left, right: right)
        let row = try #require(result.rows.first)

        #expect(row.status == .different)
        #expect(row.differenceFields == [.uncompressedByteCount, .content])
        #expect(row.left?.uncompressedByteCount == 4)
        #expect(row.right?.uncompressedByteCount == 5)
        #expect(row.left?.contentSHA256 == nil)
        #expect(row.right?.contentSHA256 == nil)
        #expect(result.statistics.hashedFileCount == 0)

        let equalLengthRight = try archiveTestZIP([
            .init(name: "value.bin", contents: Data("LEFT".utf8)),
        ])
        let hashed = try engine.compare(left: left, right: equalLengthRight)
        let hashedRow = try #require(hashed.rows.first)
        #expect(hashedRow.status == .different)
        #expect(hashedRow.differenceFields == [.content])
        #expect(hashedRow.left?.contentSHA256?.count == 64)
        #expect(hashedRow.right?.contentSHA256?.count == 64)
        #expect(hashedRow.left?.contentSHA256 != hashedRow.right?.contentSHA256)
        #expect(hashed.statistics.readAndHashedByteCount == 8)
    }

    @Test("Stable merge reports one-sided entries in normalized path order")
    func oneSidedStableMerge() throws {
        let left = archiveTestTAR([
            .init(name: "a.txt", contents: Data("a".utf8)),
            .init(name: "shared.txt", contents: Data("same".utf8)),
        ])
        let right = archiveTestTAR([
            .init(name: "b.txt", contents: Data("b".utf8)),
            .init(name: "shared.txt", contents: Data("same".utf8)),
        ])

        let first = try engine.compare(left: left, right: right)
        let second = try engine.compare(left: left, right: right)

        #expect(first == second)
        #expect(first.rows.map(\.path) == ["a.txt", "b.txt", "shared.txt"])
        #expect(first.rows.map(\.status) == [.leftOnly, .rightOnly, .same])
        #expect(first.statistics.leftOnlyCount == 1)
        #expect(first.statistics.rightOnlyCount == 1)
    }

    @Test("Directories are metadata-only and symbolic-link destinations are never followed")
    func directoriesAndSymbolicLinks() throws {
        let left = archiveTestTAR([
            .init(name: "folder/", kind: .directory),
            .init(
                name: "latest",
                kind: .symbolicLink,
                linkDestination: "../../outside-left"
            ),
        ])
        let right = archiveTestTAR([
            .init(name: "folder/", kind: .directory),
            .init(
                name: "latest",
                kind: .symbolicLink,
                linkDestination: "../../outside-right"
            ),
        ])

        let result = try engine.compare(left: left, right: right)
        let link = try #require(result.rows.first { $0.path == "latest" })

        #expect(result.rows.first { $0.path == "folder" }?.status == .same)
        #expect(link.status == .different)
        #expect(link.differenceFields == [.symbolicLinkDestination])
        #expect(link.left?.symbolicLinkDestination == "../../outside-left")
        #expect(link.right?.symbolicLinkDestination == "../../outside-right")
        #expect(link.left?.contentSHA256 == nil)
        #expect(result.statistics.hashedFileCount == 0)
        #expect(result.statistics.readAndHashedByteCount == 0)
    }

    @Test("Compression, modification dates, and permissions are opt-in semantic fields")
    func optionalMetadataRules() throws {
        let payload = Data(repeating: 0x42, count: 512)
        let stored = try archiveTestZIP([.init(name: "item", contents: payload)])
        let deflated = try archiveTestZIP([.init(name: "item", contents: payload, deflated: true)])
        #expect(try engine.compare(left: stored, right: deflated).rows.first?.status == .same)

        let compressionOptions = try ArchiveComparisonOptions(compareCompression: true)
        let compressionResult = try engine.compare(
            left: stored,
            right: deflated,
            options: compressionOptions
        )
        #expect(compressionResult.rows.first?.differenceFields == [.compression])

        let old = archiveTestTAR([
            .init(name: "item", contents: payload, permissions: 0o600, modificationTime: 100),
        ])
        let new = archiveTestTAR([
            .init(name: "item", contents: payload, permissions: 0o644, modificationTime: 200),
        ])
        #expect(try engine.compare(left: old, right: new).rows.first?.status == .same)

        let metadataOptions = try ArchiveComparisonOptions(
            compareModificationDate: true,
            comparePermissions: true
        )
        let metadataResult = try engine.compare(left: old, right: new, options: metadataOptions)
        #expect(metadataResult.rows.first?.differenceFields == [.modificationDate, .permissions])
    }

    @Test("Disabling content comparison performs no member reads or hashes")
    func contentComparisonCanBeDisabled() throws {
        let left = try archiveTestZIP([.init(name: "value", contents: Data("left".utf8))])
        let right = try archiveTestZIP([.init(name: "value", contents: Data("LEFT".utf8))])
        let options = try ArchiveComparisonOptions(compareContent: false)

        let result = try engine.compare(left: left, right: right, options: options)

        #expect(result.rows.first?.status == .same)
        #expect(result.statistics.hashedFileCount == 0)
        #expect(result.statistics.readAndHashedByteCount == 0)
    }

    @Test("CRC damage, encryption, and traversal are rejected without extracting")
    func unsafeArchivesAreRejected() throws {
        let payload = Data("actual".utf8)
        let damaged = try archiveTestZIP([
            .init(name: "bad.txt", contents: payload, declaredCRC32: 0x1234_5678),
        ])
        let valid = try archiveTestZIP([.init(name: "bad.txt", contents: payload)])
        do {
            _ = try engine.compare(left: damaged, right: valid)
            Issue.record("Expected CRC rejection")
        } catch let error as ArchiveResourceError {
            #expect(error.code == .checksumMismatch)
            #expect(error.path == "bad.txt")
        }

        let encrypted = try archiveTestZIP([
            .init(name: "secret", contents: Data("x".utf8), flags: 0x0001),
        ])
        do {
            _ = try engine.compare(left: encrypted, right: valid)
            Issue.record("Expected encrypted-entry rejection")
        } catch let error as ArchiveResourceError {
            #expect(error.code == .encryptedEntry)
        }

        let traversal = try archiveTestZIP([
            .init(name: "../escape", contents: Data("x".utf8)),
        ])
        do {
            _ = try engine.compare(left: traversal, right: valid)
            Issue.record("Expected traversal rejection")
        } catch let error as ArchiveResourceError {
            #expect(error.code == .invalidPath)
        }
    }

    @Test("Comparison entry and content budgets fail closed with path-free errors")
    func comparisonLimits() throws {
        let twoEntries = archiveTestTAR([
            .init(name: "a", contents: Data("a".utf8)),
            .init(name: "b", contents: Data("b".utf8)),
        ])
        let entryLimits = try ArchiveComparisonLimits(maxComparedEntryCount: 1)
        try expectComparisonError(.comparedEntryLimitExceeded) {
            _ = try engine.compare(
                left: twoEntries,
                right: twoEntries,
                options: ArchiveComparisonOptions(limits: entryLimits)
            )
        }

        let fourBytes = archiveTestTAR([.init(name: "file", contents: Data("1234".utf8))])
        let singleLimits = try ArchiveComparisonLimits(
            maxSingleFileReadByteCount: 3,
            maxTotalReadAndHashByteCount: 10
        )
        try expectComparisonError(.singleFileReadLimitExceeded) {
            _ = try engine.compare(
                left: fourBytes,
                right: fourBytes,
                options: ArchiveComparisonOptions(limits: singleLimits)
            )
        }

        let totalLimits = try ArchiveComparisonLimits(
            maxSingleFileReadByteCount: 4,
            maxTotalReadAndHashByteCount: 7
        )
        try expectComparisonError(.totalReadAndHashLimitExceeded) {
            _ = try engine.compare(
                left: fourBytes,
                right: fourBytes,
                options: ArchiveComparisonOptions(limits: totalLimits)
            )
        }

        let resourceLimits = ArchiveResourceLimits(maxArchiveByteCount: fourBytes.count - 1)
        let bounded = try ArchiveComparisonLimits(archiveLimits: resourceLimits)
        try expectComparisonError(.archiveResourceLimitExceeded) {
            _ = try engine.compare(
                left: fourBytes,
                right: fourBytes,
                options: ArchiveComparisonOptions(limits: bounded)
            )
        }
    }

    @Test("Limits and options reject invalid decoded values")
    func strictCodableLimits() throws {
        let encoded = try JSONEncoder().encode(ArchiveComparisonOptions.default)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var limits = try #require(object["limits"] as? [String: Any])
        limits["maxComparedEntryCount"] = 0
        object["limits"] = limits
        let invalid = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: ArchiveComparisonError.self) {
            _ = try JSONDecoder().decode(ArchiveComparisonOptions.self, from: invalid)
        }

        #expect(throws: ArchiveComparisonError.self) {
            _ = try ArchiveComparisonLimits(
                archiveLimits: ArchiveResourceLimits(maxExpansionRatio: .infinity)
            )
        }
        #expect(throws: ArchiveComparisonError.self) {
            _ = try ArchiveComparisonLimits(
                maxSingleFileReadByteCount: 10,
                maxTotalReadAndHashByteCount: 9
            )
        }
    }

    @Test("Results are Codable, deterministic, Hashable, and strictly Sendable")
    func resultValueSemantics() async throws {
        let archive = archiveTestTAR([.init(name: "资料/<item>.txt", contents: Data("值".utf8))])
        let result = try engine.compare(left: archive, right: archive)
        requireArchiveComparisonSendable(result)
        let copied = await Task.detached { @Sendable in result }.value
        #expect(copied == result)
        #expect(Set([result, copied]).count == 1)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(result)
        let second = try encoder.encode(result)
        #expect(first == second)
        #expect(try JSONDecoder().decode(ArchiveComparisonResult.self, from: first) == result)
        #expect(!String(decoding: first, as: UTF8.self).contains("值"))
    }
}

private func requireArchiveComparisonSendable<T: Sendable>(_ value: T) {}

private func expectComparisonError(
    _ code: ArchiveComparisonError.Code,
    operation: () throws -> Void
) throws {
    do {
        try operation()
        Issue.record("Expected archive comparison error \(code.rawValue)")
    } catch let error as ArchiveComparisonError {
        #expect(error.code == code)
        #expect(!error.detail.contains("/"))
        #expect(!error.detail.contains("a.txt"))
        #expect(!error.detail.contains("fourBytes"))
    }
}

private struct ArchiveTestTARMember {
    enum Kind {
        case file
        case directory
        case symbolicLink
    }

    let name: String
    let contents: Data
    let kind: Kind
    let linkDestination: String
    let permissions: UInt16
    let modificationTime: Int

    init(
        name: String,
        contents: Data = Data(),
        kind: Kind = .file,
        linkDestination: String = "",
        permissions: UInt16 = 0o644,
        modificationTime: Int = 0
    ) {
        self.name = name
        self.contents = contents
        self.kind = kind
        self.linkDestination = linkDestination
        self.permissions = permissions
        self.modificationTime = modificationTime
    }
}

private func archiveTestTAR(_ members: [ArchiveTestTARMember]) -> Data {
    var archive = Data()
    for member in members {
        var header = Data(repeating: 0, count: 512)
        archiveTestWrite(Data(member.name.utf8), to: &header, at: 0, capacity: 100)
        archiveTestWriteOctal(Int(member.permissions), to: &header, at: 100, length: 8)
        archiveTestWriteOctal(0, to: &header, at: 108, length: 8)
        archiveTestWriteOctal(0, to: &header, at: 116, length: 8)
        let payload = member.kind == .file ? member.contents : Data()
        archiveTestWriteOctal(payload.count, to: &header, at: 124, length: 12)
        archiveTestWriteOctal(member.modificationTime, to: &header, at: 136, length: 12)
        for index in 148..<156 { header[index] = 0x20 }
        switch member.kind {
        case .file: header[156] = 0x30
        case .directory: header[156] = 0x35
        case .symbolicLink:
            header[156] = 0x32
            archiveTestWrite(Data(member.linkDestination.utf8), to: &header, at: 157, capacity: 100)
        }
        archiveTestWrite(Data("ustar\0".utf8), to: &header, at: 257, capacity: 6)
        archiveTestWrite(Data("00".utf8), to: &header, at: 263, capacity: 2)
        archiveTestWriteOctal(header.reduce(0) { $0 + Int($1) }, to: &header, at: 148, length: 8)
        archive.append(header)
        archive.append(payload)
        let remainder = payload.count % 512
        if remainder != 0 {
            archive.append(Data(repeating: 0, count: 512 - remainder))
        }
    }
    archive.append(Data(repeating: 0, count: 1_024))
    return archive
}

private func archiveTestWrite(
    _ value: Data,
    to destination: inout Data,
    at offset: Int,
    capacity: Int
) {
    precondition(value.count <= capacity)
    destination.replaceSubrange(offset..<(offset + value.count), with: value)
}

private func archiveTestWriteOctal(
    _ value: Int,
    to destination: inout Data,
    at offset: Int,
    length: Int
) {
    let digits = String(value, radix: 8)
    precondition(digits.count <= length - 2)
    let field = String(repeating: "0", count: length - 2 - digits.count) + digits + "\0 "
    archiveTestWrite(Data(field.utf8), to: &destination, at: offset, capacity: length)
}

private struct ArchiveTestZIPMember {
    let name: String
    let contents: Data
    let deflated: Bool
    let flags: UInt16
    let declaredCRC32: UInt32?

    init(
        name: String,
        contents: Data,
        deflated: Bool = false,
        flags: UInt16 = 0x0800,
        declaredCRC32: UInt32? = nil
    ) {
        self.name = name
        self.contents = contents
        self.deflated = deflated
        self.flags = flags
        self.declaredCRC32 = declaredCRC32
    }
}

private func archiveTestZIP(_ members: [ArchiveTestZIPMember]) throws -> Data {
    struct CentralRecord {
        let member: ArchiveTestZIPMember
        let compressed: Data
        let crc32: UInt32
        let offset: UInt32
    }

    var archive = Data()
    var central: [CentralRecord] = []
    for member in members {
        let compressed = member.deflated ? try archiveTestDeflate(member.contents) : member.contents
        let crc = member.declaredCRC32 ?? archiveTestCRC32(member.contents)
        let name = Data(member.name.utf8)
        let offset = UInt32(archive.count)
        archive.appendArchiveLE(UInt32(0x0403_4b50))
        archive.appendArchiveLE(UInt16(20))
        archive.appendArchiveLE(member.flags)
        archive.appendArchiveLE(UInt16(member.deflated ? 8 : 0))
        archive.appendArchiveLE(UInt16(0))
        archive.appendArchiveLE(UInt16(0))
        archive.appendArchiveLE(crc)
        archive.appendArchiveLE(UInt32(compressed.count))
        archive.appendArchiveLE(UInt32(member.contents.count))
        archive.appendArchiveLE(UInt16(name.count))
        archive.appendArchiveLE(UInt16(0))
        archive.append(name)
        archive.append(compressed)
        central.append(.init(member: member, compressed: compressed, crc32: crc, offset: offset))
    }

    let centralOffset = archive.count
    for record in central {
        let name = Data(record.member.name.utf8)
        archive.appendArchiveLE(UInt32(0x0201_4b50))
        archive.appendArchiveLE(UInt16((3 << 8) | 20))
        archive.appendArchiveLE(UInt16(20))
        archive.appendArchiveLE(record.member.flags)
        archive.appendArchiveLE(UInt16(record.member.deflated ? 8 : 0))
        archive.appendArchiveLE(UInt16(0))
        archive.appendArchiveLE(UInt16(0))
        archive.appendArchiveLE(record.crc32)
        archive.appendArchiveLE(UInt32(record.compressed.count))
        archive.appendArchiveLE(UInt32(record.member.contents.count))
        archive.appendArchiveLE(UInt16(name.count))
        archive.appendArchiveLE(UInt16(0))
        archive.appendArchiveLE(UInt16(0))
        archive.appendArchiveLE(UInt16(0))
        archive.appendArchiveLE(UInt16(0))
        archive.appendArchiveLE(UInt32(0o100644 << 16))
        archive.appendArchiveLE(record.offset)
        archive.append(name)
    }
    let centralSize = archive.count - centralOffset

    archive.appendArchiveLE(UInt32(0x0605_4b50))
    archive.appendArchiveLE(UInt16(0))
    archive.appendArchiveLE(UInt16(0))
    archive.appendArchiveLE(UInt16(members.count))
    archive.appendArchiveLE(UInt16(members.count))
    archive.appendArchiveLE(UInt32(centralSize))
    archive.appendArchiveLE(UInt32(centralOffset))
    archive.appendArchiveLE(UInt16(0))
    return archive
}

private func archiveTestDeflate(_ input: Data) throws -> Data {
    var stream = z_stream()
    guard deflateInit2_(
        &stream,
        Z_DEFAULT_COMPRESSION,
        Z_DEFLATED,
        -MAX_WBITS,
        8,
        Z_DEFAULT_STRATEGY,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    ) == Z_OK else {
        throw CocoaError(.coderInvalidValue)
    }
    defer { deflateEnd(&stream) }

    let outputCapacity = max(Int(compressBound(uLong(input.count))) + 16, 32)
    var output = Data(count: outputCapacity)
    let status: Int32 = input.withUnsafeBytes { source in
        output.withUnsafeMutableBytes { destination in
            stream.next_in = UnsafeMutablePointer(
                mutating: source.baseAddress?.assumingMemoryBound(to: Bytef.self)
            )
            stream.avail_in = uInt(input.count)
            stream.next_out = destination.baseAddress?.assumingMemoryBound(to: Bytef.self)
            stream.avail_out = uInt(outputCapacity)
            return deflate(&stream, Z_FINISH)
        }
    }
    guard status == Z_STREAM_END else {
        throw CocoaError(.coderInvalidValue)
    }
    output.count = Int(stream.total_out)
    return output
}

private func archiveTestCRC32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
    var crc: UInt32 = 0xffff_ffff
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            let mask = UInt32(bitPattern: -Int32(crc & 1))
            crc = (crc >> 1) ^ (0xedb8_8320 & mask)
        }
    }
    return ~crc
}

private extension Data {
    mutating func appendArchiveLE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendArchiveLE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
