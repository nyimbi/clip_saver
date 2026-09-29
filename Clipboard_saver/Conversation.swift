import Foundation

/// Who said a turn. The raw value is what appears in the Markdown body, so
/// renaming a case changes output — which is why the cases are `.user` and
/// `.assistant` rather than something more Swift-idiomatic.
enum TurnRole: String, Codable, CaseIterable {
    case user
    case assistant

    /// Some platforms label the model's internal monologue separately from its
    /// answer. It is off by default because most people want the answer.
    case reasoning
}

/// How a turn's body is encoded on the wire.
enum BodyFormat: String, Codable {
    case markdown
    case html
}

/// One message in a conversation.
///
/// `body` is already Markdown. Extraction turns the DOM into a structural
/// representation and renders it here, so nothing downstream has to guess at
/// what a `<div class="prose">` meant.
struct Turn: Codable, Equatable, Hashable {
    var role: TurnRole
    var body: String
    var timestamp: Date?

    /// Reasoning and tool calls are kept separate from the answer so they can be
    /// included or dropped without re-parsing the message.
    var reasoning: String?
    var toolCalls: [ToolCall]
    /// Files the turn referenced.
    var attachments: [Attachment]
    /// How `body` is encoded.
    ///
    /// Conversions are almost always Markdown already, and converting twice
    /// would mangle it. But a page capture arrives as HTML from the browser, and
    /// converting it there would mean shipping the structural converter into
    /// JavaScript -- so the body is tagged and the *app* does the work, which is
    /// where the 64 tests of it live.
    var format: BodyFormat

    init(
        role: TurnRole,
        body: String,
        timestamp: Date? = nil,
        reasoning: String? = nil,
        toolCalls: [ToolCall] = [],
        attachments: [Attachment] = [],
        format: BodyFormat = .markdown
    ) {
        self.role = role
        self.body = body
        self.timestamp = timestamp
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.attachments = attachments
        self.format = format
    }

    /// Decoded explicitly rather than synthesised, because a default in an
    /// initialiser does not make a property optional on the wire.
    ///
    /// The sender is JavaScript, which naturally omits empty fields, so a
    /// synthesised decoder rejects a perfectly ordinary message for lacking
    /// `toolCalls`. That surfaced as `malformedRequest` from a request that was
    /// in fact well formed -- an unhelpful answer to a correct message, and one
    /// that would have been blamed on the extension.
    enum CodingKeys: String, CodingKey {
        case role, body, timestamp, reasoning, toolCalls, attachments, format
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(TurnRole.self, forKey: .role)
        body = try container.decode(String.self, forKey: .body)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        // Absent means Markdown, which is what every existing sender means.
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        format = try container.decodeIfPresent(BodyFormat.self, forKey: .format) ?? .markdown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        // Omitted when empty, so the payload stays small for the common case of a
        // conversation with no tool calls at all.
        if !toolCalls.isEmpty {
            try container.encode(toolCalls, forKey: .toolCalls)
        }
        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }
        if format != .markdown {
            try container.encode(format, forKey: .format)
        }
    }
}

/// A file referenced by a conversation.
///
/// Recorded as a *reference*, never fetched. The app makes no network
/// connections by design, and that is not a limitation to work around -- it is
/// the reason the archive is worth keeping. So an attachment is captured as
/// what the page says about it: name, kind, size, and where it lives.
///
/// A reference is still most of the value. The list of what a conversation was
/// *about* survives; the bytes do not, and pretending otherwise with a broken
/// local link would be worse than saying so.
struct Attachment: Codable, Equatable, Hashable {
    var name: String
    /// A coarse kind, for display: "image", "document", "code", "archive".
    var kind: String
    var byteSize: Int?
    /// Where the page said it was. Not fetched.
    var url: String?
    /// Set when the file was retrievable from the DOM itself, which is a
    /// data: URL or an inline blob the page already holds.
    var inline: Bool

    init(name: String, kind: String? = nil, byteSize: Int? = nil, url: String? = nil, inline: Bool = false) {
        // Sanitised once, here, so no downstream renderer can be tricked.
        //
        // The name arrives from a remote page, which makes it untrusted input
        // wearing the costume of a filename. A backtick closes a Markdown code
        // span and a newline ends the line, so "chart` **done**\n\n# Injected"
        // would otherwise write a fabricated heading into the user's own note
        // -- forging content that looks like it came from them.
        //
        // The newlines cannot be preserved, and pretending otherwise would mean
        // writing a name that cannot be read back. The URL is the authoritative
        // reference; the name is a label.
        self.name = Self.sanitised(name)
        self.kind = kind ?? Self.kind(forName: name)
        self.byteSize = byteSize
        self.url = url
        self.inline = inline
    }

