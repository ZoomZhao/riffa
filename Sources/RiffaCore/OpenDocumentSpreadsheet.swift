import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Content-detected OpenDocument Spreadsheet support for the existing Office
/// comparison pipeline. File-name extensions are intentionally unavailable at
/// this layer: a package is ODS only when its ZIP declarations agree.
struct OpenDocumentSpreadsheetSnapshotBuilder {
    private static let mediaType = "application/vnd.oasis.opendocument.spreadsheet"
    private static let requiredPaths = [
        "mimetype",
        "META-INF/manifest.xml",
        "content.xml",
    ]

    private let limits: OpenXMLComparisonLimits
    private let provider: ArchiveResourceProvider
    private let files: [String: ArchiveResourceEntry]
    private let xmlBudget: ODSXMLBudget
    private let expansionBudget: ODSSpreadsheetExpansionBudget

    static func snapshotIfRecognized(
        data: Data,
        limits: OpenXMLComparisonLimits
    ) throws -> OpenXMLDocumentSnapshot? {
        try Task.checkCancellation()
        var builder = try Self(data: data, limits: limits)
        try Task.checkCancellation()
        return try builder.buildIfRecognized()
    }

    private init(data: Data, limits: OpenXMLComparisonLimits) throws {
        self.limits = limits
        let archiveLimits = ArchiveResourceLimits(
            maxArchiveByteCount: limits.maxArchiveByteCount,
            maxEntryCount: limits.maxPartCount,
            maxEntryUncompressedByteCount: limits.maxPartByteCount,
            maxTotalUncompressedByteCount: limits.maxTotalUncompressedByteCount,
            maxExpansionRatio: limits.maxExpansionRatio,
            maxPathByteCount: 4_096,
            maxPathDepth: 256
        )
        provider = try ArchiveResourceProvider(data: data, format: .zip, limits: archiveLimits)

        let nonDirectories = provider.list().filter { $0.kind != .directory }
        guard nonDirectories.count <= limits.maxPartCount else {
            throw OpenXMLComparisonError(code: .partCountLimitExceeded)
        }
        if let unsupported = nonDirectories.first(where: { $0.kind != .file }) {
            throw OpenXMLComparisonError(code: .unexpectedPartKind, part: unsupported.path)
        }
        files = Dictionary(uniqueKeysWithValues: nonDirectories.map { ($0.path, $0) })

        let xmlEntries = nonDirectories.filter { Self.isXMLPart($0.path) }
        guard xmlEntries.count <= limits.maxXMLPartCount else {
            throw OpenXMLComparisonError(code: .xmlPartCountLimitExceeded)
        }
        var totalXMLBytes = 0
        for entry in xmlEntries {
            guard entry.uncompressedByteCount <= limits.maxSingleXMLPartByteCount else {
                throw OpenXMLComparisonError(code: .xmlPartSizeLimitExceeded, part: entry.path)
            }
            let (next, overflow) = totalXMLBytes.addingReportingOverflow(
                entry.uncompressedByteCount
            )
            guard !overflow, next <= limits.maxTotalXMLByteCount else {
                throw OpenXMLComparisonError(code: .totalXMLSizeLimitExceeded)
            }
            totalXMLBytes = next
        }

        xmlBudget = ODSXMLBudget(limits: limits)
        expansionBudget = ODSSpreadsheetExpansionBudget(
            limits: limits,
            xmlBudget: xmlBudget,
            part: "content.xml"
        )
    }

    private mutating func buildIfRecognized() throws -> OpenXMLDocumentSnapshot? {
        try Task.checkCancellation()
        let markerCount = Self.requiredPaths.count { files[$0] != nil }
        let isOPCPackage = files["[Content_Types].xml"] != nil
            && files["_rels/.rels"] != nil

        guard markerCount > 0 else { return nil }
        guard markerCount == Self.requiredPaths.count else {
            // A valid OPC package may contain an unrelated top-level content.xml.
            if isOPCPackage { return nil }
            throw OpenXMLComparisonError(
                code: .invalidOpenDocumentPackage,
                detail: "Required ODS package declarations are incomplete"
            )
        }
        guard !isOPCPackage else {
            throw OpenXMLComparisonError(
                code: .invalidPackage,
                detail: "Ambiguous OPC and OpenDocument declarations"
            )
        }

        let expectedMimetype = Data(Self.mediaType.utf8)
        guard let mimetypeEntry = files["mimetype"],
              mimetypeEntry.compression == .none,
              mimetypeEntry.compressedByteCount == expectedMimetype.count,
              mimetypeEntry.uncompressedByteCount == expectedMimetype.count else {
            throw OpenXMLComparisonError(
                code: .invalidOpenDocumentPackage,
                part: "mimetype",
                detail: "The ODS mimetype member must be stored with its exact byte length"
            )
        }
        try Task.checkCancellation()
        let mimetype = try provider.read("mimetype")
        try Task.checkCancellation()
        guard mimetype == expectedMimetype else {
            throw OpenXMLComparisonError(
                code: .invalidOpenDocumentPackage,
                part: "mimetype",
                detail: "The package does not declare the ODS media type"
            )
        }

        try validateManifest()
        let sections = try contentSections()
        let properties = try metadataProperties()
        let parts = try partSummaries()
        try expansionBudget.consumeOutput([OpenXMLDocumentType.openDocumentSpreadsheet.rawValue])
        return OpenXMLDocumentSnapshot(
            documentType: .openDocumentSpreadsheet,
            coreProperties: properties,
            sections: sections,
            parts: parts
        )
    }

    private mutating func validateManifest() throws {
        let path = "META-INF/manifest.xml"
        let delegate = ODSManifestDelegate(budget: xmlBudget, part: path)
        try parseXML(try xmlData(path), part: path, delegate: delegate)
        try delegate.validatePackage(
            expectedMediaType: Self.mediaType,
            requiredContentPath: "content.xml"
        )
    }

    private mutating func contentSections() throws -> [OpenXMLLogicalSection] {
        let path = "content.xml"
        let delegate = ODSContentDelegate(
            budget: xmlBudget,
            expansionBudget: expansionBudget,
            part: path,
            maxSheetCount: limits.maxWorksheetOrSlideCount
        )
        try parseXML(try xmlData(path), part: path, delegate: delegate)
        return try delegate.result()
    }

    private mutating func metadataProperties() throws -> OpenXMLCoreProperties {
        let path = "meta.xml"
        guard files[path] != nil else { return OpenXMLCoreProperties() }
        let delegate = ODSMetadataDelegate(
            budget: xmlBudget,
            expansionBudget: expansionBudget,
            part: path
        )
        try parseXML(try xmlData(path), part: path, delegate: delegate)
        return delegate.result()
    }

