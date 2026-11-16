import XCTest
import AppKit
import SwiftUI
import GatekeeperCore
@testable import Gatekeeper

@MainActor final class SessionLifecycleTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!
    private var client: SessionConnection!
    private var clock: SessionClock!
    private var captures = 0
    private var pixel: UInt8 = 100
    private var trackedWindow: ScreenWindowContext?
    private var afterCapture: (() -> Void)?

    override func setUp() async throws {
        Diagnostics.enabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gatekeeper-session-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        client = SessionConnection(); clock = SessionClock()
        model = AppModel(client: client, sessionStore: SessionStore(file: directory.appendingPathComponent("sessions.json")))
        // A clean CI runner has no saved task; never depend on local UserDefaults.
        model.goal = "Write the project documentation"
        model.taskContext = "Review the project and document its behaviour."
        model.runsSessionLoop = false
        model.pollWindowContexts = { [:] }
        model.permissionAvailable = { true }
        model.currentTime = { [clock] in clock!.now }
        model.countdownDelay = {}
        model.freshnessDelay = {}
        model.cacheCheckDelay = {}
        model.prioritySettleDelay = {}
        model.hideForWork = {}
        model.foregroundAppName = { "Test Editor" }
        model.sessionMinutes = 1; model.aiIntervalSeconds = 15
        model.captureScreens = { [unowned self] in
            self.captures += 1
            self.afterCapture?()
            let file = self.directory.appendingPathComponent("image-\(UUID().uuidString).jpg")
            try Data("synthetic image".utf8).write(to: file)
            let fingerprint = ScreenFingerprint(displayID: 1, sourceWidth: 1600, sourceHeight: 900,
                                                pixels: Array(repeating: self.pixel, count: 160 * 90))
            return [CapturedScreen(id: 1, label: "Synthetic screen", image: NSImage(size: NSSize(width: 16, height: 9)), file: file, fingerprint: fingerprint, context: self.trackedWindow)]
        }
        await model.connect()
    }

    override func tearDown() async throws {
        model.shutdown()
        await model.checkTask?.value
        await model.cachedCheckTask?.value
        try? FileManager.default.removeItem(at: directory)
        model = nil; client = nil; clock = nil
    }

    private func start() async {
        model.startSession()
        await model.checkTask?.value
    }

    func testStartChecksOnceThenSkipsUnchangedScreensAndCanDetectLaterChanges() async {
        await start()
        XCTAssertEqual(client.requests, 1)
        XCTAssertEqual(model.session?.state, .running)
        clock.now += 10; model.tickSession()
        XCTAssertEqual(captures, 1) // No wasted captures during the AI cooldown.
        clock.now += 5; model.tickSession(); await model.checkTask?.value
        XCTAssertEqual(client.requests, 1)
        XCTAssertEqual(model.session?.skippedSamples, 1)
        pixel = 200
        clock.now += 5; model.tickSession(); await model.checkTask?.value
        XCTAssertEqual(client.requests, 2)
        XCTAssertEqual(model.session?.aiChecks, 2)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(files.contains { $0.hasSuffix(".jpg") })
    }

    func testPauseStopsCapturesAndFreezesRemainingTimeUntilResume() async {
        await start()
        clock.now += 10; model.pauseSession()
        XCTAssertEqual(model.remainingSeconds, 50)
        let before = captures
        clock.now += 100; model.tickSession()
        XCTAssertEqual(captures, before)
        XCTAssertEqual(model.remainingSeconds, 50)
        model.resumeSession()
        clock.now += 49; model.tickSession(); await model.checkTask?.value
        XCTAssertEqual(model.remainingSeconds, 1)
        clock.now += 1; model.tickSession()
        XCTAssertEqual(model.session?.state, .completed)
    }

    func testTimerExpiryStopsAllFurtherCapturesAndPersistsSummary() async throws {
        await start()
        clock.now += 60; model.tickSession()
        XCTAssertFalse(model.hasActiveSession)
        XCTAssertEqual(model.session?.state, .completed)
        let before = captures
        clock.now += 100; model.tickSession()
        XCTAssertEqual(captures, before)
        let saved = try SessionStore(file: directory.appendingPathComponent("sessions.json")).load()
        XCTAssertEqual(saved.first?.state, .completed)
        XCTAssertEqual(saved.first?.aiChecks, 1)
    }

    func testStopDuringAnalysisDropsLateResultAndRemovesTemporaryImages() async {
        client.holdResult = true
        let started = expectation(description: "Analysis started")
        client.onRequest = { started.fulfill() }
        model.startSession()
        await fulfillment(of: [started], timeout: 2)
        let task = model.checkTask
        clock.now += 20; model.tickSession()
        XCTAssertEqual(client.requests, 1) // No overlap, even after the cooldown expires.
        model.endSession()
        await task?.value
        XCTAssertNil(model.verdict)
        XCTAssertEqual(model.session?.state, .ended)
        XCTAssertFalse(model.session?.events.contains { $0.kind == "on_task" } ?? true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(files.contains { $0.hasSuffix(".jpg") })
    }

    func testFailureIsLoggedAsErrorAndRetryIsBounded() async {
        client.fail = true
        await start()
        XCTAssertTrue(model.session?.events.contains { $0.kind == "error" } ?? false)
        XCTAssertFalse(model.session?.events.contains { $0.kind == "off_task" } ?? true)
        client.fail = false
        await model.connect()
        clock.now += 15; model.tickSession()
        XCTAssertEqual(client.requests, 1)
        clock.now += 16; model.tickSession(); await model.checkTask?.value
        XCTAssertEqual(client.requests, 2)
        XCTAssertEqual(model.verdict?.status, "on_task")
    }

    func testReopenedAppDoesNotRestartAnInterruptedSession() async {
        await start()
        let other = AppModel(client: SessionConnection(), sessionStore: SessionStore(file: directory.appendingPathComponent("sessions.json")))
        defer { other.shutdown() }
        XCTAssertFalse(other.hasActiveSession)
        XCTAssertNil(other.checkTask)
        XCTAssertEqual(other.history.first?.state, .interrupted)
    }

    func testOffTaskOverlayAppearsAndRelevantCorrectionIsRecorded() async {
        client.reply = offTask()
        await start()
        XCTAssertEqual(model.interventions.map(\.id), [1])
        model.markRelevant(displayID: 1)
        XCTAssertTrue(model.interventions.isEmpty)
        XCTAssertTrue(model.session?.events.contains { $0.kind == "correction" } ?? false)
        clock.now += 15; model.queueSessionCheck(.manual); model.tickSession(); await model.checkTask?.value
        XCTAssertTrue(model.interventions.isEmpty)
    }

    func testBreakPauseAndExpiryRemoveOverlaysImmediately() async {
        client.reply = offTask()
        await start()
        XCTAssertFalse(model.interventions.isEmpty)
        model.onSessionExitRequested = { _, resolve in resolve(true) }
        model.takeBreak()
        XCTAssertTrue(model.interventions.isEmpty)
        XCTAssertEqual(model.session?.state, .paused)
        clock.now += 15; model.resumeSession(); model.tickSession(); await model.checkTask?.value
        XCTAssertFalse(model.interventions.isEmpty)
        clock.now += 60; model.tickSession()
        XCTAssertTrue(model.interventions.isEmpty)
        XCTAssertEqual(model.session?.state, .completed)
    }

    func testChangedPageAndDisplayEventsCannotUnlatchAnExistingBlur() async {
        client.reply = offTask()
        await start()
        XCTAssertFalse(model.interventions.isEmpty)
        pixel = 200
        clock.now += 2; model.tickSession(); await model.checkTask?.value
        XCTAssertFalse(model.interventions.isEmpty)
        XCTAssertEqual(client.requests, 1) // Respect the gap even when checking overlay freshness.
        clock.now += 15; model.tickSession(); await model.checkTask?.value
        XCTAssertFalse(model.interventions.isEmpty)
        model.contextChanged(.appSwitch)
        XCTAssertFalse(model.interventions.isEmpty)
        model.contextChanged(.displayChange)
        XCTAssertFalse(model.interventions.isEmpty)
    }

    func testAppSwitchToChangedContentWithholdsBlurAndQueuesNewView() async {
        client.reply = offTask()
        client.beforeReply = { [unowned self] in
            self.pixel = 200
            self.model.contextChanged(.appSwitch)
        }
        await start()
        XCTAssertTrue(model.interventions.isEmpty)
        XCTAssertEqual(model.policy.pendingTrigger, .appSwitch)
    }

    func testSessionStartKeepsWindowOpenWhileOneOffCheckStillHidesIt() async {
        var hides = 0
        model.hideForWork = { hides += 1 }
        await start()
        XCTAssertEqual(hides, 0)
        model.endSession()
        model.check(); await model.checkTask?.value
        XCTAssertEqual(hides, 1)
    }

    func testSceneChangedDuringModelCallDoesNotReceiveAStaleBlur() async {
        client.reply = offTask()
        client.beforeReply = { [unowned self] in self.pixel = 200 }
        await start()
        XCTAssertTrue(model.interventions.isEmpty)
        XCTAssertEqual(model.policy.pendingTrigger, .visualChange)
        XCTAssertTrue(model.session?.events.contains { $0.reason.contains("content changed and no window identity was available") } ?? false)
    }

    func testReturnToWorkQueuesWithinRateLimitAndClearsOnFreshRelevantVerdict() async {
        client.reply = offTask()
        await start()
        model.returnToWork(displayID: 1)
        XCTAssertTrue(model.interventions.isEmpty)
        XCTAssertEqual(client.requests, 1)
        XCTAssertNil(model.policy.pendingTrigger) // Recheck is queued when navigation time expires.
        client.reply = Verdict(status: "on_task", reason: "Relevant", nextStep: "Continue",
            screens: [ScreenVerdict(screenIndex: 1, status: "on_task", reason: "Relevant")])
        clock.now += 2; model.tickSession()
        XCTAssertEqual(client.requests, 1)
        clock.now += 1; model.tickSession(); await model.checkTask?.value
        XCTAssertTrue(model.interventions.isEmpty)
        XCTAssertEqual(model.verdict?.status, "on_task")
    }

    func testReturnGraceCannotRecallCachedBlurAndReblursIfStillOffTask() async {
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77)
        client.reply = offTask()
        await start()
        model.returnToWork(displayID: 1)
        model.contextChanged(.appSwitch); await model.cachedCheckTask?.value
        clock.now += 2; model.tickSession()
        XCTAssertTrue(model.interventions.isEmpty)
        XCTAssertEqual(client.requests, 1)
        clock.now += 1; model.tickSession(); await model.checkTask?.value
        XCTAssertEqual(client.requests, 2)
        XCTAssertEqual(model.interventions.count, 1)
    }

    func testReturnOnlyLiftsClickedScreenAndRestoresFromCacheBeforeAIReply() async {
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77)
        let originalCapture = model.captureScreens
        model.captureScreens = {
            let first = try await originalCapture()[0]
            let second = CapturedScreen(id: 2, label: "Screen 2", image: first.image, file: first.file,
                fingerprint: ScreenFingerprint(displayID: 2, sourceWidth: 1600, sourceHeight: 900,
                    pixels: first.fingerprint.pixels), context: first.context)
            return [first, second]
        }
        client.reply = Verdict(status: "off_task", reason: "Feeds", nextStep: "Return",
            screens: [ScreenVerdict(screenIndex: 1, status: "off_task", reason: "Feed"),
                      ScreenVerdict(screenIndex: 2, status: "off_task", reason: "Feed")])
        await start()
        model.returnToWork(displayID: 1)
        XCTAssertEqual(model.interventions.map(\.id), [2])
        client.holdResult = true
        clock.now += 3; model.tickSession()
        await model.cachedCheckTask?.value
        XCTAssertEqual(Set(model.interventions.map(\.id)), [1, 2])
        model.pauseSession()
    }

    func testScrollingInsideTheSameWindowDoesNotVetoBlur() async {
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77)
        client.reply = offTask()
        client.beforeReply = { [unowned self] in self.pixel = 200 }
        await start()
        XCTAssertEqual(model.interventions.count, 1)
    }

    func testSwitchingToADifferentWindowStillRejectsAStaleVerdict() async {
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77)
        client.reply = offTask()
        client.beforeReply = { [unowned self] in self.trackedWindow = ScreenWindowContext(windowID: 11, processID: 88) }
        await start()
        XCTAssertTrue(model.interventions.isEmpty)
    }

    func testNewTabCannotUnlatchAnExistingBlur() async {
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77, navigationToken: 1)
        client.reply = offTask()
        await start()
        XCTAssertEqual(model.interventions.count, 1)
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77, navigationToken: 2)
        model.contextChanged(.navigation); await model.cachedCheckTask?.value
        XCTAssertEqual(model.interventions.count, 1)
        XCTAssertEqual(client.requests, 1)
        clock.now += 3
        client.beforeReply = { [unowned self] in
            self.trackedWindow = ScreenWindowContext(windowID: 10, processID: 77, navigationToken: 3)
        }
        model.tickSession(); await model.checkTask?.value
        XCTAssertEqual(client.requests, 2)
        XCTAssertEqual(model.interventions.count, 1)
    }

    func testReturningToKnownOffTaskViewBlursFromCacheWithoutAnAIRequest() async {
        var entries: [String] = []
        Diagnostics.onRecord = { entries.append($0) }
        defer { Diagnostics.onRecord = nil }
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77)
        client.reply = offTask()
        await start()
        XCTAssertEqual(client.requests, 1)
        model.returnToWork(displayID: 1)
        trackedWindow = ScreenWindowContext(windowID: 20, processID: 88); pixel = 200
        model.contextChanged(.appSwitch); await model.cachedCheckTask?.value
        XCTAssertTrue(model.interventions.isEmpty)
        clock.now += 3
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77); pixel = 100
        model.contextChanged(.appSwitch); await model.cachedCheckTask?.value
        XCTAssertTrue(entries.contains { $0.contains("event=cache_lookup_finished") && $0.contains("hits=0") })
        let hit = entries.last { $0.contains("event=cache_lookup_finished") && $0.contains("hits=1") }
        XCTAssertNotNil(hit)
        let hitTrace = hit?.split(separator: " ").first { $0.hasPrefix("trace=") }.map(String.init)
        XCTAssertNotNil(hitTrace)
        XCTAssertTrue(entries.contains { $0.contains("event=blur_requested") && $0.contains(hitTrace ?? "missing") })
        XCTAssertEqual(model.interventions.count, 1)
        XCTAssertEqual(client.requests, 1)
    }

    func testUserExitRequiresApprovalWhileMonitoringContinues() async {
        client.reply = offTask()
        await start()
        var resolve: ((Bool) -> Void)?
        model.onSessionExitRequested = { _, callback in resolve = callback }
        model.requestSessionExit(.pause)
        XCTAssertEqual(model.session?.state, .running)
        XCTAssertFalse(model.interventions.isEmpty)
        clock.now += 1; model.tickSession()
        XCTAssertEqual(model.remainingSeconds, 59)
        resolve?(false)
        XCTAssertEqual(model.session?.state, .running)
        model.requestSessionExit(.pause)
        resolve?(true)
        XCTAssertEqual(model.session?.state, .paused)
        XCTAssertTrue(model.interventions.isEmpty)
    }

    func testEndQuitAndNewTaskCannotUseAnUnconfirmedRequest() async {
        await start()
        var resolve: ((Bool) -> Void)?
        model.onSessionExitRequested = { _, callback in resolve = callback }
        var quit = false
        model.requestSessionExit(.quit) { quit = true }
        XCTAssertFalse(quit)
        resolve?(false)
        XCTAssertFalse(quit)
        model.requestSessionExit(.end)
        XCTAssertEqual(model.session?.state, .running)
        resolve?(true)
        XCTAssertEqual(model.session?.state, .ended)
        await start()
        let oldGoal = model.goal
        var openedEditor = false
        model.requestSessionExit(.newTask) { openedEditor = true }
        XCTAssertEqual(model.goal, oldGoal)
        XCTAssertFalse(openedEditor)
        resolve?(true)
        XCTAssertTrue(openedEditor)
        XCTAssertFalse(model.hasActiveSession)
        XCTAssertTrue(model.goal.isEmpty)
        model.goal = oldGoal
    }

    func testExpiredSessionCannotBeChangedByOldHoldConfirmation() async {
        await start()
        var resolve: ((Bool) -> Void)?
        model.onSessionExitRequested = { _, callback in resolve = callback }
        var quit = false
        model.requestSessionExit(.quit) { quit = true }
        clock.now += 60; model.tickSession()
        XCTAssertEqual(model.session?.state, .completed)
        resolve?(true)
        XCTAssertFalse(quit)
        XCTAssertEqual(model.session?.state, .completed)
    }

    func testRefreshKeepsLastCompletedVerdictImagesAndDateUntilNewResult() async {
        await start()
        let previousReason = model.verdict?.reason
        let previousImage = model.screenshots.first?.file
        let previousDate = model.lastCheck
        func cardHeight() -> CGFloat {
            let host = NSHostingView(rootView: ContentView(model: model).captureCard.frame(width: 700))
            return host.fittingSize.height
        }
        let previousHeight = cardHeight()
        client.holdResult = true
        let requested = expectation(description: "Refresh running")
        client.onRequest = { requested.fulfill() }
        clock.now += 3
        model.check()
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertTrue(model.analysisInFlight)
        XCTAssertEqual(cardHeight(), previousHeight, accuracy: 1)
        XCTAssertEqual(model.verdict?.reason, previousReason)
        XCTAssertEqual(model.screenshots.first?.file, previousImage)
        XCTAssertEqual(model.lastCheck, previousDate)
        model.pauseSession()
        await model.checkTask?.value
        XCTAssertFalse(model.analysisInFlight)
        XCTAssertEqual(model.verdict?.reason, previousReason)
    }

    func testFailedRefreshPreservesCompletedAssessment() async {
        await start()
        let previousDate = model.lastCheck
        let previousReason = model.verdict?.reason
        client.fail = true
        clock.now += 3; model.check(); await model.checkTask?.value
        XCTAssertTrue(model.session?.events.contains { $0.kind == "error" } ?? false)
        XCTAssertEqual(model.lastCheck, previousDate)
        XCTAssertEqual(model.verdict?.reason, previousReason)
    }

    func testFreshOnTaskVerdictAndErrorsCannotUnlatchBlur() async {
        client.reply = offTask()
        await start()
        client.reply = Verdict(status: "on_task", reason: "Relevant", nextStep: "Continue",
            screens: [ScreenVerdict(screenIndex: 1, status: "on_task", reason: "Relevant")])
        clock.now += 3; model.check(); await model.checkTask?.value
        XCTAssertEqual(model.verdict?.status, "on_task")
        XCTAssertEqual(model.interventions.count, 1)
        client.fail = true
        clock.now += 3; model.check(); await model.checkTask?.value
        XCTAssertEqual(model.interventions.count, 1)
        model.returnToWork(displayID: 1)
        XCTAssertTrue(model.interventions.isEmpty)
    }

    func testCorrectionSurvivesAppSwitchOnAnotherMonitor() async {
        let approved = ScreenWindowContext(windowID: 10, processID: 77, navigationToken: 1)
        trackedWindow = approved
        model.pollWindowContexts = { [1: approved, 2: ScreenWindowContext(windowID: 20, processID: 88)] }
        client.reply = offTask()
        await start()
        model.markRelevant(displayID: 1)
        model.pollWindowContexts = { [1: approved, 2: ScreenWindowContext(windowID: 21, processID: 99)] }
        model.contextChanged(.appSwitch)
        await model.cachedCheckTask?.value
        XCTAssertTrue(model.interventions.isEmpty)
        clock.now += 4; model.tickSession()
        clock.now += 1; model.tickSession(); await model.checkTask?.value
        XCTAssertEqual(client.requests, 2)
        XCTAssertTrue(model.interventions.isEmpty)
        trackedWindow = ScreenWindowContext(windowID: 30, processID: 66, navigationToken: 2)
        model.pollWindowContexts = { [1: ScreenWindowContext(windowID: 30, processID: 66, navigationToken: 2)] }
        model.contextChanged(.navigation)
        clock.now += 4; model.tickSession()
        clock.now += 1; model.tickSession(); await model.checkTask?.value
        XCTAssertEqual(model.interventions.count, 1)
    }

    func testChangedThreadWithoutTitleChangeGetsPriorityBeforeBackgroundGap() async {
        await start()
        pixel = 200
        await model.probeForViewChange()
        XCTAssertEqual(model.policy.pendingTrigger, .viewChange)
        client.reply = offTask()
        clock.now += 3; model.tickSession(); await model.checkTask?.value
        XCTAssertEqual(client.requests, 2)
        XCTAssertEqual(model.interventions.count, 1)
    }

    func testSupersededInferenceIsInterruptedWithoutRestartingConnection() async {
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77)
        client.holdResult = true; client.supportsInterrupt = true
        let started = expectation(description: "Old analysis running")
        client.onRequest = { started.fulfill() }
        model.startSession()
        await fulfillment(of: [started], timeout: 2)
        let oldTask = model.checkTask
        client.onRequest = nil
        trackedWindow = ScreenWindowContext(windowID: 20, processID: 88)
        model.pollWindowContexts = { [1: ScreenWindowContext(windowID: 20, processID: 88)] }
        model.contextChanged(.navigation)
        await model.priorityInterruptTask?.value
        await oldTask?.value
        XCTAssertEqual(client.interrupts, 1)
        XCTAssertEqual(client.stops, 0)
        XCTAssertNil(model.verdict)
        XCTAssertNil(model.error)
        client.holdResult = false; client.reply = offTask(); pixel = 200
        clock.now += 3; model.tickSession()
        clock.now += 1; model.tickSession(); await model.checkTask?.value
        XCTAssertEqual(client.requests, 2)
        XCTAssertEqual(model.interventions.count, 1)
    }

    func testRepeatedTitleChangesKeepFirstInferenceAndPermitUnchangedOffTaskContent() async {
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77, navigationToken: 1)
        client.holdResult = true; client.supportsInterrupt = true; client.reply = offTask()
        let started = expectation(description: "First inference")
        client.onRequest = { started.fulfill() }
        model.startSession(); await fulfillment(of: [started], timeout: 2)
        for token in 2...12 {
            trackedWindow = ScreenWindowContext(windowID: 10, processID: 77, navigationToken: token)
            model.pollWindowContexts = { [unowned self] in [1: self.trackedWindow!] }
            model.contextChanged(.navigation)
            await model.priorityInterruptTask?.value
        }
        XCTAssertEqual(client.interrupts, 0)
        client.completeHeldReply(); await model.checkTask?.value
        XCTAssertEqual(client.requests, 1)
        XCTAssertEqual(model.verdict?.status, "off_task")
        XCTAssertEqual(model.interventions.map(\.id), [1])
    }

    func testChangedTabInSameWindowCannotReceiveOldBlur() async {
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77, navigationToken: 1)
        client.reply = offTask()
        client.beforeReply = { [unowned self] in
            self.trackedWindow = ScreenWindowContext(windowID: 10, processID: 77, navigationToken: 2)
            self.pixel = 200
            self.model.contextChanged(.navigation)
        }
        await start()
        XCTAssertTrue(model.interventions.isEmpty)
        XCTAssertNotNil(model.verdict)
        XCTAssertEqual(model.policy.pendingTrigger, .navigation)
    }

    func testNavigationOnOtherMonitorPreservesUsableFirstResultPerScreen() async {
        var contexts: [UInt32: ScreenWindowContext] = [
            1: ScreenWindowContext(windowID: 10, processID: 77),
            2: ScreenWindowContext(windowID: 20, processID: 88)]
        model.pollWindowContexts = { contexts }
        model.captureScreens = { [unowned self] in
            try [UInt32(1), UInt32(2)].map { id in
                let file = self.directory.appendingPathComponent("synthetic-\(UUID().uuidString).jpg")
                try Data("synthetic".utf8).write(to: file)
                let value: UInt8 = id == 2 && contexts[id]?.windowID == 30 ? 200 : 100
                let fingerprint = ScreenFingerprint(displayID: id, sourceWidth: 1600, sourceHeight: 900,
                    pixels: Array(repeating: value, count: 160 * 90))
                return CapturedScreen(id: id, label: "Synthetic", image: NSImage(size: NSSize(width: 16, height: 9)),
                    file: file, fingerprint: fingerprint, context: contexts[id])
            }
        }
        client.supportsInterrupt = true
        client.reply = Verdict(status: "off_task", reason: "Synthetic", nextStep: "Return",
            screens: [ScreenVerdict(screenIndex: 1, status: "off_task", reason: "Synthetic feed"),
                      ScreenVerdict(screenIndex: 2, status: "off_task", reason: "Synthetic feed")])
        client.beforeReply = { [unowned self] in
            contexts[2] = ScreenWindowContext(windowID: 30, processID: 99)
            self.model.contextChanged(.appSwitch)
        }
        await start()
        await model.priorityInterruptTask?.value
        XCTAssertEqual(client.requests, 1)
        XCTAssertEqual(client.interrupts, 0)
        XCTAssertEqual(model.interventions.map(\.id), [1])
        XCTAssertEqual(model.policy.pendingTrigger, .appSwitch)
    }

    func testSessionStartHasNoCountdownButOneOffStillDoes() async {
        var waits = 0
        model.countdownDelay = { waits += 1 }
        await start()
        XCTAssertEqual(waits, 0)
        model.endSession()
        model.check(); await model.checkTask?.value
        XCTAssertEqual(waits, 3)
    }

    func testPixelOnlyChangesDoNotRestartInferenceOrBlurChangedContent() async {
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77)
        client.holdResult = true; client.supportsInterrupt = true; client.reply = offTask()
        let started = expectation(description: "First check running")
        client.onRequest = { started.fulfill() }
        model.startSession()
        await fulfillment(of: [started], timeout: 2)
        client.onRequest = nil
        pixel = 200
        await model.probeForViewChange()
        XCTAssertEqual(model.policy.pendingTrigger, .viewChange)
        XCTAssertNil(model.priorityInterruptTask)
        XCTAssertEqual(client.interrupts, 0)
        client.completeHeldReply()
        await model.checkTask?.value
        XCTAssertEqual(client.requests, 1)
        XCTAssertTrue(model.interventions.isEmpty)
        XCTAssertNotNil(model.verdict) // Retained as a completed historical assessment.
        client.holdResult = false
        clock.now += 3; model.tickSession(); await model.checkTask?.value
        XCTAssertEqual(client.requests, 2)
        XCTAssertEqual(model.interventions.count, 1)
    }

    func testDesktopChangeRecallsKnownViewPastOldTwoMinuteCacheWithoutAI() async {
        model.sessionMinutes = 10
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77)
        client.reply = offTask()
        await start()
        model.returnToWork(displayID: 1)
        clock.now += 150
        model.contextChanged(.spaceChange)
        await model.cachedCheckTask?.value
        XCTAssertEqual(model.interventions.count, 1)
        XCTAssertEqual(client.requests, 1)
        XCTAssertEqual(model.policy.pendingTrigger, .spaceChange)
    }

    func testSpaceAndWindowNotificationBurstOnlyInterruptsOnce() async {
        trackedWindow = ScreenWindowContext(windowID: 10, processID: 77)
        client.holdResult = true; client.supportsInterrupt = true
        let started = expectation(description: "Inference running")
        client.onRequest = { started.fulfill() }
        model.startSession(); await fulfillment(of: [started], timeout: 2)
        let old = model.checkTask
        trackedWindow = ScreenWindowContext(windowID: 20, processID: 88)
        model.pollWindowContexts = { [1: ScreenWindowContext(windowID: 20, processID: 88)] }
        model.contextChanged(.appSwitch)
        model.contextChanged(.navigation)
        model.contextChanged(.spaceChange)
        await model.priorityInterruptTask?.value
        await old?.value
        XCTAssertEqual(client.interrupts, 1)
        XCTAssertEqual(model.policy.pendingTrigger, .spaceChange)
        XCTAssertNil(model.error)
    }

    func testNativeSpaceNotificationQueuesPriorityWork() async {
        await start()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        for _ in 0..<30 {
            if model.policy.pendingTrigger == .spaceChange { break }
            await Task.yield()
        }
        XCTAssertEqual(model.policy.pendingTrigger, .spaceChange)
        XCTAssertEqual(client.requests, 1)
    }

    func testDiagnosticsConnectSessionCaptureAssessmentAndBlurWithoutTaskText() async throws {
        var entries: [String] = []
        Diagnostics.onRecord = { entries.append($0) }
        defer { Diagnostics.onRecord = nil }
        client.reply = offTask()
        await start()
        let phases = ["session_started", "capture_started", "capture_finished", "ai_started",
                      "ai_reply_received", "freshness_started", "freshness_finished", "blur_requested",
                      "assessment_completed", "check_finished"]
        var traceIDs: Set<String> = []
        for phase in phases {
            let row = try XCTUnwrap(entries.first { $0.hasPrefix("event=\(phase) ") }, phase)
            let trace = try XCTUnwrap(row.split(separator: " ").first { $0.hasPrefix("trace=") }, phase)
            traceIDs.insert(String(trace))
            XCTAssertTrue(row.contains("elapsed_ms="), phase)
        }
        XCTAssertEqual(traceIDs.count, 1)
        let log = entries.joined(separator: "\n")
        XCTAssertFalse(log.contains(model.goal))
        XCTAssertFalse(log.contains(model.taskContext))
        XCTAssertFalse(log.contains("Unrelated feed"))
        XCTAssertFalse(log.contains("Test Editor"))
    }

    private func offTask() -> Verdict {
        Verdict(status: "off_task", reason: "Unrelated feed", nextStep: "Return to work",
                screens: [ScreenVerdict(screenIndex: 1, status: "off_task", reason: "Unrelated feed")])
    }

    func testQuitDuringAnalysisCleansFilesImmediatelyAndSavesInterruptedSession() async throws {
        client.holdResult = true
        let started = expectation(description: "Analysis started")
        client.onRequest = { started.fulfill() }
        model.startSession()
        await fulfillment(of: [started], timeout: 2)
        let pending = model.checkTask
        model.shutdown()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".jpg") })
        let saved = try SessionStore(file: directory.appendingPathComponent("sessions.json")).load()
        XCTAssertEqual(saved.first?.state, .interrupted)
        await pending?.value
        XCTAssertNil(model.verdict)
    }
}

