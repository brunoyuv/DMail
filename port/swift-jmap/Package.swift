// swift-tools-version: 6.2
import PackageDescription

// Host regression tests for the same staged JMAP source used in the HAP.
let package = Package(name: "ThunderbirdJmapUpstreamTests", targets: [
    .target(name: "EmailAddress"),
    .target(name: "CHarmonyLogging", publicHeadersPath: "."),
    .target(name: "HarmonyLogging", dependencies: ["CHarmonyLogging"]),
    .target(name: "JMAP", dependencies: ["EmailAddress", "HarmonyLogging"]),
    .testTarget(name: "JMAPTests", dependencies: ["JMAP", "EmailAddress"])
])
