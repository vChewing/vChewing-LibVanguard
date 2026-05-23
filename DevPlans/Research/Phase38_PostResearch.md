# Phase 39 調查報告：拼音免聲調長句組字卡頓根因分析

> 結案日期：2026-04-23
> 研究範圍：`vChewing-macOS`（為主）、`vChewing-LibVanguard`
> 研究員：Claude Opus 4
> 觸發條件：拼音模式、免聲調輸入、組字區超過六個字
> 文檔狀態：完成、可用於後續 Phase 的開工依據。

---

## 一、問題現象

Phase 38 完成後，注音加密解密已從 TextMap query surface 徹底移除。但在拼音模式下以免聲調構建複雜長句子時，組字區超過六個字仍出現明顯延遲。Instruments Time Profiler 顯示兩個高 HANG 區段，主要熱點集中在：

```
LMAssembly.LMInstantiator.unigramsFor(keyArray:)          97.8%
  └─ factoryUnigramsFor(key:keyArray:column:)              39.3%
     └─ TextMapTrie.getNodes(keyArray:filterType:...)      38.0%
        └─ TextMapTrie.getNodeIDsForKeyArray(_:longerSegment:) 18.4%
           └─ Sequence.compactMap<A>(_:)                   12.0%
              └─ closure #2 in getNodeIDsForKeyArray        10.1%
                 └─ TrieStringOperationCache.getCachedFirstChar  6.4%
                    └─ Dictionary.subscript.getter           6.1%
                       └─ _stringCompareInternal              3.2%
```

---

## 二、完整熱路徑 Call Chain（拼音免聲調模式）

以單次 `unigramsFor(keyArray:)` 呼叫（含 `&` tone bucket）為例：

```
Homa.Assembler.assignNodes()
  ├── for each position × length:
  │     └── gramQuerier(keyArray)                        // [String] → [GramRAW]
  │           └── LMInstantiator.lookupHub.grams(for:)
  │                 └── LMInstantiator.unigramsFor(keyArray:)
  │                       ├── keyArray.joined().contains("&") → true
  │                       └── mergedAlternativeBucketUnigrams(for:)
  │                             └── expandAlternativeKeyArrays(from:)
  │                                   // 將 ["ㄕ&ㄕˊ&ㄕˇ&ㄕˋ&ㄕ˙", "ㄐㄧ&..."]
  │                                   // 展開為笛卡爾積，例如 5×5=25 組
  │                                   │
  │                             └── for each expandedKeyArray:   × N combinations
  │                                   └── unigramsFor(keyArray: expandedKeyArray)
  │                                         // 每次展開後的 keyArray 不再含 "&"
  │                                         // 但每次都完整跑一遍下方流程
  │                                         │
  │                                         ├── factoryUnigramsFor(column:.theDataCHEW)
  │                                         │     └── trie.getNodes(keyArray:, filterType:[], ...)
  │                                         │           ├── getNodeIDsForKeyArray(keyArray, longerSegment:false)
  │                                         │           │     ├── compactMap:
  │                                         │           │     │     TrieStringOperationCache.getCachedFirstChar($0)  × keyArray.count
  │                                         │           │     │     TrieStringPool.shared.internKey(...)              × keyArray.count
  │                                         │           │     ├── Hasher() → cacheKey
  │                                         │           │     ├── QueryBuffer4NodeIDs.get(hashKey:)   // DispatchQueue.sync + Date()
  │                                         │           │     ├── keyInitialsIDMap[keyInitials] lookup
  │                                         │           │     └── QueryBuffer4NodeIDs.set(hashKey:)   // DispatchQueue.sync + Date()
  │                                         │           │
  │                                         │           └── for each matchedNodeID:
  │                                         │                 ├── getNode(nodeID)
  │                                         │                 │     ├── QueryBuffer4Node.get(hashKey:)
  │                                         │                 │     ├── parsedEntries(keyEntryIndex)
  │                                         │                 │     └── QueryBuffer4Node.set(hashKey:)
  │                                         │                 ├── getCachedSplit(node.readingKey, separator:)
  │                                         │                 ├── nodeMeetsFilter(node, filter:)
  │                                         │                 └── zip(nodeKeyArray, keyArray).allSatisfy(==)
  │                                         │
  │                                         ├── factoryUnigramsFor(column:.theDataMISC)   // 如果 _ 前綴
  │                                         ├── factoryCoreUnigramsFor(strategy:.configuredLookup)
  │                                         │     └── factoryUnigramsFor(column:.theDataCHS/.theDataCHT)
  │                                         │           └── trie.getNodes(...)              // 同上，再跑一遍
  │                                         ├── factoryUnigramsFor(column:.theDataCNS)      // 如果啟用
  │                                         ├── factoryUnigramsFor(column:.theDataSYMB)     // 如果啟用
  │                                         ├── lmUserPhrases.unigramsFor(...)
  │                                         ├── lmUserSymbols.unigramsFor(...)
  │                                         ├── LMPlainBopomofo.valuesFor(...)
  │                                         ├── queryDateTimeUnigrams(...)
  │                                         ├── InputToken expansion
  │                                         ├── lmReplacements.valuesFor(...)
  │                                         ├── lmFiltered.unigramsFor(...)
  │                                         └── rawAllUnigrams.consolidate(filter:)
  │
  └── Homa.Assembler.queryGrams(using:cache:)
        // gramQuerier 的結果經 sortGramRAW + compactMap 去重後塞入 gramQueryCache
```

