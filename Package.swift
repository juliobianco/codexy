// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Codexy",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CodexyCore"),
        .executableTarget(name: "CodexyUsage", dependencies: ["CodexyCore"], resources: [.copy("skins"), .copy("pets")]),
        .testTarget(name: "CodexyCoreTests", dependencies: ["CodexyCore"]),
        // Orcy: a second app in the package, for Orca (the agent orchestrator). Its mascot, sky and formatting come
        // from CodexyCore; OrcyCore holds only the Orca readers. See docs/ORCY.md.
        .target(name: "OrcyCore"),
        .executableTarget(name: "Orcy", dependencies: ["CodexyCore", "OrcyCore"], resources: [.copy("skins"), .copy("pets")]),
        .testTarget(name: "OrcyCoreTests", dependencies: ["OrcyCore", "CodexyCore"]),
    ]
)
