import Foundation
import SystemConfiguration

/// The user currently logged in at the GUI, or nil at the login window.
func consoleUser() -> (name: String, uid: uid_t)? {
    var uid: uid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
          !name.isEmpty, name != "loginwindow", uid != 0
    else { return nil }
    return (name, uid)
}