---

## 三、根因分析

經逐層拆解，拼音免聲調長句卡頓可歸因為以下四個根因，按影響程度排序：

---

### 根因 A：Tone Bucket 笛卡爾積展開導致查詢量指數膨脹（HIGH IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) `mergedAlternativeBucketUnigrams(for:)` + `expandAlternativeKeyArrays(from:)`

**問題**：Phase 37 實作的 tone bucket 機制，讓每個免聲調 syllable 以 `ㄕ&ㄕˊ&ㄕˇ&ㄕˋ&ㄕ˙` 格式傳入。當 `unigramsFor(keyArray:)` 偵測到 `&` 時，呼叫 `mergedAlternativeBucketUnigrams(for:)`，該函式先以 `expandAlternativeKeyArrays()` 做笛卡爾積展開，然後對每個展開後的 keyArray **完整**執行一次 `unigramsFor(keyArray:)`。

**量化**：以 6 個 syllable 為例——每個 syllable 有 5 個聲調變體（輕聲 + 四聲）：
- 笛卡爾積組合數：5⁶ = 15,625 次 `unigramsFor()` 呼叫
- 即使部分 syllable 僅有 2-3 個聲調變體（如零聲母），組合數仍輕易達到 3⁴ × 5² = 2,025 次
- 每次 `unigramsFor()` 內部會跑 5-6 次原廠 trie `getNodes()` 查詢（CHEW + MISC + Core + CNS + SYMB）
- 加上 user phrases / symbols / filtered / replacements / dateTime 等後處理

**核心矛盾**：Homa `Assembler.assignNodes()` 在建構長句時，對每個 position × length 組合都呼叫一次 `gramQuerier(keyArray)`，而 `gramQuerier` 就是 `unigramsFor(keyArray:)`。對 6 個 key，position × length 組合數為 6 + 5 + 4 + 3 + 2 + 1 = 21 次 `gramQuerier` 呼叫。其中最長的 keyArray（6 個 syllable）的笛卡爾積組合數可達數千。

**與既有基礎設施的矛盾**：`VanguardTrieProtocol` 已經提供 `getNodes(keysChopped:filterType:partiallyMatch:)` 和 `getEntryGroups(keysChopped:filterType:partiallyMatch:)` 這兩個在 trie 層級處理 `&` alternatives 的 API，內部自動展開並以 node ID 去重。但 `mergedAlternativeBucketUnigrams()` 完全沒有使用這些既有基礎設施，而是在 LMI 層自行展開。

