import AppKit
import XCTest
@testable import Clipboard_saver

/// Guards the contract between `Info.plist` and the running app.
///
/// This is the class of defect that makes an `NSServices` app fail *silently*:
/// macOS dispatches a service by looking up the `NSMessage` string on the
/// `NSApp.servicesProvider` object. A missing `CFBundleIdentifier` means
/// LaunchServices cannot register the app at all, and a `NSMessage` with no
/// matching selector means the menu item exists and does nothing when chosen.
/// Neither produces a build error, which is exactly why they went unnoticed.
final class ServiceContractTests: XCTestCase {

    private var info: [String: Any] {
        // The unit tests are hosted by the app, so `Bundle.main` is the built
        // application bundle and this is the post-processed plist.
        guard let dictionary = Bundle.main.infoDictionary else {
            XCTFail("the test host is not the application bundle")
            return [:]
        }
        return dictionary
    }

    // MARK: - Bundle identity

    func testBundleHasAnIdentifier() {
        let identifier = info["CFBundleIdentifier"] as? String
        XCTAssertEqual(identifier, "datacraft.Clipboard-saver")
    }

    /// Without this, LaunchServices cannot launch the app as a service.
    func testBundleNamesItsExecutable() {
        let executable = info["CFBundleExecutable"] as? String
        XCTAssertEqual(executable, "Clipboard_saver")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Clipboard_saver").path
            )
        )
    }

    func testBundleTypeIsAnApplication() {
        XCTAssertEqual(info["CFBundlePackageType"] as? String, "APPL")
    }

    /// The app is an agent: it has no windows and must not appear in the Dock.
    func testAppIsAnAgentApplication() {
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
    }

    // MARK: - Service declarations

    private var services: [[String: Any]] {
        info["NSServices"] as? [[String: Any]] ?? []
    }

    func testFourServicesAreDeclared() {
        XCTAssertEqual(services.count, 4)
    }

    /// The background service must declare no `NSSendTypes`. Finder only offers
    /// a service whose declared types are present on the pasteboard, and a
    /// background right-click carries no file URL -- so constraining this one
    /// removes the only way to save into the current folder.
    func testTheBackgroundServiceIsUnconstrained() throws {
        let here = try XCTUnwrap(services.first { ($0["NSMessage"] as? String) == "saveHere" })
        XCTAssertNil(here["NSSendTypes"], "a constrained saveHere is never offered on a background click")
    }

    /// The folder service is the opposite: it must be constrained to file URLs,
    /// otherwise it appears on every background click alongside "…Here".
    func testTheFolderServiceRequiresAFileSelection() throws {
        let folder = try XCTUnwrap(services.first { ($0["NSMessage"] as? String) == "saveToFolder" })
        let types = folder["NSSendTypes"] as? [String] ?? []
        XCTAssertTrue(types.contains("public.file-url"))
        XCTAssertTrue(types.contains("NSFilenamesPboardType"))
    }

    /// Search takes a typed phrase, not rich content. Advertising `public.html`
    /// would offer it whenever anything rich is selected — which is most of the
    /// time, and almost always a request to *save* something rather than to
    /// search for it.
    func testTheSearchServiceTakesPlainTextOnly() throws {
        let search = try XCTUnwrap(services.first { ($0["NSMessage"] as? String) == "searchArchive" })
        let types = search["NSSendTypes"] as? [String] ?? []
        XCTAssertEqual(types, ["NSStringPboardType"])
        XCTAssertFalse(types.contains("public.html"))
        XCTAssertFalse(types.contains("public.rtf"))
    }

    /// Search is only useful in a folder context, and declaring no context would
    /// put it in every application's Services menu.
    func testTheSearchServiceIsOfferedInFinder() throws {
        let search = try XCTUnwrap(services.first { ($0["NSMessage"] as? String) == "searchArchive" })
        let context = search["NSRequiredContext"] as? [String: String]
        XCTAssertEqual(context?["NSApplicationIdentifier"], "com.apple.finder")
    }

    /// Every `NSMessage` must name a method that the services provider
    /// actually implements. AppKit matches the message against the beginning of
    /// an Objective-C selector, so `saveHere` is served by
    /// `saveHere:userData:error:`.
    func testEveryServiceMessageHasAMatchingSelector() throws {
        let provider = AppDelegate.self
        let selectors = selectors(on: provider)

        let messages = services.compactMap { $0["NSMessage"] as? String }
        XCTAssertEqual(messages.count, services.count, "every service needs an NSMessage")

        for message in messages {
            let expected = "\(message):userData:error:"
            XCTAssertTrue(
                selectors.contains(expected),
                "NSMessage \"\(message)\" has no \(expected) on AppDelegate; known: \(selectors.sorted())"
            )
        }
    }

    /// The port name has to match the executable, or the service is registered
    /// against a binary that does not exist.
    func testServicePortMatchesTheExecutable() {
        let executable = info["CFBundleExecutable"] as? String
        for service in services {
            XCTAssertEqual(service["NSPortName"] as? String, executable)
        }
    }

    func testEveryServiceHasAMenuItem() {
        for service in services {
            let menuItem = service["NSMenuItem"] as? [String: Any]
            XCTAssertNotNil(menuItem?["default"], "menu item missing a title")
            XCTAssertFalse((menuItem?["default"] as? String ?? "").isEmpty)
        }
    }

    /// The Services menu entry has to offer the rich representations, or
    /// "Save Clipboard to File" can only ever write plain text.
    func testRunServiceAcceptsRichRepresentations() throws {
        let run = try XCTUnwrap(services.first { ($0["NSMessage"] as? String) == "saveToDesktop" })
        let types = run["NSSendTypes"] as? [String] ?? []
        XCTAssertTrue(types.contains("NSStringPboardType"), "plain text must be accepted")
        XCTAssertTrue(types.contains("public.html"), "HTML must be accepted or conversion never runs")
        XCTAssertTrue(types.contains("public.rtf"))
    }

    /// The Finder-specific services must only be offered inside Finder.
    func testFinderServicesAreScopedToFinder() {
        for name in ["saveToFolder", "saveHere"] {
            let service = services.first { ($0["NSMessage"] as? String) == name }
            XCTAssertNotNil(service, "\(name) is not declared")
            let context = service?["NSRequiredContext"] as? [String: Any]
            XCTAssertEqual(
                context?["NSApplicationIdentifier"] as? String, "com.apple.finder",
                "\(name) would otherwise appear in every app's Services menu"
            )
        }
    }

    func testTheAppleEventUsageDescriptionIsPresent() {
        // Without it, the front-Finder-window lookup silently fails under
        // App Sandbox and recent macOS privacy controls.
        XCTAssertFalse((info["NSAppleEventsUsageDescription"] as? String ?? "").isEmpty)
    }

    // MARK: - Helpers

    private func selectors(on cls: AnyClass) -> Set<String> {
        var result = Set<String>()
        var current: AnyClass? = cls
        while let target = current {
            var count: UInt32 = 0
            if let methods = class_copyMethodList(target, &count) {
                for index in 0..<Int(count) {
                    result.insert(NSStringFromSelector(method_getName(methods[index])))
                }
                free(methods)
            }
            current = class_getSuperclass(target)
        }
        return result
    }
}
