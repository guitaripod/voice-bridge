// swift-tools-version:6.1
import PackageDescription

let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "voice-bridge",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoiceGatewayCore", targets: ["VoiceGatewayCore"]),
        .executable(name: "voice-bridge", targets: ["voice-bridge"]),
        .executable(name: "voice-probe", targets: ["voice-probe"]),
    ],
    dependencies: [
        .package(path: "../CodingAgentKit"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "VoiceGatewayCore",
            dependencies: [
                .product(name: "VoiceKit", package: "CodingAgentKit"),
                .product(name: "SetupKit", package: "CodingAgentKit"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "HummingbirdWSClient", package: "hummingbird-websocket"),
            ],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "voice-bridge",
            dependencies: ["VoiceGatewayCore"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "voice-probe",
            dependencies: ["VoiceGatewayCore"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "VoiceGatewayTests",
            dependencies: ["VoiceGatewayCore"],
            swiftSettings: strict
        ),
    ]
)
