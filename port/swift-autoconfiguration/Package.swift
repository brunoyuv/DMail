// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ThunderbirdAutoconfigurationPort", products: [
    .library(name: "Autoconfiguration", targets: ["Autoconfiguration"])
], targets: [
    .target(name: "CAutoconfigCrypto", publicHeadersPath: ".", linkerSettings: [.linkedLibrary("crypto")]),
    .target(name: "Autoconfiguration", dependencies: ["CAutoconfigCrypto"]),
    .testTarget(name: "AutoconfigurationTests", dependencies: ["Autoconfiguration"])
])
