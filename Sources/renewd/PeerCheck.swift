import Foundation
import Security

/// Checks which program is on the other end of the control socket, by its
/// code signature. Used for the few requests only the Renew app should
/// send (a script must not be able to say the Mac is shutting down).
enum PeerCheck {
    /// The connected process's audit token, from the kernel.
    static func auditToken(of socket: Int32) -> Data? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    /// renewd's own Team ID, or nil if it isn't signed by a team (a local
    /// unsigned build).
    static let ownTeam: String? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// Whether `token` belongs to the Renew app, signed by the same team as
    /// renewd. Without a team (unsigned builds), the app's installed path
    /// is checked instead.
    static func isRenewApp(_ token: Data?, appPath: String) -> Bool {
        guard let token else { return false }
        var code: SecCode?
        let attrs = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        if let team = ownTeam {
            let text = "identifier \"com.renew.app\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
            else { return false }
            return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
        var staticCode: SecStaticCode?
        var url: CFURL?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let path = (url as URL?)?.path
        else { return false }
        return path == appPath
    }
}
