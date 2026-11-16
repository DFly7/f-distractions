import SwiftUI
import GatekeeperCore

@MainActor final class AppModel: ObservableObject {
    @Published var goal = UserDefaults.standard.string(forKey: "goal") ?? ""
    @Published var taskContext = UserDefaults.standard.string(forKey: "taskContext") ?? ""
    @Published var taskQuestion: String?
    @Published var taskAnswer = ""
    @Published private(set) var refiningTask = false
    private var taskSetupID: UUID?
    @Published var connection = "Connecting to Codex…"
    @Published var account: String?
    @Published var accountEmail: String?
    @Published var models: [CodexModel] = []
    @Published var selectedModel = ""
    @Published var displayCount = NSScreen.screens.count
    @Published var connecting = false
    @Published var checking = false
    @Published var signingIn = false
    @Published var countdown: Int?
    @Published var screenshots: [CapturedScreen] = []
    @Published var verdict: Verdict?
    @Published var error: String?
    @Published var lastCheck: Date?
    @Published var stage = ""
    @Published var screenAccess = CGPreflightScreenCaptureAccess()
    @Published var permissionRequested = false
    @Published var sessionMinutes = max(1, min(240, UserDefaults.standard.object(forKey: "sessionMinutes") as? Int ?? 45))
    @Published var aiIntervalSeconds = UserDefaults.standard.object(forKey: "aiIntervalSeconds") as? Int ?? 30
    @Published private(set) var session: FocusSession?
    @Published private(set) var history: [FocusSession] = []
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var policy = MonitoringPolicy(minimumGap: 30)
    @Published var historyError: String?
    @Published var reviewedSessionID: UUID?
    @Published private(set) var interventions: [InterventionCandidate] = []
    @Published private(set) var correctionNote: String?
    @Published private(set) var interventionNote: String?
    var onInterventionsChanged: (([InterventionCandidate]) -> Void)?
    var onSessionExitRequested: ((SessionExitAction, @escaping (Bool) -> Void) -> Void)?
    private var exitRequestID: UUID?

    func requestSessionExit(_ action: SessionExitAction, completion: (() -> Void)? = nil) {
        guard hasActiveSession else {
            if action == .newTask { newTask() }
            completion?()
            return
        }
        guard exitRequestID == nil else { return }
        let requestID = UUID(), sessionID = session?.id
        exitRequestID = requestID
        onSessionExitRequested?(action, { [weak self] confirmed in
            guard let self, self.exitRequestID == requestID else { return }
            self.exitRequestID = nil
            guard confirmed, self.hasActiveSession, self.session?.id == sessionID else { return }
            switch action {
            case .pause: self.pauseSession()
            case .end: self.endSession()
            case .newTask: self.newTask()
            case .quit: break
            }
            completion?()
        })
    }

