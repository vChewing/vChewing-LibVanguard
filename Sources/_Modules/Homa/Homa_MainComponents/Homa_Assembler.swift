// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - Homa.Assembler

extension Homa {
  /// 一個組字器用來在給定一系列的索引鍵的情況下（藉由一系列的觀測行為）返回一套資料值。
  ///
  /// 用於輸入法的話，給定的索引鍵可以是注音、且返回的資料值都是漢語字詞組合。該組字器
  /// 還可以用來對文章做分節處理：此時的索引鍵為漢字，返回的資料值則是漢語字詞分節組合。
  public final class Assembler {
    // MARK: Lifecycle

    /// 初期化一個組字器。
    /// - Parameters:
    ///   - gramQuerier: 元圖存取專用 API。
    ///   - gramAvailabilityChecker: 元圖在庫檢查器。
    ///   - config: 組態設定。
    public init(
      gramQuerier: @escaping Homa.GramQuerier,
      gramAvailabilityChecker: @escaping Homa.GramAvailabilityChecker,
      config: Config = Config()
    ) {
      self.gramQuerier = gramQuerier
      self.gramAvailabilityChecker = gramAvailabilityChecker
      self.config = config
    }

    /// 以指定組字器生成拷貝。
    /// - Remark: 因為 Node 不是 Struct，所以會在 Assembler 被拷貝的時候無法被真實複製。
    /// 這樣一來，Assembler 複製品當中的 Node 的變化會被反應到原先的 Assembler 身上。
    /// 這在某些情況下會造成意料之外的混亂情況，所以需要引入一個拷貝用的建構子。
    public init(from target: Assembler) {
      self.config = target.config.hardCopy
      self.gramQuerier = target.gramQuerier
      self.gramAvailabilityChecker = target.gramAvailabilityChecker
    }

    // MARK: Public

    /// 就文字輸入方向而言的方向。
    public enum TypingDirection { case front, rear }
    /// 軌格增減行為。
    public enum ResizeBehavior { case expand, shrink }

    /// 元圖存取專用 API。
    public var gramQuerier: Homa.GramQuerier
    /// 元圖在庫檢查器。
    public var gramAvailabilityChecker: Homa.GramAvailabilityChecker
    /// 組態設定。
    public private(set) var config = Config()

    /// 最近一次爬軌結果。
    public var assembledSentence: [GramInPath] {
      get { config.assembledSentence }
      set { config.assembledSentence = newValue }
    }

    /// 該組字器已經插入的的索引鍵，以陣列的形式存放。
    public private(set) var keys: [String] {
      get { config.keys }
      set { config.keys = newValue }
    }

    /// 回傳當前組句結果所對應的真實讀音索引鍵陣列。
    ///
    /// 護摩引擎支援對讀音鍵的部分比對，所以需要這個 API 以返回真實結果。
    public var actualKeys: [String] {
      config.assembledSentence.keyArrays.flatMap(\.self)
    }

    /// 該組字器的幅位單元陣列。
    public private(set) var spans: [NodeSpan] {
      get { config.spans }
      set { config.spans = newValue }
    }

    /// 該組字器的敲字游標位置。
    public var cursor: Int {
      get { config.cursor }
      set { config.cursor = newValue }
    }

    /// 該組字器的標記器（副游標）位置。
    public var marker: Int {
      get { config.marker }
      set { config.marker = newValue }
    }

    /// 該軌格內可以允許的最大幅位長度。
    public var maxSpanLength: Int {
      get { config.maxSpanLength }
      set { config.maxSpanLength = newValue }
    }

    /// 該組字器的長度，組字器內已經插入的單筆索引鍵的數量，也就是內建漢字讀音的數量（唯讀）。
    /// - Remark: 理論上而言，spans.count 也是這個數。
    /// 但是，為了防止萬一，就用了目前的方法來計算。
    public var length: Int { config.length }

    /// 組字器是否為空。
    public var isEmpty: Bool { spans.isEmpty && keys.isEmpty }

    /// 該組字器的硬拷貝。
    /// - Remark: 因為 Node 不是 Struct，所以會在 Assembler 被拷貝的時候無法被真實複製。
    /// 這樣一來，Assembler 複製品當中的 Node 的變化會被反應到原先的 Assembler 身上。
    /// 這在某些情況下會造成意料之外的混亂情況，所以需要引入一個拷貝用的建構子。
    public var copy: Assembler { .init(from: self) }

