import Foundation
import XCTest
@testable import Gatekeeper

final class DiagnosticsTests: XCTestCase {
    func testRotationKeepsOnlyTwoArchivesAndRestrictsPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("gatekeeper.log")
        for value in ["first\n", "second\n", "third\n", "fourth\n"] {
            try DiagnosticLogFile.append(Data(value.utf8), to: file, maximumBytes: 10)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "fourth\n")
        XCTAssertEqual(try String(contentsOf: file.appendingPathExtension("1"), encoding: .utf8), "third\n")
        XCTAssertEqual(try String(contentsOf: file.appendingPathExtension("2"), encoding: .utf8), "second\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 3)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
