// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - Extending Assembler for Node Consolidation.

extension Homa.Assembler {
  /// 鞏固當前組字器游標上下文，防止在當前游標位置固化節點時給作業範圍以外的內容帶來不想要的變化。
  ///
  /// 打比方說輸入法原廠詞庫內有「章太炎」一詞，你敲「章太炎」，然後想把「太」改成「泰」以使其變成「章泰炎」。
  /// **macOS 內建的注音輸入法不會在這個過程對這個詞除了「太」以外的部分有任何變動**，
  /// 但石磬軟體的所有輸入法產品都對此有 Bug：會將這些部分全部重設為各自的讀音下的最高原始權重的漢字。
  /// 也就是說，選字之後的結果可能會變成「張泰言」。
  ///
  /// - Remark: 類似的可以拿來測試的詞有「蔡依林」「周杰倫」。
  ///
  /// 測試時請務必也測試「敲長句子、且這種詞在句子中間出現時」的情況。
  /// - Parameters:
  ///   - theCandidate: 要拿來覆寫的詞音配對。
  ///   - cursorType: 選字時是前置游標還是後置游標。
  /// - Throws: 任何可能的覆寫失敗。（一般情況下不用處理這個，除非需要診斷故障。）
  public func consolidateCandidateCursorContext(
    for theCandidate: Homa.CandidatePair,
    cursorType: CandidateCursor,
    debugIntelHandler: ((String) -> ())? = nil
  ) throws {
    let grid = copy
    let actualNodeCursorPosition = getLogicalCandidateCursorPosition(forCursor: cursorType)
    var debugIntelToPrint = [String]()

    // 嘗試覆寫候選字並組裝格柵
    try grid.overrideCandidate(theCandidate, at: actualNodeCursorPosition)
    grid.assemble()

    // 獲取預期的邊界範圍
    let rangeTemp = grid.assembledNodes.contextRange(ofGivenCursor: actualNodeCursorPosition)
    let rearBoundaryEX = rangeTemp.lowerBound
    let frontBoundaryEX = rangeTemp.upperBound
    debugIntelToPrint.append("EX: \(rearBoundaryEX)..<\(frontBoundaryEX), ")

    // 獲取當前的邊界範圍
    let range = assembledNodes.contextRange(ofGivenCursor: actualNodeCursorPosition)
    var rearBoundary = min(range.lowerBound, rearBoundaryEX)
    var frontBoundary = max(range.upperBound, frontBoundaryEX)
    debugIntelToPrint.append("INI: \(rearBoundary)..<\(frontBoundary), ")

    // 通過跳轉游標來確定實際的邊界
    calculatedActualBoundaries(rear: &rearBoundary, front: &frontBoundary)
    debugIntelToPrint.append("FIN: \(rearBoundary)..<\(frontBoundary)")
    debugIntelHandler?("[HOMA_DEBUG] \(debugIntelToPrint.joined())")

    // 應用節點鞏固
    applyNodeConsolidation(from: rearBoundary, to: frontBoundary)
  }

  /// 計算實際的上下文邊界
  /// - Parameters:
  ///   - rearBoundary: 後邊界引用
  ///   - frontBoundary: 前邊界引用
  private func calculatedActualBoundaries(
    rear rearBoundary: inout Int,
    front frontBoundary: inout Int
  ) {
    let cursorBackup = cursor

    // 向後計算
    while cursor > rearBoundary {
      try? jumpCursorBySpan(to: .rear)
    }
    rearBoundary = min(cursor, rearBoundary)

    // 還原游標，再向前計算
    cursor = cursorBackup
    while cursor < frontBoundary {
      try? jumpCursorBySpan(to: .front)
    }
    frontBoundary = min(max(cursor, frontBoundary), length)

    // 計算結束，游標歸位
    cursor = cursorBackup
  }

  /// 應用節點鞏固
  /// - Parameters:
  ///   - rearBoundary: 後邊界
  ///   - frontBoundary: 前邊界
  private func applyNodeConsolidation(
    from rearBoundary: Int,
    to frontBoundary: Int
  ) {
    var nodeIndices = [Int]() // 僅作統計用
    var position = rearBoundary

    while position < frontBoundary {
      guard let regionIndex = assembledNodes.cursorRegionMap[position] else {
        position += 1
        continue
      }

      // 避免重複處理同一個節點
      if !nodeIndices.contains(regionIndex) {
        nodeIndices.append(regionIndex)

        // 防止索引越界
        guard assembledNodes.count > regionIndex else { break }

        let currentNode = assembledNodes[regionIndex]
        guard let currentNodeGramPair = currentNode.currentPair else { break }

        // 處理整個節點或按字元個別處理
        if currentNodeGramPair.keyArray.count == currentNodeGramPair.value.count {
          // 按字元個別處理
          let values = currentNodeGramPair.value.map(\.description)
          for (subPosition, key) in currentNode.keyArray.enumerated() {
            guard values.count > subPosition else { break }
            let thePair = Homa.CandidatePair(
              keyArray: [key], value: values[subPosition]
            )
            try? overrideCandidate(thePair, at: position)
            position += 1
          }
        } else {
          // 整個節點處理
          try? overrideCandidate(currentNodeGramPair, at: position)
          position += currentNode.keyArray.count
        }
        continue
      }
      position += 1
    }
  }
}
