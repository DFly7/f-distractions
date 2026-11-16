import Foundation
import GatekeeperCore

@MainActor protocol GatekeeperConnection: AnyObject {
    var onLoginCompleted: ((Bool, String?) -> Void)? { get set }
    var onDiagnostic: ((String) -> Void)? { get set }
    var accountEmail: String? { get }
    func connect() async throws
    func account() async throws -> String?
    func models() async throws -> [CodexModel]
    func signIn() async throws -> URL
    func cancelSignIn() async
    func analyse(goal: String, images: [URL], model: String) async throws -> Verdict
    func refineTask(goal: String, details: String, model: String) async throws -> TaskBrief
    func interruptAnalysis() async -> Bool
    func stop(reason: String)
}

extension CodexClient: GatekeeperConnection {}
extension GatekeeperConnection {
    func interruptAnalysis() async -> Bool { false }
    func stop() { stop(reason: "Connection stopped.") }
    func refineTask(goal: String, details: String, model: String) async throws -> TaskBrief {
        throw GatekeeperError("Task setup is unavailable for this connection.")
    }
}
