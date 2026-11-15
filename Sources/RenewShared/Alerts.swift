import Foundation
import SystemConfiguration

/// Tamper alerts for an accountability partner: a short message POSTed to a
/// URL. This is the only thing Renew sends off the Mac.
///
/// - ntfy (`https://ntfy.sh/<topic>`, free, no account): the partner
///   subscribes to the topic in the ntfy app. Any other URL gets the same
///   plain-text POST with ntfy's Title/Priority/Tags headers.
/// - Discord and Slack incoming webhooks get the JSON they expect.
public enum Alerts {
    /// A usable destination, trimmed, or nil.
    public static func normalize(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 2_048, let u = URL(string: t), let scheme = u.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = u.host, !host.isEmpty
        else { return nil }
        return t
    }

    public static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "a Mac"
    }

    /// Sends one alert. Does nothing without a destination.
    ///
    /// `kind` and `minInterval` rate-limit repeats across every Renew process
    /// (daemon, guard, CLI), so a restart or a burst of tampering sends one
    /// message, not ten. `wait` blocks until it's sent or times out, for use
    /// right before the process exits.
    public static func send(to url: String?, _ message: String, kind: String? = nil,
                            minInterval: TimeInterval = 0, wait: Bool = false) {
        guard let url, let request = makeRequest(url, title: "Renew on \(macName)", message: message) else { return }
        if let kind, minInterval > 0, !claim(kind, for: minInterval) {
            log("alert '\(kind)' suppressed (sent recently)")
            return
        }
        log("sending alert\(kind.map { " '\($0)'" } ?? ""): \(message)")
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, response, error in
            if let error {
                log("alert failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log("alert failed: HTTP \(http.statusCode)")
            }
            done.signal()
        }.resume()
        if wait { _ = done.wait(timeout: .now() + 8) }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        return URLSession(configuration: c)
    }()

    static func makeRequest(_ urlString: String, title: String, message: String) -> URLRequest? {
        guard let url = URL(string: urlString) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        let host = url.host?.lowercased() ?? ""
        let json: [String: String]?
        if host.hasSuffix("discord.com") || host.hasSuffix("discordapp.com") {
            json = ["content": "**\(title)**\n\(message)"]
        } else if host == "hooks.slack.com" {
            json = ["text": "*\(title)*\n\(message)"]
        } else {
            json = nil
        }
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: json)
        } else {
            r.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            r.setValue(asciiHeader(title), forHTTPHeaderField: "Title")
            r.setValue("high", forHTTPHeaderField: "Priority")
            r.setValue("warning", forHTTPHeaderField: "Tags")
            r.httpBody = Data(message.utf8)
        }
        return r
    }

    /// HTTP header values must be ASCII ("Mark’s MacBook" → "Mark's MacBook").
    static func asciiHeader(_ s: String) -> String {
        let folded = s.replacingOccurrences(of: "’", with: "'")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 }.map(Character.init))
    }

    // MARK: rate limit

    private static var sentFile: String { Paths.dataDir + "/alerts-sent.json" }

    /// Records that `kind` is being sent unless it already was within
    /// `interval`. Clock-proof, like sessions. Fails open if the record
    /// can't be written (a missed rate limit beats a missed alert).
    private static func claim(_ kind: String, for interval: TimeInterval) -> Bool {
        let fd = open(sentFile, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = handle.readDataToEndOfFile()
        var sent = (try? Wire.decoder.decode([String: Countdown].self, from: data)) ?? [:]
        let now = ClockReading.now()
        if let quiet = sent[kind], quiet.remaining(at: now) > 0 { return false }
        sent[kind] = Countdown(remaining: interval, at: now)
        sent = sent.filter { $0.value.remaining(at: now) > 0 }
        guard let out = try? Wire.encoder.encode(sent) else { return true }
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        handle.write(out)
        return true
    }
}
