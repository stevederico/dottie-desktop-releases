//
//  AppLogger.swift
//  Dottie
//
//  Created by Claude on 1/25/26.
//

import Foundation

/// Centralized file-based logger that writes timestamped, leveled log entries to `~/.dottie/logs/app.log`.
/// Supports debug, info, warn, and error levels. Automatically rotates the log file at 5 MB.
/// All writes are serialized on a dedicated background queue.
class AppLogger {
    static let shared = AppLogger()

    private let logQueue = DispatchQueue(label: "com.dottie.applogger", qos: .utility)
    private let logFileURL: URL
    private let dateFormatter: DateFormatter
    private let maxLogSize: Int64 = 5 * 1024 * 1024 // 5MB max

    private init() {
        // Set up log file path
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dottie/logs")

        // Create logs directory if needed
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        logFileURL = logsDir.appendingPathComponent("app.log")

        // Configure date formatter
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        // Log startup with session marker
        log("━━━ SESSION START [\(Date())] ━━━", level: .info)
    }

    /// Severity levels for log entries, stored as their uppercase string representation.
    enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    /// Writes a log entry with the given level, including timestamp, source file, function, and line number.
    /// Also prints to stdout for Xcode console visibility. Triggers log rotation if file exceeds 5 MB.
    /// - Parameters:
    ///   - message: The log message to record.
    ///   - level: The severity level (defaults to `.info`).
    ///   - file: The source file path (auto-captured via `#file`).
    ///   - function: The calling function name (auto-captured via `#function`).
    ///   - line: The source line number (auto-captured via `#line`).
    func log(_ message: String, level: LogLevel = .info, file: String = #file, function: String = #function, line: Int = #line) {
        logQueue.async { [weak self] in
            guard let self = self else { return }

            let timestamp = self.dateFormatter.string(from: Date())
            let logLine = AppLogger.format(timestamp: timestamp, level: level, file: file, function: function, line: line, message: message)

            // Also print to console for Xcode debugging
            print(logLine, terminator: "")

            // Rotate log if too large
            self.rotateLogIfNeeded()

            // Write to file. Cannot use AppLogger.error for failures here
            // (would recurse), so failures go to stderr.
            if let data = logLine.data(using: .utf8) {
                do {
                    if FileManager.default.fileExists(atPath: self.logFileURL.path) {
                        let fileHandle = try FileHandle(forWritingTo: self.logFileURL)
                        defer { try? fileHandle.close() }
                        try fileHandle.seekToEnd()
                        try fileHandle.write(contentsOf: data)
                    } else {
                        try data.write(to: self.logFileURL)
                    }
                } catch {
                    fputs("AppLogger write failed: \(error)\n", stderr)
                }
            }
        }
    }

    /// Pure formatter for a single log line — the single source of truth for the
    /// on-disk line shape. Extracted so it can be unit-tested without touching the
    /// real log file. Returns a trailing-newline-terminated entry.
    static func format(timestamp: String, level: LogLevel, file: String, function: String, line: Int, message: String) -> String {
        let filename = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        return "[\(timestamp)] [\(level.rawValue)] [\(filename):\(line)] \(function): \(message)\n"
    }

    /// Rotates the log file if it exceeds `maxLogSize` by moving it to `app.old.log` and starting fresh.
    private func rotateLogIfNeeded() {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: logFileURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0

            if fileSize > maxLogSize {
                // Rename current log to .old and start fresh
                let oldLogURL = logFileURL.deletingPathExtension().appendingPathExtension("old.log")
                try? FileManager.default.removeItem(at: oldLogURL)
                try FileManager.default.moveItem(at: logFileURL, to: oldLogURL)
            }
        } catch {
            // Ignore rotation errors
        }
    }

    /// Logs a message at the `DEBUG` level.
    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .debug, file: file, function: function, line: line)
    }

    /// Logs a message at the `INFO` level.
    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .info, file: file, function: function, line: line)
    }

    /// Logs a message at the `WARN` level.
    func warn(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .warn, file: file, function: function, line: line)
    }

    /// Logs a message at the `ERROR` level (local file only).
    func error(_ message: String, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .error, file: file, function: function, line: line)
    }

    /// The file URL of the current log file at `~/.dottie/logs/app.log`.
    var logPath: URL {
        logFileURL
    }

    // MARK: - Static Convenience Methods

    /// Logs a message at the `DEBUG` level via the shared instance.
    static func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        shared.debug(message, file: file, function: function, line: line)
    }

    /// Logs a message at the `INFO` level via the shared instance.
    static func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        shared.info(message, file: file, function: function, line: line)
    }

    /// Logs a message at the `WARN` level via the shared instance.
    static func warn(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        shared.warn(message, file: file, function: function, line: line)
    }

    /// Logs a message at the `ERROR` level via the shared instance.
    static func error(_ message: String, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        shared.error(message, error: error, file: file, function: function, line: line)
    }
}
