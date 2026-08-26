# Phase 45 調查報告：拼音免聲調長句組字卡頓第二輪根因分析

> 調查日期：2026-04-25
> 研究範圍：`vChewing-macOS`（為主）、`vChewing-LibVanguard`
> 研究員：Kimi-K2.6 (Moonshot, service operated by VolcEngine)
> 觸發條件：拼音模式、免聲調輸入、組字區超過六個字
> 文檔狀態：完成、可用於後續 Phase 的開工依據。

---

## 一、問題現象

Phase 44 已落實 `hasUnigramsForFast`：
- 新增輕量版 availability 檢查，跳過濾除表、語彙置換、InputToken、DateTime 等後處理。
- `gramAvailabilityChecker`、`composeReadingIfReady`、`performPinyinAutoChopIfNeeded` 三處已切換至 `hasUnigramsForFast`。

但從 `vChewing-macOS` `./tmp/TestResult_AfterPhase44.trace` 可見，拼音模式免聲調輸入長句時，Main Thread 仍有 Severe Hang：

| 時間區段 | 持續時間 | 類型 |
|---------|---------|------|
| `00:10.647` – `00:11.108` | 461 ms | Microhang |
| `00:12.269` – `00:14.438` | 2.17 s | **Severe Hang** |

相較 Phase 43 的 2.67 s / 2.70 s / 14.12 s，最大 HANG 從 14.12 s 縮短至 2.17 s，但 2.17 s 的 Severe Hang 仍未消除。Instruments CPU Profiler 顯示熱點已從 `hasUnigramsFor` 轉移至 `mergedAlternativeBucketUnigrams` 內部的剩餘開銷。

---

## 二、Phase 44 後的熱路徑 Call Chain

從 `TestResult_AfterPhase44_cpu.xml` 的 HANG 區段提取的 top vChewing call chains（leaf-first）：

```
  93  specialized BidirectionalCollection<>.joined(separator:)
      < LMAssembly.LMInstantiator.mergedAlternativeBucketUnigrams(for:)
      < LMAssembly.LMInstantiator.unigramsFor(keyArray:)
      < LMAssembly.LMInstantiator.LookupHub.grams(for:)

  76  _StringGutsSlice._fastNFCCheck(_:_:)
      < specialized _StringGutsSlice._withNFCCodeUnits(_:)
      < _StringGutsSlice._normalizedHash(into:)
      < protocol witness for Hashable.hash(into:) in conformance String
      < specialized _NativeDictionary.mutatingFind(_:isUnique:)
      < LMAssembly.LMInstantiator.unigramsFor(keyArray:)

  67  _StringGutsSlice._fastNFCCheck(_:_:)
      < closure #2 in VanguardTrie.TextMapTrie.getNodes(...)
      < VanguardTrie.TextMapTrie.getNodes(...)
      < LMAssembly.LMInstantiator.factoryUnigramsFor(key:keyArray:column:)
      < specialized memoizedFactoryUnigrams in mergedAlternativeBucketUnigrams

  58  _stringCompareFastUTF8Abnormal(_:_:expecting:)
      < specialized Set.insert(_:)
      < protocol witness for IteratorProtocol.next() in conformance AlternativeKeyArrayIterator
      < _copySequenceToContiguousArray<A>(_:)   // ← Array(AnySequence)

  40  _stringCompareFastUTF8Abnormal(_:_:expecting:)
      < specialized __RawDictionaryStorage.find<A>(_:hashValue:)
      < _findStringSwitchCaseWithCache(cases:string:cache:)
      < specialized TokenTrigger.init(rawValue:)
      < TokenTrigger.init(rawValue:)
      < LMAssembly.LMInstantiator.mergedAlternativeBucketUnigrams(for:)

  33  _swift_stdlib_getScalarBitArrayIdx
      < _StringGutsSlice._fastNFCCheck(_:_:)
      < specialized Set.insert(_:)
      < protocol witness for IteratorProtocol.next() in conformance AlternativeKeyArrayIterator

  29  makeFactoryUnigrams
      < memoizedFactoryUnigrams
      < mergedAlternativeBucketUnigrams
      < unigramsFor

  24  closure #2 in LMCoreEX.unigramsFor
      < mergedAlternativeBucketUnigrams
      < unigramsFor
      < LookupHub.grams(for:)
```

