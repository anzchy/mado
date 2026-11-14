// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MadoKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MadoCore", targets: ["MadoCore"]),
        .library(name: "MadoApplication", targets: ["MadoApplication"]),
        .library(name: "MadoInfrastructure", targets: ["MadoInfrastructure"]),
        .library(name: "MadoMacUI", targets: ["MadoMacUI"]),
    ],
    targets: [
        .target(name: "MadoCore"),
        .target(name: "MadoApplication", dependencies: ["MadoCore"]),
        .target(name: "MadoInfrastructure", dependencies: ["MadoCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "MadoMacUI", dependencies: ["MadoCore", "MadoApplication"], exclude: ["B4Samples/PROVENANCE.md"], resources: [
            .copy("B4Samples/alley.jpg"), .copy("B4Samples/lakeside.jpg"),
            .copy("B4Samples/temple.jpg"), .copy("B4Samples/hillside.jpg"),
            .copy("B4Samples/lakehouse.jpg"), .copy("B4Samples/gate.jpg")
        ]),
        .testTarget(name: "MadoApplicationTests", dependencies: ["MadoCore", "MadoApplication", "MadoInfrastructure"]),
        .testTarget(name: "MadoMacUITests", dependencies: ["MadoMacUI", "MadoInfrastructure"], exclude: ["B4PinnedDesign"]),
        .testTarget(name: "MadoCoreTests", dependencies: ["MadoCore"]),
        .testTarget(name: "MadoInfrastructureTests", dependencies: ["MadoCore", "MadoInfrastructure"]),
    ],
    swiftLanguageModes: [.v6]
)

// Exercise two real Sessions against the real admission actor at the integration seam.
package.targets.first(where: { $0.name == "MadoInfrastructureTests" })!.dependencies.append("MadoApplication")

// Preferences implement the Application store port.
package.targets.first(where: { $0.name == "MadoInfrastructure" })!.dependencies.append("MadoApplication")
