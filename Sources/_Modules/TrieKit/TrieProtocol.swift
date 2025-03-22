// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - VanguardTrieProtocol

public protocol VanguardTrieProtocol {
  typealias TNode = VanguardTrie.Trie.TNode
  typealias Entry = VanguardTrie.Trie.Entry
  typealias EntryType = VanguardTrie.Trie.EntryType

  var readingSeparator: Character { get }
  func getNodeIDs(keyArray: [String], filterType: EntryType, partiallyMatch: Bool) -> Set<Int>
  func getNode(nodeID: Int) -> TNode?
  func getEntries(node: TNode) -> [Entry]
}

extension VanguardTrieProtocol {
  var chopCaseSeparator: Character { "&" }

  /// 特殊函式，專門用來處理那種單個讀音位置有兩個讀音的情況。
  ///
  /// 這只可能是前端打拼音串之後被 Tekkon.PinyinTrie 分析出了多個結果。
  /// 比如說敲了漢語拼音 s 的話會被分析成兩個結果「ㄕ」和「ㄙ」。
  /// 這會以「ㄕ\(chopCaseSeparator)ㄙ」的形式插入注拼引擎、然後再被傳到這個 Trie 內來查詢。
  func getNodeIDs(
    keysChopped: [String],
    filterType: EntryType,
    partiallyMatch: Bool
  )
    -> [(keys: [String], ids: Set<Int>)] {
    // 單個讀音位置的多個可能性以 chopCaseSeparator 區隔。
    guard keysChopped.joined().contains(chopCaseSeparator) else {
      let result = getNodeIDs(
        keyArray: keysChopped,
        filterType: filterType,
        partiallyMatch: partiallyMatch
      )
      return [(keysChopped, result)]
    }

    var possibleReadings = [[String]]()

    // 遞歸函數生成所有組合可能性
    func generateCombinations(index: Int, current: [String]) {
      // 如果已經處理完所有切片，將當前組合加入結果
      if index >= keysChopped.count {
        possibleReadings.append(current)
        return
      }

      // 取得當前位置的所有候選項
      let candidates = keysChopped[index].split(separator: chopCaseSeparator)

      // 對每個候選項進行遞歸
      for candidate in candidates {
        var newCombination = current
        newCombination.append(candidate.description)
        generateCombinations(index: index + 1, current: newCombination)
      }
    }

    // 從索引0開始，使用空數組作為初始組合
    generateCombinations(index: 0, current: [])

    var result = [Int: (keys: [String], ids: Set<Int>)]()
    possibleReadings.forEach { keyArray in
      let nodeIDsFetched = getNodeIDs(
        keyArray: keyArray,
        filterType: filterType,
        partiallyMatch: partiallyMatch
      )
      nodeIDsFetched.forEach { nodeID in
        let changedIDs = result[keyArray.hashValue, default: (keyArray, [])].ids.union([nodeID])
        result[keyArray.hashValue, default: (keyArray, [])] = (keyArray, changedIDs)
      }
    }
    return Array(result.values)
  }

  func partiallyMatchedKeys(
    _ keys: [String],
    nodeIDs: Set<Int>,
    filterType: VanguardTrie.Trie.EntryType
  )
    -> Set<[String]> {
    guard !keys.isEmpty else { return [] }

    // 2. 準備收集結果與追蹤已處理節點，避免重複處理
    var result: Set<[String]> = []
    var processedNodes = Set<Int>()

    // 3. 對每個 NodeID 獲取對應節點、詞條和讀音
    for nodeID in nodeIDs {
      // 跳過已處理的節點
      guard !processedNodes.contains(nodeID),
            let node = getNode(nodeID: nodeID) else { continue }

      processedNodes.insert(nodeID)

      // 5. 提前獲取一次 entries 並重用
      let entries = getEntries(node: node)

      // 確保讀音數量相符
      let nodeReadings = node.readingKey.split(separator: readingSeparator).map(\.description)
      guard nodeReadings.count == keys.count else { continue }
      // 確保每個讀音都以對應的前綴開頭
      let allPrefixMatched = zip(keys, nodeReadings).allSatisfy { $1.hasPrefix($0) }
      guard allPrefixMatched else { continue }

      // 6. 過濾出符合條件的詞條
      let firstMatchedEntry = entries.first { entry in

        // 確保類型相符
        if !filterType.isEmpty, !filterType.contains(entry.typeID) {
          return false
        }
        return true
      }

      guard firstMatchedEntry != nil else { continue }

      // 7. 收集讀音
      result.insert(nodeReadings)
    }

    return result
  }

