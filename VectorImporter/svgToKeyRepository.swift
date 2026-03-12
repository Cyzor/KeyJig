import Cocoa
import SwiftUI

class AppState: ObservableObject {
    @Published var svgURL: String = ""
    @Published var svgString: String = ""
}

func convertClipboardToSVG() -> String {
    let pasteboard = NSPasteboard.general

    // 1. Check for explicit SVG types (Affinity Designer often provides this)
    let svgType = NSPasteboard.PasteboardType("public.svg-image")
    if let data = pasteboard.data(forType: svgType),
        let svgString = String(data: data, encoding: .utf8)
    {
        return svgString
    }

    // 2. Check for raw SVG text in the string type
    if let content = pasteboard.string(forType: .string), content.contains("<svg") {
        return content
    }

    return ""
}

func getTempSVGURL() -> URL {
    let tempDir = NSTemporaryDirectory()
    return URL(fileURLWithPath: tempDir).appendingPathComponent("VectorImporter_bridge.svg")
}

func svgToClipboard(svgData: String) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()

    let tempFile = getTempSVGURL()

    do {
        try svgData.write(to: tempFile, atomically: true, encoding: .utf8)
        // Put the file URL on the pasteboard.
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
    let inkscapePaths = [
        "/usr/local/bin/inkscape", "/opt/homebrew/bin/inkscape",
        "/Applications/Inkscape.app/Contents/MacOS/inkscape",
    ]
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
    } catch {}
    return false
}

// Extract SVG dimensions from SVG string
func extractSVGDimensions(svgString: String) -> (width: String, height: String)? {
    // Look for viewBox attribute first (more reliable)
    if let viewBoxRange = svgString.range(
        of: "viewBox=[\"']([^\"']+)[\"']", options: .regularExpression)
    {
        let viewBoxValue = String(svgString[viewBoxRange])
        let cleanValue = String(viewBoxValue.dropFirst(9).dropLast(1))
        let parts = cleanValue.split(separator: " ")
        if parts.count >= 4 {
            return (String(parts[2]), String(parts[3]))
        }
    }

    // Fallback: look for width and height attributes
    var width: String?
    var height: String?

    if let widthRange = svgString.range(
        of: "width=[\"']([^\"']+)[\"']", options: .regularExpression)
    {
        let widthValue = String(svgString[widthRange])
        width = String(widthValue.dropFirst(7).dropLast(1))
    }
    if let heightRange = svgString.range(
        of: "height=[\"']([^\"']+)[\"']", options: .regularExpression)
    {
        let heightValue = String(svgString[heightRange])
        height = String(heightValue.dropFirst(8).dropLast(1))
    }

    if let w = width, let h = height {
        return (w, h)
    }

    return nil
}

// Get file size in human-readable format
func getFileSizeString(svgString: String) -> String {
    let bytes = svgString.utf8.count

    if bytes < 1024 {
        return "\(bytes) B"
    } else if bytes < 1024 * 1024 {
        let kb = Double(bytes) / 1024.0
        return String(format: "%.1f KB", kb)
    } else {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }
}

// Extract creator/application from SVG metadata
func extractSVGCreator(svgString: String) -> String? {
    // Look for common creator attributes
    let patterns = [
        "<!--.*?Creator:\\s*([^-]+)-->",  // SVG comment format
        "<meta\\s+name=[\"']creator[\"']\\s+content=[\"']([^\"']+)[\"']",
        "application-name=[\"']([^\"']+)[\"']",
        "Creator:\\s*([^\\n<]+)",
    ]

    for pattern in patterns {
        if let range = svgString.range(of: pattern, options: .regularExpression) {
            let match = String(svgString[range])
            // Try to extract the actual value
            if let valueRange = match.range(
                of: ":\\s*(.+?)(?:[\"']|-->|<|$)", options: .regularExpression)
            {
                let value = String(match[valueRange]).trimmingCharacters(
                    in: CharacterSet(charactersIn: ": \"'"))
                if !value.isEmpty && value != "Creator" {
                    return value
                }
            }
        }
    }

    return nil
}

// Wrap SVG with responsive HTML/CSS to fill container
func wrapSVGForResponsiveDisplay(svgString: String) -> String {
    return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                html, body {
                    width: 100%;
                    height: 100%;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    background: transparent;
                }
                svg {
                    width: 100%;
                    height: 100%;
                    max-width: 100%;
                    max-height: 100%;
                    object-fit: contain;
                }
            </style>
        </head>
        <body>
            \(svgString)
        </body>
        </html>
        """
}