    /// Collapses a name to one line of safe, printable text.
    ///
    /// Control characters and newlines go; the rest survives untouched, because
    /// a filename that is ugly but honest beats one that is tidy and wrong.
    static func sanitised(_ raw: String) -> String {
        let printable = raw.unicodeScalars.map { scalar -> Character in
            // Newlines, C0 controls and DEL cannot appear in a one-line label.
            // The rest are kept: some are real punctuation in real filenames, and
            // dropping them would make the name a lie.
            let isNewline = scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}"
            return (isNewline || scalar.value < 0x20 || scalar.value == 0x7F) ? " " : Character(scalar)
        }
        return String(printable)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Wraps the name in a code span, widening the fence to fit.
    ///
    /// CommonMark lets a code span use more backticks than it contains, so a
    /// name with a backtick in it stays literal instead of ending the span and
    /// letting the rest of the name be read as Markdown.
    public var codeSpan: String {
        var longest = 0
        var run = 0
        for character in name {
            if character == "`" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        let fence = String(repeating: "`", count: max(1, longest + 1))
        // A leading or trailing backtick would touch the fence, so pad per
        // CommonMark.
        let pad = name.hasPrefix("`") || name.hasSuffix("`") ? " " : ""
        return fence + pad + name + pad + fence
    }

    /// The fence width this name needs, for reading the span back.
    var fenceWidth: Int {
        var longest = 0
        var run = 0
        for character in name {
            if character == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        return max(1, longest + 1)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = try container.decode(String.self, forKey: .name)
        name = Self.sanitised(rawName)
        // The sender is allowed to send null: the extension does, because the
        // table that maps an extension to a kind lives here and not there. A
        // required non-optional field across a process boundary is a trap with
        // the serialiser on one side of it and the deserialiser on the other.
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? Self.kind(forName: name)
        byteSize = try container.decodeIfPresent(Int.self, forKey: .byteSize)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        inline = try container.decodeIfPresent(Bool.self, forKey: .inline) ?? false
    }

    /// Guesses a kind from the extension.
    ///
    /// From the name alone, and it says so implicitly: the extension is the only
    /// evidence available, so an unusual name is filed as "file" rather than
    /// guessed into a category it might not belong to.
    static func kind(forName name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "avif": return "image"
        case "pdf", "doc", "docx", "rtf", "odt", "pages": return "document"
        case "txt", "md", "csv", "json", "yaml", "yml", "toml", "xml": return "text"
        case "swift", "py", "js", "ts", "rs", "go", "rb", "java", "kt", "c", "cpp", "h": return "code"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar": return "archive"
        case "mp3", "wav", "m4a", "flac", "aac": return "audio"
        case "mp4", "mov", "webm", "mkv", "avi": return "video"
        default: return ext.isEmpty ? "file" : "file"
        }
    }

    /// A one-line description for the saved file.
    public var description: String {
        var out = "`\(name)`"
        if let byteSize { out += " (\(ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)))" }
        if !inline { out += " — not downloaded" }
        return out
    }
}

struct ToolCall: Codable, Equatable, Hashable {
    var name: String
    var input: String?
    var output: String?
}

/// Which product a conversation came from.
///
/// A string rather than a closed enum on purpose: new AI products appear
/// monthly, and an unknown platform should degrade to "works, slightly less
/// well" rather than fail to decode. Adapters add a `DisplayName`.
enum ConversationSource: RawRepresentable, Codable, Equatable, Hashable {
    case chatgpt
    case claude
    case gemini
    case perplexity
    case copilot
    /// A page that is not a chat at all — the "save this article" path.
    case webPage
    /// Anything the adapter recognises but this build does not name.
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "chatgpt": self = .chatgpt
        case "claude": self = .claude
        case "gemini": self = .gemini
        case "perplexity": self = .perplexity
        case "copilot": self = .copilot
        case "web": self = .webPage
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .chatgpt: return "chatgpt"
        case .claude: return "claude"
        case .gemini: return "gemini"
        case .perplexity: return "perplexity"
        case .copilot: return "copilot"
        case .webPage: return "web"
        case .other(let name): return name
        }
    }

    var displayName: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .perplexity: return "Perplexity"
        case .copilot: return "Copilot"
        case .webPage: return "Web"
        case .other(let name):
            // Adapters pass through a product name; title-case it rather than
            // showing a raw slug.
            guard !name.isEmpty else { return "Unknown" }
            return name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    /// Accepts either the slug or the display name.
    ///
    /// The frontmatter stores the display name, because that is what a person
    /// reads in the file, so reading a file back has to resolve `"Claude"` to
    /// `.claude`. A fingerprint computed from the display name would not match
    /// one computed from the slug, and every re-save would look like a new
    /// conversation.
    init(identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        for known in [ConversationSource.chatgpt, .claude, .gemini, .perplexity, .copilot, .webPage] {
            if known.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
                || known.displayName.caseInsensitiveCompare(trimmed) == .orderedSame {
                self = known
                return
            }
        }
        self = ConversationSource(rawValue: trimmed)
    }
}

