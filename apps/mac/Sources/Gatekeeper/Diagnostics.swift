import Foundation
import OSLog
import GatekeeperCore

/// Events only: never screenshot contents, goals, tokens, email addresses or model replies.
@MainActor enum Diagnostics {
    static var enabled = true
    static var onRecord: ((String) -> Void)?
    private static let logger = Logger(subsystem: "dev.gatekeeper.poc", category: "lifecycle")
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Gatekeeper/gatekeeper.log")

    private static let runID = String(UUID().uuidString.prefix(8))
    private static let writer = DispatchQueue(label: "dev.gatekeeper.poc.diagnostics", qos: .utility)
    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    struct Trace {
        let id = String(UUID().uuidString.prefix(8))
        let started = ProcessInfo.processInfo.systemUptime
        var elapsedMS: Int { max(0, Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) }
    }

    /// Callers supply fixed operational categories/counts only, never evidence or user text.
    static func event(_ name: String, trace: Trace? = nil, details: String = "") {
        let correlation = trace.map { " trace=\($0.id) elapsed_ms=\($0.elapsedMS)" } ?? ""
        record("event=\(name)\(correlation)\(details.isEmpty ? "" : " " + details)")
    }

    static func record(_ event: String) {
        onRecord?(event)
        guard enabled else { return }
        logger.info("\(event, privacy: .public)")
        let data = Data("\(timestamp.string(from: Date())) run=\(runID) \(event)\n".utf8)
        let destination = file
        let logger = self.logger
        writer.async {
            do { try DiagnosticLogFile.append(data, to: destination) }
            catch { logger.error("Could not write local diagnostics log.") }
        }
    }

    static func flush() { writer.sync {} }

    static func failure(_ stage: String, _ error: Error, trace: Trace? = nil) {
        let value = error as NSError
        let category = (error as? GatekeeperError)?.diagnosticSummary ?? "system_error"
        event("failure", trace: trace, details: "stage=\(stage) category=\(category) domain=\(value.domain) code=\(value.code)")
    }
}

/// Serial writer owns rotation. Keep the active file and two bounded archives.
enum DiagnosticLogFile {
    static func append(_ data: Data, to file: URL, maximumBytes: Int = 2_000_000) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 0 && size + data.count > maximumBytes {
            let oldest = file.appendingPathExtension("2"), previous = file.appendingPathExtension("1")
            if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
            if manager.fileExists(atPath: previous.path) { try manager.moveItem(at: previous, to: oldest) }
            try manager.moveItem(at: file, to: previous)
        }
        if !manager.fileExists(atPath: file.path) {
            manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
