// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - TrieSQLScriptGenerator

extension VanguardTrie {
  public class TrieSQLScriptGenerator {
    // MARK: Public

    /// 將 Trie 結構匯出為 SQL 腳本
    /// - Parameters:
    ///   - trie: 要匯出的 Trie 結構
    /// - Returns: SQL 腳本內容。
    public static func generateSQLScript(_ trie: VanguardTrie.Trie) -> String {
      var sqlCommands = [String]()

      // 設置優化參數，提高大量數據導入速度
      sqlCommands.append("""
      -- 設置性能優化參數
      PRAGMA cache_size=10000;
      PRAGMA page_size=8192;
      PRAGMA temp_store=MEMORY;

      -- 開始事務
      BEGIN TRANSACTION;

      -- 移除現有表格
      DROP TABLE IF EXISTS reading_mappings;
      DROP TABLE IF EXISTS keychain_id_map;
      DROP TABLE IF EXISTS entries;
      DROP TABLE IF EXISTS nodes;
      DROP TABLE IF EXISTS config;

      -- 創建資料表結構
      CREATE TABLE config (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
      );

      CREATE TABLE nodes (
          id INTEGER PRIMARY KEY,
          parent_id INTEGER,
          character TEXT NOT NULL,
          FOREIGN KEY (parent_id) REFERENCES nodes(id),
          UNIQUE (parent_id, character)
      );

      CREATE TABLE entries (
          id INTEGER PRIMARY KEY,
          node_id INTEGER NOT NULL,
          value TEXT NOT NULL,
          probability REAL NOT NULL,
          previous TEXT,
          type_id INTEGER NOT NULL DEFAULT 1,
          FOREIGN KEY (node_id) REFERENCES nodes(id)
      );

      CREATE TABLE reading_mappings (
          id INTEGER PRIMARY KEY,
          entry_id INTEGER NOT NULL,
          reading TEXT NOT NULL,
          entry_index INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY (entry_id) REFERENCES entries(id),
          UNIQUE (entry_id, reading)
      );

      -- 新增 keychain_id_map 表，對應原始的 keyChainIDMap 結構
      CREATE TABLE keychain_id_map (
          id INTEGER PRIMARY KEY,
          keychain TEXT NOT NULL,
          node_id INTEGER NOT NULL,
          FOREIGN KEY (node_id) REFERENCES nodes(id),
          UNIQUE (keychain, node_id)
      );
      """)

      // 添加分隔符配置
      let escapedSeparator = trie.readingSeparator.replacingOccurrences(of: "'", with: "''")
      sqlCommands.append("-- 儲存分隔符設定")
      sqlCommands
        .append("INSERT INTO config (key, value) VALUES ('separator', '\(escapedSeparator)');")

      // 使用批量插入優化節點數據
      sqlCommands.append("-- 插入所有節點（包括根節點）")
      generateBatchNodeInserts(trie.nodes, into: &sqlCommands)

      // 批量插入詞條和讀音映射
      sqlCommands.append("-- 插入詞條和讀音映射")
      generateBatchEntryAndReadingInserts(
        trie.nodes,
        with: trie.readingSeparator,
        into: &sqlCommands
      )

      // 批量插入 keychain_id_map 數據
      sqlCommands.append("-- 插入 keychain_id_map 數據")
      generateBatchKeychainIdMapInserts(trie.keyChainIDMap, into: &sqlCommands)

      // 提交事務，啟用外鍵約束
      sqlCommands.append("""
      -- 提交事務
      COMMIT;

      -- 啟用外鍵約束
      PRAGMA foreign_keys=ON;

      -- 創建索引
      CREATE INDEX IF NOT EXISTS idx_keychain_id_map_keychain ON keychain_id_map(keychain);
      CREATE INDEX IF NOT EXISTS idx_keychain_id_map_node ON keychain_id_map(node_id);
      CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(parent_id);
      CREATE INDEX IF NOT EXISTS idx_entries_node ON entries(node_id);
      CREATE INDEX IF NOT EXISTS idx_entries_type ON entries(type_id);
      CREATE INDEX IF NOT EXISTS idx_reading_mappings_reading ON reading_mappings(reading);

      -- 專門針對前綴匹配優化的索引
      CREATE INDEX IF NOT EXISTS idx_reading_prefix ON reading_mappings(substr(reading,1,1));
      CREATE INDEX IF NOT EXISTS idx_reading_mappings_like ON reading_mappings(reading COLLATE NOCASE);
      CREATE INDEX IF NOT EXISTS idx_keychain_prefix ON keychain_id_map(substr(keychain,1,3));

      -- 收集資料庫統計資訊，優化查詢
      ANALYZE;
      """)

      return sqlCommands.joined(separator: "\n")
    }

    // MARK: Private

