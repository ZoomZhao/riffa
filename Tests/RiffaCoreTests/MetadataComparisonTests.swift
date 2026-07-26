import Darwin
import Darwin.membership
import Foundation
import Testing
@testable import RiffaCore

@Suite("Typed metadata comparison")
struct MetadataComparisonTests {
    private let comparison = MetadataComparison()

    @Test("Metadata values have a stable Codable round trip")
    func codableValues() throws {
        let values: [MetadataValue] = [
            .string("标题"),
            .integer(42),
            .decimal(Decimal(string: "12.340")!),
            .boolean(true),
            .date(Date(timeIntervalSinceReferenceDate: 1234)),
            .data(MetadataDataSummary(data: Data("abc".utf8))),
            .null
        ]

        let data = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([MetadataValue].self, from: data)

        #expect(decoded == values)
    }

    @Test("Equal-looking values of different types remain different")
    func typeDifference() {
        let result = comparison.compare(
            left: [field("track", .integer(1))],
            right: [field("track", .decimal(1))]
        )

        #expect(result.rows.map(\.status) == [.different])
        #expect(result.statistics.differentCount == 1)
    }

    @Test("Duplicate keys are paired by stable occurrence index")
    func duplicateFields() {
        let left = [
            field("artist", .string("A")),
            field("artist", .string("B")),
            field("artist", .string("C"))
        ]
        let right = [
            field("artist", .string("A")),
            field("artist", .string("Changed"))
        ]

        let result = comparison.compare(left: left, right: right)

        #expect(result.rows.count == 3)
        #expect(result.rows.map(\.occurrenceIndex) == [0, 1, 2])
        #expect(result.rows.map(\.status) == [.same, .different, .leftOnly])
        #expect(result.rows[1].left?.value == .string("B"))
        #expect(result.rows[1].right?.value == .string("Changed"))
        #expect(result.rows[2].left?.value == .string("C"))
        #expect(result.statistics == MetadataComparisonStatistics(
            totalCount: 3,
            sameCount: 1,
            differentCount: 1,
            leftOnlyCount: 1,
            rightOnlyCount: 0
        ))
    }

    @Test("String, numeric, and date tolerances are inclusive")
    func comparisonTolerances() {
        let leftDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let rightDate = Date(timeIntervalSinceReferenceDate: 1_005)
        let left = [
            field("title", .string(" Hello \tWorld ")),
            field("count", .integer(100)),
            field("ratio", .decimal(Decimal(string: "1.25")!)),
            field("created", .date(leftDate))
        ]
        let right = [
            field("title", .string("helloworld")),
            field("count", .integer(103)),
            field("ratio", .decimal(Decimal(string: "1.30")!)),
            field("created", .date(rightDate))
        ]
        let options = MetadataComparisonOptions(
            ignoreStringCase: true,
            ignoreStringWhitespace: true,
            numericTolerance: Decimal(string: "0.05")!,
            dateTolerance: 5
        )

        let result = comparison.compare(left: left, right: right, options: options)

        #expect(result.rows.first(where: { $0.key == "title" })?.status == .same)
        #expect(result.rows.first(where: { $0.key == "ratio" })?.status == .same)
        #expect(result.rows.first(where: { $0.key == "created" })?.status == .same)
        // The shared tolerance is fractional here, so an integer delta of 3 remains different.
        #expect(result.rows.first(where: { $0.key == "count" })?.status == .different)

        let integerTolerance = comparison.compare(
            left: [field("count", .integer(100))],
            right: [field("count", .integer(103))],
            options: MetadataComparisonOptions(numericTolerance: 3)
        )
        #expect(integerTolerance.rows[0].status == .same)
    }

    @Test("Ignored keys remove every occurrence")
    func ignoredKeys() {
        let result = comparison.compare(
            left: [
                field("volatile", .string("a")),
                field("keep", .boolean(true)),
                field("volatile", .string("b"))
            ],
            right: [
                field("volatile", .string("different")),
                field("keep", .boolean(true))
            ],
            options: MetadataComparisonOptions(ignoredKeys: ["volatile"])
        )

        #expect(result.rows.map(\.key) == ["keep"])
        #expect(result.statistics.totalCount == 1)
        #expect(!result.hasDifferences)
    }

    @Test("Data is summarized with SHA-256 rather than retained")
    func dataDigest() {
        let summary = MetadataDataSummary(data: Data("abc".utf8))

        #expect(summary.byteCount == 3)
        #expect(summary.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let same = comparison.compare(
            left: [field("artwork", .data(summary))],
            right: [field("artwork", .data(MetadataDataSummary(data: Data("abc".utf8))))]
        )
        let different = comparison.compare(
            left: [field("artwork", .data(summary))],
            right: [field("artwork", .data(MetadataDataSummary(data: Data("abd".utf8))))]
        )

        #expect(same.rows[0].status == .same)
        #expect(different.rows[0].status == .different)
    }

    @Test("Unique keys sort deterministically and preserve side-only rows")
    func deterministicOrdering() {
        let leftA = [
            field("zeta", .integer(1), importance: .informational),
            field("alpha", .integer(2), importance: .important)
        ]
        let leftB = leftA.reversed()
        let rightA = [
            field("middle", .integer(3), importance: .critical),
            field("alpha", .integer(2), importance: .normal)
        ]
        let rightB = rightA.reversed()

        let first = comparison.compare(left: leftA, right: rightA)
        let second = comparison.compare(left: Array(leftB), right: Array(rightB))

        #expect(first == second)
        #expect(first.rows.map(\.key) == ["alpha", "middle", "zeta"])
        #expect(first.rows.map(\.status) == [.same, .rightOnly, .leftOnly])
        #expect(first.rows[0].importance == .important)
        #expect(first.rows[1].importance == .critical)
    }

    private func field(
        _ key: String,
        _ value: MetadataValue,
        importance: MetadataImportance = .normal
    ) -> MetadataField {
        MetadataField(
            key: key,
            displayName: key.capitalized,
            value: value,
            importance: importance
        )
    }
}

