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
    // 使用 keyChainIDMap 優化查詢效能，尤其對於精確比對的情況
    if !partiallyMatch {
      let nodeIDs = keyChainIDMap[key, default: []]
      if !nodeIDs.isEmpty {
        var results: [(readings: [String], entry: Entry)] = []
        for nodeID in nodeIDs {
          if let node = nodes[nodeID] {
            let readings = node.readingKey.split(separator: readingSeparator).map(\.description)
            node.entries.forEach { entry in
              results.append((readings: readings, entry: entry))
            }
          }
        }
        return results
      }
    }

    var currentNode = root
    // 遍歷關鍵字的每個字符
    for char in key {
      let charStr = char.description
      // 查找對應字符的子節點
      guard let childNodeID = currentNode.children[charStr] else { return [] }
      guard let childNode = nodes[childNodeID] else { return [] }
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
    -> Set<Int> {
    switch partiallyMatch {
    case false:
      return keyChainIDMap[keyArray.joined(separator: readingSeparator.description)] ?? []
    case true:
      guard !keyArray.isEmpty else { return [] }

      // 使用 keyChainIDMap 來優化查詢
      var matchedNodeIDs = Set<Int>()

      // 從 keyChainIDMap 中查找所有鍵
      keyChainIDMap.forEach { keyChain, nodeIDs in
        // 只處理那些至少和首個查詢鍵相符的鍵鏈
        let keyComponents = keyChain.split(separator: readingSeparator).map(\.description)

        // 檢查長度是否相符
        guard keyComponents.count == keyArray.count else { return }

        // 檢查每個元素是否以對應的前綴開頭
        guard zip(keyArray, keyComponents).allSatisfy({ $1.hasPrefix($0) }) else { return }

        // 檢查類型過濾條件
        if !filterType.isEmpty {
          for nodeID in nodeIDs {
            guard let node = nodes[nodeID] else { continue }
            if node.entries.contains(where: { filterType.contains($0.typeID) }) {
              matchedNodeIDs.insert(nodeID)
            }
          }
        } else {
          matchedNodeIDs.formUnion(nodeIDs)
        }
      }
      return matchedNodeIDs
    }
  }

  public func getNode(nodeID: Int) -> TNode? {
    nodes[nodeID]
  }

  public func getEntries(node: TNode) -> [Entry] {
    node.entries
  }
}
