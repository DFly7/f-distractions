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
    var onInterventionsChanged: (([InterventionCandidate], Diagnostics.Trace?) -> Void)?
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
    private var viewProbeTask: Task<Void, Never>?
    private(set) var priorityInterruptTask: Task<Void, Never>?
    private var viewProbeBaseline: [ScreenFingerprint]?
    private var inFlightWindows: [UInt32: ScreenWindowContext] = [:]
    private var inFlightScreenCount = 0
    private var sceneRevision = 0
    private var visualRevision = 0
    var prioritySettleDelay: () async throws -> Void = { try await Task.sleep(nanoseconds: 350_000_000) }
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
    private let secondaryClient: (any GatekeeperConnection)?
    private(set) var secondaryCheckTask: Task<Void, Never>?
    private(set) var warmSecondaryTask: Task<Void, Never>?
    private var secondaryReady = false
    private var busySlots: Set<Int> = []
    private var inferenceSlots: Set<Int> = []
    private var slotTraces: [Int: Diagnostics.Trace] = [:]
    private var priorityPending = false
    private var submittedViews: [UInt32: (fingerprint: ScreenFingerprint, context: ScreenWindowContext?, pointerEpoch: Int)] = [:]
    private var pointerEpochs: [UInt32: Int] = [:]
    private var scrollHints: [UInt32: (epoch: Int, context: ScreenWindowContext?, date: Date)] = [:]
    private var inputContexts: [UInt32: ScreenWindowContext] = [:]
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var displayOrder: [UInt32] = []
    private var requestSequence = 0
    private var latestRequestByDisplay: [UInt32: Int] = [:]
    private var completedScreens: [UInt32: (capture: CapturedScreen, verdict: ScreenVerdict, date: Date, nextStep: String)] = [:]
    @Published private(set) var assessmentTimes: [UInt32: Date] = [:]
    private var signInDeadline: Task<Void, Never>?
    private var loginAttempt: UUID?
    var openSignInURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    private(set) var checkTask: Task<Void, Never>?
    private var previousApplication: NSRunningApplication?
    private var spaceObserver: NSObjectProtocol?
    private var interruptScheduleID: UUID?
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

    init(client: (any GatekeeperConnection)? = nil, sessionStore: SessionStore? = nil, secondaryClient: (any GatekeeperConnection)? = nil) {
        self.client = client ?? CodexClient()
        self.secondaryClient = secondaryClient ?? (client == nil ? CodexClient() : nil)
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
        client.onDiagnostic = { [weak self] message in
            Diagnostics.event("provider", trace: self?.slotTraces[0], details: "slot=0 " + message)
        }
        self.secondaryClient?.onDiagnostic = { [weak self] message in
            Diagnostics.event("provider", trace: self?.slotTraces[1], details: "slot=1 " + message)
        }
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
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.contextChanged(.spaceChange) }
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
                startWarmingSecondary()
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
        warmSecondaryTask?.cancel(); secondaryClient?.stop(); secondaryReady = false
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

    private var pendingSceneTrace: Diagnostics.Trace?
    private var activeAITrace: Diagnostics.Trace?
    private var lastProbeFailureAt: Date?

    private func scheduleCachedCheck() {
        cachedCheckTask?.cancel()
        guard session?.state == .running else { return }
        guard interventionRules.hasRecentViews(at: currentTime()) else {
            Diagnostics.event("cache_unavailable", trace: pendingSceneTrace, details: "reason=no_recent_views")
            return
        }
        let id = session?.id, revision = contextRevision
        let trace = pendingSceneTrace ?? Diagnostics.Trace()
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
                Diagnostics.event("cache_lookup_started", trace: trace)
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
                var recalled = interventionRules.recalled(current: captures.map(\.fingerprint), contexts: contexts, at: currentTime())
                var usedMotionComparison = false
                let matchingContext = interventionRules.hasMatchingContext(contexts, at: currentTime())
                if recalled.isEmpty, matchingContext {
                    usedMotionComparison = true
                    try await freshnessDelay()
                    let next = try await captureScreens()
                    files += next.map(\.file); temporaryImages += next.map(\.file)
                    try Task.checkCancellation()
                    guard sessionIsCurrent(id), contextRevision == revision else { return }
                    let nextContexts = windowContexts(next)
                    // Never compare motion across a window/tab change.
                    if nextContexts == contexts {
                        recalled = interventionRules.recalled(current: captures.map(\.fingerprint), followup: next.map(\.fingerprint), contexts: contexts, at: currentTime())
                    }
                }
                let recalledIDs = Set(recalled.map(\.id))
                retained.removeAll { recalledIDs.contains($0.id) }
                let newIDs = recalledIDs.subtracting(interventions.map(\.id))
                Diagnostics.event("cache_lookup_finished", trace: trace, details: "hits=\(recalled.count) new_blurs=\(newIDs.count) motion_comparison=\(usedMotionComparison) matching_context=\(matchingContext)")
                setInterventions(retained + recalled, trace: trace)
                if !newIDs.isEmpty {
                    recordEvent(kind: "intervention", trigger: .appSwitch, reason: "Immediately blurred a recently confirmed off-task view from the local cache.")
                }
            } catch {
                Diagnostics.event(error is CancellationError ? "cache_cancelled" : "cache_failed", trace: trace)
            }
        }
    }

    func startSession() {
        guard canStartSession else { return }
        refreshScreenAccess()
        if !screenAccess { requestScreenAccess() }
        guard screenAccess else { error = "Allow screen access before starting a focus session."; return }
        let now = currentTime()
        submittedViews = [:]; latestRequestByDisplay = [:]; completedScreens = [:]; assessmentTimes = [:]
        priorityPending = false
        pendingSceneTrace = Diagnostics.Trace()
        Diagnostics.event("session_started", trace: pendingSceneTrace)
        session = FocusSession(goal: goal.trimmingCharacters(in: .whitespacesAndNewlines), startedAt: now,
                               durationSeconds: sessionMinutes * 60, remainingSeconds: sessionMinutes * 60)
        installPointerMonitors()
        session?.taskContext = taskContext
        UserDefaults.standard.set(taskContext, forKey: "taskContext")
        remainingSeconds = sessionMinutes * 60
        sessionDeadline = now.addingTimeInterval(Double(remainingSeconds))
        observedWindows = pollWindowContexts()
        inputContexts = observedWindows ?? [:]; pointerEpochs = [:]; scrollHints = [:]
        policy = MonitoringPolicy(minimumGap: Double(aiIntervalSeconds))
        interventionRules.reset(); setInterventions([], allowRemoval: true); correctionNote = nil; interventionNote = nil
        viewProbeBaseline = nil
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
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                }
            }
            viewProbeTask?.cancel()
            viewProbeTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.session?.id == id, self.hasActiveSession else { return }
                    await self.probeForViewChange()
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
            }
        }
        beginCheck(automatic: true, withCountdown: false)
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
        let remaining = max(0, Int(ceil(deadline.timeIntervalSince(now))))
        if remainingSeconds != remaining { remainingSeconds = remaining }
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
        let priorityPending = policy.pendingTrigger == .spaceChange || policy.pendingTrigger == .appSwitch || policy.pendingTrigger == .navigation || policy.pendingTrigger == .viewChange || policy.pendingTrigger == .displayChange || policy.pendingTrigger == .manual
        if !priorityPending, let lastSampleAt, now.timeIntervalSince(lastSampleAt) < (interventions.isEmpty ? 5 : 2) { return }
        beginCheck(automatic: true, withCountdown: false)
    }

    func queueSessionCheck(_ trigger: CheckTrigger) {
        guard session?.state == .running else { return }
        policy.queue(trigger, at: currentTime())
        if pendingSceneTrace == nil { pendingSceneTrace = Diagnostics.Trace() }
        let waitMS = max(0, Int((policy.nextAllowedRequest?.timeIntervalSince(currentTime()) ?? 0) * 1000))
        Diagnostics.event("check_queued", trace: pendingSceneTrace, details: "trigger=\(trigger.rawValue) in_flight=\(analysisInFlight) connecting=\(connecting) signing_in=\(signingIn) cooldown_ms=\(waitMS)")
        if trigger == .visualChange, secondaryClient != nil {
            priorityPending = true; scheduleParallelCheck()
        }
    }

    func pauseSession(reason: String = "Paused by you. No captures or AI requests until resumed.") {
        guard session?.state == .running else { return }
        if let sessionDeadline { remainingSeconds = max(0, Int(ceil(sessionDeadline.timeIntervalSince(currentTime())))) }
        if remainingSeconds == 0 { endSession(completed: true); return }
        session?.remainingSeconds = remainingSeconds; session?.state = .paused
        uninstallPointerMonitors()
        returnDeadlines = [:]; pendingReturns = []
        setInterventions([], allowRemoval: true)
        sessionDeadline = nil
        interruptCheck()
        recordEvent(kind: "paused", reason: reason)
    }

    func resumeSession() {
        guard session?.state == .paused, !checking, !connecting, account != nil else { return }
        session?.state = .running
        installPointerMonitors()
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
        uninstallPointerMonitors()
        returnDeadlines = [:]; pendingReturns = []
        setInterventions([], allowRemoval: true); interventionRules.reset(); correctionNote = nil
        session?.endedAt = currentTime(); sessionDeadline = nil
        sessionTask?.cancel(); sessionTask = nil
        viewProbeTask?.cancel(); viewProbeTask = nil
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

    private func installPointerMonitors() {
        guard runsSessionLoop, globalPointerMonitor == nil, localPointerMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            let scrolling = event.type == .scrollWheel
            Task { @MainActor in self?.recordPointerAtMouseLocation(scrolling: scrolling) }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            let scrolling = event.type == .scrollWheel
            Task { @MainActor in self?.recordPointerAtMouseLocation(scrolling: scrolling) }
            return event
        }
    }

    private func uninstallPointerMonitors() {
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor); self.globalPointerMonitor = nil }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor); self.localPointerMonitor = nil }
    }

    private func recordPointerAtMouseLocation(scrolling: Bool) {
        guard runsSessionLoop, session?.state == .running,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return }
        recordPointerActivity(displayID: id, scrolling: scrolling)
    }

    /// Metadata only: no text, key events, pointer coordinates or destinations are stored.
    func recordPointerActivity(displayID: UInt32, scrolling: Bool) {
        guard session?.state == .running else { return }
        if scrolling {
            scrollHints[displayID] = (pointerEpochs[displayID, default: 0], inputContexts[displayID], currentTime())
        } else {
            pointerEpochs[displayID, default: 0] += 1; scrollHints[displayID] = nil
        }
    }

    private func scrollContinuesView(displayID: UInt32, context: ScreenWindowContext?, epoch: Int) -> Bool {
        guard let context, let hint = scrollHints[displayID] else { return false }
        let age = currentTime().timeIntervalSince(hint.date)
        return age >= 0 && age <= 1.5 && hint.epoch == epoch && pointerEpochs[displayID, default: 0] == epoch && hint.context == context &&
            pollWindowContexts()[displayID] == context
    }

    private func startWarmingSecondary() {
        guard let secondaryClient, !secondaryReady, warmSecondaryTask == nil, !shuttingDown else { return }
        warmSecondaryTask = Task {
            defer { warmSecondaryTask = nil }
            do {
                try await secondaryClient.connect()
                guard try await secondaryClient.account() != nil else { throw GatekeeperError("Subscription sign-in needed.") }
                _ = try await secondaryClient.models()
                try Task.checkCancellation()
                guard !shuttingDown else { return }
                secondaryReady = true
                Diagnostics.event("parallel_slot_ready", details: "slot=1")
                if priorityPending { scheduleParallelCheck() }
            } catch {
                secondaryReady = false; secondaryClient.stop()
                Diagnostics.failure("parallel_slot_warmup", error)
            }
        }
    }

    /// One coalesced pending view, sampled only when a slot can actually accept it.
    private func scheduleParallelCheck() {
        guard secondaryClient != nil, priorityPending, session?.state == .running,
              priorityInterruptTask == nil, !reconnectAfterCheck, !shuttingDown else { return }
        if busySlots.count >= 2 {
            Diagnostics.event("parallel_pending", trace: pendingSceneTrace, details: "reason=both_slots_busy")
            return
        }
        priorityInterruptTask = Task {
            defer { priorityInterruptTask = nil }
            do { try await prioritySettleDelay() } catch { return }
            guard !Task.isCancelled, priorityPending, session?.state == .running, !policy.isBackingOff(at: currentTime()) else { return }
            if !busySlots.contains(0) {
                beginCheck(automatic: true, withCountdown: false, slot: 0, changedOnly: true)
            } else if secondaryReady && !busySlots.contains(1) {
                beginCheck(automatic: true, withCountdown: false, slot: 1, changedOnly: true)
            }
        }
    }

    private func changedCaptures(_ first: [CapturedScreen]) async throws -> (captures: [CapturedScreen], extraFiles: [URL]) {
        var files: [URL] = []
        do {
            let needsMotionSample = first.contains { capture in
                guard let previous = submittedViews[capture.id] else { return false }
                return ScreenComparison.changed([capture.fingerprint], since: [previous.fingerprint])
            }
            var followup: [CapturedScreen] = []
            if needsMotionSample {
                try await freshnessDelay()
                followup = try await captureScreens(); files = followup.map(\.file)
                try Task.checkCancellation()
            }
            let current = followup.isEmpty ? first : followup
            let cachedIDs = Set(interventionRules.recalled(current: first.map(\.fingerprint), followup: followup.map(\.fingerprint),
                contexts: windowContexts(current), at: currentTime()).map(\.id))
            let changed = current.filter { capture in
                guard !cachedIDs.contains(capture.id),
                      !interventionRules.isApproved(capture.fingerprint, context: capture.context, at: currentTime()) else { return false }
                guard let previous = submittedViews[capture.id] else { return true }
                if scrollContinuesView(displayID: capture.id, context: previous.context, epoch: previous.pointerEpoch) { return false }
                if let old = previous.context, let new = capture.context,
                   old.windowID != new.windowID || old.processID != new.processID { return true }
                guard let initial = first.first(where: { $0.id == capture.id }) else { return true }
                // Ignore progress-title churn and moving video when stable content is unchanged.
                return !SceneFreshness.matches(previous.fingerprint, current: initial.fingerprint,
                    followup: followup.first(where: { $0.id == capture.id })?.fingerprint)
            }
            return (changed, files)
        } catch {
            for file in files { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    func completedVerdict(forPhysicalIndex index: Int) -> ScreenVerdict? {
        guard !completedScreens.isEmpty else { return verdict?.screens.first { $0.screenIndex == index } }
        guard displayOrder.indices.contains(index - 1) else { return nil }
        return completedScreens[displayOrder[index - 1]]?.verdict
    }

    private func publishAssessment(_ result: Verdict, captures: [CapturedScreen], at date: Date, sequence: Int) {
        for (index, capture) in captures.enumerated() where latestRequestByDisplay[capture.id] == sequence {
            let screen = result.screens.first { $0.screenIndex == index + 1 } ??
                ScreenVerdict(screenIndex: index + 1, status: result.status, reason: result.reason)
            completedScreens[capture.id] = (capture, screen, date, result.nextStep)
        }
        let ordered = displayOrder.compactMap { completedScreens[$0] }
        guard !ordered.isEmpty else { return }
        screenshots = ordered.map(\.capture)
        assessmentTimes = Dictionary(uniqueKeysWithValues: ordered.map { ($0.capture.id, $0.date) })
        lastCheck = ordered.map(\.date).max()
        let screens = ordered.enumerated().map { index, item in
            ScreenVerdict(screenIndex: index + 1, status: item.verdict.status, reason: item.verdict.reason,
                          evidenceSource: item.verdict.evidenceSource)
        }
        let status = screens.contains { $0.status == "off_task" } ? "off_task" :
            screens.contains { $0.status == "unsure" } ? "unsure" : screens.contains { $0.status == "on_task" } ? "on_task" : "unsure"
        // Preserve the provider's coherent summary for a complete, current batch.
        let completeBatch = captures.count == displayOrder.count && captures.count == ordered.count && captures.allSatisfy { latestRequestByDisplay[$0.id] == sequence }
        verdict = completeBatch ? result : Verdict(status: status,
            reason: ordered.map { item in "Screen \((displayOrder.firstIndex(of: item.capture.id) ?? 0) + 1): \(item.verdict.reason)" }.joined(separator: " "),
            nextStep: ordered.first(where: { $0.verdict.status == "off_task" })?.nextStep ?? result.nextStep, screens: screens)
    }

    private func beginCheck(automatic: Bool, withCountdown: Bool, slot: Int = 0, changedOnly: Bool = false) {
        guard !busySlots.contains(slot), let requestClient = slot == 0 ? client : secondaryClient else { return }
        if slot == 1 && !secondaryReady { return }
        busySlots.insert(slot)
        let sessionID = automatic ? session?.id : nil
        let taskGoal = classifierGoal(automatic: automatic)
        let model = selectedModel
        checking = true; error = nil
        UserDefaults.standard.set(automatic ? (session?.goal ?? goal) : goal, forKey: "goal")
        UserDefaults.standard.set(model, forKey: "model")
        let trace = pendingSceneTrace ?? Diagnostics.Trace()
        let task = Task {
            var sequence = 0
            var outcome = "abandoned"
            var imageFiles: [URL] = []
            var requestTrigger: CheckTrigger?
            var appName: String?
            defer {
                Diagnostics.event("check_finished", trace: trace, details: "outcome=\(outcome)")
                slotTraces[slot] = nil
                if slot == 0 { activeAITrace = nil; inFlightWindows = [:]; inFlightScreenCount = 0 }
                for file in imageFiles { try? FileManager.default.removeItem(at: file) }
                temporaryImages.removeAll { imageFiles.contains($0) }
                busySlots.remove(slot); inferenceSlots.remove(slot)
                checking = !busySlots.isEmpty; analysisInFlight = !inferenceSlots.isEmpty
                if slot == 0 { countdown = nil; checkTask = nil } else { secondaryCheckTask = nil }
                if !checking { stage = "" }
                if reconnectAfterCheck && busySlots.isEmpty && !shuttingDown {
                    reconnectAfterCheck = false
                    Task { await self.connect() }
                }
                if priorityPending && sessionIsCurrent(sessionID) { scheduleParallelCheck() }
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
                if slot == 0 { countdown = nil }
                if inferenceSlots.isEmpty { stage = "Comparing screens locally…" }
                try Task.checkCancellation()
                if automatic { guard sessionIsCurrent(sessionID) else { return } }
                lastSampleAt = currentTime()
                appName = foregroundAppName()
                let capturedContext = contextRevision
                let capturedScene = sceneRevision
                let capturedVisual = visualRevision
                let capturedPointerEpochs = pointerEpochs
                let capturedAt = currentTime()
                let capturedApplication = NSWorkspace.shared.frontmostApplication
                let captureStart = ProcessInfo.processInfo.systemUptime
                Diagnostics.event("capture_started", trace: trace)
                let allCaptures = try await captureScreens()
                var captures = allCaptures
                displayOrder = allCaptures.map(\.id)
                Diagnostics.event("capture_finished", trace: trace, details: "duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - captureStart) * 1000)) screens=\(allCaptures.count) slot=\(slot)")
                imageFiles = allCaptures.map(\.file)
                temporaryImages += imageFiles
                try Task.checkCancellation()
                if automatic { guard sessionIsCurrent(sessionID) else { return } }
                if changedOnly {
                    let selected = try await changedCaptures(allCaptures)
                    imageFiles += selected.extraFiles; temporaryImages += selected.extraFiles
                    try Task.checkCancellation()
                    guard sessionIsCurrent(sessionID) else { return }
                    captures = selected.captures
                    guard !captures.isEmpty else {
                        if capturedScene == sceneRevision && capturedVisual == visualRevision { priorityPending = false }
                        outcome = "unchanged_or_cached"
                        return
                    }
                }
                let fingerprints = captures.map(\.fingerprint)
                if automatic {
                    if interventionRules.invalidateChangedViews(fingerprints, contexts: windowContexts(captures), at: currentTime()) { correctionNote = nil }
                    if !interventions.isEmpty && !changedOnly {
                        let remaining = try await retainedInterventions(current: fingerprints, contexts: windowContexts(captures))
                        try Task.checkCancellation()
                        guard sessionIsCurrent(sessionID) else { return }
                        if remaining.count != interventions.count {
                            setInterventions(remaining)
                            policy.queue(.visualChange, at: currentTime())
                        }
                    }
                    guard let trigger = changedOnly && !policy.isBackingOff(at: currentTime()) ? (policy.pendingTrigger ?? .viewChange) : policy.trigger(for: fingerprints, at: currentTime()) else {
                        session?.skippedSamples += 1
                        outcome = "local_skip"
                        return
                    }
                    requestTrigger = trigger
                    for capture in captures { submittedViews[capture.id] = (capture.fingerprint, capture.context, capturedPointerEpochs[capture.id, default: 0]) }
                    viewProbeBaseline = displayOrder.compactMap { submittedViews[$0]?.fingerprint }
                    policy.beganRequest(at: currentTime())
                    session?.aiChecks += 1
                    persistSession()
                } else { requestTrigger = .manual }
                displayCount = allCaptures.count
                stage = "Checking screens against your goal…"; inferenceSlots.insert(slot); analysisInFlight = true
                if slot == 0 {
                    inFlightWindows = windowContexts(captures); inFlightScreenCount = captures.count
                    activeAITrace = trace
                }
                requestSequence += 1; sequence = requestSequence
                for capture in captures { latestRequestByDisplay[capture.id] = sequence }
                slotTraces[slot] = trace
                if capturedScene == sceneRevision && capturedVisual == visualRevision { priorityPending = false }
                if pendingSceneTrace?.id == trace.id { pendingSceneTrace = nil }
                Diagnostics.event("ai_started", trace: trace, details: "trigger=\(requestTrigger?.rawValue ?? "unknown") screens=\(captures.count) model=\(model) slot=\(slot) sequence=\(sequence) concurrent=\(inferenceSlots.count) displays=\(captures.map { String($0.id) }.joined(separator: ","))")
                if !automatic { showWindow?() }
                let result = try await requestClient.analyse(goal: taskGoal, images: captures.map(\.file), model: model)
                Diagnostics.event("ai_reply_received", trace: trace, details: "status=\(result.status)")
                try Task.checkCancellation()
                if automatic {
                    guard sessionIsCurrent(sessionID) else { return }
                    // A different monitor or title update cannot invalidate every
                    // screen. Each off-task screen is checked against fresh evidence below.
                }
                let eligibleIDs = Set(captures.filter { latestRequestByDisplay[$0.id] == sequence }.map(\.id))
                guard capturedContext == contextRevision, !eligibleIDs.isEmpty else {
                    outcome = "superseded"
                    Diagnostics.event("assessment_discarded", trace: trace, details: "reason=newer_request_or_display_mapping slot=\(slot)")
                    return
                }
                publishAssessment(result, captures: captures, at: capturedAt, sequence: sequence)
                interventionNote = nil
                if automatic {
                    var baseline = Dictionary(uniqueKeysWithValues: (policy.baseline ?? []).map { ($0.displayID, $0) })
                    for capture in captures where eligibleIDs.contains(capture.id) { baseline[capture.id] = capture.fingerprint }
                    policy.succeeded(with: displayOrder.compactMap { baseline[$0] })
                    recordEvent(kind: verdict?.status ?? result.status, trigger: requestTrigger, app: appName,
                                reason: verdict?.reason ?? result.reason, nextStep: verdict?.nextStep ?? result.nextStep)
                    if result.status == "on_task", capturedContext == contextRevision,
                       capturedApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        lastOnTaskApplication = capturedApplication
                    }
                    Diagnostics.event("freshness_started", trace: trace)
                    let assessedCandidates = try await currentInterventions(for: result, assessed: fingerprints,
                        assessedAt: capturedAt, capturedContext: capturedContext, assessedContexts: windowContexts(captures),
                        assessedVisualRevision: capturedVisual, assessedSceneRevision: capturedScene, assessedPointerEpochs: capturedPointerEpochs, trace: trace)
                    try Task.checkCancellation()
                    guard sessionIsCurrent(sessionID) else { return }
                    let candidates = assessedCandidates.filter { latestRequestByDisplay[$0.id] == sequence }.map { candidate in
                        InterventionCandidate(fingerprint: candidate.fingerprint,
                            screenIndex: (displayOrder.firstIndex(of: candidate.id) ?? candidate.screenIndex - 1) + 1,
                            reason: candidate.reason, context: candidate.context)
                    }
                    let newIDs = Set(candidates.map(\.id)).subtracting(interventions.map(\.id))
                    Diagnostics.event("freshness_finished", trace: trace, details: "eligible_blurs=\(candidates.count)")
                    setInterventions(candidates, trace: trace)
                    interventionRules.remember(candidates, at: currentTime())
                    if !newIDs.isEmpty {
                        recordEvent(kind: "intervention", reason: "A gradual blur was applied to \(newIDs.count) screen(s) after a fresh off-task judgment.")
                    }
                }
                outcome = "completed"
                Diagnostics.event("assessment_completed", trace: trace, details: "status=\(result.status)")
            } catch {
                outcome = Task.isCancelled || error is CancellationError ? "cancelled" : "failed"
                if !Task.isCancelled && !(error is CancellationError) {
                    self.error = error.localizedDescription
                    Diagnostics.failure("Screen check", error, trace: trace)
                    if automatic && sessionIsCurrent(sessionID) {
                        setInterventions([])
                        policy.failed(at: currentTime())
                        recordEvent(kind: "error", trigger: requestTrigger ?? .retry, app: appName,
                                    reason: "Check failed; this is not an off-task judgment. A retry is delayed by at least 30 seconds.")
                        if analysisInFlight {
                            reconnectAfterCheck = true
                            requestClient.stop(reason: "Reconnecting after a failed analysis.")
                            if slot == 1 { secondaryReady = false }
                        }
                    }
                }
            }
            if !automatic { showWindow?() }
        }
        if slot == 0 { checkTask = task } else { secondaryCheckTask = task }
    }

    func probeForViewChange() async {
        guard session?.state == .running, let previous = viewProbeBaseline else { return }
        let id = session?.id
        var files: [URL] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        do {
            let first = try await captureScreens(); files += first.map(\.file)
            guard sessionIsCurrent(id), !Task.isCancelled, viewProbeBaseline == previous else { return }
            let current = first.map(\.fingerprint)
            guard ScreenComparison.changed(current, since: previous) else { return }
            try await freshnessDelay()
            let second = try await captureScreens(); files += second.map(\.file)
            guard sessionIsCurrent(id), !Task.isCancelled, viewProbeBaseline == previous else { return }
            let followup = second.map(\.fingerprint)
            var ignoredScrollIDs: Set<UInt32> = []
            let navigated = previous.filter { baseline in
                guard let first = current.first(where: { $0.displayID == baseline.displayID }),
                      let next = followup.first(where: { $0.displayID == baseline.displayID }),
                      ScreenComparison.substantialSettledChange(previous: [baseline], current: [first], followup: [next]) else { return false }
                if let submitted = submittedViews[baseline.displayID],
                   scrollContinuesView(displayID: baseline.displayID, context: submitted.context, epoch: submitted.pointerEpoch) {
                    ignoredScrollIDs.insert(baseline.displayID)
                    Diagnostics.event("scroll_change_ignored", details: "display=\(baseline.displayID)")
                    return false
                }
                return true
            }
            // Keep ignored pixels pending so an expired scroll hint cannot hide a
            // later unknown view until the background interval.
            viewProbeBaseline = followup.map { frame in
                ignoredScrollIDs.contains(frame.displayID) ? previous.first(where: { $0.displayID == frame.displayID }) ?? frame : frame
            }
            if !navigated.isEmpty {
                contextChanged(.viewChange)
                Diagnostics.record("Settled visual view change queued for priority assessment")
            }
        } catch {
            if !Task.isCancelled && !(error is CancellationError),
               lastProbeFailureAt == nil || currentTime().timeIntervalSince(lastProbeFailureAt!) >= 30 {
                lastProbeFailureAt = currentTime()
                Diagnostics.failure("visual_probe", error)
            }
        }
    }

    private func schedulePriorityInterrupt(force: Bool = false) {
        guard analysisInFlight else { return }
        priorityInterruptTask?.cancel()
        let scheduleID = UUID(); interruptScheduleID = scheduleID
        let task = checkTask
        priorityInterruptTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.interruptScheduleID == scheduleID { self.priorityInterruptTask = nil; self.interruptScheduleID = nil }
            }
            do { try await self.prioritySettleDelay() } catch { return }
            guard !Task.isCancelled, self.interruptScheduleID == scheduleID, self.analysisInFlight, self.session?.state == .running else { return }
            let current = self.pollWindowContexts()
            let allWindowsReplaced = self.inFlightScreenCount > 0 && self.inFlightWindows.count == self.inFlightScreenCount &&
                self.inFlightWindows.allSatisfy { id, old in
                    guard let latest = current[id] else { return false }
                    return old.windowID != latest.windowID || old.processID != latest.processID
                }
            let trace = self.activeAITrace
            guard force || allWindowsReplaced else {
                Diagnostics.event("inference_retained", trace: trace, details: "reason=assessed_window_still_present_or_identity_unknown")
                return
            }
            Diagnostics.event("interrupt_requested", trace: trace)
            let interrupted = await self.client.interruptAnalysis()
            Diagnostics.event("interrupt_finished", trace: trace, details: "accepted=\(interrupted)")
            if interrupted { task?.cancel() }
        }
    }

    func contextChanged(_ trigger: CheckTrigger) {
        if trigger == .viewChange {
            visualRevision += 1
            pendingSceneTrace = Diagnostics.Trace()
            Diagnostics.event("scene_detected", trace: pendingSceneTrace, details: "trigger=\(trigger.rawValue) visual_revision=\(visualRevision)")
        }
        if trigger == .spaceChange || trigger == .appSwitch || trigger == .navigation || trigger == .displayChange {
            sceneRevision += 1
            pendingSceneTrace = Diagnostics.Trace()
            Diagnostics.event("scene_detected", trace: pendingSceneTrace, details: "trigger=\(trigger.rawValue) scene_revision=\(sceneRevision)")
            if secondaryClient == nil { schedulePriorityInterrupt(force: trigger == .displayChange) }
        }
        let contexts = pollWindowContexts()
        for id in Set(inputContexts.keys).union(contexts.keys) where inputContexts[id] != contexts[id] {
            pointerEpochs[id, default: 0] += 1; scrollHints[id] = nil
        }
        inputContexts = contexts
        if interventionRules.invalidateChangedWindows(contexts) { correctionNote = nil }
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
        if secondaryClient != nil, session?.state == .running {
            priorityPending = true
            scheduleParallelCheck()
        }
        if trigger == .spaceChange || trigger == .appSwitch || trigger == .navigation || trigger == .viewChange { scheduleCachedCheck() }
    }

    func returnToWork(displayID: UInt32) {
        guard interventions.contains(where: { $0.id == displayID }), session?.state == .running else { return }
        Diagnostics.event("return_to_work", details: "display=\(displayID) grace_ms=3000")
        returnDeadlines[displayID] = currentTime().addingTimeInterval(3)
        pendingReturns.insert(displayID)
        cachedCheckTask?.cancel()
        setInterventions(interventions.filter { $0.id != displayID }, allowRemoval: true)
        interventionNote = "This screen is clear for 3 seconds. Switch back to your task."
        recordEvent(kind: "returning", reason: "This screen's blur lifted for 3 seconds. Unchanged distractions reblur locally; changed views get a fresh assessment.")
    }

    func markRelevant(displayID: UInt32) {
        guard let candidate = interventions.first(where: { $0.id == displayID }), session?.state == .running else { return }
        Diagnostics.event("relevance_correction", details: "display=\(displayID)")
        let latest = screenshots.first { $0.id == displayID && $0.context == candidate.context }
        interventionRules.approve(latest?.fingerprint ?? candidate.fingerprint, context: latest?.context ?? candidate.context, at: currentTime())
        setInterventions(interventions.filter { $0.id != displayID }, allowRemoval: true)
        correctionNote = "Screen \(candidate.screenIndex) approved for this view for up to 2 minutes."
        recordEvent(kind: "correction", reason: "You marked Screen \(candidate.screenIndex) relevant. This view is exempt from blur for up to 2 minutes, until this screen’s window/tab or content changes.")
    }

    func takeBreak() { requestSessionExit(.pause) }

    private func setInterventions(_ candidates: [InterventionCandidate], allowRemoval: Bool = false, trace: Diagnostics.Trace? = nil) {
        // Interventions latch until an explicit action. Background samples, AI
        // verdicts and errors can add/update a blur, but cannot silently lift it.
        var byDisplay = Dictionary(uniqueKeysWithValues: (allowRemoval ? [] : interventions).map { ($0.id, $0) })
        for candidate in candidates { byDisplay[candidate.id] = candidate }
        let next = byDisplay.values.filter { currentTime() >= returnDeadlines[$0.id, default: .distantPast] }
            .sorted { $0.screenIndex < $1.screenIndex }
        interventionNote = next.isEmpty ? nil : "\(next.count) screen(s) locked. Use Return to work or This is relevant to lift the blur."
        guard next != interventions else { return }
        let added = Set(next.map(\.id)).subtracting(interventions.map(\.id))
        for id in added { Diagnostics.event("blur_requested", trace: trace, details: "display=\(id)") }
        interventions = next
        if !next.isEmpty { correctionNote = nil }
        onInterventionsChanged?(next, trace)
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
                                     capturedContext: Int, assessedContexts: [UInt32: ScreenWindowContext], assessedVisualRevision: Int, assessedSceneRevision: Int, assessedPointerEpochs: [UInt32: Int], trace: Diagnostics.Trace? = nil) async throws -> [InterventionCandidate] {
        guard result.screens.contains(where: { $0.status == "off_task" }) else { return [] }
        guard capturedContext == contextRevision, currentTime().timeIntervalSince(assessedAt) <= 20 else {
            queueSessionCheck(.visualChange)
            let reason = capturedContext != contextRevision ? "The display arrangement changed during analysis." : "The assessment was older than 20 seconds."
            recordEvent(kind: "rechecking", reason: reason + " Blur was withheld and a fresh check queued.")
            Diagnostics.event("blur_withheld", trace: trace, details: "reason=\(capturedContext != contextRevision ? "display_change" : "result_age")")
            interventionNote = reason + " Rechecking before applying a blur."
            return []
        }
        let samples = try await freshSceneSamples(against: assessed)
        let verifyChangedPixels = assessedVisualRevision != visualRevision || assessedSceneRevision != sceneRevision
        let candidates = interventionRules.candidates(verdict: result, assessed: assessed, current: samples.0,
            followup: samples.1, assessedAt: assessedAt, now: currentTime(), contextUnchanged: capturedContext == contextRevision,
            assessedContexts: assessedContexts, currentContexts: samples.2).filter { candidate in
                guard assessedAt >= returnDeadlines[candidate.id, default: .distantPast] else { return false }
                guard verifyChangedPixels else { return true }
                if scrollContinuesView(displayID: candidate.id, context: assessedContexts[candidate.id],
                                       epoch: assessedPointerEpochs[candidate.id, default: 0]),
                   assessedContexts[candidate.id] == samples.2[candidate.id] { return true }
                guard let evidence = assessed.first(where: { $0.displayID == candidate.id }),
                      let current = samples.0.first(where: { $0.displayID == candidate.id }) else { return false }
                return SceneFreshness.matches(evidence, current: current,
                    followup: samples.1.first { $0.displayID == candidate.id })
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
                verifyChangedPixels ? "the visible content changed during analysis" :
                assessedContexts[id] != nil ? "the visible app window changed" : "content changed and no window identity was available"
            withheld.append("Screen \(screen.screenIndex): \(reason)")
        }
        if !withheld.isEmpty {
            let description = withheld.joined(separator: "; ")
            Diagnostics.event("blur_withheld", trace: trace, details: description)
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
        priorityInterruptTask?.cancel(); priorityInterruptTask = nil
        cachedCheckTask?.cancel(); cachedCheckTask = nil
        checkTask?.cancel(); secondaryCheckTask?.cancel()
        priorityPending = false
        if secondaryCheckTask != nil {
            secondaryReady = false
            secondaryClient?.stop(reason: "Screen check interrupted by session controls.")
        }
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
        viewProbeTask?.cancel(); viewProbeTask = nil
        UserDefaults.standard.set(goal, forKey: "goal")
        UserDefaults.standard.set(taskContext, forKey: "taskContext")
        if !selectedModel.isEmpty { UserDefaults.standard.set(selectedModel, forKey: "model") }
        uninstallPointerMonitors()
        Diagnostics.record("App shutting down")
        checkTask?.cancel(); secondaryCheckTask?.cancel(); warmSecondaryTask?.cancel()
        client.stop(); secondaryClient?.stop()
        for file in temporaryImages { try? FileManager.default.removeItem(at: file) }
        temporaryImages = []
        ScreenCapture.cleanupTemporaryCaptures()
        Diagnostics.flush()
    }
}
