# Phase 45 實作計畫：拼音免聲調長句組字卡頓第二輪根因修復

> 本文件為 Phase 45 的實作計畫，對應調查報告 `Phase45_PreResearch.md`。

## 目標

根據 `Phase45_PreResearch.md` 的調查報告，消除 `mergedAlternativeBucketUnigrams` 中殘餘的 Severe Hang（2.17 s）。預期將單次呼叫從數百毫秒降為數十毫秒，使 `assignNodes()` 總計 < 500 ms。

## 執行原則

**一次只執行一步**，順序為：B → D → A+C。
每一步獨立完成、獨立測試、獨立提交後，再進入下一步。

## 手術範圍

- `vChewing-macOS`（主倉庫）
- `vChewing-OSX-Legacy`（鏡像倉庫）
- `vChewing-LibVanguard`：本 phase 無需變更
- `vChewing-VanguardLexicon`：本 phase 無需變更

---

## Step B：`queryDateTimeUnigrams` 前置 O(1) 預篩選

### 問題

15,625 次 `TokenTrigger.init(rawValue:)` 呼叫，每次都做 string switch（`_findStringSwitchCaseWithCache`）。

### 解決方案

1. 在 `LMInstantiator_DateTimeExtension.swift` 中讓 `TokenTrigger` 採納 `CaseIterable`，並新增：
   ```swift
   static let knownTriggers: Set<String> = { Set(allCases.map(\.rawValue)) }()
   ```

2. 在 `queryDateTimeUnigrams` 第一行改為：
   ```swift
   guard TokenTrigger.knownTriggers.contains(key), let tokenTrigger = TokenTrigger(rawValue: key) else { return [] }
   ```

3. 在 `mergedAlternativeBucketUnigrams` 的迴圈中，呼叫 `queryDateTimeUnigrams` 前先以 `TokenTrigger.knownTriggers.contains(keyChain)` 過濾。

### 涉及檔案

- `vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator_DateTimeExtension.swift`
- `vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift`
- `vChewing-OSX-Legacy/Shared/vChewingComponents/LMAssembly/LMInstantiator_DateTimeExtension.swift`
- `vChewing-OSX-Legacy/Shared/vChewingComponents/LMAssembly/LMInstantiator.swift`

### 預期收益

無 trigger 時：15,625 次 string switch → 15,625 次 O(1) hash lookup。

---

## Step D：快取 `LMCoreEX` 的 `keySet`

### 問題

每次 `mergedAlternativeBucketUnigrams` 都從 `rangeMap.keys` 構建 `Set<String>`（數萬次 string hash）。

### 解決方案

1. 在 `LMCoreEX` 中新增 `var keySet: Set<String> = []`
2. 在 `replaceData(textData:)` 中於 `rangeMap = newMap` 後同步：`keySet = Set(rangeMap.keys)`
3. 在 `clear()` 中同步清空：`keySet.removeAll(keepingCapacity: false)`
4. 在 `hasUnigramsFor(key:)` 中改為 `keySet.contains(key) || temporaryMap[key] != nil`

### 涉及檔案

- `vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/SubLMs/lmCoreEX.swift`
- `vChewing-OSX-Legacy/Shared/vChewingComponents/LMAssembly/SubLMs/lmCoreEX.swift`

### 預期收益

`hasUnigramsFor(key:)` 和 `rangeMap.keys` → `Set` 的轉換成本降為零。

---

## Step AC：單次 Pass 消除 `Array(AnySequence)` + `[[String]]` key 改 `String` key

### 問題

`mergedAlternativeBucketUnigrams` 仍用 `Array(expandAlternativeKeyArrays(...))` 強制展開為 15,625 個 `[String]`；內部多個 Dictionary 以 `[String]` 為 key，造成逐元素 string hash。

### 解決方案

1. **移除 `Array(...)`**：直接 `for expandedKeyArray in expandAlternativeKeyArrays(...)`
2. **移除 `joinedKeyCache`**：單次 pass 中每個組合只處理一次，直接計算 `joined(separator: "-")`
3. **調整預篩選**：不再預建 `expandedKeyChains` Set，迴圈內直接以 `keyChain` 查 `hasUnigramsFor`
4. **`factoryCoreUnigramsByKeyArray`** 改為 `[String: [Homa.Gram]]`（以 joined key group）
5. **`topScoreByKeyArray`** 改為 `[String: Double]`
6. **`factoryLookupMemo`** / **`FactoryLookupMemoKey`** 改為以 joined `String` + column 為 key
7. **`deferredFilterByKeyArray`** 改為 `[String: Set<String>]`

### 涉及檔案

- `vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift`
- `vChewing-OSX-Legacy/Shared/vChewingComponents/LMAssembly/LMInstantiator.swift`

### 預期收益

從 O(M^N) 記憶體分配降為 O(1) 迭代器狀態；消除逐元素 string hash。

---

## 跨倉庫同步要求

每步變更須同步至 macOS 與 Legacy 倉庫。LibVanguard 本 phase 無對應檔案。

## 測試策略（每步後執行）

- `vChewing-macOS/Packages/vChewing_LangModelAssembly`：`swift test`
- `vChewing-macOS/Packages/vChewing_Typewriter`：`swift test`
- `vChewing-macOS/Packages/vChewing_Homa`：`swift test`
- `vChewing-macOS/Packages/vChewing_MainAssembly4Darwin`：`swift test`
- `vChewing-OSX-Legacy`：`make debug-core`
- 提交前：`make lint; make format`
