import Foundation

/// Named blocklists (shared by the app and the CLI) in ~/.config/renew/lists.json, on top of built-ins.
public enum ListStore {
    public static let builtIn: [String: [String]] = [
        "test": ["youtube.com/shorts", "reddit.com"],
        "social": [
            "facebook.com", "instagram.com", "x.com", "twitter.com", "tiktok.com", "reddit.com",
            "threads.net", "threads.com", "snapchat.com", "bsky.app", "linkedin.com/feed",
        ],
        "video": [
            "youtube.com", "netflix.com", "twitch.tv", "hulu.com", "disneyplus.com",
            "primevideo.com", "max.com", "!music.youtube.com",
        ],
        "news": [
            "news.ycombinator.com", "cnn.com", "foxnews.com", "nytimes.com", "bbc.com",
            "theverge.com", "news.google.com",
        ],
    ]

    private struct File: Codable { var lists: [String: [String]] }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/renew/lists.json")
    }

    public static func userLists() -> [String: [String]] {
        guard let data = try? Data(contentsOf: fileURL),
              let f = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        return f.lists
    }

    public static func all() -> [String: [String]] {
        builtIn.merging(userLists()) { _, user in user }
    }

    public static func get(_ name: String) -> [String]? { all()[name.lowercased()] }

    public static func save(_ lists: [String: [String]]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(File(lists: lists)).write(to: fileURL, options: .atomic)
    }

    public static func add(_ name: String, _ rules: [String]) throws -> [String] {
        let key = name.lowercased()
        var lists = userLists()
        let existing = lists[key] ?? builtIn[key] ?? []
        let (valid, _) = canonicalRules(existing + rules)
        lists[key] = valid
        try save(lists)
        return valid
    }

    /// Removes rules from a list, or the whole user list if `rules` is empty.
    public static func remove(_ name: String, _ rules: [String]) throws -> [String]? {
        let key = name.lowercased()
        var lists = userLists()
        if rules.isEmpty {
            lists[key] = nil
            try save(lists)
            return builtIn[key]
        }
        let drop = Set(canonicalRules(rules).valid)
        let remaining = (lists[key] ?? builtIn[key] ?? []).filter { !drop.contains(Rule.parse($0)?.description ?? $0) }
        lists[key] = remaining
        try save(lists)
        return remaining
    }

    /// Replaces a list's rules (creating it if needed).
    public static func set(_ name: String, _ rules: [String]) throws {
        var lists = userLists()
        lists[name.lowercased()] = canonicalRules(rules).valid
        try save(lists)
    }

    /// Deletes a custom list, or resets a built-in one to its defaults.
    public static func delete(_ name: String) throws {
        var lists = userLists()
        lists[name.lowercased()] = nil
        try save(lists)
    }

    public static func isBuiltIn(_ name: String) -> Bool { builtIn[name.lowercased()] != nil }

    public static func isCustomized(_ name: String) -> Bool {
        let key = name.lowercased()
        guard let user = userLists()[key] else { return false }
        return builtIn[key] != nil && builtIn[key] != user
    }
}
