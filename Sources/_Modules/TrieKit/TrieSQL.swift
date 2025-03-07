// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import CSQLite3
import Foundation

// MARK: - VanguardTrie.SQLTrie

extension VanguardTrie {
  public final class SQLTrie {
    // MARK: Lifecycle

    /// 初始化 SQL 資料庫讀取器
    /// - Parameters:
    ///   - dbPath: SQLite 資料庫檔案路徑
    ///   - readOnly: 是否以唯讀模式開啟
    public init?(dbPath: String, readOnly: Bool = false) {
      // 檢查資料庫檔案是否存在
      guard FileManager.default.fileExists(atPath: dbPath) else {
        Self.printDebug("資料庫檔案不存在: \(dbPath)")
        return nil
      }

      // 選擇開啟模式
      let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE

      // 打開資料庫連接
      if sqlite3_open_v2(dbPath, &database, flags, nil) != SQLITE_OK {
        Self.printDebug("無法開啟資料庫: \(dbPath)")
        return nil
      }

      self.isReadOnly = readOnly

      // 讀取分隔符設定
      if !initializeSettings() {
        return nil
      }
    }

    /// 從 SQL 腳本內容初始化記憶體中的資料庫
    /// - Parameter sqlContent: SQL 腳本內容
    public init?(sqlContent: String) {
      // 創建記憶體資料庫
      if sqlite3_open_v2(":memory:", &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) !=
        SQLITE_OK {
        Self.printDebug("無法創建記憶體資料庫")
        return nil
      }

      self.isReadOnly = false

      // 禁用外鍵約束，以避免初始化期間的問題
      if sqlite3_exec(database, "PRAGMA foreign_keys=OFF;", nil, nil, nil) != SQLITE_OK {
        Self.printDebug("無法禁用外鍵約束: \(String(cString: sqlite3_errmsg(database)))")
        sqlite3_close(database)
        return nil
      }

      // 啟用延遲事務
      if sqlite3_exec(database, "PRAGMA synchronous=OFF;", nil, nil, nil) != SQLITE_OK ||
        sqlite3_exec(database, "PRAGMA journal_mode=MEMORY;", nil, nil, nil) != SQLITE_OK {
        Self.printDebug("無法優化資料庫性能: \(String(cString: sqlite3_errmsg(database)))")
      }

      // 開始事務以提高性能
      if sqlite3_exec(database, "BEGIN TRANSACTION;", nil, nil, nil) != SQLITE_OK {
        Self.printDebug("無法開始事務: \(String(cString: sqlite3_errmsg(database)))")
        sqlite3_close(database)
        return nil
      }

      // 逐行執行 SQL 腳本，確保每條命令都執行成功
      let commands = sqlContent.components(separatedBy: ";")

      for command in commands {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // 跳過空行和事務控制語句
        if trimmedCommand.isEmpty ||
          trimmedCommand.uppercased().contains("BEGIN TRANSACTION") ||
          trimmedCommand.uppercased().contains("COMMIT") {
          continue
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, "\(trimmedCommand);", nil, nil, &errorMessage)

        if result != SQLITE_OK {
          if let errorMsg = errorMessage {
            let errorString = String(cString: errorMsg)
            Self.printDebug("執行 SQL 命令時發生錯誤: \(errorString)")
            Self.printDebug("問題命令: \(trimmedCommand)")
            sqlite3_free(errorMessage)
          } else {
            Self.printDebug("執行 SQL 命令時發生錯誤，代碼: \(result)")
            Self.printDebug("問題命令: \(trimmedCommand)")
          }
          sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
          sqlite3_close(database)
          return nil
        }
      }

      // 提交事務
      if sqlite3_exec(database, "COMMIT;", nil, nil, nil) != SQLITE_OK {
        Self.printDebug("無法提交事務: \(String(cString: sqlite3_errmsg(database)))")
        sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
        sqlite3_close(database)
        return nil
      }

      // 重新啟用外鍵約束
      if sqlite3_exec(database, "PRAGMA foreign_keys=ON;", nil, nil, nil) != SQLITE_OK {
        Self.printDebug("無法重新啟用外鍵約束: \(String(cString: sqlite3_errmsg(database)))")
      }

      // 初始化設定 - 直接調用相同的方法以確保一致性
      if !initializeSettings() {
        Self.printDebug("無法初始化分隔符設定")
        sqlite3_close(database)
        return nil
      }
    }

