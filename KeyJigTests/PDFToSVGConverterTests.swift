// PDFToSVGConverterTests.swift
// Regression tests for the native CGPDFScanner PDF→SVG converter.
// The fixtures deliberately reproduce the structures behind the converter's
// hard-won fixes (see CLAUDE.md "Native PDF→SVG Conversion"): named ICCBased
// colorspaces resolved via /N, and stroke/dash values scaled by
// sqrt(|det(CTM)|) for EMU-scale PDFs.

import XCTest

final class PDFToSVGConverterTests: XCTestCase {

    // MARK: - Basic painting

    func testFilledRectangleRGB() throws {
        let pdf = PDFFixtures.makePDF(content: "1 0 0 rg 10 20 50 30 re f")
        let svg = try XCTUnwrap(convertPDFToSVG(pdf))
        XCTAssertTrue(svg.contains("viewBox=\"0 0 200 100\""))
        XCTAssertTrue(svg.contains("<path "))
        XCTAssertTrue(svg.contains("fill=\"#ff0000\""))
        XCTAssertTrue(svg.contains("stroke=\"none\""))
        // PDF y=20 with page height 100 flips to SVG y=80 (rect starts at
        // its bottom-left corner).
        XCTAssertTrue(svg.contains("M10,80"))
    }

    func testGrayFill() throws {
        let pdf = PDFFixtures.makePDF(content: "0.5 g 0 0 10 10 re f")
        let svg = try XCTUnwrap(convertPDFToSVG(pdf))
        XCTAssertTrue(svg.contains("fill=\"#808080\""))
    }

    func testCMYKFill() throws {
        // C=0 M=1 Y=1 K=0 → pure red.
        let pdf = PDFFixtures.makePDF(content: "0 1 1 0 k 0 0 10 10 re f")
        let svg = try XCTUnwrap(convertPDFToSVG(pdf))
        XCTAssertTrue(svg.contains("fill=\"#ff0000\""))
    }

    func testStrokedLine() throws {
        let pdf = PDFFixtures.makePDF(content: "0 0 1 RG 2 w 0 0 m 100 0 l S")
        let svg = try XCTUnwrap(convertPDFToSVG(pdf))
        XCTAssertTrue(svg.contains("stroke=\"#0000ff\""))
        XCTAssertTrue(svg.contains("stroke-width=\"2\""))
        XCTAssertTrue(svg.contains("fill=\"none\""))
    }

    func testEvenOddFillRule() throws {
        let pdf = PDFFixtures.makePDF(
            content: "0 0 0 rg 0 0 50 50 re 10 10 30 30 re f*")
        let svg = try XCTUnwrap(convertPDFToSVG(pdf))
        XCTAssertTrue(svg.contains("fill-rule=\"evenodd\""))
    }

    func testBezierCurveEmitsCubicCommand() throws {
        let pdf = PDFFixtures.makePDF(
            content: "0 0 0 rg 0 0 m 10 20 30 40 50 60 c h f")
        let svg = try XCTUnwrap(convertPDFToSVG(pdf))
        XCTAssertTrue(svg.contains("C"), "cubic bezier should emit an SVG C command")
    }

    // MARK: - CTM-scaled strokes and dashes (the Excel EMU-coordinate fix)

    func testStrokeWidthAndDashScaledByCTM() throws {
        // Scale CTM down 100×; user-space width 100 and dash [300 100] must
        // come out as 1 and 3,1 — raw values would be absurdly thick.
        let pdf = PDFFixtures.makePDF(
            content: "q 0.01 0 0 0.01 0 0 cm 0 0 0 RG 100 w [300 100] 0 d "
                + "0 0 m 5000 0 l S Q")
        let svg = try XCTUnwrap(convertPDFToSVG(pdf))
        XCTAssertTrue(svg.contains("stroke-width=\"1\""), "stroke width must be scaled by sqrt(|det(CTM)|)")
        XCTAssertTrue(svg.contains("stroke-dasharray=\"3,1\""), "dash array must be scaled by sqrt(|det(CTM)|)")
    }

    // MARK: - Named colorspaces (the /Cs1 → ICCBased RGB fix)

