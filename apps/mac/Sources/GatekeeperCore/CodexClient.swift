import Foundation

public struct GatekeeperError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    /// Fixed categories only; upstream messages may contain private account/request data.
    public var diagnosticSummary: String {
        let text = message.lowercased()
        if text.contains("workspace routing discovery timed out") { return "workspace_routing_timeout" }
        if text.contains("didn’t respond") || text.contains("timed out") { return "request_timeout" }
        if text.contains("connection closed") { return "connection_closed" }
        if text.contains("api key") { return "subscription_sign_in_required" }
        if text.contains("cli wasn’t found") { return "codex_executable_missing" }
        if text.contains("screen access") || text.contains("recording permission") { return "screen_permission_unavailable" }
        return "request_failed_see_app_error"
    }
}

public enum ScreenEvidenceSource: String, Codable, CaseIterable {
    case activeContent = "active_content"
    case inactiveNavigation = "inactive_navigation"
    case monitoringUI = "monitoring_ui"
    case unreadable = "unreadable"
}

public struct ScreenVerdict: Codable, Equatable {
    public let screenIndex: Int
    public let evidenceSource: ScreenEvidenceSource
    public let status: String
    public let reason: String
    public init(screenIndex: Int, status: String, reason: String, evidenceSource: ScreenEvidenceSource = .activeContent) {
        self.evidenceSource = evidenceSource
        self.screenIndex = screenIndex; self.status = status; self.reason = reason
    }
}

public struct Verdict: Codable {
    public let status: String
    public let reason: String
    public let nextStep: String
    public let screens: [ScreenVerdict]
    public init(status: String, reason: String, nextStep: String, screens: [ScreenVerdict] = []) {
        self.status = status; self.reason = reason; self.nextStep = nextStep; self.screens = screens
    }
    private enum CodingKeys: String, CodingKey { case status, reason, nextStep, screens }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decode(String.self, forKey: .status)
        reason = try values.decode(String.self, forKey: .reason)
        nextStep = try values.decode(String.self, forKey: .nextStep)
        screens = try values.decodeIfPresent([ScreenVerdict].self, forKey: .screens) ?? []
    }
    public func validated(screenCount: Int) throws -> Verdict {
        guard screenCount > 0, screens.count == screenCount,
              Set(screens.map(\.screenIndex)) == Set(1...screenCount),
              screens.allSatisfy({ ["on_task", "off_task", "unsure", "neutral"].contains($0.status) }) else {
            throw GatekeeperError("The model didn’t assess every screen correctly. Try another check.")
        }
        guard screens.allSatisfy({ $0.status != "off_task" || $0.evidenceSource == .activeContent }) else {
            throw GatekeeperError("The model cited inactive navigation, monitoring UI or unreadable content as a distraction. No new blur was applied; checking again later.")
        }
        let expected = screens.contains { $0.status == "off_task" } ? "off_task" :
            screens.contains { $0.status == "unsure" } ? "unsure" :
            screens.contains { $0.status == "on_task" } ? "on_task" : "unsure"
        guard status == expected else { throw GatekeeperError("The model’s screen judgments were inconsistent. Try another check.") }
        return self
    }
    public static func decode(_ text: String) throws -> Verdict {
        let result = try JSONDecoder().decode(Verdict.self, from: Data(text.utf8))
        guard ["on_task", "off_task", "unsure"].contains(result.status) else {
            throw GatekeeperError("The model returned an unrecognised verdict. Try another check.")
        }
        return result
    }
}

public struct TaskBrief: Codable {
    public let goal: String
    public let allowed: [String]
    public let offTask: [String]
    public let question: String
    public init(goal: String, allowed: [String], offTask: [String], question: String) {
        self.goal = goal; self.allowed = allowed; self.offTask = offTask; self.question = question
    }
    public var context: String {
        "Outcome: \(goal)\nAllowed work:\n" + allowed.map { "• " + $0 }.joined(separator: "\n") +
        "\nOff task:\n" + offTask.map { "• " + $0 }.joined(separator: "\n")
    }
}

public struct CodexModel: Identifiable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    public init(id: String, name: String, isDefault: Bool) {
        self.id = id; self.name = name; self.isDefault = isDefault
    }
}

