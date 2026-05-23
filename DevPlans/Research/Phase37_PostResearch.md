# Phase 37 結案後追加研究報告：拼音無調查詢、tone bucket、與 continuous stem auto-chop

> 結案日期：2026-04-23
> 研究範圍：`vChewing-macOS`、`vChewing-LibVanguard`、`vChewing-OSX-Legacy`
> 研究員：GLM-5.1
> 文檔狀態：完成、可用於接下來的 Phase 的開工依據。

---

（前七章位於 `Phase37_Research.md` 內。）

## 八、GLM 追加研究：中段熱區根因剖析與解決方案

> 研究日期：2026-04-23
> 研究員：GLM-5.1
> 研究方法：基於既有 profiling 結論，逐層追蹤中段熱區（00:02.42 – 00:03.64）涉及的完整 call chain，從 `LMInstantiator.unigramsFor(keyArray:)` 一路向下拆解到 `TextMapTrie.getNodes()`、`QueryBuffer`、`TrieStringPool` / `TrieStringOperationCache`、`PhonabetCipher` 等底層元件。

### 8.1 完整熱路徑 Call Chain

以下為單次 `unigramsFor(keyArray:)` 呼叫（不含 `&` alternatives 展開）的完整展開路徑：

```
LMInstantiator.unigramsFor(keyArray:)
  ├── keyArray.joined(separator: "-")           // String 拼接
  ├── keyArray.joined().contains("&")           // Phase 37 tone bucket 偵測
  │
  ├── factoryUnigramsFor(key:keyArray:column:)  // 每個 column 各跑一次
  │   ├── PhonabetCipher.convertPhonabetToASCII()  × N keys   // 逐字元 dict lookup
  │   ├── TextMapTrie.getNodes(keyArray:filterType:partiallyMatch:longerSegment:)
  │   │   ├── Hasher() × 4 參數 → cacheKey
  │   │   ├── QueryBuffer4Nodes.get(hashKey:)       // DispatchQueue.sync + Date()
  │   │   ├── TextMapTrie.getNodeIDsForKeyArray(keyArray:longerSegment:)
  │   │   │   ├── TrieStringPool.shared.internKey()        × N keys  // NSLock
  │   │   │   ├── TrieStringOperationCache.shared.getCachedFirstChar() × N keys  // NSLock
  │   │   │   ├── Hasher() × 2 參數 → cacheKey
  │   │   │   ├── QueryBuffer4NodeIDs.get(hashKey:)        // DispatchQueue.sync + Date()
  │   │   │   ├── keyInitialsIDMap[keyInitials] lookup
  │   │   │   └── QueryBuffer4NodeIDs.set(hashKey:value:)  // DispatchQueue.sync + Date()
  │   │   │
  │   │   └── for each matchedNodeID:
  │   │       ├── TextMapTrie.getNode(nodeID:)
  │   │       │   ├── QueryBuffer4Node.get(hashKey:)       // DispatchQueue.sync + Date()
  │   │       │   ├── parseNodeEntries(nodeID)
  │   │       │   │   └── parsedEntries(keyEntryIndex)
  │   │       │   │       ├── NSCache.lookup(keyStart)
  │   │       │   │       └── (cache miss) parseValueLine × count lines
  │   │       │   └── QueryBuffer4Node.set(hashKey:value:) // DispatchQueue.sync + Date()
  │   │       │
  │   │       ├── TrieStringOperationCache.shared.getCachedSplit()  // NSLock
  │   │       ├── nodeMeetsFilter(node, filter:)
  │   │       └── zip(nodeKeyArray, keyArray).allSatisfy(==)  // 逐位精確比對
  │   │
  │   ├── QueryBuffer4Nodes.set(hashKey:value:)     // DispatchQueue.sync + Date()
  │   └── makeFactoryUnigrams(entries:keyArray:sourceKey:column:)
  │
  ├── lmUserPhrases.unigramsFor(key:keyArray:)   // 使用者片語
  ├── lmUserSymbols.unigramsFor(key:keyArray:)   // 使用者符號
  ├── LMPlainBopomofo.valuesFor(key:isCHS:)      // 倚天排序
  ├── queryDateTimeUnigrams(with:keyArray:)       // 日期時間
  ├── InputToken expansion                        // 逐筆檢查 + 展開
  ├── lmReplacements.valuesFor(key:)              // 語彙置換（逐筆）
  ├── lmFiltered.unigramsFor(key:keyArray:)       // 濾除表
  └── rawAllUnigrams.consolidate(filter:)         // 去重 + 過濾
```

