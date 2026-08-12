// swift-tools-version: 5.9
// Moore umbrella package — merged shape post #19 + #20 + #21 + #22 + #23 + #24 + #26 + #27.
// Owns all modules landed so far in this integration worktree.
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
        .library(name: "MooreWorkout", targets: ["MooreWorkout"]),
        .library(name: "MooreRest", targets: ["MooreRest"]),
        .library(name: "MooreProgression", targets: ["MooreProgression"]),
        .library(name: "MooreRecords", targets: ["MooreRecords"]),
        .library(name: "MooreAnalytics", targets: ["MooreAnalytics"]),
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
            name: "MooreWorkout",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MooreWorkout"
        ),
        .target(
            name: "MooreRest",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MooreRest",
            resources: [.process("Migrations")]
        ),
        .target(
            name: "MooreProgression",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MooreProgression",
            resources: [.process("Migrations")]
        ),
        .target(
            name: "MooreRecords",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MooreRecords",
            resources: [.process("Migrations")]
        ),
        .target(
            name: "MooreAnalytics",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MooreAnalytics"
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
            name: "MooreWorkoutTests",
            dependencies: ["MooreWorkout"],
            path: "Tests/MooreWorkoutTests",
            exclude: ["Fixtures", "VerifyWorkoutFsm.mjs"]
        ),
        .testTarget(
            name: "MooreRestTests",
            dependencies: ["MooreRest"],
            path: "Tests/MooreRestTests",
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "MooreProgressionTests",
            dependencies: ["MooreProgression"],
            path: "Tests/MooreProgressionTests",
            exclude: ["Fixtures", "VerifyProgression.mjs"]
        ),
        .testTarget(
            name: "MooreRecordsTests",
            dependencies: ["MooreRecords"],
            path: "Tests/MooreRecordsTests",
            exclude: ["Fixtures", "VerifyRecords.mjs"]
        ),
        .testTarget(
            name: "MooreAnalyticsTests",
            dependencies: ["MooreAnalytics"],
            path: "Tests/MooreAnalyticsTests",
            exclude: ["Fixtures", "VerifyAnalytics.mjs"]
        ),
    ]
)