@MainActor private final class SessionClock {
    var now = Date(timeIntervalSince1970: 1000)
}

@MainActor private final class SessionConnection: GatekeeperConnection {
    var onLoginCompleted: ((Bool, String?) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var accountEmail: String? { nil }
    var requests = 0
    var fail = false
    var reply: Verdict?
    var beforeReply: (() -> Void)?
    var holdResult = false
    var supportsInterrupt = false
    var interrupts = 0
    var stops = 0
    var onRequest: (() -> Void)?
    private var held: CheckedContinuation<Verdict, Error>?
    func connect() async throws {}
    func account() async throws -> String? { "ChatGPT Test" }
    func models() async throws -> [CodexModel] { [CodexModel(id: "test", name: "Test", isDefault: true)] }
    func signIn() async throws -> URL { URL(string: "https://example.invalid")! }
    func cancelSignIn() async {}
    func analyse(goal: String, images: [URL], model: String) async throws -> Verdict {
        requests += 1
        XCTAssertFalse(images.isEmpty)
        XCTAssertTrue(images.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        onRequest?()
        if fail { throw GatekeeperError("Synthetic connection failure") }
        if holdResult { return try await withCheckedThrowingContinuation { held = $0 } }
        beforeReply?()
        return try result()
    }
    private func result() throws -> Verdict {
        if let reply { return reply }
        return try Verdict.decode("{\"status\":\"on_task\",\"reason\":\"Synthetic work\",\"nextStep\":\"Continue\"}")
    }
    func completeHeldReply() {
        let continuation = held; held = nil
        continuation?.resume(with: Result { try result() })
    }
    func interruptAnalysis() async -> Bool {
        guard supportsInterrupt, let continuation = held else { return false }
        interrupts += 1; held = nil
        continuation.resume(throwing: CancellationError())
        return true
    }
    func stop(reason: String) {
        stops += 1
        let continuation = held; held = nil
        continuation?.resume(with: Result { try result() }) // Simulate a late success after stopping.
    }
}