### 8.2 根因分析

經逐層拆解，中段熱區的 CPU 高佔用可歸因為以下六個根因，按影響程度排序：

---

#### 根因 A：Tone Bucket 組合爆炸（Phase 37 特有，HIGH IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) `mergedAlternativeBucketUnigrams(for:)` + `expandAlternativeKeyArrays(from:)`

**問題**：當 `keyArray` 含有 `&` alternatives 時，`expandAlternativeKeyArrays()` 會以笛卡爾積展開所有組合，然後對每個組合呼叫完整的 `unigramsFor(keyArray:)`。以 5 個 syllable、每個 5 個聲調變體為例：5⁵ = 3125 次完整 `unigramsFor()` 呼叫。

每次 `unigramsFor()` 都會完整跑過：
- Factory trie 查詢（含 PhonabetCipher 轉換 + TextMapTrie 查詢 + QueryBuffer 操作）
- User phrases 查詢
- User symbols 查詢
- ETen DOS 查詢
- DateTime 查詢
- InputToken 展開
- 語彙置換
- 濾除表過濾
- Consolidation（去重 + 過濾）

**關鍵洞察**：`VanguardTrieProtocol` 已經有 `getNodes(keysChopped:filterType:partiallyMatch:)` 和 `getEntryGroups(keysChopped:filterType:partiallyMatch:)` 這兩個 API，它們在 trie 層級處理 `&` alternatives，且以 node ID 去重，避免了重複解析同一個 node。但 `mergedAlternativeBucketUnigrams()` 完全沒有使用這些既有基礎設施，而是在 LMI 層自行展開，導致大量冗餘工作。

**浪費量化**：假設一次 tone bucket query 有 3 個 syllable、每個 5 個聲調變體（5³ = 125 組合），則：
- Factory trie 查詢次數：125 × (CHEW + MISC + Core + CNS + SYMB) ≈ 125 × 5 = 625 次
- PhonabetCipher 轉換次數：625 × 3 keys = 1875 次
- QueryBuffer 操作次數：至少 625 × 6 = 3750 次 DispatchQueue.sync
- User phrases / symbols / filtered 查詢：各 125 次
- Consolidation：125 次（每次都做 Set 去重）

而如果改用 trie 層級的 `keysChopped` 路徑，factory trie 只需查詢一次（內部展開但以 node ID 去重），其餘後處理也只跑一次。

---

#### 根因 B：QueryBuffer 鎖競爭與 Date() 開銷（MEDIUM IMPACT）

**位置**：[TK_QueryBuffer.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-LibVanguard/Sources/_Modules/TrieKit/TK_QueryBuffer.swift)

**問題**：

1. **DispatchQueue.sync 開銷**：每個 `get()` / `set()` 呼叫都走 `lockQueue.sync {}`。單次 `getNodes()` 至少觸發 4 次 `get()` + 2 次 `set()`（分別對 `queryBuffer4NodeIDs` 和 `queryBuffer4Nodes`），加上 `getNode()` 內部的 `queryBuffer4Node` 操作。一次完整查詢至少 8-10 次 `DispatchQueue.sync`。

2. **Date() 物件建立**：每次 `get()` / `set()` 都會在 `cleanupIfNeeded()` 中建立 `Date()` 物件用於時間戳比較。`Date()` 初始化涉及系統呼叫（`clock_gettime`），在高頻呼叫路徑上成本不可忽視。

