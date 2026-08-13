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
        XCTAssertTrue(application.staticTexts["Welcome to MOUNTLI"].waitForExistence(timeout: 30))

        #if os(iOS)
            let screenshot = XCUIScreen.main.screenshot()
        #else
            let screenshot = application.windows.firstMatch.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "MOUNTLI-App-Store"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
