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

      var stateCleaningTasks: [() -> ()] = []
      defer {
        // 確保所有資料結構都被清理
        stateCleaningTasks.forEach { $0() }
        stateCleaningTasks.removeAll()
        visited.removeAll()
        bestScore.removeAll()
      }

      // 初期化起始狀態。
      let leadingGram = Homa.Gram(keyArray: ["$LEADING"], current: "")
      let leadingState = SearchState(
        gram: leadingGram,
        position: 0,
        prev: nil,
        distance: 0,
        isOverridden: false,
        cleaningTaskRegister: &stateCleaningTasks,
        pathFinder: self
      )
      openSet.enqueue(PrioritizedState(state: leadingState))
      bestScore[0] = 0

      // 追蹤最佳結果。
      var bestFinalState: SearchState?
      var bestFinalScore = Double(Int32.min)

      // 主要 Dijkstra 迴圈。
      while !openSet.isEmpty {
        guard let currentState = openSet.dequeue()?.state else { break }
        stateCleaningTasks.append(currentState.cleanChainRecursively)

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
            isOverridden: nextNode.isOverridden,
            cleaningTaskRegister: &stateCleaningTasks,
            pathFinder: self
          )

          bestScore[nextPos] = newScore
          openSet.enqueue(PrioritizedState(state: nextState))
        }
      }

      // 從最佳終止狀態重建路徑。
      guard let finalState = bestFinalState else {
        return
      }

      var pathGrams: [Homa.GramInPath] = []
      var current: SearchState? = finalState

      while let state = current {
        defer {
          state.prev = nil
          state.gram = nil
        }
        // 排除起始和結束的虛擬節點。
        if let stateGram = state.gram, stateGram !== leadingGram {
          pathGrams.insert(
            .init(gram: stateGram, isOverridden: state.isOverridden),
            at: 0
          )
        }
        current = state.prev
        // 備註：此處不需要手動 ASAN，因為沒有參據循環（Retain Cycle）。
      }

      newassembledSentence = pathGrams
      // 清理路徑重建過程中的臨時陣列
      pathGrams.removeAll()
    }

    deinit {
      #if DEBUG
        if searchStateCreatedCount != searchStateDestroyedCount {
          print(
            "PathFinder 記憶體洩漏檢測: 建立了 \(searchStateCreatedCount) 個 SearchState，但只析構了 \(searchStateDestroyedCount) 個"
          )
        }
      #endif
    }

    // MARK: Private

    // MARK: - SearchState 記憶體追蹤

    private var searchStateCreatedCount: Int = 0
    private var searchStateDestroyedCount: Int = 0
  }
}

extension Homa.PathFinder {
  // MARK: - SearchState

  /// 用於追蹤搜尋過程中的狀態。
  /// - Note: 採用弱引用設計以最佳化記憶體使用。
  private final class SearchState: Hashable {
    // MARK: Lifecycle

    /// 初期化搜尋狀態。
    /// - Parameters:
    ///   - gram: 當前節點。
    ///   - position: 在輸入串中的位置。
    ///   - prev: 前一個狀態。
    ///   - distance: 到達此狀態的累計分數。
    ///   - isOverridden: 是否被覆寫。
    ///   - cleaningTaskRegister: 登記自毀任務池。
    ///   - pathFinder: PathFinder 實例，用於更新計數器。
    init(
      gram: Homa.Gram?,
      position: Int,
      prev: SearchState?,
      distance: Double = Double(Int.min),
      isOverridden: Bool,
      cleaningTaskRegister: inout [() -> ()],
      pathFinder: Homa.PathFinder
    ) {
      self.gram = gram
      self.position = position
      self.prev = prev
      self.distance = distance
      self.isOverridden = isOverridden
      self.pathFinder = pathFinder
      // 使用不可變的標識符來確保 hash 一致性
      self.originalGramRef = gram
      self.stableHash = Self.computeStableHash(gram: gram, position: position)
      cleaningTaskRegister.append(cleanChainRecursively)
      // 更新建立計數器
      pathFinder.searchStateCreatedCount += 1
      #if DEBUG
        // 移除個別的建立訊息
      #endif
    }

    deinit {
      // 更新析構計數器
      pathFinder?.searchStateDestroyedCount += 1
      gram = nil
      prev = nil
      pathFinder = nil
      #if DEBUG
        // 移除個別的析構訊息
      #endif
    }

    // MARK: Internal

    weak var gram: Homa.Gram? // 當前節點（可變，用於清理）
    let position: Int // 在輸入串中的位置
    weak var prev: SearchState? // 前一個狀態（可變以支援手動位址清理）
    var distance: Double // 累計分數
    let isOverridden: Bool
    weak var pathFinder: Homa.PathFinder? // PathFinder 弱引用

    // MARK: - Hashable 協定實作

    static func == (lhs: SearchState, rhs: SearchState) -> Bool {
      lhs.originalGramRef === rhs.originalGramRef && lhs.position == rhs.position
    }

    /// 清理整個 SearchState 鏈條，從當前節點開始向後遞歸清理
    /// 採用深度優先遍歷策略，確保每個節點都被清理
    func cleanChainRecursively() {
      var visited = Set<ObjectIdentifier>()
      var stack: [SearchState] = []
      stack.append(self)

      while !stack.isEmpty {
        let current = stack.removeLast()
        let currentId = ObjectIdentifier(current)

        // 避免重複清理和無限循環
        guard !visited.contains(currentId) else { continue }
        visited.insert(currentId)

        // 在清理前，將 prev 加入堆疊（如果存在）
        if let prevState = current.prev {
          stack.append(prevState)
        }

        // 清理當前節點
        current.gram = nil
        current.prev?.cleanChainRecursively()
        current.prev = nil
      }
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(stableHash)
    }

    // MARK: Private

    // 用於穩定 hash 計算的不可變參據
    private weak var originalGramRef: Homa.Gram? // 原始節點參據（不可變，弱引用）
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

  // MARK: - PrioritizedState

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