    private func partSummaries() throws -> [OpenXMLPartSummary] {
        let entries = files.values.sorted { $0.path < $1.path }
        var summaries: [OpenXMLPartSummary] = []
        summaries.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            try ODSCancellation.check(iteration: index)
            let data = try provider.read(entry.path)
            try Task.checkCancellation()
            let digest = try ODSDigest.data(data)
            try expansionBudget.consumeOutput([entry.path, digest])
            summaries.append(OpenXMLPartSummary(
                partName: entry.path,
                uncompressedByteCount: data.count,
                sha256: digest
            ))
        }
        return summaries
    }

    private static func isXMLPart(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".xml")
    }

    private mutating func xmlData(_ path: String) throws -> Data {
        try Task.checkCancellation()
        guard let entry = files[path] else {
            throw OpenXMLComparisonError(code: .missingRequiredPart, part: path)
        }
        guard Self.isXMLPart(path) else {
            throw OpenXMLComparisonError(code: .malformedXML, part: path)
        }
        guard entry.uncompressedByteCount <= limits.maxSingleXMLPartByteCount else {
            throw OpenXMLComparisonError(code: .xmlPartSizeLimitExceeded, part: path)
        }
        let data = try provider.read(path)
        try Task.checkCancellation()
        guard !ODSXMLSecurity.containsForbiddenDeclaration(data) else {
            throw OpenXMLComparisonError(code: .forbiddenDTD, part: path)
        }
        return data
    }

    private func parseXML(
        _ data: Data,
        part: String,
        delegate: ODSBoundedDelegate
    ) throws {
        try Task.checkCancellation()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        #if canImport(FoundationXML)
        parser.externalEntityResolvingPolicy = .never
        #endif
        parser.delegate = delegate
        let parsed = parser.parse()
        if let failure = delegate.failure { throw failure }
        try Task.checkCancellation()
        guard parsed else {
            throw OpenXMLComparisonError(code: .malformedXML, part: part)
        }
        try delegate.validateComplete()
    }
}

private enum ODSNamespaces {
    static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    static let table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    static let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    static let manifest = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"
    static let metadata = "urn:oasis:names:tc:opendocument:xmlns:meta:1.0"
    static let dc = "http://purl.org/dc/elements/1.1/"
}

enum ODSCancellation {
    private static let interval = 256
    @TaskLocal static var checkpointHook: (@Sendable (Int) -> Void)?

    static func check(iteration: Int) throws {
        if iteration.isMultiple(of: interval) {
            checkpointHook?(iteration)
            try Task.checkCancellation()
        }
    }
}

private struct ODSExpandedName: Hashable {
    let namespaceURI: String?
    let localName: String
}

private struct ODSAttribute {
    let name: ODSExpandedName
    let value: String
}

/// XML default namespaces never apply to unqualified attributes. Attribute
/// names are therefore resolved from the exact in-scope prefix mapping before
/// any ODF consumer sees them.
private struct ODSAttributes {
    let entries: [ODSAttribute]

    init(
        raw: [String: String],
        namespaceMappings: [String: String],
        part: String
    ) throws {
        var parsed: [ODSAttribute] = []
        parsed.reserveCapacity(raw.count)
        var names: Set<ODSExpandedName> = []
        names.reserveCapacity(raw.count)

        for (qualifiedName, value) in raw {
            let name: ODSExpandedName
            if let separator = qualifiedName.firstIndex(of: ":") {
                let prefix = String(qualifiedName[..<separator])
                let localStart = qualifiedName.index(after: separator)
                let localName = String(qualifiedName[localStart...])
                guard !prefix.isEmpty,
                      !localName.isEmpty,
                      !localName.contains(":"),
                      let namespaceURI = namespaceMappings[prefix] else {
                    throw OpenXMLComparisonError(code: .malformedXML, part: part)
                }
                name = ODSExpandedName(namespaceURI: namespaceURI, localName: localName)
            } else {
                guard !qualifiedName.isEmpty else {
                    throw OpenXMLComparisonError(code: .malformedXML, part: part)
                }
                name = ODSExpandedName(namespaceURI: nil, localName: qualifiedName)
            }

            guard names.insert(name).inserted else {
                throw OpenXMLComparisonError(
                    code: .invalidOpenDocumentPackage,
                    part: part,
                    detail: "Duplicate expanded attribute name"
                )
            }
            parsed.append(ODSAttribute(name: name, value: value))
        }
        entries = parsed
    }

    func value(namespaceURI: String, localName: String) -> String? {
        entries.first {
            $0.name.namespaceURI == namespaceURI && $0.name.localName == localName
        }?.value
    }

    func containsSecuritySignal(namespaceURI: String) -> Bool {
        entries.contains { attribute in
            guard attribute.name.namespaceURI == namespaceURI else { return false }
            let localName = attribute.name.localName.lowercased()
            return (localName == "encrypted" || localName.contains("encryption"))
                && attribute.value.lowercased() != "false"
        }
    }
}

private final class ODSXMLBudget {
    private let limits: OpenXMLComparisonLimits
    private var nodeCount = 0
    private var parsedTextCharacterCount = 0
    private var logicalItemCount = 0

    init(limits: OpenXMLComparisonLimits) {
        self.limits = limits
    }

    func consumeNode(part: String) throws {
        nodeCount = try adding(
            nodeCount,
            1,
            limit: limits.maxXMLNodeCount,
            code: .xmlNodeLimitExceeded,
            part: part
        )
        try ODSCancellation.check(iteration: nodeCount)
    }

    func consumeParsedText(_ text: String, part: String) throws {
        try Task.checkCancellation()
        parsedTextCharacterCount = try adding(
            parsedTextCharacterCount,
            text.count,
            limit: limits.maxTextCharacterCount,
            code: .textCharacterLimitExceeded,
            part: part
        )
    }

    func consumeLogicalItems(_ count: Int = 1, part: String) throws {
        try Task.checkCancellation()
        logicalItemCount = try adding(
            logicalItemCount,
            count,
            limit: limits.maxLogicalItemCount,
            code: .logicalItemLimitExceeded,
            part: part
        )
    }

    private func adding(
        _ value: Int,
        _ increment: Int,
        limit: Int,
        code: OpenXMLComparisonError.Code,
        part: String
    ) throws -> Int {
        let (next, overflow) = value.addingReportingOverflow(increment)
        guard increment >= 0, !overflow, next <= limit else {
            throw OpenXMLComparisonError(code: code, part: part)
        }
        return next
    }
}

private final class ODSSpreadsheetExpansionBudget {
    private let limits: OpenXMLComparisonLimits
    private let xmlBudget: ODSXMLBudget
    private let part: String
    private var sheetCount = 0
    private var rowCount = 0
    private var cellCount = 0
    private var outputCharacterCount = 0
    private var expandedByteCount = 0

    init(limits: OpenXMLComparisonLimits, xmlBudget: ODSXMLBudget, part: String) {
        self.limits = limits
        self.xmlBudget = xmlBudget
        self.part = part
    }