**浪費量化**：以 3 個 syllable × 5 個 tone variants 為例（5³ = 125 組合）：
- 原廠 trie 查詢次數：125 × 5 columns = 625 次 `getNodes()`
- 每次 `getNodes()` 內部至少 4+4+2 = 10 次 `QueryBuffer` 操作（`DispatchQueue.sync` + `Date()`）
- 加上 `getCachedFirstChar` / `internKey` / `getCachedSplit` × keyArray.count
- User phrases / symbols / filtered / replacements 各 125 次
- Consolidation 125 次

如果改用 trie 層級的 `keysChopped` 路徑，原廠 trie 只需查詢一次（內部展開但去重），其餘後處理也只跑一次。

---

### 根因 B：`getNodeIDsForKeyArray` 內 `getCachedFirstChar` 的 Dictionary.subscript 開銷（MEDIUM-HIGH IMPACT）

**位置**：[TrieTextMap_Core.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-LibVanguard/Sources/_Modules/TrieKit/TrieTextMap_Core.swift) `getNodeIDsForKeyArray(_:longerSegment:)` → [TrieKit_PerformanceUtils.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-LibVanguard/Sources/_Modules/TrieKit/TrieKit_PerformanceUtils.swift) `TrieStringOperationCache.getCachedFirstChar(_:)`

**問題**：Instruments 顯示 `getCachedFirstChar` 佔 `getNodeIDsForKeyArray` 總時間的約 35%（838M / 2410M），而其內部的 `Dictionary.subscript.getter` 又佔 `getCachedFirstChar` 的 95%（793M / 838M），且其中有 42% 的時間花在 `_stringCompareInternal` 上。

**根因拆解**：

1. **每次呼叫都走 NSLock**：`getCachedFirstChar` 在 `lock.withLock {}` 內做 dictionary lookup。對於拼音 tone bucket 場景，同一個 keyArray 中不同聲調變體共享相同的首字元（如 `ㄕ` / `ㄕˊ` / `ㄕˇ` / `ㄕˋ` / `ㄕ˙` 的首字元都是 `ㄕ`），但因為 `getCachedFirstChar` 的 cache key 是完整字串，所以 `ㄕˊ` 和 `ㄕˋ` 被視為不同的 key，各自觸發一次 dictionary lookup。

2. **Swift Dictionary 的 string hash 碰撞放大**：`firstCharCache` 是 `[String: String]`，每次 lookup 都需要對 key 做 hash + equality check。對於包含 Unicode Bopomofo 字元的短字串（如 `ㄕˊ`），Swift 的 string comparison 走的是 full Unicode scalar comparison（`_stringCompareInternal` → `_stringCompareFastUTF8Abnormal`），這正是 trace 中看到的 3.2% `_stringCompareInternal` + 1.7% `_stringCompareFastUTF8Abnormal` 的來源。

3. **與 `internKey` 的重複鎖定**：`getNodeIDsForKeyArray` 對每個 key 先做 `getCachedFirstChar`（一次 NSLock），再做 `internKey`（又一次 NSLock）。兩次鎖定的臨界區都極短，但頻繁的 lock/unlock 本身在主執行緒上會累積開銷。

4. **cache 的複合鍵問題**：`getCachedSplit` 使用 `"\(string)|\(separator)"` 作為複合鍵，每次呼叫都要做一次 String interpolation，這也是一個 allocation 熱點。但此問題不在 `getNodeIDsForKeyArray` 的熱路徑上（`getCachedSplit` 在 `getNodes` 的 matchedNodeID 迴路中才用到），影響相對較小。

---

### 根因 C：QueryBuffer 的 DispatchQueue.sync + Date() 開銷（MEDIUM IMPACT）

**位置**：[TK_QueryBuffer.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-LibVanguard/Sources/_Modules/TrieKit/TK_QueryBuffer.swift)

