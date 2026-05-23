# Phase 46 調查報告：拼音免聲調長句組字卡頓第三輪根因分析

> 調查日期：2026-04-25
> 研究範圍：`vChewing-macOS`（為主）
> 研究員：Kimi（Moonshot）
> 觸發條件：拼音模式、免聲調輸入、組字區超過六個字
> 文檔狀態：完成、可用於後續 Phase 的開工依據。

---

## 一、問題現象

Phase 44–45 已完成兩輪最佳化：
- Phase 44：新增 `hasUnigramsForFast`，切斷 availability 檢查的完整重入。
- Phase 45：`mergedAlternativeBucketUnigrams` 改為單次 pass 迭代（`AnySequence` 惰性展開），消除 `Array(AnySequence)` 的全量展開與 `[[String]]` Dictionary key。

但從 `vChewing-macOS` `./tmp/TestResult_AfterPhase45.trace` 可見，拼音模式免聲調輸入長句時，Main Thread 的 Severe Hang 不僅未消除，反而顯著惡化：

| 時間區段 | 持續時間 | 類型 |
|---------|---------|------|
| `00:10.951` – `00:11.434` | 483 ms | Microhang |
| `00:12.971` – `00:15.004` | 2.03 s | Severe Hang |
| `00:17.230` – `00:28.310` | **11.08 s** | **Severe Hang** |

**總 Severe Hang 時間：13.11 s**，遠超 Phase 44 的 2.17 s。

---

## 二、Phase 45 後的熱路徑 Call Chain

從 `TestResult_AfterPhase45_cpu.xml` 的 HANG 區段提取的 top vChewing call chains（leaf-first）：

```
  93  specialized BidirectionalCollection<>.joined(separator:)
      < LMAssembly.LMInstantiator.mergedAlternativeBucketUnigrams(for:)
      < LMAssembly.LMInstantiator.unigramsFor(keyArray:)
      < LMAssembly.LMInstantiator.LookupHub.grams(for:)

  76  _StringGutsSlice._fastNFCCheck(_:_:)
      < specialized _StringGutsSlice._withNFCCodeUnits(_:)
      < _StringGutsSlice._normalizedHash(into:)
      < <deduplicated_symbol>
      < specialized Dictionary.subscript.getter
      < LMAssembly.LMInstantiator.unigramsFor(keyArray:)

  67  specialized Set.contains(_:)
      < specialized Set.contains(_:)
      < LMAssembly.LMInstantiator.unigramsFor(keyArray:)
      < LMAssembly.LMInstantiator.LookupHub.grams(for:)
      < closure #2 in InputHandler.init(...)
      < Homa.Assembler.queryGrams(using:cache:)

  58  _StringGutsSlice._fastNFCCheck(_:_:)
      < protocol witness for Hashable._rawHashValue(seed:) in conformance String
      < specialized Set.insert(_:)
      < protocol witness for IteratorProtocol.next() in conformance
        LMAssembly.LMInstantiator.AlternativeKeyArrayIterator

  40  _stringCompareInternal(_:_:expecting:)
      < _stringCompare(_:_:expecting:)
      < LMAssembly.LMInstantiator.unigramsFor(keyArray:)
      < LMAssembly.LMInstantiator.LookupHub.grams(for:)

  33  _xzm_free / _xzm_xzone_malloc
      < swift_allocObject
      < specialized Array._createNewBuffer(...)
      < VanguardTrie.TextMapTrie.getNodes(...)
      < LMAssembly.LMInstantiator.factoryUnigramsFor(...)

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

Phase 45 的單次 pass 消除了 `Array(AnySequence)` 的記憶體分配峰值，但 `mergedAlternativeBucketUnigrams` 的**單一組合處理成本**與**總組合數量**均未降低。按影響程度排序：

---

### 根因 A：`AlternativeKeyArrayIterator` 的 `seen` Set 去重是純粹浪費（HIGHEST IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) line ~863–907

**問題**：

```swift
private struct AlternativeKeyArrayIterator: IteratorProtocol {
  private var seen: Set<String>

