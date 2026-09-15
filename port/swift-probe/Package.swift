// swift-tools-version: 6.2
import PackageDescription

// The preparation script copies these targets and tests byte-for-byte from
// the pinned upstream checkout. This reduced manifest isolates runtime
// feasibility from unrelated Apple-only modules and remote dependencies.
let package = Package(
    name: "ThunderbirdReuseProbe",
    products: [.executable(name: "upstream-probe", targets: ["Probe"])],
    targets: [
        .target(name: "EmailAddress"),
        .target(name: "MIME"),
        .executableTarget(name: "Probe", dependencies: ["EmailAddress", "MIME"]),
        .testTarget(name: "EmailAddressTests", dependencies: ["EmailAddress"]),
        .testTarget(name: "MIMETests", dependencies: ["MIME"], resources: [.process("Resources")])
    ]
)
