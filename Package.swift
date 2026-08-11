// swift-tools-version:5.9
// Moore umbrella package — assembled per-worktree so each ticket can build
// standalone. #19 (SC-foundation) owns `MooreFoundation`; #20 owns
// `MooreExercises`. Integration: once both land, delete this shim and keep
// the merged Package.swift that includes both products.
import PackageDescription

let package = Package(
    name: "Moore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "MooreExercises", targets: ["MooreExercises"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
    ],
    targets: [
        .target(
            name: "MooreExercises",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MooreExercises",
            resources: [.process("Seed")]
        ),
        .testTarget(
            name: "MooreExercisesTests",
            dependencies: ["MooreExercises"],
            path: "Tests/MooreExercisesTests",
            resources: [.process("Fixtures")]
        ),
    ]
)