/// Owns only its own child process. Never reads or copies account tokens.
@MainActor public final class CodexClient {
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var turnWaiter: CheckedContinuation<String, Error>?
    private var turnDeadline: Task<Void, Never>?
    private var currentThread: String?
    private var responseText = ""
    private var ready = false
    private var activeLoginID: String?
    private var loginGeneration = 0
    private var lowEffortModels: Set<String> = []
    public var onLoginCompleted: ((Bool, String?) -> Void)?
    public var onDiagnostic: ((String) -> Void)?
    public private(set) var executablePath = ""
    public private(set) var accountEmail: String?

    public init() {}

    public func connect() async throws {
        if ready { return }
        stop()
        let fm = FileManager.default
        let candidates = [
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        guard let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw GatekeeperError("Codex CLI wasn’t found. Install it with npm install -g @openai/codex, then reconnect.")
        }
        executablePath = path
        let child = Process()
        // Finder/LaunchServices can start us in /. Avoid workspace discovery there.
        let workingDirectory = fm.temporaryDirectory.appendingPathComponent("gatekeeper-codex", isDirectory: true)
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        child.currentDirectoryURL = workingDirectory
        onDiagnostic?("Starting Codex in dedicated Gatekeeper working directory")
        // npm installations use an env-node launcher, so Finder launches need a complete PATH.
        child.executableURL = URL(fileURLWithPath: path)
        child.arguments = ["app-server", "--listen", "stdio://",
                           "--disable", "shell_tool", "--disable", "unified_exec",
                           "--disable", "multi_agent", "--disable", "apps",
                           "--disable", "plugins", "--disable", "hooks",
                           "--disable", "browser_use", "--disable", "computer_use",
                           "--disable", "image_generation", "--disable", "skill_search",
                           "-c", "web_search=\"disabled\"", "-c", "mcp_servers={}"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ([URL(fileURLWithPath: path).deletingLastPathComponent().path,
                                 "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] +
                                (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        child.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard self?.process === child else { return }
                self?.failAll(GatekeeperError("The Codex connection closed. Click Reconnect to try again."))
                self?.ready = false
            }
        }
        process = child; input = stdin.fileHandleForWriting
        do {
            try child.run()
            _ = try await request("initialize", ["clientInfo": ["name": "gatekeeper_poc", "title": "Gatekeeper", "version": "0.1.0"]])
            onDiagnostic?("Codex initialize completed")
            try send(["method": "initialized"])
            ready = true
        } catch { stop(); throw error }
    }

    public func account() async throws -> String? {
        accountEmail = nil
        let result = try await request("account/read", ["refreshToken": false])
        onDiagnostic?("Codex account/read completed")
        guard let account = result["account"] as? [String: Any] else { return nil }
        guard account["type"] as? String == "chatgpt" else {
            throw GatekeeperError("Codex is using an API key. Sign in with ChatGPT to use your subscription for this POC.")
        }
        let plan = (account["planType"] as? String ?? "ChatGPT").capitalized
        accountEmail = account["email"] as? String
        return "ChatGPT \(plan)"
    }

    public func signIn() async throws -> URL {
        loginGeneration += 1
        let generation = loginGeneration
        let result = try await request("account/login/start", ["type": "chatgpt"])
        guard let id = result["loginId"] as? String else { throw GatekeeperError("Codex didn’t return a sign-in attempt ID.") }
        guard generation == loginGeneration else {
            _ = try? await request("account/login/cancel", ["loginId": id])
            throw CancellationError()
        }
        activeLoginID = id
        guard let value = result["authUrl"] as? String, let url = URL(string: value), url.scheme == "https" else {
            throw GatekeeperError("Codex didn’t return a valid sign-in URL.")
        }
        return url
    }

    public func cancelSignIn() async {
        loginGeneration += 1
        guard let id = activeLoginID else { return }
        activeLoginID = nil // Ignore cancellation and late completion notifications.
        _ = try? await request("account/login/cancel", ["loginId": id])
        onDiagnostic?("Pending ChatGPT sign-in cancelled")
    }

    public func models() async throws -> [CodexModel] {
        var result: [CodexModel] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let page = try await request("model/list", params)
            onDiagnostic?("Codex model/list page completed")
            for item in page["data"] as? [[String: Any]] ?? [] {
                let modalities = item["inputModalities"] as? [String]
                if let modalities, !modalities.contains("image") { continue }
                guard let id = item["model"] as? String else { continue }
                if (item["supportedReasoningEfforts"] as? [[String: Any]])?.contains(where: { $0["reasoningEffort"] as? String == "low" }) == true {
                    lowEffortModels.insert(id)
                }
                result.append(CodexModel(id: id, name: item["displayName"] as? String ?? id,
                                         isDefault: item["isDefault"] as? Bool ?? false))
            }
            cursor = page["nextCursor"] as? String
        } while cursor != nil
        guard !result.isEmpty else { throw GatekeeperError("No image-capable models were returned by Codex.") }
        return result
    }

    public func analyse(goal: String, image: URL, model: String) async throws -> Verdict {
        try await analyse(goal: goal, images: [image], model: model)
    }

    public func analyse(goal: String, images: [URL], model: String) async throws -> Verdict {
        guard !images.isEmpty else { throw GatekeeperError("No screen images were supplied for this check.") }
        let instructions = FocusClassifierPrompt.instructions
        let screenSchema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["screenIndex": ["type": "integer", "minimum": 1, "maximum": images.count],
                           "evidenceSource": ["type": "string", "enum": ScreenEvidenceSource.allCases.map(\.rawValue)],
                           "status": ["type": "string", "enum": ["on_task", "off_task", "unsure", "neutral"]],
                           "reason": ["type": "string"]],
            "required": ["screenIndex", "evidenceSource", "status", "reason"]
        ]
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["status": ["type": "string", "enum": ["on_task", "off_task", "unsure"]],
                           "reason": ["type": "string"], "nextStep": ["type": "string"],
                           "screens": ["type": "array", "items": screenSchema, "minItems": images.count, "maxItems": images.count]],
            "required": ["status", "reason", "nextStep", "screens"]
        ]
        var input: [[String: Any]] = [["type": "text", "text": "User goal and task boundaries:\n\(goal)\n\nThere are \(images.count) screen images, ordered Screen 1 through Screen \(images.count). Assess every screen together."]]
        input.append(contentsOf: images.map { ["type": "localImage", "path": $0.path] })
        let output = try await structuredRequest(instructions: instructions, input: input, schema: schema, model: model)
        return try Verdict.decode(output).validated(screenCount: images.count)
    }

    public func refineTask(goal: String, details: String, model: String) async throws -> TaskBrief {
        let schema: [String: Any] = ["type": "object", "additionalProperties": false,
            "properties": ["goal": ["type": "string"], "allowed": ["type": "array", "items": ["type": "string"]],
                           "offTask": ["type": "array", "items": ["type": "string"]], "question": ["type": "string"]],
            "required": ["goal", "allowed", "offTask", "question"]]
        let instructions = """
        Help define one concrete focus session. Use only the goal and details provided.
        Return a concise task brief with the outcome, up to five allowed activities and
        up to five clear off-task examples. Do not invent coursework requirements or assume
        unrelated projects fit because a course label appears. If important context is missing,
        ask ONE specific clarifying question in question; otherwise use an empty question.
        Preserve the user's scope. Do not execute tools, read files or browse. All returned
        details remain editable by the user. Keep this fast and concise.
        """
        let input: [[String: Any]] = [["type": "text", "text": "Goal: \(goal)\nProvided details and answers:\n\(details)"]]
        let output = try await structuredRequest(instructions: instructions, input: input, schema: schema, model: model)
        return try JSONDecoder().decode(TaskBrief.self, from: Data(output.utf8))
    }

    private func structuredRequest(instructions: String, input: [[String: Any]], schema: [String: Any], model: String) async throws -> String {
        guard turnWaiter == nil else { throw GatekeeperError("An AI request is already running.") }
        guard try await account() != nil else { throw GatekeeperError("Sign in with ChatGPT before checking your screen.") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gatekeeper-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let thread = try await request("thread/start", [
            "model": model, "cwd": scratch.path, "ephemeral": true,
            "approvalPolicy": "untrusted", "sandbox": "read-only",
            "baseInstructions": instructions, "developerInstructions": "Return only the requested JSON. Never use tools.",
            "config": ["mcp_servers": [:], "project_doc_max_bytes": 0]
        ])
        guard let value = thread["thread"] as? [String: Any], let threadID = value["id"] as? String else {
            throw GatekeeperError("Codex didn’t create an analysis session.")
        }
        currentThread = threadID; responseText = ""
        defer {
            currentThread = nil; turnDeadline?.cancel(); turnDeadline = nil
        }
        let output: String = try await withCheckedThrowingContinuation { continuation in
            turnWaiter = continuation
            turnDeadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { return }
                self?.stop(reason: "The AI request timed out. Reconnect and try again.")
            }
            Task {
                do {
                    var params: [String: Any] = [
                        "threadId": threadID,
                        "input": input,
                        "outputSchema": schema
                    ]
                    if lowEffortModels.contains(model) { params["effort"] = "low" }
                    onDiagnostic?("AI request starting: reasoning=\(lowEffortModels.contains(model) ? "low" : "model default")")
                    _ = try await request("turn/start", params)
                } catch { finishTurn(.failure(error)) }
            }
        }
        return output
    }

    public func stop(reason: String = "Connection stopped.") {
        activeLoginID = nil; loginGeneration += 1
        ready = false
        let child = process
        process = nil
        if let pipe = child?.standardOutput as? Pipe { pipe.fileHandleForReading.readabilityHandler = nil }
        if let pipe = child?.standardError as? Pipe { pipe.fileHandleForReading.readabilityHandler = nil }
        try? input?.close(); input = nil
        if child?.isRunning == true { child?.terminate() }
        buffer.removeAll()
        failAll(GatekeeperError(reason))
    }

    private func send(_ object: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw GatekeeperError("Codex isn’t connected. Click Reconnect.") }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        nextID += 1; let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.deadlines.removeValue(forKey: id)
                self.pending.removeValue(forKey: id)?.resume(throwing: GatekeeperError("Codex didn’t respond to \(method). Reconnect and try again."))
            }
            do { try send(["id": id, "method": method, "params": params]) }
            catch {
                deadlines.removeValue(forKey: id)?.cancel()
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let method = message["method"] as? String {
                if let id = message["id"] {
                    // No model-initiated commands, file access approvals or interactive tools.
                    try? send(["id": id, "error": ["code": -32601, "message": "Gatekeeper supports classification only; tools are unavailable."]])
                    continue
                }
                handle(method, message["params"] as? [String: Any] ?? [:])
            } else if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                deadlines.removeValue(forKey: id)?.cancel()
                if let error = message["error"] as? [String: Any] {
                    continuation.resume(throwing: GatekeeperError(error["message"] as? String ?? "Codex request failed."))
                } else { continuation.resume(returning: message["result"] as? [String: Any] ?? [:]) }
            }
        }
    }

    private func handle(_ method: String, _ params: [String: Any]) {
        if method == "account/login/completed" {
            guard let id = params["loginId"] as? String, id == activeLoginID else { return }
            activeLoginID = nil
            onLoginCompleted?(params["success"] as? Bool ?? false, params["error"] as? String)
            return
        }
        guard let currentThread, params["threadId"] as? String == currentThread else { return }
        if method == "item/agentMessage/delta", let delta = params["delta"] as? String { responseText += delta }
        if method == "item/completed", let item = params["item"] as? [String: Any],
           item["type"] as? String == "agentMessage", let text = item["text"] as? String {
            responseText = text
        }
        if method == "turn/completed", let turn = params["turn"] as? [String: Any] {
            guard turn["status"] as? String == "completed" else {
                let error = turn["error"] as? [String: Any]
                finishTurn(.failure(GatekeeperError(error?["message"] as? String ?? "The analysis was interrupted. Try again.")))
                return
            }
            finishTurn(.success(responseText))
        }
    }

    private func finishTurn(_ result: Result<String, Error>) {
        let waiter = turnWaiter; turnWaiter = nil
        waiter?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let requests = pending; pending.removeAll()
        deadlines.values.forEach { $0.cancel() }; deadlines.removeAll()
        requests.values.forEach { $0.resume(throwing: error) }
        finishTurn(.failure(error))
    }
}