  mutating func next() -> [String]? {
    while !isDone {
      let result = alternativeColumns.indices.map { alternativeColumns[$0][indices[$0]] }
      let joined = result.joined(separator: "-")
      // ...
      if seen.insert(joined).inserted {
        return result
      }
    }
    return nil
  }
}
```

`seen` Set 的目的是去重，但對於拼音免聲調的 tone bucket 場景，每列的 alternatives 是**互不相同**的（如 `ㄕ` / `ㄕˊ` / `ㄕˇ` / `ㄕˋ` / `ㄕ˙`）。笛卡爾積的數學性質保證：若每列元素互異，則所有組合必然互異，**不可能出現重複**。

因此 `seen.insert(joined)` 永遠回傳 `.inserted`，但每次仍要：
1. 計算 `result.joined(separator: "-")`（string concat）
2. 對 joined string 做 hash（`_StringGutsSlice._normalizedHash` / `_fastNFCCheck`）
3. 在 `Set` 中查找並插入

對 15,625 個組合，這是 15,625 次完全浪費的 string concat + hash + Set 操作。Instruments 顯示 `Set.insert` + `_fastNFCCheck` 佔據顯著比例，正是此處。

**關鍵矛盾**：去重機制是為了防禦「同一列內含重複 alternatives」的邊緣情況，但這在 tone bucket 場景下不可能發生。演算法為了極低概率的邊緣情況，支付了 100% 場景的固定成本。

---

### 根因 B：`mergedAlternativeBucketUnigrams` 迴圈中每個組合做 `joined(separator: "-")`（HIGH IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) line ~988–1053

**問題**：

```swift
for expandedKeyArray in expandAlternativeKeyArrays(from: keyArray) {
  let keyChain = expandedKeyArray.joined(separator: "-")
  // ...
}
```

迴圈內第一行即計算 `joined(separator: "-")`。對 15,625 個組合，這是 15,625 次 string concat。Instruments 顯示 `BidirectionalCollection<>.joined(separator:)` 為 top leaf，印證此處是最大熱點。

更糟的是，迴圈內多個位置間接重複使用 joined key（但不再重複計算）：
- `factoryCoreUnigramsByKeyArray[keyChain]`
- `lmUserSymbols.hasUnigramsFor(key: keyChain)`
- `memoizedFactoryUnigrams(keyChain: keyChain, ...)`
- `lmUserPhrases.hasUnigramsFor(key: keyChain)`
- `lmFiltered.hasUnigramsFor(key: keyChain)`
- `dateTimeKnownTriggers.contains(keyChain)`
- 最後 `deferredFilterByKeyArray` 遍歷時：`gram.keyArray.joined(separator: "-")`

---

### 根因 C：非原廠查詢的 hash lookup 次數隨組合數線性膨脹（HIGH IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) line ~993–1052

**問題**：迴圈內對每個組合執行：

```swift
lmUserSymbols.hasUnigramsFor(key: keyChain)     // hash lookup
lmUserPhrases.hasUnigramsFor(key: keyChain)     // hash lookup
lmFiltered.hasUnigramsFor(key: keyChain)        // hash lookup
Self.dateTimeKnownTriggers.contains(keyChain)   // Set.contains (hash lookup)
```

即使這些查詢單次僅 ~1–2 µs，15,625 × 4 = 62,500 次累積仍達 60–120 ms。加上 Swift runtime 的函式呼叫開銷、`String` hash、記憶體存取，實際可能達 200–500 ms 每輪 `mergedAlternativeBucketUnigrams`。

Phase 45 之前的批量預篩選（`expandedKeyChains.intersection(userPhraseKeySet)`）雖然有 Set 構建成本，但能在「無 user data 命中」時一次性跳過全部組合。Phase 45 的單次 pass 為了消除 `Array` 分配，將這個「整批短路」能力也一併移除。

---

### 根因 D：`memoizedFactoryUnigrams` 在同輪中命中率極低（MEDIUM IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) line ~973–986

**問題**：

```swift
func memoizedFactoryUnigrams(
  keyArray: [String],
  keyChain: String,
  column: LMAssembly.LMInstantiator.CoreColumn
) -> [Homa.Gram] {
  let memoKey = "\(keyChain)|\(column.rawValue)"
  if let cached = factoryLookupMemo[memoKey] { return cached }
  let resolved = factoryUnigramsFor(key: keyChain, keyArray: keyArray, column: column)
  factoryLookupMemo[memoKey] = resolved
  return resolved
}
```

`factoryUnigramsFor` **內部沒有任何 cache**（直接呼叫 `trie.getNodes` -> `makeFactoryUnigrams`）。`memoizedFactoryUnigrams` 在 `mergedAlternativeBucketUnigrams` 內部加了一層 `factoryLookupMemo`。

但在單次 `mergedAlternativeBucketUnigrams` 呼叫中，每個 `expandedKeyArray` 的 `keyChain` 都不同（笛卡爾積的每個組合唯一），因此 `factoryLookupMemo` **幾乎不會命中**。它的實際效果是：
1. 每次查詢都要拼接 `memoKey` string
2. 執行一次 Dictionary lookup（必然 miss）
3. 呼叫 `factoryUnigramsFor`（trie 查詢）
4. 將結果存入 Dictionary（永遠不會被再次讀取）

步驟 1、2、4 是純 overhead，沒有帶來任何快取收益。

---

### 根因 E：`deferredFilterByKeyArray` 最後遍歷時重複計算 joined key（MEDIUM IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) line ~1055–1060

**問題**：

```swift
rawAllUnigrams.removeAll { gram in
  let keyChain = gram.keyArray.joined(separator: "-")
  guard let dataAsFilter = deferredFilterByKeyArray[keyChain] else { return false }
  return dataAsFilter.contains(gram.current)
}
```

對 `rawAllUnigrams` 中每個 gram（可能數百至數千筆），重新計算 `joined(separator: "-")`。如果結果數量大，這是額外的 O(N) string concat。

---

### 根因 F：`topScoreByKeyArray` 使用 joined String key（LOW-MEDIUM IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) line ~963–969

**問題**：

```swift
let topScoreByKeyArray: [String: Double] = rawAllUnigrams.reduce(into: [:]) { partialResult, current in
  let keyChain = current.keyArray.joined(separator: "-")
  // ...
}
```

構建 `topScoreByKeyArray` 時對 `rawAllUnigrams` 中每個 gram 計算 joined key。`rawAllUnigrams` 在這個階段已包含原廠辭典結果（可能數百筆），每筆都做一次 string concat。

---

## 四、根因交互效應

```
Root Cause A (seen Set 去重浪費)
  -> 15,625 次 joined + hash + Set.insert
  -> Root Cause B (迴圈內 joined) 叠加，總計 ~30,000+ 次 string concat
  -> Root Cause C (hash lookup 線性膨脹) x 15,625 組合
  -> Root Cause E (最後遍歷 joined) x N grams
