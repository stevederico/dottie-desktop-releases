//
//  MultiLogReader.swift
//  Dottie
//

import Foundation
import AppKit
import SwiftUI

/// A single parsed log line from one of the four log files, normalized into a
/// common shape so all sources can be merged into one chronological stream.
struct LogLine: Identifiable {
    let id = UUID()
    let source: LogSource
    /// Parsed level when the line carries a `[LEVEL]` tag (our own logs); nil for
    /// raw child-process output (talk / mac-use kernel logs).
    let level: LogLevel?
    /// Wall-clock timestamp parsed from a leading `[YYYY-MM-DD HH:MM:SS.mmm]`, when present.
    let timestamp: Date?
    /// The instant used to order this line in the merged stream. Either the parsed
    /// timestamp, or — for continuation lines (stack traces) and unstamped child
    /// output — the previous line's key so the line stays next to its context.
    let sortKey: Date
    /// The raw line text (unmodified, including its own timestamp/level tags).
    let text: String

    /// Parsed `[LEVEL]` value, or nil. Used for color-coding.
    enum LogLevel: String {
        case error = "ERROR"
        case warn = "WARN"
        case info = "INFO"
        case debug = "DEBUG"

        var color: Color {
            switch self {
            case .error: return .red
            case .warn: return .orange
            case .info: return .primary
            case .debug: return .secondary
            }
        }
    }
}

/// Identifies the four live log sources. `tag` is the short label shown inline;
/// `color` tints both the filter chip and the inline source tag so a merged
/// stream stays scannable.
enum LogSource: String, CaseIterable, Identifiable {
    case app = "App"
    case agent = "Agent"
    case talk = "Talk"
    case macuse = "MacUse"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .app: return .blue
        case .agent: return .purple
        case .talk: return .teal
        case .macuse: return .pink
        }
    }

    var logPath: URL {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dottie/logs")
        switch self {
        case .app: return AppLogger.shared.logPath
        case .agent: return logsDir.appendingPathComponent("gateway.log")
        case .talk: return logsDir.appendingPathComponent("talk.log")
        case .macuse: return logsDir.appendingPathComponent("macuse.log")
        }
    }
}

/// Reads ALL log files and merges them into one chronological, filterable stream.
///
/// Replaces the old per-file tabbed `LogReader`. Design notes:
/// - Tail-reads each file capped at `maxTailBytes` so a huge child log never
///   makes the poll expensive; a partial leading line from the cut is dropped.
/// - Only our own logs (app.log / gateway.log) carry a `[YYYY-MM-DD HH:MM:SS.mmm]`
///   timestamp. Child-process logs (talk / macuse) don't, so their lines inherit
///   the previous line's sort key (carry-forward), anchored to the file's mtime —
///   good enough to interleave them by recency without a fake global clock.
/// - Polls every 3s, same cadence as before.
class MultiLogReader: ObservableObject {
    /// All merged lines (unfiltered); the view applies source/level/search filters.
    @Published var lines: [LogLine] = []

    private var timer: Timer?
    /// Read at most this many trailing bytes per file per poll.
    private let maxTailBytes: UInt64 = 256 * 1024
    private static let sessionMarker = "SESSION START"

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    deinit { stop() }

    func start() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-read every source and rebuild the merged stream. Reading happens off the
    /// main thread; the published assignment hops back to main.
    func reload() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var all: [LogLine] = []
            for source in LogSource.allCases {
                all.append(contentsOf: self.readSource(source))
            }
            // Stable sort by the assigned sort key so same-instant lines keep
            // their within-source order (e.g. a stack trace stays in sequence).
            let merged = all.enumerated().sorted { lhs, rhs in
                if lhs.element.sortKey == rhs.element.sortKey { return lhs.offset < rhs.offset }
                return lhs.element.sortKey < rhs.element.sortKey
            }.map { $0.element }
            DispatchQueue.main.async { self.lines = merged }
        }
    }

    /// Tail-read one file, trim to the current session window, and parse each line.
    private func readSource(_ source: LogSource) -> [LogLine] {
        let path = source.logPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let fileSize = attrs[.size] as? UInt64 else {
            return []
        }
        let fileDate = (attrs[.modificationDate] as? Date) ?? Date()

        guard let handle = try? FileHandle(forReadingFrom: path) else { return [] }
        defer { try? handle.close() }

        let start = fileSize > maxTailBytes ? fileSize - maxTailBytes : 0
        handle.seek(toFileOffset: start)
        guard let data = try? handle.readToEnd(),
              var text = String(data: data, encoding: .utf8) else { return [] }

        // If we cut mid-line, drop the leading partial line.
        if start > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }

        // Trim to the last session window when a marker is present.
        if let markerRange = text.range(of: Self.sessionMarker, options: .backwards) {
            let lineStart = text[..<markerRange.lowerBound].lastIndex(of: "\n")
                .map { text.index(after: $0) } ?? text.startIndex
            text = String(text[lineStart...])
        }

        var result: [LogLine] = []
        var carryKey = fileDate
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.contains(Self.sessionMarker) { continue } // hide the marker line itself

            let (ts, level) = parse(line)
            let key = ts ?? carryKey
            carryKey = key
            result.append(LogLine(source: source, level: level, timestamp: ts, sortKey: key, text: line))
        }
        return result
    }

    /// Pull a leading `[YYYY-MM-DD HH:MM:SS.mmm]` timestamp and a `[LEVEL]` tag out
    /// of a line, if present. Both are optional — child-process lines have neither.
    private func parse(_ line: String) -> (Date?, LogLine.LogLevel?) {
        // Timestamp: must be the very first bracketed token.
        var date: Date?
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            let inner = String(line[line.index(after: line.startIndex)..<close])
            date = dateFormatter.date(from: inner)
        }
        // Level: first of the known tags appearing in the line's leading segment.
        var level: LogLine.LogLevel?
        let head = line.prefix(80)
        for candidate in [LogLine.LogLevel.error, .warn, .info, .debug] where head.contains("[\(candidate.rawValue)]") {
            level = candidate
            break
        }
        return (date, level)
    }

    /// Truncate every log file to empty.
    func clearAll() {
        for source in LogSource.allCases {
            try? "".write(to: source.logPath, atomically: true, encoding: .utf8)
        }
        lines = []
    }

    /// Copy the given (already-filtered) lines to the pasteboard as plain text.
    func copy(_ visible: [LogLine]) {
        let text = visible.map { "[\($0.source.rawValue)] \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
