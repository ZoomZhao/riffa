import Foundation
import Testing
import zlib
@testable import RiffaCore

@Suite("Read-only archive resource provider")
struct ArchiveResourceProviderTests {
    @Test("USTAR exposes files, directories, symlinks, and PAX Unicode paths")
    func tarHappyPath() throws {
        let paxPath = "资料/一段远超传统名称字段并且仍然保持有效的归档路径/报告.txt"
        let archive = makeTAR([
            TARTestMember(name: "docs/", kind: .directory),
            TARTestMember(name: "docs/readme.txt", contents: Data("hello\n".utf8)),
            TARTestMember(name: "latest", kind: .symbolicLink, linkDestination: "docs/readme.txt"),
            TARTestMember(name: "short", contents: Data("PAX 内容".utf8), paxPath: paxPath),
        ])

        let provider = try ArchiveResourceProvider(data: archive)
        requireSendable(provider)

        #expect(provider.format == .tar)
        #expect(provider.list().map(\.path) == [
            "docs",
            "docs/readme.txt",
            "latest",
            "资料",
            "资料/一段远超传统名称字段并且仍然保持有效的归档路径",
            paxPath,
        ])
        #expect(try provider.read("docs//./readme.txt") == Data("hello\n".utf8))
        #expect(try provider.read(paxPath) == Data("PAX 内容".utf8))
        #expect(try provider.stat("latest").kind == .symbolicLink)
        #expect(try provider.stat("latest").symbolicLinkDestination == "docs/readme.txt")
        #expect(try provider.stat("docs").permissions == 0o755)

        expectArchiveError(.symbolicLinkReadDenied) {
            _ = try provider.read("latest")
        }
        expectArchiveError(.notRegularFile) {
            _ = try provider.read("docs")
        }
    }

    @Test("TAR traversal, Unicode aliases, and non-directory parents are rejected")
    func tarPathSafety() throws {
        expectArchiveError(.invalidPath) {
            _ = try ArchiveResourceProvider(
                data: makeTAR([TARTestMember(name: "../escape", contents: Data("x".utf8))]),
                format: .tar
            )
        }

        expectArchiveError(.duplicatePath) {
            _ = try ArchiveResourceProvider(
                data: makeTAR([
                    TARTestMember(name: "café", contents: Data()),
                    TARTestMember(name: "cafe\u{301}", contents: Data()),
                ]),
                format: .tar
            )
        }

        expectArchiveError(.invalidPath) {
            _ = try ArchiveResourceProvider(
                data: makeTAR([
                    TARTestMember(name: "node", contents: Data()),
                    TARTestMember(name: "node/child", contents: Data()),
                ]),
                format: .tar
            )
        }
    }

    @Test("TAR rejects truncation, checksum damage, and configured limits")
    func tarIntegrityAndLimits() throws {
        let valid = makeTAR([TARTestMember(name: "file", contents: Data(repeating: 7, count: 32))])
        expectArchiveError(.truncatedArchive) {
            _ = try ArchiveResourceProvider(data: Data(valid.prefix(700)), format: .tar)
        }

        var damaged = valid
        damaged[0] ^= 1
        expectArchiveError(.checksumMismatch) {
            _ = try ArchiveResourceProvider(data: damaged, format: .tar)
        }

        let sizeLimits = ArchiveResourceLimits(maxEntryUncompressedByteCount: 16)
        expectArchiveError(.entrySizeLimitExceeded) {
            _ = try ArchiveResourceProvider(data: valid, format: .tar, limits: sizeLimits)
        }

        let countLimits = ArchiveResourceLimits(maxEntryCount: 1)
        let nested = makeTAR([TARTestMember(name: "one/two/file", contents: Data())])
        expectArchiveError(.entryLimitExceeded) {
            _ = try ArchiveResourceProvider(data: nested, format: .tar, limits: countLimits)
        }

        let archiveLimits = ArchiveResourceLimits(maxArchiveByteCount: valid.count - 1)
        expectArchiveError(.archiveSizeLimitExceeded) {
            _ = try ArchiveResourceProvider(data: valid, format: .tar, limits: archiveLimits)
        }
    }

    @Test("BSD tar-style roots and opaque macOS PAX attributes remain compatible")
    func bsdTarCompatibility() throws {
        let opaqueAttribute = paxRecord(
            key: "SCHILY.xattr.com.apple.FinderInfo",
            rawValue: Data([0xff, 0x00, 0xfe, 0x80])
        )
        let archive = makeTAR([
            TARTestMember(name: "./", kind: .directory),
            TARTestMember(
                name: "./left.txt",
                contents: Data("left\n".utf8),
                rawPAXPayload: opaqueAttribute
            ),
        ])

        let provider = try ArchiveResourceProvider(data: archive, format: .tar)
        #expect(provider.list().map(\.path) == ["left.txt"])
        #expect(try provider.read("./left.txt") == Data("left\n".utf8))
    }

    @Test("ZIP reads stored and raw-DEFLATE members and decodes UTF-8 and CP437 names")
    func zipHappyPath() throws {
        let utf8Name = "目录/你好.txt"
        let cp437Name = Data([0x63, 0x61, 0x66, 0x82, 0x2e, 0x74, 0x78, 0x74]) // café.txt
        let archive = try makeZIP([
            ZIPTestMember(name: Data("plain.txt".utf8), contents: Data("stored".utf8)),
            ZIPTestMember(
                name: Data(utf8Name.utf8),
                contents: Data(repeating: 0x41, count: 200),
                method: .deflate,
                flags: 0x0800
            ),
            ZIPTestMember(name: cp437Name, contents: Data("CP437".utf8)),
        ])

        let provider = try ArchiveResourceProvider(data: archive)
        requireSendable(provider)

        #expect(provider.format == .zip)
        #expect(try provider.read("plain.txt") == Data("stored".utf8))
        #expect(try provider.read(utf8Name) == Data(repeating: 0x41, count: 200))
        #expect(try provider.read("café.txt") == Data("CP437".utf8))
        #expect(try provider.stat("目录").kind == .directory)
        #expect(provider.list().map(\.path) == ["café.txt", "plain.txt", "目录", utf8Name])
    }

    @Test("Info-ZIP Unicode path extra fields override legacy name bytes when CRC matches")
    func zipUnicodePathExtraField() throws {
        let legacyName = Data("fallback.txt".utf8)
        var unicodeField = Data([1])
        unicodeField.appendLE(testCRC32(legacyName))
        unicodeField.append(Data("日本語.txt".utf8))
        let archive = try makeZIP([
            ZIPTestMember(
                name: legacyName,
                contents: Data("unicode".utf8),
                centralExtra: zipExtraField(identifier: 0x7075, contents: unicodeField)
            ),
        ])

        let provider = try ArchiveResourceProvider(data: archive)
        #expect(try provider.read("日本語.txt") == Data("unicode".utf8))
        expectArchiveError(.notFound) {
            _ = try provider.stat("fallback.txt")
        }
    }

    @Test("ZIP CRC is verified on read without returning corrupt bytes")
    func zipCRCValidation() throws {
        let archive = try makeZIP([
            ZIPTestMember(
                name: Data("bad.txt".utf8),
                contents: Data("actual".utf8),
                declaredCRC32: 0x1234_5678
            ),
        ])
        let provider = try ArchiveResourceProvider(data: archive)

        expectArchiveError(.checksumMismatch) {
            _ = try provider.read("bad.txt")
        }
    }

    @Test("ZIP rejects traversal and duplicate normalized paths")
    func zipPathSafety() throws {
        let unsafeNames = ["../escape", "/absolute", "C:/drive", "safe/..\\escape"]
        for name in unsafeNames {
            let archive = try makeZIP([
                ZIPTestMember(name: Data(name.utf8), contents: Data()),
            ])
            expectArchiveError(.invalidPath) {
                _ = try ArchiveResourceProvider(data: archive, format: .zip)
            }
        }

        let duplicate = try makeZIP([
            ZIPTestMember(name: Data("a/./b".utf8), contents: Data()),
            ZIPTestMember(name: Data("a/b".utf8), contents: Data()),
        ])
        expectArchiveError(.duplicatePath) {
            _ = try ArchiveResourceProvider(data: duplicate, format: .zip)
        }
    }

    @Test("ZIP explicitly rejects encrypted, ZIP64, unsupported, and truncated members")
    func zipUnsupportedAndTruncated() throws {
        let encrypted = try makeZIP([
            ZIPTestMember(name: Data("secret".utf8), contents: Data(), flags: 1),
        ])
        expectArchiveError(.encryptedEntry) {
            _ = try ArchiveResourceProvider(data: encrypted, format: .zip)
        }

        let zip64 = try makeZIP([
            ZIPTestMember(
                name: Data("large".utf8),
                contents: Data(),
                centralExtra: zipExtraField(identifier: 0x0001, contents: Data(repeating: 0, count: 8))
            ),
        ])
        expectArchiveError(.unsupportedZIP64) {
            _ = try ArchiveResourceProvider(data: zip64, format: .zip)
        }

        let unsupported = try makeZIP([
            ZIPTestMember(name: Data("old".utf8), contents: Data(), rawMethod: 12),
        ])
        expectArchiveError(.unsupportedCompression) {
            _ = try ArchiveResourceProvider(data: unsupported, format: .zip)
        }

        let valid = try makeZIP([ZIPTestMember(name: Data("x".utf8), contents: Data("x".utf8))])
        expectArchiveError(.truncatedArchive) {
            _ = try ArchiveResourceProvider(data: Data(valid.dropLast(3)), format: .zip)
        }
    }

    @Test("ZIP declared sizes and expansion ratios enforce anti-bomb limits before decoding")
    func zipBombLimits() throws {
        let large = Data(repeating: 0, count: 8_192)
        let deflated = try makeZIP([
            ZIPTestMember(name: Data("bomb".utf8), contents: large, method: .deflate),
        ])

        let sizeLimits = ArchiveResourceLimits(maxEntryUncompressedByteCount: 4_096)
        expectArchiveError(.entrySizeLimitExceeded) {
            _ = try ArchiveResourceProvider(data: deflated, format: .zip, limits: sizeLimits)
        }

        let ratioLimits = ArchiveResourceLimits(
            maxEntryUncompressedByteCount: 16_384,
            maxTotalUncompressedByteCount: 16_384,
            maxExpansionRatio: 2
        )
        expectArchiveError(.expansionRatioLimitExceeded) {
            _ = try ArchiveResourceProvider(data: deflated, format: .zip, limits: ratioLimits)
        }

        let total = try makeZIP([
            ZIPTestMember(name: Data("one".utf8), contents: Data(repeating: 1, count: 12)),
            ZIPTestMember(name: Data("two".utf8), contents: Data(repeating: 2, count: 12)),
        ])
        let totalLimits = ArchiveResourceLimits(
            maxEntryUncompressedByteCount: 16,
            maxTotalUncompressedByteCount: 20
        )
        expectArchiveError(.totalSizeLimitExceeded) {
            _ = try ArchiveResourceProvider(data: total, format: .zip, limits: totalLimits)
        }
    }

    @Test("ZIP local-header disagreement and damaged DEFLATE streams fail closed")
    func zipStructuralIntegrity() throws {
        var nameMismatch = try makeZIP([
            ZIPTestMember(name: Data("same".utf8), contents: Data("data".utf8)),
        ])
        // The local name begins at byte 30; the central name remains unchanged.
        nameMismatch[30] = Character("x").asciiValue!
        expectArchiveError(.malformedArchive) {
            _ = try ArchiveResourceProvider(data: nameMismatch, format: .zip)
        }

        var damaged = try makeZIP([
            ZIPTestMember(
                name: Data("deflated".utf8),
                contents: Data(repeating: 0x55, count: 128),
                method: .deflate
            ),
        ])
        let payloadOffset = 30 + "deflated".utf8.count
        damaged[payloadOffset] ^= 0xff
        let provider = try ArchiveResourceProvider(data: damaged, format: .zip)
        expectArchiveError(.decompressionFailed) {
            _ = try provider.read("deflated")
        }
    }
}