    func validatedRepeat(_ rawValue: String?, attribute: String) throws -> Int {
        try Task.checkCancellation()
        guard let rawValue else { return 1 }
        guard !rawValue.isEmpty,
              rawValue.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let value = Int(rawValue),
              value > 0 else {
            throw OpenXMLComparisonError(
                code: .invalidOpenDocumentPackage,
                part: part,
                detail: "Invalid positive integer for \(attribute)"
            )
        }
        guard value <= limits.maxSpreadsheetRepeatCount else {
            throw OpenXMLComparisonError(
                code: .spreadsheetRepeatLimitExceeded,
                part: part,
                detail: attribute
            )
        }
        return value
    }

    func validatedRowSpan(_ rawValue: String?, attribute: String) throws -> Int? {
        try validatedSpan(
            rawValue,
            attribute: attribute,
            limit: limits.maxSpreadsheetRowCount,
            code: .spreadsheetRowLimitExceeded
        )
    }

    func validatedColumnSpan(_ rawValue: String?, attribute: String) throws -> Int? {
        try validatedSpan(
            rawValue,
            attribute: attribute,
            limit: limits.maxSpreadsheetColumnCount,
            code: .spreadsheetColumnLimitExceeded
        )
    }

    private func validatedSpan(
        _ rawValue: String?,
        attribute: String,
        limit: Int,
        code: OpenXMLComparisonError.Code
    ) throws -> Int? {
        guard let rawValue else { return nil }
        let value = try validatedRepeat(rawValue, attribute: attribute)
        guard value <= limit else {
            throw OpenXMLComparisonError(
                code: code,
                part: part,
                detail: attribute
            )
        }
        return value > 1 ? value : nil
    }

    func validateSpanEndpoints(
        completedRowCount: Int,
        rowRepeat: Int,
        maximumAnchorColumn: Int,
        rowSpan: Int?,
        columnSpan: Int?
    ) throws {
        let maximumAnchorRow = try checkedAdd(
            completedRowCount,
            rowRepeat,
            code: .spreadsheetRowLimitExceeded
        )
        let rowEndpoint = try checkedAdd(
            maximumAnchorRow,
            (rowSpan ?? 1) - 1,
            code: .spreadsheetRowLimitExceeded
        )
        guard rowEndpoint <= limits.maxSpreadsheetRowCount else {
            throw OpenXMLComparisonError(code: .spreadsheetRowLimitExceeded, part: part)
        }

        let columnEndpoint = try checkedAdd(
            maximumAnchorColumn,
            (columnSpan ?? 1) - 1,
            code: .spreadsheetColumnLimitExceeded
        )
        guard columnEndpoint <= limits.maxSpreadsheetColumnCount else {
            throw OpenXMLComparisonError(code: .spreadsheetColumnLimitExceeded, part: part)
        }
    }

    func consumeSheet() throws {
        try Task.checkCancellation()
        sheetCount = try checkedAdd(sheetCount, 1, code: .worksheetOrSlideLimitExceeded)
        guard sheetCount <= limits.maxWorksheetOrSlideCount else {
            throw OpenXMLComparisonError(code: .worksheetOrSlideLimitExceeded, part: part)
        }
        try xmlBudget.consumeLogicalItems(part: part)
        try consumeExpandedBytes(64)
    }

    func consumeRows(_ count: Int) throws {
        try Task.checkCancellation()
        let next = try checkedAdd(rowCount, count, code: .spreadsheetRowLimitExceeded)
        guard next <= limits.maxSpreadsheetRowCount else {
            throw OpenXMLComparisonError(code: .spreadsheetRowLimitExceeded, part: part)
        }
        rowCount = next
        try xmlBudget.consumeLogicalItems(count, part: part)
        try consumeExpandedBytes(try checkedMultiply(count, 64, code: .spreadsheetExpansionLimitExceeded))
    }

    func validateColumnTotal(_ count: Int) throws {
        guard count <= limits.maxSpreadsheetColumnCount else {
            throw OpenXMLComparisonError(code: .spreadsheetColumnLimitExceeded, part: part)
        }
    }

    func consumeCells(_ columnRepeat: Int, rowRepeat: Int, isCovered: Bool) throws -> Int {
        try Task.checkCancellation()
        let expandedCount = try checkedMultiply(
            columnRepeat,
            rowRepeat,
            code: .spreadsheetCellLimitExceeded
        )
        let next = try checkedAdd(cellCount, expandedCount, code: .spreadsheetCellLimitExceeded)
        guard next <= limits.maxSpreadsheetCellCount else {
            throw OpenXMLComparisonError(code: .spreadsheetCellLimitExceeded, part: part)
        }
        cellCount = next
        try xmlBudget.consumeLogicalItems(expandedCount, part: part)
        try consumeExpandedBytes(
            try checkedMultiply(expandedCount, isCovered ? 24 : 96, code: .spreadsheetExpansionLimitExceeded)
        )
        return expandedCount
    }

    func measureOutput(_ strings: [String]) throws -> (characters: Int, utf8Bytes: Int) {
        try Task.checkCancellation()
        var characters = 0
        var bytes = 0
        for string in strings {
            characters = try checkedAdd(
                characters,
                string.count,
                code: .spreadsheetExpansionLimitExceeded
            )
            bytes = try checkedAdd(
                bytes,
                string.utf8.count,
                code: .spreadsheetExpansionLimitExceeded
            )
        }
        return (characters, bytes)
    }

    func validateOutput(
        characters: Int,
        utf8Bytes: Int,
        instanceCount: Int = 1
    ) throws {
        let expandedCharacters = try checkedMultiply(
            characters,
            instanceCount,
            code: .textCharacterLimitExceeded
        )
        let nextCharacters = try checkedAdd(
            outputCharacterCount,
            expandedCharacters,
            code: .textCharacterLimitExceeded
        )
        guard nextCharacters <= limits.maxTextCharacterCount else {
            throw OpenXMLComparisonError(code: .textCharacterLimitExceeded, part: part)
        }
        let expandedBytes = try checkedMultiply(
            utf8Bytes,
            instanceCount,
            code: .spreadsheetExpansionLimitExceeded
        )
        let nextBytes = try checkedAdd(
            expandedByteCount,
            expandedBytes,
            code: .spreadsheetExpansionLimitExceeded
        )
        guard nextBytes <= limits.maxSpreadsheetExpandedByteCount else {
            throw OpenXMLComparisonError(code: .spreadsheetExpansionLimitExceeded, part: part)
        }
    }

    func consumeOutput(_ strings: [String], instanceCount: Int = 1) throws {
        let measured = try measureOutput(strings)
        try consumeOutput(
            characters: measured.characters,
            utf8Bytes: measured.utf8Bytes,
            instanceCount: instanceCount
        )
    }

