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
        let page = doc.page(at: 1)
    else {
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
        var lineCap: Int32 = 0  // 0 butt · 1 round · 2 square
        var lineJoin: Int32 = 0  // 0 miter · 1 round · 2 bevel
        var miterLimit: CGFloat = 4
        var dashArray: [CGFloat] = []
        var dashPhase: CGFloat = 0
        var fillCS: CSKind = .rgb
        var strokeCS: CSKind = .rgb
    }

    // MARK: Text state

    private struct TextState {
        var matrix: CGAffineTransform = .identity  // Tm — text-to-user-space
        var lineMatrix: CGAffineTransform = .identity  // Tlm — baseline origin, used by Td/T*
        var fontResourceName: String = ""  // name in PDF resource dict (from Tf)
        var fontBaseName: String = ""  // /BaseFont PostScript name
        var fontSize: CGFloat = 12  // Tfs (from Tf)
        var charSpacing: CGFloat = 0  // Tc
        var wordSpacing: CGFloat = 0  // Tw
        var hScale: CGFloat = 100  // Tz (percent)
        var leading: CGFloat = 0  // TL
        var rise: CGFloat = 0  // Ts
        var renderMode: Int = 0  // Tr (0 fill, 1 stroke, 2 both, 3 invisible)
    }

    private var ts = TextState()

    private struct ResolvedFont {
        let ctFont: CTFont
        let cgFont: CGFont?
        let widths: [Int: CGFloat]  // charCode → width in glyph space (1000 units)
        let firstChar: Int
        let encoding: [UInt8: CGGlyph]  // charCode byte → glyph ID (for embedded fonts)
        let isEmbedded: Bool
    }
    private var fontCache: [String: ResolvedFont] = [:]

    /// Accumulator for the currently open BT…ET text run. While nil we are not
    /// inside a text block; the first Tj/TJ/'/" opens one, ET closes it. The
    /// run is then flushed to `elements` as a single `<g>` carrying the
    /// outlined glyph `<path>`s and (when a usable family resolves) a parallel
    /// `<text>` element reusing the original string.
    private struct TextRun {
        var pageTm: CGAffineTransform = .identity  // first Tm of the run (in page/user space)
        var pageTmSet: Bool = false  // first Tj/TJ adopts current Tm
        var ctmAtStart: CGAffineTransform = .identity  // CTM at run open, for wrapping <g> transform
        var string: String = ""  // original PDF text, concatenated across Tj/TJ chunks
        var pathFragments: [String] = []  // serialized SVG `d=` strings, one per outlined glyph
        var fillColor: String = "#000000"
        var strokeColor: String = "none"
        var fillAlpha: CGFloat = 1
        var strokeAlpha: CGFloat = 1
        var renderMode: Int = 0
    }

    private var run: TextRun?

    private var gsStack: [GS] = [GS()]
    private var gs: GS {
        get { gsStack.last ?? GS() }
        set {
            if gsStack.isEmpty {
                gsStack.append(newValue)
            } else {
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

    private let W: CGFloat  // width in pts
    private let H: CGFloat  // height in pts — used to flip Y axis

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
        defer {
            CGPDFOperatorTableRelease(table)
            opTable = nil
        }

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
        func reg(
            _ op: StaticString,
            _ cb: @escaping @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void
        ) {
            CGPDFOperatorTableSetCallback(t, op.utf8Start, cb)
        }

        // Graphics state
        reg("q") { s, i in ctx(i).pushGS() }
        reg("Q") { s, i in ctx(i).popGS() }
        reg("cm") { s, i in ctx(i).op_cm(s) }
        reg("w") { s, i in ctx(i).op_w(s) }
        reg("J") { s, i in ctx(i).op_J(s) }
        reg("j") { s, i in ctx(i).op_j(s) }
        reg("M") { s, i in ctx(i).op_M(s) }
        reg("d") { s, i in ctx(i).op_d(s) }

        // Color — device
        reg("g") { s, i in ctx(i).op_g(s) }
        reg("G") { s, i in ctx(i).op_G(s) }
        reg("rg") { s, i in ctx(i).op_rg(s) }
        reg("RG") { s, i in ctx(i).op_RG(s) }
        reg("k") { s, i in ctx(i).op_k(s) }
        reg("K") { s, i in ctx(i).op_K(s) }

        // Color — colorspace + set-color families
        reg("cs") { s, i in ctx(i).op_cs(s, fill: true) }
        reg("CS") { s, i in ctx(i).op_cs(s, fill: false) }
        reg("sc") { s, i in ctx(i).op_sc(s, fill: true, extended: false) }
        reg("SC") { s, i in ctx(i).op_sc(s, fill: false, extended: false) }
        reg("scn") { s, i in ctx(i).op_sc(s, fill: true, extended: true) }
        reg("SCN") { s, i in ctx(i).op_sc(s, fill: false, extended: true) }

        // Transparency
        reg("ca") { s, i in ctx(i).op_ca(s, fill: true) }
        reg("CA") { s, i in ctx(i).op_ca(s, fill: false) }

        // Path construction
        reg("m") { s, i in ctx(i).op_m(s) }
        reg("l") { s, i in ctx(i).op_l(s) }
        reg("c") { s, i in ctx(i).op_c(s) }
        reg("v") { s, i in ctx(i).op_v(s) }
        reg("y") { s, i in ctx(i).op_y(s) }
        reg("h") { s, i in ctx(i).op_h() }
        reg("re") { s, i in ctx(i).op_re(s) }

        // Path painting
        reg("S") { s, i in ctx(i).paint(fill: false, stroke: true, close: false, eo: false) }
        reg("s") { s, i in ctx(i).paint(fill: false, stroke: true, close: true, eo: false) }
        reg("f") { s, i in ctx(i).paint(fill: true, stroke: false, close: false, eo: false) }
        reg("F") { s, i in ctx(i).paint(fill: true, stroke: false, close: false, eo: false) }
        reg("f*") { s, i in ctx(i).paint(fill: true, stroke: false, close: false, eo: true) }
        reg("B") { s, i in ctx(i).paint(fill: true, stroke: true, close: false, eo: false) }
        reg("B*") { s, i in ctx(i).paint(fill: true, stroke: true, close: false, eo: true) }
        reg("b") { s, i in ctx(i).paint(fill: true, stroke: true, close: true, eo: false) }
        reg("b*") { s, i in ctx(i).paint(fill: true, stroke: true, close: true, eo: true) }
        reg("n") { s, i in ctx(i).clearPath() }

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
        reg("'") { s, i in ctx(i).op_apos(s) }
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
    private func popGS() { if gsStack.count > 1 { gsStack.removeLast() } }

    private func op_cm(_ s: CGPDFScannerRef) {
        var f: CGPDFReal = 0
        var e: CGPDFReal = 0
        var d: CGPDFReal = 1
        var cc: CGPDFReal = 0
        var b: CGPDFReal = 0
        var a: CGPDFReal = 1
        CGPDFScannerPopNumber(s, &f)
        CGPDFScannerPopNumber(s, &e)
        CGPDFScannerPopNumber(s, &d)
        CGPDFScannerPopNumber(s, &cc)
        CGPDFScannerPopNumber(s, &b)
        CGPDFScannerPopNumber(s, &a)
        let m = CGAffineTransform(
            a: CGFloat(a), b: CGFloat(b), c: CGFloat(cc),
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
        gs.fillColor = gray(CGFloat(v))
        gs.fillCS = .gray
    }
    private func op_G(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &v)
        gs.strokeColor = gray(CGFloat(v))
        gs.strokeCS = .gray
    }
    private func op_rg(_ s: CGPDFScannerRef) {
        var b: CGPDFReal = 0
        var g: CGPDFReal = 0
        var r: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &b)
        CGPDFScannerPopNumber(s, &g)
        CGPDFScannerPopNumber(s, &r)
        self.gs.fillColor = rgb(CGFloat(r), CGFloat(g), CGFloat(b))
        self.gs.fillCS = .rgb
    }
    private func op_RG(_ s: CGPDFScannerRef) {
        var b: CGPDFReal = 0
        var g: CGPDFReal = 0
        var r: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &b)
        CGPDFScannerPopNumber(s, &g)
        CGPDFScannerPopNumber(s, &r)
        self.gs.strokeColor = rgb(CGFloat(r), CGFloat(g), CGFloat(b))
        self.gs.strokeCS = .rgb
    }
    private func op_k(_ s: CGPDFScannerRef) {
        var k: CGPDFReal = 0
        var y: CGPDFReal = 0
        var m: CGPDFReal = 0
        var c: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &k)
        CGPDFScannerPopNumber(s, &y)
        CGPDFScannerPopNumber(s, &m)
        CGPDFScannerPopNumber(s, &c)
        gs.fillColor = cmyk(CGFloat(c), CGFloat(m), CGFloat(y), CGFloat(k))
        gs.fillCS = .cmyk
    }
    private func op_K(_ s: CGPDFScannerRef) {
        var k: CGPDFReal = 0
        var y: CGPDFReal = 0
        var m: CGPDFReal = 0
        var c: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &k)
        CGPDFScannerPopNumber(s, &y)
        CGPDFScannerPopNumber(s, &m)
        CGPDFScannerPopNumber(s, &c)
        gs.strokeColor = cmyk(CGFloat(c), CGFloat(m), CGFloat(y), CGFloat(k))
        gs.strokeCS = .cmyk
    }

    private func op_cs(_ s: CGPDFScannerRef, fill: Bool) {
        var ptr: UnsafePointer<CChar>? = nil
        guard CGPDFScannerPopName(s, &ptr), let ptr else { return }
        let name = String(cString: ptr)
        var kind: CSKind
        switch name {
        case "DeviceGray", "CalGray": kind = .gray
        case "DeviceRGB", "CalRGB": kind = .rgb
        case "DeviceCMYK": kind = .cmyk
        default:
            kind = .other
            // Resolve named colorspace from resources
            let cs = CGPDFScannerGetContentStream(s)
            if let csObj = CGPDFContentStreamGetResource(cs, "ColorSpace", name) {
                kind = resolveColorSpaceKind(csObj)
            }
        }
        if fill { gs.fillCS = kind } else { gs.strokeCS = kind }
    }

    private func resolveColorSpaceKind(_ obj: CGPDFObjectRef) -> CSKind {
        // Could be a name (direct) or an array [/ICCBased stream] or [/Separation ...]
        var namePtr: UnsafePointer<CChar>? = nil
        if CGPDFObjectGetValue(obj, .name, &namePtr), let namePtr {
            let n = String(cString: namePtr)
            switch n {
            case "DeviceGray", "CalGray": return .gray
            case "DeviceRGB", "CalRGB": return .rgb
            case "DeviceCMYK": return .cmyk
            default: return .other
            }
        }
        var arr: CGPDFArrayRef? = nil
        guard CGPDFObjectGetValue(obj, .array, &arr), let arr else { return .other }
        var typePtr: UnsafePointer<CChar>? = nil
        guard CGPDFArrayGetName(arr, 0, &typePtr), let typePtr else { return .other }
        let typeName = String(cString: typePtr)
        switch typeName {
        case "ICCBased":
            var stream: CGPDFStreamRef? = nil
            if CGPDFArrayGetStream(arr, 1, &stream), let stream {
                let dict = CGPDFStreamGetDictionary(stream)!
                var n: CGPDFInteger = 0
                if CGPDFDictionaryGetInteger(dict, "N", &n) {
                    switch n {
                    case 1: return .gray
                    case 3: return .rgb
                    case 4: return .cmyk
                    default: break
                    }
                }
            }
            return .other
        case "Separation", "DeviceN":
            return .other
        case "Indexed":
            // Base colorspace is at index 1
            var baseObj: CGPDFObjectRef? = nil
            if CGPDFArrayGetObject(arr, 1, &baseObj), let baseObj {
                return resolveColorSpaceKind(baseObj)
            }
            return .other
        default:
            return .other
        }
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
        case (.gray, 1): color = gray(comps[0])
        case (.rgb, 3): color = rgb(comps[0], comps[1], comps[2])
        case (.cmyk, 4): color = cmyk(comps[0], comps[1], comps[2], comps[3])
        case (_, 1): color = gray(comps[0])
        case (_, 3): color = rgb(comps[0], comps[1], comps[2])
        case (_, 4): color = cmyk(comps[0], comps[1], comps[2], comps[3])
        default: return
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
        var y: CGPDFReal = 0
        var x: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &y)
        CGPDFScannerPopNumber(s, &x)
        cx = CGFloat(x)
        cy = CGFloat(y)
        let p = txPt(cx, cy)
        pathData += "M\(f(p.x)),\(f(p.y))"
    }
    private func op_l(_ s: CGPDFScannerRef) {
        var y: CGPDFReal = 0
        var x: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &y)
        CGPDFScannerPopNumber(s, &x)
        cx = CGFloat(x)
        cy = CGFloat(y)
        let p = txPt(cx, cy)
        pathData += "L\(f(p.x)),\(f(p.y))"
    }
    private func op_c(_ s: CGPDFScannerRef) {
        var y3: CGPDFReal = 0
        var x3: CGPDFReal = 0
        var y2: CGPDFReal = 0
        var x2: CGPDFReal = 0
        var y1: CGPDFReal = 0
        var x1: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &y3)
        CGPDFScannerPopNumber(s, &x3)
        CGPDFScannerPopNumber(s, &y2)
        CGPDFScannerPopNumber(s, &x2)
        CGPDFScannerPopNumber(s, &y1)
        CGPDFScannerPopNumber(s, &x1)
        cx = CGFloat(x3)
        cy = CGFloat(y3)
        let p1 = txPt(CGFloat(x1), CGFloat(y1))
        let p2 = txPt(CGFloat(x2), CGFloat(y2))
        let p3 = txPt(cx, cy)
        pathData += "C\(f(p1.x)),\(f(p1.y)) \(f(p2.x)),\(f(p2.y)) \(f(p3.x)),\(f(p3.y))"
    }
    private func op_v(_ s: CGPDFScannerRef) {
        // First control point = current point
        var y3: CGPDFReal = 0
        var x3: CGPDFReal = 0
        var y2: CGPDFReal = 0
        var x2: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &y3)
        CGPDFScannerPopNumber(s, &x3)
        CGPDFScannerPopNumber(s, &y2)
        CGPDFScannerPopNumber(s, &x2)
        let p1 = txPt(cx, cy)
        cx = CGFloat(x3)
        cy = CGFloat(y3)
        let p2 = txPt(CGFloat(x2), CGFloat(y2))
        let p3 = txPt(cx, cy)
        pathData += "C\(f(p1.x)),\(f(p1.y)) \(f(p2.x)),\(f(p2.y)) \(f(p3.x)),\(f(p3.y))"
    }
    private func op_y(_ s: CGPDFScannerRef) {
        // Last control point = endpoint
        var y3: CGPDFReal = 0
        var x3: CGPDFReal = 0
        var y1: CGPDFReal = 0
        var x1: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &y3)
        CGPDFScannerPopNumber(s, &x3)
        CGPDFScannerPopNumber(s, &y1)
        CGPDFScannerPopNumber(s, &x1)
        let p1 = txPt(CGFloat(x1), CGFloat(y1))
        cx = CGFloat(x3)
        cy = CGFloat(y3)
        let p3 = txPt(cx, cy)
        pathData += "C\(f(p1.x)),\(f(p1.y)) \(f(p3.x)),\(f(p3.y)) \(f(p3.x)),\(f(p3.y))"
    }
    private func op_h() {
        pathData += "Z"
    }
    private func op_re(_ s: CGPDFScannerRef) {
        var hh: CGPDFReal = 0
        var ww: CGPDFReal = 0
        var y: CGPDFReal = 0
        var x: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &hh)
        CGPDFScannerPopNumber(s, &ww)
        CGPDFScannerPopNumber(s, &y)
        CGPDFScannerPopNumber(s, &x)
        let bl = txPt(CGFloat(x), CGFloat(y))
        let br = txPt(CGFloat(x) + CGFloat(ww), CGFloat(y))
        let tr = txPt(CGFloat(x) + CGFloat(ww), CGFloat(y) + CGFloat(hh))
        let tl = txPt(CGFloat(x), CGFloat(y) + CGFloat(hh))
        pathData +=
            "M\(f(bl.x)),\(f(bl.y))L\(f(br.x)),\(f(br.y))L\(f(tr.x)),\(f(tr.y))L\(f(tl.x)),\(f(tl.y))Z"
        cx = CGFloat(x)
        cy = CGFloat(y)
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
            let sc = ctmScale
            attrs += " stroke-width=\"\(f(gs.lineWidth * sc))\""
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
                let da = gs.dashArray.map { f($0 * sc) }.joined(separator: ",")
                attrs += " stroke-dasharray=\"\(da)\""
                if gs.dashPhase != 0 { attrs += " stroke-dashoffset=\"\(f(gs.dashPhase * sc))\"" }
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
            String(cString: subtypePtr!) == "Form"
        else { return }

        // Save/restore graphics state around the Form XObject
        pushGS()

        // Apply the XObject's optional Matrix (in addition to the current CTM)
        var matrixArray: CGPDFArrayRef? = nil
        if CGPDFDictionaryGetArray(dict, "Matrix", &matrixArray), let matrixArray {
            var a: CGPDFReal = 1
            var b: CGPDFReal = 0
            var c: CGPDFReal = 0
            var d: CGPDFReal = 1
            var e: CGPDFReal = 0
            var ff: CGPDFReal = 0
            CGPDFArrayGetNumber(matrixArray, 0, &a)
            CGPDFArrayGetNumber(matrixArray, 1, &b)
            CGPDFArrayGetNumber(matrixArray, 2, &c)
            CGPDFArrayGetNumber(matrixArray, 3, &d)
            CGPDFArrayGetNumber(matrixArray, 4, &e)
            CGPDFArrayGetNumber(matrixArray, 5, &ff)
            let xm = CGAffineTransform(
                a: CGFloat(a), b: CGFloat(b), c: CGFloat(c),
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
        run = TextRun()
        run?.ctmAtStart = gs.ctm
    }

    private func op_ET() {
        flushTextRun()
        // No other state to clean up; text state persists across BT/ET per spec.
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

        let cs = CGPDFScannerGetContentStream(s)
        guard let fontObj = CGPDFContentStreamGetResource(cs, "Font", resourceName) else { return }
        var fontDict: CGPDFDictionaryRef? = nil
        guard CGPDFObjectGetValue(fontObj, .dictionary, &fontDict), let fontDict else { return }
        var baseFontPtr: UnsafePointer<CChar>? = nil
        if CGPDFDictionaryGetName(fontDict, "BaseFont", &baseFontPtr), let baseFontPtr {
            ts.fontBaseName = String(cString: baseFontPtr)
        }

        if fontCache[resourceName] == nil {
            fontCache[resourceName] = resolveFont(fontDict)
        }
    }

    private func resolveFont(_ fontDict: CGPDFDictionaryRef) -> ResolvedFont {
        let baseName = ts.fontBaseName

        // 1. Try to extract embedded font data
        var descDict: CGPDFDictionaryRef? = nil
        var embeddedCGFont: CGFont? = nil
        if CGPDFDictionaryGetDictionary(fontDict, "FontDescriptor", &descDict), let descDict {
            embeddedCGFont = extractEmbeddedFont(descDict)
        }

        // 2. Build CTFont: prefer embedded, fall back to system font by name
        let ctFont: CTFont
        if let cgFont = embeddedCGFont {
            ctFont = CTFontCreateWithGraphicsFont(cgFont, 1.0, nil, nil)
        } else {
            var name = baseName
            if name.count > 7, name[name.index(name.startIndex, offsetBy: 6)] == "+" {
                name = String(name.dropFirst(7))
            }
            ctFont = CTFontCreateWithName(name as CFString, 1.0, nil)
        }

        // 3. Read /Widths and /FirstChar from the PDF font dictionary
        var firstChar: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(fontDict, "FirstChar", &firstChar)
        var widths: [Int: CGFloat] = [:]
        var widthsArr: CGPDFArrayRef? = nil
        if CGPDFDictionaryGetArray(fontDict, "Widths", &widthsArr), let widthsArr {
            let count = CGPDFArrayGetCount(widthsArr)
            for i in 0..<count {
                var w: CGPDFReal = 0
                if CGPDFArrayGetNumber(widthsArr, i, &w) {
                    widths[Int(firstChar) + i] = CGFloat(w)
                }
            }
        }

        // 4. Build encoding: charCode byte → glyph ID
        let encoding = buildEncodingMap(fontDict: fontDict, ctFont: ctFont, cgFont: embeddedCGFont)

        let isEmbedded = embeddedCGFont != nil
        return ResolvedFont(ctFont: ctFont, cgFont: embeddedCGFont, widths: widths,
                            firstChar: Int(firstChar), encoding: encoding, isEmbedded: isEmbedded)
    }

    private func extractEmbeddedFont(_ descDict: CGPDFDictionaryRef) -> CGFont? {
        var stream: CGPDFStreamRef? = nil
        let found = CGPDFDictionaryGetStream(descDict, "FontFile2", &stream)
            || CGPDFDictionaryGetStream(descDict, "FontFile3", &stream)
            || CGPDFDictionaryGetStream(descDict, "FontFile", &stream)
        guard found, let stream else { return nil }
        var format: CGPDFDataFormat = .raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return nil }
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGFont(provider)
    }

    private func buildEncodingMap(fontDict: CGPDFDictionaryRef, ctFont: CTFont, cgFont: CGFont?) -> [UInt8: CGGlyph] {
        var map: [UInt8: CGGlyph] = [:]

        // Read /Encoding from font dict
        var encObj: CGPDFObjectRef? = nil
        var diffArr: CGPDFArrayRef? = nil
        if CGPDFDictionaryGetObject(fontDict, "Encoding", &encObj), let encObj {
            var encNamePtr: UnsafePointer<CChar>? = nil
            var encDict: CGPDFDictionaryRef? = nil
            if CGPDFObjectGetValue(encObj, .name, &encNamePtr) {
                // Named encoding like "WinAnsiEncoding" — no /Differences to process
            } else if CGPDFObjectGetValue(encObj, .dictionary, &encDict), let encDict {
                CGPDFDictionaryGetArray(encDict, "Differences", &diffArr)
            }
        }

        // Process /Differences array: [code name name ... code name ...]
        if let diffArr, let font = cgFont ?? (CTFontCopyGraphicsFont(ctFont, nil) as CGFont?) {
            let count = CGPDFArrayGetCount(diffArr)
            var currentCode: Int = 0
            for i in 0..<count {
                var intVal: CGPDFInteger = 0
                var namePtr: UnsafePointer<CChar>? = nil
                if CGPDFArrayGetInteger(diffArr, i, &intVal) {
                    currentCode = Int(intVal)
                } else if CGPDFArrayGetName(diffArr, i, &namePtr), let namePtr {
                    let glyphName = String(cString: namePtr)
                    let glyph = font.getGlyphWithGlyphName(name: glyphName as CFString)
                    if glyph != 0 && currentCode >= 0 && currentCode <= 255 {
                        map[UInt8(currentCode)] = glyph
                    }
                    currentCode += 1
                }
            }
        }

        return map
    }

    private func op_Tc(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &v)
        ts.charSpacing = CGFloat(v)
    }
    private func op_Tw(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &v)
        ts.wordSpacing = CGFloat(v)
    }
    private func op_Tz(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 100
        CGPDFScannerPopNumber(s, &v)
        ts.hScale = CGFloat(v)
    }
    private func op_TL(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &v)
        ts.leading = CGFloat(v)
    }
    private func op_Ts(_ s: CGPDFScannerRef) {
        var v: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &v)
        ts.rise = CGFloat(v)
    }
    private func op_Tr(_ s: CGPDFScannerRef) {
        var v: CGPDFInteger = 0
        CGPDFScannerPopInteger(s, &v)
        ts.renderMode = Int(v)
    }

    private func op_Td(_ s: CGPDFScannerRef, setLeading: Bool) {
        var ty: CGPDFReal = 0
        var tx: CGPDFReal = 0
        CGPDFScannerPopNumber(s, &ty)
        CGPDFScannerPopNumber(s, &tx)
        if setLeading { ts.leading = -CGFloat(ty) }
        let move = CGAffineTransform(translationX: CGFloat(tx), y: CGFloat(ty))
        ts.lineMatrix = move.concatenating(ts.lineMatrix)
        ts.matrix = ts.lineMatrix
    }

    private func op_Tm(_ s: CGPDFScannerRef) {
        var f: CGPDFReal = 0
        var e: CGPDFReal = 0
        var d: CGPDFReal = 1
        var c: CGPDFReal = 0
        var b: CGPDFReal = 0
        var a: CGPDFReal = 1
        CGPDFScannerPopNumber(s, &f)
        CGPDFScannerPopNumber(s, &e)
        CGPDFScannerPopNumber(s, &d)
        CGPDFScannerPopNumber(s, &c)
        CGPDFScannerPopNumber(s, &b)
        CGPDFScannerPopNumber(s, &a)
        let m = CGAffineTransform(
            a: CGFloat(a), b: CGFloat(b), c: CGFloat(c),
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
        var charSpace: CGPDFReal = 0
        var wordSpace: CGPDFReal = 0
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

        // Build display string for the parallel <text> element (best-effort)
        if let cfStr = CGPDFStringCopyTextString(str), let s = (cfStr as String).nilIfEmpty {
            run?.string.append(s)
        }

        // First Tj/TJ inside a run locks in the run's start Tm for the <text> x/y.
        if var r = run, !r.pageTmSet {
            r.pageTm = ts.matrix
            r.pageTmSet = true
            r.fillColor = gs.fillColor
            r.strokeColor = gs.strokeColor
            r.fillAlpha = gs.fillAlpha
            r.strokeAlpha = gs.strokeAlpha
            r.renderMode = ts.renderMode
            run = r
        }

        showBytes(bytes)
    }

    private func showBytes(_ bytes: [UInt8]) {
        guard let resolved = fontCache[ts.fontResourceName] else { return }
        let Tfs = ts.fontSize
        let Th = ts.hScale / 100.0
        let fill =
            ts.renderMode == 0 || ts.renderMode == 2 || ts.renderMode == 4 || ts.renderMode == 6
        let stroke =
            ts.renderMode == 1 || ts.renderMode == 2 || ts.renderMode == 5 || ts.renderMode == 6

        for byte in bytes {
            // Resolve glyph: prefer PDF encoding map, fall back to Unicode lookup
            var glyph: CGGlyph = 0
            if let mapped = resolved.encoding[byte] {
                glyph = mapped
            } else {
                var ch = UniChar(byte)
                CTFontGetGlyphsForCharacters(resolved.ctFont, &ch, &glyph, 1)
            }

            if glyph != 0 {
                let scaleTx = CGAffineTransform(
                    a: Tfs * Th, b: 0, c: 0, d: Tfs,
                    tx: 0, ty: ts.rise)
                let trm = scaleTx.concatenating(ts.matrix).concatenating(gs.ctm)
                let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
                var finalTx = trm.concatenating(flip)

                if let glyphPath = CTFontCreatePathForGlyph(resolved.ctFont, glyph, nil),
                    let transformed = glyphPath.copy(using: &finalTx)
                {
                    let svgD = pathToSVGD(transformed)
                    if !svgD.isEmpty { emitTextPath(svgD, fill: fill, stroke: stroke) }
                }
            }

            // Advance: prefer PDF /Widths, fall back to font metrics
            let charCode = Int(byte)
            var advWidth: CGFloat
            if let pdfWidth = resolved.widths[charCode] {
                advWidth = pdfWidth / 1000.0  // PDF widths are in 1/1000 of text space
            } else {
                var g = glyph
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(resolved.ctFont, .horizontal, &g, &advance, 1)
                advWidth = advance.width
            }
            let isSpace = (byte == 0x20)
            let adv = (advWidth * Tfs + ts.charSpacing + (isSpace ? ts.wordSpacing : 0)) * Th
            ts.matrix = CGAffineTransform(translationX: adv, y: 0).concatenating(ts.matrix)
        }
    }

    private func emitTextPath(_ svgD: String, fill: Bool, stroke: Bool) {
        // While inside a BT…ET run, accumulate paths; otherwise emit directly
        // (kept as a defensive fallback for malformed streams with shows outside BT).
        if run != nil {
            run?.pathFragments.append(svgD)
            return
        }
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
            attrs += " stroke-width=\"\(f(gs.lineWidth * ctmScale))\""
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
                d +=
                    "C\(f(pts[0].x)),\(f(pts[0].y)) \(f(pts[1].x)),\(f(pts[1].y)) \(f(pts[2].x)),\(f(pts[2].y))"
            case .closeSubpath:
                d += "Z"
            @unknown default:
                break
            }
        }
        return d
    }


    // MARK: - Text run flush

    /// Emits the open run as a single unwrapped `<path>` element aggregating
    /// every outlined glyph (so break-apart yields one shape node, not N) plus,
    /// when a usable family name resolves, a `<g>` wrapping a parallel `<text>`
    /// element. Drops runs with nothing to draw.
    private func flushTextRun() {
        guard let run, !(run.pathFragments.isEmpty && run.string.isEmpty) else {
            self.run = nil
            return
        }

        // Outlined glyph paths are already in page-space SVG coordinates
        // (the per-glyph Y-flip happened inside showUnichars), so they are
        // emitted bare without any extra transform.
        if !run.pathFragments.isEmpty {
            let fillAttr: String
            let alphaAttr: String
            let isFill =
                run.renderMode == 0 || run.renderMode == 2
                || run.renderMode == 4 || run.renderMode == 6
            if isFill {
                fillAttr = " fill=\"\(run.fillColor)\""
                alphaAttr =
                    run.fillAlpha < 1
                    ? " fill-opacity=\"\(f(run.fillAlpha))\"" : ""
            } else {
                fillAttr = " fill=\"none\""
                alphaAttr = ""
            }
            let strokeAttr =
                (run.renderMode == 1 || run.renderMode == 2
                    || run.renderMode == 5 || run.renderMode == 6)
                ? " stroke=\"\(run.strokeColor)\" stroke-width=\"\(f(gs.lineWidth * ctmScale))\""
                : " stroke=\"none\""
            let combined = run.pathFragments.joined()
            elements.append("<path d=\"\(combined)\"\(fillAttr)\(alphaAttr)\(strokeAttr)/>")
        }

        // Parallel <text>: only fill-mode runs qualify; stroke or invisible
        // runs would render <text> wrongly in apps that honor it.
        let isFill =
            run.renderMode == 0 || run.renderMode == 2
            || run.renderMode == 4 || run.renderMode == 6
        let trimmed = run.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFill, !trimmed.isEmpty, let family = resolvedTextFamily() {
            // Adapt the run's PDF-Y-up text matrix into an SVG-Y-down canvas
            // transform. flipY is its own inverse, so flipY · M · flipY reduces
            // piece-wise to: keep a/d/tx, negate b/c, transform ty = H - ty.
            let m = run.pageTm.concatenating(run.ctmAtStart)
            let adapted = CGAffineTransform(
                a: m.a, b: -m.b, c: -m.c, d: m.d,
                tx: m.tx, ty: H - m.ty
            )
            let txAttr = affineToAttr(adapted)
            let safeFamily = family.replacingOccurrences(of: "\"", with: "")
            let escaped = xmlEscape(run.string)
            let fillColor = run.fillColor
            let fillOpacity =
                run.fillAlpha < 1
                ? " fill-opacity=\"\(f(run.fillAlpha))\"" : ""
            let gOpen = "<g transform=\"\(txAttr)\">"
            let textOpen =
                "<text x=\"0\" y=\"0\" font-family=\"\(safeFamily)\""
                + " font-size=\"\(f(ts.fontSize))\" fill=\"\(fillColor)\"\(fillOpacity)"
                + " xml:space=\"preserve\">"
            elements.append("\(gOpen)\n    \(textOpen)\(escaped)</text>\n  </g>")
        }

        self.run = nil
    }

    /// Returns a CSS-safe font-family for the resolved CTFont, or nil if the
    /// alignment is unusable (LastResort, .AppleSystemUIFont, empty, missing).
    private func resolvedTextFamily() -> String? {
        guard !ts.fontBaseName.isEmpty else { return nil }
        guard let resolved = fontCache[ts.fontResourceName] else { return nil }
        let f = resolved.ctFont
        // CTFont's accessor for family uses the C API; the bridge returns CFString.
        let cfName = CTFontCopyFamilyName(f)
        var name = (cfName as String?) ?? ""
        if name.isEmpty { return nil }
        let lower = name.lowercased()
        // Reject CoreText placeholder fonts we shouldn't advertise as families.
        if lower.contains("lastresort") || lower.contains(".apple") { return nil }
        // Strip the postScript-style suffix for common cases; keep raw if unsure.
        // CSS font-family ignores weights beyond the "Bold/Oblique" family split
        // only when the PostScript name is a compound like "Helvetica-Bold".
        if let dash = name.firstIndex(of: "-"), name[dash...].count > 1 {
            let tail = String(name[name.index(after: dash)...]).lowercased()
            if ["bold", "italic", "oblique", "bolditalic", "boldoblique"].contains(tail) {
                name = String(name[..<dash])
            }
        }
        return name
    }

    private func affineToAttr(_ t: CGAffineTransform) -> String {
        // Standard SVG "matrix(a b c d e f)" ordering.
        if t.isIdentity { return "matrix(1 0 0 1 0 0)" }
        return "matrix(\(f(t.a)) \(f(t.b)) \(f(t.c)) \(f(t.d)) \(f(t.tx)) \(f(t.ty)))"
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

    private var ctmScale: CGFloat {
        sqrt(abs(gs.ctm.a * gs.ctm.d - gs.ctm.b * gs.ctm.c))
    }
}

