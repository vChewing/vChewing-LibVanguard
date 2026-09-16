# LibVanguard, a Chinese Input Method Engine

This project is under development and is in its early stage.

Some developer nodes are available in [EVOLUTION_MEMO.md](./EVOLUTION_MEMO.md) (Traditional Chinese).

## The Purpose

The vChewing Input Method is dedicated for servicing macOS starting from 10.9 Mavericks, the earliest macOS supported by Swift 5. It has at least these problems:

- The entire input method is overcoupled with macOS-specific frameworks and APIs.
- Supporting macOS releases earlier than 10.15 Catalina results in further limitations:
  - The impossibility of using Swift-concurrency APIs, leaving the entire project non-concurrency-safe.
  - The impossibility of using Swift 6 which behaves much better on Linux and Windows.

All problems above led to the decision of making this "LibVanguard" project -- a new cross-platform Chinese input method engine.

> This repository builds against **Swift 6.4+**, plus Swift 5.10 on the macOS 10.9 legacy path. Swift 6.0 ~ 6.3 are banned outright by blocker manifests: 6.0 and 6.1 are plagued with inconveniences, while 6.2 and 6.3 demand an explicit `@MainActor` on conformances in a default-isolated package (`#ConformanceIsolation`) and cannot build this repository's dependency closure at all.

## What Is In This Repository

This repository is the aggregate package of the whole input-method core: every target of the
`BPMFVS`, `BrailleSputnik`, `Homa`, `LexiconAssembly`, `LibVanguard`, `ResourceLocator`,
`Shared` and `Tekkon` modules lives here, and the single dynamic product
`Vanguard` pulls in the entire dependency closure as `libVanguard.dylib`.

The general-purpose utility module `SwiftExtension` is
*not* part of this aggregate: it was extracted into its own package, whose directory name,
package identity and package name are all `VanguardSwiftExtension` (its target and module stay
`SwiftExtension`, so call sites keep writing `import SwiftExtension`), and which ships as a
separate dynamic product `VanguardSwiftExtension`. It lives **inside this package's own
directory**, at `Deps/VanguardSwiftExtension/`, rather than as a sibling under `Packages/`: one
aggregate sits under `Packages/` and the other *is* the repository root, so a sibling
relationship can never line up, whereas `Deps/…` resolves to the same relative path in both
repositories. That is what keeps this manifest byte-identical with its `vChewing-macOS`
counterpart; consumers reach it via
`.package(path: "../vChewing_OSNeutral_LibVanguard/Deps/VanguardSwiftExtension")` and take
`package: "VanguardSwiftExtension"` as the module's package identity.

SwiftPM refuses to have the same target consumed by both a dynamic and a static product
(`This will result in duplication of library code.`), hence the whole closure must ship as one
dynamic library and cannot be split into separately consumable static packages.

Module names and target names are the package's own: `import LibVanguard`, `import LexiconAssembly`,
and so on. The aggregate module is `LibVanguard`, named after the package; the shipping product is
`Vanguard`, named after the engine, and that is why the artifact is `libVanguard.dylib` and not
`libLibVanguard.dylib`.

The `LXAssemblyMaterials4Tests` and `HomaSharedTestComponents` products are test fixtures and are
shipped apart from `Vanguard` on purpose, so that no test material ends up inside the shipping
dynamic library.

## Building

- **Swift 6.4 or newer is a hard floor.** `Package.swift` declares `swift-tools-version: 6.4`, and the blocker manifests (`Package@swift-6.0.swift` … `Package@swift-6.3.swift`) make any 6.0 ~ 6.3 toolchain fail loudly instead of half-building. Besides `Package.swift`, the aggregate also carries `Package@swift-5.10.swift` — the macOS 10.9 legacy path, which produces static archives only (`make build510` / `make build510SwiftExtension` / `make clean510`, scratch `.build/.legacy`) and needs a Swift 5.10.1 OpenSource toolchain plus **an old-enough Xcode** and the **`MacOSX13.3.sdk` that Command Line Tools carries** at `/Library/Developer/CommandLineTools/SDKs/MacOSX13.3.sdk` (the copy inside Xcode 15 is only a symlink to it; `LEGACY_SDK` names the CLT path). Two caveats: that SDK is a *legacy* one — current CLTs no longer ship it and instead install a remover (`com.apple.pkg.CLTools_SDK_macOS13` → `CLTools_macOS_DevSDK_Remove_macOS13.pkg`), so on a clean machine obtain it from the macOS 13.3 Command Line Tools or from Xcode 14.3 and drop it into the CLT's `SDKs/`; and the Xcode is still required, because the 5.10 build-plugin compilation takes the *active developer directory's default* macOS SDK and `--sdk` does not reach it — any Xcode whose default SDK is ≤ 14.x (i.e. ≤ 15.4) does the job.
- **Linux and Windows**: only the latest official Swift release is recommended — **6.4.0 at minimum**.
- **Compiling with Swift 6.4+ on systems older than macOS 27** (e.g. the last Intel MacBook Pro 13-inch): making your current shell pick up a 6.4+ OpenSource toolchain is **your** responsibility. The official **Swiftly** is one workable answer, but its shell-environment setup is tedious, and it reinstalls every FOSS toolchain into your user space instead of the system root (at least that works on macOS 26). On a machine that tops out at macOS 15, Swiftly may fail to put a toolchain into user space at all — you then have to install the official `.dmg` / `.pkg` into the system root with administrator rights, and you may need to adapt this repository's `makefile` to your own setup. These chores can be delegated to an LLM nowadays, but convenience and risk travel together.
- **No version-pinned build entry points.** There is deliberately no `build640`-style target: every Swift release would otherwise force another sweep through every `makefile`. Build targets use whatever `swift` the current shell resolves to.

## Contributions

Unless specifically invited, this repository is not accepting external contribution for now. The developer might privately license this library to some commercial companies to earn some money for living expenses. That's the reason of using LGPL instead in this library.

## Credits

- (c) 2022 and onwards The vChewing Project (LGPL-3.0-or-later).
  - Swift programmer: Shiki Suen
- (c) 2025 and onwards The vChewing Project (LGPL-3.0-or-later) -- the `Homa`,
  `TrieKit` and `BrailleSputnik` modules.

```text
// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.
```

However, there are exceptions. See [COPYING](./COPYING) for details.

This project adopts a dual-licensing approach. In addition to LGPLv3, we offer different licensing terms for commercial users (such as permitting closed-source usage). For details, please [contact the author via email](shikisuen@yeah.net).

$ EOF.