private func requireSendable<T: Sendable>(_ value: T) {
    _ = value
}

private func expectArchiveError(
    _ expectedCode: ArchiveResourceError.Code,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected ArchiveResourceError.\(expectedCode.rawValue)")
    } catch let error as ArchiveResourceError {
        #expect(error.code == expectedCode)
    } catch {
        Issue.record("Expected ArchiveResourceError, got \(error)")
    }
}

private struct TARTestMember {
    enum Kind: UInt8 {
        case file = 0x30
        case directory = 0x35
        case symbolicLink = 0x32
    }

    let name: String
    let kind: Kind
    let contents: Data
    let linkDestination: String
    let paxPath: String?
    let rawPAXPayload: Data?

    init(
        name: String,
        kind: Kind = .file,
        contents: Data = Data(),
        linkDestination: String = "",
        paxPath: String? = nil,
        rawPAXPayload: Data? = nil
    ) {
        self.name = name
        self.kind = kind
        self.contents = contents
        self.linkDestination = linkDestination
        self.paxPath = paxPath
        self.rawPAXPayload = rawPAXPayload
    }
}

private func makeTAR(_ members: [TARTestMember]) -> Data {
    var result = Data()
    for (index, member) in members.enumerated() {
        if member.paxPath != nil || member.rawPAXPayload != nil {
            var payload = member.rawPAXPayload ?? Data()
            if let paxPath = member.paxPath {
                payload.append(paxRecord(key: "path", rawValue: Data(paxPath.utf8)))
            }
            appendTARMember(
                name: "PaxHeaders/\(index)",
                type: 0x78,
                contents: payload,
                linkDestination: "",
                to: &result
            )
        }
        appendTARMember(
            name: member.name,
            type: member.kind.rawValue,
            contents: member.contents,
            linkDestination: member.linkDestination,
            to: &result
        )
    }
    result.append(Data(repeating: 0, count: 1_024))
    return result
}

