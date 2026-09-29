import Foundation

/// A named place conversations are saved to.
///
/// A destination is configuration rather than a path passed per request,
/// because the extension is a separate process and should not be the thing
/// holding the answer to "where does the user keep these". The host owns that.
///
/// Three behaviours, because they answer genuinely different needs:
///
///   - `separate`: one file per conversation, merged on re-save. The default,
///     and the only one that behaves well when a thread grows.
///   - `daily`: every conversation from a day lands in one dated file. People
///     keep notes by day, and an archive nobody can browse is an archive nobody
///     reads.
///   - `append`: one growing file per platform or topic, like a scratch log.
enum Destination: Equatable {
    case separate(URL)
    case daily(URL)
    case append(URL, name: String)

    var directory: URL {
        switch self {
        case .separate(let url), .daily(let url), .append(let url, _): return url
        }
    }

    /// A plain path becomes a `separate` destination.
    ///
    /// This is the one construction available to the extension, and it is
    /// deliberately the least powerful: a caller who can only name a folder gets
    /// one file per conversation and nothing else. The other behaviours are
    /// reachable only through the user's own configuration, because they are
    /// destructive in a way that needs to have been asked for.
    static func resolve(preset: String?, path: String) -> Destination {
        .separate(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    /// A destination named by the user's own configuration.
    ///
    /// The `appBehaviour` field is deliberately a string on the wire rather than
    /// the enum, because a host that receives a behaviour it does not know must
    /// fall back rather than fail: an extension from a future build should still
    /// be able to save a conversation.
    struct Preset: Codable, Equatable {
        var name: String
        var path: String
        /// "separate" | "daily" | "append". Anything else is treated as separate.
        var behaviour: String?

        /// Declared explicitly because the convenience init below suppresses
        /// Swift's memberwise initialiser for a struct, and the memberwise form
        /// is the one callers and fixtures actually want.
        init(name: String, path: String, behaviour: String? = nil) {
            self.name = name
            self.path = path
            self.behaviour = behaviour
        }

        func resolved() -> Destination {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            switch behaviour {
            case "daily": return .daily(url)
            case "append": return .append(url, name: name)
            default: return .separate(url)
            }
        }

        init(_ destination: Destination, name: String) {
            self.name = name
            self.path = destination.directory.path
            switch destination {
            case .separate: behaviour = "separate"
            case .daily: behaviour = "daily"
            case .append(_, let file): behaviour = "append"; self.name = file
            }
        }
    }
}

/// Resolves a destination and works out the filename for a conversation.
enum DestinationResolver {

    /// The default, when nothing is configured.
    ///
    /// `~/Documents/Conversations`, which may not exist. Creating a folder the
    /// user never asked for is worse than reporting that nothing is configured.
    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Conversations", isDirectory: true)
    }

    /// Resolves a preset name to a destination.
    ///
    /// `defaults` is injectable so this is testable without writing to the
    /// user's real settings — a test that reached `.standard` would silently
    /// repoint a real user's daily notes at a temporary directory.
    static func resolve(preset: String?, defaults: UserDefaults = .standard) -> Destination {
        let presets = load(defaults: defaults)
        if let preset, let found = presets.first(where: { $0.name == preset }) {
            return found.resolved()
        }
        if let first = presets.first {
            return first.resolved()
        }
        if let fallback = defaultDirectory() {
            return .separate(fallback)
        }
        // Nothing is available; the saver turns this into a structured
        // "no destination" rather than writing somewhere arbitrary.
        return .separate(URL(fileURLWithPath: "/"))
    }

    /// Presets, from user defaults. Read through here rather than at each call
    /// site so there is one definition of the key.
    /// The key presets are stored under.
    static let defaultsKey = "destinations"

    /// Read as `Data`, not as a string array.
    ///
    /// The obvious implementation stores a `stringArray`, which round-trips
    /// nothing: a preset is an object, and `stringArray(forKey:)` silently
    /// returns empty for anything that is not an array of strings. Every
    /// configured destination then vanished on the next read, with no error --
    /// so a user's daily-note setting quietly stopped being daily.
    static func load(defaults: UserDefaults = .standard) -> [Destination.Preset] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Destination.Preset].self, from: data)
        else { return [] }
        return decoded
    }

    static func save(_ presets: [Destination.Preset], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    // MARK: - Filenames

    /// The filename a conversation gets under a destination.
    static func filename(for conversation: Conversation, at destination: Destination, now: Date = Date()) -> String {
        switch destination {
        case .separate:
            return title(from: conversation)
        case .daily:
            // One file per day, so a conversation saved twice on the same day is
            // merged by IncrementalSave like any other.
            return iso8601.day(from: now) + ".md"
        case .append(_, let name):
            return name
        }
    }

    /// A title-derived filename, deduplicated against what is on disk.
    static func title(from conversation: Conversation) -> String {
        let title = Frontmatter.resolvedTitle(conversation)
        let basis = title.isEmpty ? conversation.turns.first?.body ?? "Chat" : title
        return FilenameGenerator.title(from: basis) + ".md"
    }
}
