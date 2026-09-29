//
//  Clipboard_saverUITests.swift
//  Clipboard_saverUITests
//
//  Created by Nyimbi K. Odero on 26/07/2025.
//

import XCTest

/// Launch tests.
///
/// The app is an `LSUIElement` agent: it has no window, no menu bar item, and
/// nothing to tap. So there is no UI to drive, and the honest question is the
/// only one available -- does it launch, and does it stay up.
///
/// There is deliberately no `measure` block here. The Xcode template ships one,
/// and it fails the suite often enough to matter ("Received unexpected number of
/// metrics: 0") while passing in isolation, because the metric is dropped when
/// other tests have run first. It asserts nothing about this app, and a test
/// that needs a re-run before it will pass trains everyone to re-run before they
/// believe a failure. The performance claim in the README is measured on the
/// conversion path instead, where the number is reproducible.
final class Clipboard_saverUITests: XCTestCase {

    override func setUpWithError() throws {
        // A launch that fails partway leaves nothing to assert against.
        continueAfterFailure = false
    }

    /// Whether the agent is up.
    ///
    /// `runningBackground` counts, and is in fact what an `LSUIElement` app with
    /// no windows reports. Asserting `runningForeground` here would be asserting
    /// that the app has a window it is specifically built not to have.
    private func isUp(_ app: XCUIApplication) -> Bool {
        app.state == .runningForeground || app.state == .runningBackground
    }

    /// The agent starts, stays running, and exits cleanly on quit.
    ///
    /// `terminate()` is the assertion. An agent that registers its Services
    /// provider and then crashes on launch still "launches", and the only way to
    /// find out is to ask it to stop and watch whether it actually does.
    @MainActor
    func testTheAgentLaunchesAndStaysUp() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(isUp(app), "the agent did not stay up after launch: \(app.state.rawValue)")

        app.terminate()
        XCTAssertFalse(isUp(app), "the agent ignored quit")
    }

    /// A second launch must work.
    ///
    /// Services apps are relaunched constantly -- once per invocation from the
    /// Finder -- so a first launch that works and a second that does not would
    /// make the app usable exactly once per login.
    @MainActor
    func testTheAgentRelaunches() throws {
        for attempt in 1...2 {
            let app = XCUIApplication()
            app.launch()
            XCTAssertTrue(isUp(app), "launch \(attempt) of 2 failed: \(app.state.rawValue)")
            app.terminate()
        }
    }
}
