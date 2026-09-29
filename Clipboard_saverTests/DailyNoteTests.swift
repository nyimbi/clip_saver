import Foundation
import XCTest
@testable import Clipboard_saver

/// Tests for daily notes and destination presets.
///
/// Daily notes are the riskiest thing in this project. A daily note is a file
/// this tool did not write: it holds the user's own prose, has no frontmatter and
/// no body hash, so every mechanism that protects the other files says "foreign,
/// hands off". The section mechanism exists to get past that safely, and these
/// tests are mostly about what it must *not* touch.
final class DailyNoteTests: XCTestCase {

    private func conversation(title: String = "Thread", bodies: [String] = ["a question"]) -> Conversation {
        Conversation(
            title: title,
            source: .claude,
            url: URL(string: "https://claude.ai/chat/abc"),
            turns: bodies.map { Turn(role: .user, body: $0) }
        )
    }

    // MARK: - Inserting

    func testAFreshNoteGetsADayHeading() {
        let out = DailyNote.appending("SECTION", to: "", now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(out.hasPrefix("# 1970-01-01\n\n"))
        XCTAssertTrue(out.contains("SECTION"))
    }

    func testTheUserOwnProseIsPreservedAboveTheSection() {
        let note = "# Notes\n\n- bought milk\n- called the dentist\n"
        let out = DailyNote.appending("SECTION", to: note)
        XCTAssertTrue(out.hasPrefix(note), "the user's own lines were rewritten")
        XCTAssertTrue(out.contains("bought milk"))
        XCTAssertTrue(out.contains("called the dentist"))
        XCTAssertTrue(out.contains("SECTION"))
    }

    func testAHeadinglessNoteIsNotGivenOne() {
        // An existing note with no heading is the user's; adding a day heading
        // above their text would be presumptuous.
        let out = DailyNote.appending("SECTION", to: "just some notes\n")
        XCTAssertTrue(out.hasPrefix("just some notes"))
    }

    func testASectionIsNotGluedToTheLastLine() {
        let out = DailyNote.appending("SECTION", to: "no trailing newline")
        XCTAssertTrue(out.contains("no trailing newline\n\nSECTION"))
    }

    func testASectionIsNotGluedToAnExistingBlankLine() {
        let out = DailyNote.appending("SECTION", to: "text\n\n")
        XCTAssertEqual(out, "text\n\nSECTION")
    }

    // MARK: - Deciding

    func testAnUnknownConversationIsInserted() {
        XCTAssertEqual(
            DailyNote.decide(note: "# Notes\n", conversation: conversation()),
            .insert
        )
    }

    func testAConversationAlreadyPresentIsUnchanged() {
        let conv = conversation()
        var note = ""
        note = DailyNote.appending(DailyNote.makeSection(conv), to: note)
        XCTAssertEqual(DailyNote.decide(note: note, conversation: conv), .unchanged)
    }

    /// A grown thread must *replace* its section, not be added a second time.
    ///
    /// The fingerprint covers the content, so a grown conversation's fingerprint
    /// no longer matches the one in the note — which is how the first version
    /// ended up with the same conversation appearing twice in one day, while the
    /// separate destination correctly updated the same thread in place.
    func testAGrownConversationReplacesItsSection() {
        let small = conversation(bodies: ["one"])
        let grown = conversation(bodies: ["one", "two"])
        let note = DailyNote.appending(DailyNote.makeSection(small, now: Date(timeIntervalSince1970: 0)), to: "")

        XCTAssertEqual(
            DailyNote.decide(note: note, conversation: grown, now: Date(timeIntervalSince1970: 0)),
            .replace
        )

        let applied = DailyNote.apply(.replace, note: note, conversation: grown, now: Date(timeIntervalSince1970: 0))
        let updated = applied ?? ""
        XCTAssertEqual(
            updated.components(separatedBy: "<!-- clipboard-saver:").count - 1,
            1,
            "a grown conversation added a second section instead of updating the first"
        )
        XCTAssertTrue(updated.contains("two"), "the new turn is missing")
    }

    /// A genuinely divergent conversation must not overwrite the section already
    /// in the note. Replacing it would lose the version that is not in hand.
    func testADivergentConversationIsAddedRatherThanOverwritten() {
        let original = conversation(title: "Thread", bodies: ["completely different"])
        let divergent = conversation(title: "Thread", bodies: ["something else entirely"])
        let note = DailyNote.appending(DailyNote.makeSection(original), to: "")

        XCTAssertEqual(DailyNote.decide(note: note, conversation: divergent), .insert)

        let updated = DailyNote.apply(.insert, note: note, conversation: divergent) ?? ""
        XCTAssertTrue(updated.contains("completely different"), "the existing section was lost")
        XCTAssertTrue(updated.contains("something else entirely"))
    }

    /// A conversation whose title matches another's must not be mistaken for it.
    func testTwoConversationsWithTheSameTitleCoexist() {
        let a = conversation(title: "Thread", bodies: ["alpha content"])
        let b = conversation(title: "Thread", bodies: ["beta content"])
        var note = ""
        for conv in [a, b] {
            let action = DailyNote.decide(note: note, conversation: conv)
            note = DailyNote.apply(action, note: note, conversation: conv) ?? note
        }
        XCTAssertTrue(note.contains("alpha content"))
        XCTAssertTrue(note.contains("beta content"))
        XCTAssertEqual(note.components(separatedBy: "<!-- clipboard-saver:").count - 1, 2)
    }

    // MARK: - Idempotence

    /// The property that matters: pressing save five times leaves one entry.
    func testRepeatedSavesAddOneSection() {
        let conv = conversation()
        var note = ""
        for _ in 0..<5 {
            let action = DailyNote.decide(note: note, conversation: conv)
            guard let updated = DailyNote.apply(action, note: note, conversation: conv) else { break }
            note = updated
        }
        XCTAssertEqual(note.components(separatedBy: "<!-- clipboard-saver:").count - 1, 1)
    }

    func testTwoConversationsCoexist() {
        let a = conversation(title: "Alpha", bodies: ["first"])
        let b = conversation(title: "Beta", bodies: ["second"])
        var note = ""
        for conv in [a, b] {
            let action = DailyNote.decide(note: note, conversation: conv)
            note = DailyNote.apply(action, note: note, conversation: conv) ?? note
        }
        XCTAssertTrue(note.contains("Alpha"))
        XCTAssertTrue(note.contains("Beta"))
        XCTAssertEqual(note.components(separatedBy: "<!-- clipboard-saver:").count - 1, 2)
    }

    // MARK: - Replacing leaves the rest alone

    func testReplacingASectionLeavesOtherSectionsIntact() {
        let a = conversation(title: "Alpha", bodies: ["first"])
        let b = conversation(title: "Beta", bodies: ["second"])
        var note = ""
        for conv in [a, b] {
            let action = DailyNote.decide(note: note, conversation: conv)
            note = DailyNote.apply(action, note: note, conversation: conv) ?? note
        }
        let withHeader = "# 2026-01-01\n\nuser prose\n\n" + note

        let replacement = DailyNote.replacingSection(in: withHeader, for: a, with: "NEW A")
        XCTAssertTrue(replacement.contains("NEW A"))
        XCTAssertFalse(replacement.contains("### Alpha"), "the old section survived")
        XCTAssertTrue(replacement.contains("Beta"), "the other conversation was lost")
        XCTAssertTrue(replacement.contains("user prose"), "the user's own text was lost")
    }

    func testReplacingTheLastSectionDoesNotEatWhatFollowsIt() {
        let a = conversation(title: "Alpha", bodies: ["first"])
        let note = DailyNote.appending(DailyNote.makeSection(a), to: "") + "\ntrailing user note\n"
        let out = DailyNote.replacingSection(in: note, for: a, with: "NEW")
        XCTAssertTrue(out.contains("trailing user note"), "text after the last marker was eaten")
    }

    /// A note the user has edited so the marker is gone must not be touched.
    /// There is no way to find the section any more, and guessing would rewrite
    /// their text.
    func testAConversationWithNoMarkerIsRefusedRatherThanGuessedAt() {
        var note = DailyNote.appending(DailyNote.makeSection(conversation(title: "Alpha")), to: "")
        note = note.replacingOccurrences(of: "<!-- clipboard-saver:", with: "<!-- edited by hand: ")
        XCTAssertEqual(DailyNote.decide(note: note, conversation: conversation(title: "Alpha")), .insert)
    }

    // MARK: - Sections

    func testASectionCarriesItsMarkerAndHeading() {
        let section = DailyNote.makeSection(conversation(title: "Alpha"), now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(section.hasPrefix("<!-- clipboard-saver:"))
        XCTAssertTrue(section.contains("### Alpha"))
        XCTAssertTrue(section.contains("https://claude.ai/chat/abc"), "the source link is missing")
    }

    func testTheMarkerIsNotRenderedByMarkdownViewers() {
        // An HTML comment: invisible in every renderer, and not stripped by
        // writing tools the way some markers are.
        let marker = DailyNote.marker(for: "abc")
        XCTAssertTrue(marker.hasPrefix("<!--"))
        XCTAssertTrue(marker.hasSuffix("-->"))
    }

    func testAConversationWithNoURLStillGetsASection() {
        let conv = Conversation(title: "No link", source: .claude, turns: [Turn(role: .user, body: "q")])
        let section = DailyNote.makeSection(conv)
        XCTAssertTrue(section.contains("### No link"))
        XCTAssertFalse(section.contains("·"), "an empty source line was left behind")
    }
}

final class DestinationTests: XCTestCase {

    private func conversation(title: String = "Thread") -> Conversation {
        Conversation(title: title, source: .claude, turns: [Turn(role: .user, body: "q")])
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Filenames

    func testASeparateDestinationUsesTheConversationTitle() {
        let name = DestinationResolver.filename(for: conversation(title: "Swift actors"), at: .separate(URL(fileURLWithPath: "/tmp")))
        XCTAssertEqual(name, "Swift actors.md")
    }

    func testADailyDestinationUsesTheDate() {
        let name = DestinationResolver.filename(
            for: conversation(),
            at: .daily(URL(fileURLWithPath: "/tmp")),
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(name, "1970-01-01.md")
    }

    func testAnUntitledConversationStillGetsAFilename() {
        let conv = Conversation(title: nil, source: .claude, turns: [Turn(role: .user, body: "some text here")])
        let name = DestinationResolver.filename(for: conv, at: .separate(URL(fileURLWithPath: "/tmp")))
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(name.hasSuffix(".md"))
    }

    // MARK: - Presets

    func testPresetsRoundTripThroughDefaults() {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }

        let presets = [
            Destination.Preset(name: "Vault", path: "/tmp/vault", behaviour: "daily"),
            Destination.Preset(name: "Log", path: "/tmp/log", behaviour: "append"),
            Destination.Preset(name: "Files", path: "/tmp/files", behaviour: "separate"),
        ]
        DestinationResolver.save(presets, defaults: defaults)
        XCTAssertEqual(DestinationResolver.load(defaults: defaults), presets)
    }

    /// An unknown behaviour must fall back rather than fail: an extension from a
    /// future build should still be able to save.
    func testAnUnknownBehaviourFallsBackToSeparate() {
        let preset = Destination.Preset(name: "Future", path: "/tmp/x", behaviour: "somethingNew")
        XCTAssertEqual(preset.resolved(), .separate(URL(fileURLWithPath: "/tmp/x")))
    }

    func testAMissingBehaviourFallsBackToSeparate() {
        let preset = Destination.Preset(name: "Plain", path: "/tmp/x", behaviour: nil)
        XCTAssertEqual(preset.resolved(), .separate(URL(fileURLWithPath: "/tmp/x")))
    }

    func testAPresetResolvesToItsBehaviour() {
        XCTAssertEqual(
            Destination.Preset(name: "Vault", path: "/tmp/v", behaviour: "daily").resolved(),
            .daily(URL(fileURLWithPath: "/tmp/v"))
        )
    }

    /// The extension can only ever construct a `separate` destination. The
    /// destructive behaviours are reachable only through the user's own
    /// configuration, because they need to have been asked for.
    func testAPlainPathIsAlwaysSeparate() {
        let destination = Destination.resolve(preset: "anything", path: "/tmp/x")
        XCTAssertEqual(destination, .separate(URL(fileURLWithPath: "/tmp/x")))
    }

    func testTildeIsExpandedInAPreset() {
        let preset = Destination.Preset(name: "Home", path: "~/notes", behaviour: "separate")
        XCTAssertFalse(preset.resolved().directory.path.hasPrefix("~"))
    }
}
