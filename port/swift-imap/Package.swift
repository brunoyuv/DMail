// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ThunderbirdIMAPPort", products: [.library(name: "IMAP", targets: ["IMAP"])],
    dependencies: [
        .package(path: "../../../imap-dependencies/swift-nio-imap"),
        .package(path: "../../../imap-dependencies/swift-nio"),
        .package(path: "../../../imap-dependencies/swift-nio-ssl")
    ], targets: [
        .target(name: "IMAP", dependencies: ["EmailAddress", "MIME", "HarmonyLogging",
            .product(name: "NIOIMAP", package: "swift-nio-imap"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIO", package: "swift-nio")]),
        .target(name: "SMTP", dependencies: ["EmailAddress", "MIME", "HarmonyLogging",
            .product(name: "NIO", package: "swift-nio"), .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl")]),
        .target(name: "EmailAddress"), .target(name: "MIME"),
        .target(name: "HarmonyLogging"),
        .testTarget(name: "SMTPTests", dependencies: ["SMTP", .product(name: "NIO", package: "swift-nio")]),
        .testTarget(name: "IMAPTests", dependencies: ["IMAP"])
    ])
