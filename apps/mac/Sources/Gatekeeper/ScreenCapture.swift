import AppKit
import ScreenCaptureKit
import GatekeeperCore

struct CapturedScreen: Identifiable {
    let id: CGDirectDisplayID
    let label: String
    let image: NSImage
    let file: URL
    let fingerprint: ScreenFingerprint
    var context: ScreenWindowContext? = nil
}

@MainActor enum ScreenCapture {
    // Exclude interventions, including fading-out panels, rather than the entire app.
    static var overlayWindowIDs: () -> Set<CGWindowID> = { [] }

    static func currentWindowContexts() -> [UInt32: ScreenWindowContext] {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let context = windowContext(on: CGDisplayBounds(id), windows: windows, excluding: overlayWindowIDs()) else { return nil }
            return (id, context)
        })
    }
    static func cleanupTemporaryCaptures() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gatekeeper-captures", isDirectory: true)
        let prefix = "\(ProcessInfo.processInfo.processIdentifier)-"
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if file.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: file) }
        }
    }
    static func captureAll() async throws -> [CapturedScreen] {
        guard CGPreflightScreenCaptureAccess() else {
            throw GatekeeperError("Allow Gatekeeper in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. macOS may ask you to quit and reopen the app.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = content.displays.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            return $0.displayID < $1.displayID
        }
        guard !displays.isEmpty else { throw GatekeeperError("No displays are available to capture. Reconnect your display and try again.") }
        let excludedIDs = overlayWindowIDs()
        let overlays = content.windows.filter { excludedIDs.contains($0.windowID) }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var captures: [CapturedScreen] = []
        do {
            for (index, display) in displays.enumerated() {
                try Task.checkCancellation()
                let screen = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                }
                let name = screen?.localizedName ?? "Display \(display.displayID)"
                let (image, file, fingerprint) = try await capture(display: display, excluding: overlays)
                let context = windowContext(on: display.frame, windows: windows, excluding: excludedIDs)
                captures.append(CapturedScreen(id: display.displayID, label: "Screen \(index + 1) · \(name)", image: image, file: file, fingerprint: fingerprint, context: context))
            }
            try Task.checkCancellation()
            return captures
        } catch {
            for capture in captures { try? FileManager.default.removeItem(at: capture.file) }
            throw error
        }
    }

    static func windowContext(on display: CGRect, windows: [[String: Any]], excluding excludedIDs: Set<CGWindowID> = []) -> ScreenWindowContext? {
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let id = window[kCGWindowNumber as String] as? UInt32, !excludedIDs.contains(id),
                  layer == 0 || pid == ProcessInfo.processInfo.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            let visible = frame.intersection(display)
            guard !visible.isNull, visible.width * visible.height >= display.width * display.height * 0.1 else { continue }
            // Transient local hash detects tab/document navigation. Titles themselves
            // are neither stored nor sent to the model.
            let token = (window[kCGWindowName as String] as? String).map { $0.hashValue }
            return ScreenWindowContext(windowID: id, processID: pid, navigationToken: token)
        }
        return nil
    }

    private static func capture(display: SCDisplay, excluding overlays: [SCWindow]) async throws -> (NSImage, URL, ScreenFingerprint) {
        let filter = SCContentFilter(display: display, excludingWindows: overlays)
        let config = SCStreamConfiguration()
        let scale = min(1.0, 1600.0 / Double(max(display.width, display.height)))
        config.width = max(1, Int(Double(display.width) * scale))
        config.height = max(1, Int(Double(display.height) * scale))
        config.showsCursor = false
        config.capturesAudio = false
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let fingerprint = try ScreenFingerprint.make(displayID: display.displayID, image: cgImage)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw GatekeeperError("Couldn’t encode the screenshot.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gatekeeper-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).jpg")
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return (image, file, fingerprint)
    }
}