3. **過期檢查的連鎖效應**：每次 `get()` / `set()` 的 `defer { cleanupIfNeeded() }` 都會檢查 `now.timeIntervalSince(lastCleanupTime) >= cleanupThreshold`，這又建立一個 `Date()` 物件。當清理觸發時，`removeExpiredEntries()` 再走一次 `lockQueue.sync {}` + 全表掃描。

4. **Hash 碰撞風險**：`QueryBuffer` 以 `Int`（即 `hashValue` 或 `Hasher().finalize()`）作為 cache key，而非原始 key。Swift 的 `Hasher` 每次進程啟動 seed 不同，但在同一進程內，不同輸入仍可能碰撞。

5. **多實例問題**：每個 `TextMapTrie` 擁有 4 個 `QueryBuffer` 實例（`queryBuffer4Node`、`queryBuffer4Nodes`、`queryBuffer4NodeIDs`、`queryBuffer4EntryGroups`），各自有獨立的 `DispatchQueue`。如果未來有多個 `TextMapTrie` 實例（如簡繁並存），鎖數量會線性增長。

---

#### 根因 C：PhonabetCipher 無快取（MEDIUM IMPACT）

**位置**：[PhonabetCipher.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/PhonabetCipher.swift)

**問題**：`convertPhonabetToASCII(_:)` 是純函式（相同輸入必產生相同輸出），但完全沒有快取。每次 factory 查詢都會對 keyArray 中的每個 key 呼叫一次，而注音讀音的總數是有限的（約 1300 個合法組合），重複轉換率極高。

在 `factoryUnigramsFor()` 中：
```swift
let encryptedKeyArray = keyArray.map { Self.convertPhonabetToASCII($0) }
```
這行對每個 key 都做一次逐字元 dictionary lookup + String 拼接。對於常見的 3-4 音節詞，每次查詢就是 3-4 次 `convertPhonabetToASCII()` 呼叫。

---

#### 根因 D：TrieStringPool / TrieStringOperationCache 鎖開銷（LOW-MEDIUM IMPACT）

**位置**：[TrieKit_PerformanceUtils.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-LibVanguard/Sources/_Modules/TrieKit/TrieKit_PerformanceUtils.swift)

**問題**：

1. **TrieStringPool.internKey()**：每次呼叫都走 `NSLock` 保護的 dictionary lookup。在 `getNodeIDsForKeyArray()` 中，對 keyArray 的每個元素都呼叫一次 `internKey(getCachedFirstChar($0))`，即 N 次 lock + unlock。

2. **TrieStringOperationCache.getCachedSplit()**：每次呼叫都構造複合鍵 `"\(string)|\(separator)"`（一次 String interpolation），然後在 `NSLock` 內做 dictionary lookup。這個複合鍵的構造本身就是一個 allocation 熱點。

3. **TrieStringOperationCache.getCachedFirstChar()**：同樣每次都走 `NSLock`。

4. **鎖的連鎖**：在 `getNodeIDsForKeyArray()` 的單次呼叫中，鎖的獲取順序為：
   - `TrieStringOperationCache.shared.lock` (getCachedFirstChar) × N
   - `TrieStringPool.shared.lock` (internKey) × N
   - `QueryBuffer.lockQueue` (get + set) × 2

   這些鎖雖然不會互相死鎖，但頻繁的 lock/unlock 上下文切換在主執行緒上會累積可觀的 overhead。

---

#### 根因 E：getNodes() 雙重驗證（LOW IMPACT）

**位置**：[TrieTextMap_Core.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-LibVanguard/Sources/_Modules/TrieKit/TrieTextMap_Core.swift) `getNodes(keyArray:filterType:partiallyMatch:longerSegment:)`

