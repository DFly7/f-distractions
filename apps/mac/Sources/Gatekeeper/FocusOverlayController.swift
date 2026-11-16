import SwiftUI
import GatekeeperCore

/// Separate click-through blur and interactive card panels keep Cmd-Tab, the menu
/// bar, and navigation in the underlying app usable. Neither panel activates us.
@MainActor final class FocusOverlayController {
    private struct Panels {
        let blur: FocusPanel
        let card: FocusPanel
    }
    private var panels: [UInt32: Panels] = [:]
    private var retiring: [UUID: Panels] = [:]
    var onReturn: ((UInt32) -> Void)?
    var onRelevant: ((UInt32) -> Void)?
    var onBreak: (() -> Void)?
    private let presentsWindows: Bool
    var activeDisplayIDs: Set<UInt32> { Set(panels.keys) }
    var visiblePanelCount: Int { panels.values.reduce(0) { $0 + ($1.blur.isVisible ? 1 : 0) + ($1.card.isVisible ? 1 : 0) } }

    init(presentsWindows: Bool = true) { self.presentsWindows = presentsWindows }

    func update(_ candidates: [InterventionCandidate], goal: String, fadeDuration: TimeInterval = 1.4) {
        let wanted = Set(candidates.map(\.id))
        for id in Set(panels.keys).subtracting(wanted) { remove(id) }
        for candidate in candidates {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == candidate.id
            }) else { remove(candidate.id); continue }
            let id = candidate.id
            let view = FocusOverlayCard(goal: goal, reason: candidate.reason, screenIndex: candidate.screenIndex,
                onReturn: { [weak self] in
                    self?.panels[id]?.card.resignKey()
                    self?.onReturn?(id)
                },
                onRelevant: { [weak self] in self?.onRelevant?(id) },
                onBreak: { [weak self] in self?.onBreak?() })
            if let existing = panels[id] {
                existing.card.contentView = NSHostingView(rootView: view)
                continue
            }
            let blur = FocusPanel(frame: screen.frame, interactive: false)
            let bounds = NSRect(origin: .zero, size: screen.frame.size)
            let container = NSView(frame: bounds)
            let w = bounds.width, h = bounds.height, edge: CGFloat = 10
            let starts = [NSRect(x: 0, y: 0, width: w, height: edge),
                          NSRect(x: 0, y: h - edge, width: w, height: edge),
                          NSRect(x: 0, y: 0, width: edge, height: h),
                          NSRect(x: w - edge, y: 0, width: edge, height: h)]
            let ends = [NSRect(x: 0, y: 0, width: w, height: h / 2 + 1),
                        NSRect(x: 0, y: h / 2, width: w, height: h / 2),
                        NSRect(x: 0, y: 0, width: w / 2 + 1, height: h),
                        NSRect(x: w / 2, y: 0, width: w / 2, height: h)]
            let bands = starts.map { frame -> NSVisualEffectView in
                let effect = NSVisualEffectView(frame: frame)
                effect.material = .fullScreenUI; effect.blendingMode = .behindWindow; effect.state = .active
                container.addSubview(effect)
                return effect
            }
            blur.contentView = container
            let width = min(600, screen.visibleFrame.width - 40)
            let height: CGFloat = min(390, screen.visibleFrame.height - 40)
            let frame = NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.midY - height / 2,
                               width: width, height: height)
            let card = FocusPanel(frame: frame, interactive: true)
            card.contentView = NSHostingView(rootView: view)
            panels[id] = Panels(blur: blur, card: card)
            if presentsWindows {
                blur.alphaValue = 1; card.alphaValue = 0
                blur.orderFrontRegardless(); card.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = fadeDuration
                    for (index, band) in bands.enumerated() { band.animator().frame = ends[index] }
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.4
                    card.animator().alphaValue = 1
                }
            }
        }
    }

    func animateOut(displayID: UInt32) {
        let outgoing = panels.removeValue(forKey: displayID).map { [$0] } ?? []
        for entry in outgoing {
            let id = UUID()
            retiring[id] = entry
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                entry.blur.animator().alphaValue = 0
                entry.card.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let entry = self?.retiring.removeValue(forKey: id) else { return }
                    entry.blur.close(); entry.card.close()
                }
            }
        }
    }

    func hideAll() {
        for id in Array(panels.keys) { remove(id) }
        for entry in retiring.values { entry.blur.close(); entry.card.close() }
        retiring.removeAll()
    }
    private func remove(_ id: UInt32) {
        guard let entry = panels.removeValue(forKey: id) else { return }
        entry.blur.orderOut(nil); entry.card.orderOut(nil)
        entry.blur.close(); entry.card.close()
    }
}

@MainActor final class FocusPanel: NSPanel {
    init(frame: NSRect, interactive: Bool) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false; isFloatingPanel = true; becomesKeyOnlyIfNeeded = true
        // isFloatingPanel resets the native level; set our ordering afterwards.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + (interactive ? 1 : 0))
        ignoresMouseEvents = !interactive; hasShadow = interactive
        isMovable = false; animationBehavior = .none
    }
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { /* Escape does not dismiss a focus intervention. */ }
}

struct FocusOverlayCard: View {
    let goal: String
    let reason: String
    let screenIndex: Int
    let onReturn: () -> Void
    let onRelevant: () -> Void
    let onBreak: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                FocusMark(size: 30)
                Text("F DISTRACTIONS").font(.system(size: 10, weight: .bold)).tracking(1.6)
                Spacer()
                Text("SCREEN \(screenIndex)").font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(FocusBrand.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("You had a plan.").font(.system(size: 14, weight: .medium)).foregroundStyle(FocusBrand.muted)
                Text(goal).font(.system(size: 27, weight: .semibold)).tracking(-0.8)
                    .lineLimit(3).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
            }
            Text(reason).font(.system(size: 12)).foregroundStyle(FocusBrand.muted)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button(action: onReturn) {
                    HStack { Text("Return to work"); Image(systemName: "arrow.up.right") }
                        .frame(maxWidth: .infinity)
                }.buttonStyle(FocusButtonStyle(kind: .primary))
                Button("This is relevant", action: onRelevant).buttonStyle(FocusButtonStyle())
            }
            HStack {
                Text("3 seconds to switch. Then we check again.")
                    .font(.system(size: 10)).foregroundStyle(FocusBrand.muted)
                Spacer()
                Button("Take a break", action: onBreak).buttonStyle(FocusButtonStyle(kind: .quiet))
            }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(FocusBrand.canvas, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.65)))
            .foregroundStyle(FocusBrand.ink).preferredColorScheme(.light)
    }
}
