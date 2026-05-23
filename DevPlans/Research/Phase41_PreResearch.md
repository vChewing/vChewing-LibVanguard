# Phase 41 手術前調查報告：拼音免聲調長句卡頓殘餘熱區

> 調查日期：2026-04-24
> 研究範圍：vChewing-VanguardLexicon、vChewing-LibVanguard、vChewing-macOS、vChewing-OSX-Legacy
> 研究員：GPT-5.3-Codex
> 文檔狀態：PreResearch（可直接作為 Phase 41 實作開工依據）

---

## 一、問題重述與觀測結果

在 Phase 38 斷開 TextMap backend 的注音 encrypt/decrypt 路徑、Phase 39 導入 chopped lookup 後，拼音免聲調長句（組字區超過六字）仍有明顯延遲。

你提供的 `TestResult_BeforePhase40.trace` 熱點摘要顯示：

- `LMAssembly.LMInstantiator.mergedAlternativeBucketUnigrams(for:)` 99.9%
- `LMAssembly.LMInstantiator.factoryChoppedCoreUnigramsFor(keyArray:strategy:)` 45.9%
- `specialized closure #1 in static _UnsafeBitset._withTemporaryUninitializedBitset` 42.0%
- `specialized closure #1 in _NativeDictionary.filter(_:)` 13.3% / 8.6%

這組符號形狀說明：目前瓶頸不是單點查詞 API，而是「大量組合展開 + Set/Dictionary 重複過濾 + 快取清理重建」的疊加成本。

---

## 二、核心元兇（Root Causes）

### RC-A：`keysChopped` 路徑仍在做笛卡爾積全展開（高影響）

關鍵檔案：
- `vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/TrieKit/TrieProtocol.swift`
- `vChewing-LibVanguard/Sources/_Modules/TrieKit/TrieProtocol.swift`
- `vChewing-OSX-legacy/Shared/vChewingComponents/LMAssembly/TrieKit/TrieProtocol.swift`

`getEntryGroups(keysChopped:filterType:partiallyMatch:)` 與其對應 `getNodes(keysChopped:...)` 目前都先把每個 `&` alternatives 位置做完整組合展開（`possibleReadings`），再逐組查詢與去重。

這代表即便 Phase 39 已把 LMI 層從「完整 `unigramsFor` 反覆呼叫」改成「chopped 路徑」，Trie 層仍保留 `O(product(alternatives_per_slot))` 的展開成本。

`_UnsafeBitset` 熱點與這裡的 `Set<[String]>` / `Set<Int>` 大量插入、去重高度一致。

### RC-B：`mergedAlternativeBucketUnigrams` 內仍存在多段全量掃描（高影響）

關鍵檔案：
- `vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift`

在 `for expandedKeyArray in expandedKeyArrays` 迴圈內，仍有幾段會重複掃描大型陣列：

1. `factoryCoreUnigramsResult.filter { $0.keyArray == expandedKeyArray }`
2. `rawAllUnigrams.lazy.filter { $0.keyArray == expandedKeyArray }` 再取 `max()`
3. 每輪都做 `rawAllUnigrams.removeAll { ... }`（針對 filter 詞彙）

當展開組合數增大時，這些操作會從「線性」疊成「近似平方級」成本，並放大 `Array` / `Set` 暫存分配與 closure 執行成本。

### RC-C：`QueryBuffer` 清理採用 `cache.filter` 重建字典（中高影響）

關鍵檔案：
- `vChewing-LibVanguard/Sources/_Modules/TrieKit/TK_QueryBuffer.swift`
- `vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/TrieKit/TK_QueryBuffer.swift`
- `vChewing-OSX-legacy/Shared/vChewingComponents/LMAssembly/TrieKit/TK_QueryBuffer.swift`

目前 `removeExpiredEntriesLocked(now:)` 是：

`cache = cache.filter { now - timestamp <= expiration }`

此做法每次清理都會：

- 建立新字典
- 重算與搬移仍有效條目
- 執行大量 closure 與 Dictionary 內部 rehash/bitset 流程

這正對應 trace 的 `_NativeDictionary.filter` 熱點。

### RC-D：KeyInitials 粗篩在 tone bucket 場景區分度不足（中影響）

關鍵檔案：
- `.../TrieTextMap_Core.swift` 的 `getNodeIDsForKeyArray`
- `vChewing-VanguardLexicon/Sources/VanguardTrieKit/TrieKit/VanguardTrie_Core.swift` 的 keyInitials 建構策略

現行 key initials 以「每個幅節首字」拼接。對 tone bucket（同 stem 不同聲調）而言，很多 alternatives 首字相同，導致粗篩候選集偏大，後段 `getNode -> split -> zip compare` 的成本被放大。

這不是唯一元兇，但會在長句與 alternatives 多時成為放大器。

---

## 三、修復方案（Phase 41 建議執行藍圖）

以下方案按優先順序排列，皆以「先在 LibVanguard 實作，再鏡像到 macOS / legacy」為原則。

### P41-A：為 `keysChopped` 增設 TextMapTrie 專用快速路徑（最高優先）

目標：移除 `possibleReadings` 全量物化與全組合查詢。

建議做法：

1. 在 `VanguardTrie.TextMapTrie` 提供 specialized chopped lookup（建議新增內部 API）。
2. 以「每個位置可接受的 initials 集合」先做候選剪枝，再進行必要的精確比對，不再先展開全部組合。
3. 直接輸出 entry groups，並以 nodeID / canonical key 去重，避免 `Set<[String]>` 大量壓力。
4. `VanguardTrieProtocol` 預設實作保留作 fallback；TextMapTrie 優先走 specialized path。