    func testNamedICCBasedRGBColorspace() throws {
        // /Cs1 resolves through the page Resources to an ICCBased stream with
        // /N 3 → RGB. Bucketing it as "other" would mis-map the components.
        let icc = PDFFixtures.streamObject(dict: "<< /N 3", content: "")
        let pdf = PDFFixtures.makePDF(
            content: "/Cs1 cs 0 1 0 sc 10 10 50 50 re f",
            resources: "<< /ColorSpace << /Cs1 5 0 R >> >>",
            extraObjects: ["[/ICCBased 6 0 R]", icc])
        let svg = try XCTUnwrap(convertPDFToSVG(pdf))
        XCTAssertTrue(svg.contains("fill=\"#00ff00\""), "ICCBased /N 3 colorspace must resolve as RGB")
    }

    func testNamedICCBasedGrayColorspace() throws {
        let icc = PDFFixtures.streamObject(dict: "<< /N 1", content: "")
        let pdf = PDFFixtures.makePDF(
            content: "/Cs1 cs 0.5 sc 10 10 50 50 re f",
            resources: "<< /ColorSpace << /Cs1 5 0 R >> >>",
            extraObjects: ["[/ICCBased 6 0 R]", icc])
        let svg = try XCTUnwrap(convertPDFToSVG(pdf))
        XCTAssertTrue(svg.contains("fill=\"#808080\""))
    }

    // MARK: - Form XObjects

    func testFormXObjectContentIsScanned() throws {
        let form = PDFFixtures.streamObject(
            dict: "<< /Type /XObject /Subtype /Form /BBox [0 0 200 100]",
            content: "0 0 1 rg 5 5 10 10 re f")
        let pdf = PDFFixtures.makePDF(
            content: "/Fm1 Do",
            resources: "<< /XObject << /Fm1 5 0 R >> >>",
            extraObjects: [form])
        let svg = try XCTUnwrap(convertPDFToSVG(pdf))
        XCTAssertTrue(svg.contains("fill=\"#0000ff\""), "content inside a Form XObject must be converted")
    }

    // MARK: - Refusal cases (what triggers the Inkscape/preview fallbacks)

    func testUnpaintedPathYieldsNil() {
        // Path constructed but never painted — no vector content to emit.
        let pdf = PDFFixtures.makePDF(content: "10 10 50 50 re n")
        XCTAssertNil(convertPDFToSVG(pdf))
    }

    func testEmptyContentStreamYieldsNil() {
        let pdf = PDFFixtures.makePDF(content: "")
        XCTAssertNil(convertPDFToSVG(pdf))
    }

    func testGarbageDataYieldsNil() {
        XCTAssertNil(convertPDFToSVG(Data("this is not a pdf".utf8)))
        XCTAssertNil(convertPDFToSVG(Data()))
    }

    // MARK: - Parallel <text> orientation (the OmniGraffle flipped-CTM fix)

    func testTextTransformUprightUnderFlippedCTM() throws {
        // OmniGraffle wraps text in a Y-flip CTM and uses a negative-d text
        // matrix; the two cancel, so the text is upright in PDF space. The
        // parallel <text> transform must come out with positive d in SVG
        // space (upright) — negating d instead of c renders it upside down.
        let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        let pdf = PDFFixtures.makePDF(
            content: "q 1 0 0 -1 0 100 cm BT /F1 1 Tf 12 0 0 -12 10 20 Tm (Hi) Tj ET Q",
            resources: "<< /Font << /F1 5 0 R >> >>",
            extraObjects: [font])
        let svg = try XCTUnwrap(convertPDFToSVG(pdf))
        XCTAssertTrue(svg.contains("<text "), "a resolvable font family must produce a parallel <text> element")
        // Effective Tm·CTM = (12 0 0 12, 10, 80); flipped to SVG space the
        // transform is (12 0 0 12, 10, 20). %.4g may print negated zeros as
        // "-0", so match b/c loosely but pin a and d exactly.
        let transform = try XCTUnwrap(
            svg.range(of: "matrix\\(12 -?0 -?0 12 10 20\\)", options: .regularExpression),
            "text transform must keep d positive (upright); got: \(svg.components(separatedBy: "<g transform=\"").dropFirst().first.map { String($0.prefix(40)) } ?? "no <g>")")
        _ = transform
    }

    // MARK: - Output document shape

    func testSVGRootCarriesNamespaceAndPageSizedViewBox() throws {
        let pdf = PDFFixtures.makePDF(
            content: "0 0 0 rg 0 0 10 10 re f",
            mediaBox: "[0 0 612 792]")
        let svg = try XCTUnwrap(convertPDFToSVG(pdf))
        XCTAssertTrue(svg.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\""))
        XCTAssertTrue(svg.contains("viewBox=\"0 0 612 792\""))
        XCTAssertTrue(svg.hasSuffix("</svg>"))
    }
}
