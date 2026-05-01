import Foundation
import os

/// Lightweight logger: writes to os.log (visible in Console.app) and to a
/// rolling file in ~/Library/Logs/ClaudeTracker/ (or the sandboxed container
/// equivalent). Max file size 512 KB; one rotation kept as claudetracker.1.log.
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private let osLog = Logger(subsystem: "com.claudetracker.app", category: "app")
    private let queue = DispatchQueue(label: "com.claudetracker.app.logger", qos: .utility)
    private let maxFileBytes = 512 * 1024

    let logFileURL: URL?

    private init() {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        if let dir = lib?.appendingPathComponent("Logs/ClaudeTracker") {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            logFileURL = dir.appendingPathComponent("claudetracker.log")
        } else {
            logFileURL = nil
        }
    }

    func info(_ msg: String)  { write(msg, level: "INFO");  osLog.info("\(msg, privacy: .public)") }
    func error(_ msg: String) { write(msg, level: "ERROR"); osLog.error("\(msg, privacy: .public)") }

    /// Returns the last `maxBytes` of the log file as a string.
    func tail(maxBytes: Int = 32_768) -> String {
        guard let url = logFileURL,
              let data = try? Data(contentsOf: url) else { return "(no log file)" }
        return String(data: data.suffix(maxBytes), encoding: .utf8) ?? "(unreadable)"
    }

    private func write(_ msg: String, level: String) {
        let line = "[\(timestamp())] [\(level)] \(msg)\n"
        queue.async { [weak self] in self?.append(line) }
    }

    private func append(_ line: String) {
        guard let url = logFileURL, let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > maxFileBytes {
            let rotated = url.deletingLastPathComponent().appendingPathComponent("claudetracker.1.log")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        if fm.fileExists(atPath: url.path) {
            guard let fh = try? FileHandle(forWritingTo: url) else { return }
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
