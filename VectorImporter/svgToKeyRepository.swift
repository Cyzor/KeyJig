import Cocoa
import SwiftUI

class AppState: ObservableObject {
    static let shared = AppState()
    @Published var svgURL: String = ""
    @Published var svgString: String = ""
}

func convertClipboardToSVG() -> String {
    let pasteboard = NSPasteboard.general
    
    // 1. Check for explicit SVG types (Affinity Designer often provides this)
    let svgType = NSPasteboard.PasteboardType("public.svg-image")
    if let data = pasteboard.data(forType: svgType), let svgString = String(data: data, encoding: .utf8) {
        return svgString
    }
    
    // 2. Check for raw SVG text in the string type
    if let content = pasteboard.string(forType: .string), content.contains("<svg") {
        return content
    }
    
    return ""
}

func svgToClipboard(svgData: String) -> Bool {
    let pasteboard = NSPasteboard.general
    // We clear after reading if we're doing a bridge, but here we just clear to write
    pasteboard.clearContents()
    
    let tempDir = NSTemporaryDirectory()
    let tempFile = URL(fileURLWithPath: tempDir).appendingPathComponent("bridge_clip.svg")
    
    do {
        try svgData.write(to: tempFile, atomically: true, encoding: .utf8)
        // Put the file URL on the pasteboard. 
        // This is what makes Keynote use its native "Editable" engine.
        pasteboard.writeObjects([tempFile as NSURL])
        return true
    } catch {
        return false
    }
}

func pdfToClipboard(pdfData: Data?) -> Bool {
    guard let data = pdfData else { return false }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let adobePdfType = NSPasteboard.PasteboardType("com.adobe.pdf")
    let applePdfType = NSPasteboard.PasteboardType("Apple PDF pasteboard type")
    pasteboard.declareTypes([adobePdfType, applePdfType], owner: nil)
    pasteboard.setData(data, forType: adobePdfType)
    pasteboard.setData(data, forType: applePdfType)
    return true
}

func convertWithInkscape(svgPath: String) -> Bool {
    let inkscapePaths = ["/usr/local/bin/inkscape", "/opt/homebrew/bin/inkscape", "/Applications/Inkscape.app/Contents/MacOS/inkscape"]
    var foundPath: String?
    for path in inkscapePaths {
        if FileManager.default.fileExists(atPath: path) {
            foundPath = path
            break
        }
    }
    guard let path = foundPath else { return false }
    let tempPDF = "/tmp/svg_fallback.pdf"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = ["--export-type=pdf", "--export-filename=\(tempPDF)", svgPath]
    do {
        try task.run()
        task.waitUntilExit()
        if let data = try? Data(contentsOf: URL(fileURLWithPath: tempPDF)) {
            return pdfToClipboard(pdfData: data)
        }
    } catch { }
    return false
}