    /// 生成用以交給 GraphViz 診斷的資料檔案內容，純文字。
    public func dumpDOT(verticalGraph: Bool = false) -> String {
      let rankDirection = verticalGraph ? "TB" : "LR"
      var strOutput = "digraph {\ngraph [ rankdir=\(rankDirection) ];\nBOS;\n"
      spans.enumerated().forEach { p, span in
        span.keys.sorted().forEach { ni in
          guard let np = span[ni], let npValue = np.value else { return }
          if p == 0 { strOutput.append("BOS -> \(npValue);\n") }
          strOutput.append("\(npValue);\n")
          if (p + ni) < spans.count {
            let destinationSpan = spans[p + ni]
            destinationSpan.keys.sorted().forEach { q in
              guard let dnValue = destinationSpan[q]?.value else { return }
              strOutput.append(npValue + " -> " + dnValue + ";\n")
            }
          }
          guard (p + ni) == spans.count else { return }
          strOutput.append(npValue + " -> EOS;\n")
        }
      }
      strOutput.append("EOS;\n}\n")
      return strOutput.description
    }

    /// 重置包括游標在內的各項參數，且清空各種由組字器生成的內部資料。
    ///
    /// 將已經被插入的索引鍵陣列與幅位單元陣列（包括其內的節點）全部清空。
    /// 最近一次的爬軌結果陣列也會被清空。游標跳轉換算表也會被清空。
    public func clear() {
      config.clear()
    }

    /// 在游標位置插入給定的索引鍵。
    /// - Parameter key: 要插入的索引鍵。
    public func insertKey(_ key: String) throws {
      guard !key.isEmpty else {
        throw Homa.Exception.givenKeyIsEmpty
      }
      guard gramAvailabilityChecker([key]) else {
        throw Homa.Exception.givenKeyHasNoResults
      }
      keys.insert(key, at: cursor)
      let gridBackup = spans
      resizeGrid(at: cursor, do: .expand)
      do {
        try assignNodes()
      } catch {
        // 用來在 langModel.hasUnigramsFor() 結果不準確的時候防呆、恢復被搞壞的 spans。
        spans = gridBackup
        throw error
      }
      cursor += 1 // 游標必須得在執行 update() 之後才可以變動。
    }

    /// 朝著指定方向砍掉一個與游標相鄰的讀音。
    ///
    /// 在護摩引擎所遵循的術語體系當中，「與文字輸入方向相反的方向」為向後（Rear），反之則為向前（Front）。
    /// 如果是朝著與文字輸入方向相反的方向砍的話，游標位置會自動遞減。
    /// - Parameter direction: 指定方向（相對於文字輸入方向而言）。
    public func dropKey(direction: TypingDirection) throws {
      let isBackSpace: Bool = direction == .rear ? true : false
      guard cursor != (isBackSpace ? 0 : keys.count) else {
        throw Homa.Exception.deleteKeyAgainstBorder
      }
      keys.remove(at: cursor - (isBackSpace ? 1 : 0))
      cursor -= isBackSpace ? 1 : 0 // 在縮節之前。
      resizeGrid(at: cursor, do: .shrink)
      try? assignNodes() // 此處拋出的異常已無利用之意義，放行即可。
    }

    /// 按幅位來前後移動游標。
    ///
    /// 在護摩引擎所遵循的術語體系當中，「與文字輸入方向相反的方向」為向後（Rear），反之則為向前（Front）。
    /// - Parameters:
    ///   - direction: 指定移動方向（相對於文字輸入方向而言）。
    ///   - isMarker: 要移動的是否為作為選擇標記的副游標（而非敲字用的主游標）。
    /// 具體用法可以是這樣：你在標記模式下，
    /// 如果出現了「副游標切了某個字音數量不相等的節點」的情況的話，
    /// 則直接用這個函式將副游標往前推到接下來的正常的位置上。
    public func jumpCursorBySpan(
      to direction: TypingDirection,
      isMarker: Bool = false
    ) throws {
      var target = isMarker ? marker : cursor
      switch (direction, target) {
      case (.front, length), (.rear, 0):
        throw Homa.Exception.cursorAlreadyAtBorder
      default: break
      }
      guard let currentRegion = assembledSentence.cursorRegionMap[target] else {
        throw Homa.Exception.cursorRegionMapMatchingFailure
      }
      let guardedCurrentRegion = min(assembledSentence.count - 1, currentRegion)
      let aRegionForward = max(currentRegion - 1, 0)
      let currentRegionBorderRear: Int = assembledSentence[
        0 ..< currentRegion
      ].map(\.spanLength).reduce(0, +)
      switch target {
      case currentRegionBorderRear:
        switch direction {
        case .front:
          target = (currentRegion > assembledSentence.count)
            ? keys.count
            : assembledSentence[0 ... guardedCurrentRegion].map(\.spanLength).reduce(0, +)
        case .rear:
          target = assembledSentence[0 ..< aRegionForward].map(\.spanLength).reduce(0, +)
        }
      default:
        switch direction {
        case .front:
          target = currentRegionBorderRear + assembledSentence[guardedCurrentRegion].spanLength
        case .rear:
          target = currentRegionBorderRear
        }
      }
      switch isMarker {
      case false: cursor = target
      case true: marker = target
      }
    }