**問題**：`getNodeIDsForKeyArray()` 用 key initials（每個 syllable 的首字元拼接）做粗篩，返回候選 node ID 列表。然後 `getNodes()` 對每個候選 node 做：
1. `getNode(nodeID)` → 解析 node entries（可能觸發 value line parsing）
2. `getCachedSplit(node.readingKey, separator:)` → 拆分完整 reading key
3. `nodeMeetsFilter(node, filter:)` → 檢查 entry type
4. `zip(nodeKeyArray, keyArray).allSatisfy(==)` → 逐位精確比對

其中步驟 1-3 在步驟 4 判定不匹配時全部浪費。key initials 篩選是必要的粗篩，但粗篩到精篩之間缺少中間層快速拒絕機制。

---

#### 根因 F：Homa Assembler gramQueryCache 鍵開銷（LOW IMPACT）

**位置**：[Homa_Assembler.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_Homa/Sources/Homa/Homa_MainComponents/Homa_Assembler.swift) `queryGrams(using:cache:)`

**問題**：`gramQueryCache` 以 `[String]` 作為 dictionary key。Swift 的 `Array<String>` Hashable 實作需要遍歷整個陣列計算 hash，在 keyArray 較長時（如 5-6 音節）開銷不可忽視。此外，cache 滿 512 條時直接 `removeAll(keepingCapacity: true)`，這是全量淘汰而非 LRU，可能導致短期內 cache 命中率驟降。

---

### 8.3 解決方案

以下按優先順序排列，每個方案標注影響範圍、實作複雜度、與預期收益。

---

#### 方案 A：將 `&` alternatives 展開下推至 Trie 層級（HIGH PRIORITY）

**目標**：消除 `mergedAlternativeBucketUnigrams()` 的組合爆炸問題。

**現狀問題**：`LMInstantiator.mergedAlternativeBucketUnigrams(for:)` 在 LMI 層展開所有 `&` 組合，然後對每個組合呼叫完整的 `unigramsFor(keyArray:)`。這導致 factory trie 查詢、user phrases、symbols、filters、replacements 等後處理全部重複執行。

**解決思路**：`VanguardTrieProtocol` 已經有 `getNodes(keysChopped:filterType:partiallyMatch:)` 和 `getEntryGroups(keysChopped:filterType:partiallyMatch:)` 這兩個 API，它們在 trie 層級處理 `&` alternatives，且以 node ID 去重。應該讓 `factoryUnigramsFor()` 在偵測到 `&` 時改走 `keysChopped` 路徑，而非讓 LMI 層自行展開。

**具體改動**：

1. **在 `LMInstantiator_TextMapExtension.swift` 新增 `factoryUnigramsForChoppedKeys(keyArray:column:)`**：
   - 偵測 keyArray 是否含有 `&`
   - 若有，呼叫 `trie.getEntryGroups(keysChopped:encryptedKeyArray, filterType:column.trieEntryType, partiallyMatch:false)` 取得所有匹配的 entry groups
   - 將結果轉換為 `[Homa.Gram]`，只做一次 `makeFactoryUnigrams()`

2. **修改 `mergedAlternativeBucketUnigrams(for:)`**：
   - 不再展開所有組合後逐一呼叫 `unigramsFor(keyArray:)`
   - 改為：先對 factory trie 做一次 `keysChopped` 查詢取得所有 factory grams
   - 然後對每個展開後的 keyArray 組合只查詢 user phrases / symbols / filtered 等非 factory 來源
   - 最後合併 factory grams + 非 factory grams，只做一次 consolidation

3. **或者更激進的方案**：讓 `mergedAlternativeBucketUnigrams()` 直接改用 `factoryUnigramsForChoppedKeys()` 取得 factory 結果，然後對 user phrases 等也做類似的批量查詢（因為 user phrases 的 key 也可以用 `&` 展開），最後只做一次合併。

**預期收益**：以 3 syllable × 5 tone variants 為例，factory trie 查詢從 125 次降為 1 次（內部展開但去重），後處理從 125 次降為 1 次。整體 CPU 時間預計降低 60-80%（在 tone bucket 場景下）。