**問題**：

1. **每次 `get()` / `set()` 都走 `DispatchQueue.sync {}`**：單次 `getNodes()` 至少觸發 `queryBuffer4NodeIDs` 的 1 get + 1 set，以及 `queryBuffer4Nodes` 的 1 get + 1 set。再加上 `getNode()` 內部的 `queryBuffer4Node` 操作。一次完整查詢至少 8-10 次 `DispatchQueue.sync`。

2. **每次操作都建立 `Date()` 物件**：`cleanupIfNeeded()` 在每次 `get()` / `set()` 的 `defer` 中被呼叫，每次都建立一個 `Date()` 物件。`Date()` 初始化涉及系統呼叫（`clock_gettime`），在高頻路徑上成本不可忽視。

3. **過期清理的連鎖效應**：當清理觸發時（每 7 秒），`removeExpiredEntries()` 在 `lockQueue.sync {}` 內做全表掃描，這會阻塞所有後續的 cache 操作。

4. **QueryBuffer 實例數量**：每個 `TextMapTrie` 擁有 4 個 `QueryBuffer` 實例，各自有獨立的 `DispatchQueue`。在 `getNodeIDsForKeyArray` → `getNodes` → `getNode` 的呼叫鏈中，最多可能同時涉及 3 個不同的 `QueryBuffer` 實例，各自做 `DispatchQueue.sync`。

**在拼音免聲調場景的放大效應**：由於根因 A 的笛卡爾積展開，`QueryBuffer` 操作次數被乘以組合數。以 125 組合為例，`QueryBuffer` 操作次數約為 125 × 10 = 1,250 次 `DispatchQueue.sync` + 1,250 個 `Date()` 物件。

---

### 根因 D：Homa Assembler `gramQueryCache` 對 `[String]` 鍵的 Hash 開銷 + 全量淘汰（LOW-MEDIUM IMPACT）

**位置**：[Homa_Assembler.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-LibVanguard/Sources/_Modules/Homa/Homa_MainComponents/Homa_Assembler.swift)

**問題**：

1. **`[String]` 作為 Dictionary key**：`gramQueryCache: [[String]: [Homa.Gram]]` 以完整的 keyArray 作為 dictionary key。Swift 的 `Array<String>` Hashable 實作需要遍歷整個陣列計算 hash，在 keyArray 較長時（如 5-6 個 syllable 的 tone bucket 展開後的組合）開銷不可忽視。

2. **全量淘汰策略**：cache 滿 512 條時 `removeAll(keepingCapacity: true)`，這是全量淘汰而非 LRU。在拼音免聲調長句場景中，`assignNodes()` 會遍歷所有 position × length 組合，每個組合的查詢結果不同。如果長度 ≥ 3 的組合數量超過 512 / 2 ≈ 256 個，cache 就會被清空，導致後續的 position × length 查詢全部 miss。

3. **與 Homa 的 `queryBuffer` 雙層快取設計**：`queryGrams(using:cache:)` 先查 local `queryBuffer`（`[[String]: [Homa.Gram]]`），再查 instance-level `gramQueryCache`，最後才呼叫 `gramQuerier`。在單次 `assignNodes()` 內，`queryBuffer` 提供跨 position × length 的去重，但 `gramQueryCache` 提供跨 `assignNodes()` 呼叫的去重。兩層快取都使用 `[String]` 作為 key，hash 開銷重複。

---

## 四、根因交互效應

上述四個根因並非獨立作用，而是在拼音免聲調長句場景下形成連鎖放大：

```
Root Cause A (笛卡爾積展開)
  → 查詢量從 O(positions × lengths) 放大為 O(positions × lengths × tone_variations^syllable_count)
  → Root Cause B (getCachedFirstChar 開銷) 被乘以組合數
  → Root Cause C (QueryBuffer 開銷) 被乘以組合數
  → Root Cause D (gramQueryCache 淘汰) 加速觸發
```

