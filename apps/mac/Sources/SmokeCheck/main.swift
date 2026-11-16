import Foundation
import AppKit
import GatekeeperCore

@main struct SmokeCheck {
    @MainActor static func main() async {
        let client = CodexClient()
        client.onDiagnostic = { if $0.hasPrefix("AI request starting:") { print($0) } }
        do {
            try await client.connect()
            guard let account = try await client.account() else {
                throw GatekeeperError("No ChatGPT sign-in found. Sign in using the app.")
            }
            print("PASS: subscription account available (\(account))")
            let models = try await client.models()
            let selectedID = CommandLine.arguments.firstIndex(of: "--model").flatMap { index in
                CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil
            }
            let model: CodexModel
            if let selectedID {
                guard let selected = models.first(where: { $0.id == selectedID }) else { throw GatekeeperError("Requested model is not available: \(selectedID)") }
                model = selected
            } else { model = models.first(where: \.isDefault) ?? models[0] }
            print("PASS: model catalogue loaded; selected \(model.id)")
            if CommandLine.arguments.contains("--task-brief-fixture") {
                let started = Date()
                let brief = try await client.refineTask(goal: "Rehearse my HCA formative demo for 25 minutes",
                    details: "COMP3074 project is a Python Padel Bot, not the separate Gatekeeper Mac app. Rehearse the terminal demo, inspect chatbot.py and retrieval.py, review identity memory, TF-IDF FAQ retrieval and FORMATIVE.md. Job applications and unrelated feeds are off task.", model: model.id)
                guard !brief.allowed.isEmpty, !brief.goal.isEmpty, !brief.offTask.isEmpty else {
                    throw GatekeeperError("Task brief was empty")
                }
                print("PASS: editable task brief returned in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                print("Task brief: \(brief.goal)")
                client.stop()
                return
            }
            if CommandLine.arguments.contains("--multi-screen-fixture") {
                var files: [URL] = []
                defer { for file in files { try? FileManager.default.removeItem(at: file) } }
                let work = try fixture("SwiftUI Documentation\n\nBuilding a macOS menu-bar application\n\nUse MenuBarExtra to create a menu-bar app.")
                files.append(work)
                let unused = try fixture("", background: .systemBlue)
                files.append(unused)
                let unrelated = try fixture("System Settings\n\nPrivacy & Security\n\nScreen & System Audio Recording\n\nGatekeeper: Allowed")
                files.append(unrelated)
                for (images, expected) in [([unused, work], "on_task"), ([work, unrelated], "off_task")] {
                    let started = Date()
                    let result = try await client.analyse(goal: "Build a macOS menu-bar application in SwiftUI", images: images, model: model.id)
                    guard result.status == expected else {
                        throw GatekeeperError("Multi-screen fixture expected \(expected), got \(result.status): \(result.reason)")
                    }
                    let offScreens = result.screens.filter { $0.status == "off_task" }.map(\.screenIndex)
                    guard offScreens == (expected == "off_task" ? [2] : []) else {
                        throw GatekeeperError("Wrong per-screen target: \(offScreens)")
                    }
                    print("PASS: combined screen verdict \(expected) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(result.reason)")
                }
                client.stop()
                return
            }
            let settingsFixture = CommandLine.arguments.contains("--settings-fixture")
            if CommandLine.arguments.contains("--analyse-fixture") || settingsFixture {
                // A synthetic image, never a capture of the user's screen.
                let image = NSImage(size: NSSize(width: 1000, height: 600))
                image.lockFocus()
                NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 600).fill()
                let text = settingsFixture
                    ? "System Settings\n\nPrivacy & Security\n\nScreen & System Audio Recording\n\nGatekeeper: Allowed"
                    : "SwiftUI Documentation\n\nBuilding a macOS menu-bar application\n\nUse MenuBarExtra to create a menu-bar app."
                (text as NSString).draw(in: NSRect(x: 45, y: 200, width: 900, height: 350),
                                         withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
                image.unlockFocus()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("gatekeeper-fixture-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: url) }
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Fixture rendering failed") }
                try png.write(to: url)
                if settingsFixture {
                    for (goal, expected) in [
                        ("Build the first version of Gatekeeper", "off_task"),
                        ("Enable Gatekeeper’s screen recording permission in macOS System Settings", "on_task")
                    ] {
                        let result = try await client.analyse(goal: goal, image: url, model: model.id)
                        guard result.status == expected else {
                            throw GatekeeperError("Settings fixture expected \(expected), got \(result.status): \(result.reason)")
                        }
                        print("PASS: settings classified \(expected) for goal: \(goal)")
                    }
                    client.stop()
                    return
                }
                let verdict = try await client.analyse(goal: "Build a macOS menu-bar application in SwiftUI", image: url, model: model.id)
                guard verdict.status == "on_task" else { throw GatekeeperError("Expected on_task for the documentation fixture; got \(verdict.status): \(verdict.reason)") }
                print("PASS: image input + structured verdict: \(verdict.status) — \(verdict.reason)")
                let offTask = try await client.analyse(goal: "Write a history essay about the Roman Empire; do not work on software", image: url, model: model.id)
                guard offTask.status == "off_task" else { throw GatekeeperError("Expected off_task for the unrelated fixture; got \(offTask.status): \(offTask.reason)") }
                print("PASS: unrelated goal detected: \(offTask.status) — \(offTask.reason)")
            }
            client.stop()
        } catch {
            client.stop()
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func fixture(_ text: String, background: NSColor = .white) throws -> URL {
        let image = NSImage(size: NSSize(width: 1000, height: 600))
        image.lockFocus()
        background.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 600).fill()
        (text as NSString).draw(in: NSRect(x: 45, y: 100, width: 900, height: 450),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw GatekeeperError("Could not create synthetic screen fixture")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gatekeeper-fixture-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }
}
