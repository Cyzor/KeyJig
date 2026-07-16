// SVGProcessingTests.swift
// Tests for SVG parsing, validation, ingest gating, dimension extraction,
// content-derived naming, and the Keynote sanitizer in SVGProcessing.swift.

import XCTest

final class SVGProcessingTests: XCTestCase {

    // MARK: - File-type sniffing

    private func writeTemp(_ data: Data, ext: String = "dat") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyJigTests-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSniffDetectsPDFMagic() throws {
        let url = try writeTemp(Data("%PDF-1.4 rest of file".utf8))
        XCTAssertEqual(sniffVectorFileType(at: url), "pdf")
    }

    func testSniffDetectsLegacyAIPostScript() throws {
        let url = try writeTemp(Data("%!PS-Adobe-3.0".utf8))
        XCTAssertEqual(sniffVectorFileType(at: url), "ai")
    }

    func testSniffDetectsSVGInUTF8AndUTF16() throws {
        let svg = "<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\"/>"
        XCTAssertEqual(sniffVectorFileType(at: try writeTemp(Data(svg.utf8))), "svg")
        let utf16 = svg.data(using: .utf16)!  // BOM-carrying
        XCTAssertEqual(sniffVectorFileType(at: try writeTemp(utf16)), "svg")
    }

    func testSniffRejectsUnknownContent() throws {
        let url = try writeTemp(Data("hello world".utf8))
        XCTAssertNil(sniffVectorFileType(at: url))
        XCTAssertNil(sniffVectorFileType(at: try writeTemp(Data())))
    }

    // MARK: - Validation

    func testValidateAcceptsPlainSVG() {
        XCTAssertNil(validateSVG("<svg viewBox=\"0 0 10 10\"><rect/></svg>"))
    }

    func testValidateRejectsEmptyAndNonSVG() {
        XCTAssertEqual(validateSVG(""), .empty)
        XCTAssertEqual(validateSVG("<html>nope</html>"), .notSVGElement)
    }

    func testValidateRejectsScriptsAndEventHandlers() {
        XCTAssertEqual(
            validateSVG("<svg><script>alert(1)</script></svg>"), .containsDangerousContent)
        XCTAssertEqual(
            validateSVG("<svg><rect onload=\"evil()\"/></svg>"), .containsDangerousContent)
        XCTAssertEqual(
            validateSVG("<svg><a href=\"javascript:evil()\">x</a></svg>"),
            .containsDangerousContent)
    }

    func testValidateRejectsRemoteReferencesButAllowsNamespaceDeclarations() {
        XCTAssertEqual(
            validateSVG("<svg><image xlink:href=\"http://evil.example/x.png\"/></svg>"),
            .containsDangerousContent)
        // xmlns:xlink declarations contain a URL but no href= attribute — allowed.
        XCTAssertNil(
            validateSVG("<svg xmlns:xlink=\"http://www.w3.org/1999/xlink\"><rect/></svg>"))
    }

    // MARK: - Ingest gate

    func testIngestAppliesEdgeMargin() throws {
        let svg = "<svg viewBox=\"0 0 100 50\" width=\"100\" height=\"50\"><rect/></svg>"
        let out = try XCTUnwrap(ingestSVG(svg))
        XCTAssertTrue(out.contains("viewBox=\"-5 -5 110 60\""))
        XCTAssertTrue(out.contains("width=\"110\""))
        XCTAssertTrue(out.contains("height=\"60\""))
    }

    func testCheckedIngestReportsReasons() {
        guard case .failure(.notSVG) = checkedIngestSVG("just text") else {
            return XCTFail("non-SVG input must fail as .notSVG")
        }
        guard case .failure(.unsafe) = checkedIngestSVG("<svg><script/></svg>") else {
            return XCTFail("hostile SVG must fail as .unsafe")
        }
        let huge = "<svg>" + String(repeating: "x", count: maxSVGBytes) + "</svg>"
        guard case .failure(.tooLarge) = checkedIngestSVG(huge) else {
            return XCTFail("oversized SVG must fail as .tooLarge")
        }
        // Hostile content near the head outranks the size verdict.
        let hugeHostile = "<svg><script>x</script>" + huge
        guard case .failure(.unsafe) = checkedIngestSVG(hugeHostile) else {
            return XCTFail("oversized hostile SVG must fail as .unsafe")
        }
    }

    func testCheckedIngestRejectsOversizedInputQuickly() {
        // Regression guard: the content screen must not scan the full body of
        // an oversized payload (~1 s/MB) before rejecting it.
        let huge = "<svg>" + String(repeating: "x", count: maxSVGBytes) + "</svg>"
        let start = Date()
        _ = checkedIngestSVG(huge)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
    }

    func testReadSVGFileAcceptsUTF8AndUTF16() throws {
        let svg = "<svg viewBox=\"0 0 1 1\"/>"
        let utf8URL = try writeTemp(Data(svg.utf8), ext: "svg")
        XCTAssertEqual(try readSVGFile(at: utf8URL), svg)
        let utf16URL = try writeTemp(svg.data(using: .utf16)!, ext: "svg")
        XCTAssertEqual(try readSVGFile(at: utf16URL), svg)
    }

