import Foundation
import os

/// Low-frequency operational logging for lifecycle and device diagnostics.
///
/// Every record is sent to macOS Unified Logging and appended to a plain-text
/// file under `~/Library/Logs/LogiMouse`. The file is intentionally independent
/// of the settings window so sleep/wake failures can be inspected afterwards.
enum RuntimeLog {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case notice = "NOTICE"
        case warning = "WARNING"
        case error = "ERROR"

        var osLogType: OSLogType {
            switch self {
            case .debug: .debug
            case .info: .info
            case .notice: .default
            case .warning: .default
            case .error: .error
            }
        }
    }

    static let subsystem = "dev.logi-mouse"
    static let fileURL: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("LogiMouse", isDirectory: true)
            .appendingPathComponent("logi-mouse.log", isDirectory: false)
    }()

    private static let maximumFileSize: UInt64 = 5 * 1_024 * 1_024
    private static let queue = DispatchQueue(label: "dev.logi-mouse.runtime-log")

    /// Formats file timestamps in the user's current system time zone and
    /// includes the numeric UTC offset so copied logs remain unambiguous.
    static func timestamp(
        for date: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    static func debug(_ category: String, _ message: @autoclosure () -> String) {
        write(.debug, category: category, message: message())
    }

    static func info(_ category: String, _ message: @autoclosure () -> String) {
        write(.info, category: category, message: message())
    }

    static func notice(_ category: String, _ message: @autoclosure () -> String) {
        write(.notice, category: category, message: message())
    }

    static func warning(_ category: String, _ message: @autoclosure () -> String) {
        write(.warning, category: category, message: message())
    }

    static func error(_ category: String, _ message: @autoclosure () -> String) {
        write(.error, category: category, message: message())
    }

    private static func write(_ level: Level, category: String, message: String) {
        let logger = Logger(subsystem: subsystem, category: category)
        logger.log(level: level.osLogType, "\(message, privacy: .public)")

        // These records are deliberately synchronous and low frequency. This
        // ensures the final pre-sleep record reaches disk before macOS suspends
        // the process, while keeping high-rate HID reports off this path.
        queue.sync {
            do {
                try rotateIfNeeded()
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                let line = "\(timestamp(for: Date())) [\(level.rawValue)] [\(category)] \(message)\n"
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                    try handle.synchronize()
                }
            } catch {
                logger.error("Failed to append runtime log file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func rotateIfNeeded() throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= maximumFileSize else { return }
        let previousURL = fileURL.deletingPathExtension().appendingPathExtension("previous.log")
        if FileManager.default.fileExists(atPath: previousURL.path) {
            try FileManager.default.removeItem(at: previousURL)
        }
        try FileManager.default.moveItem(at: fileURL, to: previousURL)
    }
}
