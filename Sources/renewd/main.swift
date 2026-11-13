import Foundation
import RenewShared

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
let devMode = arguments.contains("--dev")

if !devMode && getuid() != 0 {
    FileHandle.standardError.write(Data("renewd must run as root (launchd starts it). Use --dev for local testing.\n".utf8))
    exit(1)
}

let guardInstance: Guard?
let daemonInstance: Daemon?
if arguments.contains("--guard") {
    guardInstance = Guard()
    daemonInstance = nil
    guardInstance?.run()
} else {
    guardInstance = nil
    daemonInstance = Daemon(dev: devMode)
    daemonInstance?.run()
}

dispatchMain()
