// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Renew",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "renewd", targets: ["renewd"]),
        .executable(name: "renew", targets: ["renew"]),
        .executable(name: "RenewApp", targets: ["RenewApp"]),
    ],
    targets: [
        .target(name: "RenewShared"),
        .executableTarget(name: "renewd", dependencies: ["RenewShared"]),
        .executableTarget(name: "renew", dependencies: ["RenewShared"]),
        // Built as "RenewApp" (a "Renew" binary would collide with the "renew" CLI
        // on a case-insensitive disk); build.sh installs it as Renew.app/Contents/MacOS/Renew.
        .executableTarget(name: "RenewApp", dependencies: ["RenewShared"]),
        .testTarget(name: "RenewSharedTests", dependencies: ["RenewShared"]),
    ],
    swiftLanguageModes: [.v5]
)
