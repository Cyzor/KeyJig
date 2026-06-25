// PDFToSVGConverter.swift
// Scans the content stream of a PDF page using CGPDFScanner / CGPDFOperatorTable
// and emits SVG from the vector operators found there. No external tools required.
//
// Handles: paths (m l c v y h re), all paint operators (S f B etc.), graphics state
// (q Q cm w J j M d), RGB/Gray/CMYK color (rg RG g G k K and cs/CS+sc/SC families),
// transparency (ca CA), Form XObjects (Do), and text (BT/ET Tf Td Tm Tj TJ and
// variants) — live text is outlined to paths via CTFontCreatePathForGlyph.
// Skips: raster images, shadings, patterns, clipping paths.

import CoreGraphics
import CoreText
import Foundation
import os.log

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "PDFConvert")

// MARK: - Entry point

/// Converts the first page of `pdfData` into an SVG string by walking its content
/// stream. Returns `nil` if the page yields no painted paths.
func convertPDFToSVG(_ pdfData: Data) -> String? {
    guard let provider = CGDataProvider(data: pdfData as CFData),
          let doc = CGPDFDocument(provider),
          doc.numberOfPages >= 1,
          let page = doc.page(at: 1) else {
        log.info("convertPDFToSVG: no page")
        return nil
    }
    let svg = PDFStreamScanner(page: page).buildSVG()
    if svg == nil { log.info("convertPDFToSVG: no vector content extracted") }
    return svg
}

// MARK: - Scanner

private final class PDFStreamScanner {

    // MARK: Graphics state

    private enum CSKind { case gray, rgb, cmyk, other }

    private struct GS {
        var ctm: CGAffineTransform = .identity
        var fillColor: String = "#000000"
        var strokeColor: String = "none"
        var fillAlpha: CGFloat = 1
        var strokeAlpha: CGFloat = 1
        var lineWidth: CGFloat = 1
        var lineCap: Int32 = 0      // 0 butt · 1 round · 2 square
        var lineJoin: Int32 = 0     // 0 miter · 1 round · 2 bevel
        var miterLimit: CGFloat = 4
        var dashArray: [CGFloat] = []
        var dashPhase: CGFloat = 0
        var fillCS: CSKind = .rgb
        var strokeCS: CSKind = .rgb
    }

    // MARK: Text state

    private struct TextState {
        var matrix: CGAffineTransform = .identity   // Tm — text-to-user-space
        var lineMatrix: CGAffineTransform = .identity // Tlm — baseline origin, used by Td/T*
        var fontResourceName: String = ""           // name in PDF resource dict (from Tf)
        var fontBaseName: String = ""               // /BaseFont PostScript name
        var fontSize: CGFloat = 12                  // Tfs (from Tf)
        var charSpacing: CGFloat = 0                // Tc
        var wordSpacing: CGFloat = 0                // Tw
        var hScale: CGFloat = 100                   // Tz (percent)
        var leading: CGFloat = 0                    // TL
        var rise: CGFloat = 0                       // Ts
        var renderMode: Int = 0                     // Tr (0 fill, 1 stroke, 2 both, 3 invisible)
    }

    private var ts = TextState()
    private var fontCache: [String: CTFont] = [:]

    private var gsStack: [GS] = [GS()]
    private var gs: GS {
        get { gsStack.last ?? GS() }
        set {
            if gsStack.isEmpty { gsStack.append(newValue) } else {
                gsStack[gsStack.count - 1] = newValue
            }
        }
    }

    // MARK: Path accumulation

    private var pathData = ""
    private var cx: CGFloat = 0, cy: CGFloat = 0  // current PDF-space point

    // MARK: Output

    private var elements: [String] = []

    // MARK: Page dimensions

    private let W: CGFloat   // width in pts
    private let H: CGFloat   // height in pts — used to flip Y axis

    // MARK: Operator table (kept alive for XObject recursion)

    private var opTable: CGPDFOperatorTableRef?

    // MARK: Init

    init(page: CGPDFPage) {
        let box = page.getBoxRect(.cropBox)
        W = box.width
        H = box.height
        self.page = page
    }

    private let page: CGPDFPage

    // MARK: Build

    func buildSVG() -> String? {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        opTable = table
        defer { CGPDFOperatorTableRelease(table); opTable = nil }

        registerAll(table)

        let cs = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(cs) }

        scanStream(cs)

