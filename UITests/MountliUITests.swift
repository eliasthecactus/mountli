import XCTest

final class MountliUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testApplicationLaunchesIntoForeground() throws {
        let application = XCUIApplication()
        application.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        application.launch()
        XCTAssertTrue(application.wait(for: .runningForeground, timeout: 15))
    }

    @MainActor
    func testCaptureAppStoreScreenshot() throws {
        let application = XCUIApplication()
        application.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "-onboarding.completed.v1", "NO",
            "-MOUNTLIScreenshotFixture",
        ]
        application.launch()
        XCTAssertTrue(application.staticTexts["Welcome to Mountli"].waitForExistence(timeout: 30))

        #if os(iOS)
            let screenshot = XCUIScreen.main.screenshot()
        #else
            let screenshot = application.windows.firstMatch.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Mountli-App-Store"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testEmptyIssuesStateIsCentered() throws {
        let application = launchInterfaceFixture()
        open("Issues", in: application)

        let emptyState = application.descendants(matching: .any).matching(identifier: "issues-empty-state").firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10))
        let title = application.staticTexts["No issues"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertLessThan(abs(title.frame.midX - emptyState.frame.midX), emptyState.frame.width * 0.12)
        XCTAssertLessThan(abs(title.frame.midY - emptyState.frame.midY), emptyState.frame.height * 0.50)
    }

    @MainActor
    func testCryptRemoteFormFitsConstrainedWindow() throws {
        let application = launchInterfaceFixture()
        open("Remotes", in: application)
        let addRemote = application.buttons["Add Remote"].firstMatch
        XCTAssertTrue(addRemote.waitForExistence(timeout: 10))
        addRemote.tap()
        XCTAssertTrue(application.staticTexts["Add Remote"].waitForExistence(timeout: 10))

        let crypt = application.staticTexts["Crypt"].firstMatch
        XCTAssertTrue(crypt.waitForExistence(timeout: 10))
        crypt.tap()

        let generatedPassword = application.staticTexts["crypt-generated-password"]
        XCTAssertTrue(generatedPassword.waitForExistence(timeout: 10))
        let window = application.windows.firstMatch.frame
        XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(generatedPassword.frame))
        let continueButton = application.buttons["crypt-continue"]
        for _ in 0..<4 where !continueButton.exists || !window.insetBy(dx: -1, dy: -1).contains(continueButton.frame) {
            application.swipeUp()
        }
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(continueButton.frame))
        XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(application.buttons["Cancel"].frame))
    }

    @MainActor
    private func launchInterfaceFixture() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "-onboarding.completed.v1", "YES",
            "-MOUNTLIScreenshotFixture",
        ]
        application.launch()
        XCTAssertTrue(application.wait(for: .runningForeground, timeout: 15))
        return application
    }

    @MainActor
    private func open(_ title: String, in application: XCUIApplication) {
        let button = application.buttons[title].firstMatch
        if button.waitForExistence(timeout: 5) {
            button.tap()
            return
        }
        let text = application.staticTexts[title].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
    }
}
