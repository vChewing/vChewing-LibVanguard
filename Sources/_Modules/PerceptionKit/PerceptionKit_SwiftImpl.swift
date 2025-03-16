// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

extension StringProtocol {
  func has(string target: any StringProtocol) -> Bool {
    let selfArray = Array(unicodeScalars)
    let targetArray = Array(target.description.unicodeScalars)
    guard !target.isEmpty else { return isEmpty }
    guard count >= target.count else { return false }
    for index in selfArray.indices {
      let range = index ..< (Swift.min(index + targetArray.count, selfArray.count))
      let ripped = Array(selfArray[range])
      if ripped == targetArray { return true }
    }
    return false
  }
}
