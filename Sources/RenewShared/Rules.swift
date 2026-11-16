import Foundation

/// One blocking rule.
///
/// Syntax accepted by `Rule.parse`:
///   reddit.com            block the domain and all subdomains
///   youtube.com/shorts    block a path prefix on a domain
///   keyword:casino        block any URL containing the word
///   !music.youtube.com    allow exception (also `allow:music.youtube.com`)
public struct Rule: Hashable, Codable, CustomStringConvertible, Sendable {
    public enum Kind: String, Codable, Sendable { case block, allow, keyword }

    public let kind: Kind
    public let host: String
    public let path: String
    public let keyword: String

    public var description: String {
        switch kind {
        case .block: return host + path
        case .allow: return "!" + host + path
        case .keyword: return "keyword:" + keyword
        }
    }

    public static func parse(_ raw: String) -> Rule? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, s.count <= 512 else { return nil }

        if s.hasPrefix("keyword:") {
            let kw = String(s.dropFirst("keyword:".count)).trimmingCharacters(in: .whitespaces)
            guard !kw.isEmpty else { return nil }
            return Rule(kind: .keyword, host: "", path: "", keyword: kw)
        }

        var kind = Kind.block
        if s.hasPrefix("!") {
            kind = .allow
            s.removeFirst()
        } else if s.hasPrefix("allow:") {
            kind = .allow
            s.removeFirst("allow:".count)
        }

        if let schemeEnd = s.range(of: "://") {
            s = String(s[schemeEnd.upperBound...])
        }
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            s = String(s[..<cut])
        }

        var hostPart = s
        var pathPart = ""
        if let slash = s.firstIndex(of: "/") {
            hostPart = String(s[..<slash])
            pathPart = String(s[slash...])
        }
        if let colon = hostPart.firstIndex(of: ":") {
            hostPart = String(hostPart[..<colon])
        }
        hostPart = normalizeHost(hostPart)
        if hostPart.hasPrefix("*.") { hostPart.removeFirst(2) }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard hostPart.contains("."),
              !hostPart.hasPrefix("."),
              hostPart.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return nil }

        while pathPart.hasSuffix("/") { pathPart.removeLast() }
        return Rule(kind: kind, host: hostPart, path: pathPart, keyword: "")
    }

    static func normalizeHost(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    func matches(_ url: NormalizedURL) -> Bool {
        switch kind {
        case .keyword:
            return url.searchable.contains(keyword)
        case .block, .allow:
            let hostOK = url.host == host || url.host.hasSuffix("." + host)
            guard hostOK else { return false }
            if path.isEmpty { return true }
            return url.path == path || url.path.hasPrefix(path + "/")
        }
    }
}

/// A URL reduced to the pieces rules care about.
public struct NormalizedURL: Equatable, Sendable {
    public let host: String
    public let path: String
    /// Lowercased, percent-decoded host + path + query, used for keyword rules.
    public let searchable: String

    /// Returns nil for anything that isn't a web page we should police:
    /// non-http schemes, search terms typed into an address bar, and
    /// Renew's own block page on localhost.
    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if let schemeEnd = s.range(of: "://") {
            let scheme = s[..<schemeEnd.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
        } else if s.contains(":") && !s.contains(".") {
            return nil // about:blank, chrome:newtab, etc.
        } else {
            s = "http://" + s
        }
        guard let comps = URLComponents(string: s), let rawHost = comps.host, !rawHost.isEmpty else {
            return nil
        }
        let host = Rule.normalizeHost(rawHost)
        if host == "127.0.0.1" || host == "localhost" || host == "::1" { return nil }
        guard host.contains(".") else { return nil }

        var path = comps.percentEncodedPath.lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        self.host = host
        self.path = path

        var full = host + path
        if let q = comps.percentEncodedQuery { full += "?" + q.lowercased() }
        self.searchable = full.removingPercentEncoding ?? full
    }
}

/// Parsed rules, ready for matching.
public struct RuleSet: Sendable {
    public let rules: [Rule]
    private let blocks: [Rule]
    private let allows: [Rule]

    public init(_ rules: [Rule]) {
        self.rules = rules
        self.blocks = rules.filter { $0.kind != .allow }
        self.allows = rules.filter { $0.kind == .allow }
    }

    public init(strings: [String]) {
        self.init(strings.compactMap(Rule.parse))
    }

    public var isEmpty: Bool { blocks.isEmpty }

    /// The rule that blocks `url`, or nil if the URL is allowed.
    /// Allow exceptions always win over block rules.
    public func match(_ url: String) -> Rule? {
        guard let n = NormalizedURL(url) else { return nil }
        if allows.contains(where: { $0.matches(n) }) { return nil }
        return blocks.first(where: { $0.matches(n) })
    }
}

/// Canonicalise, de-duplicate and validate rule strings. Returns (valid, rejected).
public func canonicalRules(_ raw: [String]) -> (valid: [String], rejected: [String]) {
    var seen = Set<String>()
    var valid: [String] = []
    var rejected: [String] = []
    for r in raw {
        if let rule = Rule.parse(r) {
            if seen.insert(rule.description).inserted { valid.append(rule.description) }
        } else {
            rejected.append(r)
        }
    }
    return (valid, rejected)
}

/// Splits typed sites on commas, spaces, tabs and newlines.
public func parseSites(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
}
