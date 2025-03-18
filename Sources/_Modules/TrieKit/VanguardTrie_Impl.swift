// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - Extending Methods (Entry).

extension VanguardTrie.Trie.Entry {
  public func asTuple(with readings: [String]) -> (
    keyArray: [String],
    value: String,
    probability: Double,
    previous: String?
  ) {
    (
      keyArray: readings,
      value: value,
      probability: probability,
      previous: previous
    )
  }

  public func isReadingValueLengthMatched(readings: [String]) -> Bool {
    readings.count == value.count
  }
}

extension VanguardTrie.Trie {
  public func search(_ key: String, partiallyMatch: Bool = false) -> [(
    readings: [String],
    entry: Entry
  )] {
    // 直接使用 key 作為 nodeID 進行查詢
    if !partiallyMatch {
      if let node = nodes[key] {
        let readings = node.readingKey.split(separator: readingSeparator).map(\.description)
        return node.entries.map { (readings: readings, entry: $0) }
      }
      return []
    }

    var currentNode = root
    // 遍歷關鍵字的每個字符
    for char in key {
      let charStr = char.description
      // 查找對應字符的子節點
      guard let childNodeID = currentNode.children[charStr],
            let childNode = nodes[childNodeID] else { return [] }
      // 更新當前節點
      currentNode = childNode
    }

    return partiallyMatch ?
      collectAllDescendantEntriesWithReadings(from: currentNode) :
      collectEntriesWithReadings(from: currentNode)
  }

  private func collectEntriesWithReadings(from node: TNode) -> [(
    readings: [String],
    entry: Entry
  )] {
    let readings = node.readingKey.split(separator: readingSeparator).map(\.description)
    return node.entries.map { (readings: readings, entry: $0) }
  }

  private func collectAllDescendantEntriesWithReadings(from node: TNode) -> [(
    readings: [String],
    entry: Entry
  )] {
    var result = collectEntriesWithReadings(from: node)
    // 遍歷所有子節點
    node.children.values.forEach { childNodeID in
      guard let childNode = nodes[childNodeID] else { return }
      result.append(contentsOf: collectAllDescendantEntriesWithReadings(from: childNode))
    }
    return result
  }
}

// MARK: - VanguardTrie.Trie + VanguardTrieProtocol

extension VanguardTrie.Trie: VanguardTrieProtocol {
  public func getNodeIDs(
    keyArray: [String],
    filterType: EntryType,
    partiallyMatch: Bool
  )
    -> Set<String> {
    guard let firstKeyCell = keyArray.first else { return [] }
    let keyChain = keyArray.joined(separator: readingSeparator.description)
    switch partiallyMatch {
    case false:
      // 對於完全匹配，只需要檢查 keyChain 是否存在，以及是否有符合類型的詞條
      guard let node = nodes[keyChain] else { return [] }
      guard filterType.isEmpty || node.entries.contains(where: { filterType.contains($0.typeID) })
      else {
        return []
      }
      return [keyChain]
    case true:
      // 對於前綴匹配，需要找出所有以指定前綴開始的 keyChain
      return Set(nodes.filter { nodeKeyChain, node in
        // 檢查是否以目標前綴開始
        guard nodeKeyChain.starts(with: firstKeyCell) else { return false }

        // 拆分讀音並檢查前綴匹配
        let nodeReadings = node.readingKey.split(separator: readingSeparator).map(\.description)
        guard zip(keyArray, nodeReadings).allSatisfy({ $1.hasPrefix($0) }) else { return false }

        // 檢查類型
        guard filterType.isEmpty || node.entries
          .contains(where: { filterType.contains($0.typeID) }) else {
          return false
        }
        return true
      }.map(\.key))
    }
  }

  public func queryGrams(
    _ keys: [String],
    filterType: EntryType,
    partiallyMatch: Bool = false,
    partiallyMatchedKeysPostHandler: ((Set<[String]>) -> ())? = nil
  )
    -> [(keyArray: [String], value: String, probability: Double, previous: String?)] {
    guard !keys.isEmpty else { return [] }

    // 獲取節點 ID
    let nodeIDsWithKeys = getNodeIDs(
      keysChopped: keys,
      filterType: filterType,
      partiallyMatch: partiallyMatch
    )
    guard !nodeIDsWithKeys.isEmpty else { return [] }

    var results = [(keyArray: [String], value: String, probability: Double, previous: String?)]()
    var processedNodeEntries = [String: [Entry]]()

    nodeIDsWithKeys.forEach { currentKeys, nodeIDs in
      for nodeID in nodeIDs {
        guard let node = nodes[nodeID] else { continue }

        // 使用緩存避免重複查詢
        let entries = processedNodeEntries[nodeID] ?? getEntries(node: node)
        processedNodeEntries[nodeID] = entries

        let nodeReadings = node.readingKey.split(separator: readingSeparator).map(\.description)
        guard nodeReadings.count == currentKeys.count else { continue }

        if partiallyMatch {
          guard zip(currentKeys, nodeReadings).allSatisfy({ searchKey, reading in
            let keyCases = searchKey.split(separator: chopCaseSeparator)
            return keyCases.contains { reading.hasPrefix($0.description) }
          }) else { continue }
        }

        // 過濾符合條件的詞條
        entries.forEach { entry in
          guard filterType.isEmpty || filterType.contains(entry.typeID) else { return }
          results.append(entry.asTuple(with: nodeReadings))
        }
      }
    }

    // 處理回調
    if partiallyMatch, let handler = partiallyMatchedKeysPostHandler {
      var matchedKeys = Set<[String]>()
      nodeIDsWithKeys.forEach { _, nodeIDs in
        nodeIDs.forEach { nodeID in
          if let node = nodes[nodeID] {
            let readings = node.readingKey.split(separator: readingSeparator).map(\.description)
            matchedKeys.insert(readings)
          }
        }
      }
      handler(matchedKeys)
    }

    return results
  }

  public func getNode(nodeID: String) -> TNode? {
    // 直接用 nodeID 作為 keychain 查詢節點
    nodes[nodeID]
  }

  public func getEntries(node: TNode) -> [Entry] {
    node.entries
  }
}
