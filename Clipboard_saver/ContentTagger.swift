import Foundation

/// Derives tags from a conversation's content.
///
/// Every tag here is a fact about the text, not a guess about meaning. "Contains
/// code" can be decided by looking for a fenced block; "this is about Swift" can
/// be decided by finding the language identifier. What the tagger deliberately
/// does not do is classify by topic, because a wrong tag is worse than a missing
/// one: it shows up in a filtered view and quietly hides conversations the user
/// wanted.
enum ContentTagger {

    /// Languages recognised inside fenced code blocks.
    ///
    /// Only the ones that identify themselves by their fence tag. A fence with no
    /// tag is a code block, but nothing more precise can be claimed from it.
    static let knownLanguages: Set<String> = [
        "swift", "python", "javascript", "typescript", "jsx", "tsx", "rust", "go",
        "ruby", "java", "kotlin", "c", "cpp", "csharp", "php", "scala", "elixir",
        "haskell", "sql", "bash", "sh", "zsh", "shell", "json", "yaml", "toml",
        "html", "css", "r", "julia", "matlab", "perl", "lua", "dart", "vue", "svelte",
    ]

    /// Tags for one conversation, lowercase and deduplicated.
    static func tags(for conversation: Conversation) -> [String] {
        var tags = Set<String>()
        let all = conversation.turns.map(\.body).joined(separator: "\n")

        if !conversation.turns.isEmpty { tags.insert("conversation") }
        if containsCode(all) { tags.insert("code") }

        for language in languages(in: all) {
            tags.insert(language)
        }

        if all.contains("$") || all.contains("\\(") { tags.insert("math") }
        if all.contains("|") && containsTableRow(all) { tags.insert("table") }
        if conversation.turns.contains(where: { !$0.toolCalls.isEmpty }) { tags.insert("tools") }
        if conversation.turns.contains(where: { !($0.reasoning ?? "").isEmpty }) { tags.insert("reasoning") }
        if conversation.turns.contains(where: { ($0.body.contains("![")) }) { tags.insert("image") }

        if all.count > 20_000 { tags.insert("long") }
        return tags.sorted()
    }

    /// A fenced code block, opening or closing.
    static func containsCode(_ text: String) -> Bool {
        text.range(of: #"(?m)^[ \t]{0,3}(`{3,}|~{3,})"#, options: .regularExpression) != nil
    }

    /// Language identifiers found on opening fences.
    static func languages(in text: String) -> Set<String> {
        var found = Set<String>()
        let pattern = #"(?m)^[ \t]{0,3}(?:`{3,}|~{3,})[ \t]*([A-Za-z0-9+#_-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return found }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange]).lowercased()
            if knownLanguages.contains(name) { found.insert(name) }
        }
        return found
    }

    /// A pipe row with at least one internal pipe, which is what distinguishes a
    /// table row from prose that happens to contain a vertical bar.
    static func containsTableRow(_ text: String) -> Bool {
        let pattern = #"(?m)^[ \t]{0,3}\|.*\|.*\|"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
