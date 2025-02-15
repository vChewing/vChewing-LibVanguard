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
    ///   - gramExistenceChecker: 元圖在庫檢查器。
    ///   - config: 組態設定。
    public init(
      gramQuerier: @escaping Homa.GramQuerier,
      gramExistenceChecker: @escaping Homa.GramExistenceChecker,
      config: Config = Config()
    ) {
      self.gramQuerier = gramQuerier
      self.gramExistenceChecker = gramExistenceChecker
      self.config = config
    }

    /// 以指定組字器生成拷貝。
    /// - Remark: 因為 Node 不是 Struct，所以會在 Assembler 被拷貝的時候無法被真實複製。
    /// 這樣一來，Assembler 複製品當中的 Node 的變化會被反應到原先的 Assembler 身上。
    /// 這在某些情況下會造成意料之外的混亂情況，所以需要引入一個拷貝用的建構子。
    public init(from target: Assembler) {
      self.config = target.config.hardCopy
      self.gramQuerier = target.gramQuerier
      self.gramExistenceChecker = target.gramExistenceChecker
    }

    // MARK: Public

    /// 就文字輸入方向而言的方向。
    public enum TypingDirection { case front, rear }
    /// 軌格增減行為。
    public enum ResizeBehavior { case expand, shrink }

    /// 元圖存取專用 API。
    public var gramQuerier: Homa.GramQuerier
    /// 元圖在庫檢查器。
    public var gramExistenceChecker: Homa.GramExistenceChecker
    /// 組態設定。
    public private(set) var config = Config()

    /// 最近一次爬軌結果。
    public var assembledNodes: [Node] {
      get { config.assembledNodes }
      set { config.assembledNodes = newValue }
    }

    /// 該組字器已經插入的的索引鍵，以陣列的形式存放。
    public private(set) var keys: [String] {
      get { config.keys }
      set { config.keys = newValue }
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
    /// - Returns: 該操作是否成功執行。
    @discardableResult
    public func insertKey(_ key: String) -> Bool {
      guard !key.isEmpty, gramExistenceChecker([key]) else { return false }
      keys.insert(key, at: cursor)
      let gridBackup = spans
      resizeGrid(at: cursor, do: .expand)
      let nodesInserted = update()
      // 用來在 langModel.hasUnigramsFor() 結果不準確的時候防呆、恢復被搞壞的 spans。
      if nodesInserted == 0 {
        spans = gridBackup
        return false
      }
      cursor += 1 // 游標必須得在執行 update() 之後才可以變動。
      return true
    }

    /// 朝著指定方向砍掉一個與游標相鄰的讀音。
    ///
    /// 在威注音的術語體系當中，「與文字輸入方向相反的方向」為向後（Rear），反之則為向前（Front）。
    /// 如果是朝著與文字輸入方向相反的方向砍的話，游標位置會自動遞減。
    /// - Parameter direction: 指定方向（相對於文字輸入方向而言）。
    /// - Returns: 該操作是否成功執行。
    @discardableResult
    public func dropKey(direction: TypingDirection) -> Bool {
      let isBackSpace: Bool = direction == .rear ? true : false
      guard cursor != (isBackSpace ? 0 : keys.count) else { return false }
      keys.remove(at: cursor - (isBackSpace ? 1 : 0))
      cursor -= isBackSpace ? 1 : 0 // 在縮節之前。
      resizeGrid(at: cursor, do: .shrink)
      update()
      return true
    }

    /// 按幅位來前後移動游標。
    ///
    /// 在威注音的術語體系當中，「與文字輸入方向相反的方向」為向後（Rear），反之則為向前（Front）。
    /// - Parameters:
    ///   - direction: 指定移動方向（相對於文字輸入方向而言）。
    ///   - isMarker: 要移動的是否為作為選擇標記的副游標（而非打字用的主游標）。
    /// 具體用法可以是這樣：你在標記模式下，
    /// 如果出現了「副游標切了某個字音數量不相等的節點」的情況的話，
    /// 則直接用這個函式將副游標往前推到接下來的正常的位置上。
    /// // 該特性不適用於小麥注音，除非小麥注音重新設計 InputState 且修改 KeyHandler、
    /// 將標記游標交給敝引擎來管理。屆時，NSStringUtils 將徹底卸任。
    /// - Returns: 該操作是否順利完成。
    @discardableResult
    public func jumpCursorBySpan(
      to direction: TypingDirection,
      isMarker: Bool = false
    )
      -> Bool {
      var target = isMarker ? marker : cursor
      switch direction {
      case .front:
        if target == length { return false }
      case .rear:
        if target == 0 { return false }
      }
      guard let currentRegion = assembledNodes.cursorRegionMap[target] else { return false }
      let guardedCurrentRegion = min(assembledNodes.count - 1, currentRegion)
      let aRegionForward = max(currentRegion - 1, 0)
      let currentRegionBorderRear: Int = assembledNodes[0 ..< currentRegion].map(\.spanLength)
        .reduce(
          0,
          +
        )
      switch target {
      case currentRegionBorderRear:
        switch direction {
        case .front:
          target =
            (currentRegion > assembledNodes.count)
              ? keys.count : assembledNodes[0 ... guardedCurrentRegion].map(\.spanLength).reduce(
                0,
                +
              )
        case .rear:
          target = assembledNodes[0 ..< aRegionForward].map(\.spanLength).reduce(0, +)
        }
      default:
        switch direction {
        case .front:
          target = currentRegionBorderRear + assembledNodes[guardedCurrentRegion].spanLength
        case .rear:
          target = currentRegionBorderRear
        }
      }
      switch isMarker {
      case false: cursor = target
      case true: marker = target
      }
      return true
    }

    /// 根據當前狀況更新整個組字器的節點文脈。
    /// - Parameter updateExisting: 是否根據目前的語言模型的資料狀態來對既有節點更新其內部的單元圖陣列資料。
    /// 該特性可以用於「在選字窗內屏蔽了某個詞之後，立刻生效」這樣的軟體功能需求的實現。
    /// - Returns: 新增或影響了多少個節點。如果返回「0」則表示可能發生了錯誤。
    @discardableResult
    public func update(updateExisting: Bool = false) -> Int {
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
      return nodesChanged
    }

    // MARK: Private

    /// 從元圖存取專用 API 將獲取的結果轉為元圖、以供 Nodes 使用。
    /// - Parameter keyArray: 讀音陣列。
    /// - Returns: 元圖陣列。
    private func queryGrams(using keyArray: [String]) -> [Homa.Gram] {
      gramQuerier(keyArray).map {
        Homa.Gram(
          keyArray: $0.keyArray,
          current: $0.value,
          previous: $0.previous,
          probability: $0.probability
        )
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

// MARK: - Extending Assembler for NodeSpan.

extension Homa.Assembler {
  /// 找出所有與該位置重疊的節點。其返回值為一個節錨陣列（包含節點、以及其起始位置）。
  /// - Parameter location: 游標位置。
  /// - Returns: 一個包含所有與該位置重疊的節點的陣列。
  public func fetchOverlappingNodes(at givenLocation: Int) -> [(location: Int, node: Homa.Node)] {
    var results = [(location: Int, node: Homa.Node)]()
    let givenLocation = max(0, min(givenLocation, keys.count - 1))
    guard spans.indices.contains(givenLocation) else { return results }

    // 先獲取該位置的所有單字節點。
    spans[givenLocation].keys.sorted().forEach { theSpanLength in
      guard let node = spans[givenLocation][theSpanLength] else { return }
      Self.insertAnchor(spanIndex: givenLocation, node: node, to: &results)
    }

    // 再獲取以當前位置結尾或開頭的節點。
    let begin: Int = givenLocation - min(givenLocation, maxSpanLength - 1)
    (begin ..< givenLocation).forEach { theLocation in
      let (A, B): (Int, Int) = (givenLocation - theLocation + 1, spans[theLocation].maxLength)
      guard A <= B else { return }
      (A ... B).forEach { theLength in
        guard let node = spans[theLocation][theLength] else { return }
        Self.insertAnchor(spanIndex: theLocation, node: node, to: &results)
      }
    }

    return results
  }

  /// 要在 fetchOverlappingNodes() 內使用的一個工具函式。
  private static func insertAnchor(
    spanIndex location: Int, node: Homa.Node,
    to targetContainer: inout [(location: Int, node: Homa.Node)]
  ) {
    guard !node.keyArray.joined().isEmpty else { return }
    let anchor = (location: location, node: node)
    for i in 0 ... targetContainer.count {
      guard !targetContainer.isEmpty else { break }
      guard targetContainer[i].node.spanLength <= anchor.node.spanLength else { continue }
      targetContainer.insert(anchor, at: i)
      return
    }
    guard targetContainer.isEmpty else { return }
    targetContainer.append(anchor)
  }
}

// MARK: - Extending Assembler for Candidates.

extension Homa.Assembler {
  /// 規定候選字陣列內容的獲取範圍類型：
  /// - all: 不只包含其它兩類結果，還允許游標穿插候選字。
  /// - beginAt: 僅獲取從當前游標位置開始的節點內的候選字。
  /// - endAt 僅獲取在當前游標位置結束的節點內的候選字。
  public enum CandidateFetchFilter { case all, beginAt, endAt }

  /// 返回在當前位置的所有候選字詞（以詞音配對的形式）。如果組字器內有幅位、且游標
  /// 位於組字器的（文字輸入順序的）最前方（也就是游標位置的數值是最大合規數值）的
  /// 話，那麼這裡會對 location 的位置自動減去 1、以免去在呼叫該函式後再處理的麻煩。
  /// - Parameter location: 游標位置，必須是顯示的游標位置、不得做任何事先糾偏處理。
  /// - Returns: 候選字音配對陣列。
  public func fetchCandidates(
    at givenLocation: Int? = nil, filter givenFilter: CandidateFetchFilter = .all
  )
    -> [Homa.CandidatePairWeighted] {
    var result = [Homa.CandidatePairWeighted]()
    guard !keys.isEmpty else { return result }
    var location = max(min(givenLocation ?? cursor, keys.count), 0)
    var filter = givenFilter
    if filter == .endAt {
      if location == keys.count { filter = .all }
      location -= 1
    }
    location = max(min(location, keys.count - 1), 0)
    let anchors: [(location: Int, node: Homa.Node)] = fetchOverlappingNodes(at: location)
    let keyAtCursor = keys[location]
    anchors.forEach { theAnchor in
      let theNode = theAnchor.node
      theNode.grams.forEach { gram in
        guard gram.previous == nil else { return } // 不要讓雙元圖的結果出現在選字窗內。
        switch filter {
        case .all:
          // 得加上這道篩選，不然會出現很多無效結果。
          if !theNode.keyArray4Query.contains(keyAtCursor) { return }
        case .beginAt:
          guard theAnchor.location == location else { return }
        case .endAt:
          guard theNode.keyArray4Query.last == keyAtCursor else { return }
          switch theNode.spanLength {
          case 2... where theAnchor.location + theAnchor.node.spanLength - 1 != location: return
          default: break
          }
        }
        result.append((
          pair: (keyArray: theNode.keyArray, value: gram.current),
          weight: gram.probability
        ))
      }
    }
    return result
  }

  /// 使用給定的候選字（詞音配對），將給定位置的節點的候選字詞改為與之一致的候選字詞。
  ///
  /// 該函式僅用作過程函式。
  /// - Parameters:
  ///   - candidate: 指定用來覆寫為的候選字（詞音鍵值配對）。
  ///   - location: 游標位置。
  ///   - overrideType: 指定覆寫行為。
  /// - Returns: 該操作是否成功執行。
  @discardableResult
  public func overrideCandidate(
    _ candidate: Homa.CandidatePair, at location: Int,
    type overrideType: Homa.Node.OverrideType = .withSpecified
  )
    -> Bool {
    overrideCandidateAgainst(
      keyArray: candidate.keyArray,
      at: location,
      value: candidate.value,
      type: overrideType
    )
  }

  /// 使用給定的候選字詞字串，將給定位置的節點的候選字詞改為與之一致的候選字詞。
  ///
  /// 注意：如果有多個「單元圖資料值雷同、卻讀音不同」的節點的話，該函式的行為結果不可控。
  /// - Parameters:
  ///   - candidate: 指定用來覆寫為的候選字（字串）。
  ///   - location: 游標位置。
  ///   - overrideType: 指定覆寫行為。
  /// - Returns: 該操作是否成功執行。
  @discardableResult
  public func overrideCandidateLiteral(
    _ candidate: String,
    at location: Int, overrideType: Homa.Node.OverrideType = .withSpecified
  )
    -> Bool {
    overrideCandidateAgainst(keyArray: nil, at: location, value: candidate, type: overrideType)
  }

  // MARK: Internal implementations.

  /// 使用給定的候選字（詞音配對）、或給定的候選字詞字串，將給定位置的節點的候選字詞改為與之一致的候選字詞。
  /// - Parameters:
  ///   - keyArray: 索引鍵陣列，也就是詞音配對當中的讀音。
  ///   - location: 游標位置。
  ///   - value: 資料值。
  ///   - type: 指定覆寫行為。
  /// - Returns: 該操作是否成功執行。
  internal func overrideCandidateAgainst(
    keyArray: [String]?,
    at location: Int,
    value: String,
    type: Homa.Node.OverrideType
  )
    -> Bool {
    let location = max(min(location, keys.count), 0) // 防呆
    var arrOverlappedNodes: [(location: Int, node: Homa.Node)] = fetchOverlappingNodes(at: min(
      keys.count - 1,
      location
    ))
    var overridden: (location: Int, node: Homa.Node)?
    for anchor in arrOverlappedNodes {
      if let keyArray, !anchor.node.allActualKeyArraysCached.contains(keyArray) {
        continue
      }
      if !anchor.node.selectOverrideGram(value: value, type: type) { continue }
      overridden = anchor
      break
    }

    guard let overridden else { return false } // 啥也不覆寫。

    (overridden.location ..< min(spans.count, overridden.location + overridden.node.spanLength))
      .forEach { i in
        /// 咱們還得弱化所有在相同的幅位座標的節點的複寫權重。舉例說之前爬軌的結果是「A BC」
        /// 且 A 與 BC 都是被覆寫的結果，然後使用者現在在與 A 相同的幅位座標位置
        /// 選了「DEF」，那麼 BC 的覆寫狀態就有必要重設（但 A 不用重設，因為已經設定過了。）。
        arrOverlappedNodes = fetchOverlappingNodes(at: i)
        arrOverlappedNodes.forEach { anchor in
          if anchor.node == overridden.node { return }
          let anchorNodeKeyJoined = anchor.node.keyArray4Query.joined(separator: "\t")
          let overriddenNodeKeyJoined = overridden.node.keyArray4Query.joined(separator: "\t")
          guard let anchorNodeValue = anchor.node.value else { return }
          guard let overriddenNodeValue = overridden.node.value else { return }
          var shouldReset = !overriddenNodeKeyJoined.has(string: anchorNodeKeyJoined)
          shouldReset = shouldReset || !overriddenNodeValue.has(string: anchorNodeValue)
          if shouldReset {
            anchor.node.reset()
            return
          }
          anchor.node.overridingScore /= 4
        }
      }
    return true
  }
}