private func appendTARMember(
    name: String,
    type: UInt8,
    contents: Data,
    linkDestination: String,
    to result: inout Data
) {
    var header = Data(repeating: 0, count: 512)
    writeBytes(Data(name.utf8), into: &header, at: 0, maximum: 100)
    writeOctal(0o755, into: &header, at: 100, length: 8)
    writeOctal(501, into: &header, at: 108, length: 8)
    writeOctal(20, into: &header, at: 116, length: 8)
    writeOctal(contents.count, into: &header, at: 124, length: 12)
    writeOctal(1_700_000_000, into: &header, at: 136, length: 12)
    for index in 148..<156 { header[index] = 0x20 }
    header[156] = type
    writeBytes(Data(linkDestination.utf8), into: &header, at: 157, maximum: 100)
    writeBytes(Data("ustar\0".utf8), into: &header, at: 257, maximum: 6)
    writeBytes(Data("00".utf8), into: &header, at: 263, maximum: 2)
    let checksum = header.reduce(0) { $0 + Int($1) }
    let checksumText = String(format: "%06o", checksum)
    writeBytes(Data(checksumText.utf8), into: &header, at: 148, maximum: 6)
    header[154] = 0
    header[155] = 0x20

    result.append(header)
    result.append(contents)
    let padding = (512 - contents.count % 512) % 512
    result.append(Data(repeating: 0, count: padding))
}

