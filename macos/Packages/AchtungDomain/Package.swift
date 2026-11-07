// swift-tools-version: 6.4
import PackageDescription

// The alert model. No UI imports, so it builds and tests on Linux (CI enforces it).
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "AchtungDomain",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "AchtungDomain", targets: ["AchtungDomain"])
    ],
    targets: [
        .target(name: "AchtungDomain", swiftSettings: strict),
        .testTarget(
            name: "AchtungDomainTests",
            dependencies: ["AchtungDomain"],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
