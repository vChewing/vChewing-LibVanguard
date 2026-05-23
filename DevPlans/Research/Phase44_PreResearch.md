# Phase 44 調查報告：拼音免聲調長句組字卡頓殘餘根因分析

> 調查日期：2026-04-24
> 研究範圍：`vChewing-macOS`（為主）、`vChewing-LibVanguard`
> 研究員：Kimi-K2.6
> 觸發條件：拼音模式、免聲調輸入、組字區超過六個字
> 文檔狀態：完成、可用於後續 Phase 的開工依據。

---

## 一、問題現象

Phase 38–43 已完成多輪最佳化（tone bucket 原廠辭典查詢下推至 Trie 層級、QueryBuffer 鎖輕量化、gramQueryCache 結構鍵化、alternatives 單輪 memo 等）。但從 `vChewing-macOS` `./tmp/TestResult_AfterPhase43.trace` 可見，拼音模式免聲調輸入長句時，Main Thread 仍有明顯 Severe Hang：

| 時間區段 | 持續時間 | 類型 |
|---------|---------|------|
| `00:10.293` – `00:12.962` | 2.67 s | Severe Hang |
| `00:24.126` – `00:26.828` | 2.70 s | Severe Hang |
| `00:28.428` – `00:42.552` | 14.12 s | Severe Hang |

Instruments CPU Profiler 顯示，HANG 區段內的熱點已從 Phase 37 的 `TextMapTrie.getNodes` + `PhonabetCipher` 轉移至 `LMInstantiator` 層級的 alternatives 展開與非原廠辭典迴路。

---

## 二、完整熱路徑 Call Chain（拼音免聲調模式，Phase 43 之後）

以單次 `unigramsFor(keyArray:)` 呼叫（含 `&` tone bucket）為例：

```
Homa.Assembler.assignNodes()
  ├── for each position × length:
  │     └── gramQuerier(keyArray)                        // [String] → [GramRAW]
  │           └── LMInstantiator.lookupHub.grams(for:)
  │                 └── LMInstantiator.unigramsFor(keyArray:)
  │                       ├── keyArray.joined().contains("&") → true
  │                       └── mergedAlternativeBucketUnigrams(for:)
  │                             ├── factoryChoppedUnigramsFor(keyArray:column:.theDataCHEW)      // 1 次
  │                             ├── factoryChoppedCoreUnigramsFor(keyArray:strategy:.configuredLookup) // 1 次
  │                             ├── factoryChoppedUnigramsFor(keyArray:column:.theDataCNS)       // 可選 1 次
  │                             │   // 以上原廠查詢已走 keysChopped，時間複雜度 O(1 per column)
  │                             │
  │                             ├── expandedKeyArrays = expandAlternativeKeyArrays(from: keyArray)
  │                             │   // 對 N 個 syllable、每個 M 個聲調變體，產生 M^N 組合
  │                             │
  │                             └── for each expandedKeyArray:   × M^N combinations
  │                                   ├── joinedKey(for:)   // cache lookup
  │                                   ├── lmUserSymbols.unigramsFor(key:keyChain:)   // hash lookup
  │                                   ├── memoizedFactoryUnigrams(keyArray:column:.theDataSYMB) // memo
  │                                   ├── lmUserPhrases.unigramsFor(...)             // hash lookup
  │                                   ├── queryDateTimeUnigrams(...)                 // TokenTrigger 檢查
  │                                   ├── lmPlainBopomofo.valuesFor(...)             // 倚天排序
  │                                   ├── lmFiltered.unigramsFor(...)                // hash lookup
  │                                   └── deferredFilterByKeyArray 累積             // Set 操作
  │
  │                             └── // 迴圈結束後：removeAll + consolidate()
  │
  └── Homa.Assembler.queryGrams(using:cache:)
        // gramQuerier 結果經 sortGramRAW + compactMap 去重後塞入 gramQueryCache

BPMFFullMatchTypewriter.composeReadingIfReady(...)
  └── handler.currentLM.hasUnigramsFor(keyArray: [readingKey])
        └── unigramsFor(keyArray:) → mergedAlternativeBucketUnigrams(for:)   // 完整重入！

BPMFFullMatchTypewriter.performPinyinAutoChopIfNeeded(...)
  └── choppedReadingKeys.allSatisfy { handler.currentLM.hasUnigramsFor(keyArray: [$0]) }
        └── 對每個 chop 結果呼叫 hasUnigramsFor → unigramsFor → mergedAlternativeBucketUnigrams
```