    /// 生成批量插入節點的 SQL 語句
    /// - Parameters:
    ///   - nodes: 節點字典
    ///   - sqlCommands: SQL 命令數組，結果會添加到此數組
    private static func generateBatchNodeInserts(
      _ nodes: [Int: VanguardTrie.Trie.TNode],
      into sqlCommands: inout [String]
    ) {
      let batchSize = 500 // 每批插入的節點數量
      var nodeValues = ["(1, NULL, '')"] // 從根節點開始
      var count = 1

      // 收集所有非根節點
      for (id, node) in nodes where id != 1 { // 排除根節點，避免重複插入
        if let parentID = node.parentID {
          let escapedChar = node.character.replacingOccurrences(of: "'", with: "''")
          nodeValues.append("(\(id), \(parentID), '\(escapedChar)')")

          // 達到批處理大小或處理完所有節點時，生成一條批量插入語句
          if nodeValues.count >= batchSize || count == nodes.count - 1 {
            sqlCommands
              .append(
                "INSERT INTO nodes (id, parent_id, character) VALUES \(nodeValues.joined(separator: ","));"
              )
            nodeValues = []
          }
        }
        count += 1
      }

      // 處理剩餘節點
      if !nodeValues.isEmpty {
        sqlCommands
          .append(
            "INSERT INTO nodes (id, parent_id, character) VALUES \(nodeValues.joined(separator: ","));"
          )
      }
    }

    /// 生成批量插入詞條和讀音映射的 SQL 語句
    /// - Parameters:
    ///   - nodes: 節點字典
    ///   - readingSeparator: 讀音分隔符
    ///   - sqlCommands: SQL 命令數組，結果會添加到此數組
    private static func generateBatchEntryAndReadingInserts(
      _ nodes: [Int: VanguardTrie.Trie.TNode],
      with readingSeparator: String,
      into sqlCommands: inout [String]
    ) {
      let entryBatchSize = 200 // 每批插入的詞條數量
      let readingBatchSize = 500 // 每批插入的讀音數量

      var entryValues: [String] = []
      var readingValues: [String] = []
      var entryIdCounter = 1
      var readingIdCounter = 1

      // 收集所有詞條和讀音
      for (nodeId, node) in nodes {
        for entry in node.entries {
          // 處理詞條
          let entryValue = generateEntryValue(entry: entry, nodeId: nodeId, entryId: entryIdCounter)
          entryValues.append(entryValue)

          // 批量插入詞條
          if entryValues.count >= entryBatchSize {
            sqlCommands
              .append(
                "INSERT INTO entries (id, node_id, value, probability, previous, type_id) VALUES \(entryValues.joined(separator: ","));"
              )
            entryValues = []
          }

          // 處理讀音 - 保留原始順序，這對於 partiallyMatch 很重要
          for (index, reading) in entry.readings.enumerated() {
            let escapedReading = reading.replacingOccurrences(of: "'", with: "''")
            readingValues
              .append("(\(readingIdCounter), \(entryIdCounter), '\(escapedReading)', \(index))")
            readingIdCounter += 1

            // 批量插入讀音
            if readingValues.count >= readingBatchSize {
              sqlCommands
                .append(
                  "INSERT INTO reading_mappings (id, entry_id, reading, entry_index) VALUES \(readingValues.joined(separator: ","));"
                )
              readingValues = []
            }
          }

          entryIdCounter += 1
        }
      }

      // 處理剩餘的詞條
      if !entryValues.isEmpty {
        sqlCommands
          .append(
            "INSERT INTO entries (id, node_id, value, probability, previous, type_id) VALUES \(entryValues.joined(separator: ","));"
          )
      }

      // 處理剩餘的讀音
      if !readingValues.isEmpty {
        sqlCommands
          .append(
            "INSERT INTO reading_mappings (id, entry_id, reading, entry_index) VALUES \(readingValues.joined(separator: ","));"
          )
      }
    }

    /// 生成批量插入 keychain_id_map 的 SQL 語句
    /// - Parameters:
    ///   - keychainMap: keyChainIDMap 字典
    ///   - sqlCommands: SQL 命令數組，結果會添加到此數組
    private static func generateBatchKeychainIdMapInserts(
      _ keychainMap: [String: Set<Int>],
      into sqlCommands: inout [String]
    ) {
      let batchSize = 500 // 每批插入數量
      var keychainValues: [String] = []
      var idCounter = 1

      // 遍歷所有 keychain 和對應的節點 ID
      for (keychain, nodeIDs) in keychainMap {
        for nodeID in nodeIDs {
          let escapedKeychain = keychain.replacingOccurrences(of: "'", with: "''")
          keychainValues.append("(\(idCounter), '\(escapedKeychain)', \(nodeID))")
          idCounter += 1

          // 批量插入
          if keychainValues.count >= batchSize {
            sqlCommands.append(
              "INSERT INTO keychain_id_map (id, keychain, node_id) VALUES \(keychainValues.joined(separator: ","));"
            )
            keychainValues = []
          }
        }
      }

      // 處理剩餘數據
      if !keychainValues.isEmpty {
        sqlCommands.append(
          "INSERT INTO keychain_id_map (id, keychain, node_id) VALUES \(keychainValues.joined(separator: ","));"
        )
      }
    }

    /// 生成詞條的 SQL 值部分（不含表名和欄位名）
    private static func generateEntryValue(
      entry: VanguardTrie.Trie.Entry,
      nodeId: Int,
      entryId: Int
    )
      -> String {
      // 處理值和前文
      let escapedValue = entry.value.replacingOccurrences(of: "'", with: "''")
      let previousPart: String
      if let previous = entry.previous {
        let escapedPrevious = previous.replacingOccurrences(of: "'", with: "''")
        previousPart = "'\(escapedPrevious)'"
      } else {
        previousPart = "NULL"
      }

      return "(\(entryId), \(nodeId), '\(escapedValue)', \(entry.probability), \(previousPart), \(entry.typeID.rawValue))"
    }
  }
}