  public func hasGrams(
    _ keys: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool = false,
    partiallyMatchedKeysHandler: ((Set<[String]>) -> ())? = nil
  )
    -> Bool {
    guard !keys.isEmpty else { return false }

    if !partiallyMatch {
      // 對於精確比對，直接用 getNodeIDs
      let nodeIDs = getNodeIDs(keysChopped: keys, filterType: filterType, partiallyMatch: false)
      return !nodeIDs.isEmpty
    } else {
      // 增加快速路徑：如果不需要處理比對結果，只需檢查是否有相符的節點
      if partiallyMatchedKeysHandler == nil {
        return !getNodeIDs(keysChopped: keys, filterType: filterType, partiallyMatch: true).isEmpty
      } else {
        let nodeIDsChopped = getNodeIDs(
          keysChopped: keys,
          filterType: filterType,
          partiallyMatch: true
        )
        var partiallyMatchedKeysStack = Set<[String]>()
        nodeIDsChopped.forEach { keys, nodeIDs in
          let partiallyMatchedResultCurrent = partiallyMatchedKeys(
            keys,
            nodeIDs: nodeIDs,
            filterType: filterType
          )
          partiallyMatchedKeysStack.formUnion(partiallyMatchedResultCurrent)
        }
        partiallyMatchedKeysHandler?(partiallyMatchedKeysStack)
        return !partiallyMatchedKeysStack.isEmpty
      }
    }
  }

  public func queryGrams(
    _ keys: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool = false,
    partiallyMatchedKeysPostHandler: ((Set<[String]>) -> ())? = nil
  )
    -> [(keyArray: [String], value: String, probability: Double, previous: String?)] {
    guard !keys.isEmpty else { return [] }

    if !partiallyMatch {
      // 精確比對 - 現在也使用緩存提高效能
      let nodeIDsChopped = getNodeIDs(
        keysChopped: keys,
        filterType: filterType,
        partiallyMatch: false
      )
      let allNodeIDs = nodeIDsChopped.flatMap(\.ids).sorted()
      guard !allNodeIDs.isEmpty else { return [] }
      var processedNodeEntries = [Int: [Entry]]()
      var results = [(keyArray: [String], value: String, probability: Double, previous: String?)]()

      for nodeID in allNodeIDs {
        guard let node = getNode(nodeID: nodeID) else { continue }

        // 使用緩存避免重複查詢
        let entries: [Entry]
        if let cachedEntries = processedNodeEntries[nodeID] {
          entries = cachedEntries
        } else if let node = getNode(nodeID: nodeID) {
          entries = getEntries(node: node)
          processedNodeEntries[nodeID] = entries
        } else {
          continue
        }

        // 過濾符合類型的詞條
        var inserted = Set<Entry>()
        let filteredEntries = entries.filter { entry in
          guard filterType.isEmpty || filterType.contains(entry.typeID) else { return false }
          return inserted.insert(entry).inserted
        }

        results.append(contentsOf: filteredEntries.map { entry in
          entry.asTuple(
            with: node.readingKey.split(separator: readingSeparator).map(\.description)
          )
        })
      }

      return results
    } else {
      // 1. 獲取所有節點IDs
      let nodeIDsChopped = getNodeIDs(
        keysChopped: keys,
        filterType: filterType,
        partiallyMatch: true
      )
      let allNodeIDs = nodeIDsChopped.flatMap(\.ids).sorted()
      guard !allNodeIDs.isEmpty else { return [] }
      // 2. 獲取比對的讀音和節點，除非 handler 是 nil。
      defer {
        if let partiallyMatchedKeysPostHandler {
          var partiallyMatchedKeysStack = Set<[String]>()
          nodeIDsChopped.forEach { keys, nodeIDs in
            let partiallyMatchedResultCurrent = partiallyMatchedKeys(
              keys,
              nodeIDs: nodeIDs,
              filterType: filterType
            )
            partiallyMatchedKeysStack.formUnion(partiallyMatchedResultCurrent)
          }
          partiallyMatchedKeysPostHandler(partiallyMatchedKeysStack)
        }
      }

      // 使用緩存避免重複查詢
      var processedNodeEntries = [Int: [Entry]]()
      var results = [(keyArray: [String], value: String, probability: Double, previous: String?)]()

      // 3. 獲取每個節點的詞條
      nodeIDsChopped.forEach { currentKeys, nodeIDs in
        for nodeID in nodeIDs {
          guard let node = getNode(nodeID: nodeID) else { continue }
          let nodeReadings = node.readingKey.split(separator: readingSeparator).map(\.description)
          // 使用緩存避免重複查詢
          let entries: [Entry]
          if let cachedEntries = processedNodeEntries[nodeID] {
            entries = cachedEntries
          } else if let node = getNode(nodeID: nodeID) {
            entries = getEntries(node: node)
            processedNodeEntries[nodeID] = entries // 緩存結果
          } else {
            continue
          }
          guard nodeReadings.count == currentKeys.count else { continue }
          guard zip(currentKeys, nodeReadings).allSatisfy({
            let keyCases = $0.split(separator: chopCaseSeparator)
            for currentKeyCase in keyCases {
              if $1.hasPrefix(currentKeyCase) { return true }
            }
            return false
          }) else { continue }

          // 4. 過濾符合條件的詞條
          var inserted = Set<Entry>()
          let filteredEntries = entries.filter { entry in
            guard filterType.isEmpty || filterType.contains(entry.typeID) else { return false }
            return inserted.insert(entry).inserted
          }

          // 5. 將符合條件的詞條添加到結果中
          results.append(contentsOf: filteredEntries.map { entry in
            entry.asTuple(
              with: node.readingKey.split(separator: readingSeparator).map(\.description)
            )
          })
        }
      }

      return results
    }
  }