    deinit {
      if let db = database {
        sqlite3_close(db)
      }
    }

    // MARK: Public

    /// 資料庫是否為唯讀模式
    public let isReadOnly: Bool
    public private(set) var readingSeparator: String = "-"

    /// 輸出資料庫診斷資訊到控制台
    public func printDatabaseDiagnostics() {
      guard database != nil else {
        Self.printDebug("資料庫連接不存在")
        return
      }

      // 檢查表結構
      let tables = ["config", "nodes", "entries", "reading_mappings", "keychain_id_map"]

      Self.printDebug("=== 資料庫診斷 ===")

      for table in tables {
        let tableExists = checkTableExists(table)
        Self.printDebug("表 \(table) \(tableExists ? "存在" : "不存在")")

        if tableExists {
          // 檢查表中的行數
          if let count = getTableRowCount(table) {
            Self.printDebug("  - 行數: \(count)")
          }

          // 顯示表的列資訊
          displayTableColumns(table)
        }
      }

      // 如果有 config 表，顯示其內容
      if checkTableExists("config") {
        displayConfigContent()
      }

      Self.printDebug("==================")
    }

    // MARK: Internal

    internal var database: OpaquePointer?

    /// 獲取表的行數
    /// - Parameter tableName: 表名
    /// - Returns: 行數，如果出錯則返回nil
    func getTableRowCount(_ tableName: String) -> Int? {
      let query = "SELECT COUNT(*) FROM \(tableName)"
      var statement: OpaquePointer?
      var count: Int?

      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        if sqlite3_step(statement) == SQLITE_ROW {
          count = Int(sqlite3_column_int(statement, 0))
        }
      }

      sqlite3_finalize(statement)
      return count
    }

    // MARK: - 輔助方法

