// swift-tools-version: 5.9
// Moore umbrella package — merged shape post #19 + #20. Owns both modules.
// Integration note: this is the merged Package.swift referenced by #20's shim
// comment — both products coexist here.
import PackageDescription

let package = Package(
    name: "Moore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MooreFoundation", targets: ["MooreFoundation"]),
        .library(name: "MooreExercises", targets: ["MooreExercises"]),
        .library(name: "MooreRoutines", targets: ["MooreRoutines"]),
        .library(name: "MooreRest", targets: ["MooreRest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
    ],
    targets: [
        .target(
            name: "MooreFoundation",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MooreFoundation",
            resources: [
                .process("Migrations"),
            ]
        ),
        .target(
            name: "MooreExercises",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MooreExercises",
            resources: [.process("Seed")]
        ),
        .target(
            name: "MooreRoutines",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MooreRoutines",
            resources: [.process("Migrations")]
        ),
        .target(
            name: "MooreRest",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MooreRest",
            resources: [.process("Migrations")]
        ),
        .testTarget(
            name: "MooreFoundationTests",
            dependencies: ["MooreFoundation"],
            path: "Tests/MooreFoundationTests"
        ),
        .testTarget(
            name: "MooreExercisesTests",
            dependencies: ["MooreExercises"],
            path: "Tests/MooreExercisesTests",
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "MooreRoutinesTests",
            dependencies: ["MooreRoutines"],
            path: "Tests/MooreRoutinesTests",
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "MooreRestTests",
            dependencies: ["MooreRest"],
            path: "Tests/MooreRestTests",
            resources: [.process("Fixtures")]
        ),
    ]
)
