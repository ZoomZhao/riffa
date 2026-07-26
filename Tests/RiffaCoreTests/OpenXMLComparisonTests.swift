import Foundation
import Testing
@testable import RiffaCore
import zlib

@Suite("Bounded Office package comparison")
struct OpenXMLComparisonTests {
    private let engine = OpenXMLComparisonEngine()

    @Test("DOCX extracts core properties, paragraphs, table text, and stable part digests")
    func docxHappyPath() throws {
        let package = try makeDOCX(
            title: "季度 <报告>",
            creator: "Riffa",
            paragraphs: ["第一段", "尾段"],
            tableRows: [["A", "B"], ["1", "2"]],
            extraParts: ["word/media/opaque.bin": Data("RAW_SECRET_BYTES".utf8)]
        )
        let snapshot = try engine.snapshot(data: package)
        requireOpenXMLSendable(snapshot)

        #expect(snapshot.documentType == .wordProcessingDocument)
        #expect(snapshot.coreProperties.title == "季度 <报告>")
        #expect(snapshot.coreProperties.creator == "Riffa")
        #expect(snapshot.sections.map(\.key) == ["paragraph.1", "table.1", "paragraph.2"])
        #expect(snapshot.sections[0].textBlocks == ["第一段"])
        #expect(snapshot.sections[1].textBlocks == ["A\tB", "1\t2"])
        #expect(snapshot.parts.map(\.partName) == snapshot.parts.map(\.partName).sorted())
        #expect(snapshot.parts.allSatisfy { $0.sha256.count == 64 })

        let encoded = try JSONEncoder().encode(snapshot)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("RAW_SECRET_BYTES"))
        #expect(try JSONDecoder().decode(OpenXMLDocumentSnapshot.self, from: encoded) == snapshot)
    }

    @Test("XLSX resolves workbook relationships, shared strings, values, formulas, and booleans")
    func xlsxHappyPath() throws {
        let package = try makeXLSX(
            sheetName: "数据 & 图表",
            sharedStrings: ["项目", "收入"],
            cells: [
                XLSXTestCell(reference: "A1", type: "s", value: "0"),
                XLSXTestCell(reference: "B1", type: "s", value: "1"),
                XLSXTestCell(reference: "A2", value: "41", formula: "40+1"),
                XLSXTestCell(reference: "B2", type: "b", value: "1"),
                XLSXTestCell(reference: "C2", type: "inlineStr", value: "内联"),
            ]
        )
        let snapshot = try engine.snapshot(data: package)

        #expect(snapshot.documentType == .spreadsheet)
        #expect(snapshot.sections.count == 1)
        #expect(snapshot.sections[0].kind == .worksheet)
        #expect(snapshot.sections[0].title == "数据 & 图表")
        #expect(snapshot.sections[0].cells == [
            OpenXMLCellSnapshot(reference: "A1", displayValue: "项目"),
            OpenXMLCellSnapshot(reference: "B1", displayValue: "收入"),
            OpenXMLCellSnapshot(reference: "A2", displayValue: "41", formula: "40+1"),
            OpenXMLCellSnapshot(reference: "B2", displayValue: "TRUE"),
            OpenXMLCellSnapshot(reference: "C2", displayValue: "内联"),
        ])
    }

    @Test("ODS extracts sheets, repeated rows and cells, typed values, formulas, and spans")
    func odsHappyPath() throws {
        let content = odsContentXML(
            sheets: [
                odsSheetXML(
                    name: "数据 & 预算",
                    declaredColumns: 4,
                    rows: """
                    <table:table-row table:number-rows-repeated="2">
                      <table:table-cell table:number-columns-repeated="2" table:number-columns-spanned="2" table:number-rows-spanned="2" office:value-type="float" office:value="42.5" table:formula="of:=SUM([.A1:.A2])"><text:p>42.50</text:p></table:table-cell>
                      <table:covered-table-cell table:number-columns-repeated="2"/>
                    </table:table-row>
                    """
                ),
                odsSheetXML(
                    name: "Types",
                    declaredColumns: 3,
                    rows: """
                    <table:table-row>
                      <table:table-cell office:value-type="boolean" office:boolean-value="true"/>
                      <table:table-cell office:value-type="date" office:date-value="2026-07-19"><text:p>19 Jul 2026</text:p></table:table-cell>
                      <table:table-cell office:value-type="currency" office:value="12.30" office:currency="CNY"><text:p>¥12.30</text:p></table:table-cell>
                    </table:table-row>
                    """
                ),
            ]
        )
        let package = try makeODS(
            contentXML: content,
            metadataXML: odsMetadataXML(title: "季度表", creator: "Riffa"),
            extraParts: [
                ZIPFixturePart(path: "Pictures/chart.png", data: Data("NOT_RENDERED".utf8)),
                ZIPFixturePart(path: "Scripts/macro.bin", data: Data("NOT_EXECUTED".utf8)),
            ]
        )

        let snapshot = try engine.snapshot(data: package)

        #expect(snapshot.documentType == .openDocumentSpreadsheet)
        #expect(snapshot.coreProperties.title == "季度表")
        #expect(snapshot.coreProperties.creator == "Riffa")
        #expect(snapshot.sections.map(\.title) == ["数据 & 预算", "Types"])
        #expect(snapshot.sections[0].textBlocks == [
            "declared-columns=4",
            "row.1:columns=4",
            "row.2:columns=4",
        ])
        #expect(snapshot.sections[0].cells.map(\.reference) == ["A1", "B1", "A2", "B2"])
        #expect(snapshot.sections[0].cells.allSatisfy {
            $0.valueType == "float"
                && $0.typedValue == "42.5"
                && $0.formula == "of:=SUM([.A1:.A2])"
                && $0.rowSpan == 2
                && $0.columnSpan == 2
        })
        #expect(snapshot.sections[1].cells[0].displayValue == "TRUE")
        #expect(snapshot.sections[1].cells[0].typedValue == "true")
        #expect(snapshot.sections[1].cells[2].currency == "CNY")
        #expect(snapshot.parts.contains { $0.partName == "Pictures/chart.png" })
        #expect(snapshot.parts.contains { $0.partName == "Scripts/macro.bin" })
        #expect(snapshot.parts.allSatisfy { $0.sha256.count == 64 })

        let encoded = try JSONEncoder().encode(snapshot)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("NOT_EXECUTED"))
        #expect(try JSONDecoder().decode(OpenXMLDocumentSnapshot.self, from: encoded) == snapshot)
    }

    @Test("ODS comparison is deterministic across sheets and detects logical changes")
    func odsComparison() throws {
        let firstSheet = odsSheetXML(
            name: "One",
            declaredColumns: 1,
            rows: odsRowXML([odsCellXML(display: "same")])
        )
        let left = try makeODS(contentXML: odsContentXML(sheets: [
            firstSheet,
            odsSheetXML(
                name: "Two",
                declaredColumns: 1,
                rows: odsRowXML([odsCellXML(display: "left", formula: "of:=1+1")])
            ),
        ]))
        let right = try makeODS(contentXML: odsContentXML(sheets: [
            firstSheet,
            odsSheetXML(
                name: "Two",
                declaredColumns: 1,
                rows: odsRowXML([odsCellXML(display: "right", formula: "of:=1+2")])
            ),
        ]))

        let identical = try engine.compare(left: left, right: left)
        let changed = try engine.compare(left: left, right: right)

        #expect(!identical.hasDifferences)
        #expect(changed.hasDifferences)
        #expect(changed.rows.contains {
            $0.key == "section.worksheet.2" && $0.status == .different
        })
        let repeatedComparison = try engine.compare(left: left, right: right)
        #expect(changed == repeatedComparison)
    }

    @Test("ODS repeated structures are rejected before expansion crosses any budget")
    func odsRepeatBudgets() throws {
        let repeatedRows = try makeODS(contentXML: odsContentXML(sheets: [
            odsSheetXML(
                name: "Rows",
                rows: "<table:table-row table:number-rows-repeated=\"2\"><table:table-cell/></table:table-row>"
            ),
        ]))
        let repeatedColumns = try makeODS(contentXML: odsContentXML(sheets: [
            odsSheetXML(
                name: "Columns",
                rows: "<table:table-row><table:table-cell table:number-columns-repeated=\"3\"/></table:table-row>"
            ),
        ]))
        let twoCells = try makeODS(contentXML: odsContentXML(sheets: [
            odsSheetXML(
                name: "Cells",
                rows: odsRowXML([odsCellXML(display: "a"), odsCellXML(display: "b")])
            ),
        ]))
        let expandedText = try makeODS(contentXML: odsContentXML(sheets: [
            odsSheetXML(
                name: "Memory",
                rows: odsRowXML([odsCellXML(display: String(repeating: "x", count: 100))])
            ),
        ]))

        expectOpenXMLError(.spreadsheetRowLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: .init(
                maxSpreadsheetRowCount: 1
            )).snapshot(data: repeatedRows)
        }
        expectOpenXMLError(.spreadsheetColumnLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: .init(
                maxSpreadsheetColumnCount: 2
            )).snapshot(data: repeatedColumns)
        }
        expectOpenXMLError(.spreadsheetCellLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: .init(
                maxSpreadsheetCellCount: 1
            )).snapshot(data: twoCells)
        }
        expectOpenXMLError(.spreadsheetExpansionLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: .init(
                maxSpreadsheetExpandedByteCount: 128
            )).snapshot(data: expandedText)
        }
        let excessiveRepeat = try makeODS(contentXML: odsContentXML(sheets: [
            odsSheetXML(
                name: "Repeat",
                rows: "<table:table-row table:number-rows-repeated=\"1000001\"/>"
            ),
        ]))
        expectOpenXMLError(.spreadsheetRepeatLimitExceeded) {
            _ = try engine.snapshot(data: excessiveRepeat)
        }
        expectOpenXMLError(.invalidLimits) {
            _ = try OpenXMLComparisonLimits(maxSpreadsheetCellCount: Int.max)
        }
    }

    @Test("ODS rejects DTD, entities, encrypted manifests, and inconsistent declarations")
    func odsSecurityDeclarations() throws {
        let maliciousContent = """
        <?xml version="1.0"?>
        <!DOCTYPE office:document-content [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"><office:body><office:spreadsheet>&xxe;</office:spreadsheet></office:body></office:document-content>
        """
        expectOpenXMLError(.forbiddenDTD) {
            _ = try engine.snapshot(data: makeODS(contentXML: maliciousContent))
        }

        let encryptedManifest = odsManifestXML(extra: """
        <manifest:file-entry manifest:full-path="secret" manifest:media-type="text/xml">
          <manifest:encryption-data><manifest:algorithm manifest:algorithm-name="AES256"/></manifest:encryption-data>
        </manifest:file-entry>
        """)
        expectOpenXMLError(.encryptedDocument) {
            _ = try engine.snapshot(data: makeODS(manifestXML: encryptedManifest))
        }

        expectOpenXMLError(.invalidOpenDocumentPackage) {
            _ = try engine.snapshot(data: makeODS(
                mimetype: "application/zip"
            ))
        }
        expectOpenXMLError(.invalidOpenDocumentPackage) {
            _ = try engine.snapshot(data: makeODS(
                manifestXML: odsManifestXML(rootMediaType: "application/zip")
            ))
        }
    }

    @Test("ODS manifest entries are direct children and encryption markers use manifest namespaces")
    func odsManifestHierarchyAndEncryptionNamespaces() throws {
        let nestedEntry = """
        <m:manifest xmlns:m="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"><m:file-entry m:full-path="/" m:media-type="application/vnd.oasis.opendocument.spreadsheet"><m:file-entry m:full-path="content.xml" m:media-type="text/xml"/></m:file-entry></m:manifest>
        """
        expectOpenXMLError(.invalidOpenDocumentPackage) {
            _ = try engine.snapshot(data: makeODS(manifestXML: nestedEntry))
        }

        let foreignMarkers = """
        <m:manifest xmlns:m="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" xmlns:x="urn:foreign" x:encryption-state="true"><m:file-entry m:full-path="/" m:media-type="application/vnd.oasis.opendocument.spreadsheet" x:encrypted="true"><x:algorithm x:encryption-kind="foreign"/></m:file-entry><m:file-entry m:full-path="content.xml" m:media-type="text/xml"/></m:manifest>
        """
        #expect(try engine.snapshot(data: makeODS(
            manifestXML: foreignMarkers
        )).documentType == .openDocumentSpreadsheet)

        let encryptedKey = """
        <m:manifest xmlns:m="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"><m:file-entry m:full-path="/" m:media-type="application/vnd.oasis.opendocument.spreadsheet"/><m:file-entry m:full-path="content.xml" m:media-type="text/xml"/><m:encrypted-key/></m:manifest>
        """
        expectOpenXMLError(.encryptedDocument) {
            _ = try engine.snapshot(data: makeODS(manifestXML: encryptedKey))
        }
    }

    @Test("ODS resolves attributes by namespace URI and ignores foreign or unqualified spoofs")
    func odsStrictAttributeNamespaces() throws {
        let manifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <m:manifest xmlns:m="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" xmlns:x="urn:foreign">
          <m:file-entry m:full-path="/" x:full-path="foreign-root" full-path="plain-root" m:media-type="application/vnd.oasis.opendocument.spreadsheet" x:media-type="application/zip"/>
          <m:file-entry m:full-path="content.xml" x:full-path="foreign.xml" m:media-type="text/xml"/>
        </m:manifest>
        """
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <o:document-content xmlns:o="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:t="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:p="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:x="urn:foreign">
          <o:body><o:spreadsheet>
            <t:table t:name="Trusted" x:name="Foreign" name="Plain">
              <t:table-column t:number-columns-repeated="2" x:number-columns-repeated="9999999" number-columns-repeated="8888888"/>
              <t:table-row x:number-rows-repeated="9999999" number-rows-repeated="8888888">
                <t:table-cell o:value-type="float" x:value-type="string" o:value="7" x:value="999" t:formula="of:=3+4" x:formula="evil"><p:p>7</p:p></t:table-cell>
              </t:table-row>
            </t:table>
          </o:spreadsheet></o:body>
        </o:document-content>
        """

        let snapshot = try engine.snapshot(data: makeODS(
            manifestXML: manifest,
            contentXML: content
        ))
        let cell = try #require(snapshot.sections.first?.cells.first)
        #expect(snapshot.sections.first?.title == "Trusted")
        #expect(snapshot.sections.first?.textBlocks == [
            "declared-columns=2",
            "row.1:columns=1",
        ])
        #expect(cell.valueType == "float")
        #expect(cell.typedValue == "7")
        #expect(cell.formula == "of:=3+4")

        let foreignOnlyManifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <m:manifest xmlns:m="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" xmlns:x="urn:foreign">
          <m:file-entry x:full-path="/" x:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
          <m:file-entry x:full-path="content.xml" x:media-type="text/xml"/>
        </m:manifest>
        """
        expectOpenXMLError(.invalidOpenDocumentPackage) {
            _ = try engine.snapshot(data: makeODS(manifestXML: foreignOnlyManifest))
        }

        let duplicateExpandedName = content.replacingOccurrences(
            of: "xmlns:x=\"urn:foreign\"",
            with: "xmlns:x=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\""
        )
        expectOpenXMLError(.invalidOpenDocumentPackage) {
            _ = try engine.snapshot(data: makeODS(contentXML: duplicateExpandedName))
        }
    }

    @Test("ODS enforces structural ancestry while accepting standard row and column wrappers")
    func odsStrictElementHierarchy() throws {
        let wrappedSheet = odsSheetXML(
            name: "Wrapped",
            rows: """
            <table:table-column-group><table:table-header-columns><table:table-column table:number-columns-repeated="2"/></table:table-header-columns></table:table-column-group>
            <table:table-row-group><table:table-header-rows><table:table-row><table:table-cell office:value-type="string"><text:p>wrapped <text:span>text</text:span></text:p></table:table-cell><table:table-cell><text:list><text:list-item><text:p>listed</text:p></text:list-item></text:list></table:table-cell></table:table-row></table:table-header-rows></table:table-row-group>
            """
        )
        let wrapped = try engine.snapshot(data: makeODS(
            contentXML: odsContentXML(sheets: [wrappedSheet])
        ))
        #expect(wrapped.sections.first?.textBlocks == [
            "declared-columns=2",
            "row.1:columns=2",
        ])
        #expect(wrapped.sections.first?.cells.first?.displayValue == "wrapped text")
        #expect(wrapped.sections.first?.cells.last?.displayValue == "listed")

        let nonCellTextAndRebinding = """
        <o:document-content xmlns:o="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:t="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:p="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:x="urn:foreign"><o:body><o:spreadsheet><t:table t:name="Restored"><x:validation-help><p:p>not a cell<p:tab/><p:s p:c="1000001"/><p:line-break/>ignored</p:p></x:validation-help><x:scope xmlns:t="urn:foreign"><t:table-row><p:p>also ignored</p:p></t:table-row></x:scope><t:table-row><t:table-cell><p:p>kept</p:p></t:table-cell></t:table-row></t:table></o:spreadsheet></o:body></o:document-content>
        """
        let restored = try OpenXMLComparisonEngine(limits: .init(
            maxSpreadsheetRepeatCount: 1
        )).snapshot(data: makeODS(contentXML: nonCellTextAndRebinding))
        #expect(restored.sections.count == 1)
        #expect(restored.sections.first?.cells.map(\.displayValue) == ["kept"])
        #expect(restored.sections.first?.textBlocks == [
            "declared-columns=0",
            "row.1:columns=1",
        ])

        let malformedSheets = [
            // A table cannot escape office:spreadsheet.
            "<table:table table:name=\"Outside\"/><office:spreadsheet/>",
            "<office:spreadsheet/><table:table table:name=\"AfterSpreadsheet\"/>",
            // A row cannot escape the active top-level sheet table.
            "<office:spreadsheet><table:table-row/></office:spreadsheet>",
            // Foreign wrappers cannot manufacture valid row ancestry.
            "<office:spreadsheet><table:table table:name=\"S\"><x:wrapper><table:table-row/></x:wrapper></table:table></office:spreadsheet>",
            // Cells and paragraphs cannot nest recursively.
            "<office:spreadsheet><table:table table:name=\"S\"><table:table-row><table:table-cell><table:table-cell/></table:table-cell></table:table-row></table:table></office:spreadsheet>",
            "<office:spreadsheet><table:table table:name=\"S\"><table:table-row><table:table-cell><text:p>outer<text:p>inner</text:p></text:p></table:table-cell></table:table-row></table:table></office:spreadsheet>",
            "<office:spreadsheet><table:table table:name=\"S\"><table:table-row><table:table-cell><text:p>outer<table:table/></text:p></table:table-cell></table:table-row></table:table></office:spreadsheet>",
            // Column declarations are invalid after the first data-row section.
            "<office:spreadsheet><table:table table:name=\"S\"><table:table-row/><table:table-column/></table:table></office:spreadsheet>",
        ]
        for body in malformedSheets {
            let content = """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:x="urn:foreign"><office:body>\(body)</office:body></office:document-content>
            """
            expectOpenXMLError(.invalidOpenDocumentPackage) {
                _ = try engine.snapshot(data: makeODS(contentXML: content))
            }
        }

        let rootTable = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"><table:table table:name="NoBody"/></office:document-content>
        """
        expectOpenXMLError(.invalidOpenDocumentPackage) {
            _ = try engine.snapshot(data: makeODS(contentXML: rootTable))
        }
    }

    @Test("ODS nested tables and covered payload stay opaque to top-level worksheet semantics")
    func odsNestedTablesAndCoveredPayloadAreSemanticOpaque() throws {
        func content(_ ignoredMarker: String) -> String {
            odsContentXML(sheets: [
                odsSheetXML(
                    name: "Top",
                    rows: """
                    <table:table-row>
                      <table:table-cell>
                        <text:p>outer before</text:p>
                        <table:table table:name="Nested"><table:table-row table:number-rows-repeated="1000001"><table:table-cell table:number-columns-repeated="1000001"><text:p>ignored ordinary \(ignoredMarker)</text:p></table:table-cell></table:table-row></table:table>
                        <text:p>outer after</text:p>
                      </table:table-cell>
                      <table:covered-table-cell>
                        <text:p>covered text</text:p>
                        <table:table table:name="CoveredNested"><table:table-row table:number-rows-repeated="1000001"><table:covered-table-cell table:number-columns-repeated="1000001"><text:p>nested covered</text:p></table:covered-table-cell></table:table-row></table:table>
                        <text:p>covered tail</text:p>
                      </table:covered-table-cell>
                      <table:table-cell><text:p>after</text:p></table:table-cell>
                    </table:table-row>
                    """
                ),
            ])
        }

        let left = try makeODS(contentXML: content("A"))
        let right = try makeODS(contentXML: content("B"))
        let strictEngine = OpenXMLComparisonEngine(limits: try .init(
            maxLogicalItemCount: 7,
            maxSpreadsheetRepeatCount: 1
        ))
        let leftSnapshot = try strictEngine.snapshot(data: left)
        let rightSnapshot = try strictEngine.snapshot(data: right)
        let section = try #require(leftSnapshot.sections.first)

        #expect(leftSnapshot.sections.count == 1)
        #expect(section.key == "worksheet.1")
        #expect(section.textBlocks == [
            "declared-columns=0",
            "row.1:columns=3",
        ])
        #expect(section.cells.map(\.reference) == ["A1", "C1"])
        #expect(section.cells.map(\.displayValue) == ["outer before\nouter after", "after"])
        #expect(leftSnapshot.sections == rightSnapshot.sections)

        let leftContent = try #require(leftSnapshot.parts.first { $0.partName == "content.xml" })
        let rightContent = try #require(rightSnapshot.parts.first { $0.partName == "content.xml" })
        #expect(leftContent.uncompressedByteCount == rightContent.uncompressedByteCount)
        #expect(leftContent.sha256 != rightContent.sha256)

        let comparison = try strictEngine.compare(left: left, right: right)
        #expect(comparison.rows.first { $0.key == "section.worksheet.1" }?.status == .same)
        #expect(comparison.rows.first { $0.key == "part.content.xml" }?.status == .different)
    }

    @Test("ODS ignored nested content still consumes raw XML node, text, and namespace work")
    func odsIgnoredNestedContentStillConsumesRawXMLBudgets() throws {
        let compactManifest = """
        <m:manifest xmlns:m="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"><m:file-entry m:full-path="/" m:media-type="application/vnd.oasis.opendocument.spreadsheet"/><m:file-entry m:full-path="content.xml" m:media-type="text/xml"/></m:manifest>
        """
        let baseline = """
        <o:document-content xmlns:o="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:t="urn:oasis:names:tc:opendocument:xmlns:table:1.0"><o:body><o:spreadsheet><t:table t:name="S"><t:table-row><t:table-cell/></t:table-row></t:table></o:spreadsheet></o:body></o:document-content>
        """
        let nestedNode = baseline.replacingOccurrences(
            of: "<t:table-cell/>",
            with: "<t:table-cell><t:table/></t:table-cell>"
        )

        _ = try OpenXMLComparisonEngine(limits: .init(
            maxXMLNodeCount: 9,
            maxTextCharacterCount: 320
        )).snapshot(data: makeODS(
            manifestXML: compactManifest,
            contentXML: baseline
        ))
        expectOpenXMLError(.xmlNodeLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: .init(
                maxXMLNodeCount: 9
            )).snapshot(data: makeODS(
                manifestXML: compactManifest,
                contentXML: nestedNode
            ))
        }

        let nestedText = baseline.replacingOccurrences(
            of: "<t:table-cell/>",
            with: "<t:table-cell><t:table><p:p xmlns:p=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\">\(String(repeating: "x", count: 321))</p:p></t:table></t:table-cell>"
        )
        expectOpenXMLError(.textCharacterLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: .init(
                maxTextCharacterCount: 320
            )).snapshot(data: makeODS(
                manifestXML: compactManifest,
                contentXML: nestedText
            ))
        }

        let duplicateExpandedAttribute = baseline.replacingOccurrences(
            of: "<t:table-cell/>",
            with: "<t:table-cell><t:table xmlns:u=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" t:name=\"one\" u:name=\"two\"/></t:table-cell>"
        )
        expectOpenXMLError(.invalidOpenDocumentPackage) {
            _ = try engine.snapshot(data: makeODS(
                manifestXML: compactManifest,
                contentXML: duplicateExpandedAttribute
            ))
        }
    }

    @Test("ODS validates the final row and column reached by every span")
    func odsSpanEndpoints() throws {
        let exactBoundary = try makeODS(contentXML: odsContentXML(sheets: [
            odsSheetXML(
                name: "Exact",
                rows: "<table:table-row table:number-rows-repeated=\"2\"><table:table-cell table:number-columns-repeated=\"2\" table:number-rows-spanned=\"2\" table:number-columns-spanned=\"2\"/></table:table-row>"
            ),
        ]))
        let exactSnapshot = try OpenXMLComparisonEngine(limits: .init(
            maxSpreadsheetRowCount: 3,
            maxSpreadsheetColumnCount: 3
        )).snapshot(data: exactBoundary)
        #expect(exactSnapshot.sections.first?.cells.count == 4)

        let rowEndpoint = try makeODS(contentXML: odsContentXML(sheets: [
            odsSheetXML(
                name: "Rows",
                rows: "<table:table-row table:number-rows-repeated=\"3\"><table:table-cell table:number-rows-spanned=\"2\"/></table:table-row>"
            ),
        ]))
        expectOpenXMLError(.spreadsheetRowLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: .init(
                maxSpreadsheetRowCount: 3
            )).snapshot(data: rowEndpoint)
        }

        let columnEndpoint = try makeODS(contentXML: odsContentXML(sheets: [
            odsSheetXML(
                name: "Columns",
                rows: "<table:table-row><table:table-cell table:number-columns-repeated=\"3\" table:number-columns-spanned=\"2\"/></table:table-row>"
            ),
        ]))
        expectOpenXMLError(.spreadsheetColumnLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: .init(
                maxSpreadsheetColumnCount: 3
            )).snapshot(data: columnEndpoint)
        }
    }

    @Test("ODS accounts every published attribute and marker once using UTF-8 expansion bytes")
    func odsOutputAccounting() throws {
        let oneCell = try makeODS(contentXML: odsContentXML(sheets: [
            odsSheetXML(name: "S", rows: odsRowXML([odsCellXML(display: "x")])),
        ]))
        // Exact expanded-output accounting: sheet/row/cell overhead 224,
        // sheet title 1, cell fields 8, row marker 15, A1 2, section key 11,
        // declared-column marker 18, three part path+digest pairs 232, and
        // the fixed document type 3 = 514 bytes. Parsed XML text has its own
        // input counter and must not charge these published strings twice.
        let exact = try OpenXMLComparisonEngine(limits: .init(
            maxSpreadsheetExpandedByteCount: 514
        )).snapshot(data: oneCell)
        #expect(exact.sections.first?.cells.first?.displayValue == "x")
        expectOpenXMLError(.spreadsheetExpansionLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: .init(
                maxSpreadsheetExpandedByteCount: 513
            )).snapshot(data: oneCell)
        }

        let compactManifest = """
        <m:manifest xmlns:m="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"><m:file-entry m:full-path="/" m:media-type="application/vnd.oasis.opendocument.spreadsheet"/><m:file-entry m:full-path="content.xml" m:media-type="text/xml"/></m:manifest>
        """
        let formulaOnly = """
        <o:document-content xmlns:o="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:t="urn:oasis:names:tc:opendocument:xmlns:table:1.0"><o:body><o:spreadsheet><t:table t:name="S"><t:table-row><t:table-cell o:value-type="float" o:value="1" t:formula="of:=12345678901234567890"/></t:table-row></t:table></o:spreadsheet></o:body></o:document-content>
        """
        expectOpenXMLError(.textCharacterLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: .init(
                maxTextCharacterCount: 10
            )).snapshot(data: makeODS(
                manifestXML: compactManifest,
                contentXML: formulaOnly
            ))
        }

        let markerOnly = """
        <o:document-content xmlns:o="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:t="urn:oasis:names:tc:opendocument:xmlns:table:1.0"><o:body><o:spreadsheet><t:table t:name="S"/></o:spreadsheet></o:body></o:document-content>
        """
        expectOpenXMLError(.textCharacterLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: .init(
                maxTextCharacterCount: 20
            )).snapshot(data: makeODS(
                manifestXML: compactManifest,
                contentXML: markerOnly
            ))
        }

        let unicodeName = try makeODS(contentXML: odsContentXML(sheets: [
            odsSheetXML(name: String(repeating: "🧪", count: 20), rows: ""),
        ]))
        expectOpenXMLError(.spreadsheetExpansionLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: .init(
                maxSpreadsheetExpandedByteCount: 128
            )).snapshot(data: unicodeName)
        }
    }

    @Test("ODS inherits ZIP path, duplicate, CRC, encryption, and expansion-ratio rejection")
    func odsArchiveSafetyInheritance() throws {
        var traversalParts = odsParts()
        traversalParts.append(ZIPFixturePart(path: "../escape", data: Data("x".utf8)))
        expectOpenXMLError(.archiveRejected, detail: "invalidPath") {
            _ = try engine.snapshot(data: makeStoredZIP(traversalParts))
        }

        var duplicateParts = odsParts()
        duplicateParts.append(ZIPFixturePart(path: "content.xml", data: Data("duplicate".utf8)))
        expectOpenXMLError(.archiveRejected, detail: "duplicatePath") {
            _ = try engine.snapshot(data: makeStoredZIP(duplicateParts))
        }

        var damagedParts = odsParts()
        let contentIndex = try #require(damagedParts.firstIndex { $0.path == "content.xml" })
        damagedParts[contentIndex].declaredCRC32 = 0x1234_5678
        expectOpenXMLError(.archiveRejected, detail: "checksumMismatch") {
            _ = try engine.snapshot(data: makeStoredZIP(damagedParts))
        }

        var encryptedParts = odsParts()
        encryptedParts[contentIndex].flags |= 1
        expectOpenXMLError(.archiveRejected, detail: "encryptedEntry") {
            _ = try engine.snapshot(data: makeStoredZIP(encryptedParts))
        }

        var compressedParts = odsParts(contentXML: odsContentXML(sheets: [
            odsSheetXML(
                name: "Ratio",
                rows: odsRowXML([odsCellXML(display: String(repeating: "a", count: 20_000))])
            ),
        ]))
        let compressedIndex = try #require(compressedParts.firstIndex { $0.path == "content.xml" })
        compressedParts[compressedIndex].deflated = true
        let compressedPackage = try makeStoredZIP(compressedParts)
        expectOpenXMLError(.archiveRejected, detail: "expansionRatioLimitExceeded") {
            _ = try OpenXMLComparisonEngine(limits: .init(
                maxExpansionRatio: 1
            )).snapshot(data: compressedPackage)
        }
    }

    @Test("ODS recognition is content-only while ordinary ZIP and partial ODS fail closed")
    func odsContentDetection() throws {
        let renamedBytes = try makeODS()
        #expect(try engine.snapshot(data: renamedBytes).documentType == .openDocumentSpreadsheet)

        let ordinary = try makeStoredZIP([
            ZIPFixturePart(path: "hello.txt", data: Data("ordinary zip renamed .ods".utf8)),
        ])
        expectOpenXMLError(.invalidPackage) {
            _ = try engine.snapshot(data: ordinary)
        }

        let partial = try makeStoredZIP([
            ZIPFixturePart(
                path: "mimetype",
                data: Data("application/vnd.oasis.opendocument.spreadsheet".utf8)
            ),
            ZIPFixturePart(path: "content.xml", data: Data(odsContentXML().utf8)),
        ])
        expectOpenXMLError(.invalidOpenDocumentPackage) {
            _ = try engine.snapshot(data: partial)
        }
    }

    @Test("ODS validates mimetype storage sizes before reading the member")
    func odsMimetypeStorageDeclaration() throws {
        let expectedMimetype = "application/vnd.oasis.opendocument.spreadsheet"
        expectOpenXMLError(.invalidOpenDocumentPackage) {
            _ = try engine.snapshot(data: makeODS(
                mimetype: String(expectedMimetype.dropLast())
            ))
        }
        expectOpenXMLError(.invalidOpenDocumentPackage) {
            _ = try engine.snapshot(data: makeODS(
                mimetype: expectedMimetype + "x"
            ))
        }

        var compressedMimetype = odsParts()
        compressedMimetype[0].deflated = true
        expectOpenXMLError(.invalidOpenDocumentPackage) {
            _ = try engine.snapshot(data: makeStoredZIP(compressedMimetype))
        }
    }

    @Test("ODS preserves CancellationError for pre-cancelled work and repeat checkpoints")
    func odsCancellationPropagation() async throws {
        let ignoredNested = try makeODS(contentXML: odsContentXML(sheets: [
            odsSheetXML(
                name: "Cancelled",
                rows: "<table:table-row><table:table-cell><table:table><table:table-row table:number-rows-repeated=\"1000001\"/></table:table></table:table-cell></table:table-row>"
            ),
        ]))
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try engine.snapshot(data: ignoredNested)
        }
        do {
            _ = try await preCancelled.value
            Issue.record("A pre-cancelled ODS snapshot unexpectedly completed")
        } catch is CancellationError {
            // Expected: the public engine must not redact cancellation as invalidPackage.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }

        let repeated = try makeODS(contentXML: odsContentXML(sheets: [
            odsSheetXML(
                name: "Cancellation",
                rows: "<table:table-row table:number-rows-repeated=\"2\"><table:table-cell office:value-type=\"string\" office:string-value=\"x\"><text:p>x</text:p></table:table-cell></table:table-row>"
            ),
        ]))
        let checkpointCancelled = Task {
            let hook: @Sendable (Int) -> Void = { iteration in
                if iteration == 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            return try ODSCancellation.$checkpointHook.withValue(hook) {
                try engine.snapshot(data: repeated)
            }
        }
        do {
            _ = try await checkpointCancelled.value
            Issue.record("An ODS repeat checkpoint ignored cancellation")
        } catch is CancellationError {
            // Expected: the iteration-zero repeat checkpoint self-cancelled.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
    }

    @Test("PPTX follows ordered slide relationships and extracts DrawingML text")
    func pptxHappyPath() throws {
        let package = try makePPTX(slides: [
            ["标题", "第一张"],
            ["第二张", "结论"],
        ])
        let snapshot = try engine.snapshot(data: package)

        #expect(snapshot.documentType == .presentation)
        #expect(snapshot.sections.map(\.key) == ["slide.1", "slide.2"])
        #expect(snapshot.sections.map(\.title) == ["标题", "第二张"])
        #expect(snapshot.sections[1].textBlocks == ["第二张", "结论"])
    }

    @Test("All document families compare deterministically with same, different, and one-sided rows")
    func comparisonsAreDeterministic() throws {
        let pairs: [(Data, Data)] = [
            (
                try makeDOCX(paragraphs: ["same", "left"]),
                try makeDOCX(paragraphs: ["same", "right", "new"])
            ),
            (
                try makeXLSX(cells: [XLSXTestCell(reference: "A1", value: "1")]),
                try makeXLSX(cells: [XLSXTestCell(reference: "A1", value: "2")])
            ),
            (
                try makePPTX(slides: [["old"]]),
                try makePPTX(slides: [["new"], ["right only"]])
            ),
        ]

        for (left, right) in pairs {
            let first = try engine.compare(left: left, right: right)
            let second = try engine.compare(left: left, right: right)
            #expect(first == second)
            #expect(first.hasDifferences)
            #expect(first.rows.contains { $0.status == .different })
            #expect(first.statistics.totalCount == first.rows.count)
            #expect(
                first.statistics.sameCount
                    + first.statistics.differentCount
                    + first.statistics.leftOnlyCount
                    + first.statistics.rightOnlyCount
                    == first.statistics.totalCount
            )
        }

        let identical = try engine.compare(left: pairs[0].0, right: pairs[0].0)
        #expect(!identical.hasDifferences)
        #expect(identical.rows.allSatisfy { $0.status == .same })

        let manualLeft = OpenXMLDocumentSnapshot(
            documentType: .wordProcessingDocument,
            coreProperties: .init(),
            sections: [OpenXMLLogicalSection(key: "paragraph.1", kind: .paragraph, textBlocks: ["left"])],
            parts: []
        )
        let manualRight = OpenXMLDocumentSnapshot(
            documentType: .wordProcessingDocument,
            coreProperties: .init(),
            sections: [OpenXMLLogicalSection(key: "paragraph.2", kind: .paragraph, textBlocks: ["right"])],
            parts: []
        )
        let oneSided = engine.compare(left: manualLeft, right: manualRight)
        #expect(oneSided.rows.contains { $0.key == "section.paragraph.1" && $0.status == .leftOnly })
        #expect(oneSided.rows.contains { $0.key == "section.paragraph.2" && $0.status == .rightOnly })
    }

    @Test("OPC relationship targets cannot escape the package root, including percent encoding")
    func relationshipTraversal() throws {
        for target in ["../../escape.xml", "%2e%2e/%2e%2e/escape.xml", "C:/escape.xml", "..\\escape.xml"] {
            let package = try makeDOCX(rootOfficeTarget: target)
            expectOpenXMLError(.relationshipTraversal) {
                _ = try engine.snapshot(data: package)
            }
        }
    }

    @Test("DOCTYPE and entity declarations are rejected before XML parsing")
    func doctypeRejected() throws {
        let malicious = """
        <?xml version="1.0"?>
        <!DOCTYPE w:document [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>&xxe;</w:t></w:r></w:p></w:body></w:document>
        """
        let package = try makeDOCX(mainDocumentOverride: malicious)
        expectOpenXMLError(.forbiddenDTD) {
            _ = try engine.snapshot(data: package)
        }
    }

    @Test("Ordinary ZIPs and packages with missing or unsupported main parts are rejected")
    func packageIdentityValidation() throws {
        let ordinary = try makeStoredZIP([ZIPFixturePart(path: "hello.txt", data: Data("zip".utf8))])
        expectOpenXMLError(.invalidPackage) {
            _ = try engine.snapshot(data: ordinary)
        }

        let missing = try makeDOCX(omitMainPart: true)
        expectOpenXMLError(.danglingRelationship) {
            _ = try engine.snapshot(data: missing)
        }

        let unsupported = try makePackage(
            mainPath: "custom/main.xml",
            mainContentType: "application/x-not-office+xml",
            mainXML: "<root/>"
        )
        expectOpenXMLError(.unsupportedDocumentType) {
            _ = try engine.snapshot(data: unsupported)
        }
    }

    @Test("Archive encryption and CRC damage surface as redacted archive rejection codes")
    func archiveIntegrity() throws {
        var encryptedParts = try docxParts(paragraphs: ["secret"])
        encryptedParts[0].flags = 1
        let encrypted = try makeStoredZIP(encryptedParts)
        expectOpenXMLError(.archiveRejected, detail: "encryptedEntry") {
            _ = try engine.snapshot(data: encrypted)
        }

        var damagedParts = try docxParts(paragraphs: ["checksum"])
        let mainIndex = try #require(damagedParts.firstIndex { $0.path == "word/document.xml" })
        damagedParts[mainIndex].declaredCRC32 = 0x1234_5678
        let damaged = try makeStoredZIP(damagedParts)
        expectOpenXMLError(.archiveRejected, detail: "checksumMismatch") {
            _ = try engine.snapshot(data: damaged)
        }
    }

    @Test("XML byte, node, text, logical item, and slide limits fail closed")
    func parsingLimits() throws {
        var oversizedParts = try docxParts(paragraphs: ["ok"])
        oversizedParts.append(ZIPFixturePart(
            path: "custom/oversized.xml",
            data: Data(repeating: 0x20, count: 1_025)
        ))
        let oversized = try makeStoredZIP(oversizedParts)
        let sizeLimits = try OpenXMLComparisonLimits(maxSingleXMLPartByteCount: 1_024)
        expectOpenXMLError(.xmlPartSizeLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: sizeLimits).snapshot(data: oversized)
        }

        let docx = try makeDOCX(paragraphs: ["one", "two", "three"])
        let totalSizeLimits = try OpenXMLComparisonLimits(
            maxSingleXMLPartByteCount: 1_024,
            maxTotalXMLByteCount: 1_024
        )
        expectOpenXMLError(.totalXMLSizeLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: totalSizeLimits).snapshot(data: docx)
        }

        let partCountLimits = try OpenXMLComparisonLimits(maxXMLPartCount: 3)
        expectOpenXMLError(.xmlPartCountLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: partCountLimits).snapshot(data: docx)
        }

        let nodeLimits = try OpenXMLComparisonLimits(maxXMLNodeCount: 4)
        expectOpenXMLError(.xmlNodeLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: nodeLimits).snapshot(data: docx)
        }

        let textLimits = try OpenXMLComparisonLimits(maxTextCharacterCount: 4)
        expectOpenXMLError(.textCharacterLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: textLimits).snapshot(data: docx)
        }

        let logicalLimits = try OpenXMLComparisonLimits(maxLogicalItemCount: 1)
        expectOpenXMLError(.logicalItemLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: logicalLimits).snapshot(data: docx)
        }

        let slides = try makePPTX(slides: [["one"], ["two"]])
        let slideLimits = try OpenXMLComparisonLimits(maxWorksheetOrSlideCount: 1)
        expectOpenXMLError(.worksheetOrSlideLimitExceeded) {
            _ = try OpenXMLComparisonEngine(limits: slideLimits).snapshot(data: slides)
        }
    }

    @Test("Invalid limits and invalid limits decoded from JSON cannot bypass validation")
    func strictLimitValidation() throws {
        expectOpenXMLError(.invalidLimits) {
            _ = try OpenXMLComparisonLimits(maxXMLNodeCount: 0)
        }
        expectOpenXMLError(.invalidLimits) {
            _ = try OpenXMLComparisonLimits(maxExpansionRatio: .infinity)
        }
        expectOpenXMLError(.invalidLimits) {
            _ = try OpenXMLComparisonLimits(
                maxPartByteCount: 16,
                maxSingleXMLPartByteCount: 17
            )
        }

        let validJSON = try JSONEncoder().encode(OpenXMLComparisonLimits.default)
        let invalidJSON = String(decoding: validJSON, as: UTF8.self)
            .replacingOccurrences(of: "\"maxXMLNodeCount\":2000000", with: "\"maxXMLNodeCount\":0")
        expectOpenXMLError(.invalidLimits) {
            _ = try JSONDecoder().decode(
                OpenXMLComparisonLimits.self,
                from: Data(invalidJSON.utf8)
            )
        }
    }

    @Test("Snapshots and comparison DTOs are strict Sendable across task boundaries")
    func sendableDTOs() async throws {
        let result = try engine.compare(
            left: makeDOCX(paragraphs: ["left"]),
            right: makeDOCX(paragraphs: ["right"])
        )
        requireOpenXMLSendable(result)
        let copied = await Task.detached { @Sendable in result }.value
        #expect(copied == result)
    }
}

