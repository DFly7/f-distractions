import XCTest
import GatekeeperCore
@testable import Gatekeeper

@MainActor final class SignInRecoveryTests: XCTestCase {
    private func connectedModel() async -> (AppModel, FakeConnection) {
        Diagnostics.enabled = false
        let connection = FakeConnection()
        let store = SessionStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("gatekeeper-auth-test-\(UUID().uuidString)/sessions.json"))
        let model = AppModel(client: connection, sessionStore: store)
        model.openSignInURL = { _ in true }
        await model.connect()
        return (model, connection)
    }

    func testReconnectClearsStuckSignInAndPreservesChosenModel() async {
        let (model, connection) = await connectedModel()
        defer { model.shutdown() }
        model.selectedModel = "second-model"
        model.signingIn = true // Reproduce the reported Connected + Waiting state.
        XCTAssertFalse(model.canCheck)
        await model.connect()
        XCTAssertFalse(model.signingIn)
        XCTAssertTrue(model.canCheck)
        XCTAssertEqual(connection.cancellations, 1)
        XCTAssertEqual(model.selectedModel, "second-model")
    }

    func testAbandonedBrowserSignInCanBeCancelledWithoutLosingAccount() async {
        let (model, connection) = await connectedModel()
        defer { model.shutdown() }
        await model.signIn()
        XCTAssertTrue(model.signingIn)
        XCTAssertFalse(model.canCheck)
        await model.cancelSignIn()
        XCTAssertFalse(model.signingIn)
        XCTAssertTrue(model.canCheck)
        XCTAssertNotNil(model.account)
        XCTAssertEqual(connection.cancellations, 1)
    }

    func testFailedBrowserLaunchDoesNotDisableChecking() async {
        let (model, connection) = await connectedModel()
        defer { model.shutdown() }
        model.openSignInURL = { _ in false }
        await model.signIn()
        XCTAssertFalse(model.signingIn)
        XCTAssertTrue(model.canCheck)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(connection.cancellations, 1)
    }

    func testFailedLoginNotificationReleasesCheckButton() async {
        let (model, connection) = await connectedModel()
        defer { model.shutdown() }
        await model.signIn()
        connection.onLoginCompleted?(false, "Browser sign-in was closed")
        XCTAssertFalse(model.signingIn)
        XCTAssertTrue(model.canCheck)
        XCTAssertEqual(model.error, "Browser sign-in was closed")
    }

    func testTaskSetupAppliesEditableBriefAndIncludesClarificationAnswer() async {
        let (model, connection) = await connectedModel()
        defer { model.shutdown() }
        model.goal = "HCA coursework"
        model.taskContext = "Python Padel Bot project"
        connection.brief = TaskBrief(goal: "Work on Padel Bot", allowed: ["Read chatbot.py"], offTask: ["Gatekeeper development"], question: "Which component are you improving?")
        await model.refineTask()
        XCTAssertFalse(model.refiningTask)
        XCTAssertEqual(model.taskQuestion, "Which component are you improving?")
        XCTAssertTrue(model.taskContext.contains("Gatekeeper development"))
        model.taskAnswer = "FAQ retrieval"
        connection.brief = TaskBrief(goal: "Improve FAQ retrieval", allowed: ["Edit retrieval.py"], offTask: ["LinkedIn"], question: "")
        await model.refineTask()
        XCTAssertTrue(connection.lastDetails.contains("FAQ retrieval"))
        XCTAssertNil(model.taskQuestion)
        XCTAssertEqual(model.goal, "Improve FAQ retrieval")
    }

    func testCompletedResultDoesNotPreventAnotherCheck() async throws {
        let (model, _) = await connectedModel()
        defer { model.shutdown() }
        model.lastCheck = Date()
        model.verdict = try Verdict.decode("{\"status\":\"on_task\",\"reason\":\"Working\",\"nextStep\":\"Continue\"}")
        XCTAssertTrue(model.canCheck)
        model.clear()
        XCTAssertTrue(model.canCheck)
    }
}

@MainActor private final class FakeConnection: GatekeeperConnection {
    var onLoginCompleted: ((Bool, String?) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var accountEmail: String? { nil }
    var cancellations = 0
    var brief: TaskBrief?
    var lastDetails = ""
    func connect() async throws {}
    func account() async throws -> String? { "ChatGPT Test" }
    func models() async throws -> [CodexModel] {
        [CodexModel(id: "test-model", name: "Test", isDefault: true),
         CodexModel(id: "second-model", name: "Second", isDefault: false)]
    }
    func signIn() async throws -> URL { URL(string: "https://example.invalid/sign-in")! }
    func cancelSignIn() async { cancellations += 1 }
    func analyse(goal: String, images: [URL], model: String) async throws -> Verdict {
        throw GatekeeperError("Tests do not capture screens or call the model")
    }
    func refineTask(goal: String, details: String, model: String) async throws -> TaskBrief {
        lastDetails = details
        guard let brief else { throw GatekeeperError("No fake brief configured") }
        return brief
    }
    func stop(reason: String) {}
}