以一個 6-syllable 免聲調拼音句子為例：
- `assignNodes()` 的 position × length 組合數 = 21
- 最長的 keyArray（6 syllables）的笛卡爾積組合數 ≈ 5⁶ = 15,625
- 但 `gramQueryCache` 會在 512 條後清空，所以實際上每次 `assignNodes()` 只能利用最近 256 次 query 的快取
- 未被快取的查詢全部走完整路徑，而完整路徑又因為 `&` 展開而極其昂貴

**關鍵洞察**：根因 A 是根本性的演算法問題——在 LMI 層做笛卡爾積展開再逐一查詢，時間複雜度是 O(tone_variations^syllable_count)。根因 B/C/D 是微觀層面的開銷，但被根因 A 指數級放大。

---

## 五、解決方案建議

按優先順序排列：

---

### 方案 A：將 `&` alternatives 展開下推至 Trie 層級（HIGHEST PRIORITY）

**目標**：消除 `mergedAlternativeBucketUnigrams()` 的笛卡爾積展開問題。

**現狀**：`unigramsFor(keyArray:)` 偵測到 `&` 後，先 `expandAlternativeKeyArrays()` 做笛卡爾積，再逐一完整查詢。

**解決思路**：

`VanguardTrieProtocol` 已經有 `getNodes(keysChopped:filterType:partiallyMatch:)` 和 `getEntryGroups(keysChopped:filterType:partiallyMatch:)` API，它們在 trie 層級處理 `&` alternatives，內部自動展開並以 node ID 去重。應該讓 `factoryUnigramsFor()` 在偵測到 `&` 時改走 `keysChopped` 路徑。

**具體改動**：

1. **在 `LMInstantiator_TextMapExtension.swift` 新增 `factoryUnigramsForChoppedKeys(keyArray:column:)`**：
   - 偵測 keyArray 是否含有 `&`
   - 若有，呼叫 `trie.getEntryGroups(keysChopped: keyArray, filterType: column.trieEntryType, partiallyMatch: false)` 取得所有匹配的 entry groups
   - 將結果轉換為 `[Homa.Gram]`，只做一次 `makeFactoryUnigrams()`

2. **重構 `mergedAlternativeBucketUnigrams(for:)`**：
   - 不再展開所有組合後逐一呼叫 `unigramsFor(keyArray:)`
   - 改為：先對原廠 trie 做一次 `keysChopped` 查詢取得所有原廠 grams
   - 然後對每個展開後的 keyArray 組合只查詢 user phrases / symbols / filtered 等非原廠來源
   - 最後合併原廠 grams + 非原廠 grams，只做一次 consolidation

3. **或者更激進的方案**：讓 `mergedAlternativeBucketUnigrams()` 不再展開笛卡爾積，而是對每個 `expandAlternativeKeyArrays` 的結果只做非原廠查詢，原廠部分改用 `keysChopped` 一次性取得。

**預期收益**：原廠 trie 查詢從 O(tone_variations^syllable_count) 降為 O(1)（內部展開但去重）。後處理也從 N 次降為 1 次。整體 CPU 時間預計降低 70-90%（在 tone bucket 長句場景下）。

**風險**：需確保 `keysChopped` 路徑的語義與現有 `expandAlternativeKeyArrays` + 逐一 `unigramsFor` 完全一致。特別是：
- `keysChopped` 路徑使用 `chopCaseSeparator`（`&`）作為分隔符，與 Phase 37 的 tone bucket 格式一致
- 需確認 `getEntryGroups(keysChopped:...)` 的去重邏輯與 `mergedAlternativeBucketUnigrams` 的 `Set<Homa.Gram>` 去重等價

**實作複雜度**：中等。核心改動集中在 `LMInstantiator_TextMapExtension.swift` 和 `LMInstantiator.swift`，不涉及 TrieKit 底層。

---

### 方案 B：重構 `getNodeIDsForKeyArray` 的 key initials 計算（MEDIUM PRIORITY）

