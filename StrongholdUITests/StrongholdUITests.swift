import GitTestSupport
import XCTest

/// End-to-end checks that launch the real app. ILLUMI_SCRIPTED=1 keeps it silent, and every launch gets
/// its own library file so the tests never touch the real one.
final class StrongholdUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(environment: [String: String] = [:], library: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ILLUMI_SCRIPTED"] = "1"
        let libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stronghold-ui-library-\(UUID().uuidString).json")
        if let library { try? Data(library.utf8).write(to: libraryURL) }
        app.launchEnvironment["STRONGHOLD_LIBRARY_PATH"] = libraryURL.path
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    func testWelcomeScreenShowsGitVersionAndEmptyLibrary() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["openRepository"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["cloneRepository"].exists)
        XCTAssertTrue(app.staticTexts["gitVersion"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "library.empty").exists)
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
        XCTAssertTrue(element(app, "changes.list").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["notes.txt"].exists)

        element(app, "sidebar.history").click()
        XCTAssertTrue(app.staticTexts["Add app"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Initial commit"].exists)
        app.terminate()
    }

    @MainActor
    func testLibraryListsRepositoriesAndOpensOne() async throws {
        let fixture = try await TemporaryRepository()
        try await fixture.commit("Initial commit", files: ["a.txt": "1\n"])
        let library = """
        {"version":1,"repositories":[{"id":"11111111-1111-1111-1111-111111111111","path":"\(fixture.path)",
        "name":"Sample Project","addedAt":"2026-11-10T10:00:00Z"}]}
        """
        let app = launch(library: library)
        let row = element(app, "library.row.Sample Project")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(element(app, "changes.clean").waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testStagingAFileAndCommittingIt() async throws {
        let fixture = try await TemporaryRepository()
        try await fixture.commit("Initial commit", files: ["a.txt": "1\n", "b.txt": "1\n"])
        try fixture.write("a.txt", "2\n")
        try fixture.write("b.txt", "2\n")

        let app = launch(environment: ["STRONGHOLD_OPEN_REPOSITORY": fixture.path])
        let stage = element(app, "stage.a.txt")
        XCTAssertTrue(stage.waitForExistence(timeout: 10))
        stage.click()
        XCTAssertTrue(element(app, "unstage.a.txt").waitForExistence(timeout: 5))

        let message = element(app, "commit.message")
        message.click()
        message.typeText("Update a")
        let commit = app.buttons["commit.button"]
        XCTAssertTrue(commit.isEnabled)
        commit.click()
        XCTAssertTrue(element(app, "commit.last").waitForExistence(timeout: 10))
        // a.txt is committed; b.txt is still waiting.
        XCTAssertFalse(element(app, "unstage.a.txt").exists)
        XCTAssertTrue(element(app, "stage.b.txt").exists)
        app.terminate()
    }

    @MainActor
    func testCloneSheetOpensFromTheWelcomeScreen() throws {
        let app = launch()
        let clone = app.buttons["cloneRepository"]
        XCTAssertTrue(clone.waitForExistence(timeout: 10))
        clone.click()
        let address = app.textFields["clone.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["clone.start"].isEnabled)
        address.click()
        address.typeText("https://example.com/team/project.git")
        XCTAssertTrue(app.buttons["clone.start"].isEnabled)
        XCTAssertEqual(app.textFields["clone.folder"].value as? String, "project")
        app.buttons["clone.cancel"].click()
        app.terminate()
    }
}
