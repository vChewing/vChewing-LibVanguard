// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

extension Homa.Assembler {
  /// 組句函式，會以 Dijkstra 演算法更新當前組字器的 assembledSentence。
  ///
  /// 該演算法會在圖中尋找具有最高分數的路徑，即最可能的字詞組合。
  ///
  /// 該演算法所依賴的 HybridPriorityQueue 針對 Sandy Bridge 經過最佳化處理，
  /// 使得該演算法在 Sandy Bridge CPU 的電腦上比 DAG 演算法擁有更優的效能。
  ///
  /// - Returns: 組句結果（已選字詞陣列）。
  @discardableResult
  public func assemble() -> [Homa.GramInPath] {
    Homa.PathFinder(config: config, assembledSentence: &assembledSentence)
    return assembledSentence
  }
}

// MARK: - Homa.PathFinder

extension Homa {
  final class PathFinder {
    // MARK: Lifecycle

    /// 組句工具，會以 Dijkstra 演算法更新當前組字器的 assembledSentence。
    ///
    /// 該演算法會在圖中尋找具有最高分數的路徑，即最可能的字詞組合。
    ///
    /// 該演算法所依賴的 HybridPriorityQueue 針對 Sandy Bridge 經過最佳化處理，
    /// 使得該演算法在 Sandy Bridge CPU 的電腦上比 DAG 演算法擁有更優的效能。
    @discardableResult
    init(config: Homa.Config, assembledSentence: inout [Homa.GramInPath]) {
      var newassembledSentence = [Homa.GramInPath]()
      defer { assembledSentence = newassembledSentence }
      guard !config.segments.isEmpty else { return }

      // 初期化資料結構。
      var openSet = HybridPriorityQueue<PrioritizedState>(reversed: true)
      var visited = Set<SearchState>()
      var bestScore = ContiguousArray<Double>(
        repeating: Double(Int32.min),
        count: config.keys.count + 1
      ) // 追蹤每個位置的最佳分數，使用陣列以提升快取效能

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
        for (length, nextNode) in config.segments[currentState.position] {
          guard let nextGram = nextNode.currentGram else { continue }
          let nextPos = currentState.position + length

          // 計算新的權重分數。
          let newScore = currentState.distance + nextNode.getScore(
            previous: currentState.gram?.current ?? ""
          )

          // 如果該位置已有更優的權重分數，則跳過。
          guard nextPos < bestScore.count, bestScore[nextPos] < newScore else { continue }

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

        // 即時記憶體最佳化：當 visited 集合過大時進行部分清理
        if visited.count > 1_000 { // 可調整的閾值
          Self.partialCleanVisitedStates(visited: &visited, keepRecentCount: 500)
        }
      }

      // 從最佳終止狀態重建路徑。
      guard let finalState = bestFinalState else {
        // 即使沒有找到最佳狀態，也需要清理所有建立的 SearchState 物件
        Self.batchCleanAllSearchStates(
          visited: visited,
          openSet: &openSet,
          leadingState: leadingState
        )
        return
      }

      var pathGrams: [Homa.GramInPath] = []
      var current: SearchState? = finalState

      while let state = current {
        // 排除起始和結束的虛擬節點。
        if let stateGram = state.gram, stateGram !== leadingGram {
          pathGrams.insert(
            .init(gram: stateGram, isOverridden: state.isOverridden),
            at: 0
          )
        }
        current = state.prev
      }
      newassembledSentence = pathGrams

      // 手動 ASAN：批次清理所有 SearchState 物件以防止記憶體洩漏
      // 包括 visited set 中的所有狀態、openSet 中剩餘的狀態，以及 leadingState
      Self.batchCleanAllSearchStates(
        visited: visited,
        openSet: &openSet,
        leadingState: leadingState
      )
    }

    // MARK: Private

    /// 部分清理已訪問狀態集合以控制記憶體使用
    /// - Parameters:
    ///   - visited: 已訪問的狀態集合
    ///   - keepRecentCount: 要保留的最近狀態數量
    private static func partialCleanVisitedStates(
      visited: inout Set<SearchState>,
      keepRecentCount: Int
    ) {
      guard visited.count > keepRecentCount else { return }

      // 按距離排序，保留分數較高的狀態
      let sortedStates = visited.sorted { $0.distance > $1.distance }
      let statesToRemove = Array(sortedStates.dropFirst(keepRecentCount))

      // 先從 Set 中移除，再清理參據（避免 hash 不一致）
      for state in statesToRemove {
        visited.remove(state)
        state.gram = nil
        state.prev = nil
      }
    }

    /// 即時清理策略：直接清理各個資料結構，避免額外的 Set 集合
    /// - Parameters:
    ///   - visited: 已訪問的狀態集合
    ///   - openSet: 優先序列中剩餘的狀態
    ///   - leadingState: 初始狀態
    private static func batchCleanAllSearchStates(
      visited: Set<SearchState>,
      openSet: inout HybridPriorityQueue<PrioritizedState>,
      leadingState: SearchState
    ) {
      // 策略1: 直接清理 visited set 中的所有狀態
      for state in visited {
        state.gram = nil
        state.prev = nil
      }

      // 策略2: 直接清理 openSet 中剩餘的所有狀態
      while !openSet.isEmpty {
        if let prioritizedState = openSet.dequeue() {
          prioritizedState.state.gram = nil
          prioritizedState.state.prev = nil
        }
      }

      // 策略3: 清理 leadingState
      leadingState.gram = nil
      leadingState.prev = nil
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
      gram: Homa.Gram?,
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
      // 使用不可變的標識符來確保 hash 一致性
      self.originalGramRef = gram
      self.stableHash = Self.computeStableHash(gram: gram, position: position)
    }

    // MARK: Internal

    var gram: Homa.Gram? // 當前節點（可變，用於清理）
    let position: Int // 在輸入串中的位置
    var prev: SearchState? // 前一個狀態（可變以支援手動位址清理）
    var distance: Double // 累計分數
    let isOverridden: Bool

    // MARK: - Hashable 協定實作

    static func == (lhs: SearchState, rhs: SearchState) -> Bool {
      lhs.originalGramRef === rhs.originalGramRef && lhs.position == rhs.position
    }

    /// 清理單一 SearchState 的參據
    /// 注意：由於新的清理策略是直接清理各個集合，這個方法現在主要用於向下相容
    func cleanState() {
      gram = nil
      prev = nil
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(stableHash)
    }

    // MARK: Private

    // 用於穩定 hash 計算的不可變參據
    private let originalGramRef: Homa.Gram? // 原始節點參據（不可變）
    private let stableHash: Int // 預計算的穩定 hash 值

    private static func computeStableHash(gram: Homa.Gram?, position: Int) -> Int {
      var hasher = Hasher()
      if let gram = gram {
        hasher.combine(ObjectIdentifier(gram))
      } else {
        hasher.combine(0) // 為 nil 節點使用固定值
      }
      hasher.combine(position)
      return hasher.finalize()
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
