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
      SupportedPlatform.macOS(.v14) // Sonoma
      SupportedPlatform.macCatalyst(.v17) // Sonoma
      SupportedPlatform.iOS(.v17) // iOS 17
      SupportedPlatform.visionOS(.v1) // VisionOS v1
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
        "KBEventKit"
        "LexiconKit"
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
    Target.testTarget(
      name: "HomaTests",
      dependencies: buildTargetDependencies {
        "Homa"
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
        "SharedTrieTestDataBundle"
        "TrieKit"
      },
      path: "./Sources/_Modules/LexiconKit"
    )
    Target.testTarget(
      name: "LexiconKitTests",
      dependencies: buildTargetDependencies {
        "Homa"
        "LexiconKit"
        "Tekkon"
        "TrieKit"
      },
      path: "./Tests/_Tests4Components/LexiconKitTests"
    )
    // CandidateKit, the basic module for holding candidate pools.
    Target.target(
      name: "CandidateKit",
      path: "./Sources/_Modules/CandidateKit"
    )
    Target.testTarget(
      name: "CandidateKitTests",
      path: "./Tests/_Tests4Components/CandidateKitTests"
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
        "CSQLite3"
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
    // KBEventKit, the Keyboard Event Management Kit.
    Target.target(
      name: "KBEventKit",
      path: "./Sources/_Modules/KBEventKit"
    )
    // CSQLite3 for all platforms.
    Target.target(
      name: "CSQLite3",
      path: "./Sources/_3rdParty/CSQLite3",
      cSettings: buildCSQLiteSettings()
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

func buildCSQLiteSettings() -> [CSetting] {
  var settings: [CSetting] = [
    .unsafeFlags(["-w"]),
    // Common performance optimizations
    .define("SQLITE_THREADSAFE", to: "2"), // Multi-thread safe
    .define("SQLITE_DEFAULT_CACHE_SIZE", to: "-64000"), // 64MB cache
    .define("SQLITE_DEFAULT_PAGE_SIZE", to: "4096"), // 4KB pages
    .define("SQLITE_DEFAULT_TEMP_CACHE_SIZE", to: "-32000"), // 32MB temp cache
    .define("SQLITE_OMIT_DEPRECATED"), // Remove deprecated APIs
    .define("SQLITE_OMIT_LOAD_EXTENSION"), // No dynamic loading
    .define("SQLITE_OMIT_SHARED_CACHE"), // No shared cache (read-only DB)
    .define("SQLITE_OMIT_UTF16"), // Only UTF-8 support
    .define("SQLITE_OMIT_PROGRESS_CALLBACK"), // No progress callbacks
    .define("SQLITE_MAX_EXPR_DEPTH", to: "0"), // No expression depth limit
    .define("SQLITE_USE_ALLOCA"), // Use alloca for small allocations
    .define("SQLITE_ENABLE_MEMORY_MANAGEMENT"), // Better memory management
    .define("SQLITE_ENABLE_FAST_SECURE_DELETE"), // Faster deletes
  ]

  #if os(Windows)
    // Windows-specific optimizations
    settings.append(.define("SQLITE_WIN32_MALLOC")) // Use Windows heap API
    settings.append(.define("SQLITE_WIN32_MALLOC_VALIDATE")) // Validate heap allocations
  #endif

  #if canImport(Darwin)
    // macOS/iOS-specific optimizations
    settings.append(.define("SQLITE_ENABLE_LOCKING_STYLE", to: "1")) // Better file locking
  #endif

  return settings
}