    func consumeOutput(
        characters: Int,
        utf8Bytes: Int,
        instanceCount: Int = 1
    ) throws {
        try validateOutput(
            characters: characters,
            utf8Bytes: utf8Bytes,
            instanceCount: instanceCount
        )
        outputCharacterCount = try checkedAdd(
            outputCharacterCount,
            try checkedMultiply(
                characters,
                instanceCount,
                code: .textCharacterLimitExceeded
            ),
            code: .textCharacterLimitExceeded
        )
        expandedByteCount = try checkedAdd(
            expandedByteCount,
            try checkedMultiply(
                utf8Bytes,
                instanceCount,
                code: .spreadsheetExpansionLimitExceeded
            ),
            code: .spreadsheetExpansionLimitExceeded
        )
    }

    private func consumeExpandedBytes(_ count: Int) throws {
        let next = try checkedAdd(
            expandedByteCount,
            count,
            code: .spreadsheetExpansionLimitExceeded
        )
        guard next <= limits.maxSpreadsheetExpandedByteCount else {
            throw OpenXMLComparisonError(code: .spreadsheetExpansionLimitExceeded, part: part)
        }
        expandedByteCount = next
    }

    private func checkedAdd(
        _ left: Int,
        _ right: Int,
        code: OpenXMLComparisonError.Code
    ) throws -> Int {
        let (result, overflow) = left.addingReportingOverflow(right)
        guard left >= 0, right >= 0, !overflow else {
            throw OpenXMLComparisonError(code: code, part: part)
        }
        return result
    }

    private func checkedMultiply(
        _ left: Int,
        _ right: Int,
        code: OpenXMLComparisonError.Code
    ) throws -> Int {
        let (result, overflow) = left.multipliedReportingOverflow(by: right)
        guard left >= 0, right >= 0, !overflow else {
            throw OpenXMLComparisonError(code: code, part: part)
        }
        return result
    }
}

private enum ODSXMLSecurity {
    static func containsForbiddenDeclaration(_ data: Data) -> Bool {
        let normalized = data.compactMap { byte -> UInt8? in
            guard byte != 0 else { return nil }
            if byte >= 0x61, byte <= 0x7a { return byte - 0x20 }
            return byte
        }
        return normalized.odsContainsSubsequence(Array("<!DOCTYPE".utf8))
            || normalized.odsContainsSubsequence(Array("<!ENTITY".utf8))
    }
}

