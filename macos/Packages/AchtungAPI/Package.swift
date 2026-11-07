// swift-tools-version: 6.4
import PackageDescription

// The server API client. swift-openapi-generator's build plugin generates it from
// Sources/AchtungAPI/openapi.yaml (a symlink to api/openapi.yaml), so no generated code
// is committed. No UI imports, so it builds and tests on Linux (CI enforces it).
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "AchtungAPI",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "AchtungAPI", targets: ["AchtungAPI"])
    ],
    dependencies: [
        .package(path: "../AchtungDomain"),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.14.4"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.4"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.8.0"),
    ],
    targets: [
        .target(
            name: "AchtungAPI",
            dependencies: [
                "AchtungDomain",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: strict,
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        .testTarget(
            name: "AchtungAPITests",
            dependencies: [
                "AchtungAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
