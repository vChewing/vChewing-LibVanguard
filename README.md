# LibVanguard, a Chinese Input Method Engine

This project is under development and is in its early stage.

## The Purpose

The vChewing Input Method is dedicated for servicing macOS starting from 10.9 Mavericks, the earliest macOS supported by Swift 5. It has at least these problems:

- The entire input method is overcoupled with macOS-specific frameworks and APIs.
- Supporting macOS releases earlier than 10.15 Catalina results in further limitations:
    - The impossibility of using Swift-concurrency APIs, leaving the entire project non-concurrency-safe.
    - The impossibility of using Swift 6 which behaves much better on Linux and Windows.

All problems above led to the decision of making this "LibVanguard" project -- a new cross-platform Chinese input method engine.

## Contributions

Unless specifically invited, this repository is not accepting external contribution for now. The developer might privately license this library to some commercial companies to earn some money for living expenses. That's the reason of using LGPL instead in this library.

## Credits

- (c) 2025 and onwards The vChewing Project (LGPL-3.0-or-later).
  - Swift programmer: Shiki Suen

```
// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.
```

An exception is that the unit tests of the Homa Sentence Assembler utilizes certain contents extracted from libvchewing-data which is released under BSD-3-Clause.
```
// (c) 2021 and onwards The vChewing Project (BSD-3-Clause).
// ====================
// This code is released under the SPDX-License-Identifier: `BSD-3-Clause`.
```

This project adopts a dual-licensing approach. In addition to LGPLv3, we offer different licensing terms for commercial users (such as permitting closed-source usage). For details, please [contact the author via email](shikisuen@yeah.net).

$ EOF.
