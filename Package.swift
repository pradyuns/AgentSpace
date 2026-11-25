// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentSpace",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentSpaceCore", targets: ["AgentSpaceCore"]),
        .executable(name: "agentspace", targets: ["agentspace"]),
        .executable(name: "agentspace-display-host", targets: ["agentspace-display-host"]),
        .executable(name: "agentspace-session-broker", targets: ["agentspace-session-broker"]),
        .executable(name: "HumanPad", targets: ["HumanPad"]),
        .executable(name: "agentspace-eval", targets: ["agentspace-eval"]),
        .executable(name: "agentspace-regression", targets: ["agentspace-regression"])
    ],
    targets: [
        .target(name: "ASDisplayShim"),
        .target(name: "AgentSpaceCore", dependencies: ["ASDisplayShim"]),
        .executableTarget(name: "agentspace", dependencies: ["AgentSpaceCore"]),
        .executableTarget(name: "agentspace-display-host", dependencies: ["AgentSpaceCore", "ASDisplayShim"]),
        .executableTarget(name: "agentspace-session-broker", dependencies: ["AgentSpaceCore"]),
        .executableTarget(name: "agentspace-regression", dependencies: ["AgentSpaceCore", "ASDisplayShim"]),
        .testTarget(name: "AgentSpaceCoreTests", dependencies: ["AgentSpaceCore"]),
        .target(name: "AgentSpaceEvalSupport", dependencies: ["AgentSpaceCore"]),
        .executableTarget(name: "HumanPad", dependencies: ["AgentSpaceEvalSupport"]),
        .executableTarget(name: "agentspace-eval", dependencies: ["AgentSpaceCore", "AgentSpaceEvalSupport"]),
        .testTarget(name: "AgentSpaceEvalSupportTests", dependencies: ["AgentSpaceEvalSupport"])
    ]
)