預期收益：tone bucket 長句場景下降幅最大（主瓶頸）。

風險：需確保與既有 `keysChopped` 語義完全等價（候選完整性、排序穩定性、partialMatch 行為）。

### P41-B：重寫 `mergedAlternativeBucketUnigrams` 為分桶聚合流程（高優先）

目標：消除 expanded-loop 內的反覆全量掃描。

建議做法：

1. 先將原廠查詢結果建立索引（例如以 keyArray hash/struct key 映射），取代每輪 `filter`。
2. 每個 expandedKeyArray 使用局部 bucket 組裝，再一次性合併，避免對同一 `rawAllUnigrams` 反覆 `removeAll/filter`。
3. 使用者詞彙升權與濾除在 bucket 內完成，最後再 consolidate。
4. 對 `dataAsFilter` 引入 per-key cache，避免同 key 重算。

預期收益：顯著降低 `_UnsafeBitset`、陣列掃描與 closure hot path。

風險：需用 regression tests 鎖住單字升權、CNS demote、replacement、filter 先後順序語義。

### P41-C：QueryBuffer 清理改為 in-place expire removal（高優先）

目標：移除 `_NativeDictionary.filter` 重建成本。

建議做法：

1. 將 `cache = cache.filter { ... }` 改為兩段式：收集過期 key，再逐一 `removeValue`。
2. 可加入低水位條件（例如 `cache.count` 小於閾值時略過全掃），避免小表頻繁清理。
3. 保持現有 `NSLock + monotonic clock + cleanup interval` 設計不變，降低回歸風險。

預期收益：直接針對 trace 中 Dictionary.filter 熱點。

風險：需小心在 lock 內 mutation 的迭代安全性與容量抖動。

### P41-D：KeyInitials 二級索引優化（次優先，可併入 A）

目標：降低粗篩誤命中導致的後段 parse/compare 成本。

建議做法：

1. 在 TextMapTrie 初始化時預建更細粒度前綴索引（例如 initials + 長度維度）。
2. chopped lookup 先使用二級索引縮小候選，再做 exact verify。

預期收益：中等，但對長句、候選量大場景穩定有效。

風險：索引記憶體上升，需量測穩態 footprint。

---

## 四、四倉庫分工與落地順序

### 1) vChewing-LibVanguard（上游先行）

- 實作 P41-A/P41-B/P41-C 的 canonical 版本。
- 新增 unit/perf regression tests（見下一章）。

### 2) vChewing-macOS（鏡像 + 實機驗證）

- 同步移植 TrieKit、LMAssembly 相關改動。
- 以既有 profiling harness 對 `tmp/TestResult_BeforePhase40.trace` 場景重跑。

### 3) vChewing-OSX-legacy（語義對位）

- 同步 QueryBuffer、TrieProtocol/TextMapTrie、LMInstantiator 變更。
- 確保舊工具鏈下編譯可過，必要時保留最小條件編譯差異。

### 4) vChewing-VanguardLexicon（資料面支援）

- 本 phase 不建議變更詞庫格式。
- 建議新增 worst-case tone-bucket benchmark fixture（測試資產層級），協助穩定重現與回歸量測。

---

## 五、驗證計畫（Definition of Done）

### 功能正確性

1. tone-less 查詢結果集合與現行語義一致。
2. explicit tone full-match 行為不退化。
3. longer-syllable overmatch 保持受控（不得回歸 `shi -> shuai` 類問題）。
4. CNS filter/demote、replacement、user phrase boosting 排序規則不變。

### 效能驗收

1. `mergedAlternativeBucketUnigrams` self cycles 顯著下降。
2. `factoryChoppedCoreUnigramsFor` path 的總 cycles 下降。
3. `_UnsafeBitset` 與 `_NativeDictionary.filter` 不再列為前排 heavy hitters。
4. 長句（>6 字）拼音免聲調連打主觀延遲顯著改善。

### 建議測試矩陣

- LibVanguard：TrieKit + LMAssembly focused tests（含 alternatives 組合壓力測試）。
- macOS：LangModelAssembly / Typewriter 既有 regression + trace 比對。
- Legacy：`make debug-core`（或等效）確認無鏡像回歸。

---

## 六、結論

Phase 41 的核心結論是：

1. Phase 39 雖已避免「每組合重跑整套 `unigramsFor`」的最壞情況，但 `keysChopped` 在 TrieProtocol 層仍保留笛卡爾積展開，造成主瓶頸尚未根治。
2. `LMInstantiator.mergedAlternativeBucketUnigrams` 內部仍有多段展開後全量掃描，與 `Set/Dictionary` 密集運算共同推高 `_UnsafeBitset` 熱點。
3. `QueryBuffer` 的 `cache.filter` 清理策略直接對應 `_NativeDictionary.filter` 高熱點，屬可立即收斂的低風險修補點。

因此，Phase 41 應聚焦三件事：

- 先把 chopped lookup 改為 specialized fast path（去除全展開）
- 再把 mergedAlternativeBucketUnigrams 改為分桶聚合
- 最後把 QueryBuffer 清理改為 in-place

這三刀完成後，才有機會在長句拼音免聲調場景把延遲從「可感知卡頓」降回可接受範圍。
