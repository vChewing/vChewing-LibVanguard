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

// MARK: - Index Revolver (only for Array)

extension Int {
  /// 將整數作為數組索引進行循環位移。
  /// - Parameters:
  ///   - target: 目標數組
  ///   - clockwise: 是否順時針位移（向更大的索引方向）
  ///   - steps: 位移步數
  public mutating func revolveAsIndex<T>(with target: [T], clockwise: Bool = true, steps: Int = 1) {
    guard self >= 0, steps > 0, !target.isEmpty else { return }

    func revolvedIndex(_ id: Int, clockwise: Bool = true, steps: Int = 1) -> Int {
      guard id >= 0, steps > 0, !target.isEmpty else { return id }
      let count = target.count

      // 優化：使用取模運算直接計算最終位置，避免循環
      let effectiveSteps = steps % count
      if effectiveSteps == 0 { return id }

      let offset = clockwise ? effectiveSteps : -effectiveSteps
      let rawResult = id + offset

      // 使用取模運算處理邊界情況
      let result = ((rawResult % count) + count) % count
      return result
    }

    self = revolvedIndex(self, clockwise: clockwise, steps: steps)
  }
}