// MARK: - Free helpers

private func ctx(_ info: UnsafeMutableRawPointer?) -> PDFStreamScanner {
    Unmanaged<PDFStreamScanner>.fromOpaque(info!).takeUnretainedValue()
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension String {
    /// Returns nil when the string is empty.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Escape the three XML-significant characters in PDF text content before it
/// reaches an SVG `<text>` element. We use a placeholder for `&` first, then
/// substitute each entity in a final pass so that the resulting strings do not
/// contain literal `<`, `>`, or `&`.
private func xmlEscape(_ s: String) -> String {
    // Placeholder bytes chosen so they cannot already appear in PDF strings.
    let AMP = "\u{01}"
    let LT = "\u{02}"
    let GT = "\u{03}"
    var raw = s
    raw = raw.replacingOccurrences(of: "&", with: AMP)
    raw = raw.replacingOccurrences(of: "<", with: LT)
    raw = raw.replacingOccurrences(of: ">", with: GT)
    raw = raw.replacingOccurrences(of: AMP, with: "\u{0026}\u{0061}\u{006D}\u{0070}\u{003B}")
    raw = raw.replacingOccurrences(of: LT, with: "\u{0026}\u{006C}\u{0074}\u{003B}")
    raw = raw.replacingOccurrences(of: GT, with: "\u{0026}\u{0067}\u{0074}\u{003B}")
    return raw
}
