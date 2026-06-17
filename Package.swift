// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MatrackTruckSim",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MatrackTruckSim",
            path: "Sources/MatrackTruckSim"
        )
    ]
)