**風險**：需要確保 `keysChopped` 路徑的語義與現有 `expandAlternativeKeyArrays` + 逐一 `unigramsFor` 完全一致。特別是：
- `keysChopped` 路徑使用 `chopCaseSeparator`（`&`）作為分隔符，與 Phase 37 的 tone bucket 格式一致
- 需確認 `getEntryGroups(keysChopped:...)` 的去重邏輯與 `mergedAlternativeBucketUnigrams` 的 `Set<Homa.Gram>` 去重等價

**實作複雜度**：中等。核心改動集中在 `LMInstantiator_TextMapExtension.swift` 和 `LMInstantiator.swift`，不涉及 TrieKit 底層。

---

#### 方案 B：重構 QueryBuffer 為輕量級鎖 + 單調時鐘（MEDIUM PRIORITY）

**目標**：降低 QueryBuffer 的鎖競爭與時間戳開銷。

**具體改動**：

1. **替換 DispatchQueue 為 `os_unfair_lock`**：
   - macOS 12+ 已提供 `OSAllocatedUnfairLock`（Swift 原生包裝）
   - `os_unfair_lock` 是核心級輕量鎖，uncontended 情況下只需一次 atomic compare-and-swap，遠比 `DispatchQueue.sync` 高效
   - 改動：將 `private let lockQueue = DispatchQueue(...)` 替換為 `private let lock = OSAllocatedUnfairLock(initialState: ...) `

2. **替換 Date() 為單調時鐘**：
   - 將 `CacheEntry.timestamp: Date` 改為 `timestamp: UInt64`，存 `mach_absolute_time()` 或 `DispatchTime.now().uptimeNanoseconds`
   - `cleanupIfNeeded()` 的時間比較改為 `currentTime - lastCleanupTime >= thresholdNanoseconds`
   - 這避免了 `Date()` 初始化的系統呼叫開銷

3. **降低清理頻率**：
   - 目前每次 `get()` / `set()` 都觸發 `cleanupIfNeeded()`
   - 改為：維護一個 `operationCount` 計數器，每 64 次操作才檢查一次是否需要清理
   - 這將 `Date()` / `mach_absolute_time()` 呼叫頻率降低 64 倍

4. **考慮無鎖讀取**：
   - QueryBuffer 的讀多寫少模式適合用 `DispatchQueue.concurrentPerform` 或讀寫鎖
   - 更激進的方案：用 `NSCache` 替換自建 QueryBuffer（`NSCache` 已是 thread-safe 且有內建淘汰策略）
   - 但 `NSCache` 的 key 必須是 `NSObject` subclass，需要包裝 `Int` 為 `NSNumber`

**預期收益**：單次 `getNodes()` 的鎖開銷從 ~8 次 `DispatchQueue.sync` 降為 ~8 次 `os_unfair_lock` lock/unlock，每次從微秒級降為奈秒級。加上 `Date()` 開銷的消除，預計 QueryBuffer 相關 CPU 時間降低 50-70%。

**風險**：`OSAllocatedUnfairLock` 需要 macOS 12+，與專案 runtime target 一致，無相容性問題。但需注意 `os_unfair_lock` 不支持遞迴鎖定，需確保 `cleanupIfNeeded()` 不會在持有鎖時再次嘗試獲取鎖。

**實作複雜度**：低。改動集中在 `TK_QueryBuffer.swift` 單一檔案。

---

#### 方案 C：為 PhonabetCipher 新增結果快取（MEDIUM PRIORITY）

**目標**：消除重複的注音→ASCII 轉換開銷。

**具體改動**：

