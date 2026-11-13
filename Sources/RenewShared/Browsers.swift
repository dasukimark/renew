import Foundation

public enum BrowserKind: Sendable {
    /// Scriptable with `URL of current tab of front window`.
    case safari
    /// Scriptable with `URL of active tab of front window`.
    case chromium
    /// No AppleScript; read through the Accessibility API.
    case firefox
    /// A browser Renew can't watch. Quit during a session.
    case unsupported
}

public enum BrowserCatalog {
    public static let safari: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    public static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "company.thebrowser.Browser", // Arc
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium",
    ]

    public static let firefox: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
    ]

    public static let unsupported: Set<String> = [
        "com.operasoftware.Opera", "com.operasoftware.OperaGX", "com.operasoftware.OperaNext",
        "com.kagi.kagimacOS", // Orion
        "app.zen-browser.zen",
        "org.torproject.torbrowser",
        "com.duckduckgo.macos.browser",
        "com.sigmaos.sigmaos.macos",
        "net.waterfox.waterfox",
        "io.gitlab.librewolf-community", "org.mozilla.librewolf",
        "com.naver.Whale",
        "ru.yandex.desktop.yandex-browser",
        "com.pushplaylabs.sidekick",
        "com.ghostbrowser.gb1",
        "company.thebrowser.dia", // Dia
        "ai.perplexity.comet",
        "com.openai.atlas",
        "org.mozilla.floorp", "one.ablaze.floorp",
        "com.mighty.app",
        "com.maxthon.mac.Maxthon",
    ]

    /// Web apps and site-specific browsers get their own bundle IDs derived from
    /// the parent browser (Safari "Add to Dock", Chrome/Edge/Brave installed web
    /// apps). Renew can't read their URL, so they count as unsupported.
    public static let webAppPrefixes: [String] = [
        "com.apple.Safari.WebApp.",
        "com.google.Chrome.app.", "com.google.Chrome.beta.app.", "com.google.Chrome.dev.app.", "com.google.Chrome.canary.app.",
        "com.microsoft.edgemac.app.", "com.microsoft.edgemac.Beta.app.", "com.microsoft.edgemac.Dev.app.", "com.microsoft.edgemac.Canary.app.",
        "com.brave.Browser.app.", "com.brave.Browser.beta.app.", "com.brave.Browser.nightly.app.",
        "com.vivaldi.Vivaldi.app.",
        "org.chromium.Chromium.app.",
        "company.thebrowser.Browser.app.",
        "com.operasoftware.Opera.app.",
    ]

    public static func kind(of bundleID: String?) -> BrowserKind? {
        guard let id = bundleID else { return nil }
        if safari.contains(id) { return .safari }
        if chromium.contains(id) { return .chromium }
        if firefox.contains(id) { return .firefox }
        if unsupported.contains(id) { return .unsupported }
        // Only the explicit web-app patterns: a broader "starts with the browser's
        // ID" rule would also match the browsers' own helper processes
        // (com.google.Chrome.helper.renderer, …).
        if webAppPrefixes.contains(where: { id.hasPrefix($0) }) { return .unsupported }
        return nil
    }
}
