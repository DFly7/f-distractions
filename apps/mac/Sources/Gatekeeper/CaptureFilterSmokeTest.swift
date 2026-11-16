import AppKit
import GatekeeperCore

/// Local-only integration check. No AI request; captured files are deleted immediately.
@MainActor enum CaptureFilterSmokeTest {
    static func run() async throws {
        guard let screen = NSScreen.main,
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            throw GatekeeperError("No test display")
        }
        let frame = NSRect(x: screen.frame.midX - screen.frame.width * 0.325, y: screen.frame.midY - screen.frame.height * 0.325,
                           width: screen.frame.width * 0.65, height: screen.frame.height * 0.65)
        let main = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let overlay = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false; overlay.isReleasedWhenClosed = false
        main.backgroundColor = .blue; overlay.backgroundColor = .red
        main.isOpaque = true; overlay.isOpaque = true
        overlay.level = .floating
        main.orderFrontRegardless(); overlay.orderFrontRegardless()
        let oldExclusions = ScreenCapture.overlayWindowIDs
        ScreenCapture.overlayWindowIDs = { oldExclusions().union([CGWindowID(overlay.windowNumber)]) }
        defer {
            ScreenCapture.overlayWindowIDs = oldExclusions
            main.close(); overlay.close()
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        let captures = try await ScreenCapture.captureAll()
        defer { for capture in captures { try? FileManager.default.removeItem(at: capture.file) } }
        guard let capture = captures.first(where: { $0.id == displayID }),
              let tiff = capture.image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB),
              color.blueComponent > 0.7, color.redComponent < 0.3,
              capture.context?.windowID == UInt32(main.windowNumber) else {
            throw GatekeeperError("Own-window capture or overlay exclusion did not match the synthetic blue window")
        }
    }
}