---

## 三、根因分析

經逐層拆解，Phase 43 之後拼音免聲調長句卡頓的**殘餘根因**如下，按影響程度排序：

---

### 根因 A：`hasUnigramsFor` 呼叫完整 `unigramsFor` 導致重入爆炸（HIGHEST IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) `hasUnigramsFor(keyArray:)`

**問題**：

```swift
public func hasUnigramsFor(keyArray: [String]) -> Bool {
  let keyChain = keyArray.joined(separator: "-")
  return keyChain == " " || (!unigramsFor(keyArray: keyArray).isEmpty && !keyChain.isEmpty)
}
```

`hasUnigramsFor` 為了「濾除表語義正確性」，選擇直接呼叫完整版 `unigramsFor(keyArray:)` 並檢查結果是否為空。當 `keyArray` 含 `&` tone bucket 時，這會**完整執行** `mergedAlternativeBucketUnigrams`，包括：

1. 原廠 `factoryChoppedUnigramsFor` × 3–4 次（雖已優化為 O(1) per column，但仍非零成本）
2. `expandAlternativeKeyArrays` 產生 M^N 組合
3. 對每個組合執行非原廠查詢（user phrases / symbols / filtered / dateTime / replacements）
4. InputToken 展開、deferred filter removal、`consolidate()`

`hasUnigramsFor` 在以下三處被高頻呼叫：

1. **Homa Assembler `gramAvailabilityChecker`**：每次 `insertKey()` 前檢查單鍵是否存在。對 tone bucket 單鍵，展開量為 M（通常 2–5）。
2. **`composeReadingIfReady`**：確認組字前檢查 `[readingKey]` 是否有辭典記錄。同樣觸發完整 `mergedAlternativeBucketUnigrams`。
3. **`performPinyinAutoChopIfNeeded`**：對每個 auto-chop 產生的 reading key 呼叫 `hasUnigramsFor`。長拼音輸入可能產生 6+ 個 chop 結果，每個都是 tone bucket。

**量化**：以 6 個 syllable 為例，`hasUnigramsFor([toneBucketKey])` 單次呼叫：
- `expandAlternativeKeyArrays` → 5 組合
- 非原廠查詢：5 × (user phrases + symbols + filtered + dateTime + replacements) ≈ 25 次 hash lookup + 字串處理
- `consolidate()` 對結果陣列去重

這只是單次 `hasUnigramsFor`。在 `assignNodes()` 的 21 次 `gramQuerier` 呼叫中，每次 `unigramsFor` 也會完整執行 `mergedAlternativeBucketUnigrams`。

**核心矛盾**：`hasUnigramsFor` 只需要知道「是否存在至少一筆結果」，但卻執行了完整的「取得全部結果、展開 InputToken、套用置換、濾除、去重」流程。這是 Phase 39–43 最佳化後仍存留的**最大演算法浪費**。

---

### 根因 B：`mergedAlternativeBucketUnigrams` 非原廠迴路仍隨組合數線性膨脹（HIGH IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) `mergedAlternativeBucketUnigrams(for:)`

**問題**：Phase 39 已將原廠辭典查詢從「每個組合逐一查詢」改為 `keysChopped` 一次性查詢（`factoryChoppedUnigramsFor` / `factoryChoppedCoreUnigramsFor`）。但**非原廠來源**仍留在 `for expandedKeyArray in expandedKeyArrays` 迴路內：

