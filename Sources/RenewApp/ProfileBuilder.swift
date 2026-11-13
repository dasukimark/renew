import Foundation

/// Builds Renew.mobileconfig: removal password, background-items lock,
/// and browser policies that turn off private windows.
enum ProfileBuilder {
    static func randomPassword(length: Int = 20) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }

    static func build(password: String) throws -> Data {
        func payload(_ type: String, _ ident: String, _ name: String, _ content: [String: Any]) -> [String: Any] {
            var p: [String: Any] = [
                "PayloadType": type,
                "PayloadIdentifier": "com.renew.profile.\(ident)",
                "PayloadUUID": UUID().uuidString,
                "PayloadVersion": 1,
                "PayloadDisplayName": name,
            ]
            p.merge(content) { _, new in new }
            return p
        }
        let chromium: [String: Any] = ["IncognitoModeAvailability": 1]
        var brave = chromium
        brave["TorDisabled"] = true

        let payloads: [[String: Any]] = [
            payload("com.apple.profileRemovalPassword", "removal-password", "Removal password",
                    ["RemovalPassword": password]),
            payload("com.apple.servicemanagement", "login-items", "Renew background items", [
                "Rules": [
                    ["RuleType": "LabelPrefix", "RuleValue": "com.renew.", "Comment": "Renew services"],
                    ["RuleType": "BundleIdentifier", "RuleValue": "com.renew.app", "Comment": "Renew app"],
                ],
            ]),
            payload("com.google.Chrome", "chrome", "Google Chrome", chromium),
            payload("com.brave.Browser", "brave", "Brave", brave),
            payload("com.vivaldi.Vivaldi", "vivaldi", "Vivaldi", chromium),
            payload("org.chromium.Chromium", "chromium", "Chromium", chromium),
            payload("com.microsoft.Edge", "edge", "Microsoft Edge",
                    ["InPrivateModeAvailability": 1]),
            payload("org.mozilla.firefox", "firefox", "Firefox", [
                "EnterprisePoliciesEnabled": true,
                "DisablePrivateBrowsing": true,
            ]),
        ]

        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.renew.profile",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "Renew",
            "PayloadDescription": "Keeps Renew running and turns off private browsing. Removing it requires the removal password.",
            "PayloadOrganization": "Renew",
            "PayloadScope": "System",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": payloads,
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// Writes the profile to ~/Downloads and returns its URL.
    static func write(password: String) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = downloads.appendingPathComponent("Renew.mobileconfig")
        try build(password: password).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
