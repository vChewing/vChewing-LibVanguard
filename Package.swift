// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "LibVanguard",
  platforms: buildSupportedPlatform {
    #if canImport(Darwin)
      /// Certain cross-platform features in Swift (e.g. Observation) are intentionally
      /// not supported on Apple platform releases prior to their official adoption.
      /// There’s no workaround for this limitation.
      SupportedPlatform.macOS(.v15) // Sonoma
      SupportedPlatform.macCatalyst(.v18) // Sonoma
      SupportedPlatform.iOS(.v18) // iOS 17
      SupportedPlatform.visionOS(.v2) // VisionOS v1
    #endif
  },
  products: buildProducts {
    Product.library(
      name: "LibVanguard",
      targets: ["LibVanguard"]
    )
    Product.library(
      name: "TrieKit",
      targets: ["TrieKit"]
    )
    Product.library(
      name: "Tekkon",
      targets: ["Tekkon"]
    )
    Product.library(
      name: "Homa",
      targets: ["Homa"]
    )
    // Basic components ---
    Product.library(
      name: "SharedCore",
      targets: ["SharedCore"]
    )
    Product.library(
      name: "CandidateKit",
      targets: ["CandidateKit"]
    )
  },
  dependencies: buildPackageDependencies {
    Package.Dependency.package(path: "CSQLite3")
  },
  targets: buildTargets {
    Target.target(
      name: "LibVanguard",
      dependencies: buildTargetDependencies {
        "CandidateKit"
        "Tekkon"
        "Homa"
        "BrailleSputnik"
        "TrieKit"
        "LexiconKit"
        "SharedCore"
      }
    )
    Target.testTarget(
      name: "LibVanguardTests",
      dependencies: buildTargetDependencies {
        "LibVanguard"
      }
    )
    // Tekkon, the phonabet composer.
    Target.target(
      name: "Tekkon",
      path: "./Sources/_Modules/Tekkon"
    )
    Target.testTarget(
      name: "TekkonTests",
      dependencies: buildTargetDependencies {
        "Tekkon"
      },
      path: "./Tests/_Tests4Components/TekkonTests"
    )
    // Homa, the sentence Assembler.
    Target.target(
      name: "Homa",
      path: "./Sources/_Modules/Homa"
    )
    // Shared bundle for all Homa-related tests.
    Target.target(
      name: "HomaSharedTestComponents",
      dependencies: buildTargetDependencies {
        "Homa"
      },
      path: "./Tests/_Tests4Components/_HomaSharedTestComponents"
    )
    Target.testTarget(
      name: "HomaTests",
      dependencies: buildTargetDependencies {
        "Homa"
        "HomaSharedTestComponents"
      },
      path: "./Tests/_Tests4Components/HomaTests"
    )
    // Shared bundle for all tests using factory trie.
    Target.target(
      name: "SharedTrieTestDataBundle",
      path: "./Tests/_Tests4Components/_SharedTrieTestDataBundle",
      resources: buildResources {
        Resource.process("./Resources")
      }
    )
    // LexiconKit, the hub for all subsidiary language models.
    Target.target(
      name: "LexiconKit",
      dependencies: buildTargetDependencies {
        "TrieKit"
        "Homa"
      },
      path: "./Sources/_Modules/LexiconKit"
    )
    Target.testTarget(
      name: "LexiconKitTests",
      dependencies: buildTargetDependencies {
        "Homa"
        "HomaSharedTestComponents"
        "LexiconKit"
        "SharedTrieTestDataBundle"
        "Tekkon"
        "TrieKit"
      },
      path: "./Tests/_Tests4Components/LexiconKitTests"
    )
    // CandidateKit, the basic module for holding candidate pools.
    Target.target(
      name: "CandidateKit",
      dependencies: buildTargetDependencies {
        "SharedCore"
      },
      path: "./Sources/_Modules/CandidateKit"
    )
    Target.testTarget(
      name: "CandidateKitTests",
      dependencies: buildTargetDependencies {
        "CandidateKit"
      },
      path: "./Tests/_Tests4Components/CandidateKitTests"
    )
    // SharedCore, the basic module for holding common protocols.
    Target.target(
      name: "SharedCore",
      dependencies: buildTargetDependencies {
        "SwiftExtension"
      },
      path: "./Sources/_Modules/SharedCore"
    )
    Target.testTarget(
      name: "SharedCoreTests",
      dependencies: buildTargetDependencies {
        "SharedCore"
      },
      path: "./Tests/_Tests4Components/SharedCoreTests"
    )
    // BrailleSputnik, the Braille module.
    Target.target(
      name: "BrailleSputnik",
      dependencies: buildTargetDependencies {
        "Tekkon"
      },
      path: "./Sources/_Modules/BrailleSputnik"
    )
    Target.testTarget(
      name: "BrailleSputnikTests",
      dependencies: buildTargetDependencies {
        "BrailleSputnik"
      },
      path: "./Tests/_Tests4Components/BrailleSputnikTests"
    )
    // VanguardTrieSupport, the data structure for factory dictionary files.
    Target.target(
      name: "TrieKit",
      dependencies: buildTargetDependencies {
        Target.Dependency.product(name: "CSQLite3", package: "CSQLite3")
      },
      path: "./Sources/_Modules/TrieKit"
    )
    Target.testTarget(
      name: "TrieKitTests",
      dependencies: buildTargetDependencies {
        "Homa"
        "Tekkon"
        "TrieKit"
      },
      path: "./Tests/_Tests4Components/TrieKitTests"
    )
    // Swift Extension
    Target.target(
      name: "SwiftExtension",
      path: "./Sources/_Modules/SwiftExtension"
    )
  }
)

// MARK: - ArrayBuilder

@resultBuilder
enum ArrayBuilder<Element> {
  static func buildEither(first elements: [Element]) -> [Element] {
    elements
  }

  static func buildEither(second elements: [Element]) -> [Element] {
    elements
  }

  static func buildOptional(_ elements: [Element]?) -> [Element] {
    elements ?? []
  }

  static func buildExpression(_ expression: Element) -> [Element] {
    [expression]
  }

  static func buildExpression(_: ()) -> [Element] {
    []
  }

  static func buildBlock(_ elements: [Element]...) -> [Element] {
    elements.flatMap { $0 }
  }

  static func buildArray(_ elements: [[Element]]) -> [Element] {
    Array(elements.joined())
  }
}

func buildTargets(@ArrayBuilder<Target?> targets: () -> [Target?]) -> [Target] {
  targets().compactMap { $0 }
}

func buildStrings(@ArrayBuilder<String?> strings: () -> [String?]) -> [String] {
  strings().compactMap { $0 }
}

func buildProducts(@ArrayBuilder<Product?> products: () -> [Product?]) -> [Product] {
  products().compactMap { $0 }
}

func buildTargetDependencies(
  @ArrayBuilder<Target.Dependency?> dependencies: () -> [Target.Dependency?]
)
  -> [Target.Dependency] {
  dependencies().compactMap { $0 }
}

func buildResources(
  @ArrayBuilder<Resource?> resources: () -> [Resource?]
)
  -> [Resource] {
  resources().compactMap { $0 }
}

func buildPackageDependencies(
  @ArrayBuilder<Package.Dependency?> dependencies: () -> [Package.Dependency?]
)
  -> [Package.Dependency] {
  dependencies().compactMap { $0 }
}

func buildSupportedPlatform(
  @ArrayBuilder<SupportedPlatform?> dependencies: () -> [SupportedPlatform?]
)
  -> [SupportedPlatform]? {
  let result = dependencies().compactMap { $0 }
  return result.isEmpty ? nil : result
}
