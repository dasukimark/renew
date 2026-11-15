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

/// The web engine an unknown app is built on, when it looks like a full browser.
public enum BrowserEngine: String, Sendable {
    case chromium = "Chromium"
    case gecko = "Firefox"
}

/// Recognises browsers Renew has no entry for (a copy of Chrome with a new
/// bundle ID, Chrome for Testing, a Firefox fork) by what's inside the app
/// rather than by name.
///
/// Electron and CEF apps also embed Chromium but aren't browsers, so they're
/// excluded by their own markers, with `exceptions` as a backstop.
public enum EngineDetector {
    /// Apps built on a browser engine that aren't browsers. Electron and CEF
    /// apps are normally caught by their markers; these are listed in case a
    /// future version renames its framework.
    public static let exceptions: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.t3tools.t3code",
        "com.openai.codex", "com.openai.chat",
        "com.tinyspeck.slackmacgap",
        "notion.id",
        "md.obsidian",
        "com.postmanlabs.mac",
        "com.bitwarden.desktop",
        "com.spotify.client",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.hnc.Discord",
        "com.figma.Desktop",
        "com.github.GitHubClient",
        "com.microsoft.teams2",
        "org.mozilla.thunderbird", "org.mozilla.thunderbird-daily",
        "org.zotero.zotero",
    ]

    /// The engine if the app bundle at `path` looks like a Chromium or
    /// Firefox-based browser, nil for anything else.
    public static func browserEngine(bundleAt path: String, bundleID: String?) -> BrowserEngine? {
        if let id = bundleID, exceptions.contains(id) { return nil }
        let fm = FileManager.default
        let contents = path + "/Contents"

        // Gecko: Firefox and its forks ship libxul as Contents/MacOS/XUL.
        if fm.fileExists(atPath: contents + "/MacOS/XUL") || fm.fileExists(atPath: contents + "/Frameworks/XUL.framework") {
            return .gecko
        }

        let frameworks = (try? fm.contentsOfDirectory(atPath: contents + "/Frameworks")) ?? []
        if frameworks.contains("Electron Framework.framework")
            || frameworks.contains("Chromium Embedded Framework.framework") {
            return nil
        }
        if isElectron(contents: contents) { return nil }

        // Chromium browsers: "<Product> Framework.framework" with the helper
        // apps inside it (Versions/<v>/Helpers/<Product> Helper (Renderer).app).
        for fw in frameworks where fw.hasSuffix(" Framework.framework") {
            let versions = contents + "/Frameworks/" + fw + "/Versions"
            for v in (try? fm.contentsOfDirectory(atPath: versions)) ?? [] where v != "Current" {
                let helpers = (try? fm.contentsOfDirectory(atPath: versions + "/" + v + "/Helpers")) ?? []
                if helpers.contains(where: { $0.hasSuffix("(Renderer).app") }) { return .chromium }
            }
        }
        return nil
    }

    /// Electron apps with a renamed framework (e.g. Codex) still declare
    /// Electron keys in Info.plist and ship their code as app.asar. Requiring
    /// both means a copied Chrome needs more than one edit to pass as Electron.
    private static func isElectron(contents: String) -> Bool {
        let info = NSDictionary(contentsOfFile: contents + "/Info.plist") as? [String: Any] ?? [:]
        guard info.keys.contains(where: { $0.hasPrefix("Electron") }) else { return false }
        let fm = FileManager.default
        let resources = contents + "/Resources"
        return fm.fileExists(atPath: resources + "/app.asar") || fm.fileExists(atPath: resources + "/app")
    }
}
