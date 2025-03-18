// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "LibVanguard",
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
      name: "LibVanguard",
      targets: ["LibVanguard"]
    ),
    .library(
      name: "TrieKit",
      targets: ["TrieKit"]
    ),
    .library(
      name: "Tekkon",
      targets: ["Tekkon"]
    ),
    .library(
      name: "Homa",
      targets: ["Homa"]
    ),
  ],
  targets: [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    .target(
      name: "LibVanguard",
      dependencies: [
        "Tekkon",
        "Homa",
        "BrailleSputnik",
        "TrieKit",
        "KBEventKit",
        "LexiconKit",
      ]
    ),
    .testTarget(
      name: "LibVanguardTests",
      dependencies: ["LibVanguard"]
    ),
    // Tekkon, the phonabet composer.
    .target(
      name: "Tekkon",
      path: "./Sources/_Modules/Tekkon"
    ),
    .testTarget(
      name: "TekkonTests",
      dependencies: ["Tekkon"],
      path: "./Tests/_Tests4Components/TekkonTests"
    ),
    // Homa, the sentence Assembler.
    .target(
      name: "Homa",
      path: "./Sources/_Modules/Homa"
    ),
    .testTarget(
      name: "HomaTests",
      dependencies: ["Homa"],
      path: "./Tests/_Tests4Components/HomaTests"
    ),
    // PerceptionKit, a companion for Homa Assembler.
    .target(
      name: "PerceptionKit",
      path: "./Sources/_Modules/PerceptionKit"
    ),
    .testTarget(
      name: "PerceptionKitTests",
      dependencies: ["PerceptionKit"],
      path: "./Tests/_Tests4Components/PerceptionKitTests"
    ),
    // Shared bundle for all tests using factory trie.
    .target(
      name: "SharedTrieTestDataBundle",
      path: "./Tests/_Tests4Components/_SharedTrieTestDataBundle",
      resources: [
        .process("./Resources"),
      ]
    ),
    // LexiconKit, the hub for all subsidiary language models.
    .target(
      name: "LexiconKit",
      dependencies: ["TrieKit", "PerceptionKit", "SharedTrieTestDataBundle"],
      path: "./Sources/_Modules/LexiconKit"
    ),
    .testTarget(
      name: "LexiconKitTests",
      dependencies: ["TrieKit", "LexiconKit", "Homa", "Tekkon"],
      path: "./Tests/_Tests4Components/LexiconKitTests"
    ),
    // BrailleSputnik, the Braille module.
    .target(
      name: "BrailleSputnik",
      dependencies: ["Tekkon"],
      path: "./Sources/_Modules/BrailleSputnik"
    ),
    .testTarget(
      name: "BrailleSputnikTests",
      dependencies: ["BrailleSputnik"],
      path: "./Tests/_Tests4Components/BrailleSputnikTests"
    ),
    // VanguardTrieSupport, the data structure for factory dictionary files.
    .target(
      name: "TrieKit",
      dependencies: ["CSQLite3"],
      path: "./Sources/_Modules/TrieKit"
    ),
    .testTarget(
      name: "TrieKitTests",
      dependencies: [
        "TrieKit",
        "Homa",
        "Tekkon",
      ],
      path: "./Tests/_Tests4Components/TrieKitTests"
    ),
    // KBEventKit, the Keyboard Event Management Kit.
    .target(
      name: "KBEventKit",
      path: "./Sources/_Modules/KBEventKit"
    ),
    // CSQLite3 for all platforms.
    .target(
      name: "CSQLite3",
      path: "./Sources/_3rdParty/CSQLite3",
      cSettings: [
        .unsafeFlags(["-w"]),
      ]
    ),
  ]
)