```swift
for expandedKeyArray in expandedKeyArrays {
  // ...
  rawAllUnigrams += lmUserSymbols.unigramsFor(key: keyChain, keyArray: expandedKeyArray)
  // ...
  var userPhraseUnigrams = Array(lmUserPhrases.unigramsFor(...).reversed())
  // ...
  rawAllUnigrams.append(contentsOf: queryDateTimeUnigrams(...))
  // ...
  let dataAsFilter = Set(lmFiltered.unigramsFor(...).map(\.current))
  // ...
}
```

以 6 個 syllable、每個 5 個聲調變體為例：
- `expandedKeyArrays.count` = 5⁶ = 15,625
- `lmUserPhrases.unigramsFor` × 15,625 = 15,625 次 hash lookup + `rangeMap` 查詢 + 可能的 `strData` 解析
- `lmUserSymbols.unigramsFor` × 15,625
- `lmFiltered.unigramsFor` × 15,625
- `queryDateTimeUnigrams` × 15,625（雖多數 early return，但函式呼叫開銷不可忽略）
- `lmPlainBopomofo.valuesFor` × 15,625
- `joinedKey(for:)` cache lookup × 15,625
- `deferredFilterByKeyArray` 累積 × 15,625

即使單次非原廠查詢僅耗時 ~1 µs，15,625 次累積仍達 15+ ms。加上 Swift Array append、String 分配、`consolidate()` 等，單次 `mergedAlternativeBucketUnigrams` 在 6-syllable 場景下仍可達 50–200 ms。

**關鍵洞察**：user phrases / symbols / filtered 的底層都是 `LMCoreEX`，其查詢介面為 `rangeMap[joinedKey]`。若能在 Trie 層級同時查詢多個 joined key，或改以「先查 user data 再與原廠結果合併」的策略，可避免 M^N 線性膨脹。

---

### 根因 C：`expandAlternativeKeyArrays` 全量展開且無 early exit（MEDIUM IMPACT）

**位置**：[LMInstantiator.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift) `expandAlternativeKeyArrays(from:)`

**問題**：

```swift
func expandAlternativeKeyArrays(from keyArray: [String]) -> [[String]] {
  // ...
  func visit(index: Int, current: [String]) {
    if index >= alternativeColumns.count {
      if dedup.insert(current).inserted {
        combinations.append(current)
      }
      return
    }
    for candidate in alternativeColumns[index] {
      var next = current
      next.append(candidate)
      visit(index: index + 1, current: next)
    }
  }
  visit(index: 0, current: [])
  return combinations
}
```

此函式對所有 alternatives 做**深度優先遞迴展開**，將結果全部塞入 `[[String]]` 後才返回。對於 `hasUnigramsFor` 這種只需要「是否存在任一結果」的場景，全量展開是純粹浪費。即使對於 `mergedAlternativeBucketUnigrams` 的完整查詢，也可在展開過程中發現「所有非原廠來源都無資料」時提前截斷。

**在 trace 中的體現**：Instruments 顯示 `specialized visit #1 (index:current:) in LMInstantiator.expandAlternativeKeyArrays(from:)` 以深遞迴形式出現多層，代表展開過程本身也在消耗 stack 與 heap。

---

### 根因 D：`gramAvailabilityChecker` 與 `gramQuerier` 雙重查詢（MEDIUM IMPACT）

