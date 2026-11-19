import Foundation

/// How the Monitor treats a site.
///
/// - `work`: never flagged, so nothing from work tools (which can hold work
///   information) reaches the Monitor log or partner reports. The list is
///   built in and can't be added to from settings. Hosts anyone can publish
///   files to without an account in your company are left out
///   (`workExceptions`).
/// - `recovery`: recovery and accountability sites (Covenant Eyes, Fortify,
///   NoFap…), whose titles talk about pornography to help people quit. The
///   built-in explicit words don't flag them; your own lists and words still
///   do.
/// - `mixed`: sites that show ordinary and adult content side by side. With
///   `MonitorSettings.flagExplicit` on they get stricter title scoring and
///   page reading (see `PageSignals`).
public enum SiteCategory: Sendable, Equatable {
    case work, recovery, mixed, other

    /// Work tools. Google is listed by exact host only: `google.com` itself
    /// would exempt Search and Images, and Drive can hold any image or video.
    /// Hosts that serve raw user files (githubusercontent.com, notion.site,
    /// OneDrive) are left off for the same reason.
    public static let workDomains: [String] = [
        "atlassian.net", "atlassian.com", "jira.com", "slack.com", "github.com", "gitlab.com", "bitbucket.org", "linear.app", "notion.so", "figma.com", "zoom.us",
        "teams.microsoft.com", "teams.live.com", "sharepoint.com", "office.com",
        "docs.google.com", "mail.google.com",
    ]

    /// Hosts under a work domain that serve personal or public files, so
    /// they're judged like any other site: gists and OneDrive for Business
    /// (`<tenant>-my.sharepoint.com`). Figma's public community pages are
    /// excluded by path in `of(url:)`.
    static func isWorkException(_ host: String) -> Bool {
        host == "gist.github.com" || host.hasSuffix("-my.sharepoint.com")
    }

    /// Recovery programs, accountability apps and support groups.
    public static let recoveryDomains: [String] = [
        "covenanteyes.com", "everaccountable.com", "accountable2you.com", "truple.io", "x3watch.com",
        "joinfortify.com", "fortifyprogram.org", "nofap.com", "rebootnation.org", "yourbrainonporn.com",
        "fightthenewdrug.org", "puredesire.org", "conquerseries.com", "settingcaptivesfree.com",
        "purelifeministries.org", "brainbuddyapp.com", "joinrelay.app", "recoverynation.com",
        "saa-recovery.org", "slaafws.org", "sa.org",
    ]

    /// Sites that mix ordinary and adult content, and alternative front ends
    /// for them. Being here only ever adds scrutiny.
    public static let mixedDomains: [String] = [
        "reddit.com", "redd.it", "x.com", "twitter.com", "youtube.com", "youtu.be", "patreon.com", "vimeo.com",
        "tumblr.com", "bsky.app", "facebook.com", "fb.com", "fb.watch", "instagram.com", "threads.net",
        "threads.com", "tiktok.com", "pixiv.net", "deviantart.com", "imgur.com", "twitch.tv", "9gag.com",
        "4chan.org", "4channel.org",
        // Reddit front ends
        "safereddit.com", "teddit.net", "redlib.catsarch.com", "libreddit.kavin.rocks", "l.opnxng.com",
        // X front ends
        "xcancel.com", "nitter.net", "nitter.poast.org", "nitter.privacydev.net",
        // YouTube front ends
        "yewtu.be", "inv.nadeko.net", "invidious.nerdvpn.de", "piped.video", "piped.kavin.rocks",
    ]

    /// Front-end software usually runs on hosts named after it
    /// ("redlib.example.org"), so those count as mixed too.
    public static let mixedHostPrefixes: [String] = [
        "redlib", "libreddit", "teddit", "nitter", "invidious", "piped",
    ]

    private static let workSet = DomainSet(workDomains)
    private static let mixedSet = DomainSet(mixedDomains)
    private static let recoverySet = DomainSet(recoveryDomains)

    /// The category of `host` (subdomains included). Work wins, then recovery, then mixed.
    public static func of(host: String) -> SiteCategory {
        let h = Rule.normalizeHost(host)
        if workSet.match(host: h) != nil, !isWorkException(h) { return .work }
        if recoverySet.match(host: h) != nil { return .recovery }
        if mixedSet.match(host: h) != nil { return .mixed }
        if let first = h.split(separator: ".").first, h.contains("."),
           mixedHostPrefixes.contains(where: { first == $0 || first.hasPrefix($0 + "-") }) {
            return .mixed
        }
        return .other
    }

    /// The category of a page address, or `other` if it has no host.
    public static func of(url: String) -> SiteCategory {
        guard let u = NormalizedURL(url) else { return .other }
        let c = of(host: u.host)
        if c == .work, u.host == "figma.com" || u.host.hasSuffix(".figma.com"),
           u.path.lowercased().hasPrefix("/community") {
            return .other
        }
        return c
    }
}

/// Whether an address is a single post rather than a feed.
public enum PostURL {
    /// Path segments that mark a single post, video or work on mixed sites,
    /// when an id follows them (`/status/123`). Without one they're usually a
    /// list of posts (`/@someone/videos`, `/someone/posts`).
    static let markers: Set<String> = ["comments", "status", "post", "posts", "artworks", "shorts",
                                       "video", "videos", "reel", "reels", "art", "photo"]
    /// Segments followed by a name, not a post: a marker after one of these
    /// is a subreddit, user or channel called "videos", "art"…
    static let nameSlots: Set<String> = ["r", "u", "user", "c", "channel", "tagged", "tag", "tags",
                                         "search", "hashtag", "explore"]
    /// Short-link hosts where any path is one post.
    static let shortLinks: Set<String> = ["youtu.be", "redd.it"]

    public static func isSinglePost(_ url: String) -> Bool {
        guard let u = NormalizedURL(url) else { return false }
        let segments = u.path.lowercased().split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return false }
        if shortLinks.contains(u.host) { return true }
        // youtube.com/watch?v=… (and front ends); facebook.com/watch alone is a feed.
        if segments[0] == "watch" { return segments.count > 1 || url.lowercased().contains("v=") }
        for (i, seg) in segments.enumerated().dropLast() where markers.contains(seg) {
            if i > 0, nameSlots.contains(segments[i - 1]) { continue }
            return true
        }
        if u.host.hasSuffix("instagram.com"), segments.first == "p" { return true }
        // vimeo.com/123, tumblr.com/blog/123
        if u.host.hasSuffix("vimeo.com") || u.host.hasSuffix("tumblr.com") {
            return segments.contains { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        }
        return false
    }
}
