// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import CSQLite3
import Foundation

// MARK: - VanguardTrie.SQLTrie + VanguardTrieProtocol

// 讓 SQLTrie 遵循 VanguardTrieProtocol
extension VanguardTrie.SQLTrie: VanguardTrieProtocol {
  /// 根據 keychain 字串查詢節點 ID
  public func getNodeIDsForKeyArray(_ keyArray: [String], longerSpan: Bool) -> [Int] {
    guard !keyArray.isEmpty, keyArray.allSatisfy({ !$0.isEmpty }) else { return [] }
    let keyInitialsStr = keyArray.compactMap {
      $0.first?.description
    }.joined()

    let formedKeyHash: Int = {
      var hasher = Hasher()
      hasher.combine(keyInitialsStr)
      hasher.combine(longerSpan)
      return hasher.finalize()
    }()

    if let cachedResult = queryBuffer4NodeIDs.get(hashKey: formedKeyHash) {
      return cachedResult.sorted()
    }

    var nodeIDs = Set<Int>()
    
    let query = switch longerSpan {
    case false: "SELECT node_ids FROM keyinitials_id_map WHERE keyinitials = ?"
    case true: "SELECT node_ids FROM keyinitials_id_map WHERE keyinitials LIKE ? || '%'"
    }

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
      defer { sqlite3_finalize(statement) }
      
      // 綁定參數，避免 SQL 注入並提升效能
      _ = keyInitialsStr.withCString { cString in
        sqlite3_bind_text(statement, 1, cString, -1, nil)
      }
      
      while sqlite3_step(statement) == SQLITE_ROW {
        if let jsonData = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) {
          // 使用高效能的特製 JSON 解析器來解析 Set<Int>
          if let setDecoded = TrieHighFrequencyDecoder.decodeIntSet(from: jsonData) {
            nodeIDs.formUnion(setDecoded)
          }
        }
      }
    }

    queryBuffer4NodeIDs.set(hashKey: formedKeyHash, value: nodeIDs)
    return nodeIDs.sorted()
  }

  /// 此處不需要做 keyArray 長度配對檢查。
  public func getNodes(
    keyArray: [String],
    filterType: EntryType,
    partiallyMatch: Bool,
    longerSpan: Bool
  )
    -> [TNode] {
    let formedKeyHash: Int = {
      var hasher = Hasher()
      hasher.combine(keyArray)
      hasher.combine(filterType)
      hasher.combine(partiallyMatch)
      hasher.combine(longerSpan)
      return hasher.finalize()
    }()

    if let cachedResult = queryBuffer4Nodes.get(hashKey: formedKeyHash) { return cachedResult }

    // 接下來的步驟與 VanguardTrie.Trie 雷同。
    let matchedNodeIDs: [Int] = getNodeIDsForKeyArray(
      keyArray,
      longerSpan: longerSpan
    )
    guard !matchedNodeIDs.isEmpty else { return [] }
    
    // 使用批次查詢優化效能
    let nodesBatch = getNodesBatch(matchedNodeIDs)
    var handledNodeHashes: Set<Int> = []
    
    let matchedNodes: [TNode] = matchedNodeIDs.compactMap { nodeID in
      guard let theNode = nodesBatch[nodeID] else { return nil }
      
      let hash = theNode.hashValue
      if !handledNodeHashes.contains(hash) {
        handledNodeHashes.insert(theNode.hashValue)
        let nodeKeyArray = theNode.readingKey.split(separator: readingSeparator)
        if nodeMeetsFilter(theNode, filter: filterType) {
          var matched: Bool = longerSpan
            ? nodeKeyArray.count > keyArray.count
            : nodeKeyArray.count == keyArray.count
          switch partiallyMatch {
          case true:
            matched = matched && zip(nodeKeyArray, keyArray).allSatisfy { $0.hasPrefix($1) }
          case false:
            matched = matched && zip(nodeKeyArray, keyArray).allSatisfy(==)
          }
          return matched ? theNode : nil
        }
      }
      return nil
    }
    let result = matchedNodes
    // 最後，將本次查詢的結果塞入快取。
    queryBuffer4Nodes.set(hashKey: formedKeyHash, value: result)
    return result
  }

  public func getNode(_ nodeID: Int) -> TNode? {
    if let cachedResult = queryBuffer4Node.get(hashKey: nodeID) { return cachedResult }
    // 基本查詢，只查必要資訊
    let query = """
    SELECT id, reading_key, entries_blob
    FROM nodes
    WHERE id = ?
    LIMIT 1
    """
    var statement: OpaquePointer?

    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
      sqlite3_finalize(statement)
      return nil
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_int64(statement, 1, sqlite3_int64(nodeID))

    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

    // 直接從欄位讀取資料（注意：欄位索引從 0 開始）
    let id = Int(sqlite3_column_int64(statement, 0))
    let readingKey = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""

    // 創建節點
    let node = VanguardTrie.Trie.TNode(
      id: id,
      entries: [],
      readingKey: readingKey
    )

    // 解析詞條資料（如果有的話）
    if let blobPtr = sqlite3_column_text(statement, 2) {
      let blobString = String(cString: blobPtr)
      if !blobString.isEmpty, let entries = decodeEntriesFromBase64(blobString) {
        guard !entries.isEmpty else {
          queryBuffer4Node.set(hashKey: nodeID, value: nil)
          return nil
        }
        node.entries = entries
      }
    }

    queryBuffer4Node.set(hashKey: nodeID, value: node)
    return node
  }
  
  /// 批次查詢多個節點，效能優於逐個查詢
  /// - Parameter nodeIDs: 要查詢的節點 ID 陣列
  /// - Returns: 節點字典，以 ID 為鍵值
  internal func getNodesBatch(_ nodeIDs: [Int]) -> [Int: TNode] {
    guard !nodeIDs.isEmpty else { return [:] }
    
    var result: [Int: TNode] = [:]
    var uncachedIDs: [Int] = []
    
    // 先檢查快取
    for nodeID in nodeIDs {
      if let cachedNode = queryBuffer4Node.get(hashKey: nodeID) {
        result[nodeID] = cachedNode
      } else {
        uncachedIDs.append(nodeID)
      }
    }
    
    guard !uncachedIDs.isEmpty else { return result }
    
    // 批次查詢未快取的節點
    let placeholders = Array(repeating: "?", count: uncachedIDs.count).joined(separator: ",")
    let query = """
    SELECT id, reading_key, entries_blob
    FROM nodes
    WHERE id IN (\(placeholders))
    """
    
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
      sqlite3_finalize(statement)
      return result
    }
    defer { sqlite3_finalize(statement) }
    
    // 綁定參數
    for (index, nodeID) in uncachedIDs.enumerated() {
      sqlite3_bind_int64(statement, Int32(index + 1), sqlite3_int64(nodeID))
    }
    
    // 處理查詢結果
    while sqlite3_step(statement) == SQLITE_ROW {
      let id = Int(sqlite3_column_int64(statement, 0))
      let readingKey = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
      
      // 創建節點
      let node = VanguardTrie.Trie.TNode(
        id: id,
        entries: [],
        readingKey: readingKey
      )
      
      // 解析詞條資料
      if let blobPtr = sqlite3_column_text(statement, 2) {
        let blobString = String(cString: blobPtr)
        if !blobString.isEmpty, let entries = decodeEntriesFromBase64(blobString) {
          if !entries.isEmpty {
            node.entries = entries
          }
        }
      }
      
      result[id] = node
      queryBuffer4Node.set(hashKey: id, value: node)
    }
    
    return result
  }
}
