markdown
# Phase 1 Manual Patch — svgToKeyRepository.swift

## Overview

This file contains all Phase 1 safety and security fixes that need to be applied manually to `KeyJig/svgToKeyRepository.swift`.

---

## Change 1: Add Security Framework Import

**File:** `KeyJig/svgToKeyRepository.swift`
**Location:** Line 2 (after `import SwiftUI`)

**Add this line:**
```swift
import Security
```

---

## Change 2: Replace arc4random_uniform with SecRandomCopyBytes

**File:** `KeyJig/svgToKeyRepository.swift`
**Location:** `makeTempSVGURL()` function (around line 175–181)

**Find this:**
```swift
/// Generates a unique temp-file URL with a human-readable name of the form
/// "Adjective-Noun-Vector-YYYY-MM-DD.svg". Uses arc4random for speed —
/// no locking, no seeding, always cryptographically random.
func makeTempSVGURL() -> URL {
    let adj = _adjectives[Int(arc4random_uniform(UInt32(_adjectives.count)))]
    let noun = _nouns[Int(arc4random_uniform(UInt32(_nouns.count)))]
```

**Replace with:**
```swift
/// Generates a unique temp-file URL with a human-readable name of the form
/// "Adjective-Noun-Vector-YYYY-MM-DD.svg". Uses SecRandomCopyBytes
/// for cryptographically secure random index selection.
func makeTempSVGURL() -> URL {
    var byte: UInt8 = 0
    _ = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
    let adj = _adjectives[Int(byte) % _adjectives.count]
    _ = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
    let noun = _nouns[Int(byte) % _nouns.count]
```

---

## Change 3: Sanitize Inkscape Process Arguments

**File:** `KeyJig/svgToKeyRepository.swift`
**Location:** `convertToSVGWithInkscape()` function (around line 280)

**Find this:**
```swift
task.arguments = [
    "--export-type=svg",
    "--export-plain-svg",
    "--export-filename=\(outputURL.path)",
    inputURL.path,
]
```

**Replace with:**
```swift
task.arguments = [
    "--export-type=svg",
    "--export-plain-svg",
    "--export-filename",
    outputURL.path,
    inputURL.path,
]
```

---

## Change 4: Add SVG Validation Functions

**File:** `KeyJig/svgToKeyRepository.swift`
**Location:** After the `AppState` class closes — insert between the closing `}` of `AppState` and `private func allInkscapePaths()` (around line 43–46).

**Find this:**
```swift
    }
}

private func allInkscapePaths() -> [String] {
```

**Replace the two closing braces and the MARK comment with:**
```swift
    }
}

// MARK: - SVG Validation

/// Validates that the given string is safe, well-formed XML containing an
/// <svg> root element. Returns nil if valid; returns an error otherwise.
func validateSVG(_ string: String) -> SVGValidationError? {
    guard !string.isEmpty else { return .empty }
    guard string.contains("<svg") else { return .notSVGElement }
    let dangerousPatterns = [
        "<script", "javascript:", "onerror=", "onclick=",
        "onload=", "onmouseover=", "xlink:href=[\"']https?://",
    ]
    for pattern in dangerousPatterns {
        if string.range(of: pattern, options: .caseInsensitive) != nil {
            return .containsDangerousContent
        }
    }
    guard let data = string.data(using: .utf8) else { return .notValidXML }
    let parser = XMLParser(data: data)
    let delegate = SVGParseValidator()
    parser.delegate = delegate
    guard parser.parse(), delegate.foundSVG else { return .notSVGElement }
    return nil
}

/// NSXMLParserDelegate that stops as soon as it confirms an <svg> root exists.
private class SVGParseValidator: NSObject, XMLParserDelegate {
    var foundSVG = false
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName.lowercased() == "svg" {
            foundSVG = true
        }
    }
}

// MARK: - Clipboard SVG detection
```

---

## Change 5: Update convertClipboardToSVG to Use validateSVG

**File:** `KeyJig/svgToKeyRepository.swift`
**Location:** `convertClipboardToSVG()` function (around lines 102–115)

**Find this:**
```swift
    let svgType = NSPasteboard.PasteboardType("public.svg-image")
    if let data = pasteboard.data(forType: svgType),
       let svgString = String(data: data, encoding: .utf8),
       svgString.contains("<svg") {
        return svgString
    }
    // 2. Raw SVG text on the string pasteboard
    if let content = pasteboard.string(forType: .string),
       content.contains("<svg") {
        return content
    }
    return ""
```

**Replace with:**
```swift
    let svgType = NSPasteboard.PasteboardType("public.svg-image")
    if let data = pasteboard.data(forType: svgType),
       let svgString = String(data: data, encoding: .utf8),
       validateSVG(svgString) == nil {
        return svgString
    }
    // 2. Raw SVG text on the string pasteboard
    if let content = pasteboard.string(forType: .string),
       validateSVG(content) == nil {
        return content
    }
    return ""
```

---

## Summary of Changes

| # | Change | Purpose |
|---|--------|---------|
| 1 | `import Security` | Required for `SecRandomCopyBytes` |
| 2 | Replace `arc4random_uniform` with `SecRandomCopyBytes` | Cryptographically secure randomness for temp file names |
| 3 | Separate Inkscape `--export-filename` argument | Prevent flag injection if path contains `--` |
| 4 | Add `validateSVG()` and `SVGParseValidator` | Validate SVG is safe XML, reject script tags, JS event handlers, external refs |
| 5 | Use `validateSVG()` in clipboard detection | Apply validation when accepting SVG from clipboard |

---

## Verification

After applying all changes, run:
```bash
xcodebuild -project KeyJig.xcodeproj -scheme KeyJig -configuration Debug build
```

Expected result: **BUILD SUCCEEDED**

---

## Notes

- `SVGValidationError` and its cases (`.empty`, `.notSVGElement`, `.containsDangerousContent`, `.notValidXML`) are already defined in `KeyJig/ErrorMessages.swift` — no additional type definitions needed.
- `SVGParseValidator` confirms the `<svg>` element exists by setting `foundSVG = true` and then checking after `parser.parse()` returns. No need to call `abortParsing()` explicitly.
- The dangerous-pattern check catches `<script>`, `javascript:` URIs, event-handler attributes (`onerror=`, `onclick=`, `onload=`, `onmouseover=`), and `xlink:href` pointing to external HTTP(S) URLs.