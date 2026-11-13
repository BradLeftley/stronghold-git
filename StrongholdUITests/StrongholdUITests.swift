import GitTestSupport
import XCTest

/// End-to-end checks that launch the real app. ILLUMI_SCRIPTED=1 keeps it silent.
final class StrongholdUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ILLUMI_SCRIPTED"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        return app
    }

    @MainActor
    func testWelcomeScreenShowsGitVersion() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["openRepository"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["gitVersion"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testOpensARepositoryAndShowsChangesAndHistory() async throws {
        let fixture = try await TemporaryRepository()
        try await fixture.commit("Initial commit", files: ["README.md": "# Demo\n"])
        try await fixture.commit("Add app", files: ["Sources/App.swift": "print(1)\n"])
        try fixture.write("README.md", "# Demo\n\nEdited.\n")
        try fixture.write("notes.txt", "new\n")

        let app = launch(environment: ["STRONGHOLD_OPEN_REPOSITORY": fixture.path])
        XCTAssertTrue(app.outlines["changes.list"].waitForExistence(timeout: 10)
                      || app.tables["changes.list"].waitForExistence(timeout: 2)
                      || app.descendants(matching: .any)["changes.list"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["notes.txt"].exists)

        app.descendants(matching: .any)["sidebar.history"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Add app"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Initial commit"].exists)
        app.terminate()
    }
}