        guard !elements.isEmpty else { return nil }

        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(f(W)) \(f(H))">
        \(elements.joined(separator: "\n"))
        </svg>
        """
    }

    // MARK: Operator registration

    private func registerAll(_ t: CGPDFOperatorTableRef) {
        // Helper: register one operator
        func reg(_ op: StaticString, _ cb: @escaping @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void) {
            CGPDFOperatorTableSetCallback(t, op.utf8Start, cb)
        }

        // Graphics state
        reg("q")  { s, i in ctx(i).pushGS() }
        reg("Q")  { s, i in ctx(i).popGS() }
        reg("cm") { s, i in ctx(i).op_cm(s) }
        reg("w")  { s, i in ctx(i).op_w(s) }
        reg("J")  { s, i in ctx(i).op_J(s) }
        reg("j")  { s, i in ctx(i).op_j(s) }
        reg("M")  { s, i in ctx(i).op_M(s) }
        reg("d")  { s, i in ctx(i).op_d(s) }

        // Color — device
        reg("g")   { s, i in ctx(i).op_g(s) }
        reg("G")   { s, i in ctx(i).op_G(s) }
        reg("rg")  { s, i in ctx(i).op_rg(s) }
        reg("RG")  { s, i in ctx(i).op_RG(s) }
        reg("k")   { s, i in ctx(i).op_k(s) }
        reg("K")   { s, i in ctx(i).op_K(s) }

        // Color — colorspace + set-color families
        reg("cs")  { s, i in ctx(i).op_cs(s, fill: true) }
        reg("CS")  { s, i in ctx(i).op_cs(s, fill: false) }
        reg("sc")  { s, i in ctx(i).op_sc(s, fill: true,  extended: false) }
        reg("SC")  { s, i in ctx(i).op_sc(s, fill: false, extended: false) }
        reg("scn") { s, i in ctx(i).op_sc(s, fill: true,  extended: true) }
        reg("SCN") { s, i in ctx(i).op_sc(s, fill: false, extended: true) }

        // Transparency
        reg("ca") { s, i in ctx(i).op_ca(s, fill: true) }
        reg("CA") { s, i in ctx(i).op_ca(s, fill: false) }

        // Path construction
        reg("m")  { s, i in ctx(i).op_m(s) }
        reg("l")  { s, i in ctx(i).op_l(s) }
        reg("c")  { s, i in ctx(i).op_c(s) }
        reg("v")  { s, i in ctx(i).op_v(s) }
        reg("y")  { s, i in ctx(i).op_y(s) }
        reg("h")  { s, i in ctx(i).op_h() }
        reg("re") { s, i in ctx(i).op_re(s) }

        // Path painting
        reg("S")  { s, i in ctx(i).paint(fill: false, stroke: true,  close: false, eo: false) }
        reg("s")  { s, i in ctx(i).paint(fill: false, stroke: true,  close: true,  eo: false) }
        reg("f")  { s, i in ctx(i).paint(fill: true,  stroke: false, close: false, eo: false) }
        reg("F")  { s, i in ctx(i).paint(fill: true,  stroke: false, close: false, eo: false) }
        reg("f*") { s, i in ctx(i).paint(fill: true,  stroke: false, close: false, eo: true) }
        reg("B")  { s, i in ctx(i).paint(fill: true,  stroke: true,  close: false, eo: false) }
        reg("B*") { s, i in ctx(i).paint(fill: true,  stroke: true,  close: false, eo: true) }
        reg("b")  { s, i in ctx(i).paint(fill: true,  stroke: true,  close: true,  eo: false) }
        reg("b*") { s, i in ctx(i).paint(fill: true,  stroke: true,  close: true,  eo: true) }
        reg("n")  { s, i in ctx(i).clearPath() }

        // XObjects (Form only; raster images are skipped)
        reg("Do") { s, i in ctx(i).op_Do(s) }

        // Text — begin/end
        reg("BT") { _, i in ctx(i).op_BT() }
        reg("ET") { _, i in ctx(i).op_ET() }

        // Text — font and simple state
        reg("Tf") { s, i in ctx(i).op_Tf(s) }
        reg("Tc") { s, i in ctx(i).op_Tc(s) }
        reg("Tw") { s, i in ctx(i).op_Tw(s) }
        reg("Tz") { s, i in ctx(i).op_Tz(s) }
        reg("TL") { s, i in ctx(i).op_TL(s) }
        reg("Ts") { s, i in ctx(i).op_Ts(s) }
        reg("Tr") { s, i in ctx(i).op_Tr(s) }

        // Text — positioning
        reg("Td") { s, i in ctx(i).op_Td(s, setLeading: false) }
        reg("TD") { s, i in ctx(i).op_Td(s, setLeading: true) }
        reg("Tm") { s, i in ctx(i).op_Tm(s) }
        reg("T*") { _, i in ctx(i).op_Tstar() }

        // Text — show
        reg("Tj") { s, i in ctx(i).op_Tj(s) }
        reg("TJ") { s, i in ctx(i).op_TJ(s) }
        reg("'")  { s, i in ctx(i).op_apos(s) }
        reg("\"") { s, i in ctx(i).op_quot(s) }
    }

    // MARK: Context helper (lifts UnsafeMutableRawPointer back to self)

    private var rawSelf: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private func scanStream(_ cs: CGPDFContentStreamRef) {
        guard let table = opTable else { return }
        let scanner = CGPDFScannerCreate(cs, table, rawSelf)
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
    }

    // MARK: - Graphics state operators

    private func pushGS() { gsStack.append(gs) }
    private func popGS()  { if gsStack.count > 1 { gsStack.removeLast() } }

    private func op_cm(_ s: CGPDFScannerRef) {
        var f: CGPDFReal = 0
        var e: CGPDFReal = 0; var d: CGPDFReal = 1; var cc: CGPDFReal = 0
        var b: CGPDFReal = 0; var a: CGPDFReal = 1
        CGPDFScannerPopNumber(s, &f); CGPDFScannerPopNumber(s, &e)
        CGPDFScannerPopNumber(s, &d); CGPDFScannerPopNumber(s, &cc)
        CGPDFScannerPopNumber(s, &b); CGPDFScannerPopNumber(s, &a)
        let m = CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(cc),
                                  d: CGFloat(d), tx: CGFloat(e), ty: CGFloat(f))
        gs.ctm = m.concatenating(gs.ctm)
    }

    private func op_w(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 1
        CGPDFScannerPopNumber(s, &v)
        gs.lineWidth = CGFloat(v)
    }
    private func op_J(_ s: CGPDFScannerRef) {
        var v: CGPDFInteger = 0
        CGPDFScannerPopInteger(s, &v)
        gs.lineCap = Int32(v)
    }
    private func op_j(_ s: CGPDFScannerRef) {
        var v: CGPDFInteger = 0
        CGPDFScannerPopInteger(s, &v)
        gs.lineJoin = Int32(v)
    }
    private func op_M(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 4
        CGPDFScannerPopNumber(s, &v)
        gs.miterLimit = CGFloat(v)
    }
    private func op_d(_ s: CGPDFScannerRef) {
        var phase: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &phase)
        var arr: CGPDFArrayRef?
        if CGPDFScannerPopArray(s, &arr), let arr {
            var da: [CGFloat] = []
            let n = CGPDFArrayGetCount(arr)
            for idx in 0..<n {
                var v: CGPDFReal = 0
                if CGPDFArrayGetNumber(arr, idx, &v) { da.append(CGFloat(v)) }
            }
            gs.dashArray = da
        }
        gs.dashPhase = CGFloat(phase)
    }

    // MARK: - Color operators

    private func op_g(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &v)
        gs.fillColor = gray(CGFloat(v)); gs.fillCS = .gray
    }
    private func op_G(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &v)
        gs.strokeColor = gray(CGFloat(v)); gs.strokeCS = .gray
    }
    private func op_rg(_ s: CGPDFScannerRef) {
        var b: CGPDFReal = 0, g: CGPDFReal = 0, r: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &b); CGPDFScannerPopNumber(s, &g)
        CGPDFScannerPopNumber(s, &r)
        self.gs.fillColor = rgb(CGFloat(r), CGFloat(g), CGFloat(b)); self.gs.fillCS = .rgb
    }
    private func op_RG(_ s: CGPDFScannerRef) {
        var b: CGPDFReal = 0, g: CGPDFReal = 0, r: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &b); CGPDFScannerPopNumber(s, &g)
        CGPDFScannerPopNumber(s, &r)
        self.gs.strokeColor = rgb(CGFloat(r), CGFloat(g), CGFloat(b)); self.gs.strokeCS = .rgb
    }
    private func op_k(_ s: CGPDFScannerRef) {
        var k: CGPDFReal = 0, y: CGPDFReal = 0, m: CGPDFReal = 0, c: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &k); CGPDFScannerPopNumber(s, &y)
        CGPDFScannerPopNumber(s, &m); CGPDFScannerPopNumber(s, &c)
        gs.fillColor = cmyk(CGFloat(c), CGFloat(m), CGFloat(y), CGFloat(k)); gs.fillCS = .cmyk
    }
    private func op_K(_ s: CGPDFScannerRef) {
        var k: CGPDFReal = 0, y: CGPDFReal = 0, m: CGPDFReal = 0, c: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &k); CGPDFScannerPopNumber(s, &y)
        CGPDFScannerPopNumber(s, &m); CGPDFScannerPopNumber(s, &c)
        gs.strokeColor = cmyk(CGFloat(c), CGFloat(m), CGFloat(y), CGFloat(k)); gs.strokeCS = .cmyk
    }

    private func op_cs(_ s: CGPDFScannerRef, fill: Bool) {
        var ptr: UnsafePointer<CChar>? = nil
        guard CGPDFScannerPopName(s, &ptr), let ptr else { return }
        let name = String(cString: ptr)
        let kind: CSKind
        switch name {
        case "DeviceGray", "CalGray": kind = .gray
        case "DeviceRGB", "CalRGB":  kind = .rgb
        case "DeviceCMYK":           kind = .cmyk
        default:                     kind = .other
        }
        if fill { gs.fillCS = kind } else { gs.strokeCS = kind }
    }

    private func op_sc(_ s: CGPDFScannerRef, fill: Bool, extended: Bool) {
        // Pop numbers (up to 4); if extended, also skip an optional name operand at top.
        if extended {
            var ptr: UnsafePointer<CChar>? = nil
            _ = CGPDFScannerPopName(s, &ptr)  // optional pattern name
        }
        var comps: [CGFloat] = []
        var v: CGPDFReal = 0
        while comps.count < 4, CGPDFScannerPopNumber(s, &v) { comps.insert(CGFloat(v), at: 0) }

        let cs = fill ? gs.fillCS : gs.strokeCS
        let color: String
        switch (cs, comps.count) {
        case (.gray, 1):              color = gray(comps[0])
        case (.rgb, 3):               color = rgb(comps[0], comps[1], comps[2])
        case (.cmyk, 4):              color = cmyk(comps[0], comps[1], comps[2], comps[3])
        case (_, 1):                  color = gray(comps[0])
        case (_, 3):                  color = rgb(comps[0], comps[1], comps[2])
        case (_, 4):                  color = cmyk(comps[0], comps[1], comps[2], comps[3])
        default:                      return
        }
        if fill { gs.fillColor = color } else { gs.strokeColor = color }
    }

    private func op_ca(_ s: CGPDFScannerRef, fill: Bool) {
        var v: CGPDFReal = 1
        CGPDFScannerPopNumber(s, &v)
        if fill { gs.fillAlpha = CGFloat(v) } else { gs.strokeAlpha = CGFloat(v) }
    }

    // MARK: - Path construction operators

    private func op_m(_ s: CGPDFScannerRef) {
        var y: CGPDFReal = 0, x: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &y); CGPDFScannerPopNumber(s, &x)
        cx = CGFloat(x); cy = CGFloat(y)
        let p = txPt(cx, cy)
        pathData += "M\(f(p.x)),\(f(p.y))"
    }
    private func op_l(_ s: CGPDFScannerRef) {
        var y: CGPDFReal = 0, x: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &y); CGPDFScannerPopNumber(s, &x)
        cx = CGFloat(x); cy = CGFloat(y)
        let p = txPt(cx, cy)
        pathData += "L\(f(p.x)),\(f(p.y))"
    }
    private func op_c(_ s: CGPDFScannerRef) {
        var y3: CGPDFReal = 0, x3: CGPDFReal = 0
        var y2: CGPDFReal = 0, x2: CGPDFReal = 0
        var y1: CGPDFReal = 0, x1: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &y3); CGPDFScannerPopNumber(s, &x3)
        CGPDFScannerPopNumber(s, &y2); CGPDFScannerPopNumber(s, &x2)
        CGPDFScannerPopNumber(s, &y1); CGPDFScannerPopNumber(s, &x1)
        cx = CGFloat(x3); cy = CGFloat(y3)
        let p1 = txPt(CGFloat(x1), CGFloat(y1))
        let p2 = txPt(CGFloat(x2), CGFloat(y2))
        let p3 = txPt(cx, cy)
        pathData += "C\(f(p1.x)),\(f(p1.y)) \(f(p2.x)),\(f(p2.y)) \(f(p3.x)),\(f(p3.y))"
    }
    private func op_v(_ s: CGPDFScannerRef) {
        // First control point = current point
        var y3: CGPDFReal = 0, x3: CGPDFReal = 0
        var y2: CGPDFReal = 0, x2: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &y3); CGPDFScannerPopNumber(s, &x3)
        CGPDFScannerPopNumber(s, &y2); CGPDFScannerPopNumber(s, &x2)
        let p1 = txPt(cx, cy)
        cx = CGFloat(x3); cy = CGFloat(y3)
        let p2 = txPt(CGFloat(x2), CGFloat(y2))
        let p3 = txPt(cx, cy)
        pathData += "C\(f(p1.x)),\(f(p1.y)) \(f(p2.x)),\(f(p2.y)) \(f(p3.x)),\(f(p3.y))"
    }
    private func op_y(_ s: CGPDFScannerRef) {
        // Last control point = endpoint
        var y3: CGPDFReal = 0, x3: CGPDFReal = 0
        var y1: CGPDFReal = 0, x1: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &y3); CGPDFScannerPopNumber(s, &x3)
        CGPDFScannerPopNumber(s, &y1); CGPDFScannerPopNumber(s, &x1)
        let p1 = txPt(CGFloat(x1), CGFloat(y1))
        cx = CGFloat(x3); cy = CGFloat(y3)
        let p3 = txPt(cx, cy)
        pathData += "C\(f(p1.x)),\(f(p1.y)) \(f(p3.x)),\(f(p3.y)) \(f(p3.x)),\(f(p3.y))"
    }
    private func op_h() {
        pathData += "Z"
    }
    private func op_re(_ s: CGPDFScannerRef) {
        var hh: CGPDFReal = 0, ww: CGPDFReal = 0
        var y: CGPDFReal = 0, x: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &hh); CGPDFScannerPopNumber(s, &ww)
        CGPDFScannerPopNumber(s, &y);  CGPDFScannerPopNumber(s, &x)
        let bl = txPt(CGFloat(x),             CGFloat(y))
        let br = txPt(CGFloat(x) + CGFloat(ww), CGFloat(y))
        let tr = txPt(CGFloat(x) + CGFloat(ww), CGFloat(y) + CGFloat(hh))
        let tl = txPt(CGFloat(x),             CGFloat(y) + CGFloat(hh))
        pathData += "M\(f(bl.x)),\(f(bl.y))L\(f(br.x)),\(f(br.y))L\(f(tr.x)),\(f(tr.y))L\(f(tl.x)),\(f(tl.y))Z"
        cx = CGFloat(x); cy = CGFloat(y)
    }

    private func clearPath() { pathData = "" }

    // MARK: - Path painting

    private func paint(fill: Bool, stroke: Bool, close: Bool, eo: Bool) {
        if close { pathData += "Z" }
        guard !pathData.isEmpty else { return }

        var attrs = "d=\"\(pathData)\""

        if fill {
            attrs += " fill=\"\(gs.fillColor)\""
            if gs.fillAlpha < 1 { attrs += " fill-opacity=\"\(f(gs.fillAlpha))\"" }
            if eo { attrs += " fill-rule=\"evenodd\"" }
        } else {
            attrs += " fill=\"none\""
        }

        if stroke {
            attrs += " stroke=\"\(gs.strokeColor)\""
            if gs.strokeAlpha < 1 { attrs += " stroke-opacity=\"\(f(gs.strokeAlpha))\"" }
            attrs += " stroke-width=\"\(f(gs.lineWidth))\""
            let capName = ["butt", "round", "square"]
            let joinName = ["miter", "round", "bevel"]
            let cap = Int(gs.lineCap)
            let join = Int(gs.lineJoin)
            if cap >= 0 && cap < capName.count && cap != 0 {
                attrs += " stroke-linecap=\"\(capName[cap])\""
            }
            if join >= 0 && join < joinName.count && join != 0 {
                attrs += " stroke-linejoin=\"\(joinName[join])\""
            }
            if gs.lineJoin == 0 && gs.miterLimit != 4 {
                attrs += " stroke-miterlimit=\"\(f(gs.miterLimit))\""
            }
            if !gs.dashArray.isEmpty {
                let da = gs.dashArray.map { f($0) }.joined(separator: ",")
                attrs += " stroke-dasharray=\"\(da)\""
                if gs.dashPhase != 0 { attrs += " stroke-dashoffset=\"\(f(gs.dashPhase))\"" }
            }
        } else {
            attrs += " stroke=\"none\""
        }

        elements.append("  <path \(attrs)/>")
        pathData = ""
    }

    // MARK: - XObject (Form)

    private func op_Do(_ s: CGPDFScannerRef) {
        var namePtr: UnsafePointer<CChar>? = nil
        guard CGPDFScannerPopName(s, &namePtr), let namePtr else { return }
        let name = String(cString: namePtr)

        // Look up in current content stream's resources
        let parentCS = CGPDFScannerGetContentStream(s)
        guard let obj = CGPDFContentStreamGetResource(parentCS, "XObject", name) else { return }

        var streamRef: CGPDFStreamRef? = nil
        guard CGPDFObjectGetValue(obj, .stream, &streamRef), let streamRef else { return }

        let dict = CGPDFStreamGetDictionary(streamRef)!
        var subtypePtr: UnsafePointer<CChar>? = nil
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtypePtr),
              String(cString: subtypePtr!) == "Form" else { return }

        // Save/restore graphics state around the Form XObject
        pushGS()

        // Apply the XObject's optional Matrix (in addition to the current CTM)
        var matrixArray: CGPDFArrayRef? = nil
        if CGPDFDictionaryGetArray(dict, "Matrix", &matrixArray), let matrixArray {
            var a: CGPDFReal = 1, b: CGPDFReal = 0, c: CGPDFReal = 0
            var d: CGPDFReal = 1, e: CGPDFReal = 0, ff: CGPDFReal = 0
            CGPDFArrayGetNumber(matrixArray, 0, &a); CGPDFArrayGetNumber(matrixArray, 1, &b)
            CGPDFArrayGetNumber(matrixArray, 2, &c); CGPDFArrayGetNumber(matrixArray, 3, &d)
            CGPDFArrayGetNumber(matrixArray, 4, &e); CGPDFArrayGetNumber(matrixArray, 5, &ff)
            let xm = CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c),
                                       d: CGFloat(d), tx: CGFloat(e), ty: CGFloat(ff))
            gs.ctm = xm.concatenating(gs.ctm)
        }

        let subCS = CGPDFContentStreamCreateWithStream(streamRef, dict, parentCS)
        defer { CGPDFContentStreamRelease(subCS) }
        scanStream(subCS)

        popGS()
    }

    // MARK: - Text operators

    private func op_BT() {
        ts.matrix = .identity
        ts.lineMatrix = .identity
    }

    private func op_ET() {
        // No state to clean up; text state persists across BT/ET per spec.
    }

    private func op_Tf(_ s: CGPDFScannerRef) {
        var size: CGPDFReal = 12
        var namePtr: UnsafePointer<CChar>? = nil
        CGPDFScannerPopNumber(s, &size)
        guard CGPDFScannerPopName(s, &namePtr), let namePtr else { return }
        ts.fontSize = CGFloat(size)
        let resourceName = String(cString: namePtr)
        ts.fontResourceName = resourceName
        ts.fontBaseName = ""

        // Resolve /BaseFont from the content stream's Font resource
        let cs = CGPDFScannerGetContentStream(s)
        guard let fontObj = CGPDFContentStreamGetResource(cs, "Font", resourceName) else { return }
        var fontDict: CGPDFDictionaryRef? = nil
        guard CGPDFObjectGetValue(fontObj, .dictionary, &fontDict), let fontDict else { return }
        var baseFontPtr: UnsafePointer<CChar>? = nil
        if CGPDFDictionaryGetName(fontDict, "BaseFont", &baseFontPtr), let baseFontPtr {
            ts.fontBaseName = String(cString: baseFontPtr)
        }
    }

    private func op_Tc(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 0; CGPDFScannerPopNumber(s, &v); ts.charSpacing = CGFloat(v)
    }
    private func op_Tw(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 0; CGPDFScannerPopNumber(s, &v); ts.wordSpacing = CGFloat(v)
    }
    private func op_Tz(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 100; CGPDFScannerPopNumber(s, &v); ts.hScale = CGFloat(v)
    }
    private func op_TL(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 0; CGPDFScannerPopNumber(s, &v); ts.leading = CGFloat(v)
    }
    private func op_Ts(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 0; CGPDFScannerPopNumber(s, &v); ts.rise = CGFloat(v)
    }
    private func op_Tr(_ s: CGPDFScannerRef) {
        var v: CGPDFInteger = 0; CGPDFScannerPopInteger(s, &v); ts.renderMode = Int(v)
    }

    private func op_Td(_ s: CGPDFScannerRef, setLeading: Bool) {
        var ty: CGPDFReal = 0, tx: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &ty); CGPDFScannerPopNumber(s, &tx)
        if setLeading { ts.leading = -CGFloat(ty) }
        let move = CGAffineTransform(translationX: CGFloat(tx), y: CGFloat(ty))
        ts.lineMatrix = move.concatenating(ts.lineMatrix)
        ts.matrix = ts.lineMatrix
    }

    private func op_Tm(_ s: CGPDFScannerRef) {
        var f: CGPDFReal = 0, e: CGPDFReal = 0
        var d: CGPDFReal = 1, c: CGPDFReal = 0
        var b: CGPDFReal = 0, a: CGPDFReal = 1
        CGPDFScannerPopNumber(s, &f); CGPDFScannerPopNumber(s, &e)
        CGPDFScannerPopNumber(s, &d); CGPDFScannerPopNumber(s, &c)
        CGPDFScannerPopNumber(s, &b); CGPDFScannerPopNumber(s, &a)
        let m = CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c),
                                  d: CGFloat(d), tx: CGFloat(e), ty: CGFloat(f))
        ts.matrix = m
        ts.lineMatrix = m
    }

    private func op_Tstar() {
        let move = CGAffineTransform(translationX: 0, y: -ts.leading)
        ts.lineMatrix = move.concatenating(ts.lineMatrix)
        ts.matrix = ts.lineMatrix
    }

    private func op_Tj(_ s: CGPDFScannerRef) {
        var str: CGPDFStringRef? = nil
        guard CGPDFScannerPopString(s, &str), let str else { return }
        showPDFString(str)
    }

    private func op_TJ(_ s: CGPDFScannerRef) {
        var arr: CGPDFArrayRef? = nil
        guard CGPDFScannerPopArray(s, &arr), let arr else { return }
        let n = CGPDFArrayGetCount(arr)
        for idx in 0..<n {
            var obj: CGPDFObjectRef? = nil
            guard CGPDFArrayGetObject(arr, idx, &obj), let obj else { continue }
            var str: CGPDFStringRef? = nil
            var numReal: CGPDFReal = 0
            var numInt: CGPDFInteger = 0
            if CGPDFObjectGetValue(obj, .string, &str), let str {
                showPDFString(str)
            } else if CGPDFObjectGetValue(obj, .real, &numReal) {
                // Negative number = advance forward (kerning offset in thousandths of text unit)
                let offset = -CGFloat(numReal) / 1000.0 * ts.fontSize * (ts.hScale / 100.0)
                ts.matrix = CGAffineTransform(translationX: offset, y: 0).concatenating(ts.matrix)
            } else if CGPDFObjectGetValue(obj, .integer, &numInt) {
                let offset = -CGFloat(numInt) / 1000.0 * ts.fontSize * (ts.hScale / 100.0)
                ts.matrix = CGAffineTransform(translationX: offset, y: 0).concatenating(ts.matrix)
            }
        }
    }

    private func op_apos(_ s: CGPDFScannerRef) {
        // ' : move to next line, show string
        op_Tstar()
        op_Tj(s)
    }

    private func op_quot(_ s: CGPDFScannerRef) {
        // " : set Tw, set Tc, move to next line, show string
        var charSpace: CGPDFReal = 0, wordSpace: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &charSpace)
        CGPDFScannerPopNumber(s, &wordSpace)
        ts.wordSpacing = CGFloat(wordSpace)
        ts.charSpacing = CGFloat(charSpace)
        op_Tj(s)
    }

    // MARK: - Text glyph outlining

    private func showPDFString(_ str: CGPDFStringRef) {
        guard ts.renderMode != 3 else { return }  // invisible
        let len = CGPDFStringGetLength(str)
        guard len > 0, let bytePtr = CGPDFStringGetBytePtr(str) else { return }
        let bytes = Array(UnsafeBufferPointer(start: bytePtr, count: len))

        // Detect UTF-16 BE (BOM 0xFE 0xFF) — used by some modern Mac apps
        if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
            var chars: [UniChar] = []
            var i = 2
            while i + 1 < bytes.count {
                chars.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                i += 2
            }
            showUnichars(chars)
        } else {
            // Single-byte: assume MacRoman (covers most Mac-origin PDFs and WinAnsi ASCII range)
            let chars = bytes.map { macRomanToUnichar($0) }
            showUnichars(chars)
        }
    }

    private func showUnichars(_ unichars: [UniChar]) {
        guard !ts.fontBaseName.isEmpty else { return }
        let ctFont = cachedFont(name: ts.fontBaseName, size: 1.0)
        let Tfs = ts.fontSize
        let Th = ts.hScale / 100.0
        let fill = ts.renderMode == 0 || ts.renderMode == 2 || ts.renderMode == 4 || ts.renderMode == 6
        let stroke = ts.renderMode == 1 || ts.renderMode == 2 || ts.renderMode == 5 || ts.renderMode == 6

        for unichar in unichars {
            var ch = unichar
            var glyph: CGGlyph = 0
            CTFontGetGlyphsForCharacters(ctFont, &ch, &glyph, 1)

            if glyph != 0 {
                // Text rendering matrix: Trm = [Tfs*Th, 0, 0, Tfs, 0, Ts] × Tm × CTM
                let scaleTx = CGAffineTransform(a: Tfs * Th, b: 0, c: 0, d: Tfs,
                                               tx: 0, ty: ts.rise)
                let trm = scaleTx.concatenating(ts.matrix).concatenating(gs.ctm)
                // Flip Y: SVG is Y-down, PDF/CoreText is Y-up
                let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
                var finalTx = trm.concatenating(flip)

                if let glyphPath = CTFontCreatePathForGlyph(ctFont, glyph, nil),
                   let transformed = glyphPath.copy(using: &finalTx) {
                    let svgD = pathToSVGD(transformed)
                    if !svgD.isEmpty { emitTextPath(svgD, fill: fill, stroke: stroke) }
                }
            }

            // Advance text matrix along the baseline
            var g = glyph
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &g, &advance, 1)
            let isSpace = unichar == 0x20
            let adv = (advance.width * Tfs + ts.charSpacing + (isSpace ? ts.wordSpacing : 0)) * Th
            ts.matrix = CGAffineTransform(translationX: adv, y: 0).concatenating(ts.matrix)
        }
    }

    private func emitTextPath(_ svgD: String, fill: Bool, stroke: Bool) {
        var attrs = "d=\"\(svgD)\""
        if fill {
            attrs += " fill=\"\(gs.fillColor)\""
            if gs.fillAlpha < 1 { attrs += " fill-opacity=\"\(f(gs.fillAlpha))\"" }
        } else {
            attrs += " fill=\"none\""
        }
        if stroke {
            attrs += " stroke=\"\(gs.strokeColor)\""
            if gs.strokeAlpha < 1 { attrs += " stroke-opacity=\"\(f(gs.strokeAlpha))\"" }
            attrs += " stroke-width=\"\(f(gs.lineWidth))\""
        } else {
            attrs += " stroke=\"none\""
        }
        elements.append("  <path \(attrs)/>")
    }

    private func pathToSVGD(_ path: CGPath) -> String {
        var d = ""
        path.applyWithBlock { elementPtr in
            let elem = elementPtr.pointee
            let pts = elem.points
            switch elem.type {
            case .moveToPoint:
                d += "M\(f(pts[0].x)),\(f(pts[0].y))"
            case .addLineToPoint:
                d += "L\(f(pts[0].x)),\(f(pts[0].y))"
            case .addQuadCurveToPoint:
                d += "Q\(f(pts[0].x)),\(f(pts[0].y)) \(f(pts[1].x)),\(f(pts[1].y))"
            case .addCurveToPoint:
                d += "C\(f(pts[0].x)),\(f(pts[0].y)) \(f(pts[1].x)),\(f(pts[1].y)) \(f(pts[2].x)),\(f(pts[2].y))"
            case .closeSubpath:
                d += "Z"
            @unknown default:
                break
            }
        }
        return d
    }

    private func cachedFont(name: String, size: CGFloat) -> CTFont {
        if let cached = fontCache[name] { return cached }
        // Strip subset prefix like "ABCDEF+Arial" → "Arial"
        var baseName = name
        if name.count > 7 {
            let idx = name.index(name.startIndex, offsetBy: 6)
            if name[idx] == "+" { baseName = String(name[name.index(after: idx)...]) }
        }
        let font = CTFontCreateWithName(baseName as CFString, size, nil)
        fontCache[name] = font
        return font
    }

    private func macRomanToUnichar(_ byte: UInt8) -> UniChar {
        guard let str = String(bytes: [byte], encoding: .macOSRoman), let ch = str.utf16.first else {
            return UniChar(byte)
        }
        return ch
    }

    // MARK: - Coordinate transform

    @inline(__always) private func txPt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let p = CGPoint(x: x, y: y).applying(gs.ctm)
        return CGPoint(x: p.x, y: H - p.y)
    }

    // MARK: - Color helpers

    private func gray(_ v: CGFloat) -> String { rgb(v, v, v) }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> String {
        let ri = Int((r * 255).rounded().clamped(to: 0...255))
        let gi = Int((g * 255).rounded().clamped(to: 0...255))
        let bi = Int((b * 255).rounded().clamped(to: 0...255))
        return String(format: "#%02x%02x%02x", ri, gi, bi)
    }

    private func cmyk(_ c: CGFloat, _ m: CGFloat, _ y: CGFloat, _ k: CGFloat) -> String {
        rgb((1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k))
    }

    // MARK: - Number formatting

    private func f(_ v: CGFloat) -> String { String(format: "%.4g", Double(v)) }
}

// MARK: - Free helpers

private func ctx(_ info: UnsafeMutableRawPointer?) -> PDFStreamScanner {
    Unmanaged<PDFStreamScanner>.fromOpaque(info!).takeUnretainedValue()
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
