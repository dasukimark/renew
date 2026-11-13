import Foundation

/// What the daemon persists in the root-only state.json.
public struct PersistedState: Codable, Equatable, Sendable {
    public var session: SessionInfo?

    public init(session: SessionInfo? = nil) {
        self.session = session
    }

    public var activeSession: SessionInfo? {
        guard let s = session, s.isActive() else { return nil }
        return s
    }
}

public enum StateStore {
    public static func load() -> PersistedState? {
        guard let data = FileManager.default.contents(atPath: Paths.stateFile) else { return nil }
        return try? Wire.decoder.decode(PersistedState.self, from: data)
    }

    public static func save(_ state: PersistedState) {
        do {
            try FileManager.default.createDirectory(atPath: Paths.dataDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try Wire.encoder.encode(state)
            let tmp = Paths.stateFile + ".tmp"
            FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
            if rename(tmp, Paths.stateFile) != 0 {
                log("state rename failed: \(String(cString: strerror(errno)))")
            }
        } catch {
            log("state save failed: \(error)")
        }
    }
}