@Suite("Local filesystem metadata comparison")
struct LocalMetadataComparisonTests {
    @Test("Legacy snapshots and read limits decode with safe ACL defaults")
    func legacyCodableDefaults() throws {
        let legacySnapshot = LocalMetadataSnapshot(
            itemName: "legacy.bin",
            itemType: .regularFile,
            byteCount: 3,
            modificationTime: LocalMetadataTimestamp(
                secondsSince1970: 1_700_000_000,
                nanoseconds: 7
            ),
            posixPermissions: 0o644,
            ownerID: 501,
            groupID: 20,
            symbolicLinkDestination: nil,
            extendedAttributes: []
        )
        let snapshotData = try JSONEncoder().encode(legacySnapshot)
        let decodedSnapshot = try JSONDecoder().decode(
            LocalMetadataSnapshot.self,
            from: snapshotData
        )
        #expect(decodedSnapshot.creationTime == nil)
        #expect(decodedSnapshot.bsdFlags == nil)
        #expect(decodedSnapshot.accessControlList == nil)

        let legacyLimits = Data(
            """
            {
              "maximumExtendedAttributeNameBytes": 1024,
              "maximumExtendedAttributeCount": 12,
              "maximumExtendedAttributeValueBytes": 2048,
              "maximumTotalExtendedAttributeValueBytes": 4096,
              "maximumSymbolicLinkDestinationBytes": 512
            }
            """.utf8
        )
        let decodedLimits = try JSONDecoder().decode(
            LocalMetadataReadLimits.self,
            from: legacyLimits
        )
        #expect(decodedLimits.maximumAccessControlListBytes == 64 * 1_024)
        #expect(decodedLimits.maximumAccessControlEntryCount == 256)
    }