private func expectOpenXMLError<T>(
    _ code: OpenXMLComparisonError.Code,
    detail: String? = nil,
    operation: () throws -> T
) {
    do {
        _ = try operation()
        Issue.record("Expected OpenXMLComparisonError.\(code.rawValue)")
    } catch let error as OpenXMLComparisonError {
        #expect(error.code == code)
        if let detail { #expect(error.detail == detail) }
        #expect(!(error.errorDescription ?? "").contains("/Users/"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func requireOpenXMLSendable<T: Sendable>(_ value: T) {}

private struct XLSXTestCell {
    let reference: String
    let type: String?
    let value: String
    let formula: String?

    init(reference: String, type: String? = nil, value: String, formula: String? = nil) {
        self.reference = reference
        self.type = type
        self.value = value
        self.formula = formula
    }
}

private func makeDOCX(
    title: String = "Document",
    creator: String = "Tester",
    paragraphs: [String] = ["Hello"],
    tableRows: [[String]] = [],
    extraParts: [String: Data] = [:],
    rootOfficeTarget: String = "word/document.xml",
    mainDocumentOverride: String? = nil,
    omitMainPart: Bool = false
) throws -> Data {
    var parts = try docxParts(
        title: title,
        creator: creator,
        paragraphs: paragraphs,
        tableRows: tableRows,
        rootOfficeTarget: rootOfficeTarget,
        mainDocumentOverride: mainDocumentOverride,
        omitMainPart: omitMainPart
    )
    parts.append(contentsOf: extraParts.sorted { $0.key < $1.key }.map {
        ZIPFixturePart(path: $0.key, data: $0.value)
    })
    return try makeStoredZIP(parts)
}

private func docxParts(
    title: String = "Document",
    creator: String = "Tester",
    paragraphs: [String] = ["Hello"],
    tableRows: [[String]] = [],
    rootOfficeTarget: String = "word/document.xml",
    mainDocumentOverride: String? = nil,
    omitMainPart: Bool = false
) throws -> [ZIPFixturePart] {
    let contentTypes = contentTypesXML(
        mainPath: "word/document.xml",
        mainContentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
        additionalOverrides: []
    )
    let relationships = rootRelationshipsXML(officeTarget: rootOfficeTarget)
    var body = paragraphs.dropLast(tableRows.isEmpty ? 0 : 1).map { paragraphXML($0) }.joined()
    if !tableRows.isEmpty {
        body += "<w:tbl>" + tableRows.map { row in
            "<w:tr>" + row.map { "<w:tc>\(paragraphXML($0))</w:tc>" }.joined() + "</w:tr>"
        }.joined() + "</w:tbl>"
        if let last = paragraphs.last { body += paragraphXML(last) }
    }
    let main = mainDocumentOverride ?? """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
    """
    var parts = [
        ZIPFixturePart(path: "[Content_Types].xml", data: Data(contentTypes.utf8)),
        ZIPFixturePart(path: "_rels/.rels", data: Data(relationships.utf8)),
        ZIPFixturePart(path: "docProps/core.xml", data: Data(corePropertiesXML(title: title, creator: creator).utf8)),
    ]
    if !omitMainPart {
        parts.append(ZIPFixturePart(path: "word/document.xml", data: Data(main.utf8)))
    }
    return parts
}

private func makeXLSX(
    sheetName: String = "Sheet 1",
    sharedStrings: [String] = [],
    cells: [XLSXTestCell] = [XLSXTestCell(reference: "A1", value: "1")]
) throws -> Data {
    let workbook = """
    <?xml version="1.0" encoding="UTF-8"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(xmlEscape(sheetName))" sheetId="1" r:id="rId1"/></sheets></workbook>
    """
    var workbookRelations = [
        relationshipXML(id: "rId1", type: "worksheet", target: "worksheets/sheet1.xml")
    ]
    if !sharedStrings.isEmpty {
        workbookRelations.append(relationshipXML(id: "rIdShared", type: "sharedStrings", target: "sharedStrings.xml"))
    }
    let rels = relationshipsXML(workbookRelations)
    let cellXML = cells.map { cell -> String in
        let type = cell.type.map { " t=\"\(xmlEscape($0))\"" } ?? ""
        let formula = cell.formula.map { "<f>\(xmlEscape($0))</f>" } ?? ""
        if cell.type == "inlineStr" {
            return "<c r=\"\(xmlEscape(cell.reference))\"\(type)>\(formula)<is><t>\(xmlEscape(cell.value))</t></is></c>"
        }
        return "<c r=\"\(xmlEscape(cell.reference))\"\(type)>\(formula)<v>\(xmlEscape(cell.value))</v></c>"
    }.joined()
    let worksheet = """
    <?xml version="1.0" encoding="UTF-8"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1">\(cellXML)</row></sheetData></worksheet>
    """
    var overrides = [
        ("/xl/worksheets/sheet1.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml")
    ]
    if !sharedStrings.isEmpty {
        overrides.append(("/xl/sharedStrings.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"))
    }
    let contentTypes = contentTypesXML(
        mainPath: "xl/workbook.xml",
        mainContentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
        additionalOverrides: overrides
    )
    var parts = [
        ZIPFixturePart(path: "[Content_Types].xml", data: Data(contentTypes.utf8)),
        ZIPFixturePart(path: "_rels/.rels", data: Data(rootRelationshipsXML(officeTarget: "xl/workbook.xml").utf8)),
        ZIPFixturePart(path: "docProps/core.xml", data: Data(corePropertiesXML(title: "Workbook", creator: "Tester").utf8)),
        ZIPFixturePart(path: "xl/workbook.xml", data: Data(workbook.utf8)),
        ZIPFixturePart(path: "xl/_rels/workbook.xml.rels", data: Data(rels.utf8)),
        ZIPFixturePart(path: "xl/worksheets/sheet1.xml", data: Data(worksheet.utf8)),
    ]
    if !sharedStrings.isEmpty {
        let contents = sharedStrings.map { "<si><t>\(xmlEscape($0))</t></si>" }.joined()
        let shared = "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\(contents)</sst>"
        parts.append(ZIPFixturePart(path: "xl/sharedStrings.xml", data: Data(shared.utf8)))
    }
    return try makeStoredZIP(parts)
}

private func makePPTX(slides: [[String]]) throws -> Data {
    let slideIDs = slides.indices.map { index in
        "<p:sldId id=\"\(256 + index)\" r:id=\"rId\(index + 1)\"/>"
    }.joined()
    let presentation = """
    <?xml version="1.0" encoding="UTF-8"?>
    <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst>\(slideIDs)</p:sldIdLst></p:presentation>
    """
    let rels = relationshipsXML(slides.indices.map { index in
        relationshipXML(id: "rId\(index + 1)", type: "slide", target: "slides/slide\(index + 1).xml")
    })
    let overrides = slides.indices.map { index in
        ("/ppt/slides/slide\(index + 1).xml", "application/vnd.openxmlformats-officedocument.presentationml.slide+xml")
    }
    let contentTypes = contentTypesXML(
        mainPath: "ppt/presentation.xml",
        mainContentType: "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
        additionalOverrides: overrides
    )
    var parts = [
        ZIPFixturePart(path: "[Content_Types].xml", data: Data(contentTypes.utf8)),
        ZIPFixturePart(path: "_rels/.rels", data: Data(rootRelationshipsXML(officeTarget: "ppt/presentation.xml").utf8)),
        ZIPFixturePart(path: "docProps/core.xml", data: Data(corePropertiesXML(title: "Slides", creator: "Tester").utf8)),
        ZIPFixturePart(path: "ppt/presentation.xml", data: Data(presentation.utf8)),
        ZIPFixturePart(path: "ppt/_rels/presentation.xml.rels", data: Data(rels.utf8)),
    ]
    for (index, textBlocks) in slides.enumerated() {
        let text = textBlocks.map { "<a:p><a:r><a:t>\(xmlEscape($0))</a:t></a:r></a:p>" }.joined()
        let slide = """
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree>\(text)</p:spTree></p:cSld></p:sld>
        """
        parts.append(ZIPFixturePart(path: "ppt/slides/slide\(index + 1).xml", data: Data(slide.utf8)))
    }
    return try makeStoredZIP(parts)
}

private func makePackage(
    mainPath: String,
    mainContentType: String,
    mainXML: String
) throws -> Data {
    try makeStoredZIP([
        ZIPFixturePart(
            path: "[Content_Types].xml",
            data: Data(contentTypesXML(mainPath: mainPath, mainContentType: mainContentType, additionalOverrides: []).utf8)
        ),
        ZIPFixturePart(path: "_rels/.rels", data: Data(rootRelationshipsXML(officeTarget: mainPath).utf8)),
        ZIPFixturePart(path: "docProps/core.xml", data: Data(corePropertiesXML(title: "Title", creator: "Creator").utf8)),
        ZIPFixturePart(path: mainPath, data: Data(mainXML.utf8)),
    ])
}

private func contentTypesXML(
    mainPath: String,
    mainContentType: String,
    additionalOverrides: [(String, String)]
) -> String {
    let overrides = ([
        ("/\(mainPath)", mainContentType),
        ("/docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml"),
    ] + additionalOverrides).map {
        "<Override PartName=\"\(xmlEscape($0.0))\" ContentType=\"\(xmlEscape($0.1))\"/>"
    }.joined()
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>\(overrides)</Types>
    """
}

private func rootRelationshipsXML(officeTarget: String) -> String {
    relationshipsXML([
        relationshipXML(id: "rIdOffice", type: "officeDocument", target: officeTarget),
        relationshipXML(id: "rIdCore", type: "metadata/core-properties", target: "docProps/core.xml"),
    ])
}

private func relationshipsXML(_ relationships: [String]) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relationships.joined())</Relationships>
    """
}

private func relationshipXML(id: String, type: String, target: String) -> String {
    "<Relationship Id=\"\(xmlEscape(id))\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(xmlEscape(type))\" Target=\"\(xmlEscape(target))\"/>"
}

private func corePropertiesXML(title: String, creator: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/"><dc:title>\(xmlEscape(title))</dc:title><dc:creator>\(xmlEscape(creator))</dc:creator><cp:lastModifiedBy>Editor</cp:lastModifiedBy><dcterms:created>2026-07-19T00:00:00Z</dcterms:created><dcterms:modified>2026-07-19T01:00:00Z</dcterms:modified></cp:coreProperties>
    """
}

private func paragraphXML(_ value: String) -> String {
    "<w:p><w:r><w:t>\(xmlEscape(value))</w:t></w:r></w:p>"
}

private func xmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

private func makeODS(
    mimetype: String = "application/vnd.oasis.opendocument.spreadsheet",
    manifestXML: String = odsManifestXML(),
    contentXML: String = odsContentXML(),
    metadataXML: String? = nil,
    extraParts: [ZIPFixturePart] = []
) throws -> Data {
    try makeStoredZIP(odsParts(
        mimetype: mimetype,
        manifestXML: manifestXML,
        contentXML: contentXML,
        metadataXML: metadataXML,
        extraParts: extraParts
    ))
}

private func odsParts(
    mimetype: String = "application/vnd.oasis.opendocument.spreadsheet",
    manifestXML: String = odsManifestXML(),
    contentXML: String = odsContentXML(),
    metadataXML: String? = nil,
    extraParts: [ZIPFixturePart] = []
) -> [ZIPFixturePart] {
    var parts = [
        ZIPFixturePart(path: "mimetype", data: Data(mimetype.utf8)),
        ZIPFixturePart(path: "META-INF/manifest.xml", data: Data(manifestXML.utf8)),
        ZIPFixturePart(path: "content.xml", data: Data(contentXML.utf8)),
    ]
    if let metadataXML {
        parts.append(ZIPFixturePart(path: "meta.xml", data: Data(metadataXML.utf8)))
    }
    parts.append(contentsOf: extraParts)
    return parts
}

private func odsManifestXML(
    rootMediaType: String = "application/vnd.oasis.opendocument.spreadsheet",
    extra: String = ""
) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">
      <manifest:file-entry manifest:full-path="/" manifest:media-type="\(xmlEscape(rootMediaType))"/>
      <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
      \(extra)
    </manifest:manifest>
    """
}

private func odsContentXML(sheets: [String] = [odsSheetXML(name: "Sheet1")]) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document-content
      xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
      xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
      xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
      xmlns:xlink="http://www.w3.org/1999/xlink"
      office:version="1.3">
      <office:scripts><office:script xlink:href="https://example.invalid/not-fetched"/></office:scripts>
      <office:body><office:spreadsheet>\(sheets.joined())</office:spreadsheet></office:body>
    </office:document-content>
    """
}

private func odsSheetXML(
    name: String,
    declaredColumns: Int = 0,
    rows: String = odsRowXML([odsCellXML(display: "1")])
) -> String {
    let columns = declaredColumns > 0
        ? "<table:table-column table:number-columns-repeated=\"\(declaredColumns)\"/>"
        : ""
    return """
    <table:table table:name="\(xmlEscape(name))">\(columns)\(rows)</table:table>
    """
}

private func odsRowXML(_ cells: [String]) -> String {
    "<table:table-row>\(cells.joined())</table:table-row>"
}

private func odsCellXML(
    display: String,
    valueType: String = "string",
    typedValue: String? = nil,
    formula: String? = nil
) -> String {
    let valueAttribute: String
    switch valueType {
    case "boolean":
        valueAttribute = " office:boolean-value=\"\(xmlEscape(typedValue ?? "false"))\""
    case "date":
        valueAttribute = " office:date-value=\"\(xmlEscape(typedValue ?? "1970-01-01"))\""
    case "time":
        valueAttribute = " office:time-value=\"\(xmlEscape(typedValue ?? "PT0S"))\""
    case "string":
        valueAttribute = " office:string-value=\"\(xmlEscape(typedValue ?? display))\""
    default:
        valueAttribute = " office:value=\"\(xmlEscape(typedValue ?? display))\""
    }
    let formulaAttribute = formula.map {
        " table:formula=\"\(xmlEscape($0))\""
    } ?? ""
    return """
    <table:table-cell office:value-type="\(xmlEscape(valueType))"\(valueAttribute)\(formulaAttribute)><text:p>\(xmlEscape(display))</text:p></table:table-cell>
    """
}

private func odsMetadataXML(title: String, creator: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><office:meta><dc:title>\(xmlEscape(title))</dc:title><meta:initial-creator>\(xmlEscape(creator))</meta:initial-creator><meta:creation-date>2026-07-19T00:00:00Z</meta:creation-date></office:meta></office:document-meta>
    """
}

private struct ZIPFixturePart {
    let path: String
    let data: Data
    var flags: UInt16 = 0x0800
    var declaredCRC32: UInt32?
    var deflated = false
}

private func makeStoredZIP(_ parts: [ZIPFixturePart]) throws -> Data {
    struct CentralRecord {
        let part: ZIPFixturePart
        let name: Data
        let compressed: Data
        let method: UInt16
        let crc32: UInt32
        let offset: UInt32
    }
    guard parts.count <= Int(UInt16.max) else { throw CocoaError(.coderInvalidValue) }
    var archive = Data()
    var central: [CentralRecord] = []
    for part in parts {
        let name = Data(part.path.utf8)
        guard name.count <= Int(UInt16.max),
              part.data.count <= Int(UInt32.max),
              archive.count <= Int(UInt32.max) else {
            throw CocoaError(.coderInvalidValue)
        }
        let compressed = part.deflated ? try odsRawDeflate(part.data) : part.data
        let method: UInt16 = part.deflated ? 8 : 0
        let crc = part.declaredCRC32 ?? zipFixtureCRC32(part.data)
        let offset = UInt32(archive.count)
        archive.appendZIPLE(UInt32(0x0403_4b50))
        archive.appendZIPLE(UInt16(20))
        archive.appendZIPLE(part.flags)
        archive.appendZIPLE(method)
        archive.appendZIPLE(UInt16(0))
        archive.appendZIPLE(UInt16(0))
        archive.appendZIPLE(crc)
        archive.appendZIPLE(UInt32(compressed.count))
        archive.appendZIPLE(UInt32(part.data.count))
        archive.appendZIPLE(UInt16(name.count))
        archive.appendZIPLE(UInt16(0))
        archive.append(name)
        archive.append(compressed)
        central.append(CentralRecord(
            part: part,
            name: name,
            compressed: compressed,
            method: method,
            crc32: crc,
            offset: offset
        ))
    }
    let centralOffset = archive.count
    for record in central {
        archive.appendZIPLE(UInt32(0x0201_4b50))
        archive.appendZIPLE(UInt16(3 << 8 | 20))
        archive.appendZIPLE(UInt16(20))
        archive.appendZIPLE(record.part.flags)
        archive.appendZIPLE(record.method)
        archive.appendZIPLE(UInt16(0))
        archive.appendZIPLE(UInt16(0))
        archive.appendZIPLE(record.crc32)
        archive.appendZIPLE(UInt32(record.compressed.count))
        archive.appendZIPLE(UInt32(record.part.data.count))
        archive.appendZIPLE(UInt16(record.name.count))
        archive.appendZIPLE(UInt16(0))
        archive.appendZIPLE(UInt16(0))
        archive.appendZIPLE(UInt16(0))
        archive.appendZIPLE(UInt16(0))
        archive.appendZIPLE(UInt32(0o100644 << 16))
        archive.appendZIPLE(record.offset)
        archive.append(record.name)
    }
    let centralSize = archive.count - centralOffset
    archive.appendZIPLE(UInt32(0x0605_4b50))
    archive.appendZIPLE(UInt16(0))
    archive.appendZIPLE(UInt16(0))
    archive.appendZIPLE(UInt16(parts.count))
    archive.appendZIPLE(UInt16(parts.count))
    archive.appendZIPLE(UInt32(centralSize))
    archive.appendZIPLE(UInt32(centralOffset))
    archive.appendZIPLE(UInt16(0))
    return archive
}

private func odsRawDeflate(_ input: Data) throws -> Data {
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
    guard status == Z_STREAM_END else { throw CocoaError(.coderInvalidValue) }
    output.count = Int(stream.total_out)
    return output
}

private func zipFixtureCRC32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
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
    mutating func appendZIPLE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendZIPLE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