/// How an extraction went.
///
/// This is the mechanism for feature 2.3. A conversation that was cut short
/// because the page had not finished virtualising its message list must never
/// look like a complete one, because the failure mode is a file that silently
/// lost most of its content.
struct ExtractionConfidence: Equatable, Codable {
    /// 0...1. Below `reliable` the caller is expected to say so rather than
    /// write the file as if nothing happened.
    var score: Double
    /// Whether the adapter believes it saw every turn.
    var complete: Bool
    /// How the adapter got the content, for diagnostics and for the
    /// fingerprint's benefit — a DOM scrape and a state read can produce the
    /// same turns but differ in whitespace.
    var strategy: ExtractionStrategy
    /// Non-fatal problems worth surfacing: a selector that no longer matches, a
    /// truncated stream, an attachment that could not be fetched.
    var warnings: [String]

    init(
        score: Double,
        complete: Bool,
        strategy: ExtractionStrategy,
        warnings: [String] = []
    ) {
        self.score = min(max(score, 0), 1)
        self.complete = complete
        self.strategy = strategy
        self.warnings = warnings
    }

    /// Same reasoning as `Turn`: the sender is JavaScript, so a missing `warnings`
    /// array must not fail the decode.
    enum CodingKeys: String, CodingKey {
        case score, complete, strategy, warnings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(Double.self, forKey: .score)
        score = min(max(raw, 0), 1)
        complete = try container.decode(Bool.self, forKey: .complete)
        strategy = try container.decode(ExtractionStrategy.self, forKey: .strategy)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    /// Below this the extraction is not trusted to be complete.
    static let reliable = 0.75

    var isReliable: Bool { complete && score >= Self.reliable && warnings.isEmpty }

    static func failed(_ reason: String) -> ExtractionConfidence {
        ExtractionConfidence(score: 0, complete: false, strategy: .none, warnings: [reason])
    }
}

enum ExtractionStrategy: String, Codable {
    /// Read from the page's own application state. Most faithful, most brittle.
    case state
    /// Fetched the same API the page uses, in the page's own session.
    case api
    /// Scraped the rendered DOM.
    case dom
    case none
}

/// A whole conversation, as the bridge and the core agree to represent one.
struct Conversation: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case title, source, model, url, turns, confidence
        case extractedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        source = try container.decode(ConversationSource.self, forKey: .source)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        turns = try container.decode([Turn].self, forKey: .turns)
        extractedAt = try container.decodeIfPresent(Date.self, forKey: .extractedAt) ?? Date()
        confidence = try container.decodeIfPresent(ExtractionConfidence.self, forKey: .confidence)
    }

    var title: String?
    var source: ConversationSource
    /// The model that produced the answers, when the page discloses it.
    var model: String?
    /// Canonical URL of the conversation, for frontmatter and for linking back.
    var url: URL?
    var turns: [Turn]
    /// When the page was read.
    ///
    /// Defaults to the moment of receipt when a sender omits it. Refusing the
    /// save over a missing timestamp would trade the whole conversation for one
    /// field the user never sees, and "now" is a defensible answer to "when did
    /// we get this" -- provided the extension sends it, which it now does.
    var extractedAt: Date

    /// How the extraction went. Optional because a conversation reconstructed
    /// from a file on disk has no extraction behind it.
    var confidence: ExtractionConfidence?

    init(
        title: String? = nil,
        source: ConversationSource = .webPage,
        model: String? = nil,
        url: URL? = nil,
        turns: [Turn] = [],
        extractedAt: Date = Date(),
        confidence: ExtractionConfidence? = nil
    ) {
        self.title = title
        self.source = source
        self.model = model
        self.url = url
        self.turns = turns
        self.extractedAt = extractedAt
        self.confidence = confidence
    }

    var isEmpty: Bool { turns.isEmpty }
}