    @Test("A snapshot exposes required fields without reading file contents")
    func requiredFieldsAndStableSelfComparison() throws {
        let fixture = try TemporaryMetadataFixture()
        defer { fixture.remove() }
        let file = fixture.url.appendingPathComponent("sample.bin")
        try Data([0, 1, 2, 3, 4]).write(to: file)
        try setExtendedAttribute(
            name: "dev.riffa.beta",
            value: Data("second".utf8),
            at: file
        )
        try setExtendedAttribute(
            name: "dev.riffa.alpha",
            value: Data("first".utf8),
            at: file
        )

        let result = try LocalMetadataComparisonEngine().compare(
            leftURL: file,
            rightURL: file
        )

        #expect(!result.hasDifferences)
        #expect(result.left.itemName == "sample.bin")
        #expect(result.left.itemType == .regularFile)
        #expect(result.left.byteCount == 5)
        #expect(result.left.extendedAttributes.map(\.name).filter { $0.hasPrefix("dev.riffa.") } == [
            "dev.riffa.alpha", "dev.riffa.beta"
        ])
        let keys = Set(result.left.fields.map(\.key))
        #expect(keys.isSuperset(of: [
            "file.name", "file.type", "file.byteCount", "file.modified",
            "file.modifiedNanoseconds", "file.posixPermissions", "file.ownerID",
            "file.groupID", "file.created", "file.createdNanoseconds",
            "file.bsdFlags", "xattr.dev.riffa.alpha", "xattr.dev.riffa.beta"
        ]))
    }

    @Test("Extended ACLs are compared as bounded value-free ordered digests")
    func accessControlListDigest() throws {
        let fixture = try TemporaryMetadataFixture()
        defer { fixture.remove() }
        let left = fixture.url.appendingPathComponent("left-acl.bin")
        let right = fixture.url.appendingPathComponent("right-acl.bin")
        try Data([1]).write(to: left)
        try Data([1]).write(to: right)
        try setAccessControlList(permission: ACL_READ_DATA, at: left)
        try setAccessControlList(permission: ACL_WRITE_DATA, at: right)

        let result = try LocalMetadataComparisonEngine().compare(
            leftURL: left,
            rightURL: right,
            options: MetadataComparisonOptions(
                ignoredKeys: [
                    "file.name", "file.created", "file.createdNanoseconds",
                    "file.modified", "file.modifiedNanoseconds"
                ]
            )
        )
        let leftACL = try #require(result.left.accessControlList)
        let rightACL = try #require(result.right.accessControlList)

        #expect(leftACL.entryCount == 1)
        #expect(rightACL.entryCount == 1)
        #expect(leftACL.valueSummary.byteCount > 0)
        #expect(leftACL.valueSummary.sha256 != rightACL.valueSummary.sha256)
        #expect(
            result.comparison.rows.first { $0.key == "file.accessControlList" }?.status
                == .different
        )

        let encoded = try JSONEncoder().encode(result.left)
        let encodedText = try #require(String(data: encoded, encoding: .utf8))
        #expect(!encodedText.contains("allow"))
        #expect(!encodedText.contains("deny"))
        #expect(!encodedText.contains(fixture.url.path))
    }

    @Test("ACL external representations obey their independent byte budget")
    func accessControlListLimit() throws {
        let fixture = try TemporaryMetadataFixture()
        defer { fixture.remove() }
        let file = fixture.url.appendingPathComponent("bounded-acl.bin")
        try Data([1]).write(to: file)
        try setAccessControlList(permission: ACL_READ_DATA, at: file)
        let engine = LocalMetadataComparisonEngine(
            limits: LocalMetadataReadLimits(maximumAccessControlListBytes: 1)
        )

        do {
            _ = try engine.snapshot(url: file, side: .right)
            Issue.record("Expected the ACL byte budget to reject the snapshot")
        } catch let error as LocalMetadataComparisonError {
            guard case let .accessControlListTooLarge(side, _, actual, limit) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(side == .right)
            #expect(actual > 1)
            #expect(limit == 1)
        }
    }

    @Test("ACL entry enumeration enforces the configured count budget")
    func accessControlListEntryLimit() throws {
        let fixture = try TemporaryMetadataFixture()
        defer { fixture.remove() }
        let file = fixture.url.appendingPathComponent("acl-entry-budget.bin")
        try Data([1]).write(to: file)
        try setAccessControlList(
            permission: ACL_READ_DATA,
            includeGroupEntry: true,
            at: file
        )
        let engine = LocalMetadataComparisonEngine(
            limits: LocalMetadataReadLimits(maximumAccessControlEntryCount: 1)
        )

        do {
            _ = try engine.snapshot(url: file, side: .left)
            Issue.record("Expected the ACL entry budget to reject the snapshot")
        } catch let error as LocalMetadataComparisonError {
            guard case let .tooManyAccessControlEntries(side, _, actual, limit) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(side == .left)
            #expect(actual == 2)
            #expect(limit == 1)
        }
    }

    @Test("Extended attribute values are retained only as bounded digests")
    func extendedAttributeDigest() throws {
        let fixture = try TemporaryMetadataFixture()
        defer { fixture.remove() }
        let file = fixture.url.appendingPathComponent("secret.bin")
        try Data([7]).write(to: file)
        let rawValue = Data("private-xattr-payload".utf8)
        try setExtendedAttribute(name: "dev.riffa.secret", value: rawValue, at: file)

        let snapshot = try LocalMetadataComparisonEngine().snapshot(url: file, side: .left)
        let attribute = try #require(
            snapshot.extendedAttributes.first { $0.name == "dev.riffa.secret" }
        )

        #expect(attribute.valueSummary.byteCount == rawValue.count)
        #expect(attribute.valueSummary.sha256 == MetadataDataSummary(data: rawValue).sha256)
        let encoded = try JSONEncoder().encode(snapshot)
        let encodedText = try #require(String(data: encoded, encoding: .utf8))
        #expect(!encodedText.contains("private-xattr-payload"))
        #expect(!encodedText.contains(fixture.url.path))
    }

    @Test("Per-attribute and total xattr limits fail closed with side context")
    func extendedAttributeLimits() throws {
        let fixture = try TemporaryMetadataFixture()
        defer { fixture.remove() }
        let file = fixture.url.appendingPathComponent("bounded.bin")
        try Data([1]).write(to: file)
        try setExtendedAttribute(
            name: "dev.riffa.large",
            value: Data(repeating: 0x5a, count: 32),
            at: file
        )
        let engine = LocalMetadataComparisonEngine(
            limits: LocalMetadataReadLimits(
                maximumExtendedAttributeValueBytes: 16,
                maximumTotalExtendedAttributeValueBytes: 128
            )
        )

        do {
            _ = try engine.snapshot(url: file, side: .right)
            Issue.record("Expected the oversized xattr to be rejected")
        } catch let error as LocalMetadataComparisonError {
            guard case let .extendedAttributeValueTooLarge(side, _, name, actual, limit) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(side == .right)
            #expect(name == "dev.riffa.large")
            #expect(actual == 32)
            #expect(limit == 16)
        }
    }

    @Test("Symbolic links are explicit and are never followed into a directory")
    func symbolicLinkDoesNotTraverse() throws {
        let fixture = try TemporaryMetadataFixture()
        defer { fixture.remove() }
        let target = fixture.url.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data(repeating: 0x41, count: 4_096).write(
            to: target.appendingPathComponent("child.dat")
        )
        let link = fixture.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "target"
        )

        let snapshot = try LocalMetadataComparisonEngine().snapshot(url: link, side: .left)

        #expect(snapshot.itemType == .symbolicLink)
        #expect(snapshot.symbolicLinkDestination == "target")
        #expect(snapshot.byteCount == 6)
        #expect(!snapshot.fields.contains { $0.key.contains("child.dat") })
    }

    @Test("Directories are supported as directory entries without recursion")
    func directoryEntry() throws {
        let fixture = try TemporaryMetadataFixture()
        defer { fixture.remove() }
        let directory = fixture.url.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("ignored body".utf8).write(to: directory.appendingPathComponent("inside.txt"))

        let snapshot = try LocalMetadataComparisonEngine().snapshot(url: directory, side: .left)

        #expect(snapshot.itemType == .directory)
        #expect(snapshot.itemName == "folder")
        #expect(snapshot.symbolicLinkDestination == nil)
        #expect(snapshot.fields.count >= 8)
    }

    @Test("Missing resources produce a structured side-aware read error")
    func missingRightResource() throws {
        let fixture = try TemporaryMetadataFixture()
        defer { fixture.remove() }
        let existing = fixture.url.appendingPathComponent("left")
        try Data().write(to: existing)
        let missing = fixture.url.appendingPathComponent("missing")

        do {
            _ = try LocalMetadataComparisonEngine().compare(
                leftURL: existing,
                rightURL: missing
            )
            Issue.record("Expected the missing right resource to fail")
        } catch let error as LocalMetadataComparisonError {
            guard case let .metadataReadFailed(side, itemName, operation, code) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(side == .right)
            #expect(itemName == "missing")
            #expect(operation.contains("metadata"))
            #expect(code == ENOENT)
        }
    }

    @Test("Non-local URLs are rejected before any metadata read")
    func nonFileURL() {
        do {
            _ = try LocalMetadataComparisonEngine().snapshot(
                url: URL(string: "https://example.invalid/item")!,
                side: .left
            )
            Issue.record("Expected a non-file URL to be rejected")
        } catch let error as LocalMetadataComparisonError {
            #expect(error == .nonFileURL(side: .left))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Different names and byte counts surface through typed comparison rows")
    func typedDifferences() throws {
        let fixture = try TemporaryMetadataFixture()
        defer { fixture.remove() }
        let left = fixture.url.appendingPathComponent("left.bin")
        let right = fixture.url.appendingPathComponent("right.bin")
        try Data([1]).write(to: left)
        try Data([1, 2, 3]).write(to: right)

        let result = try LocalMetadataComparisonEngine().compare(
            leftURL: left,
            rightURL: right,
            options: MetadataComparisonOptions(dateTolerance: 60)
        )

        #expect(result.hasDifferences)
        #expect(result.comparison.rows.first { $0.key == "file.name" }?.status == .different)
        #expect(result.comparison.rows.first { $0.key == "file.byteCount" }?.status == .different)
    }

    private func setExtendedAttribute(name: String, value: Data, at url: URL) throws {
        let result: Int32 = value.withUnsafeBytes { bytes in
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return name.withCString { attributeName in
                    Darwin.setxattr(
                        path,
                        attributeName,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        XATTR_NOFOLLOW
                    )
                }
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func setAccessControlList(
        permission: acl_perm_t,
        includeGroupEntry: Bool = false,
        at url: URL
    ) throws {
        var acl: acl_t? = Darwin.acl_init(includeGroupEntry ? 2 : 1)
        guard acl != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOMEM)
        }
        defer {
            if let acl {
                Darwin.acl_free(UnsafeMutableRawPointer(acl))
            }
        }

        var entry: acl_entry_t?
        guard Darwin.acl_create_entry(&acl, &entry) == 0, let entry else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var userUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let membershipResult = mbr_uid_to_uuid(getuid(), &userUUID)
        guard membershipResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: membershipResult) ?? .EIO)
        }
        let qualifierResult = withUnsafePointer(to: &userUUID) { pointer in
            Darwin.acl_set_qualifier(entry, UnsafeRawPointer(pointer))
        }
        guard qualifierResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var permissionSet: acl_permset_t?
        guard Darwin.acl_get_permset(entry, &permissionSet) == 0,
              let permissionSet,
              Darwin.acl_clear_perms(permissionSet) == 0,
              Darwin.acl_add_perm(permissionSet, permission) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        if includeGroupEntry {
            var groupEntry: acl_entry_t?
            guard Darwin.acl_create_entry(&acl, &groupEntry) == 0,
                  let groupEntry,
                  Darwin.acl_set_tag_type(groupEntry, ACL_EXTENDED_ALLOW) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var groupUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            let groupMembershipResult = mbr_gid_to_uuid(getgid(), &groupUUID)
            guard groupMembershipResult == 0 else {
                throw POSIXError(
                    POSIXErrorCode(rawValue: groupMembershipResult) ?? .EIO
                )
            }
            let groupQualifierResult = withUnsafePointer(to: &groupUUID) { pointer in
                Darwin.acl_set_qualifier(groupEntry, UnsafeRawPointer(pointer))
            }
            guard groupQualifierResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var groupPermissionSet: acl_permset_t?
            guard Darwin.acl_get_permset(groupEntry, &groupPermissionSet) == 0,
                  let groupPermissionSet,
                  Darwin.acl_clear_perms(groupPermissionSet) == 0,
                  Darwin.acl_add_perm(groupPermissionSet, ACL_READ_ATTRIBUTES) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        guard let completedACL = acl else {
            throw POSIXError(.EIO)
        }
        let setResult = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.acl_set_link_np(path, ACL_TYPE_EXTENDED, completedACL)
        }
        guard setResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private struct TemporaryMetadataFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Riffa-Metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
