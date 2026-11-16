import Foundation

public struct ScreenWindowContext: Equatable {
    public let windowID: UInt32
    public let processID: Int32
    public let navigationToken: Int?
    public init(windowID: UInt32, processID: Int32, navigationToken: Int? = nil) {
        self.windowID = windowID; self.processID = processID; self.navigationToken = navigationToken
    }
}

public struct InterventionCandidate: Identifiable, Equatable {
    public var id: UInt32 { fingerprint.displayID }
    public let fingerprint: ScreenFingerprint
    public let screenIndex: Int
    public let reason: String
    public let context: ScreenWindowContext?
    public init(fingerprint: ScreenFingerprint, screenIndex: Int, reason: String, context: ScreenWindowContext? = nil) {
        self.fingerprint = fingerprint; self.screenIndex = screenIndex; self.reason = reason
        self.context = context
    }
}

public enum SceneFreshness {
    /// Ignore pixels moving between two fresh local samples (e.g. a playing video),
    /// but require the stable part of the screen to match the assessed screenshot.
    public static func matches(_ evidence: ScreenFingerprint, current: ScreenFingerprint, followup: ScreenFingerprint? = nil) -> Bool {
        guard evidence.displayID == current.displayID,
              evidence.sourceWidth == current.sourceWidth, evidence.sourceHeight == current.sourceHeight,
              !evidence.pixels.isEmpty, evidence.pixels.count == current.pixels.count else { return false }
        if !ScreenComparison.changed([current], since: [evidence]) { return true }
        guard let followup, followup.displayID == current.displayID,
              followup.sourceWidth == current.sourceWidth, followup.sourceHeight == current.sourceHeight,
              followup.pixels.count == current.pixels.count else { return false }
        var stable = 0, changed = 0
        for index in current.pixels.indices {
            if abs(Int(current.pixels[index]) - Int(followup.pixels[index])) <= 18 {
                stable += 1
                if abs(Int(evidence.pixels[index]) - Int(followup.pixels[index])) > 18 { changed += 1 }
            }
        }
        guard stable >= evidence.pixels.count / 5 else { return false }
        return Double(changed) / Double(stable) < 0.025
    }
}

public struct InterventionRules {
    private struct Approval {
        let fingerprint: ScreenFingerprint
        let expiresAt: Date
    }
    private var approvals: [UInt32: Approval] = [:]
    private var recent: [(candidate: InterventionCandidate, expiresAt: Date)] = []
    public init() {}
    public mutating func reset() { approvals = [:]; recent = [] }
    public mutating func clearApprovals() { approvals = [:] }
    public func hasRecentViews(at now: Date) -> Bool { recent.contains { now < $0.expiresAt && $0.candidate.context != nil } }
    public mutating func remember(_ candidates: [InterventionCandidate], at now: Date) {
        recent.removeAll { now >= $0.expiresAt }
        for candidate in candidates {
            recent.removeAll { $0.candidate.id == candidate.id && $0.candidate.context == candidate.context &&
                !ScreenComparison.changed([$0.candidate.fingerprint], since: [candidate.fingerprint]) }
            recent.insert((candidate, now.addingTimeInterval(120)), at: 0)
        }
        recent = Array(recent.prefix(20))
    }
    public func recalled(current: [ScreenFingerprint], contexts: [UInt32: ScreenWindowContext], at now: Date) -> [InterventionCandidate] {
        current.compactMap { screen in
            guard !isApproved(screen, at: now), let match = recent.first(where: {
                now < $0.expiresAt && $0.candidate.id == screen.displayID && $0.candidate.context != nil &&
                $0.candidate.context == contexts[screen.displayID] &&
                !ScreenComparison.changed([screen], since: [$0.candidate.fingerprint])
            }) else { return nil }
            return InterventionCandidate(fingerprint: screen, screenIndex: current.firstIndex(where: { $0.displayID == screen.displayID })! + 1,
                reason: match.candidate.reason, context: match.candidate.context)
        }
    }
    @discardableResult public mutating func expireApprovals(at now: Date) -> Bool {
        let expired = approvals.filter { now >= $0.value.expiresAt }.map(\.key)
        for id in expired { approvals.removeValue(forKey: id) }
        return !expired.isEmpty
    }
    public mutating func approve(_ fingerprint: ScreenFingerprint, at now: Date) {
        approvals[fingerprint.displayID] = Approval(fingerprint: fingerprint, expiresAt: now.addingTimeInterval(120))
    }
    public func isApproved(_ current: ScreenFingerprint, followup: ScreenFingerprint? = nil, at now: Date) -> Bool {
        guard let approval = approvals[current.displayID], now < approval.expiresAt else { return false }
        return SceneFreshness.matches(approval.fingerprint, current: current, followup: followup)
    }
    public func candidates(verdict: Verdict, assessed: [ScreenFingerprint], current: [ScreenFingerprint],
                           followup: [ScreenFingerprint] = [], assessedAt: Date, now: Date,
                           contextUnchanged: Bool, assessedContexts: [UInt32: ScreenWindowContext] = [:],
                           currentContexts: [UInt32: ScreenWindowContext] = [:]) -> [InterventionCandidate] {
        guard contextUnchanged, now.timeIntervalSince(assessedAt) >= 0,
              now.timeIntervalSince(assessedAt) <= 20,
              (try? verdict.validated(screenCount: assessed.count)) != nil else { return [] }
        return verdict.screens.compactMap { screen in
            guard screen.status == "off_task", assessed.indices.contains(screen.screenIndex - 1) else { return nil }
            let evidence = assessed[screen.screenIndex - 1]
            guard let latest = current.first(where: { $0.displayID == evidence.displayID }) else { return nil }
            let next = followup.first { $0.displayID == evidence.displayID }
            let oldWindow = assessedContexts[evidence.displayID], newWindow = currentContexts[evidence.displayID]
            let validView = oldWindow != nil || newWindow != nil ? oldWindow != nil && oldWindow == newWindow :
                SceneFreshness.matches(evidence, current: latest, followup: next)
            guard validView,
                  !isApproved(latest, followup: next, at: now) else { return nil }
            return InterventionCandidate(fingerprint: next ?? latest, screenIndex: screen.screenIndex, reason: screen.reason, context: newWindow)
        }
    }
}