---

## 三、根因分析

Phase 44 的 `hasUnigramsForFast` 成功切斷了 availability 路徑的完整重入，但 **`gramQuerier` 路徑**（即 `unigramsFor → mergedAlternativeBucketUnigrams`）仍是 Severe Hang 的來源。按影響程度排序：

---

### 根因 A：`mergedAlternativeBucketUnigrams` 中 `Array(AnySequence)` 強制全量展開（HIGHEST IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) line ~987

**問題**：

```swift
let expandedKeyArrays = Array(expandAlternativeKeyArrays(from: keyArray))
```

`expandAlternativeKeyArrays` 已於 Phase 44 改為回傳 `AnySequence<[String]>`（惰性迭代器），但 `mergedAlternativeBucketUnigrams` 仍用 `Array(...)` 將其**強制展開為完整陣列**。對 6-syllable、每 syllable 5 個聲調變體的場景，這會產生 15,625 個 `[String]` 實例。

`AlternativeKeyArrayIterator` 的 `next()` 內部使用 `seen.insert(joined)` 做去重，而 `joined` 是每次即時計算的 `result.joined(separator: "-")`。Instruments 顯示 `_stringCompareFastUTF8Abnormal` + `Set.insert` 佔據顯著比例，正是這個去重步驟的 string hash/compare 成本。

**關鍵矛盾**：`mergedAlternativeBucketUnigrams` 需要多次遍歷 `expandedKeyArrays`（先算 `expandedKeyChains` Set，再主迴圈處理），因此才強制轉 Array。但「多次遍歷」的需求本身可透過「單次 pass + 邊展開邊處理」消除。

---

### 根因 B：`TokenTrigger.init(rawValue:)` 對每個 expanded key 重複初始化（HIGH IMPACT）

**位置**：[LMInstantiator_DateTimeExtension.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator_DateTimeExtension.swift) + [LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) line ~1088

**問題**：

```swift
rawAllUnigrams.append(contentsOf: queryDateTimeUnigrams(with: keyChain, keyArray: expandedKeyArray))
```

`queryDateTimeUnigrams` 第一行：

```swift
guard let tokenTrigger = TokenTrigger(rawValue: key) else { return [] }
```

`TokenTrigger` 是 `RawRepresentable String enum`，`init(rawValue:)` 會對傳入的 `keyChain` 做 string switch 比對所有 case（約 20 個）。對 15,625 個 expanded key，即使 99.9% early return，仍有 15,625 次 enum switch + string compare。

Instruments 顯示 `_findStringSwitchCaseWithCache` + `__RawDictionaryStorage.find` 佔據顯著比例，正是 `TokenTrigger.init(rawValue:)` 的 string switch 實作。

---

### 根因 C：`joinedKeyCache` 與 `deferredFilterByKeyArray` 的 `[[String]]` hash 成本（MEDIUM-HIGH IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) line ~997–1015

**問題**：

```swift
var joinedKeyCache: [[String]: String] = [:]
var factoryLookupMemo: [FactoryLookupMemoKey: [Homa.Gram]] = [:]  // FactoryLookupMemoKey.keyArray 是 [String]
var deferredFilterByKeyArray: [[String]: Set<String>] = [:]
```

三個結構都以 `[String]` 作為 Dictionary key。Swift 對 `[String]` 的 `Hashable` 實現需要逐元素 hash（`_StringGutsSlice._normalizedHash` / `_fastNFCCheck`）。Instruments 顯示 `_StringGutsSlice._fastNFCCheck` + `_normalizedHash` 佔據大量 sample，正是這些字典操作的 string hash 成本。

`joinedKeyCache` 尤其多餘：它的目的是避免重複計算 `joined(separator: "-")`，但查找 cache 本身就要 hash `[String]`，其成本可能接近直接計算 joined string。

