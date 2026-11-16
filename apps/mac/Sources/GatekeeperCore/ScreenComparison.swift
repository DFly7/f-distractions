import CoreGraphics
import Foundation

public struct ScreenFingerprint: Equatable {
    public let displayID: UInt32
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let pixels: [UInt8]

    public init(displayID: UInt32, sourceWidth: Int, sourceHeight: Int, pixels: [UInt8]) {
        self.displayID = displayID; self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight; self.pixels = pixels
    }

    public static func make(displayID: UInt32, image: CGImage) throws -> ScreenFingerprint {
        let width = 160, height = 90
        var bytes = [UInt8](repeating: 0, count: width * height)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw GatekeeperError("Couldn’t compare screen images locally.") }
        return ScreenFingerprint(displayID: displayID, sourceWidth: image.width, sourceHeight: image.height, pixels: bytes)
    }
}

public enum ScreenComparison {
    /// A substantial change in the stable region identifies navigation without
    /// treating moving video pixels as a new page every second.
    public static func substantialSettledChange(previous: [ScreenFingerprint], current: [ScreenFingerprint], followup: [ScreenFingerprint]) -> Bool {
        for old in previous {
            guard let a = current.first(where: { $0.displayID == old.displayID }),
                  let b = followup.first(where: { $0.displayID == old.displayID }),
                  old.sourceWidth == a.sourceWidth, old.sourceHeight == a.sourceHeight,
                  a.sourceWidth == b.sourceWidth, a.sourceHeight == b.sourceHeight,
                  !old.pixels.isEmpty, old.pixels.count == a.pixels.count, a.pixels.count == b.pixels.count else { continue }
            var stable = 0, changed = 0
            for i in old.pixels.indices where abs(Int(a.pixels[i]) - Int(b.pixels[i])) <= 18 {
                stable += 1
                if abs(Int(old.pixels[i]) - Int(b.pixels[i])) > 18 { changed += 1 }
            }
            if stable >= old.pixels.count / 5 && Double(changed) / Double(stable) >= 0.18 { return true }
        }
        return false
    }

    /// Compare against the last successful analysis, not the previous sample.
    public static func changed(_ current: [ScreenFingerprint], since baseline: [ScreenFingerprint]?) -> Bool {
        guard let baseline, current.count == baseline.count else { return true }
        guard Set(current.map(\.displayID)) == Set(baseline.map(\.displayID)) else { return true }
        for screen in current {
            guard let old = baseline.first(where: { $0.displayID == screen.displayID }),
                  screen.sourceWidth == old.sourceWidth, screen.sourceHeight == old.sourceHeight,
                  !screen.pixels.isEmpty, screen.pixels.count == old.pixels.count else { return true }
            let changed = zip(screen.pixels, old.pixels).reduce(0) { count, pair in
                count + (abs(Int(pair.0) - Int(pair.1)) > 18 ? 1 : 0)
            }
            if Double(changed) / Double(screen.pixels.count) >= 0.025 { return true }
        }
        return false
    }
}

public enum CheckTrigger: String, Codable {
    case initial = "Session started"
    case spaceChange = "Desktop changed"
    case appSwitch = "App switched"
    case navigation = "Window/tab changed"
    case viewChange = "View content changed"
    case displayChange = "Displays changed"
    case visualChange = "Screen changed"
    case manual = "Requested check"
    case retry = "Retry after error"
}

public struct MonitoringPolicy {
    public var minimumGap: TimeInterval
    public private(set) var baseline: [ScreenFingerprint]?
    public private(set) var lastRequest: Date?
    public private(set) var pendingTrigger: CheckTrigger? = .initial
    private var settleUntil: Date?
    private var retryAfter: Date?

    public init(minimumGap: TimeInterval) { self.minimumGap = max(1, minimumGap) }

    public mutating func queue(_ trigger: CheckTrigger, at now: Date) {
        let existingIsPriority = pendingTrigger == .spaceChange || pendingTrigger == .appSwitch || pendingTrigger == .navigation || pendingTrigger == .viewChange || pendingTrigger == .displayChange || pendingTrigger == .manual
        let incomingIsPriority = trigger == .spaceChange || trigger == .appSwitch || trigger == .navigation || trigger == .viewChange || trigger == .displayChange || trigger == .manual
        if (baseline != nil || pendingTrigger != .initial) && (!existingIsPriority || incomingIsPriority) { pendingTrigger = trigger }
        if trigger == .spaceChange || trigger == .appSwitch || trigger == .navigation || trigger == .viewChange || trigger == .displayChange { settleUntil = now.addingTimeInterval(0.35) }
    }

    public func trigger(for screens: [ScreenFingerprint], at now: Date) -> CheckTrigger? {
        if let settleUntil, now < settleUntil { return nil }
        if let retryAfter, now < retryAfter { return nil }
        if let lastRequest, now.timeIntervalSince(lastRequest) < requestGap { return nil }
        if let pendingTrigger { return pendingTrigger }
        return ScreenComparison.changed(screens, since: baseline) ? .visualChange : nil
    }

    public mutating func beganRequest(at now: Date) {
        lastRequest = now; pendingTrigger = nil; settleUntil = nil; retryAfter = nil
    }

    public mutating func succeeded(with screens: [ScreenFingerprint]) { baseline = screens }

    public mutating func failed(at now: Date) {
        if pendingTrigger == nil { pendingTrigger = .retry }
        retryAfter = now.addingTimeInterval(max(30, minimumGap))
    }

    public var nextAllowedRequest: Date? {
        [lastRequest?.addingTimeInterval(requestGap), retryAfter, settleUntil].compactMap { $0 }.max()
    }

    private var requestGap: TimeInterval {
        switch pendingTrigger {
        case .spaceChange, .appSwitch, .navigation, .viewChange, .displayChange, .manual: return min(3, minimumGap)
        default: return minimumGap
        }
    }
}
