//
//  ErrorMessages.swift
//  KeyJig
//
//  Centralized error message mapper that converts system errors into user-friendly strings.
//  Used by ScriptingCommands and UI components to provide consistent, helpful feedback.
//

import Cocoa

// MARK: - Error Message Struct

struct ErrorMessages {

    // MARK: File Reading Errors

    /// Converts file reading errors into user-friendly messages.
    static func fileReadError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoSuchFileError:
                return "The file could not be found."
            case NSFileReadNoPermissionError:
                return "You don't have permission to read this file."
            case NSFileReadInvalidFileNameError:
                return "The file name is invalid."
            case NSFileReadCorruptFileError:
                return "The file appears to be corrupted."
            default:
                return "Unable to read the file."
            }
        } else if nsError.domain == NSPOSIXErrorDomain {
            switch Int(nsError.code) {
            case Int(ENOENT):  // No such file or directory
                return "The file could not be found."
            case Int(EACCES):  // Permission denied
                return "You don't have permission to read this file."
            case Int(EBADF):  // Bad file descriptor
                return "The file appears to be corrupted."
            default:
                return "Unable to read the file."
            }
        }
        return "An unknown error occurred while reading the file."
    }

    // MARK: SVG Errors

    /// Converts SVG validation errors into user-friendly messages.
    static func svgError(_ error: Error) -> String {
        if let svgError = error as? SVGValidationError {
            return svgError.errorDescription ?? "The SVG is invalid."
        }
        if let sizeError = error as? SizeLimitError {
            return sizeError.errorDescription ?? "The file exceeds size limits."
        }
        return "The SVG could not be processed."
    }

    // MARK: Inkscape Errors

    /// Converts Inkscape-related errors into user-friendly messages.
    static func inkscapeError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, Int(nsError.code) == Int(ENOENT) {
            return
                "Inkscape is not installed or cannot be found. Please install it from inkscape.org"
        }
        return "The conversion failed. Please ensure Inkscape is installed."
    }

    // MARK: Clipboard Errors

    /// Converts clipboard access errors into user-friendly messages.
    static func clipboardError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            // Cocoa error codes for pasteboard operations
            switch nsError.code {
            case 256:  // NSPasteboard.PasteboardError.couldNotReadFromPasteboard
                return "Unable to read from the clipboard."
            case 257:  // NSPasteboard.PasteboardError.couldNotWriteToPasteboard
                return "Unable to write to the clipboard."
            default:
                break
            }
        }
        return "Unable to access the clipboard."
    }

    // MARK: General Errors

    /// Generic error message for unknown errors.
    static func generalError(_ error: Error) -> String {
        return "An unexpected error occurred: \(error.localizedDescription)"
    }
}

// MARK: - NSScriptCommand Extension for Easy Error Setting

extension NSScriptCommand {

    /// Sets a file reading error with appropriate error code and message.
    func setFileReadError(_ error: Error) {
        self.scriptErrorNumber = -43  // fnfErr: file not found / general file error
        self.scriptErrorString = ErrorMessages.fileReadError(error)
    }

    /// Sets an SVG validation error with appropriate error code and message.
    func setSVGError(_ error: Error) {
        self.scriptErrorNumber = -128  // nerrArg: bad argument / invalid data
        self.scriptErrorString = ErrorMessages.svgError(error)
    }

    /// Sets an Inkscape conversion error with appropriate error code and message.
    func setInkscapeError(_ error: Error) {
        self.scriptErrorNumber = -108  // errAEOps: operation failed
        self.scriptErrorString = ErrorMessages.inkscapeError(error)
    }

    /// Sets a clipboard access error with appropriate error code and message.
    func setClipboardError(_ error: Error) {
        self.scriptErrorNumber = -108  // errAEOps: operation failed
        self.scriptErrorString = ErrorMessages.clipboardError(error)
    }

    /// Sets a general error with appropriate error code and message.
    func setGeneralError(_ error: Error) {
        self.scriptErrorNumber = -108  // errAEOps: operation failed
        self.scriptErrorString = ErrorMessages.generalError(error)
    }
}

// MARK: - SVG Validation Errors (for use with ErrorMessages.svgError)

enum SVGValidationError: Error, LocalizedError {
    case notValidXML
    case notSVGElement
    case containsDangerousContent
    case empty

    var errorDescription: String? {
        switch self {
        case .notValidXML:
            return "The file is not valid XML."
        case .notSVGElement:
            return "The file does not contain an SVG element."
        case .containsDangerousContent:
            return "The file contains potentially dangerous content and cannot be loaded."
        case .empty:
            return "The file is empty."
        }
    }
}

// MARK: - Size Limit Errors (for use with ErrorMessages.svgError)

enum SizeLimitError: Error, LocalizedError {
    case fileSizeExceeded(limit: Int, actual: Int)
    case nodeCountExceeded(limit: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .fileSizeExceeded(let limit, let actual):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let actualString = formatter.string(fromByteCount: Int64(actual))
            let limitMB = Double(limit) / 1_000_000
            return "File size (\(actualString)) exceeds the limit of \(limitMB) MB."
        case .nodeCountExceeded(let limit, let actual):
            return "SVG contains \(actual) nodes, exceeding the limit of \(limit)."
        }
    }
}