---

### 根因 D：`memoizedFactoryUnigrams` 的冗餘 memo 層（MEDIUM IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) line ~1017–1029

**問題**：`memoizedFactoryUnigrams` 在 `mergedAlternativeBucketUnigrams` 內部對 `.theDataSYMB` 查詢做 memo。但 `factoryUnigramsFor` 底層已經有 `factoryUnigramsCache: [String: [Homa.Gram]]`（以 joined key 為 key）。這裡的 `FactoryLookupMemoKey`（含 `[String]`）是多餘的一層 memo，增加了 hash 成本卻沒有額外收益。

---

### 根因 E：`lmUserPhrases.rangeMap.keys` 的 `Set` 構建成本（MEDIUM IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) line ~1035–1050

**問題**：

```swift
let userPhraseKeySet = Set(lmUserPhrases.rangeMap.keys)
  .union(lmUserPhrases.temporaryMap.keys)
```

每次 `mergedAlternativeBucketUnigrams` 都從 `rangeMap.keys` 構建 `Set<String>`。`rangeMap` 是 `LMCoreEX` 的內部字典，其 keys 數量可能達數萬。雖然 `Set` 構建是 O(N)，但 N 很大時仍不可忽略。更關鍵的是：這個 `Set` 在每次 `mergedAlternativeBucketUnigrams` 呼叫時都重新構建，而 `lmUserPhrases` 在單次組句過程中不會變更。

---

## 四、根因交互效應

```
Root Cause A (Array(AnySequence) 全量展開)
  → 產生 15,625 個 [String] 實例
  → Root Cause B (TokenTrigger.init) × 15,625 次 string switch
  → Root Cause C ([[String]] hash) × 數萬次字典操作
  → Root Cause E (Set 構建) 每輪重建
```

Phase 44 的 `hasUnigramsForFast` 切斷了 `gramAvailabilityChecker` 路徑，但 `gramQuerier` 路徑（`unigramsFor → mergedAlternativeBucketUnigrams`）在 `assignNodes()` 中仍被呼叫 21 次。每次呼叫都完整執行上述 A–E 的開銷，累積為 2.17 s Severe Hang。

---

## 五、解決方案建議

按優先順序排列：

---

### 方案 A：合併展開與處理為單次 pass，消除 `Array(AnySequence)`（HIGHEST PRIORITY）

**目標**：讓 `mergedAlternativeBucketUnigrams` 不再全量展開所有 alternatives。

**解決思路**：

1. **移除 `expandedKeyArrays = Array(...)`**：改為直接迭代 `expandAlternativeKeyArrays(from: keyArray)`。
2. **將「預篩選」與「主迴圈」合併為單次 pass**：
   - 不再需要 `expandedKeyChains`（因為不需要先算 Set）。
   - 對每個惰性展開的 `expandedKeyArray`：
     1. 計算 `keyChain = expandedKeyArray.joined(separator: "-")`（僅此一次）
     2. 檢查 user phrases / symbols / filtered — 直接以 `keyChain` 查詢 `rangeMap`，無需預建 Set
     3. 處理 factory symbols（memo 可直接以 `keyChain` 查 `factoryUnigramsCache`）
     4. 處理 dateTime — 見方案 B
     5. 累積結果

3. **消除 `joinedKeyCache`**：既然每個 `expandedKeyArray` 只處理一次，直接計算 `joined` 並傳遞，無需 cache。

4. **消除 `deferredFilterByKeyArray` 的 `[String]` key**：改為以 `String`（joined key）作為 key。

**預期收益**：
- 從 O(M^N) 記憶體分配（15,625 個 `[String]`）降為 O(1) 迭代器狀態。
- `AlternativeKeyArrayIterator` 的 `seen.insert(joined)` 成本隨迭代即時攤提，無需額外 `Array` 拷貝。
- 單次 pass 讓整體演算法更接近「 streaming」。

**風險**：需要重構 `mergedAlternativeBucketUnigrams` 的結構，但邏輯不變。

---