**目標**：消除 `getCachedFirstChar` + `internKey` 的重複鎖定與 string comparison 開銷。

**現狀**：`getNodeIDsForKeyArray` 對 keyArray 的每個元素執行：
```swift
keyArray.compactMap {
    TrieStringPool.shared.internKey(
        TrieStringOperationCache.shared.getCachedFirstChar($0)
    )
}.joined()
```
每次呼叫涉及 2×N 次 NSLock + N 次 Dictionary.subscript（string comparison）。

**解決思路**：

1. **改用 UTF-8 first byte 作為 key initial**：raw phonabet 字串的首位元組即可唯一確定聲母。對於 Phase 38 之後的 raw phonabet TextMap，`KEY_LINE_MAP` 中的 key 已經是 raw 注音符號（如 `ㄕ-ㄧ-ㄝ`），首字元就是聲母。可以改為直接取 `string.utf8.first` 來構建 key initials，避免 string comparison。

2. **預計算 key initials**：在 `TextMapTrie` 初始化時，對每個 `KeyEntry` 預計算其 key initials string 並存為 property，查詢時直接使用，避免 runtime 計算。

3. **合併 `getCachedFirstChar` + `internKey` 為單一操作**：減少鎖定次數從 2N 次降為 N 次。

4. **或者更根本的方案**：在 `TextMapTrie` 層級，對於 exact-match（`longerSegment == false`）場景，key initials 可以直接從 binary search 的結果獲得，無需先計算 key initials 再查 `keyInitialsIDMap`。因為 binary search 本身就是以完整 key 做比較，只要找到匹配的 key entry，就可以直接返回其 node ID。

**預期收益**：消除 `getCachedFirstChar` 佔用的 6.4% CPU 時間，以及相關的 `Dictionary.subscript` / `_stringCompareInternal` 開銷。

**實作複雜度**：中低。改動集中在 `TrieTextMap_Core.swift` 的 `getNodeIDsForKeyArray` 方法。

---

### 方案 C：重構 QueryBuffer 為輕量級鎖 + 單調時鐘（MEDIUM PRIORITY）

**目標**：降低 QueryBuffer 的鎖競爭與時間戳開銷。

**具體改動**：

1. **替換 DispatchQueue 為 `os_unfair_lock`**：
   - macOS 12+ 已提供 `OSAllocatedUnfairLock`（Swift 原生包裝）
   - `os_unfair_lock` 是核心級輕量鎖，uncontended 情況下只需一次 atomic compare-and-swap，遠比 `DispatchQueue.sync` 高效

2. **替換 Date() 為單調時鐘**：
   - 將 `CacheEntry.timestamp: Date` 改為 `timestamp: UInt64`，存 `mach_absolute_time()` 或 `DispatchTime.now().uptimeNanoseconds`
   - 這避免了 `Date()` 初始化的 `clock_gettime` 系統呼叫開銷

3. **降低清理頻率**：
   - 目前每次 `get()` / `set()` 都觸發 `cleanupIfNeeded()`
   - 改為：維護一個 `operationCount` 計數器，每 64 次操作才檢查一次是否需要清理
   - 將時間戳呼叫頻率降低 64 倍

**預期收益**：單次 `getNodes()` 的鎖開銷從 ~8 次 `DispatchQueue.sync` 降為 ~8 次 `os_unfair_lock` lock/unlock，每次從微秒級降為奈秒級。加上 `Date()` 開銷的消除，預計 QueryBuffer 相關 CPU 時間降低 50-70%。

**風險**：`OSAllocatedUnfairLock` 需要 macOS 12+，與專案 runtime target 一致，無相容性問題。

**實作複雜度**：低。改動集中在 `TK_QueryBuffer.swift` 單一檔案。

---

### 方案 D：Homa gramQueryCache 改用更高效的快取策略（LOW PRIORITY）