1. **在 `PhonabetCipher` 內新增靜態字典快取**：
   ```swift
   nonisolated enum PhonabetCipher {
     @usableFromInline static var asciiCache: [String: String] = [:]
     @usableFromInline static var asciiCacheLock = NSLock()

     static func convertPhonabetToASCII(_ incoming: String) -> String {
       guard !incoming.contains("_") else { return incoming }
       asciiCacheLock.withLock {
         if let cached = asciiCache[incoming] { return cached }
       }
       var result = ""
       result.reserveCapacity(incoming.unicodeScalars.count)
       for character in incoming {
         if let mapped = charPhonabet2ASCII[character] {
           result.append(mapped)
         } else {
           result.append(character)
         }
       }
       asciiCacheLock.withLock {
         if asciiCache.count < 2048 {
           asciiCache[incoming] = result
         }
       }
       return result
     }
   }
   ```

2. **或者更簡潔的方案**：直接用 `TrieStringPool` 的 `internKey` 模式，因為 PhonabetCipher 的輸入域極小（約 1300 個合法注音組合 + 少量特殊 key），快取永遠不會超過合理大小。

**預期收益**：在重複查詢相同讀音的場景下（這幾乎是所有場景），`convertPhonabetToASCII` 從逐字元 dictionary lookup + String 拼接降為單次 dictionary lookup。預計該函式 CPU 時間降低 80-90%。

**風險**：極低。純函式快取，不影響語義正確性。需注意 `restorePhonabetFromASCII` 也應同步新增快取。

**實作複雜度**：極低。改動集中在 `PhonabetCipher.swift` 單一檔案，約 10 行。

---

#### 方案 D：優化 TrieStringOperationCache 的複合鍵構造（LOW PRIORITY）

**目標**：消除 `getCachedSplit()` 的 String interpolation 開銷。

**具體改動**：

1. **將 `splitCache` 的 key 從 `String` 改為結構化鍵**：
   ```swift
   private struct SplitCacheKey: Hashable {
     let string: String
     let separator: Character
   }
   private var splitCache: [SplitCacheKey: [String]] = [:]
   ```

2. **移除 `getCachedSplit()` 中的 `"\(string)|\(separator)"` 構造**：
   ```swift
   func getCachedSplit(_ string: String, separator: Character) -> [String] {
     let key = SplitCacheKey(string: string, separator: separator)
     return lock.withLock {
       if let cached = splitCache[key] { return cached }
       let result = string.split(separator: separator).map(String.init)
       if splitCache.count < maxCacheSize { splitCache[key] = result }
       return result
     }
   }
   ```

**預期收益**：每次 `getCachedSplit()` 呼叫省去一次 String interpolation（涉及 memory allocation + copy），改為 stack 上的 struct 構造。在 `getNodes()` 的熱路徑中，這個函式被呼叫頻率極高。

**風險**：極低。純重構，不改變語義。

**實作複雜度**：極低。改動集中在 `TrieKit_PerformanceUtils.swift`，約 15 行。

---

#### 方案 E：在 getNodes() 中加入快速拒絕中間層（LOW PRIORITY）

**目標**：減少 `getNodes()` 中因粗篩通過但精篩失敗而浪費的 node 解析開銷。

**具體改動**：

1. **在 `getNodeIDsForKeyArray()` 返回候選 node ID 時，同時返回每個 node 的完整 key hash**：
   - 在 `KeyEntry` 中預計算 `keyArrayHash: Int`（在 init 時用 `Hasher()` 對完整 key 計算）
   - `getNodeIDsForKeyArray()` 返回 `[(nodeID: Int, keyHash: Int)]`
   - `getNodes()` 在呼叫 `getNode()` 之前，先用 `keyHash` 做快速拒絕

2. **或者更簡單的方案**：在 `KeyEntry` 中預存完整的 keyArray count，讓 `getNodes()` 在呼叫 `getNode()` 之前先檢查 count 是否匹配（對於 non-longerSegment 查詢，count 不匹配可直接跳過）。

**預期收益**：對於 key initials 粗篩後仍有大量候選的查詢（如單音節讀音），可避免不必要的 node 解析。但對於多音節查詢，粗篩已經足夠精確，收益有限。

