// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - CandidateCellData

/// 用來管理選字窗內顯示的候選字的單位。用 class 型別會比較方便一些。
public class CandidateCellData: Hashable {
  // MARK: Lifecycle

  public init(
    key: String, displayedText: String,
    spanLength spanningLength: Int? = nil, isSelected: Bool = false
  ) {
    self.selectionKey = key
    self.displayedText = displayedText
    self.spanLength = max(spanningLength ?? displayedText.count, 1)
    self.isHighlighted = isSelected
  }

  // MARK: Public

  public var locale = ""
  public var selectionKey: String
  public let displayedText: String
  public var spanLength: Int
  public var isHighlighted: Bool = false
  public var whichLine: Int = 0
  // 該候選字詞在資料池內的總索引編號
  public var index: Int = 0
  // 該候選字詞在當前行/列內的索引編號
  public var subIndex: Int = 0

  public var hardCopy: CandidateCellData {
    let result = CandidateCellData(
      key: selectionKey,
      displayedText: displayedText,
      spanLength: spanLength,
      isSelected: isHighlighted
    )
    result.locale = locale
    result.whichLine = whichLine
    result.index = index
    result.subIndex = subIndex
    return result
  }

  public var cleanCopy: CandidateCellData {
    let result = hardCopy
    result.isHighlighted = false
    result.selectionKey = " "
    return result
  }

  public static func == (lhs: CandidateCellData, rhs: CandidateCellData) -> Bool {
    lhs.selectionKey == rhs.selectionKey && lhs.displayedText == rhs.displayedText
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(selectionKey)
    hasher.combine(displayedText)
  }
}

// MARK: - Array Container Extension.

extension Array where Element == CandidateCellData {
  public var hasHighlightedCell: Bool {
    for neta in self {
      if neta.isHighlighted { return true }
    }
    return false
  }
}
