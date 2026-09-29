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

    init(
        role: TurnRole,
        body: String,
        timestamp: Date? = nil,
        reasoning: String? = nil,
        toolCalls: [ToolCall] = []
    ) {
        self.role = role
        self.body = body
        self.timestamp = timestamp
        self.reasoning = reasoning
        self.toolCalls = toolCalls
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
    var title: String?
    var source: ConversationSource
    /// The model that produced the answers, when the page discloses it.
    var model: String?
    /// Canonical URL of the conversation, for frontmatter and for linking back.
    var url: URL?
    var turns: [Turn]
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
