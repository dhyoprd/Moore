// swift-tools-version: 5.9
// Moore umbrella package — integration shape: all 12 modules (#19–#30) unified.
// This is the canonical Package.swift for feat/integration-v1; per-ticket branches
// carried subsets, reconciled here at merge time.
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
        .library(name: "MooreWarmup", targets: ["MooreWarmup"]),
        .library(name: "MooreAnalytics", targets: ["MooreAnalytics"]),
        .library(name: "MooreSettings", targets: ["MooreSettings"]),
        .library(name: "MooreCues", targets: ["MooreCues"]),
        .library(name: "MooreImport", targets: ["MooreImport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
    ],
    targets: [
        .target(
            name: "MooreFoundation",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/MooreFoundation",
            resources: [.process("Migrations")]
        ),
        .target(
            name: "MooreExercises",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/MooreExercises",
            resources: [.process("Seed"), .process("Migrations")]
        ),
        .target(
            name: "MooreRoutines",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/MooreRoutines",
            resources: [.process("Migrations")]
        ),
        .target(
            name: "MooreWorkout",
            // MooreRoutines: SessionStatsProvider implements SC-routines'
            // SessionStatsProviding seam (#33 app shell wires it into Home).
            dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "MooreRoutines"],
            path: "Sources/MooreWorkout"
        ),
        .target(
            name: "MooreRest",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/MooreRest",
            resources: [.process("Migrations")]
        ),
        .target(
            name: "MooreProgression",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/MooreProgression",
            resources: [.process("Migrations")]
        ),
        .target(
            name: "MooreRecords",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/MooreRecords",
            resources: [.process("Migrations")]
        ),
        .target(
            name: "MooreWarmup",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/MooreWarmup",
            resources: [.process("Migrations")]
        ),
        .target(
            name: "MooreAnalytics",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/MooreAnalytics",
            resources: [.process("Migrations")]
        ),
        .target(
            name: "MooreSettings",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/MooreSettings",
            resources: [.process("Migrations")]
        ),
        .target(
            name: "MooreCues",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/MooreCues"
        ),
        .target(
            name: "MooreImport",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/MooreImport"
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
            name: "MooreWarmupTests",
            dependencies: ["MooreWarmup"],
            path: "Tests/MooreWarmupTests",
            exclude: ["Fixtures", "VerifyWarmup.mjs"]
        ),
        .testTarget(
            name: "MooreAnalyticsTests",
            dependencies: ["MooreAnalytics"],
            path: "Tests/MooreAnalyticsTests",
            exclude: ["Fixtures", "VerifyAnalytics.mjs"]
        ),
        .testTarget(
            name: "MooreSettingsTests",
            dependencies: ["MooreSettings"],
            path: "Tests/MooreSettingsTests",
            exclude: ["Fixtures", "VerifySettings.mjs"]
        ),
        .testTarget(
            name: "MooreCuesTests",
            dependencies: ["MooreCues"],
            path: "Tests/MooreCuesTests",
            exclude: ["Fixtures", "VerifyCues.mjs"]
        ),
        .testTarget(
            name: "MooreImportTests",
            dependencies: ["MooreImport"],
            path: "Tests/MooreImportTests",
            exclude: ["Fixtures", "VerifyImport.mjs"]
        ),
    ]
)