```

Phase 45 的單次 pass 消除了 `Array` 分配的記憶體峰值，但**單一組合處理成本未變**。當輸入句子增長（如從 6 syllables 增至 8–10 syllables），M^N 組合數從 15,625 爆炸至 390,625（8 syllables）或 9,765,625（10 syllables），總時間隨組合數線性增長，導致 11.08 s 的 Severe Hang。

---

## 五、解決方案建議

按優先順序排列：

---

### 方案 A：條件式去重（移除 `seen` Set）（HIGHEST PRIORITY）

**目標**：消除 15,625 次無意義的 joined + hash + Set.insert。

**解決思路**：

1. **判斷是否需要去重**：在 `expandAlternativeKeyArrays` 中，檢查每列 alternatives 是否有重複：
   ```swift
   let needsDedup = alternativeColumns.contains { column in
     Set(column).count != column.count
   }
   ```
   對於 tone bucket 場景，`needsDedup` 為 `false`。

2. **無需去重時回傳簡化迭代器**：
   ```swift
   if !needsDedup {
     return AnySequence {
       SimpleAlternativeKeyArrayIterator(alternativeColumns: alternativeColumns)
     }
   }
   ```
   `SimpleAlternativeKeyArrayIterator` 沒有 `seen` Set，直接返回所有組合。

3. **需要去重時保留現有 `AlternativeKeyArrayIterator`**。

**預期收益**：tone bucket 場景下消除 100% 的 `seen` Set 開銷（15,625 次 joined + hash + insert）。

**實作複雜度**：低。僅需新增一個簡化迭代器與條件分支。

---

### 方案 B：讓迭代器同時回傳 joined key，消除迴圈內重複計算（HIGH PRIORITY）

**目標**：消除 `mergedAlternativeBucketUnigrams` 迴圈內的 `joined(separator: "-")`。

**解決思路**：

1. **修改迭代器回傳 `(keyArray, joinedKey)`**：
   ```swift
   struct AlternativeKeyArrayJoinedIterator: IteratorProtocol {
     typealias Element = (keyArray: [String], joinedKey: String)
     // ...
     mutating func next() -> Element? {
       // ...
       let result = alternativeColumns.indices.map { ... }
       let joined = result.joined(separator: "-")
       // 推進 indices...
       return (result, joined)
     }
   }
   ```

2. **迴圈直接使用預計算的 joinedKey**：
   ```swift
   for (expandedKeyArray, keyChain) in expandAlternativeKeyArraysWithJoined(from: keyArray) {
     // 無需再計算 joined
   }
   ```

**預期收益**：消除迴圈內 15,625 次 `joined(separator: "-")`。

**實作複雜度**：低。

---

### 方案 C：批量預篩選非原廠查詢，恢復「整批短路」能力（HIGH PRIORITY）

**目標**：消除 62,500 次無意義的 hash lookup。

**解決思路**：

1. **在迴圈前先檢查 user data 是否可能有命中**：
   ```swift
   let hasUserData = !config.bypassUserPhrasesData && (
     !lmUserPhrases.keySet.isEmpty ||
     (config.isSymbolEnabled && !lmUserSymbols.keySet.isEmpty) ||
     !lmFiltered.keySet.isEmpty
   )
   ```
   若 `hasUserData` 為 `false`，迴圈內直接跳過所有 user data 查詢。

2. **更激進的預篩選**：先取前 N 個展開組合（如 100 個）測試是否有 user data 命中。若無，假設整批無命中並跳過。
   > 風險：可能誤判。需確認 user data 的分佈特性。

**預期收益**：無 user data 時，迴圈內僅保留原廠查詢與 DateTime 檢查，hash lookup 從 62,500 次降為 0 次。

**實作複雜度**：低（方案 1）至中（方案 2）。

---

### 方案 D：移除 `memoizedFactoryUnigrams` 冗余層（MEDIUM PRIORITY）

**目標**：消除無意義的 Dictionary lookup 與 string 拼接 overhead。

**解決思路**：

由於 `factoryUnigramsFor` **內部沒有 cache**，且 `factoryLookupMemo` 在同輪中命中率為 0（每個組合的 `keyChain` 唯一），`memoizedFactoryUnigrams` 純粹是多餘的包裝。

**直接內聯**：將 `memoizedFactoryUnigrams(...)` 改為直接呼叫 `factoryUnigramsFor(...)`，移除 `factoryLookupMemo` 變數與 `memoizedFactoryUnigrams` 函式。

**預期收益**：消除每次呼叫的 `memoKey` 拼接 + Dictionary miss lookup + 結果寫入。

**實作複雜度**：低。

---

### 方案 E：優化 `deferredFilterByKeyArray` 與 `topScoreByKeyArray` 的 joined key 計算（MEDIUM PRIORITY）

**目標**：消除最後遍歷與預處理階段的重複 joined。

**解決思路**：

1. **`deferredFilterByKeyArray`**：迴圈內已經知道 `keyChain`，可直接在 `rawAllUnigrams` 中標記哪些 gram 需要過濾，避免最後遍歷時重新計算 joined。
   或者：將 `deferredFilterByKeyArray` 的 key 改為 `Int`（`keyArray` 的 hash value），避免 string 比對。

2. **`topScoreByKeyArray`**：改為遍歷 `factoryCoreUnigramsResult` 而非 `rawAllUnigrams`，因為只有原廠結果需要 top score。

**預期收益**：降低最後遍歷與預處理的 string concat 成本。

**實作複雜度**：低。

---

## 六、優先順序與建議執行順序

| 順序 | 方案 | 預期收益 | 實作複雜度 |
|------|------|---------|-----------|
| 1 | A: 條件式去重（移除 `seen` Set） | 消除 15,625 次 joined + hash + Set.insert | 低 |
| 2 | B: 迭代器回傳 joined key | 消除迴圈內 15,625 次 joined | 低 |
| 3 | C: 批量預篩選非原廠查詢 | 消除 62,500 次 hash lookup | 低 |
| 4 | D: 移除 `memoizedFactoryUnigrams` | 消除無意義的 memo overhead | 低 |
| 5 | E: 優化 `deferredFilter` / `topScore` | 降低最後遍歷成本 | 低 |

**建議**：方案 A + B + C 是決定性組合。
- A 消除迭代器自身的浪費（約 20–30% 的 CPU）。
- B 消除迴圈內最熱的 `joined(separator:)`（約 30–40% 的 CPU）。
- C 消除非原廠查詢的線性膨脹（約 20–30% 的 CPU）。

三項合計預計可將 `mergedAlternativeBucketUnigrams` 的單次執行時間從數百毫秒降至數十毫秒。

---

## 七、方案 A+B+C 落地後的預期效能模型

假設方案 A、B、C 落地，6-syllable 免聲調拼音長句的 `mergedAlternativeBucketUnigrams` 效能模型：

- **展開階段**：
  - `SimpleAlternativeKeyArrayIterator` 無 `seen` Set，無 joined 計算
  - 記憶體：O(1)

- **迴圈處理**（對每個 expanded combination）：
  1. 直接使用預計算的 `joinedKey`，無 string concat
  2. 若 `hasUserData` 為 `false`：
     - 僅執行 `factoryCoreUnigramsByKeyArray[joinedKey]`（Dictionary lookup）
     - `dateTimeKnownTriggers.contains(joinedKey)`（Set.contains）
     - 單次組合處理 ≈ 2 次 hash lookup
  3. 若 `hasUserData` 為 `true`：
     - 追加 `lmUserPhrases.hasUnigramsFor(key:)` 等 3 次 hash lookup
     - 但多數場景 `hasUserData` 為 `false`

- **總結**：
  - 無 user data 時：15,625 × 2 次 hash lookup ≈ 10–20 ms
  - 對比 Phase 45 的 50–200 ms：再降 5–10 倍
  - `assignNodes()` 呼叫 21 次：總計 < 500 ms，Severe Hang 轉為 Microhang 或完全消除

---

## 八、為何 Phase 45 後 HANG 反而惡化？

Phase 45 的單次 pass 重構雖然消除了 `Array(AnySequence)` 的全量展開（降低峰值記憶體），但：
1. **失去了批量預篩選能力**：Phase 44 之前用 `Set.intersection` 預篩選，可在「無 user data」時一次性跳過全部組合。Phase 45 改為逐組合檢查，導致每個組合都必須執行 `hasUnigramsFor` hash lookup。
2. **`seen` Set 的浪費被放大**：Phase 45 之前 `Array(AnySequence)` 一次性展開，`seen` 的檢查在展開過程中完成。Phase 45 的迭代器將這個成本分散到每次 `next()`，但每次仍有 joined + hash + insert。
3. **測試場景可能更長**：若 Phase 45 測試了 8–10 syllable 的句子，組合數從 15,625 增至 390,625 或更高，線性膨脹的開銷自然增加。

---

## 九、附錄：Trace 中的 Top Leaf Frames（HANG 區段內）

| 出現次數 | Leaf Frame |
|---------|-----------|
| 93 | `specialized BidirectionalCollection<>.joined(separator:)` |
| 76 | `_StringGutsSlice._fastNFCCheck(_:_:)`（Dictionary hash） |
| 67 | `specialized Set.contains(_:)` |
| 58 | `_StringGutsSlice._fastNFCCheck(_:_:)`（Set.insert hash） |
| 40 | `_stringCompareInternal(_:_:expecting:)` |
| 33 | `_xzm_free` / `_xzm_xzone_malloc`（Array 分配） |
| 29 | `makeFactoryUnigrams` |
| 24 | `closure #2 in LMCoreEX.unigramsFor` |
| 21 | `getNodes` / `getEntryGroups`（Trie 查詢） |

統計印證：
1. `joined(separator:)` 仍是 top leaf，說明 Phase 45 未解決 string concat 問題。
2. `_StringGutsSlice._fastNFCCheck` 佔兩個顯著位置（Dictionary subscript + Set.insert），對應 joined key 的重複 hash。
3. `Set.contains` 與 `Set.insert` 同時出現，對應 `dateTimeKnownTriggers` 檢查與 `AlternativeKeyArrayIterator` 的去重。
4. `getNodes` / `getEntryGroups` 仍在，但比例降低，說明原廠 Trie 查詢已非最大瓶頸。


## 十、First Principle 檢視：Typewriter → Homa → LMInstantiator 的架構設計問題

> 本章節轉移至 `Phase46_PreResearch_1stPrinciple.md`。