    // MARK: - Dimensions

    func testDimensionsPreferViewBox() {
        let svg = "<svg viewBox=\"0 0 300 150\" width=\"12\" height=\"34\"/>"
        let dims = extractSVGDimensions(svgString: svg)
        XCTAssertEqual(dims?.width, 300)
        XCTAssertEqual(dims?.height, 150)
    }

    func testDimensionsAcceptCommaSeparatedViewBox() {
        let dims = extractSVGDimensions(svgString: "<svg viewBox=\"0,0,640,480\"/>")
        XCTAssertEqual(dims?.width, 640)
        XCTAssertEqual(dims?.height, 480)
    }

    func testDimensionsFallBackToWidthHeightAttributes() {
        let dims = extractSVGDimensions(svgString: "<svg width=\"88\" height=\"44\"/>")
        XCTAssertEqual(dims?.width, 88)
        XCTAssertEqual(dims?.height, 44)
        XCTAssertNil(extractSVGDimensions(svgString: "<svg/>"))
    }

    // MARK: - Content-derived naming

    func testNameHintPrefersTitle() {
        let svg = "<svg><title>Quarterly Sales Chart</title><text>ignored</text></svg>"
        XCTAssertEqual(extractSVGNameHint(svgString: svg), "Quarterly-Sales-Chart")
    }

    func testNameHintReadsInkscapeDocname() {
        let svg = "<svg sodipodi:docname=\"company logo.svg\"><rect/></svg>"
        XCTAssertEqual(extractSVGNameHint(svgString: svg), "company-logo")
    }

    func testNameHintFallsBackToTextContentFlatteningTspans() {
        let svg = "<svg><text><tspan>Annual</tspan> <tspan>Report</tspan></text></svg>"
        XCTAssertEqual(extractSVGNameHint(svgString: svg), "Annual-Report")
    }

    func testNameHintRejectsGenericPlaceholders() {
        XCTAssertNil(extractSVGNameHint(svgString: "<svg><title>Untitled drawing</title></svg>"))
        XCTAssertNil(extractSVGNameHint(svgString: "<svg><rect/></svg>"))
    }

    func testSanitizeNameHintDecodesEntitiesAndCapsWords() {
        XCTAssertEqual(sanitizeNameHint("Tom &amp; Jerry"), "Tom-Jerry")
        XCTAssertEqual(sanitizeNameHint("one two three four five six"), "one-two-three-four")
        XCTAssertEqual(sanitizeNameHint("logo-final.svg"), "logo-final")
        XCTAssertNil(sanitizeNameHint("untitled document"))
        XCTAssertNil(sanitizeNameHint("!!!"))
    }

    func testCreatorExtractedFromComment() {
        let svg = "<svg><!-- Creator: CorelDRAW 2020 --><rect/></svg>"
        XCTAssertEqual(extractSVGCreator(svgString: svg), "CorelDRAW 2020")
    }

    // MARK: - Margin expansion

    func testAddSVGMarginExpandsViewBoxAndDimensions() {
        let svg = "<svg viewBox=\"0 0 100 50\" width=\"100\" height=\"50\"><rect/></svg>"
        let out = addSVGMargin(svg, margin: 5)
        XCTAssertTrue(out.contains("viewBox=\"-5 -5 110 60\""))
        XCTAssertTrue(out.contains("width=\"110\""))
        XCTAssertTrue(out.contains("height=\"60\""))
        // Content untouched.
        XCTAssertTrue(out.contains("<rect/>"))
    }

    func testAddSVGMarginLeavesViewBoxlessSVGAlone() {
        let svg = "<svg width=\"100\" height=\"50\"/>"
        XCTAssertEqual(addSVGMargin(svg), svg)
    }

    // MARK: - Keynote sanitizer

    func testSanitizerStripsColorProfileElements() {
        let selfClosing = "<svg><color-profile name=\"p\" xlink:href=\"#icc\"/><rect/></svg>"
        XCTAssertFalse(sanitizeSVGForKeynote(selfClosing).contains("color-profile"))
        let paired = "<svg><color-profile name=\"p\">data</color-profile><rect/></svg>"
        let out = sanitizeSVGForKeynote(paired)
        XCTAssertFalse(out.contains("color-profile"))
        XCTAssertTrue(out.contains("<rect/>"), "sibling content must survive")
    }

    // MARK: - Responsive wrapping

    func testResponsiveWrapSynthesizesViewBoxAndStripsInlineSize() {
        let svg = "<svg width=\"80px\" height=\"60px\"><rect/></svg>"
        let html = wrapSVGForResponsiveDisplay(svgString: svg)
        XCTAssertTrue(html.contains("viewBox=\"0 0 80 60\""), "viewBox must be synthesized from width/height, units stripped")
        XCTAssertFalse(html.contains("width=\"80px\""), "inline width must be stripped so CSS drives sizing")
    }
}