  /// 關聯詞語檢索，返回 Gram Raw 結果，不去除重複結果。
  ///
  /// 此處不以 anterior 作為參數，以免影響到之後的爬軌結果。
  ///
  /// - Remark: 如果想只獲取沒有 anterior 的結果的話，請將 anterior 設定為空字串。
  public func queryAssociatedPhrasesAsGrams(
    _ previous: (keyArray: [String], value: String),
    anterior anteriorValue: String? = nil,
    filterType: VanguardTrie.Trie.EntryType
  )
    -> [(keyArray: [String], value: String, probability: Double, previous: String?)]? {
    guard !previous.keyArray.isEmpty else { return nil }
    guard previous.keyArray.allSatisfy({ !$0.isEmpty }) else { return nil }
    guard !previous.value.isEmpty else { return nil }
    let prevSpanLength = previous.keyArray.count
    let nodeIDs = getNodeIDs(
      keyArray: previous.keyArray,
      filterType: filterType,
      partiallyMatch: true
    )
    guard !nodeIDs.isEmpty else { return nil }
    var resultsMap = [
      Int: (keyArray: [String], value: String, probability: Double, previous: String?, seq: Int)
    ]()
    nodeIDs.forEach { nodeID in
      guard let node = getNode(nodeID: nodeID) else { return }
      let nodeKeyArray = node.readingKey.split(separator: readingSeparator).map(\.description)
      /// 得前綴相等。
      guard Array(nodeKeyArray.prefix(prevSpanLength)) == previous.keyArray else { return }
      /// 得前綴幅長相等。
      guard nodeKeyArray.count > prevSpanLength else { return }
      getEntries(node: node).forEach { entry in
        /// 故意略過那些 Entry Value 的長度不等於幅長的資料值。
        guard entry.value.count == nodeKeyArray.count else { return }
        /// Value 的前綴也得與 previous.value 一致。
        guard entry.value.prefix(prevSpanLength) == previous.value else { return }
        /// 指定要過濾的資料種類。
        guard filterType.isEmpty || filterType.contains(entry.typeID) else { return }
        if let anteriorValue {
          if !anteriorValue.isEmpty {
            guard entry.previous == anteriorValue else { return }
          } else {
            guard entry.previous == nil else { return }
          }
        }
        let newResult = (
          keyArray: nodeKeyArray,
          value: entry.value,
          probability: entry.probability,
          previous: entry.previous,
          seq: resultsMap.count
        )
        let hashTag = "\(newResult.keyArray)::\(newResult.value)::\(newResult.previous ?? "NULL")"
        let theHash = hashTag.hashValue
        if let existingValue = resultsMap[theHash] {
          if existingValue.probability < newResult.probability {
            resultsMap[theHash] = newResult
          }
        } else {
          resultsMap[theHash] = newResult
        }
      }
    }
    guard !resultsMap.isEmpty else { return nil }
    var final = [(keyArray: [String], value: String, probability: Double, previous: String?)]()
    final = resultsMap.values.sorted {
      ($0.keyArray.count, $0.probability, $1.seq, $0.previous?.count ?? 0) > (
        $1.keyArray.count, $1.probability, $0.seq, $1.previous?.count ?? 0
      )
    }.map {
      (
        keyArray: $0.keyArray,
        value: $0.value,
        probability: $0.probability,
        previous: $0.previous
      )
    }
    guard !final.isEmpty else { return nil }
    return final
  }

  /// 關聯詞語檢索：僅用於ㄅ半輸入模式，有做過進階去重複處理。
  public func queryAssociatedPhrasesPlain(
    _ previous: (keyArray: [String], value: String),
    anterior anteriorValue: String? = nil,
    filterType: VanguardTrie.Trie.EntryType
  )
    -> [(keyArray: [String], value: String)]? {
    let rawResults = queryAssociatedPhrasesAsGrams(
      previous,
      anterior: anteriorValue,
      filterType: filterType
    )
    guard let rawResults else { return nil }
    let prevSpanLength = previous.keyArray.count
    var results = [(keyArray: [String], value: String)]()
    var inserted = Set<Int>()
    rawResults.forEach { entry in
      let newResult = (
        keyArray: Array(entry.keyArray[prevSpanLength...]),
        value: entry.value.map(\.description)[prevSpanLength...].joined()
      )
      let theHash = "\(newResult)".hashValue
      guard !inserted.contains(theHash) else { return }
      inserted.insert("\(newResult)".hashValue)
      results.append(newResult)
    }
    guard !results.isEmpty else { return nil }
    return results
  }
}
