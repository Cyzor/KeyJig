import Cocoa
import os

private let log = Logger(subsystem: "com.cyzor.KeyJig", category: "CompletionHook")

// MARK: - Completion hook

enum HookSource: String {
    case clipboard   = "clipboard"
    case keynotePull = "keynote-pull"
    case fileDrop    = "file-drop"
    case test        = "test"
}

/// Returns the display name (filename without extension) for the content in appState.
func svgDisplayName(for appState: AppState) -> String {
    if !appState.svgURL.isEmpty {
        return URL(fileURLWithPath: appState.svgURL).deletingPathExtension().lastPathComponent
    }
    if let bridgeURL = appState.bridgeFileURL {
        return bridgeURL.deletingPathExtension().lastPathComponent
    }
    return ""
}

/// Fires the user-configured completion AppleScript snippet, if one is set.
/// Substitutes {svgPath}, {svgName}, {source} into the script text, then
/// runs it via osascript on a background thread. Must be called on the main thread.
func fireCompletionHook(outputPath: String, svgName: String, source: HookSource) {
    let template = UserDefaults.standard.string(forKey: "completionHookScript") ?? ""
    guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    let script = template
        .replacingOccurrences(of: "{svgPath}", with: hookEscape(outputPath))
        .replacingOccurrences(of: "{svgName}", with: hookEscape(svgName))
        .replacingOccurrences(of: "{source}",  with: source.rawValue)

    DispatchQueue.global(qos: .utility).async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = FileHandle.nullDevice

        guard runProcess(task, timeout: 30) else {
            reportHookError("script timed out after 30 s")
            return
        }
        if task.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "exit \(task.terminationStatus)"
            reportHookError(msg)
        }
    }
}

private func reportHookError(_ message: String) {
    log.error("hook error: \(message, privacy: .public)")
    DispatchQueue.main.async {
        AppDelegate.shared?.frontWindowState?.statusMessage = "Hook error: \(message)"
    }
}

/// Escapes backslashes and double-quotes so the value is safe inside an
/// AppleScript double-quoted string literal. {svgPath} and {svgName} are
/// pre-escaped — place them directly between double quotes in your script.
private func hookEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}