private func writeOctal(_ value: Int, into data: inout Data, at offset: Int, length: Int) {
    let digits = String(value, radix: 8)
    let padding = max(0, length - 1 - digits.utf8.count)
    let field = String(repeating: "0", count: padding) + digits + "\0"
    writeBytes(Data(field.utf8), into: &data, at: offset, maximum: length)
}

private func writeBytes(_ bytes: Data, into data: inout Data, at offset: Int, maximum: Int) {
    for (relativeIndex, byte) in bytes.prefix(maximum).enumerated() {
        data[offset + relativeIndex] = byte
    }
}

private func paxRecord(key: String, rawValue: Data) -> Data {
    var body = Data(" \(key)=".utf8)
    body.append(rawValue)
    body.append(0x0a)
    var length = body.count + 1
    while true {
        var candidate = Data(String(length).utf8)
        candidate.append(body)
        if candidate.count == length {
            return candidate
        }
        length = candidate.count
    }
}

private enum ZIPTestMethod: UInt16 {
    case stored = 0
    case deflate = 8
}

private struct ZIPTestMember {
    let name: Data
    let contents: Data
    let method: ZIPTestMethod
    let flags: UInt16
    let declaredCRC32: UInt32?
    let centralExtra: Data
    let rawMethod: UInt16?

