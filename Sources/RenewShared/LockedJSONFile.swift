import Foundation

/// A JSON value kept in a file that's read, changed and written under an
/// exclusive lock (on a separate lock file, since writes replace the file
/// atomically). A file that can't be read is kept aside, not silently
/// emptied. Used for renewd's root-only outbox and partner log.
public struct LockedJSONFile<Value: Codable & Equatable> {
    public let path: String
    /// Names the file in log lines.
    let label: String
    /// The value when there's no file yet.
    let empty: Value

    public init(path: String, label: String, empty: Value) {
        self.path = path
        self.label = label
        self.empty = empty
    }

    @discardableResult
    public func update(_ change: (Value) -> Value) -> Value {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else {
            log("\(label): can't open \(path).lock: \(String(cString: strerror(errno)))")
            return change(empty)
        }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }

        var current = empty
        if let data = fm.contents(atPath: path), !data.isEmpty {
            if let value = try? Report.decoder.decode(Value.self, from: data) {
                current = value
            } else {
                let aside = path + ".unreadable-\(Int(Date().timeIntervalSince1970))"
                try? fm.moveItem(atPath: path, toPath: aside)
                log("\(label): couldn't read \(path); kept it as \(aside) and started a new one")
            }
        }
        let updated = change(current)
        guard updated != current else { return updated }
        guard let out = try? Report.encoder.encode(updated) else { return current }
        let tmp = path + ".tmp"
        guard fm.createFile(atPath: tmp, contents: out, attributes: [.posixPermissions: 0o600]),
              rename(tmp, path) == 0 else {
            log("\(label): couldn't save \(path): \(String(cString: strerror(errno)))")
            return current
        }
        return updated
    }

    /// Reads the value under a shared lock, without creating anything or
    /// moving an unreadable file aside (the next `update` does that).
    public func load() -> Value {
        let lock = open(path + ".lock", O_RDONLY)
        if lock >= 0 { flock(lock, LOCK_SH) }
        defer {
            if lock >= 0 {
                flock(lock, LOCK_UN)
                close(lock)
            }
        }
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty,
              let value = try? Report.decoder.decode(Value.self, from: data) else { return empty }
        return value
    }
}