    /// 根據給定的讀音列表查詢完全匹配的詞條
    /// - Parameter keys: 讀音列表
    /// - Returns: 匹配的詞條
    func queryExactMatch(_ keys: [String], filterType: Trie.EntryType) -> [(
      keyArray: [String],
      value: String,
      probability: Double,
      previous: String?
    )] {
      var result: [(keyArray: [String], value: String, probability: Double, previous: String?)] = []

      // 打印調試信息
      Self.printDebug("DEBUG: 查詢詞條，keys = \(keys), filterType = \(filterType)")

      // 使用 keychain_id_map 表進行精確匹配
      let keychain = keys.joined(separator: readingSeparator)
      let escapedKeychain = keychain.replacingOccurrences(of: "'", with: "''")

      // 構建查詢
      let typeFilter = filterType
        .rawValue > 0 ? "AND (e.type_id & \(filterType.rawValue) != 0)" : ""

      let query = """
        SELECT e.id, e.value, e.probability, e.previous, e.type_id, e.node_id
        FROM entries e
        JOIN keychain_id_map k ON e.node_id = k.node_id
        WHERE k.keychain = '\(escapedKeychain)'
        \(typeFilter)
      """

      var statement: OpaquePointer?

      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
          // 獲取基本詞條信息
          let entryId = sqlite3_column_int(statement, 0)
          guard let valuePtr = sqlite3_column_text(statement, 1) else { continue }
          let value = String(cString: valuePtr)
          let probability = sqlite3_column_double(statement, 2)

          // 處理可能為空的 previous 欄位
          let previous: String?
          if let prevPtr = sqlite3_column_text(statement, 3) {
            previous = String(cString: prevPtr)
          } else {
            previous = nil
          }

          // 處理 typeID
          let typeIDRaw = sqlite3_column_int(statement, 4)
          let typeID = Trie.EntryType(rawValue: typeIDRaw)

          // 為每個詞條單獨查詢讀音，確保順序正確
          let readings = getReadingsForEntry(entryId: entryId)

          if !readings.isEmpty {
            Self.printDebug(
              "DEBUG: 找到結果：value = \(value), probability = \(probability), readings = \(readings)"
            )

            // 創建 Entry 對象
            let entry = VanguardTrie.Trie.Entry(
              readings: readings,
              value: value,
              typeID: typeID,
              probability: probability,
              previous: previous
            )

            result.append(entry.asTuple)
          }
        }
      } else {
        Self.printDebug("ERROR: SQL準備失敗: \(String(cString: sqlite3_errmsg(database)))")
      }

      sqlite3_finalize(statement)
      Self.printDebug("DEBUG: 查詢結束，找到 \(result.count) 個結果")

      return result
    }

    /// 根據 keychain 字串查詢節點 ID
    func getNodeIDsForKeychain(_ keychain: String, filterType: Trie.EntryType = []) -> Set<Int> {
      var nodeIDs = Set<Int>()
      let escapedKeychain = keychain.replacingOccurrences(of: "'", with: "''")

      let typeFilter = filterType.rawValue > 0 ?
        """
        JOIN entries e ON k.node_id = e.node_id
        WHERE k.keychain = '\(escapedKeychain)'
        AND (e.type_id & \(filterType.rawValue) != 0)
        """ :
        "WHERE k.keychain = '\(escapedKeychain)'"

      let query = "SELECT DISTINCT k.node_id FROM keychain_id_map k \(typeFilter)"
      var statement: OpaquePointer?

      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
          let nodeID = Int(sqlite3_column_int(statement, 0))
          nodeIDs.insert(nodeID)
        }
      }

      sqlite3_finalize(statement)
      return nodeIDs
    }

    /// 獲取詞條的所有讀音，保持原始順序
    internal func getReadingsForEntry(entryId: Int32) -> [String] {
      // 使用 entry_index 欄位來獲取原始讀音順序
      var allReadings = [String]()
      let query = "SELECT reading FROM reading_mappings WHERE entry_id = ? ORDER BY entry_index"
      var stmt: OpaquePointer?

      if sqlite3_prepare_v2(database, query, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_int(stmt, 1, entryId)

        while sqlite3_step(stmt) == SQLITE_ROW {
          if let readingPtr = sqlite3_column_text(stmt, 0) {
            let reading = String(cString: readingPtr)
            allReadings.append(reading)
          }
        }
      }
      sqlite3_finalize(stmt)

      return allReadings
    }

    // MARK: Private

    private static func printDebug(
      _ items: Any...,
      separator: String = " ",
      terminator: String = "\n"
    ) {
      #if !DEBUG
        return
      #else
        print(items, separator: separator, terminator: terminator)
      #endif
    }

    /// 初始化資料庫設定
    /// - Returns: 是否成功初始化
    private func initializeSettings() -> Bool {
      // 檢查必要表是否存在
      let requiredTables = ["nodes", "entries", "reading_mappings", "keychain_id_map"]
      for table in requiredTables {
        if !checkTableExists(table) {
          Self.printDebug("資料庫中不存在 \(table) 表")
          return false
        }
      }

      // 檢查config表是否存在，如果存在則獲取分隔符，否則使用默認值
      if checkTableExists("config") {
        readingSeparator = fetchSeparator()
      } else {
        Self.printDebug("資料庫中不存在 config 表，使用預設分隔符 '-'")
        readingSeparator = "-"
      }

      return true
    }

    /// 獲取分隔符設定
    /// - Returns: 分隔符字符串，如果獲取失敗則返回預設值 "-"
    private func fetchSeparator() -> String {
      var separator = "-"
      let query = "SELECT value FROM config WHERE key = 'separator'"
      var statement: OpaquePointer?

      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        let stepResult = sqlite3_step(statement)

        if stepResult == SQLITE_ROW {
          if let cString = sqlite3_column_text(statement, 0) {
            separator = String(cString: cString)
          }
        } else if stepResult == SQLITE_DONE {
          // 表存在但沒有找到分隔符配置，使用預設值
          Self.printDebug("警告：找不到分隔符設定，使用預設值 '-'")
        } else {
          Self.printDebug("查詢分隔符設定時發生錯誤: \(String(cString: sqlite3_errmsg(database)))")
        }
      } else {
        Self.printDebug("準備 SQL 語句時發生錯誤: \(String(cString: sqlite3_errmsg(database)))")
      }

      sqlite3_finalize(statement)
      return separator
    }

    /// 檢查資料表是否存在
    /// - Parameter tableName: 資料表名稱
    /// - Returns: 資料表是否存在
    private func checkTableExists(_ tableName: String) -> Bool {
      // 直接嘗試查詢表，如果不報錯就說明表存在
      let query = "SELECT 1 FROM \(tableName) LIMIT 1"
      var statement: OpaquePointer?
      let result = sqlite3_prepare_v2(database, query, -1, &statement, nil)

      // 無論查詢結果如何，都需要釋放statement
      defer {
        if statement != nil {
          sqlite3_finalize(statement)
        }
      }

      // SQLITE_OK 意味著查詢語句是正確的，表存在
      return result == SQLITE_OK
    }

    /// 顯示表的列資訊
    /// - Parameter tableName: 表名
    private func displayTableColumns(_ tableName: String) {
      // 這個查詢將返回表的所有列信息
      let query = "PRAGMA table_info(\(tableName))"
      var statement: OpaquePointer?

      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        Self.printDebug("  - 表結構:")

        while sqlite3_step(statement) == SQLITE_ROW {
          let name = String(cString: sqlite3_column_text(statement, 1))
          let type = String(cString: sqlite3_column_text(statement, 2))
          let notNull = sqlite3_column_int(statement, 3) != 0
          Self.printDebug("    * \(name) (\(type))\(notNull ? " NOT NULL" : "")")
        }
      }

      sqlite3_finalize(statement)
    }

    /// 顯示config表的內容
    private func displayConfigContent() {
      var statement: OpaquePointer?
      let query = "SELECT key, value FROM config"

      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        Self.printDebug("\n配置項:")
        var hasRows = false

        while sqlite3_step(statement) == SQLITE_ROW {
          hasRows = true
          let key = String(cString: sqlite3_column_text(statement, 0))
          let value = String(cString: sqlite3_column_text(statement, 1))
          Self.printDebug("  * \(key): \(value)")
        }

        if !hasRows {
          Self.printDebug("  * 無配置項")
        }
      }

      sqlite3_finalize(statement)
    }

    // 直接查詢表中數據的調試方法
    private func directQueryDebug(keys: [String]) {
      // 1. 檢查 reading_mappings 表中是否有這些 readings
      for key in keys {
        var stmt: OpaquePointer?
        let query = "SELECT count(*) FROM reading_mappings WHERE reading = ?"
        if sqlite3_prepare_v2(database, query, -1, &stmt, nil) == SQLITE_OK {
          sqlite3_bind_text(stmt, 1, key, -1, nil)

          if sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_int(stmt, 0)
            Self.printDebug("DEBUG: reading '\(key)' 在表中出現 \(count) 次")
          }
        }
        sqlite3_finalize(stmt)
      }

      // 2. 檢查有多少條目
      var stmt: OpaquePointer?
      if sqlite3_prepare_v2(database, "SELECT count(*) FROM entries", -1, &stmt, nil) == SQLITE_OK {
        if sqlite3_step(stmt) == SQLITE_ROW {
          let count = sqlite3_column_int(stmt, 0)
          Self.printDebug("DEBUG: entries 表中有 \(count) 條記錄")
        }
      }
      sqlite3_finalize(stmt)

      // 3. 檢查總共有多少 readings
      if sqlite3_prepare_v2(database, "SELECT count(*) FROM reading_mappings", -1, &stmt, nil) ==
        SQLITE_OK {
        if sqlite3_step(stmt) == SQLITE_ROW {
          let count = sqlite3_column_int(stmt, 0)
          Self.printDebug("DEBUG: reading_mappings 表中有 \(count) 條記錄")
        }
      }
      sqlite3_finalize(stmt)
    }
  }
}
