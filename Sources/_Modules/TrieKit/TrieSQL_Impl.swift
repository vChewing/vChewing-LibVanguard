// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import CSQLite3

// MARK: - VanguardTrie.SQLTrie + VanguardTrieProtocol

// 讓 SQLTrie 遵循 VanguardTrieProtocol
extension VanguardTrie.SQLTrie: VanguardTrieProtocol {
  /// 此處不需要做 keyArray 長度配對檢查。
  public func getNodeIDs(
    keyArray: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool
  )
    -> Set<String> {
    guard !keyArray.isEmpty else { return [] }
    let formedKey: String
    let result: Set<String>
    if !partiallyMatch {
      formedKey = "\(keyArray)::\(filterType.rawValue)::\(partiallyMatch ? 1 : 0)"
      if let cachedResult = queryBuffer4NodeIDs.get(key: formedKey) { return cachedResult }
      // 精確比對
      let keychain = keyArray.joined(separator: readingSeparator.description)
      result = [keychain] // 因為 keychain 本身就是 nodeID
    } else {
      let firstKeyEscaped = keyArray[0].replacingOccurrences(of: "'", with: "''")
      formedKey = "\(firstKeyEscaped)::\(filterType.rawValue)::\(partiallyMatch ? 1 : 0)"
      if let cachedResult = queryBuffer4NodeIDs.get(key: formedKey) { return cachedResult }
      var nodeIDs = Set<String>()

      let query = """
        SELECT keychain, entries_blob
        FROM nodes
        WHERE keychain LIKE '\(firstKeyEscaped)%'
      """

      var statement: OpaquePointer?
      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
          guard let keychainPtr = sqlite3_column_text(statement, 0) else { continue }
          let keyChainValue = String(cString: keychainPtr)
          let keyComponents = keyChainValue.split(separator: readingSeparator).map(\.description)

          guard keyComponents.first?.hasPrefix(keyArray[0]) ?? false else { continue }

          if let entriesBlobPtr = sqlite3_column_text(statement, 1) {
            let entriesBlob = String(cString: entriesBlobPtr)
            guard let entries = decodeEntriesFromBase64(entriesBlob) else { continue }

            if !filterType.isEmpty {
              guard entries.contains(where: { filterType.contains($0.typeID) }) else { continue }
            }

            guard zip(keyArray, keyComponents).allSatisfy({ $1.hasPrefix($0) }) else { continue }
            nodeIDs.insert(keyChainValue)
          }
        }
      }
      sqlite3_finalize(statement)
      result = nodeIDs
    }
    queryBuffer4NodeIDs.set(key: formedKey, value: result)
    return result
  }

  public func getNode(nodeID: String) -> VanguardTrie.Trie.TNode? {
    if let cachedResult = queryBuffer4Nodes.get(key: nodeID) { return cachedResult }

    let query = """
      SELECT parent_id, character, reading_key, entries_blob
      FROM nodes
      WHERE keychain = ?
    """

    var statement: OpaquePointer?
    var node: VanguardTrie.Trie.TNode?

    nodeID.withCString { nodeIDCstr in
      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, nodeIDCstr, -1, nil)

        if sqlite3_step(statement) == SQLITE_ROW {
          // 獲取父節點 ID
          let parentID: String? = {
            guard let parentIDPtr = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: parentIDPtr)
          }()

          // 獲取字符和讀音鍵（確保不為 nil）
          guard let charPtr = sqlite3_column_text(statement, 1),
                let readingKeyPtr = sqlite3_column_text(statement, 2)
          else { return }

          let character = String(cString: charPtr)
          let readingKey = String(cString: readingKeyPtr)

          // 創建節點
          node = VanguardTrie.Trie.TNode(
            id: nodeID,
            entries: [],
            parentID: parentID,
            character: character,
            readingKey: readingKey
          )

          // 獲取並解析 entries
          if let blobPtr = sqlite3_column_text(statement, 3) {
            let blobString = String(cString: blobPtr)
            if !blobString.isEmpty, let entries = decodeEntriesFromBase64(blobString) {
              node?.entries = entries
            }
          }

          // 獲取子節點
          let childrenQuery = "SELECT keychain, character FROM nodes WHERE parent_id = ?"
          var childStmt: OpaquePointer?

          if sqlite3_prepare_v2(database, childrenQuery, -1, &childStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(childStmt, 1, nodeIDCstr, -1, nil)

            while sqlite3_step(childStmt) == SQLITE_ROW {
              guard let childKeychain = sqlite3_column_text(childStmt, 0),
                    let charPtr = sqlite3_column_text(childStmt, 1)
              else { continue }

              let char = String(cString: charPtr)
              node?.children[char] = String(cString: childKeychain)
            }
          }
          sqlite3_finalize(childStmt)
        }
      }
    }

    sqlite3_finalize(statement)

    if let node {
      queryBuffer4Nodes.set(key: nodeID, value: node)
    }

    return node
  }

  public func getEntries(node: VanguardTrie.Trie.TNode) -> [Entry] {
    node.entries
  }
}
