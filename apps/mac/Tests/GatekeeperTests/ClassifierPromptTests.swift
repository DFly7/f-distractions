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
    func testSharedVerdictFixturesMatchMacEvidenceValidation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/verdicts.json"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for item in cases {
            let name = item["name"] as? String ?? "fixture"
            let count = try XCTUnwrap(item["screenCount"] as? Int)
            let valid = try XCTUnwrap(item["valid"] as? Bool)
            let response = try JSONSerialization.data(withJSONObject: XCTUnwrap(item["response"]))
            if valid {
                _ = try Verdict.decode(String(decoding: response, as: UTF8.self)).validated(screenCount: count)
            } else {
                XCTAssertThrowsError(try Verdict.decode(String(decoding: response, as: UTF8.self)).validated(screenCount: count), name)
            }
        }
    }
}