**目標**：降低 `gramQueryCache` 的 hash 開銷與淘汰策略問題。

**具體改動**：

1. **改用 `Int` 作為 cache key**：對 keyArray 預計算一個穩定 hash（如 `Hasher().combine(keyArray).finalize()`），以 `Int` 作為 cache key，避免每次 lookup 都重算 `Array<String>` 的 hash。

2. **改用 LRU 或 segmented LRU 淘汰策略**：取代 `removeAll(keepingCapacity: true)` 的全量淘汰，改為保留最近最常使用的條目。

**預期收益**：降低 cache lookup 的 hash 開銷，提高 cache 命中率。

**實作複雜度**：低。改動集中在 `Homa_Assembler.swift`。

---

## 六、優先順序與建議執行順序

| 順序 | 方案 | 預期收益 | 實作複雜度 |
|------|------|---------|-----------|
| 1 | A: Tone bucket 下推至 Trie 層級 | 70-90% CPU 降低（長句場景） | 中等 |
| 2 | B: key initials 計算重構 | 6-10% CPU 降低 | 中低 |
| 3 | C: QueryBuffer 輕量化 | 3-5% CPU 降低 | 低 |
| 4 | D: gramQueryCache 優化 | 1-2% CPU 降低 | 低 |

**建議**：方案 A 是決定性因素——只要笛卡爾積展開問題不解決，B/C/D 的最佳化效果會被指數級膨脹的查詢量完全淹沒。反之，方案 A 落地後，B/C/D 的最佳化在正常（非 tone bucket）場景下仍有價值，但不再是拼音免聲調長句卡頓的瓶頸。

---

## 七、方案 A 落地後的預期效能模型

假設方案 A 落地，6-syllable 免聲調拼音長句的效能模型變為：

- `assignNodes()` 的 21 次 `gramQuerier` 呼叫中：
  - 含 `&` 的 keyArray：原廠 trie 只做一次 `keysChopped` 查詢（內部展開去重）
  - 非原廠部分（user phrases / symbols / filtered 等）仍需按展開後的 keyArray 逐一查詢
  - 但非原廠查詢通常只涉及 hash table lookup（`lmUserPhrases.unigramsFor`），遠比 trie 查詢輕量

- 查詢量從 O(21 × tone_variations^max_syllable_count) 降為 O(21 × 1 + 21 × non_factory_cost_per_expanded_keyArray)
- 預計卡頓從秒級降為毫秒級

---

## 八、附錄：Trace 中的非瓶頸項目

以下項目在 trace 中出現但**不是**瓶頸，解釋為何：

1. **`_stringCompareFastUTF8Abnormal`**（1.7%）：這是 Swift string comparison 的內部實作，當字串包含 non-ASCII scalar 時走 abnormal path。這是 `getCachedFirstChar` 內 Dictionary lookup 的副作用，會隨方案 B 一起消失。

2. **`specialized Sequence.compactMap<A>(_:)`**（12%）：這是 `getNodeIDsForKeyArray` 中 `keyArray.compactMap { ... }` 的 Swift generic 特化，其成本主要來自閉包內的 `getCachedFirstChar` + `internKey` 呼叫。會隨方案 B 一起降低。

3. **`nodeMeetsFilter`** / **`zip(...).allSatisfy(==)`**：這些在 `getNodes` 的 matchedNodeID 迴路中，佔比不大，且是必要的精確匹配邏輯。

---

## 九、跨倉庫影響評估

| 倉庫 | 影響 |
|------|------|
| `vChewing-LibVanguard` | 方案 B/C 的改動位置；方案 A 不涉及（`keysChopped` API 已存在） |
| `vChewing-macOS` | 方案 A 的主要改動位置（`LMInstantiator_TextMapExtension.swift` + `LMInstantiator.swift`） |
| `vChewing-OSX-Legacy` | 需同步移植方案 A 的 `LMInstantiator` 改動 |
| `vChewing-VanguardLexicon` | 不受影響 |
