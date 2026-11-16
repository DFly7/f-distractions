import Foundation
import GatekeeperCore

enum SessionState: String, Codable {
    case running, paused, completed, ended, interrupted
}

struct SessionEvent: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var kind: String
    var trigger: String?
    var app: String?
    var reason: String
    var nextStep: String?
}

struct FocusSession: Identifiable, Codable {
    var id = UUID()
    var goal: String
    var taskContext: String? = nil
    var startedAt: Date
    var durationSeconds: Int
    var remainingSeconds: Int
    var state: SessionState = .running
    var endedAt: Date?
    var aiChecks = 0
    var skippedSamples = 0
    var events: [SessionEvent] = []
}

@MainActor final class SessionStore {
    let file: URL
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gatekeeper/sessions.json")
    }

    func load() throws -> [FocusSession] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([FocusSession].self, from: Data(contentsOf: file))
    }

    func save(_ sessions: [FocusSession]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Array(sessions.prefix(20))).write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