### 方案 B：`queryDateTimeUnigrams` 前置批次預篩選（HIGH PRIORITY）

**目標**：消除 15,625 次 `TokenTrigger.init(rawValue:)` 呼叫。

**解決思路**：

1. **提取 `TokenTrigger` 的所有 rawValue**：
   ```swift
   private static let allTokenTriggers: Set<String> = {
     Set(TokenTrigger.allCases.map(\.rawValue))
   }()
   ```

2. **在 `mergedAlternativeBucketUnigrams` 中，對所有 `expandedKeyChains` 批次檢查**：
   ```swift
   let hasAnyDateTimeTrigger = expandedKeyChains.contains(where) { TokenTrigger.allTokenTriggers.contains($0) }
   ```
   但這仍需要展開。更好的方式：

3. **直接在單次 pass 中檢查**：
   ```swift
   if DateTimeTokenTrigger.possibleTriggers.contains(keyChain) {
     rawAllUnigrams.append(contentsOf: queryDateTimeUnigrams(...))
   }
   ```
   或者更簡單：讓 `queryDateTimeUnigrams` 的判定邏輯外移，先檢查 `keyChain` 是否以已知的 trigger prefix 開頭（如 `ㄕˊ-ㄐㄧㄢ` 等），若無則完全跳過函式呼叫。

**更徹底的方案**：將 `TokenTrigger` 從 `enum : String` 改為 `struct` + `static let knownTriggers: Set<String>`，這樣 `contains` 檢查是 O(1) hash lookup，而非 string switch。

**預期收益**：15,625 次 `TokenTrigger.init(rawValue:)` 降為 0 次（無 trigger 時）或僅對實際命中者執行。

---

### 方案 C：將所有 `[[String]]` key 改為 `String` key（MEDIUM-HIGH PRIORITY）

**目標**：消除 `_StringGutsSlice._normalizedHash` 熱點。

**解決思路**：

1. **`factoryLookupMemo` 改為以 `String`（joined key）+ `CoreColumn` 為 key**：
   ```swift
   var factoryLookupMemo: [String: [Homa.Gram]] = [:]  // key 是 "joinedKey)|\(column.rawValue)"
   ```
   或者直接移除 `memoizedFactoryUnigrams`，因為 `factoryUnigramsFor` 內部已有 `factoryUnigramsCache`。

2. **`deferredFilterByKeyArray` 改為 `[String: Set<String>]`**：以 joined key 為 key。

3. **`factoryCoreUnigramsByKeyArray` 改為 `[String: [Homa.Gram]]`**：以 joined key 為 key。

**預期收益**：消除 `[String]` 的逐元素 hash，降低 30–50% 的字串處理開銷。

---

### 方案 D：快取 `rangeMap.keys` 的 `Set`（MEDIUM PRIORITY）

**目標**：消除每次 `mergedAlternativeBucketUnigrams` 重建 `Set` 的成本。

**解決思路**：

1. 在 `LMCoreEX` 中新增 `var keySet: Set<String>`，於資料載入/更新時同步維護。
2. 或者在 `LMInstantiator` 層級，對 `lmUserPhrases`、`lmUserSymbols`、`lmFiltered` 的快取 `Set<String>` 做懶性初始化，並在 `replaceData` 時失效。

**預期收益**：每次 `mergedAlternativeBucketUnigrams` 節省數萬次 string hash（`rangeMap.keys` → `Set`）。

---

### 方案 E：`factoryUnigramsFor` 內部 cache 的 key 統一（LOW-MEDIUM PRIORITY）

**目標**：確認並移除冗餘 memo 層。

**解決思路**：

1. 檢查 `factoryUnigramsFor` 內部的 `factoryUnigramsCache` 是否已涵蓋 `mergedAlternativeBucketUnigrams` 中 `memoizedFactoryUnigrams` 的使用場景（`.theDataSYMB`）。
2. 若已涵蓋，直接移除 `memoizedFactoryUnigrams` 與 `factoryLookupMemo`。

---

## 六、優先順序與建議執行順序

