import XCTest
import GatekeeperCore

final class ClassifierPromptTests: XCTestCase {
    func testReferenceMatchesEmbeddedClassifierInstructions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let reference = try String(contentsOf: root.appendingPathComponent("shared/prompts/classify.txt"), encoding: .utf8)
        XCTAssertEqual(reference.trimmingCharacters(in: .whitespacesAndNewlines), FocusClassifierPrompt.instructions)
    }
}
