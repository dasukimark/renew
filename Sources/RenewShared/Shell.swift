import Foundation

public struct ShellResult {
    public let status: Int32
    public let out: String
    public let err: String
    public var ok: Bool { status == 0 }
}

/// Runs a binary (no shell interpolation) and collects its output.
@discardableResult
public func shell(_ path: String, _ args: [String]) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    p.standardInput = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        return ShellResult(status: -1, out: "", err: String(describing: error))
    }
    // Drain stderr concurrently so neither pipe can fill and deadlock.
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    p.waitUntilExit()
    return ShellResult(
        status: p.terminationStatus,
        out: String(decoding: outData, as: UTF8.self),
        err: String(decoding: errData, as: UTF8.self)
    )
}

public enum Launchctl {
    public static func isLoaded(_ serviceTarget: String) -> Bool {
        shell("/bin/launchctl", ["print", serviceTarget]).ok
    }

    @discardableResult
    public static func bootstrap(domain: String, plist: String) -> ShellResult {
        shell("/bin/launchctl", ["bootstrap", domain, plist])
    }

    @discardableResult
    public static func bootout(_ serviceTarget: String) -> ShellResult {
        shell("/bin/launchctl", ["bootout", serviceTarget])
    }

    @discardableResult
    public static func kickstart(_ serviceTarget: String) -> ShellResult {
        shell("/bin/launchctl", ["kickstart", "-k", serviceTarget])
    }
}

public func log(_ message: String) {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    FileHandle.standardOutput.write(Data("[\(f.string(from: Date()))] \(message)\n".utf8))
}