**風險**：低。增加 `KeyEntry` 的記憶體佔用（每個 entry 多 4-8 bytes），但 keyEntries 陣列通常只有數萬條，影響可忽略。

**實作複雜度**：中等。需要修改 `KeyEntry` 結構、`parseKeyLineMapContent`、`getNodeIDsForKeyArray`、`getNodes` 等多處。

---

#### 方案 F：Homa Assembler gramQueryCache 改用預計算 hash key（LOW PRIORITY）

**目標**：降低 `gramQueryCache` 的 key 計算開銷。

**具體改動**：

1. **在 `queryGrams(using:cache:)` 中預計算 hash key**：
   ```swift
   let cacheHashKey: Int = {
     var hasher = Hasher()
     hasher.combine(keyArray)
     return hasher.finalize()
   }()
   ```
   然後用 `Int` 作為 cache key（類似 `QueryBuffer` 的做法），而非 `[String]`。

2. **或者改用 LRU 淘汰策略**：將 `gramQueryCache` 從 `[[String]: [Homa.Gram]]` 改為有容量限制的 `OrderedDictionary` 或自建 LRU cache，避免全量淘汰導致的命中率驟降。

**預期收益**：Cache lookup 從 O(N) hash（N = keyArray count）降為 O(1) hash。但由於 `gramQueryCache` 的命中率已經很高（大部分查詢在首次 assignNodes 後都會命中），實際收益有限。

**風險**：使用 `Int` 作為 cache key 有碰撞風險，需在碰撞時做 full key 比對。

**實作複雜度**：低。改動集中在 `Homa_Assembler.swift`。

---

### 8.4 方案優先順序與實作建議

| 方案 | 影響程度 | 實作複雜度 | 建議優先順序 | 備註 |
|------|----------|------------|-------------|------|
| A: `&` alternatives 下推至 Trie 層級 | HIGH | 中等 | **P0** | Phase 37 特有的最大效能瓶頸 |
| B: QueryBuffer 輕量級鎖 + 單調時鐘 | MEDIUM | 低 | **P1** | 通用基礎設施改善 |
| C: PhonabetCipher 結果快取 | MEDIUM | 極低 | **P1** | 投入產出比最高 |
| D: TrieStringOperationCache 結構化鍵 | LOW-MEDIUM | 極低 | **P2** | 順手可做 |
| E: getNodes() 快速拒絕中間層 | LOW | 中等 | **P3** | 需更多 profiling 數據確認收益 |
| F: gramQueryCache 預計算 hash key | LOW | 低 | **P3** | 邊際收益有限 |

**建議實作順序**：C → B → D → A → E → F

理由：
- C 和 B 是低風險、高回報的基礎設施改善，可以立即著手
- D 是順手可做的小改動
- A 是最核心的改動，但需要仔細驗證語義等價性，適合在 C/B/D 落地後再做（此時 profiling 數據更乾淨）
- E 和 F 的收益需要更多數據支撐，可留待後續 phase

---

### 8.5 補充說明：為何不建議在 Phase 37 內實作這些方案

Phase 37 的功能目標已結案（tone-less pinyin + continuous stem auto-chop），且這些效能改善涉及多個跨 repo 模組（LibVanguard 的 TrieKit、macOS 的 LangModelAssembly、Homa），不適合塞進已結案的 phase。建議另立 Phase 38 或獨立效能改善 phase 處理。

此外，目前的 profiling 數據來自 Xcode Instruments 的 unsymbolized XML 匯出（`TestResult_AfterPhase37_cpu_profile.xml`），缺少 dSYM 符號化資訊，無法直接從 hex address 對應到具體函式名稱。本次分析是基於 source code 靜態追蹤 + 既有 profiling 結論推導而出。**建議在實作任何方案之前，先用 symbolicated Instruments trace 做一次精確的 hot spot 確認**，避免基於推測做過度優化。