    /// 根據當前狀況更新整個組字器的節點文脈。
    /// - Parameter updateExisting: 是否根據目前的語言模型的資料狀態來對既有節點更新其內部的單元圖陣列資料。
    /// 該特性可以用於「在選字窗內屏蔽了某個詞之後，立刻生效」這樣的軟體功能需求的實現。
    public func assignNodes(updateExisting: Bool = false) throws {
      let maxSpanLength = maxSpanLength
      let rangeOfPositions: Range<Int>
      if updateExisting {
        rangeOfPositions = spans.indices
      } else {
        let lowerbound = Swift.max(0, cursor - maxSpanLength)
        let upperbound = Swift.min(cursor + maxSpanLength, keys.count)
        rangeOfPositions = lowerbound ..< upperbound
      }
      var nodesChanged = 0
      rangeOfPositions.forEach { position in
        let rangeOfLengths = 1 ... min(maxSpanLength, rangeOfPositions.upperBound - position)
        rangeOfLengths.forEach { theLength in
          guard position + theLength <= keys.count, position >= 0 else { return }
          let keyArraySliced = keys[position ..< (position + theLength)].map(\.description)
          if (0 ..< spans.count).contains(position), let theNode = spans[position][theLength] {
            if !updateExisting { return }
            let unigrams: [Homa.Gram] = queryGrams(using: keyArraySliced)
            // 自動銷毀無效的節點。
            if unigrams.isEmpty {
              if theNode.keyArray.count == 1 { return }
              spans[position][theNode.spanLength] = nil
            } else {
              theNode.syncingGrams(from: unigrams)
            }
            nodesChanged += 1
            return
          }
          let unigrams: [Homa.Gram] = queryGrams(using: keyArraySliced)
          guard !unigrams.isEmpty else { return }
          // 這裡原本用 SpanUnit.addNode 來完成的，但直接當作辭典來互動的話也沒差。
          spans[position][theLength] = .init(keyArray: keyArraySliced, grams: unigrams)
          nodesChanged += 1
        }
      }
      guard nodesChanged != 0 else { throw Homa.Exception.noNodesAssigned }
    }

    // MARK: Private

    /// 從元圖存取專用 API 將獲取的結果轉為元圖、以供 Nodes 使用。
    /// - Parameter keyArray: 讀音陣列。
    /// - Returns: 元圖陣列。
    private func queryGrams(using keyArray: [String]) -> [Homa.Gram] {
      gramQuerier(keyArray).map { Homa.Gram($0) }.sorted {
        $0.probability > $1.probability
      }
    }
  }
}

// MARK: - Internal Methods (Maybe Public)

extension Homa.Assembler {
  /// 在該軌格的指定幅位座標擴增或減少一個幅位單元。
  /// - Parameters:
  ///   - location: 給定的幅位座標。
  ///   - action: 指定是擴張還是縮減一個幅位。
  private func resizeGrid(at location: Int, do action: ResizeBehavior) {
    let location = max(min(location, spans.count), 0) // 防呆
    switch action {
    case .expand:
      spans.insert(.init(), at: location)
      if [0, spans.count].contains(location) { return }
    case .shrink:
      if spans.count == location { return }
      spans.remove(at: location)
    }
    dropWreckedNodes(at: location)
  }

  /// 扔掉所有被 resizeGrid() 損毀的節點。
  ///
  /// 拿新增幅位來打比方的話，在擴增幅位之前：
  /// ```
  /// Span Index 0   1   2   3
  ///                (---)
  ///                (-------)
  ///            (-----------)
  /// ```
  /// 在幅位座標 2 (SpanIndex = 2) 的位置擴增一個幅位之後:
  /// ```
  /// Span Index 0   1   2   3   4
  ///                (---)
  ///                (XXX?   ?XXX) <-被扯爛的節點
  ///            (XXXXXXX?   ?XXX) <-被扯爛的節點
  /// ```
  /// 拿縮減幅位來打比方的話，在縮減幅位之前：
  /// ```
  /// Span Index 0   1   2   3
  ///                (---)
  ///                (-------)
  ///            (-----------)
  /// ```
  /// 在幅位座標 2 的位置就地砍掉一個幅位之後:
  /// ```
  /// Span Index 0   1   2   3   4
  ///                (---)
  ///                (XXX? <-被砍爛的節點
  ///            (XXXXXXX? <-被砍爛的節點
  /// ```
  /// - Parameter location: 給定的幅位座標。
  internal func dropWreckedNodes(at location: Int) {
    let location = max(min(location, spans.count), 0) // 防呆
    guard !spans.isEmpty else { return }
    let affectedLength = maxSpanLength - 1
    let begin = max(0, location - affectedLength)
    guard location >= begin else { return }
    (begin ..< location).forEach { delta in
      ((location - delta + 1) ... maxSpanLength).forEach { theLength in
        spans[delta][theLength] = nil
      }
    }
  }
}
