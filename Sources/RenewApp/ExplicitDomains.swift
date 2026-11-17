import Foundation
import RenewShared

/// The bundled explicit-site list (`Resources/explicit-domains.txt`). renewd
/// does the flagging with its own installed copy; the app only counts the
/// list's entries, to show the preset's size in the Monitor settings. The
/// count is worked out once, off the main thread, without keeping the list.
enum ExplicitDomains {
    private static let queue = DispatchQueue(label: "agent.explicit-domains", qos: .utility)
    private static var counted: Int?
    private static var waiting: [(Int) -> Void] = []
    private static var counting = false

    /// Calls `completion` on the main thread with the number of sites in the
    /// list (0 if it can't be found).
    static func count(_ completion: @escaping (Int) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let counted { completion(counted); return }
        waiting.append(completion)
        guard !counting else { return }
        counting = true
        queue.async {
            var n = 0
            readFile()?.enumerateLines { line, _ in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty && !t.hasPrefix("#") { n += 1 }
            }
            DispatchQueue.main.async {
                counted = n
                counting = false
                let callbacks = waiting
                waiting.removeAll()
                callbacks.forEach { $0(n) }
            }
        }
    }

    /// The app bundle's copy, or the repository's for `swift run` dev runs.
    private static func readFile() -> String? {
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: "explicit-domains", withExtension: "txt") { candidates.append(u) }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Resources/explicit-domains.txt"))
        // .build/<config>/RenewApp → repository root.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent("../../../Resources/explicit-domains.txt").standardized)
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        log("explicit-site list not found in the app; its size isn't shown")
        return nil
    }
}