    init(
        name: Data,
        contents: Data,
        method: ZIPTestMethod = .stored,
        flags: UInt16 = 0,
        declaredCRC32: UInt32? = nil,
        centralExtra: Data = Data(),
        rawMethod: UInt16? = nil
    ) {
        self.name = name
        self.contents = contents
        self.method = method
        self.flags = flags
        self.declaredCRC32 = declaredCRC32
        self.centralExtra = centralExtra
        self.rawMethod = rawMethod
    }
}

private func makeZIP(_ members: [ZIPTestMember]) throws -> Data {
    struct CentralRecord {
        let member: ZIPTestMember
        let method: UInt16
        let compressed: Data
        let crc32: UInt32
        let localOffset: UInt32
    }

    var result = Data()
    var centralRecords: [CentralRecord] = []
    for member in members {
        let method = member.rawMethod ?? member.method.rawValue
        let compressed = member.method == .deflate ? try rawDeflate(member.contents) : member.contents
        let crc32 = member.declaredCRC32 ?? testCRC32(member.contents)
        let localOffset = UInt32(result.count)

        result.appendLE(UInt32(0x0403_4b50))
        result.appendLE(UInt16(20))
        result.appendLE(member.flags)
        result.appendLE(method)
        result.appendLE(UInt16(0))
        result.appendLE(UInt16(0))
        result.appendLE(crc32)
        result.appendLE(UInt32(compressed.count))
        result.appendLE(UInt32(member.contents.count))
        result.appendLE(UInt16(member.name.count))
        result.appendLE(UInt16(0))
        result.append(member.name)
        result.append(compressed)

        centralRecords.append(CentralRecord(
            member: member,
            method: method,
            compressed: compressed,
            crc32: crc32,
            localOffset: localOffset
        ))
    }

    let centralOffset = result.count
    for record in centralRecords {
        result.appendLE(UInt32(0x0201_4b50))
        result.appendLE(UInt16(3 << 8 | 20))
        result.appendLE(UInt16(20))
        result.appendLE(record.member.flags)
        result.appendLE(record.method)
        result.appendLE(UInt16(0))
        result.appendLE(UInt16(0))
        result.appendLE(record.crc32)
        result.appendLE(UInt32(record.compressed.count))
        result.appendLE(UInt32(record.member.contents.count))
        result.appendLE(UInt16(record.member.name.count))
        result.appendLE(UInt16(record.member.centralExtra.count))
        result.appendLE(UInt16(0))
        result.appendLE(UInt16(0))
        result.appendLE(UInt16(0))
        result.appendLE(UInt32(0o100644 << 16))
        result.appendLE(record.localOffset)
        result.append(record.member.name)
        result.append(record.member.centralExtra)
    }
    let centralSize = result.count - centralOffset

    result.appendLE(UInt32(0x0605_4b50))
    result.appendLE(UInt16(0))
    result.appendLE(UInt16(0))
    result.appendLE(UInt16(members.count))
    result.appendLE(UInt16(members.count))
    result.appendLE(UInt32(centralSize))
    result.appendLE(UInt32(centralOffset))
    result.appendLE(UInt16(0))
    return result
}

private func zipExtraField(identifier: UInt16, contents: Data) -> Data {
    var result = Data()
    result.appendLE(identifier)
    result.appendLE(UInt16(contents.count))
    result.append(contents)
    return result
}

private func rawDeflate(_ input: Data) throws -> Data {
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
    let status: Int32 = input.withUnsafeBytes { sourceBytes in
        output.withUnsafeMutableBytes { destinationBytes in
            stream.next_in = UnsafeMutablePointer(
                mutating: sourceBytes.baseAddress?.assumingMemoryBound(to: Bytef.self)
            )
            stream.avail_in = uInt(input.count)
            stream.next_out = destinationBytes.baseAddress?.assumingMemoryBound(to: Bytef.self)
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

private func testCRC32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
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
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
