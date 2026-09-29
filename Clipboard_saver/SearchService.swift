import Foundation

/// Turns a query into something worth reading.
///
/// The output is Markdown, because the caller pastes it somewhere that renders
/// Markdown, and because the point of the service is to hand the user something
/// they can act on rather than a list they have to interpret.
enum SearchService {

    struct Result {
        var query: String
        var hits: [SearchHit]
        var totalMessages: Int
        var totalDocuments: Int
        var scannedFolder: URL?
        var error: String?

        var isEmpty: Bool { hits.isEmpty && error == nil }

        /// Renders results for display. Capped, because a Services-menu result
        /// that scrolls for four screens is not a result.
        func markdown(limit: Int = 10) -> String {
            if let error {
                return "**Archive search failed**\n\n\(error)"
            }
            if hits.isEmpty {
                var out = "No archived messages match **\(query)**."
                if let scannedFolder {
                    out += "\n\nIndexed folder: `\(scannedFolder.path)`"
                }
                return out
            }

            var out = "**\(hits.count)** match\(hits.count == 1 ? "" : "es") for *\(query)*\n\n"

            for (index, hit) in hits.prefix(limit).enumerated() {
                let name = URL(fileURLWithPath: hit.path).deletingPathExtension().lastPathComponent
                out += "\(index + 1). `\(name)` — \(hit.role), turn \(hit.turn + 1)\n"
                let snippet = hit.snippet
                    .replacingOccurrences(of: "<<", with: "**")
                    .replacingOccurrences(of: ">>", with: "**")
                out += "   \(snippet)\n"
            }

            if hits.count > limit {
                out += "\n_\(hits.count - limit) more not shown._\n"
            }
            out += "\n\(totalMessages) messages across \(totalDocuments) documents indexed."
            return out
        }
    }

    /// Searches every configured archive folder.
    ///
    /// The index is refreshed first, on the theory that a search is the one
    /// moment a stale index is guaranteed to be noticed and be the user's
    /// problem.
    static func search(
        _ query: String,
        folders: [URL],
        limit: Int = 50,
        refresh: Bool = true
    ) -> Result {
        var result = Result(query: query, hits: [], totalMessages: 0, totalDocuments: 0, scannedFolder: nil, error: nil)

        do {
            let store = try ArchiveStore()
            let indexer = ArchiveIndexer(store: store)

            for folder in folders {
                guard FileManager.default.fileExists(atPath: folder.path) else { continue }
                result.scannedFolder = folder
                if refresh {
                    _ = try indexer.indexFolder(folder)
                }
            }

            result.totalDocuments = try store.documentCount()
            result.totalMessages = try store.messageCount()
            result.hits = try store.search(query, limit: limit)
        } catch {
            result.error = "\(error)"
        }

        return result
    }

    /// The folders to search, from user defaults.
    ///
    /// Defaults to `~/Documents/Conversations` — a plausible location that may
    /// not exist, in which case the folder check skips it and the search runs
    /// against whatever else is configured. Creating a folder the user never
    /// asked for would be worse than finding nothing.
    static func folders(fromDefaults defaults: UserDefaults = .standard) -> [URL] {
        if let configured = defaults.stringArray(forKey: "archiveFolders"), !configured.isEmpty {
            return configured.map { URL(fileURLWithPath: $0) }
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let documents else { return [] }
        return [documents.appendingPathComponent("Conversations", isDirectory: true)]
    }
}