**位置**：[InputHandler_CoreProtocol.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_Typewriter/Sources/Typewriter/InputHandler/InputHandler_CoreProtocol.swift) + [Homa_Assembler.swift](file:///Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_Homa/Sources/Homa/Homa_MainComponents/Homa_Assembler.swift)

**問題**：`InputHandler` 初始化時：

```swift
assembler.gramQuerier = { [weak self] keyArray in
  self?.currentLM.unigramsFor(keyArray: keyArray).map { ... }
}
assembler.gramAvailabilityChecker = { [weak self] keyArray in
  self?.currentLM.hasUnigramsFor(keyArray: keyArray) ?? false
}
```

在 `Homa.Assembler.insertKey()` 中，先呼叫 `gramAvailabilityChecker` 驗證 key 是否合法；隨後在 `assignNodes()` 中，對每個 position × length 又呼叫 `gramQuerier`。兩者最終都落入 `unigramsFor`（因 `hasUnigramsFor` 呼叫 `unigramsFor`）。

對於 tone bucket 長句，這意味著：**同一個 keyArray 會被完整查詢兩次**（一次 by `hasUnigramsFor`，一次 by `gramQuerier`），而 `Homa.Assembler` 的 `gramQueryCache` 僅能快取 `gramQuerier` 的結果，無法攔截 `gramAvailabilityChecker`。

---

## 四、根因交互效應

上述四個根因並非獨立，而是形成連鎖放大：

```
Root Cause A (hasUnigramsFor 重入完整 unigramsFor)
  → 每次 insertKey / composeReadingIfReady / autoChop 都觸發完整 mergedAlternativeBucketUnigrams
  → Root Cause B (非原廠迴路 M^N 膨脹) 被 gramAvailabilityChecker 與 gramQuerier 雙重觸發
  → Root Cause C (全量展開) 確保無論是否需要，都產生全部 M^N 組合
  → Root Cause D (雙重查詢) 讓一切開銷乘以 2
```

以 6-syllable 免聲調拼音句子為例：
- `insertKey` 呼叫 6 次 `gramAvailabilityChecker` → 6 次完整 `mergedAlternativeBucketUnigrams`
- `composeReadingIfReady` 呼叫 1 次 `hasUnigramsFor` → 又 1 次完整
- `assignNodes()` 的 21 次 `gramQuerier` 呼叫 → 21 次完整
- 每次 `mergedAlternativeBucketUnigrams` 非原廠迴路迭代 5^max_syllables_in_span 次
- 最長 span（6 syllables）= 15,625 次非原廠查詢

**這解釋了為何 Phase 43 之後仍有 2–14 秒的 Severe Hang**：原廠辭典查詢已被 `keysChopped` 收斂到 O(1)，但 `hasUnigramsFor` 與 `mergedAlternativeBucketUnigrams` 的非原廠迴路仍讓總工作量與 tone 組合數成正比。

---

## 五、解決方案建議

按優先順序排列：

---

### 方案 A：`hasUnigramsFor` 新增 tone bucket 快速拒絕路徑（HIGHEST PRIORITY）

**目標**：讓 `hasUnigramsFor` 不再呼叫完整 `unigramsFor`，尤其是 tone bucket 場景。

**現狀**：`hasUnigramsFor` 為了濾除表正確性，強行走 `unigramsFor → mergedAlternativeBucketUnigrams`。

**解決思路**：

1. **區分「fast availability」與「full query」**：
   - 對於 `gramAvailabilityChecker`（Homa `insertKey` 使用），只需要知道「原廠辭典 + user phrases + symbols」是否有任何匹配。
   - 濾除表、語彙置換、InputToken、dateTime 等**不應影響 availability 判定**——這些是「有資料後的後處理」，不是「有無資料的先決條件」。

2. **新增 `hasUnigramsForFast(keyArray:)`**：
   - 若 keyArray 不含 `&`，直接走現有邏輯（或維持 `!unigramsFor(...).isEmpty`）。
   - 若含 `&`：
     - 先呼叫 `factoryChoppedCoreUnigramsFor`（僅 Core column），若結果不空則直接回傳 `true`
     - 否則，對 `expandAlternativeKeyArrays` 的結果做**早期截斷**檢查：只要任一 expanded key 在 `lmUserPhrases.rangeMap` 或 `lmUserSymbols.rangeMap` 中存在，即回傳 `true`
     - 全部無命中才回傳 `false`

3. **修改 `gramAvailabilityChecker`**：改用 `hasUnigramsForFast`，而非 `hasUnigramsFor`。

4. **`composeReadingIfReady` 與 `performPinyinAutoChopIfNeeded`**：同樣改用 `hasUnigramsForFast`。

**預期收益**：將 `hasUnigramsFor` 的時間複雜度從 O(M^N + consolidate) 降為 O(1)（原廠命中時）或 O(M^N early-exit)（需要檢查 user data 時）。

**風險**：需確保 `hasUnigramsForFast` 的語義與 `hasUnigramsFor` 在「availability」層面等價。濾除表不影響 availability（濾除後仍視為「有資料」），語彙置換也不影響（置換前已有資料）。

**實作複雜度**：低。僅涉及 `LMInstantiator.swift` 新增方法 + `InputHandler_CoreProtocol` / `Typewriter_BPMFFullMatch` 切換呼叫點。

---

### 方案 B：`mergedAlternativeBucketUnigrams` 非原廠迴路批量查詢（HIGH PRIORITY）

**目標**：讓 user phrases / symbols / filtered 等非原廠查詢不再隨 tone 組合數線性膨脹。

**現狀**：非原廠查詢在 `for expandedKeyArray in expandedKeyArrays` 內逐筆執行。

**解決思路**：

1. **預篩選有資料的 expanded key**：
   - `LMCoreEX` 的 `rangeMap` 是 `[String: [Range]]`。可先將所有 expanded key 的 joined string 收集為 `Set<String>`。
   - 對 `lmUserPhrases.rangeMap.keys`、`lmUserSymbols.rangeMap.keys`、`lmFiltered.rangeMap.keys` 做 `Set.intersection`，找出「真正可能存在資料的」expanded keys。
   - 只有交集內的 key 才需要呼叫 `unigramsFor`。

2. **對於多數長句場景**：user phrases / symbols / filtered 的命中極低（user 不會為每種聲調變體都自建詞條）。`Set.intersection` 操作可將 15,625 次查詢降為 0–10 次。

3. **DateTime / PlainBPMF / Replacements 同樣可批量**：
   - `queryDateTimeUnigrams` 只對特定 trigger string（如 `@date`）有反應。可先檢查 `expandedKeyArrays` 中是否有任何 joined key 匹配 `TokenTrigger`，若無則整批跳過。
   - `lmPlainBopomofo.valuesFor` 可改為對唯一 joined key set 批量查詢後快取。

**預期收益**：非原廠迴路從 O(M^N) 降為 O(1)（無 user data 命中時）或 O(K)（K = 實際有資料的 key 數，通常 < 10）。

**實作複雜度**：中等。需改寫 `mergedAlternativeBucketUnigrams` 的迴路結構，但底層 `LMCoreEX` 介面不變。

---

### 方案 C：`expandAlternativeKeyArrays` 改為惰性生成器（MEDIUM PRIORITY）

**目標**：避免全量展開所有 tone 組合。

**解決思路**：

1. 將 `expandAlternativeKeyArrays` 從「回傳 `[[String]]`」改為「回傳 `AnySequence<[String]>` 或自訂 `IteratorProtocol`」。
2. 在 `hasUnigramsForFast` 中，使用 `for expandedKeyArray in expandAlternativeKeyArrays(from: keyArray)` 並在首次命中時 `return true`。
3. 在 `mergedAlternativeBucketUnigrams` 中，若方案 B 的批量查詢已實作，則仍可使用全量展開（但此時展開對象僅為「預篩選後的少量 key」）；若方案 B 未實作，惰性生成器至少可減少 peak memory。

**預期收益**：降低 peak heap 使用量（避免 15,625 個 `[String]` 同時常駐），並讓 early-exit 場景真正節省展開成本。

**實作複雜度**：低。Swift `Sequence` / `IteratorProtocol` 實作簡單。

---

### 方案 D：Homa Assembler `gramAvailabilityChecker` 與 `gramQuerier` 結果共用（LOW-MEDIUM PRIORITY）✅ 已實作

**目標**：消除 Root Cause D 的雙重查詢。

**調查發現**：`Homa.Assembler.insertKeys()` 實際上已使用 `queryGrams(using: [key], cache: &warmupQueryBuffer)` 來檢查單鍵可用性，**並未呼叫外部傳入的 `gramAvailabilityChecker`**。因此 Root Cause D 的「雙重查詢」在當前程式碼中實際上並不存在——`gramAvailabilityChecker` 是一個未被使用的死程式碼屬性。

**實作內容**：

1. **從 `Homa.Assembler` 移除 `gramAvailabilityChecker`**：
   - 移除 `init` 與 `init(from:)` 中的 `gramAvailabilityChecker` 參數與複製邏輯。
   - 移除 `public var gramAvailabilityChecker: Homa.GramAvailabilityChecker` 屬性。
   - 更新 `insertKeys` 的防呆註解，移除對 `gramAvailabilityChecker()` 的提及。
2. **移除 `Homa.GramAvailabilityChecker` 型別別名**：該型別已無任何使用者。
3. **清理所有下游初始化與賦值點**：
   - `vChewing-macOS` / `vChewing-OSX-Legacy` 的 `InputHandler.swift`
   - `MockedInputHandlerAndStates.swift`
   - 所有單元測試中的 `Assembler(gramAvailabilityChecker: ...)` 與 `assembler.gramAvailabilityChecker = ...`
   - `TrieJoinedTests.swift` 的 `makeFactoryGramAvailabilityChecker`
   - `_HomaTestShim.swift` 的 `asGramAvailabilityChecker`

**預期收益**：消除未使用屬性與型別別名，簡化 `Assembler` 的公共介面，避免未來開發者誤以為該屬性仍在運作。

**實作複雜度**：低。屬於死程式碼清理，無行為變更。

---

## 六、優先順序與建議執行順序

| 順序 | 方案 | 預期收益 | 實作複雜度 |
|------|------|---------|-----------|
| 1 | A: `hasUnigramsFor` fast path | 消除 `hasUnigramsFor` 造成的完整重入，降低 60–80% 總 CPU | 低 |
| 2 | B: 非原廠迴路批量查詢 | 將 M^N 非原廠查詢降為 O(1)–O(K) | 中等 |
| 3 | C: 惰性展開 | 降低 memory pressure，強化 early-exit | 低 |
| 4 | D: availability / query 共用 | 消除 double query | 中低 |

**建議**：方案 A 是決定性因素——`hasUnigramsFor` 每次重入完整 `unigramsFor` 是 Phase 43 後最大的殘餘浪費。只要將 `gramAvailabilityChecker`、`composeReadingIfReady`、`autoChop` 的 availability 檢查改走 fast path，即使方案 B 未實作，6-syllable 場景的 HANG 也應從數秒降為數百毫秒。

方案 B 則負責收斂 `gramQuerier` 路徑的 `mergedAlternativeBucketUnigrams` 殘餘成本，讓長句組句進入毫秒級。

---

## 七、方案 A+B 落地後的預期效能模型

假設方案 A 與 B 落地，6-syllable 免聲調拼音長句的效能模型變為：

- **`insertKey` 階段**：
  - `gramAvailabilityChecker` 改走 `hasUnigramsForFast`
  - 原廠命中：O(1) per key
  - user data 檢查：early-exit，平均 O(1) per key
  - 6 個 key 總計 < 1 ms

- **`composeReadingIfReady` / `autoChop`**：
  - `hasUnigramsForFast` 取代 `hasUnigramsFor`
  - 單次 < 1 ms

- **`assignNodes()` 階段**：
  - 21 次 `gramQuerier` 呼叫
  - `mergedAlternativeBucketUnigrams` 原廠部分：O(1) per call（已如此）
  - `mergedAlternativeBucketUnigrams` 非原廠部分：
    - 批量預篩選後，多數 span 的 user data 查詢次數為 0
    - 最長 span（6 syllables）的組合數雖仍為 15,625，但實際需要查詢的 key 數為 0–10
  - 單次 `assignNodes()` 預計 < 50 ms

- **總結**：從 Severe Hang（2–14 秒）降為 Microhang（< 100 ms）或完全消除。

---

## 八、跨倉庫影響評估

| 倉庫 | 影響 |
|------|------|
| `vChewing-LibVanguard` | 方案 C（惰性展開）與方案 D（Homa cache）需在此實作、且同步至下游；方案 A/B 在下游 `LMInstantiator` 層 |
| `vChewing-macOS` | 方案 A/B 的主要改動位置（`LMInstantiator.swift` + `InputHandler_CoreProtocol` / `Typewriter_BPMFFullMatch`） |
| `vChewing-OSX-Legacy` | 需同步移植 `LMInstantiator` 與 Typewriter 改動 |
| `vChewing-VanguardLexicon` | 不受影響（格式與資產無需變更） |

---

## 九、附錄：Trace 中的熱點統計（HANG 區段內）

從 `TestResult_AfterPhase43_cpu.xml` 的 Severe Hang 區段（`00:10.293–00:12.962`、`00:24.126–00:26.828`、`00:28.428–00:42.552`）提取的前 20 個 vChewing 相關 call chain（leaf-first）：

| 出現次數 | Call Chain（前 6 層） |
|---------|----------------------|
| 93 | `factoryTrie.getter` ← `memoizedFactoryUnigrams` ← `mergedAlternativeBucketUnigrams` ← `unigramsFor` ← `LookupHub.grams` ← `queryGrams` |
| 76 | `factoryChoppedUnigramsFor` ← `mergedAlternativeBucketUnigrams` ← `unigramsFor` ← `hasUnigramsFor` ← `composeReadingIfReady` ← `handle` |
| 67 | `factoryChoppedUnigramsFor` ← `factoryChoppedCoreUnigramsFor` ← `unigramsFor` ← `hasUnigramsFor` ← `composeReadingIfReady` ← `handle` |
| 58 | `outlined init with copy of LMCoreEX` ← `mergedAlternativeBucketUnigrams` ← `unigramsFor` ← `LookupHub.grams` ← `queryGrams` ← `assignNodes` |
| 40 | `outlined destroy of LMCoreEX` ← `mergedAlternativeBucketUnigrams` ← `unigramsFor` ← `LookupHub.grams` ← `queryGrams` ← `assignNodes` |
| 33 | `visit #1 in expandAlternativeKeyArrays`（多層遞迴） |
| 29 | `makeFactoryUnigrams` ← `memoizedFactoryUnigrams` ← `mergedAlternativeBucketUnigrams` ← `unigramsFor` ← `LookupHub.grams` ← `queryGrams` |
| 24 | `closure #2 in LMCoreEX.unigramsFor` ← `mergedAlternativeBucketUnigrams` ← `unigramsFor` ← `LookupHub.grams` ← `queryGrams` ← `assignNodes` |
| 21 | `factoryChoppedUnigramsFor` ← `mergedAlternativeBucketUnigrams` ← `unigramsFor` ← `hasUnigramsFor` ← `performPinyinAutoChopIfNeeded` ← `consumeReadingInputIfNeeded` |
| 17 | `mergedAlternativeBucketUnigrams` 自我呼叫（遞迴/重入） |

統計印證：
1. `hasUnigramsFor` → `unigramsFor` → `mergedAlternativeBucketUnigrams` 佔據顯著比例（`composeReadingIfReady` + `autoChop`）。
2. `mergedAlternativeBucketUnigrams` 的非原廠部分（`LMCoreEX` init/destroy / `unigramsFor` closure）仍在熱路徑上。
3. `expandAlternativeKeyArrays` 的遞迴展開自身也成為熱點。