    var previewBlur: () -> Void = {}
    var freshnessDelay: () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) }
    private var interventionRules = InterventionRules()
    private var contextRevision = 0
    private(set) var lastOnTaskApplication: NSRunningApplication?
    private let sessionStore: SessionStore
    private var sessionTask: Task<Void, Never>?
    private var sessionDeadline: Date?
    private var lastSampleAt: Date?
    @Published private(set) var analysisInFlight = false
    private var reconnectAfterCheck = false
    private var shuttingDown = false
    private var temporaryImages: [URL] = []
    private var connectionRetryAt: Date?
    private var observedWindows: [UInt32: ScreenWindowContext]?
    private var returnDeadlines: [UInt32: Date] = [:]
    private var pendingReturns: Set<UInt32> = []
    var pollWindowContexts: () -> [UInt32: ScreenWindowContext] = { ScreenCapture.currentWindowContexts() }
    private var lifecycleObservers: [NSObjectProtocol] = []
    var currentTime: () -> Date = Date.init
    var captureScreens: () async throws -> [CapturedScreen] = { try await ScreenCapture.captureAll() }
    var permissionAvailable: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var countdownDelay: () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) }
    var hideForWork: () -> Void = { NSApp?.hide(nil) }
    var foregroundAppName: () -> String? = { NSWorkspace.shared.frontmostApplication?.localizedName }
    var runsSessionLoop = true
    var cacheCheckDelay: () async throws -> Void = { try await Task.sleep(nanoseconds: 300_000_000) }
    private(set) var cachedCheckTask: Task<Void, Never>?
    let client: any GatekeeperConnection
    private var signInDeadline: Task<Void, Never>?
    private var loginAttempt: UUID?
    var openSignInURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    private(set) var checkTask: Task<Void, Never>?
    private var previousApplication: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var displayObserver: NSObjectProtocol?
    var showWindow: (() -> Void)?

    var canCheck: Bool {
        !checking && !connecting && !signingIn && !refiningTask && account != nil && !selectedModel.isEmpty &&
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session?.state != .paused
    }

    var hasActiveSession: Bool { session?.state == .running || session?.state == .paused }
    var canStartSession: Bool {
        canCheck && !hasActiveSession && (1...240).contains(sessionMinutes) && [15, 30, 60].contains(aiIntervalSeconds)
    }
    var timelineSession: FocusSession? {
        if let reviewedSessionID { return history.first { $0.id == reviewedSessionID } ?? session }
        return session ?? history.first
    }

    init(client: (any GatekeeperConnection)? = nil, sessionStore: SessionStore? = nil) {
        self.client = client ?? CodexClient()
        self.sessionStore = sessionStore ?? SessionStore()
        do {
            history = try self.sessionStore.load().map { item in
                var item = item
                if item.state == .running || item.state == .paused {
                    item.state = .interrupted; item.endedAt = Date()
                    item.events.append(SessionEvent(date: Date(), kind: "interrupted", reason: "The app closed before this session ended. Monitoring has not resumed."))
                }
                return item
            }
        } catch { historyError = "Couldn’t load session history: \(error.localizedDescription)" }
        let client = self.client
        client.onDiagnostic = { Diagnostics.record($0) }
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.displayCount = NSScreen.screens.count
                self?.contextChanged(.displayChange)
            }
        }
        Diagnostics.record("App started. screenAccess=\(screenAccess)")
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshScreenAccess() }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !app.isTerminated else { return }
            Task { @MainActor in
                if app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.previousApplication = app }
                self?.contextChanged(.appSwitch)
            }
        }
        for notification in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                             NSWorkspace.sessionDidResignActiveNotification] {
            lifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pauseSession(reason: "Paused because the Mac slept, its displays slept, or the user session became inactive.") }
            })
        }
        let app = NSWorkspace.shared.frontmostApplication
        if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = app }
        client.onLoginCompleted = { [weak self] success, message in
            guard let self, self.signingIn else { return }
            self.resetSignInState()
            if success { Task { await self.connect() } }
            else { self.error = message ?? "Sign-in didn’t complete. Try again." }
        }
    }

    func connect() async {
        guard !connecting, !checking, !refiningTask, !shuttingDown else { return }
        let wasSigningIn = signingIn
        resetSignInState()
        connecting = true; error = nil; connection = "Connecting to Codex…"
        defer { connecting = false }
        do {
            if wasSigningIn { await client.cancelSignIn() }
            try await client.connect()
            account = try await client.account()
            accountEmail = client.accountEmail
            if account != nil {
                Diagnostics.record("Codex connected: ChatGPT subscription authenticated")
                models = try await client.models()
                let saved = UserDefaults.standard.string(forKey: "model")
                selectedModel = models.first(where: { $0.id == selectedModel })?.id ?? models.first(where: { $0.id == saved })?.id ?? models.first(where: \.isDefault)?.id ?? models[0].id
                connection = "Connected"
                connectionRetryAt = nil
            } else {
                connection = "Sign-in needed"
                Diagnostics.record("Codex connected: no signed-in account")
            }
        } catch {
            Diagnostics.failure("Codex connection", error)
            account = nil; accountEmail = nil; connection = "Connection needs attention"; self.error = error.localizedDescription
            client.stop()
            if session?.state == .running { connectionRetryAt = currentTime().addingTimeInterval(max(30, Double(aiIntervalSeconds))) }
        }
    }

    func signIn() async {
        guard !signingIn, !connecting, !checking, !refiningTask, !hasActiveSession else { return }
        signingIn = true; error = nil
        let attempt = UUID(); loginAttempt = attempt
        Diagnostics.record("ChatGPT browser sign-in started")
        signInDeadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled, let self, self.loginAttempt == attempt else { return }
            await self.cancelSignIn()
            self.error = "Sign-in timed out. You can try again, or continue checking with the connected account."
        }
        do {
            try await client.connect()
            guard loginAttempt == attempt else { return }
            let url = try await client.signIn()
            guard loginAttempt == attempt else { return }
            guard openSignInURL(url) else { throw GatekeeperError("Couldn’t open your browser for sign-in.") }
        } catch {
            guard loginAttempt == attempt else { return }
            resetSignInState()
            await client.cancelSignIn()
            self.error = error.localizedDescription
        }
    }

    private func resetSignInState() {
        signingIn = false; loginAttempt = nil
        signInDeadline?.cancel(); signInDeadline = nil
    }

    func cancelSignIn() async {
        guard signingIn else { return }
        // Reconnect cancels the browser attempt and verifies the existing account.
        await connect()
    }

    func refineTask() async {
        guard canCheck, !hasActiveSession else { return }
        let id = UUID(); taskSetupID = id; refiningTask = true; error = nil
        defer { if taskSetupID == id { refiningTask = false; taskSetupID = nil } }
        var details = taskContext
        if let question = taskQuestion, !taskAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            details += "\nClarifying question: \(question)\nYour answer: \(taskAnswer)"
        }
        do {
            let brief = try await client.refineTask(goal: goal, details: details, model: selectedModel)
            guard taskSetupID == id else { return }
            goal = brief.goal; taskContext = brief.context
            taskQuestion = brief.question.isEmpty ? nil : brief.question
            taskAnswer = ""
            UserDefaults.standard.set(goal, forKey: "goal")
            UserDefaults.standard.set(taskContext, forKey: "taskContext")
        } catch {
            guard taskSetupID == id else { return }
            self.error = error.localizedDescription
        }
    }

    func cancelTaskSetup() {
        guard refiningTask else { return }
        taskSetupID = nil; refiningTask = false
        client.stop(reason: "Task setup cancelled.")
        Task { await self.connect() }
    }

    private func classifierGoal(automatic: Bool) -> String {
        let title = automatic ? (session?.goal ?? goal) : goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = automatic ? (session?.taskContext ?? "") : taskContext
        return details.isEmpty ? title : title + "\nTask details and boundaries:\n" + details
    }

    private func windowContexts(_ captures: [CapturedScreen]) -> [UInt32: ScreenWindowContext] {
        Dictionary(uniqueKeysWithValues: captures.compactMap { capture in capture.context.map { (capture.id, $0) } })
    }

    private func scheduleCachedCheck() {
        cachedCheckTask?.cancel()
        guard session?.state == .running, interventionRules.hasRecentViews(at: currentTime()) else { return }
        let id = session?.id, revision = contextRevision
        cachedCheckTask = Task {
            var files: [URL] = []
            defer {
                for file in files { try? FileManager.default.removeItem(at: file) }
                temporaryImages.removeAll { files.contains($0) }
            }
            do {
                try await cacheCheckDelay()
                try Task.checkCancellation()
                guard sessionIsCurrent(id) else { return }
                let captures = try await captureScreens()
                files = captures.map(\.file); temporaryImages += files
                try Task.checkCancellation()
                guard sessionIsCurrent(id), contextRevision == revision else { return }
                let contexts = windowContexts(captures)
                if interventionRules.invalidateChangedViews(captures.map(\.fingerprint), contexts: contexts, at: currentTime()) { correctionNote = nil }
                var retained = interventions.filter { candidate in
                    if let context = candidate.context { return context == contexts[candidate.id] }
                    return false
                }
                let recalled = interventionRules.recalled(current: captures.map(\.fingerprint), contexts: contexts, at: currentTime())
                let recalledIDs = Set(recalled.map(\.id))
                retained.removeAll { recalledIDs.contains($0.id) }
                let newIDs = recalledIDs.subtracting(interventions.map(\.id))
                setInterventions(retained + recalled)
                if !newIDs.isEmpty {
                    recordEvent(kind: "intervention", trigger: .appSwitch, reason: "Immediately blurred a recently confirmed off-task view from the local cache.")
                }
            } catch { /* A cache miss/failure never creates an off-task judgment. */ }
        }
    }

    func startSession() {
        guard canStartSession else { return }
        refreshScreenAccess()
        if !screenAccess { requestScreenAccess() }
        guard screenAccess else { error = "Allow screen access before starting a focus session."; return }
        let now = currentTime()
        session = FocusSession(goal: goal.trimmingCharacters(in: .whitespacesAndNewlines), startedAt: now,
                               durationSeconds: sessionMinutes * 60, remainingSeconds: sessionMinutes * 60)
        session?.taskContext = taskContext
        UserDefaults.standard.set(taskContext, forKey: "taskContext")
        remainingSeconds = sessionMinutes * 60
        sessionDeadline = now.addingTimeInterval(Double(remainingSeconds))
        observedWindows = pollWindowContexts()
        policy = MonitoringPolicy(minimumGap: Double(aiIntervalSeconds))
        interventionRules.reset(); setInterventions([], allowRemoval: true); correctionNote = nil; interventionNote = nil
        lastSampleAt = nil; reviewedSessionID = nil; error = nil
        verdict = nil; screenshots = []; lastCheck = nil
        UserDefaults.standard.set(sessionMinutes, forKey: "sessionMinutes")
        UserDefaults.standard.set(aiIntervalSeconds, forKey: "aiIntervalSeconds")
        recordEvent(kind: "started", reason: "Session started. All displays monitored; fresh off-task screens will gradually blur.")
        if runsSessionLoop {
            let id = session?.id
            sessionTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.session?.id == id, self.hasActiveSession else { return }
                    self.tickSession()
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
            }
        }
        beginCheck(automatic: true, withCountdown: true)
    }

    func tickSession() {
        guard session?.state == .running, let deadline = sessionDeadline else { return }
        let now = currentTime()
        let expired = pendingReturns.filter { now >= returnDeadlines[$0, default: .distantFuture] }
        if !expired.isEmpty {
            pendingReturns.subtract(expired)
            policy.queue(.manual, at: now)
            scheduleCachedCheck()
        }
        let windows = pollWindowContexts()
        if let old = observedWindows, old != windows { contextChanged(.navigation) }
        observedWindows = windows
        if interventionRules.expireApprovals(at: now) {
            correctionNote = nil
            policy.queue(.manual, at: now)
        }
        remainingSeconds = max(0, Int(ceil(deadline.timeIntervalSince(now))))
        if remainingSeconds == 0 { endSession(completed: true); return }
        guard !checking, !connecting, !signingIn else { return }
        if account == nil {
            if connectionRetryAt == nil || now >= connectionRetryAt! {
                connectionRetryAt = now.addingTimeInterval(max(30, Double(aiIntervalSeconds)))
                Task { await self.connect() }
            }
            return
        }
        // During a request cooldown, another screenshot cannot trigger inference anyway.
        if interventions.isEmpty, let next = policy.nextAllowedRequest, now < next { return }
        let priorityPending = policy.pendingTrigger == .appSwitch || policy.pendingTrigger == .navigation || policy.pendingTrigger == .displayChange || policy.pendingTrigger == .manual
        if !priorityPending, let lastSampleAt, now.timeIntervalSince(lastSampleAt) < (interventions.isEmpty ? 5 : 2) { return }
        beginCheck(automatic: true, withCountdown: false)
    }

    func queueSessionCheck(_ trigger: CheckTrigger) {
        guard session?.state == .running else { return }
        policy.queue(trigger, at: currentTime())
    }

    func pauseSession(reason: String = "Paused by you. No captures or AI requests until resumed.") {
        guard session?.state == .running else { return }
        if let sessionDeadline { remainingSeconds = max(0, Int(ceil(sessionDeadline.timeIntervalSince(currentTime())))) }
        if remainingSeconds == 0 { endSession(completed: true); return }
        session?.remainingSeconds = remainingSeconds; session?.state = .paused
        returnDeadlines = [:]; pendingReturns = []
        setInterventions([], allowRemoval: true)
        sessionDeadline = nil
        interruptCheck()
        recordEvent(kind: "paused", reason: reason)
    }

    func resumeSession() {
        guard session?.state == .paused, !checking, !connecting, account != nil else { return }
        session?.state = .running
        sessionDeadline = currentTime().addingTimeInterval(Double(remainingSeconds))
        lastSampleAt = nil
        policy.queue(.manual, at: currentTime())
        recordEvent(kind: "resumed", reason: "Session resumed.")
    }

    func endSession(completed: Bool = false) {
        guard hasActiveSession else { return }
        if let sessionDeadline { remainingSeconds = max(0, Int(ceil(sessionDeadline.timeIntervalSince(currentTime())))) }
        session?.remainingSeconds = completed ? 0 : remainingSeconds
        remainingSeconds = session?.remainingSeconds ?? 0
        session?.state = completed ? .completed : .ended
        returnDeadlines = [:]; pendingReturns = []
        setInterventions([], allowRemoval: true); interventionRules.reset(); correctionNote = nil
        session?.endedAt = currentTime(); sessionDeadline = nil
        sessionTask?.cancel(); sessionTask = nil
        interruptCheck()
        recordEvent(kind: completed ? "completed" : "ended", reason: completed ? "Time is up. Monitoring stopped." : "Session ended. Monitoring stopped.")
        if let session {
            history.removeAll { $0.id == session.id }
            history.insert(session, at: 0); history = Array(history.prefix(20))
        }
        persistSession()
    }

    func check() {
        guard canCheck else { return }
        if session?.state == .running {
            queueSessionCheck(.manual)
            tickSession()
        } else { beginCheck(automatic: false, withCountdown: true) }
    }

    private func beginCheck(automatic: Bool, withCountdown: Bool) {
        guard !checking else { return }
        let sessionID = automatic ? session?.id : nil
        let taskGoal = classifierGoal(automatic: automatic)
        let model = selectedModel
        checking = true; error = nil
        UserDefaults.standard.set(automatic ? (session?.goal ?? goal) : goal, forKey: "goal")
        UserDefaults.standard.set(model, forKey: "model")
        checkTask = Task {
            var imageFiles: [URL] = []
            var requestTrigger: CheckTrigger?
            var appName: String?
            defer {
                for file in imageFiles { try? FileManager.default.removeItem(at: file) }
                temporaryImages.removeAll { imageFiles.contains($0) }
                checking = false; analysisInFlight = false; countdown = nil; stage = ""; checkTask = nil
                if reconnectAfterCheck && !shuttingDown {
                    reconnectAfterCheck = false
                    Task { await self.connect() }
                }
            }
            do {
                if !automatic {
                    refreshScreenAccess()
                    if !screenAccess { requestScreenAccess() }
                    guard screenAccess else { throw GatekeeperError("Enable screen recording access, then restart F Distractions if macOS requires it.") }
                }
                if withCountdown {
                    for remaining in (1...3).reversed() {
                        countdown = remaining; stage = "Switch to your work"
                        try await countdownDelay()
                        if remaining == 3 && !automatic { hideForWork() }
                    }
                }
                countdown = nil; stage = "Comparing screens locally…"
                try Task.checkCancellation()
                if automatic { guard sessionIsCurrent(sessionID) else { return } }
                lastSampleAt = currentTime()
                appName = foregroundAppName()
                let capturedContext = contextRevision
                let capturedAt = currentTime()
                let capturedApplication = NSWorkspace.shared.frontmostApplication
                let captures = try await captureScreens()
                imageFiles = captures.map(\.file)
                temporaryImages = imageFiles
                try Task.checkCancellation()
                if automatic { guard sessionIsCurrent(sessionID) else { return } }
                let fingerprints = captures.map(\.fingerprint)
                if automatic {
                    if interventionRules.invalidateChangedViews(fingerprints, contexts: windowContexts(captures), at: currentTime()) { correctionNote = nil }
                    if !interventions.isEmpty {
                        let remaining = try await retainedInterventions(current: fingerprints, contexts: windowContexts(captures))
                        try Task.checkCancellation()
                        guard sessionIsCurrent(sessionID) else { return }
                        if remaining.count != interventions.count {
                            setInterventions(remaining)
                            policy.queue(.visualChange, at: currentTime())
                        }
                    }
                    guard let trigger = policy.trigger(for: fingerprints, at: currentTime()) else {
                        session?.skippedSamples += 1
                        return
                    }
                    requestTrigger = trigger
                    policy.beganRequest(at: currentTime())
                    session?.aiChecks += 1
                    persistSession()
                } else { requestTrigger = .manual }
                displayCount = captures.count
                stage = "Checking all screens against your goal…"; analysisInFlight = true
                Diagnostics.record("AI check started: trigger=\(requestTrigger?.rawValue ?? "unknown") screens=\(captures.count)")
                if !automatic { showWindow?() }
                let result = try await client.analyse(goal: taskGoal, images: imageFiles, model: model)
                try Task.checkCancellation()
                if automatic { guard sessionIsCurrent(sessionID) else { return } }
                // Publish a complete assessment together. Refreshes never clear the last result.
                screenshots = captures; lastCheck = capturedAt; verdict = result
                interventionNote = nil
                if automatic {
                    policy.succeeded(with: fingerprints)
                    recordEvent(kind: result.status, trigger: requestTrigger, app: appName,
                                reason: result.reason, nextStep: result.nextStep)
                    if result.status == "on_task", capturedContext == contextRevision,
                       capturedApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        lastOnTaskApplication = capturedApplication
                    }
                    let candidates = try await currentInterventions(for: result, assessed: fingerprints,
                        assessedAt: capturedAt, capturedContext: capturedContext, assessedContexts: windowContexts(captures))
                    try Task.checkCancellation()
                    guard sessionIsCurrent(sessionID) else { return }
                    let newIDs = Set(candidates.map(\.id)).subtracting(interventions.map(\.id))
                    setInterventions(candidates)
                    interventionRules.remember(candidates, at: currentTime())
                    if !newIDs.isEmpty {
                        recordEvent(kind: "intervention", reason: "A gradual blur was applied to \(newIDs.count) screen(s) after a fresh off-task judgment.")
                    }
                }
                Diagnostics.record("Analysis completed: status=\(result.status)")
            } catch {
                if !Task.isCancelled && !(error is CancellationError) {
                    self.error = error.localizedDescription
                    Diagnostics.failure("Screen check", error)
                    if automatic && sessionIsCurrent(sessionID) {
                        setInterventions([])
                        policy.failed(at: currentTime())
                        recordEvent(kind: "error", trigger: requestTrigger ?? .retry, app: appName,
                                    reason: "Check failed; this is not an off-task judgment. A retry is delayed by at least 30 seconds.")
                        if analysisInFlight {
                            reconnectAfterCheck = true
                            client.stop(reason: "Reconnecting after a failed analysis.")
                        }
                    }
                }
            }
            if !automatic { showWindow?() }
        }
    }

    func contextChanged(_ trigger: CheckTrigger) {
        if interventionRules.invalidateChangedWindows(pollWindowContexts()) { correctionNote = nil }
        if trigger == .displayChange {
            contextRevision += 1
            interventionRules.reset()
            let connected = Set(NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value })
            setInterventions(interventions.filter { connected.contains($0.id) }, allowRemoval: true)
        }
        // App activation is global, while interventions target physical screens.
        // A switch on another monitor does not invalidate unchanged off-task content.
        // Existing overlays are checked against fresh images on the next local sample.
        queueSessionCheck(trigger)
        if trigger == .appSwitch || trigger == .navigation { scheduleCachedCheck() }
    }

    func returnToWork(displayID: UInt32) {
        guard interventions.contains(where: { $0.id == displayID }), session?.state == .running else { return }
        returnDeadlines[displayID] = currentTime().addingTimeInterval(3)
        pendingReturns.insert(displayID)
        cachedCheckTask?.cancel()
        setInterventions(interventions.filter { $0.id != displayID }, allowRemoval: true)
        interventionNote = "This screen is clear for 3 seconds. Switch back to your task."
        recordEvent(kind: "returning", reason: "This screen's blur lifted for 3 seconds. Unchanged distractions reblur locally; changed views get a fresh assessment.")
    }

    func markRelevant(displayID: UInt32) {
        guard let candidate = interventions.first(where: { $0.id == displayID }), session?.state == .running else { return }
        let latest = screenshots.first { $0.id == displayID && $0.context == candidate.context }
        interventionRules.approve(latest?.fingerprint ?? candidate.fingerprint, context: latest?.context ?? candidate.context, at: currentTime())
        setInterventions(interventions.filter { $0.id != displayID }, allowRemoval: true)
        correctionNote = "Screen \(candidate.screenIndex) approved for this view for up to 2 minutes."
        recordEvent(kind: "correction", reason: "You marked Screen \(candidate.screenIndex) relevant. This view is exempt from blur for up to 2 minutes, until this screen’s window/tab or content changes.")
    }

    func takeBreak() { requestSessionExit(.pause) }

    private func setInterventions(_ candidates: [InterventionCandidate], allowRemoval: Bool = false) {
        // Interventions latch until an explicit action. Background samples, AI
        // verdicts and errors can add/update a blur, but cannot silently lift it.
        var byDisplay = Dictionary(uniqueKeysWithValues: (allowRemoval ? [] : interventions).map { ($0.id, $0) })
        for candidate in candidates { byDisplay[candidate.id] = candidate }
        let next = byDisplay.values.filter { currentTime() >= returnDeadlines[$0.id, default: .distantPast] }
            .sorted { $0.screenIndex < $1.screenIndex }
        interventionNote = next.isEmpty ? nil : "\(next.count) screen(s) locked. Use Return to work or This is relevant to lift the blur."
        guard next != interventions else { return }
        interventions = next
        if !next.isEmpty { correctionNote = nil }
        onInterventionsChanged?(next)
        Diagnostics.record("Focus overlays updated: screens=\(next.count)")
    }

    private func freshSceneSamples(against baseline: [ScreenFingerprint], first: [ScreenFingerprint]? = nil,
                                   firstContexts: [UInt32: ScreenWindowContext] = [:]) async throws -> ([ScreenFingerprint], [ScreenFingerprint], [UInt32: ScreenWindowContext]) {
        var temporary: [URL] = []
        defer {
            for file in temporary { try? FileManager.default.removeItem(at: file) }
            temporaryImages.removeAll { temporary.contains($0) }
        }
        let current: [ScreenFingerprint]
        var contexts = firstContexts
        if let first { current = first }
        else {
            let captures = try await captureScreens()
            temporary += captures.map(\.file); temporaryImages += captures.map(\.file)
            current = captures.map(\.fingerprint)
            contexts = windowContexts(captures)
        }
        try Task.checkCancellation()
        let baselineIDs = Set(baseline.map(\.displayID))
        if ScreenComparison.changed(current.filter { baselineIDs.contains($0.displayID) }, since: baseline) {
            try await freshnessDelay()
            let captures = try await captureScreens()
            temporary += captures.map(\.file); temporaryImages += captures.map(\.file)
            try Task.checkCancellation()
            return (current, captures.map(\.fingerprint), windowContexts(captures))
        }
        return (current, [], contexts)
    }

    private func retainedInterventions(current: [ScreenFingerprint], contexts: [UInt32: ScreenWindowContext]) async throws -> [InterventionCandidate] {
        let existing = interventions
        let revision = contextRevision
        let samples = try await freshSceneSamples(against: existing.map(\.fingerprint), first: current, firstContexts: contexts)
        guard revision == contextRevision else { return [] }
        return existing.filter { candidate in
            guard let fresh = samples.0.first(where: { $0.displayID == candidate.id }) else { return false }
            if let context = candidate.context { return context == samples.2[candidate.id] }
            return SceneFreshness.matches(candidate.fingerprint, current: fresh,
                followup: samples.1.first { $0.displayID == candidate.id })
        }
    }

    private func currentInterventions(for result: Verdict, assessed: [ScreenFingerprint], assessedAt: Date,
                                     capturedContext: Int, assessedContexts: [UInt32: ScreenWindowContext]) async throws -> [InterventionCandidate] {
        guard result.screens.contains(where: { $0.status == "off_task" }) else { return [] }
        guard capturedContext == contextRevision, currentTime().timeIntervalSince(assessedAt) <= 20 else {
            queueSessionCheck(.visualChange)
            let reason = capturedContext != contextRevision ? "The display arrangement changed during analysis." : "The assessment was older than 20 seconds."
            recordEvent(kind: "rechecking", reason: reason + " Blur was withheld and a fresh check queued.")
            Diagnostics.record("Blur withheld: \(capturedContext != contextRevision ? "display_change" : "result_age")")
            interventionNote = reason + " Rechecking before applying a blur."
            return []
        }
        let samples = try await freshSceneSamples(against: assessed)
        let candidates = interventionRules.candidates(verdict: result, assessed: assessed, current: samples.0,
            followup: samples.1, assessedAt: assessedAt, now: currentTime(), contextUnchanged: capturedContext == contextRevision,
            assessedContexts: assessedContexts, currentContexts: samples.2).filter {
                assessedAt >= returnDeadlines[$0.id, default: .distantPast]
            }
        var withheld: [String] = []
        for screen in result.screens where screen.status == "off_task" && !candidates.contains(where: { $0.screenIndex == screen.screenIndex }) {
            guard assessed.indices.contains(screen.screenIndex - 1) else { continue }
            let id = assessed[screen.screenIndex - 1].displayID
            let latest = samples.0.first { $0.displayID == id }
            let following = samples.1.first { $0.displayID == id }
            let reason = latest == nil ? "display unavailable" :
                interventionRules.isApproved(latest!, followup: following, context: samples.2[id], at: currentTime()) ? "view approved by you" :
                capturedContext != contextRevision ? "display arrangement changed" :
                assessedContexts[id] != nil ? "the visible app window changed" : "content changed and no window identity was available"
            withheld.append("Screen \(screen.screenIndex): \(reason)")
        }
        if !withheld.isEmpty {
            let description = withheld.joined(separator: "; ")
            Diagnostics.record("Blur withheld: \(description)")
            recordEvent(kind: "rechecking", reason: "Blur withheld. " + description + ".")
            interventionNote = "Blur withheld. " + description + "."
        }
        if candidates.isEmpty && !result.screens.filter({ $0.status == "off_task" }).allSatisfy({ screen in
            guard assessed.indices.contains(screen.screenIndex - 1),
                  let current = samples.0.first(where: { $0.displayID == assessed[screen.screenIndex - 1].displayID }) else { return false }
            return interventionRules.isApproved(current, followup: samples.1.first { $0.displayID == current.displayID }, context: samples.2[current.displayID], at: currentTime())
        }) {
            queueSessionCheck(.visualChange)
        }
        return candidates
    }

    private func sessionIsCurrent(_ id: UUID?) -> Bool {
        guard session?.id == id, session?.state == .running, let deadline = sessionDeadline else { return false }
        if currentTime() >= deadline { endSession(completed: true); return false }
        return true
    }

    private func interruptCheck() {
        cachedCheckTask?.cancel(); cachedCheckTask = nil
        checkTask?.cancel()
        if analysisInFlight {
            reconnectAfterCheck = true
            client.stop(reason: "Screen check interrupted by session controls.")
            connection = "Reconnecting…"
        }
    }

    func cancel() {
        if session?.state == .running { requestSessionExit(.pause) }
        else { interruptCheck() }
    }

    private func recordEvent(kind: String, trigger: CheckTrigger? = nil, app: String? = nil, reason: String, nextStep: String? = nil) {
        guard session != nil else { return }
        session?.events.append(SessionEvent(date: currentTime(), kind: kind, trigger: trigger?.rawValue,
                                            app: app, reason: reason, nextStep: nextStep))
        if let count = session?.events.count, count > 500 { session?.events.removeFirst(count - 500) }
        persistSession()
    }

    private func persistSession() {
        var records = history
        if let session {
            records.removeAll { $0.id == session.id }; records.insert(session, at: 0)
        }
        do { try sessionStore.save(records); historyError = nil }
        catch { historyError = "Couldn’t save session history: \(error.localizedDescription)" }
    }

    func saveTaskDraft() {
        UserDefaults.standard.set(goal, forKey: "goal")
        UserDefaults.standard.set(taskContext, forKey: "taskContext")
    }

    func newTask() {
        guard !checking, !refiningTask else { return }
        if hasActiveSession { endSession() }
        session = nil; reviewedSessionID = nil; remainingSeconds = 0
        goal = ""; taskContext = ""; taskQuestion = nil; taskAnswer = ""
        interventionNote = nil; correctionNote = nil
        clear()
        UserDefaults.standard.set("", forKey: "goal")
        UserDefaults.standard.set("", forKey: "taskContext")
    }

    func clear() {
        screenshots = []; verdict = nil; lastCheck = nil; error = nil
    }

    func openPermissions() {
        Diagnostics.record("Opening screen recording settings")
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func refreshScreenAccess() {
        let granted = permissionAvailable()
        if granted != screenAccess {
            Diagnostics.record("Screen access changed: \(granted)")
            if granted { error = nil }
        }
        screenAccess = granted
    }

    func requestScreenAccess() {
        permissionRequested = true
        Diagnostics.record("Requesting macOS screen recording permission")
        let granted = CGRequestScreenCaptureAccess()
        screenAccess = granted || CGPreflightScreenCaptureAccess()
        Diagnostics.record("Permission request returned. screenAccess=\(screenAccess)")
    }

    func restart() {
        guard !checking, !hasActiveSession else { return }
        UserDefaults.standard.set(goal, forKey: "goal")
        UserDefaults.standard.set(selectedModel, forKey: "model")
        UserDefaults.standard.synchronize()
        Diagnostics.record("Restart requested to reload macOS permissions")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            Task { @MainActor in
                if let error {
                    self.error = "Couldn’t restart F Distractions: \(error.localizedDescription)"
                    Diagnostics.failure("Restart", error)
                } else { NSApp.terminate(nil) }
            }
        }
    }

    func openLogs() { NSWorkspace.shared.open(Diagnostics.file) }

    func shutdown() {
        taskSetupID = nil; cachedCheckTask?.cancel(); cachedCheckTask = nil
        setInterventions([], allowRemoval: true)
        shuttingDown = true; reconnectAfterCheck = false
        resetSignInState()
        if hasActiveSession {
            if let sessionDeadline { session?.remainingSeconds = max(0, Int(ceil(sessionDeadline.timeIntervalSince(currentTime())))) }
            session?.state = .interrupted; session?.endedAt = currentTime()
            recordEvent(kind: "interrupted", reason: "App quit. Monitoring stopped and will not restart automatically.")
        }
        sessionTask?.cancel(); sessionTask = nil
        UserDefaults.standard.set(goal, forKey: "goal")
        UserDefaults.standard.set(taskContext, forKey: "taskContext")
        if !selectedModel.isEmpty { UserDefaults.standard.set(selectedModel, forKey: "model") }
        Diagnostics.record("App shutting down")
        checkTask?.cancel(); client.stop()
        for file in temporaryImages { try? FileManager.default.removeItem(at: file) }
        temporaryImages = []
        ScreenCapture.cleanupTemporaryCaptures()
    }
}
