import SwiftUI
import AppKit

/// Only user-initiated interruptions use this gate; timer expiry and sleep remain automatic.
enum SessionExitAction {
    case pause, end, newTask, quit
    var title: String {
        switch self {
        case .pause: return "Pause this session?"
        case .end: return "End this session early?"
        case .newTask: return "Leave this task?"
        case .quit: return "Quit during your session?"
        }
    }
    var verb: String {
        switch self { case .pause: return "pause"; case .end: return "end session"; case .newTask: return "start a new task"; case .quit: return "quit" }
    }
}

/// Monotonic time makes clock changes irrelevant. Release and loss of focus reset all progress.
struct ContinuousHold {
    private(set) var startedAt: TimeInterval?
    let duration: TimeInterval = 10
    mutating func begin(at time: TimeInterval) { if startedAt == nil { startedAt = time } }
    mutating func reset() { startedAt = nil }
    func progress(at time: TimeInterval) -> Double {
        guard let startedAt else { return 0 }
        return min(1, max(0, (time - startedAt) / duration))
    }
    mutating func complete(at time: TimeInterval) -> Bool {
        guard progress(at: time) >= 1 else { return false }
        reset(); return true
    }
}

@MainActor final class SessionExitController {
    private var panel: NSPanel?
    private var resolution: ((Bool) -> Void)?
    func present(action: SessionExitAction, goal: String, parent: NSWindow, completion: @escaping (Bool) -> Void) {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true; panel.titleVisibility = .hidden
        panel.contentView = NSHostingView(rootView: SessionExitView(action: action, goal: goal,
            onCancel: { [weak self] in self?.dismiss(confirmed: false) },
            onComplete: { [weak self] in self?.dismiss(confirmed: true) }))
        self.panel = panel; resolution = completion
        parent.beginSheet(panel)
    }
    func dismiss(confirmed: Bool = false) {
        guard let panel else { return }
        self.panel = nil
        panel.sheetParent?.endSheet(panel)
        panel.close()
        let completion = resolution; resolution = nil
        completion?(confirmed)
    }
}

private struct SessionExitView: View {
    let action: SessionExitAction
    let goal: String
    let onCancel: () -> Void
    let onComplete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(action.title).font(.system(size: 24, weight: .semibold)).tracking(-0.5)
            Text(goal).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
            Text("Hold for 10 seconds to \(action.verb). Releasing resets the hold. Your session keeps running until you finish.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HoldControl(verb: action.verb, onComplete: onComplete).frame(height: 46)
            HStack {
                Spacer()
                Button("Keep focusing", action: onCancel).buttonStyle(FocusButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }.padding(28).frame(width: 500, height: 350)
            .foregroundStyle(FocusBrand.ink).background(FocusBrand.canvas).preferredColorScheme(.light)
    }
}

private struct HoldControl: NSViewRepresentable {
    let verb: String
    let onComplete: () -> Void
    func makeNSView(context: Context) -> NativeHoldControl {
        let control = NativeHoldControl(); control.verb = verb; control.onComplete = onComplete
        return control
    }
    func updateNSView(_ view: NativeHoldControl, context: Context) { view.verb = verb; view.onComplete = onComplete }
}

@MainActor final class NativeHoldControl: NSView {
    var verb = "continue"
    var onComplete: (() -> Void)?
    private var hold = ContinuousHold()
    private var timer: Timer?
    private var focusObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
        resetHold()
        if let window {
            focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resetHold() }
            }
        }
        setAccessibilityLabel("Hold for ten seconds to \(verb). Hold the mouse button or Space; releasing resets.")
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); beginHold() }
    override func mouseDragged(with event: NSEvent) {
        if !bounds.contains(convert(event.locationInWindow, from: nil)) { resetHold() }
    }
    override func mouseUp(with event: NSEvent) { resetHold() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { if !event.isARepeat { beginHold() } }
        else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { resetHold() } else { super.keyUp(with: event) } }
    override func resignFirstResponder() -> Bool { resetHold(); return super.resignFirstResponder() }
    private func beginHold() {
        guard timer == nil, window?.isKeyWindow == true else { return }
        hold.begin(at: ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common); needsDisplay = true
    }
    private func advance() {
        guard window?.isKeyWindow == true else { resetHold(); return }
        if hold.complete(at: ProcessInfo.processInfo.systemUptime) {
            resetHold(); onComplete?()
        } else { needsDisplay = true }
    }
    private func resetHold() { timer?.invalidate(); timer = nil; hold.reset(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let progress = hold.progress(at: ProcessInfo.processInfo.systemUptime)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill(); shape.fill()
        NSGraphicsContext.saveGraphicsState(); shape.addClip()
        NSColor(calibratedRed: 0.29, green: 0.37, blue: 0.20, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let text = (hold.startedAt == nil ? "Hold to \(verb) · 10s" : "Keep holding · \(max(1, Int(ceil(10 * (1 - progress)))))s") as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if window?.firstResponder === self {
            NSColor.white.withAlphaComponent(0.5).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6)
            ring.lineWidth = 1; ring.stroke()
        }
    }
}
