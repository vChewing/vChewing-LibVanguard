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
  ],
  targets: [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    .target(
      name: "LibVanguard",
      dependencies: ["TekkonNext", "Homa"]
    ),
    .testTarget(
      name: "LibVanguardTests",
      dependencies: ["LibVanguard"]
    ),
    // Tekkon, the phonabet composer.
    .target(
      name: "TekkonNext",
      path: "./Sources/_Modules/TekkonNext"
    ),
    .testTarget(
      name: "TekkonNextTests",
      dependencies: ["TekkonNext"],
      path: "./Tests/_Tests4Components/TekkonNextTests"
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
  ]
)
