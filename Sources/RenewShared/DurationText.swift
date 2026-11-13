import Foundation

public enum DurationText {
    /// Longest duration accepted anywhere (the daemon caps sessions lower).
    public static let maxSeconds = 365 * 86_400

    /// Parses "90m", "2h", "1h30m", "45s", "1d", or a bare number of minutes.
    /// Returns nil for anything malformed, zero, or longer than `maxSeconds`
    /// (including values that would overflow).
    public static func parse(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty, s.count <= 32 else { return nil }
        if s.allSatisfy(\.isNumber) {
            guard let minutes = Int(s) else { return nil }
            return checked(minutes, times: 60, plus: 0)
        }

        var total = 0
        var number = ""
        var sawUnit = false
        for ch in s {
            if ch.isNumber {
                number.append(ch)
                continue
            }
            guard let n = Int(number) else { return nil }
            let unit: Int
            switch ch {
            case "d": unit = 86_400
            case "h": unit = 3_600
            case "m": unit = 60
            case "s": unit = 1
            default: return nil
            }
            guard let next = checked(n, times: unit, plus: total) else { return nil }
            total = next
            number = ""
            sawUnit = true
        }
        guard number.isEmpty, sawUnit, total > 0 else { return nil }
        return total
    }

    /// `a * b + c`, or nil on overflow, non-positive result, or past `maxSeconds`.
    private static func checked(_ a: Int, times b: Int, plus c: Int) -> Int? {
        let (product, o1) = a.multipliedReportingOverflow(by: b)
        guard !o1 else { return nil }
        let (sum, o2) = product.addingReportingOverflow(c)
        guard !o2, sum > 0, sum <= maxSeconds else { return nil }
        return sum
    }

    /// "2h 05m", "14m 03s", "45s".
    public static func format(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60, sec = s % 60
        if d > 0 { return String(format: "%dd %02dh %02dm", d, h, m) }
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return "\(sec)s"
    }
}
