// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Container-Compose",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.1"),
        .package(url: "https://github.com/mcrich23/container", branch: "add-command-option-group-function-macro"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6"),
        .package(url: "https://github.com/onevcat/Rainbow", .upToNextMajor(from: "4.0.0")),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        
// Security Hardening module (Plan 85)
    .target(
      name: "SecurityHardening",
      dependencies: [],
      path: "Sources/SecurityHardening"
    ),

    // Library target containing core logic
    .target(
      name: "ContainerComposeCore",
      dependencies: [
        .product(
          name: "ContainerCommands",
          package: "container"
        ),
        .product(
          name: "ArgumentParser",
          package: "swift-argument-parser"
        ),
        "Yams",
        "Rainbow",
        "SecurityHardening",
      ],
      path: "Sources/Container-Compose"
    ),
        
        // Executable target
        .executableTarget(
            name: "Container-Compose",
            dependencies: [
                "ContainerComposeCore"
            ],
            path: "Sources/ContainerComposeApp"
        ),
        
    // Test Helper
    .target(
      name: "TestHelpers",
      dependencies: [
        .product(name: "ContainerAPIClient", package: "container"),
        .product(name: "ContainerResource", package: "container")
      ],
      path: "Tests/TestHelpers",
      exclude: ["test_helpers.sh"]
    ),
    
    // Container Testing utilities (Memory Governor Trait, etc.)
    // Note: Uses Swift Testing framework (built into Swift 6+)
    .target(
      name: "ContainerTesting",
      dependencies: [],
      path: "Sources/ContainerTesting"
    ),
        
    // Tests
    .testTarget(
      name: "Container-Compose-StaticTests",
      dependencies: [
        "ContainerComposeCore",
        "TestHelpers",
        "ContainerTesting"
      ]
    ),

    .testTarget(
      name: "Container-Compose-DynamicTests",
      dependencies: [
        "ContainerComposeCore",
        "TestHelpers",
        "ContainerTesting"
      ]
    ),

    .testTarget(
      name: "Container-Compose-Tests",
      dependencies: [
        "ContainerComposeCore",
        "TestHelpers",
        "Yams",
        "ContainerTesting"
      ]
    ),

// Security Hardening Tests (Plan 85)
.testTarget(
  name: "SecurityHardeningTests",
  dependencies: [
    "SecurityHardening",
    "ContainerComposeCore"
  ],
  path: "Tests/SecurityHardeningTests"
),
]
)