| 順序 | 方案 | 預期收益 | 實作複雜度 |
|------|------|---------|-----------|
| 1 | A: 單次 pass 消除全量展開 | 消除 15,625 個 `[String]` 分配 + `Array` 拷貝 + `Set` hash | 中等 |
| 2 | B: DateTime 批次預篩選 | 消除 15,625 次 `TokenTrigger.init` | 低 |
| 3 | C: `[[String]]` key 改 `String` | 消除逐元素 string hash | 低 |
| 4 | D: 快取 `rangeMap.keys` Set | 消除每輪 Set 重建 | 低 |
| 5 | E: 移除冗餘 factory memo | 簡化結構 | 低 |

**建議**：方案 A 是決定性因素——`Array(AnySequence)` 的全量展開是 Phase 44 後最大的殘餘浪費。只要改為單次 pass 迭代，即使方案 B–E 未實作，6-syllable 場景的 `mergedAlternativeBucketUnigrams` 也應從數百毫秒降為數十毫秒。

方案 B 則負責消除 `TokenTrigger.init` 的 string switch 爆炸，這在 trace 中佔據顯著比例。

---

## 七、方案 A+B+C 落地後的預期效能模型

假設方案 A、B、C 落地，6-syllable 免聲調拼音長句的 `mergedAlternativeBucketUnigrams` 效能模型：

- **展開階段**：
  - `AnySequence` 惰性迭代，不預先展開為 Array
  - 記憶體：O(1)（僅迭代器狀態）

- **單次 pass 處理**（對每個 expanded combination）：
  1. `joined(separator: "-")` 一次：O(S)（S = syllable 數）
  2. 原廠辭典查詢：`factoryChopped...` 已在迴圈外執行，迴圈內僅需 `factoryUnigramsCache` lookup（String key）
  3. User data 查詢：`rangeMap[joinedKey]` hash lookup（String key）
  4. DateTime：`Set.contains(joinedKey)`（O(1)），僅命中時才呼叫 `queryDateTimeUnigrams`
  5. Filtered：`Set.contains(joinedKey)`（O(1)），僅命中時才查詢

- **總結**：
  - 無 user data / dateTime / filter 命中時：單次 `mergedAlternativeBucketUnigrams` ≈ 15,625 × (String concat + 2–3 次 String hash lookup) ≈ 10–30 ms
  - 對比 Phase 44 的 50–200 ms：再降 3–10 倍
  - `assignNodes()` 呼叫 21 次：總計 < 500 ms，Severe Hang 轉為 Microhang 或完全消除

---

## 八、附錄：Trace 中的 Top Leaf Frames（HANG 區段內）

| 出現次數 | Leaf Frame |
|---------|-----------|
| 93 | `specialized BidirectionalCollection<>.joined(separator:)` |
| 76 | `_StringGutsSlice._fastNFCCheck(_:_:)` |
| 67 | `_StringGutsSlice._fastNFCCheck(_:_:)`（Trie getNodes 內） |
| 58 | `_stringCompareFastUTF8Abnormal(_:_:expecting:)`（Set.insert） |
| 40 | `_stringCompareFastUTF8Abnormal(_:_:expecting:)`（TokenTrigger switch） |
| 33 | `_swift_stdlib_getScalarBitArrayIdx`（Set.insert hash） |
| 29 | `makeFactoryUnigrams` |
| 24 | `closure #2 in LMCoreEX.unigramsFor` |
| 21 | `factoryChoppedUnigramsFor` |
| 17 | `mergedAlternativeBucketUnigrams` 自我呼叫 |

統計印證：
1. `joined(separator:)` 仍是 top leaf，但已從 Phase 43 的「hash lookup key」轉為「展開過程中的 string concat」。
2. `_StringGutsSlice._fastNFCCheck` 佔據顯著比例，對應 `[[String]]` Dictionary key 的 hash 成本。
3. `TokenTrigger.init(rawValue:)` 的 string switch 成為新熱點，需批次預篩選消除。
4. `Set.insert` 在 `AlternativeKeyArrayIterator` 中因 `Array(AnySequence)` 而放大。
