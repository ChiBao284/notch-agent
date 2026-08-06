//
//  AppleScriptRunner.swift
//  ClaudeIsland
//
//  Runs AppleScript off the main thread
//

import Foundation
import os.log

enum AppleScriptError: Error {
    case compileFailed
    /// The script ran but AppleScript reported an error — most often -1743,
    /// meaning the user has not granted Automation permission for the target app.
    case executionFailed(code: Int, message: String)

    /// True when macOS refused the Apple Event for permission reasons.
    var isPermissionDenied: Bool {
        guard case .executionFailed(let code, _) = self else { return false }
        return code == -1743 || code == -600 || code == -10004
    }
}

/// Executes AppleScript on a dedicated serial queue.
///
/// Never run this on the main thread: the first Apple Event to a given app pops
/// the Automation permission dialog, and `executeAndReturnError` blocks until
/// the user answers it — which would freeze the notch.
enum AppleScriptRunner {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "AppleScript")
    private static let queue = DispatchQueue(label: "com.claudeisland.applescript")

    static func run(_ source: String) async -> Result<String, AppleScriptError> {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: .failure(.compileFailed))
                    return
                }

                var errorInfo: NSDictionary?
                let descriptor = script.executeAndReturnError(&errorInfo)

                if let errorInfo {
                    let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
                    logger.error("AppleScript failed (\(code)): \(message, privacy: .public)")
                    continuation.resume(returning: .failure(.executionFailed(code: code, message: message)))
                    return
                }

                continuation.resume(returning: .success(descriptor.stringValue ?? ""))
            }
        }
    }

    /// Escape a value for interpolation into an AppleScript string literal.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
