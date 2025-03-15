// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

extension Homa.Assembler {
  /// 爬軌函式，會以 Dijkstra 演算法更新當前組字器的 assembledSentence。
  ///
  /// 該演算法會在圖中尋找具有最高分數的路徑，即最可能的字詞組合。
  ///
  /// 該演算法所依賴的 HybridPriorityQueue 針對 Sandy Bridge 經過最佳化處理，
  /// 使得該演算法在 Sandy Bridge CPU 的電腦上比 DAG 演算法擁有更優的效能。
  ///
  /// - Returns: 爬軌結果（已選字詞陣列）。
  @discardableResult
  public func assemble() -> [Homa.GramInPath] {
    Homa.PathFinder(config: config, assembledSentence: &assembledSentence)
    return assembledSentence
  }
}

// MARK: - Homa.PathFinder

extension Homa {
  final class PathFinder {
    /// 爬軌工具，會以 Dijkstra 演算法更新當前組字器的 assembledSentence。
    ///
    /// 該演算法會在圖中尋找具有最高分數的路徑，即最可能的字詞組合。
    ///
    /// 該演算法所依賴的 HybridPriorityQueue 針對 Sandy Bridge 經過最佳化處理，
    /// 使得該演算法在 Sandy Bridge CPU 的電腦上比 DAG 演算法擁有更優的效能。
    @discardableResult
    init(config: Homa.Config, assembledSentence: inout [Homa.GramInPath]) {
      var newassembledSentence = [Homa.GramInPath]()
      defer { assembledSentence = newassembledSentence }
      guard !config.spans.isEmpty else { return }

      // 初期化資料結構。
      var openSet = HybridPriorityQueue<PrioritizedState>(reversed: true)
      var visited = Set<SearchState>()
      var bestScore = [Int: Double]() // 追蹤每個位置的最佳分數

      // 初期化起始狀態。
      let leadingGram = Homa.Gram(keyArray: ["$LEADING"], current: "")
      let leadingState = SearchState(
        gram: leadingGram,
        position: 0,
        prev: nil,
        distance: 0,
        isOverridden: false
      )
      openSet.enqueue(PrioritizedState(state: leadingState))
      bestScore[0] = 0

      // 追蹤最佳結果。
      var bestFinalState: SearchState?
      var bestFinalScore = Double(Int32.min)

      // 主要 Dijkstra 迴圈。
      while !openSet.isEmpty {
        guard let currentState = openSet.dequeue()?.state else { break }

        // 如果已經造訪過具有更好分數的狀態，則跳過。
        if visited.contains(currentState) { continue }
        visited.insert(currentState)

        // 檢查是否已到達終點。
        if currentState.position >= config.keys.count {
          if currentState.distance > bestFinalScore {
            bestFinalScore = currentState.distance
            bestFinalState = currentState
          }
          continue
        }

        // 處理下一個可能的節點。
        for (length, nextNode) in config.spans[currentState.position] {
          guard let nextGram = nextNode.currentGram else { continue }
          let nextPos = currentState.position + length

          // 計算新的權重分數。
          let newScore = currentState.distance + nextNode.getScore(
            previous: currentState.gram.current
          )

          // 如果該位置已有更優的權重分數，則跳過。
          guard (bestScore[nextPos] ?? .init(Int32.min)) < newScore else { continue }

          let nextState = SearchState(
            gram: nextGram,
            position: nextPos,
            prev: currentState,
            distance: newScore,
            isOverridden: nextNode.isOverridden
          )

          bestScore[nextPos] = newScore
          openSet.enqueue(PrioritizedState(state: nextState))
        }
      }

      // 從最佳終止狀態重建路徑。
      guard let finalState = bestFinalState else { return }
      var pathGrams: [Homa.GramInPath] = []
      var current: SearchState? = finalState

      while let state = current {
        // 排除起始和結束的虛擬節點。
        if state.gram !== leadingGram {
          pathGrams.insert(
            .init(gram: state.gram, isOverridden: state.isOverridden),
            at: 0
          )
        }
        current = state.prev
        // 備註：此處不需要手動 ASAN，因為沒有參據循環（Retain Cycle）。
      }
      newassembledSentence = pathGrams
    }
  }
}

// MARK: - 搜尋狀態相關定義

extension Homa.PathFinder {
  /// 用於追蹤搜尋過程中的狀態。
  private final class SearchState: Hashable {
    // MARK: Lifecycle

    /// 初期化搜尋狀態。
    /// - Parameters:
    ///   - gram: 當前節點。
    ///   - position: 在輸入串中的位置。
    ///   - prev: 前一個狀態。
    ///   - distance: 到達此狀態的累計分數。
    init(
      gram: Homa.Gram,
      position: Int,
      prev: SearchState?,
      distance: Double = Double(Int.min),
      isOverridden: Bool
    ) {
      self.gram = gram
      self.position = position
      self.prev = prev
      self.distance = distance
      self.isOverridden = isOverridden
    }

    // MARK: Internal

    unowned let gram: Homa.Gram // 當前節點
    let position: Int // 在輸入串中的位置
    unowned let prev: SearchState? // 前一個狀態
    var distance: Double // 累計分數
    let isOverridden: Bool

    // MARK: - Hashable 協定實作

    static func == (lhs: SearchState, rhs: SearchState) -> Bool {
      lhs.gram === rhs.gram && lhs.position == rhs.position
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(gram)
      hasher.combine(position)
    }
  }

  /// 用於優先序列的狀態包裝結構
  private struct PrioritizedState: Comparable {
    let state: SearchState

    // MARK: - Comparable 協定實作

    static func < (lhs: Self, rhs: Self) -> Bool {
      lhs.state.distance < rhs.state.distance
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.state == rhs.state
    }
  }
}