private extension Array where Element == UInt8 {
    func odsContainsSubsequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        for start in 0...(count - needle.count) {
            if self[start..<(start + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }
}

private class ODSBoundedDelegate: NSObject, XMLParserDelegate {
    let budget: ODSXMLBudget
    let part: String
    let expectedRoot: String
    let expectedRootNamespace: String
    private(set) var failure: (any Error)?
    private(set) var elementStack: [ODSExpandedName] = []
    private var namespaceScopes: [[String: String]] = []
    private var pendingNamespaceMappings: [String: String] = [:]
    private var rootSeen = false

    init(
        budget: ODSXMLBudget,
        part: String,
        expectedRoot: String,
        expectedRootNamespace: String
    ) {
        self.budget = budget
        self.part = part
        self.expectedRoot = expectedRoot
        self.expectedRootNamespace = expectedRootNamespace
    }

    var currentElement: ODSExpandedName? { elementStack.last }

    var parentElement: ODSExpandedName? {
        guard elementStack.count >= 2 else { return nil }
        return elementStack[elementStack.count - 2]
    }

    func parser(
        _ parser: XMLParser,
        didStartMappingPrefix prefix: String,
        toURI namespaceURI: String
    ) {
        pendingNamespaceMappings[prefix] = namespaceURI
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { parser.abortParsing(); return }
        do {
            try budget.consumeNode(part: part)
            var namespaceMappings = namespaceScopes.last
                ?? ["xml": "http://www.w3.org/XML/1998/namespace"]
            for (prefix, namespaceURI) in pendingNamespaceMappings {
                namespaceMappings[prefix] = namespaceURI
            }
            pendingNamespaceMappings.removeAll(keepingCapacity: true)
            let attributes = try ODSAttributes(
                raw: attributeDict,
                namespaceMappings: namespaceMappings,
                part: part
            )
            namespaceScopes.append(namespaceMappings)
            elementStack.append(ODSExpandedName(
                namespaceURI: namespaceURI,
                localName: elementName
            ))
            if elementStack.count == 1 {
                guard !rootSeen,
                      elementName == expectedRoot,
                      namespaceURI == expectedRootNamespace else {
                    throw OpenXMLComparisonError(
                        code: .malformedXML,
                        part: part,
                        detail: "Unexpected XML root element or namespace"
                    )
                }
                rootSeen = true
            }
            try startElement(
                elementName,
                namespaceURI: namespaceURI,
                qualifiedName: qName,
                attributes: attributes
            )
        } catch {
            fail(error, parser: parser)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard failure == nil else { return }
        do {
            guard currentElement == ODSExpandedName(
                namespaceURI: namespaceURI,
                localName: elementName
            ) else {
                throw OpenXMLComparisonError(code: .malformedXML, part: part)
            }
            try endElement(elementName, namespaceURI: namespaceURI, qualifiedName: qName)
            elementStack.removeLast()
            namespaceScopes.removeLast()
        } catch {
            fail(error, parser: parser)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard failure == nil else { return }
        do {
            try budget.consumeParsedText(string, part: part)
            try characters(string)
        } catch {
            fail(error, parser: parser)
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else {
            fail(OpenXMLComparisonError(code: .malformedXML, part: part), parser: parser)
            return
        }
        self.parser(parser, foundCharacters: text)
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        fail(OpenXMLComparisonError(code: .forbiddenDTD, part: part), parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        fail(OpenXMLComparisonError(code: .forbiddenDTD, part: part), parser: parser)
        return nil
    }

    func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: ODSAttributes
    ) throws {}

    func endElement(_ name: String, namespaceURI: String?, qualifiedName: String?) throws {}
    func characters(_ string: String) throws {}

    func validateComplete() throws {
        if let failure { throw failure }
        guard rootSeen,
              elementStack.isEmpty,
              namespaceScopes.isEmpty,
              pendingNamespaceMappings.isEmpty else {
            throw OpenXMLComparisonError(code: .malformedXML, part: part)
        }
    }

    private func fail(_ error: any Error, parser: XMLParser) {
        guard failure == nil else { return }
        failure = error
        parser.abortParsing()
    }
}

private final class ODSManifestDelegate: ODSBoundedDelegate {
    private var mediaTypes: [String: String] = [:]
    private var encrypted = false

    init(budget: ODSXMLBudget, part: String) {
        super.init(
            budget: budget,
            part: part,
            expectedRoot: "manifest",
            expectedRootNamespace: ODSNamespaces.manifest
        )
    }

    override func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: ODSAttributes
    ) throws {
        if (namespaceURI == ODSNamespaces.manifest
            && [
                "encryption-data",
                "algorithm",
                "key-derivation",
                "start-key-generation",
                "encrypted-key",
            ].contains(name))
            || attributes.containsSecuritySignal(namespaceURI: ODSNamespaces.manifest) {
            encrypted = true
            throw OpenXMLComparisonError(code: .encryptedDocument, part: part)
        }
        guard namespaceURI == ODSNamespaces.manifest else { return }
        guard name == "file-entry" else { return }
        guard parentElement == ODSExpandedName(
                  namespaceURI: ODSNamespaces.manifest,
                  localName: "manifest"
              ),
              let path = attributes.value(
                  namespaceURI: ODSNamespaces.manifest,
                  localName: "full-path"
              ),
              let mediaType = attributes.value(
                  namespaceURI: ODSNamespaces.manifest,
                  localName: "media-type"
              ),
              !path.isEmpty,
              mediaTypes[path] == nil else {
            throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
        }
        try budget.consumeLogicalItems(part: part)
        mediaTypes[path] = mediaType
    }

    func validatePackage(expectedMediaType: String, requiredContentPath: String) throws {
        guard !encrypted else {
            throw OpenXMLComparisonError(code: .encryptedDocument, part: part)
        }
        guard mediaTypes["/"] == expectedMediaType,
              let contentType = mediaTypes[requiredContentPath],
              contentType.isEmpty
                || contentType == "text/xml"
                || contentType == "application/xml" else {
            throw OpenXMLComparisonError(
                code: .invalidOpenDocumentPackage,
                part: part,
                detail: "The manifest does not identify an ODS root and content.xml"
            )
        }
    }
}

private struct ODSCellTemplate {
    let column: Int
    let displayValue: String
    let formula: String?
    let valueType: String?
    let typedValue: String?
    let currency: String?
    let rowSpan: Int?
    let columnSpan: Int?
}

private struct ODSRowState {
    let repeatCount: Int
    var columnCount = 0
    var cells: [ODSCellTemplate] = []
}

private struct ODSCellState {
    let startColumn: Int
    let repeatCount: Int
    let valueType: String?
    let typedValue: String?
    let stringValue: String?
    let currency: String?
    let formula: String?
    let rowSpan: Int?
    let columnSpan: Int?
    var paragraphs: [String] = []
    var currentParagraph: String?
    let outputInstanceCount: Int
    let fixedOutputCharacterCount: Int
    let fixedOutputUTF8ByteCount: Int
    var displayCharacterCount = 0
    var displayUTF8ByteCount = 0
}

private final class ODSContentDelegate: ODSBoundedDelegate {
    private static let rowWrapperNames: Set<String> = [
        "table-header-rows",
        "table-rows",
        "table-row-group",
    ]
    private static let columnWrapperNames: Set<String> = [
        "table-header-columns",
        "table-columns",
        "table-column-group",
    ]

    private let expansionBudget: ODSSpreadsheetExpansionBudget
    private let maxSheetCount: Int
    private var bodySeen = false
    private var bodyOpen = false
    private var spreadsheetSeen = false
    private var spreadsheetOpen = false
    private var tableOpen = false
    private var rowSeenInCurrentTable = false
    private var coveredCellDepth: Int?
    private var ignoredNestedTableDepth: Int?
    private var sheetIndex = 0
    private var sheetName: String?
    private var declaredColumnCount = 0
    private var outputRowCount = 0
    private var rowMarkers: [String] = []
    private var cells: [OpenXMLCellSnapshot] = []
    private var currentRow: ODSRowState?
    private var currentCell: ODSCellState?
    private(set) var sections: [OpenXMLLogicalSection] = []

    private var coveredCellOpen: Bool { coveredCellDepth != nil }

    init(
        budget: ODSXMLBudget,
        expansionBudget: ODSSpreadsheetExpansionBudget,
        part: String,
        maxSheetCount: Int
    ) {
        self.expansionBudget = expansionBudget
        self.maxSheetCount = maxSheetCount
        super.init(
            budget: budget,
            part: part,
            expectedRoot: "document-content",
            expectedRootNamespace: ODSNamespaces.office
        )
    }

    override func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: ODSAttributes
    ) throws {
        // A covered cell's payload and a legal direct-child nested table are
        // package content, not cells/rows in the top-level worksheet model.
        // The base delegate has already charged XML nodes and resolved every
        // namespace before this semantic short-circuit.
        if coveredCellOpen || ignoredNestedTableDepth != nil { return }

        if namespaceURI == ODSNamespaces.office, name == "body" {
            guard parentElement == ODSExpandedName(
                      namespaceURI: ODSNamespaces.office,
                      localName: "document-content"
                  ),
                  !bodySeen,
                  !bodyOpen,
                  !spreadsheetOpen,
                  !tableOpen else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            bodySeen = true
            bodyOpen = true
            return
        }

        if namespaceURI == ODSNamespaces.office, name == "spreadsheet" {
            guard bodyOpen,
                  parentElement == ODSExpandedName(
                      namespaceURI: ODSNamespaces.office,
                      localName: "body"
                  ),
                  !spreadsheetSeen,
                  !spreadsheetOpen,
                  !tableOpen else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            spreadsheetSeen = true
            spreadsheetOpen = true
            return
        }

        if namespaceURI == ODSNamespaces.table, name == "table" {
            if parentElement == ODSExpandedName(
                namespaceURI: ODSNamespaces.table,
                localName: "table-cell"
            ) {
                guard currentCell != nil,
                      currentCell?.currentParagraph == nil,
                      tableOpen,
                      currentRow != nil else {
                    throw OpenXMLComparisonError(
                        code: .invalidOpenDocumentPackage,
                        part: part
                    )
                }
                ignoredNestedTableDepth = elementStack.count
                return
            }

            guard parentElement == ODSExpandedName(
                      namespaceURI: ODSNamespaces.office,
                      localName: "spreadsheet"
                  ),
                  spreadsheetOpen,
                  !tableOpen,
                  currentRow == nil,
                  currentCell == nil,
                  !coveredCellOpen else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            guard sheetIndex < maxSheetCount else {
                throw OpenXMLComparisonError(code: .worksheetOrSlideLimitExceeded, part: part)
            }
            try expansionBudget.consumeSheet()
            sheetIndex += 1
            let resolvedSheetName = attributes.value(
                namespaceURI: ODSNamespaces.table,
                localName: "name"
            ) ?? "Sheet \(sheetIndex)"
            try expansionBudget.consumeOutput([resolvedSheetName])
            sheetName = resolvedSheetName
            declaredColumnCount = 0
            outputRowCount = 0
            rowMarkers = []
            cells = []
            rowSeenInCurrentTable = false
            tableOpen = true
            return
        }

        if namespaceURI == ODSNamespaces.table,
           Self.columnWrapperNames.contains(name) {
            guard tableOpen,
                  Self.isColumnContainer(parentElement),
                  currentRow == nil,
                  currentCell == nil,
                  !coveredCellOpen,
                  !rowSeenInCurrentTable else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            return
        }

        if namespaceURI == ODSNamespaces.table,
           Self.rowWrapperNames.contains(name) {
            guard tableOpen,
                  Self.isRowContainer(parentElement),
                  currentRow == nil,
                  currentCell == nil,
                  !coveredCellOpen else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            rowSeenInCurrentTable = true
            return
        }

        if namespaceURI == ODSNamespaces.table, name == "table-column" {
            guard tableOpen,
                  Self.isColumnContainer(parentElement),
                  currentRow == nil,
                  currentCell == nil,
                  !coveredCellOpen,
                  !rowSeenInCurrentTable else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            let count = try expansionBudget.validatedRepeat(
                attributes.value(
                    namespaceURI: ODSNamespaces.table,
                    localName: "number-columns-repeated"
                ),
                attribute: "table:number-columns-repeated"
            )
            let (next, overflow) = declaredColumnCount.addingReportingOverflow(count)
            guard !overflow else {
                throw OpenXMLComparisonError(code: .spreadsheetColumnLimitExceeded, part: part)
            }
            try expansionBudget.validateColumnTotal(next)
            declaredColumnCount = next
            return
        }

        if namespaceURI == ODSNamespaces.table, name == "table-row" {
            guard tableOpen,
                  Self.isRowContainer(parentElement),
                  currentRow == nil,
                  currentCell == nil,
                  !coveredCellOpen else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            let repeatCount = try expansionBudget.validatedRepeat(
                attributes.value(
                    namespaceURI: ODSNamespaces.table,
                    localName: "number-rows-repeated"
                ),
                attribute: "table:number-rows-repeated"
            )
            try expansionBudget.consumeRows(repeatCount)
            currentRow = ODSRowState(repeatCount: repeatCount)
            rowSeenInCurrentTable = true
            return
        }

        if namespaceURI == ODSNamespaces.table,
           name == "covered-table-cell" {
            guard parentElement == ODSExpandedName(
                      namespaceURI: ODSNamespaces.table,
                      localName: "table-row"
                  ),
                  var row = currentRow,
                  currentCell == nil,
                  !coveredCellOpen else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            let repeatCount = try expansionBudget.validatedRepeat(
                attributes.value(
                    namespaceURI: ODSNamespaces.table,
                    localName: "number-columns-repeated"
                ),
                attribute: "table:number-columns-repeated"
            )
            let (nextColumn, overflow) = row.columnCount.addingReportingOverflow(repeatCount)
            guard !overflow else {
                throw OpenXMLComparisonError(code: .spreadsheetColumnLimitExceeded, part: part)
            }
            try expansionBudget.validateColumnTotal(nextColumn)
            _ = try expansionBudget.consumeCells(
                repeatCount,
                rowRepeat: row.repeatCount,
                isCovered: true
            )
            row.columnCount = nextColumn
            currentRow = row
            coveredCellDepth = elementStack.count
            return
        }

        if namespaceURI == ODSNamespaces.table,
           name == "table-cell" {
            guard parentElement == ODSExpandedName(
                      namespaceURI: ODSNamespaces.table,
                      localName: "table-row"
                  ),
                  let row = currentRow,
                  currentCell == nil,
                  !coveredCellOpen else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            let repeatCount = try expansionBudget.validatedRepeat(
                attributes.value(
                    namespaceURI: ODSNamespaces.table,
                    localName: "number-columns-repeated"
                ),
                attribute: "table:number-columns-repeated"
            )
            let (nextColumn, overflow) = row.columnCount.addingReportingOverflow(repeatCount)
            guard !overflow else {
                throw OpenXMLComparisonError(code: .spreadsheetColumnLimitExceeded, part: part)
            }
            try expansionBudget.validateColumnTotal(nextColumn)
            let outputInstanceCount = try expansionBudget.consumeCells(
                repeatCount,
                rowRepeat: row.repeatCount,
                isCovered: false
            )
            let valueType = attributes.value(
                namespaceURI: ODSNamespaces.office,
                localName: "value-type"
            )
            let rowSpan = try expansionBudget.validatedRowSpan(
                attributes.value(
                    namespaceURI: ODSNamespaces.table,
                    localName: "number-rows-spanned"
                ),
                attribute: "table:number-rows-spanned"
            )
            let columnSpan = try expansionBudget.validatedColumnSpan(
                attributes.value(
                    namespaceURI: ODSNamespaces.table,
                    localName: "number-columns-spanned"
                ),
                attribute: "table:number-columns-spanned"
            )
            try expansionBudget.validateSpanEndpoints(
                completedRowCount: outputRowCount,
                rowRepeat: row.repeatCount,
                maximumAnchorColumn: nextColumn,
                rowSpan: rowSpan,
                columnSpan: columnSpan
            )
            let typedValue = Self.typedValue(valueType: valueType, attributes: attributes)
            let stringValue = attributes.value(
                namespaceURI: ODSNamespaces.office,
                localName: "string-value"
            )
            let currency = attributes.value(
                namespaceURI: ODSNamespaces.office,
                localName: "currency"
            )
            let formula = attributes.value(
                namespaceURI: ODSNamespaces.table,
                localName: "formula"
            )
            let fixedOutput = try expansionBudget.measureOutput([
                formula ?? "",
                valueType ?? "",
                typedValue ?? "",
                currency ?? "",
                rowSpan.map(String.init) ?? "",
                columnSpan.map(String.init) ?? "",
            ])
            try expansionBudget.validateOutput(
                characters: fixedOutput.characters,
                utf8Bytes: fixedOutput.utf8Bytes,
                instanceCount: outputInstanceCount
            )
            currentCell = ODSCellState(
                startColumn: try added(row.columnCount, 1),
                repeatCount: repeatCount,
                valueType: valueType,
                typedValue: typedValue,
                stringValue: stringValue,
                currency: currency,
                formula: formula,
                rowSpan: rowSpan,
                columnSpan: columnSpan,
                outputInstanceCount: outputInstanceCount,
                fixedOutputCharacterCount: fixedOutput.characters,
                fixedOutputUTF8ByteCount: fixedOutput.utf8Bytes
            )
            return
        }

        if namespaceURI == ODSNamespaces.text, name == "p" {
            // ODF uses text paragraphs in validation messages, tracked
            // changes, shapes, and other non-cell payloads. They remain
            // covered by the raw XML budgets but are not worksheet values.
            guard var cell = currentCell else { return }
            guard cell.currentParagraph == nil else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            if !cell.paragraphs.isEmpty {
                let nextCharacters = try added(cell.displayCharacterCount, 1)
                let nextBytes = try added(cell.displayUTF8ByteCount, 1)
                try validatePendingOutput(
                    cell,
                    displayCharacters: nextCharacters,
                    displayUTF8Bytes: nextBytes
                )
                cell.displayCharacterCount = nextCharacters
                cell.displayUTF8ByteCount = nextBytes
            }
            cell.currentParagraph = ""
            currentCell = cell
            return
        }

        guard namespaceURI == ODSNamespaces.text,
              ["tab", "line-break", "s"].contains(name) else { return }
        guard currentCell != nil else { return }
        guard currentCell?.currentParagraph != nil else {
            throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
        }
        switch name {
        case "tab":
            try appendToCurrentParagraph("\t")
        case "line-break":
            try appendToCurrentParagraph("\n")
        case "s":
            let count = try expansionBudget.validatedRepeat(
                attributes.value(
                    namespaceURI: ODSNamespaces.text,
                    localName: "c"
                ),
                attribute: "text:c"
            )
            try appendSpacesToCurrentParagraph(count)
        default:
            break
        }
    }

    override func characters(_ string: String) throws {
        if coveredCellOpen || ignoredNestedTableDepth != nil { return }
        if currentCell?.currentParagraph != nil {
            try appendToCurrentParagraph(string)
        }
    }

    override func endElement(_ name: String, namespaceURI: String?, qualifiedName: String?) throws {
        if let ignoredDepth = ignoredNestedTableDepth {
            guard elementStack.count >= ignoredDepth else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            if elementStack.count == ignoredDepth {
                guard currentElement == ODSExpandedName(
                    namespaceURI: ODSNamespaces.table,
                    localName: "table"
                ) else {
                    throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
                }
                ignoredNestedTableDepth = nil
            }
            return
        }

        if let coveredDepth = coveredCellDepth, elementStack.count > coveredDepth {
            return
        }

        if namespaceURI == ODSNamespaces.text, name == "p", var cell = currentCell,
           let paragraph = cell.currentParagraph {
            cell.paragraphs.append(paragraph)
            cell.currentParagraph = nil
            currentCell = cell
            return
        }

        if namespaceURI == ODSNamespaces.table, name == "covered-table-cell" {
            guard coveredCellOpen,
                  coveredCellDepth == elementStack.count,
                  currentCell == nil,
                  currentRow != nil,
                  parentElement == ODSExpandedName(
                      namespaceURI: ODSNamespaces.table,
                      localName: "table-row"
                  ) else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            coveredCellDepth = nil
            return
        }

        if namespaceURI == ODSNamespaces.table, name == "table-cell", let cell = currentCell {
            guard !coveredCellOpen,
                  parentElement == ODSExpandedName(
                      namespaceURI: ODSNamespaces.table,
                      localName: "table-row"
                  ) else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            guard var row = currentRow else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            let displayValue = Self.displayValue(for: cell)
            try expansionBudget.consumeOutput(
                [
                    displayValue,
                    cell.formula ?? "",
                    cell.valueType ?? "",
                    cell.typedValue ?? "",
                    cell.currency ?? "",
                    cell.rowSpan.map(String.init) ?? "",
                    cell.columnSpan.map(String.init) ?? "",
                ],
                instanceCount: cell.outputInstanceCount
            )
            row.cells.reserveCapacity(try added(row.cells.count, cell.repeatCount))
            for offset in 0..<cell.repeatCount {
                try ODSCancellation.check(iteration: offset)
                row.cells.append(ODSCellTemplate(
                    column: try added(cell.startColumn, offset),
                    displayValue: displayValue,
                    formula: cell.formula,
                    valueType: cell.valueType,
                    typedValue: cell.typedValue,
                    currency: cell.currency,
                    rowSpan: cell.rowSpan,
                    columnSpan: cell.columnSpan
                ))
            }
            row.columnCount = try added(row.columnCount, cell.repeatCount)
            currentRow = row
            currentCell = nil
            return
        }

        if namespaceURI == ODSNamespaces.table, name == "table-row", let row = currentRow {
            guard currentCell == nil,
                  !coveredCellOpen,
                  Self.isRowContainer(parentElement) else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            try expansionBudget.validateColumnTotal(max(row.columnCount, declaredColumnCount))
            rowMarkers.reserveCapacity(try added(rowMarkers.count, row.repeatCount))
            let repeatedCellCount = try multiplied(row.cells.count, row.repeatCount)
            cells.reserveCapacity(try added(cells.count, repeatedCellCount))
            for repetition in 0..<row.repeatCount {
                try ODSCancellation.check(iteration: repetition)
                let rowNumber = try added(try added(outputRowCount, repetition), 1)
                let marker = "row.\(rowNumber):columns=\(row.columnCount)"
                try expansionBudget.consumeOutput([marker])
                rowMarkers.append(marker)
                for (cellIndex, cell) in row.cells.enumerated() {
                    try ODSCancellation.check(iteration: cellIndex)
                    let reference = "\(Self.columnName(cell.column))\(rowNumber)"
                    try expansionBudget.consumeOutput([reference])
                    cells.append(OpenXMLCellSnapshot(
                        reference: reference,
                        displayValue: cell.displayValue,
                        formula: cell.formula,
                        valueType: cell.valueType,
                        typedValue: cell.typedValue,
                        currency: cell.currency,
                        rowSpan: cell.rowSpan,
                        columnSpan: cell.columnSpan
                    ))
                }
            }
            outputRowCount = try added(outputRowCount, row.repeatCount)
            currentRow = nil
            return
        }

        if namespaceURI == ODSNamespaces.table, name == "table" {
            guard tableOpen,
                  currentRow == nil,
                  currentCell == nil,
                  !coveredCellOpen,
                  parentElement == ODSExpandedName(
                      namespaceURI: ODSNamespaces.office,
                      localName: "spreadsheet"
                  ) else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            let sectionKey = "worksheet.\(sheetIndex)"
            let declaredColumnsMarker = "declared-columns=\(declaredColumnCount)"
            try expansionBudget.consumeOutput([sectionKey, declaredColumnsMarker])
            sections.append(OpenXMLLogicalSection(
                key: sectionKey,
                kind: .worksheet,
                title: sheetName,
                textBlocks: [declaredColumnsMarker] + rowMarkers,
                cells: cells
            ))
            sheetName = nil
            rowMarkers = []
            cells = []
            tableOpen = false
            return
        }

        if namespaceURI == ODSNamespaces.office, name == "spreadsheet" {
            guard spreadsheetOpen,
                  !tableOpen,
                  currentRow == nil,
                  currentCell == nil,
                  parentElement == ODSExpandedName(
                      namespaceURI: ODSNamespaces.office,
                      localName: "body"
                  ) else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            spreadsheetOpen = false
            return
        }

        if namespaceURI == ODSNamespaces.office, name == "body" {
            guard bodyOpen,
                  !spreadsheetOpen,
                  !tableOpen,
                  parentElement == ODSExpandedName(
                      namespaceURI: ODSNamespaces.office,
                      localName: "document-content"
                  ) else {
                throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
            }
            bodyOpen = false
        }
    }

    func result() throws -> [OpenXMLLogicalSection] {
        guard bodySeen,
              !bodyOpen,
              spreadsheetSeen,
              !spreadsheetOpen,
              !tableOpen,
              currentRow == nil,
              currentCell == nil,
              !coveredCellOpen,
              ignoredNestedTableDepth == nil else {
            throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
        }
        return sections
    }

    private func multiplied(_ left: Int, _ right: Int) throws -> Int {
        let (result, overflow) = left.multipliedReportingOverflow(by: right)
        guard !overflow else {
            throw OpenXMLComparisonError(code: .spreadsheetCellLimitExceeded, part: part)
        }
        return result
    }

    private func added(_ left: Int, _ right: Int) throws -> Int {
        let (result, overflow) = left.addingReportingOverflow(right)
        guard left >= 0, right >= 0, !overflow else {
            throw OpenXMLComparisonError(code: .spreadsheetExpansionLimitExceeded, part: part)
        }
        return result
    }

    private func validatePendingOutput(
        _ cell: ODSCellState,
        displayCharacters: Int,
        displayUTF8Bytes: Int
    ) throws {
        try expansionBudget.validateOutput(
            characters: try added(cell.fixedOutputCharacterCount, displayCharacters),
            utf8Bytes: try added(cell.fixedOutputUTF8ByteCount, displayUTF8Bytes),
            instanceCount: cell.outputInstanceCount
        )
    }

    private func appendToCurrentParagraph(_ string: String) throws {
        guard var cell = currentCell, var paragraph = cell.currentParagraph else {
            throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
        }
        let nextCharacters = try added(cell.displayCharacterCount, string.count)
        let nextBytes = try added(cell.displayUTF8ByteCount, string.utf8.count)
        try validatePendingOutput(
            cell,
            displayCharacters: nextCharacters,
            displayUTF8Bytes: nextBytes
        )
        paragraph.append(string)
        cell.currentParagraph = paragraph
        cell.displayCharacterCount = nextCharacters
        cell.displayUTF8ByteCount = nextBytes
        currentCell = cell
    }

    private func appendSpacesToCurrentParagraph(_ count: Int) throws {
        guard var cell = currentCell, var paragraph = cell.currentParagraph else {
            throw OpenXMLComparisonError(code: .invalidOpenDocumentPackage, part: part)
        }
        let nextCharacters = try added(cell.displayCharacterCount, count)
        let nextBytes = try added(cell.displayUTF8ByteCount, count)
        try validatePendingOutput(
            cell,
            displayCharacters: nextCharacters,
            displayUTF8Bytes: nextBytes
        )
        paragraph.append(String(repeating: " ", count: count))
        cell.currentParagraph = paragraph
        cell.displayCharacterCount = nextCharacters
        cell.displayUTF8ByteCount = nextBytes
        currentCell = cell
    }

    private static func isRowContainer(_ element: ODSExpandedName?) -> Bool {
        guard element?.namespaceURI == ODSNamespaces.table,
              let localName = element?.localName else { return false }
        return localName == "table" || rowWrapperNames.contains(localName)
    }

    private static func isColumnContainer(_ element: ODSExpandedName?) -> Bool {
        guard element?.namespaceURI == ODSNamespaces.table,
              let localName = element?.localName else { return false }
        return localName == "table" || columnWrapperNames.contains(localName)
    }

    private static func typedValue(
        valueType: String?,
        attributes: ODSAttributes
    ) -> String? {
        switch valueType {
        case "boolean": return attributes.value(namespaceURI: ODSNamespaces.office, localName: "boolean-value")
        case "date": return attributes.value(namespaceURI: ODSNamespaces.office, localName: "date-value")
        case "time": return attributes.value(namespaceURI: ODSNamespaces.office, localName: "time-value")
        case "string": return attributes.value(namespaceURI: ODSNamespaces.office, localName: "string-value")
        default:
            return attributes.value(namespaceURI: ODSNamespaces.office, localName: "value")
                ?? attributes.value(namespaceURI: ODSNamespaces.office, localName: "string-value")
                ?? attributes.value(namespaceURI: ODSNamespaces.office, localName: "boolean-value")
                ?? attributes.value(namespaceURI: ODSNamespaces.office, localName: "date-value")
                ?? attributes.value(namespaceURI: ODSNamespaces.office, localName: "time-value")
        }
    }

    private static func displayValue(for cell: ODSCellState) -> String {
        if !cell.paragraphs.isEmpty { return cell.paragraphs.joined(separator: "\n") }
        if let stringValue = cell.stringValue { return stringValue }
        if cell.valueType == "boolean", let typedValue = cell.typedValue {
            return typedValue.lowercased() == "true" ? "TRUE" : "FALSE"
        }
        return cell.typedValue ?? ""
    }

    private static func columnName(_ column: Int) -> String {
        var number = column
        var result = ""
        while number > 0 {
            number -= 1
            result.insert(Character(UnicodeScalar(65 + number % 26)!), at: result.startIndex)
            number /= 26
        }
        return result
    }
}

private final class ODSMetadataDelegate: ODSBoundedDelegate {
    private let expansionBudget: ODSSpreadsheetExpansionBudget
    private var currentField: String?
    private var currentValue = ""
    private var values: [String: String] = [:]

    init(
        budget: ODSXMLBudget,
        expansionBudget: ODSSpreadsheetExpansionBudget,
        part: String
    ) {
        self.expansionBudget = expansionBudget
        super.init(
            budget: budget,
            part: part,
            expectedRoot: "document-meta",
            expectedRootNamespace: ODSNamespaces.office
        )
    }

    override func startElement(
        _ name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: ODSAttributes
    ) throws {
        let supported = (namespaceURI == ODSNamespaces.dc
            && ["title", "subject", "creator", "description", "date"].contains(name))
            || (namespaceURI == ODSNamespaces.metadata
                && ["initial-creator", "keyword", "creation-date"].contains(name))
        if supported, currentField == nil {
            currentField = name
            currentValue = ""
        }
    }

    override func characters(_ string: String) throws {
        if currentField != nil { currentValue += string }
    }

    override func endElement(_ name: String, namespaceURI: String?, qualifiedName: String?) throws {
        guard currentField == name else { return }
        if values[name] == nil {
            try expansionBudget.consumeOutput([currentValue])
            values[name] = currentValue
        }
        currentField = nil
        currentValue = ""
    }

    func result() -> OpenXMLCoreProperties {
        OpenXMLCoreProperties(
            title: values["title"],
            subject: values["subject"],
            creator: values["creator"] ?? values["initial-creator"],
            description: values["description"],
            keywords: values["keyword"],
            created: values["creation-date"],
            modified: values["date"]
        )
    }
}

private enum ODSDigest {
    private static let chunkByteCount = 1 * 1_024 * 1_024

    static func data(_ data: Data) throws -> String {
        var hasher = SHA256()
        var offset = 0
        repeat {
            try Task.checkCancellation()
            let end = min(data.count, offset + chunkByteCount)
            if offset < end {
                hasher.update(data: data[offset..<end])
            }
            offset = end
        } while offset < data.count
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
