import Foundation
import OSLog
import GatekeeperCore

/// Events only: never screenshot contents, goals, tokens, email addresses or model replies.
@MainActor enum Diagnostics {
    static var enabled = true
    private static let logger = Logger(subsystem: "dev.gatekeeper.poc", category: "lifecycle")
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Gatekeeper/gatekeeper.log")

    static func record(_ event: String) {
        guard enabled else { return }
        logger.info("\(event, privacy: .public)")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(event)\n".utf8))
        } catch { logger.error("Could not write local diagnostics log.") }
    }

    static func failure(_ stage: String, _ error: Error) {
        let value = error as NSError
        let category = (error as? GatekeeperError)?.diagnosticSummary ?? "system_error"
        record("\(stage) failed: category=\(category) domain=\(value.domain) code=\(value.code)")
    }
}
