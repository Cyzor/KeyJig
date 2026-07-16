// PDFFixtures.swift
// Builds minimal, hand-assembled PDF files as Data for converter tests.
// Hand assembly (rather than CGContext PDF output) gives byte-level control
// over the content stream and resource dictionaries, so fixtures can
// reproduce the exact structures the converter's hard-won fixes target:
// named ICCBased colorspaces, tiny-scale CTMs, and Form XObjects.

import Foundation

enum PDFFixtures {

    /// Builds a single-page PDF whose page content stream is `content`.
    /// Objects: 1 Catalog, 2 Pages, 3 Page, 4 Contents. `extraObjects` are
    /// appended starting at object number 5 and can be referenced from
    /// `resources` (e.g. `<< /ColorSpace << /Cs1 5 0 R >> >>`).
    static func makePDF(
        content: String,
        resources: String = "<< >>",
        extraObjects: [String] = [],
        mediaBox: String = "[0 0 200 100]",
        pageCount: Int = 1
    ) -> Data {
        precondition(pageCount == 1, "fixture builder emits single-page PDFs")
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objects.append(
            "<< /Type /Page /Parent 2 0 R /MediaBox \(mediaBox) "
                + "/Resources \(resources) /Contents 4 0 R >>")
        objects.append(streamObject(dict: "<<", content: content))
        objects.append(contentsOf: extraObjects)

        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, obj) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(obj)\nendobj\n"
        }
        let xrefStart = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for off in offsets {
            pdf += String(format: "%010d 00000 n \n", off)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        pdf += "startxref\n\(xrefStart)\n%%EOF"
        return Data(pdf.utf8)
    }

    /// A stream object body. `dict` is the opening of the stream dictionary
    /// without the closing `>>` (e.g. `"<<"` or `"<< /N 3"`); /Length is added.
    static func streamObject(dict: String, content: String) -> String {
        "\(dict) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
    }
}
