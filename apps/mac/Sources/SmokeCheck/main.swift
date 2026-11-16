import Foundation
import AppKit
import GatekeeperCore

@main struct SmokeCheck {
    @MainActor static func main() async {
        let client = CodexClient()
        client.onDiagnostic = { if $0.hasPrefix("AI request") || $0.hasPrefix("AI setup") { print($0) } }
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
            if CommandLine.arguments.contains("--interrupt-fixture") {
                let url = try fixture("Coursework report\n\nEvaluate chatbot intent routing with labelled queries and a confusion matrix.")
                defer { try? FileManager.default.removeItem(at: url) }
                var cancellation: Task<Bool, Never>?
                client.onDiagnostic = { line in
                    print(line)
                    if line.hasPrefix("AI request starting:"), cancellation == nil {
                        cancellation = Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            return await client.interruptAnalysis()
                        }
                    }
                }
                do {
                    _ = try await client.analyse(goal: "Write the chatbot coursework report.", image: url, model: model.id)
                    throw GatekeeperError("Expected superseded inference to be cancelled")
                } catch is CancellationError { }
                guard await cancellation?.value == true else { throw GatekeeperError("Turn interruption did not succeed") }
                print("PASS: obsolete turn cancelled without stopping the connection")
                client.onDiagnostic = { if $0.hasPrefix("AI request") || $0.hasPrefix("AI setup") { print($0) } }
                let result = try await client.analyse(goal: "Write the chatbot coursework report.", image: url, model: model.id)
                guard result.status == "on_task" else { throw GatekeeperError("Expected a fresh on-task result after interruption") }
                print("PASS: same connection completed the replacement request")
                client.stop(); return
            }
            if CommandLine.arguments.contains("--focus-ui-fixture") {
                let url = try fixture("F Distractions\nFocus session: Write the chatbot report\nTimer: 34:20 remaining\n\nLAST COMPLETED CHECK — HISTORICAL SCREENSHOT PREVIEW\nCaptured earlier: AI conversation about planning a holiday\nPrevious reason: This holiday discussion was unrelated.\n\nReturn to work | This is relevant | View screenshots & reasons")
                defer { try? FileManager.default.removeItem(at: url) }
                let result = try await client.analyse(goal: "Write the chatbot coursework report.", image: url, model: model.id)
                guard result.status == "unsure" else { throw GatekeeperError("Focus UI fixture expected unsure, got \(result.status): \(result.reason)") }
                print("PASS: monitoring UI and historical preview classified unsure: \(result.reason)")
                client.stop(); return
            }
            if CommandLine.arguments.contains("--conversation-fixture") {
                var files: [URL] = []
                defer { for file in files { try? FileManager.default.removeItem(at: file) } }
                let goal = "Work on HCI chatbot coursework, using AI conversations to understand intent routing and evaluation. Unrelated dissertation work, holidays and job hunting are off task."
                let cases = [
                    ("HCI coursework", "User: How should I evaluate intent routing for my HCI chatbot report?\n\nAssistant: Compare predicted intents against labelled test queries. Report a confusion matrix and discuss ambiguous utterances.", "on_task"),
                    ("Holiday planning", "User: Help me plan a beach holiday in Spain. Which resorts have the best nightlife?\n\nAssistant: Compare beach resorts, hotels and party venues. Here is a seven-day holiday itinerary.", "off_task"),
                    ("Dissertation", "User: Help structure my unrelated dissertation on solar energy policy.\n\nAssistant: Start with renewable energy economics, policy incentives and national electricity market data.", "off_task")
                ]
                for (selected, messages, expected) in cases {
                    let url = try conversationFixture(selected: selected, messages: messages)
                    files.append(url)
                    let result = try await client.analyse(goal: goal, image: url, model: model.id)
                    guard result.status == expected, result.screens.first?.status == expected else {
                        throw GatekeeperError("Conversation fixture expected \(expected), got \(result.status): \(result.reason)")
                    }
                    print("PASS: \(selected) classified \(expected): \(result.reason)")
                }
                client.stop(); return
            }
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

    // Synthetic conversation UI: the same sidebar contains related and unrelated
    // thread names in every case. Only the displayed messages determine relevance.
    @MainActor static func conversationFixture(selected: String, messages: String) throws -> URL {
        let image = NSImage(size: NSSize(width: 1200, height: 760))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 760).fill()
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 240, height: 760).fill()
        for (index, title) in ["HCI coursework", "Dissertation", "Holiday planning"].enumerated() {
            let y = CGFloat(620 - index * 70)
            if title == selected {
                NSColor(calibratedWhite: 0.8, alpha: 1).setFill(); NSRect(x: 12, y: y - 10, width: 216, height: 50).fill()
            }
            (title as NSString).draw(at: NSPoint(x: 25, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 21), .foregroundColor: NSColor.black])
        }
        ("AI conversation" as NSString).draw(at: NSPoint(x: 280, y: 690), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.black])
        (messages as NSString).draw(in: NSRect(x: 280, y: 120, width: 870, height: 510), withAttributes: [.font: NSFont.systemFont(ofSize: 27), .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { throw GatekeeperError("Could not render conversation fixture") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gatekeeper-conversation-\(UUID().uuidString).png")
        try data.write(to: url); return url
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
