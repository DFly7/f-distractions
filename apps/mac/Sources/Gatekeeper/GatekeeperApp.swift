import SwiftUI
import Combine
import GatekeeperCore

@main struct GatekeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = AppModel()
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var statusSubscription: AnyCancellable?
    private let overlays = FocusOverlayController()
    private let exitController = SessionExitController()
    private var quitApproved = false
    private var previewTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "F Distractions"
        window.minSize = NSSize(width: 900, height: 680)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center()
        model.showWindow = { [weak self] in self?.show() }
        model.onInterventionsChanged = { [weak self] candidates in
            guard let self else { return }
            self.overlays.update(candidates, goal: self.model.session?.goal ?? self.model.goal)
            if NSApp.isActive {
                self.window.level = candidates.isEmpty ? .normal : NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
            }
        }
        model.onSessionExitRequested = { [weak self] action, resolve in
            guard let self else { resolve(false); return }
            self.show()
            self.exitController.present(action: action, goal: self.model.session?.goal ?? self.model.goal,
                parent: self.window, completion: resolve)
        }
        model.previewBlur = { [weak self] in self?.runOverlaySmokeTest() }
        overlays.onReturn = { [weak self] id in
            self?.overlays.animateOut(displayID: id)
            self?.model.returnToWork(displayID: id)
        }
        overlays.onRelevant = { [weak self] id in self?.model.markRelevant(displayID: id) }
        overlays.onBreak = { [weak self] in self?.model.takeBreak(); self?.show() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menuMark = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let letter = "F" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .heavy),
                .foregroundColor: NSColor.black
            ]
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2), withAttributes: attributes)
            return true
        }
        menuMark.isTemplate = true
        menuMark.accessibilityDescription = "F Distractions"
        statusItem.button?.image = menuMark
        let menu = NSMenu()
        menu.addItem(withTitle: "Open F Distractions", action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: "Check my screens", action: #selector(check), keyEquivalent: "")
        menu.addItem(withTitle: "Pause session", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(withTitle: "End session", action: #selector(endSession), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit F Distractions", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        statusSubscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateStatus() }
        }
        show()
        Task { await model.connect() }
        if CommandLine.arguments.contains("--design-snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let card = FocusOverlayCard(goal: "Finish the first draft of my assignment.",
                    reason: "The open AI conversation is planning a holiday, which is unrelated to your chatbot coursework.", screenIndex: 1,
                    onReturn: {}, onRelevant: {}, onBreak: {})
                let renderer = ImageRenderer(content: card.frame(width: 600, height: 430))
                renderer.scale = 2
                if let image = renderer.cgImage {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/fdistractions-card.png"))
                }
                let loading = ImageRenderer(content: TaskRefinementStatus(onCancel: {})
                    .padding(20).frame(width: 550).background(FocusBrand.canvas).preferredColorScheme(.light))
                loading.scale = 2
                if let image = loading.cgImage {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/fdistractions-loading.png"))
                }
                for (name, view) in [
                    ("settings", AnyView(ContentView(model: self.model, initialSection: .settings, showModelChoices: true))),
                    ("history", AnyView(SessionTimelineView(model: self.model, showHistory: true)
                        .padding(24).frame(width: 740, height: 740, alignment: .top)
                        .background(FocusBrand.canvas).buttonStyle(FocusButtonStyle())))
                ] {
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: name == "settings" ? 980 : 740, height: 740)
                    host.layoutSubtreeIfNeeded()
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/fdistractions-\(name).png"))
                    }
                }
                if let view = self.window.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/fdistractions-main.png"))
                }
            }
        }
        if CommandLine.arguments.contains("--exit-hold-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.exitController.present(action: .end, goal: "Finish the first draft of my assignment.", parent: self.window) { _ in }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if let view = self.window.attachedSheet?.contentView,
                       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/fdistractions-hold.png"))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.exitController.dismiss() }
            }
        }
        if CommandLine.arguments.contains("--overlay-smoke-test") { runOverlaySmokeTest() }
        if CommandLine.arguments.contains("--capture-context-test") {
            Task {
                do {
                    let captures = try await ScreenCapture.captureAll()
                    defer { for capture in captures { try? FileManager.default.removeItem(at: capture.file) } }
                    Diagnostics.record("Capture context self-test: screens=\(captures.count) identified_windows=\(captures.filter { $0.context != nil }.count)")
                } catch { Diagnostics.failure("Capture context self-test", error) }
            }
        }
    }

    @objc func show() {
        window.level = model.interventions.isEmpty ? .normal : NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func applicationDidResignActive(_ notification: Notification) { window.level = .normal }
    private func runOverlaySmokeTest() {
        guard let screen = window.screen ?? NSScreen.screens.first,
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return }
        previewTask?.cancel()
        previewTask = Task {
            window.level = .normal
            let fingerprint = ScreenFingerprint(displayID: id, sourceWidth: 1600, sourceHeight: 900,
                                                pixels: Array(repeating: 100, count: 160 * 90))
            overlays.update([InterventionCandidate(fingerprint: fingerprint, screenIndex: 1, reason: "Native overlay test. This clears automatically.")],
                            goal: "Blur preview · clears in 3 seconds", fadeDuration: CommandLine.arguments.contains("--overlay-smoke-test") ? 1.4 : 0.35)
            let visible = overlays.visiblePanelCount
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            overlays.update(model.interventions, goal: model.session?.goal ?? model.goal)
            if NSApp.isActive {
                window.level = model.interventions.isEmpty ? .normal : NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
            }
            Diagnostics.record("Native overlay smoke test: shown=\(visible) remaining=\(overlays.visiblePanelCount)")
        }
    }
    @objc func check() { model.check() }
    @objc func togglePause() {
        if model.session?.state == .paused { model.resumeSession() } else { model.requestSessionExit(.pause) }
    }
    @objc func endSession() { model.requestSessionExit(.end) }
    private func updateStatus() {
        guard model.hasActiveSession else {
            if !CommandLine.arguments.contains("--exit-hold-preview") { exitController.dismiss() }
            statusItem.button?.title = ""; return
        }
        let prefix = model.session?.state == .paused ? "Ⅱ " : ""
        statusItem.button?.title = prefix + String(format: "%02d:%02d", model.remainingSeconds / 60, model.remainingSeconds % 60)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePause) {
            menuItem.title = model.session?.state == .paused ? "Resume session" : "Pause session"
            return model.hasActiveSession && (model.session?.state != .paused || (!model.checking && !model.connecting && model.account != nil))
        }
        if menuItem.action == #selector(endSession) { return model.hasActiveSession }
        if menuItem.action == #selector(check) { return model.canCheck }
        return true
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasActiveSession, !quitApproved else { return .terminateNow }
        model.requestSessionExit(.quit) { [weak self] in
            self?.quitApproved = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { previewTask?.cancel(); overlays.hideAll(); model.shutdown() }
}
