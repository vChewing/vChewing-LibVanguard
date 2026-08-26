# Phase 46 手術計畫：移除 `&` 字串編碼（Omega-1）+ 希臘字母後續任務

---

## 執行摘要

**根本原因**：`Typewriter_BPMFFullMatch.swift` 第 139 行將五種聲調變體編碼成單一 `&` 分隔字串（`toneVariants.joined(separator: "&")`）。這種字串編碼的歧義性迫使 Homa 必須原字儲存、LMInstantiator 必須解析並展開，進而衍生出 `mergedAlternativeBucketUnigrams` 這個下游補丁。

**Omega-1（根治）**：引入 `Homa.PossibleKey` 枚舉（`.singleKey(String)` / `.multipleKeys([String])`）取代 `[String]` 索引鍵。每個位置以結構化枚舉儲存其替代讀音。Typewriter 傳遞陣列。Homa 在呼叫 `gramQuerier` 前透過 `allValues` 於內部執行笛卡爾積展開。

> **設計演進備註**：原始計畫將 `keys` 由 `[String]` 改為 `[[String]]`。實作過程中精煉為 `[PossibleKey]`，以避免嵌套陣列的語意歧義（單一鍵與僅有一個替代項的鍵外觀同為 `[String]`）。`PossibleKey` 使意圖明確，並提供便利屬性（`allValues`、`first`、`isValid`、`description`）。

**Omega-1 後的實際狀態**：
- Homa 內部已完全不再使用 `&` 字串。`keys` 為 `[PossibleKey]`，`assignNodes` 透過 `allValues` 做笛卡爾積展開。
- **O-14 / O-16 已落實**：`mergedAlternativeBucketUnigrams`、`expandAlternativeKeyArrays`、`AlternativeKeyArrayIterator` 已從 `LMInstantiator.swift` 徹底移除。`unigramsFor` 不再處理 `&`，僅接收並快取精確的 `keyArray`。原有的 5 個 tone-bucket 迴歸測試已從 `LMInstantiator_TextMapTests.swift` 移除，改由 Homa 層的 `testMultipleKeysCartesianProductMergesResults` 覆蓋 `multipleKeys` 的笛卡爾積合併行為。
- **LRU cache 已實作**：`unigramsFor` 對精確 keyArray 啟用 LRU 快取（上限 1024），以 `config.hashValue` 作為 fingerprint 確保 config 變更時快取失效。

**希臘字母任務狀態**：
- ✅ **Alpha**：`queryGramsForAlternatives` 移除冗餘 `insertedIntel` Set（`queryGrams` 內部已透過 `makeGramIdentityHash` 去重），並加入無替代讀音時的快速路徑（不執行笛卡爾積）。
- ✅ **Zeta**：`queryGramsForAlternatives` 的無替代讀音快速路徑即為 Zeta 的實現；existence pre-check 在 `assignNodes` 層面已由空結果自然短路（`guard !queriedGrams.isEmpty else { return }`）。
- ✅ **Beta**：`unigramsFor` LRU cache 已完成（vChewing-macOS、vChewing-OSX-Legacy）。LibVanguard 無 LMInstantiator，無需實施。
- ❌ **Eta**：**已放棄**。原設計的 `effectiveMaxSegLength`（高聲調密度時縮減 `maxSegLength`）會影響未來「搜狗 style 不完全拼寫」的實作（該功能不只是聲調可省略，還涉及更複雜的動態長度調整）。保留原始 `maxSegLength` 行為。
- ⏸️ **Gamma、Delta、Epsilon、Theta**：暫緩。僅當 profiling 顯示仍有需要時才執行。

**Omega-2**：僅作備忘。除非所有希臘字母任務完成後仍有效能問題，否則不實施。

---

## 第一部分：Omega-1 — 根治（Homa `keys: [PossibleKey]`）

### 1.1 設計原則

1. **`GramQuerier` 契約維持不變**：`([String]) -> [GramRAW]`。LMInstantiator 永遠接收精確的索引鍵陣列。
2. **Homa 負責展開**：`assignNodes` 計算每個幅節替代讀音的笛卡爾積，並透過 `gramQuerier` 查詢每種組合。結果合併為單一 Node。
3. **向下相容**：`insertKey(_ key: String)` 保留為便利過載，包裝為 `[.singleKey(key)]`。
4. **Typewriter 停止產生 `&` 字串**：`makeToneInsensitivePinyinQueryKey` 回傳 `[String]`。

### 1.2 逐步實施

#### 步驟 O-1：Homa — 引入 `PossibleKey` 枚舉並將 `Config.keys` 改為 `[PossibleKey]`

**新增檔案**：`vChewing_Homa/Sources/Homa/Homa_BasicTypes/Homa_PossibleKey.swift`

```swift
public enum PossibleKey: Hashable, Sendable {
  case singleKey(String)
  case multipleKeys([String])

  public var isValid: Bool {
    switch self {
    case .singleKey(let key): return !key.isEmpty
    case .multipleKeys(let keys): return !keys.isEmpty
    }
  }

  public var allValues: [String] {
    switch self {
    case .singleKey(let key): return [key]
    case .multipleKeys(let keys): return keys
    }
  }

  public var first: String {
    switch self {
    case .singleKey(let key): return key
    case .multipleKeys(let keys): return keys.first ?? Self.pokayokeChar
    }
  }

  public var description: String { allValues.joined(separator: "&") }

  private static let pokayokeChar = "🛇"
}

extension Homa.PossibleKey: Codable {
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .singleKey(let key): try container.encode(key)
    case .multipleKeys(let keys): try container.encode(keys)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let key = try? container.decode(String.self) {
      self = .singleKey(key)
    } else {
      self = .multipleKeys(try container.decode([String].self))
    }
  }
}
```

**檔案**：`vChewing_Homa/Sources/Homa/Homa_BasicTypes/Homa_Config.swift`

- `public var keys = [String]()` → `public var keys = [PossibleKey]()`
- `public init(keys: [String] = [])` → `public init(keys: [PossibleKey] = [])`
- `length` 維持 `keys.count`
- `Codable` 透過 `PossibleKey.Codable` 自動達成

#### 步驟 O-2：Homa — 更新 `Assembler.keys` 計算屬性

**檔案**：`vChewing_Homa/Sources/Homa/Homa_MainComponents/Homa_Assembler.swift`

- `public private(set) var keys: [String]` → `public private(set) var keys: [PossibleKey]`
- `actualKeys` 目前的 `config.assembledSentence.keyArrays.flatMap(\.self)` — 無需更動。

#### 步驟 O-3：Homa — 更新 `insertKey` / `insertKeys` 簽名並新增向下相容過載

**檔案**：`vChewing_Homa/Sources/Homa/Homa_MainComponents/Homa_Assembler.swift`

```swift
// 主要 API
public func insertKeys(_ givenKeys: [PossibleKey]) throws {
    guard !givenKeys.isEmpty, givenKeys.allSatisfy(\.isValid) else {
        throw Homa.Exception.givenKeyIsEmpty
    }
    let gridBackup = segments
    var keyExistenceChecked = [GramQueryCacheKey: Bool]()
    var warmupQueryBuffer = [GramQueryCacheKey: [Homa.Gram]]()
    for (cursorAdvancedPosition, key) in givenKeys.enumerated() {
        let cacheKey = GramQueryCacheKey(key.allValues)
        if !(keyExistenceChecked[cacheKey] ?? false) {
            let hasAnyResult = key.allValues.contains { alt in
                !queryGrams(using: [alt], cache: &warmupQueryBuffer).isEmpty
            }
            guard hasAnyResult else {
                throw Homa.Exception.givenKeyHasNoResults
            }
            keyExistenceChecked[cacheKey] = true
        }
        keys.insert(key, at: cursor + cursorAdvancedPosition)
        resizeGrid(at: cursor + cursorAdvancedPosition, do: .expand)
    }
    do {
        try assignNodes()
    } catch {
        segments = gridBackup
        throw error
    }
    cursor += givenKeys.count
}

// 向下相容過載，橋接至 [PossibleKey]
public func insertKey(_ key: String) throws {
    try insertKeys([.singleKey(key)])
}

public func insertKey(_ key: [String]) throws {
    try insertKeys(key.count <= 1 ? [.singleKey(key.first ?? "")] : [.multipleKeys(key)])
}

public func insertKeys(_ givenKeys: [[String]]) throws {
    try insertKeys(givenKeys.map { $0.count <= 1 ? .singleKey($0.first ?? "") : .multipleKeys($0) })
}
```

**關鍵變更**：存在性檢查改為遍歷 `allValues`，不再傳遞 `&` 連接字串。

#### 步驟 O-4：Homa — 更新 `assignNodes` 以處理 `[PossibleKey]` 索引鍵

**檔案**：`vChewing_Homa/Sources/Homa/Homa_MainComponents/Homa_Assembler.swift`

幅節索引鍵陣列的建構方式為關鍵變更：

```swift
// 之前：
let keyArraySliced = keys[position ..< (position + theLength)].map(\.description)
let queriedGrams = queryGrams(using: keyArraySliced, cache: &queryBuffer)

// 之後：
let alternativesSlice = keys[position ..< (position + theLength)]  // [PossibleKey]
let queriedGrams = queryGramsForAlternatives(alternativesSlice, cache: &queryBuffer)
```

`queryGramsForAlternatives` 計算 `allValues` 的笛卡爾積、查詢每種組合、並排序合併結果：

```swift
private func queryGramsForAlternatives(
  _ alternativesSlice: ArraySlice<PossibleKey>,
  cache: inout [GramQueryCacheKey: [Homa.Gram]]
) -> [Homa.Gram] {
  // Alpha/Zeta: 無替代讀音時直接查詢，無需笛卡爾積展開
  if alternativesSlice.allSatisfy({ if case .singleKey = $0 { return true } else { return false } }) {
    let keyArray = alternativesSlice.map(\.first)
    return queryGrams(using: keyArray, cache: &cache)
  }
  let combinations = Self.cartesianProduct(alternativesSlice.map(\.allValues))
  var mergedGrams: [Homa.Gram] = []
  mergedGrams.reserveCapacity(combinations.count * 4)
  for combination in combinations {
    let grams = queryGrams(using: combination, cache: &cache)
    mergedGrams.append(contentsOf: grams)
  }
  // 關鍵修正：合併結果必須排序以確保 DP 選字正確性
  return mergedGrams.sorted {
    if $0.keyArray.count != $1.keyArray.count {
      return $0.keyArray.count > $1.keyArray.count
    }
    if $0.probability != $1.probability {
      return $0.probability > $1.probability
    }
    if $0.keyArray != $1.keyArray {
      return $0.keyArray.lexicographicallyPrecedes($1.keyArray)
    }
    return ($0.previous ?? "") < ($1.previous ?? "")
  }
}
```

**關鍵修正**：按 `keyArray.count` 降冪再 `probability` 降冪的顯式排序為必要。缺少此排序時，工廠 unigram 可能在合併結果中壓過使用者臨時詞組，導致 `test_IH117` 迴歸。

**Alpha 說明**：移除 `insertedIntel` Set。`queryGrams` 內部已透過 `makeGramIdentityHash` 去重，跨組合再 dedup 是冗餘開銷。

笛卡爾積輔助函式：

```swift
private static func cartesianProduct<T>(_ arrays: [[T]]) -> [[T]] {
    guard !arrays.isEmpty else { return [[]] }
    guard !arrays.contains(where: \.isEmpty) else { return [] }
    var result: [[T]] = [[]]
    for array in arrays {
        var newResult: [[T]] = []
        newResult.reserveCapacity(result.count * array.count)
        for prefix in result {
            for element in array {
                newResult.append(prefix + [element])
            }
        }
        result = newResult
    }
    return result
}
```

#### 步驟 O-5：Homa — 更新 `dropKey` 及其他 `keys` 變異點

**檔案**：`vChewing_Homa/Sources/Homa/Homa_MainComponents/Homa_Assembler.swift`

- `dropKey` 執行 `keys.remove(at: cursor - (isBackSpace ? 1 : 0))` — 此操作對 `[PossibleKey]` 仍有效，因 `remove(at:)` 適用於任何 Array。
- 其他直接 `keys` 變異點經檢查後確認：`keys` 僅於 `insertKeys` 與 `dropKey` 中變異。

#### 步驟 O-6：Homa — 更新 `dumpDOT` 及 `keys` 讀取點

**檔案**：`vChewing_Homa/Sources/Homa/Homa_MainComponents/Homa_Assembler.swift`

- `dumpDOT` 透過 `segments` 索引隱式使用 `keys.count` — 無需更動。
- `isEmpty` 檢查 `segments.isEmpty && keys.isEmpty` — 無需更動。
- `length` 回傳 `config.length` 即 `keys.count` — 無需更動。

#### 步驟 O-7：Homa — 檢查使用 `[String]` 的 `insertKeys` 測試

**檔案**：`HomaTests_*.swift`

測試呼叫 `assembler.insertKeys(["a", "b", "c"])` 及 `assembler.insertKeys(["hello", "world", "test"])`。

透過向下相容過載 `insertKeys(_ givenKeys: [[String]])`，這些呼叫會自動橋接至 `[PossibleKey]`。`insertKeys` 無需更動測試。

然而，任何直接檢視 `assembler.keys` 或 `config.keys` 的測試必須更新為使用 `PossibleKey` API（例如以 `keys.map(\.first)` 取代視為 `[String]` 的 `keys`）。

#### 步驟 O-8：Typewriter — 將 `makeToneInsensitivePinyinQueryKey` 改為回傳 `[String]`

**檔案**：`vChewing_Typewriter/Sources/Typewriter/Typewriter/Typewriter_BPMFFullMatch.swift`

```swift
// 之前：
private func makeToneInsensitivePinyinQueryKey(from readingKey: String) -> String {
    var toneVariants = [String]()
    Tekkon.allowedIntonations.forEach { tone in
        let intonationNow = (tone != " ") ? String(tone) : ""
        let candidate = "\(readingKey)\(intonationNow)"
        if !toneVariants.contains(candidate) { toneVariants.append(candidate) }
    }
    return toneVariants.joined(separator: "&")
}

// 之後：
private func makeToneInsensitivePinyinQueryKey(from readingKey: String) -> [String] {
    var toneVariants = [String]()
    Tekkon.allowedIntonations.forEach { tone in
        let intonationNow = (tone != " ") ? String(tone) : ""
        let candidate = "\(readingKey)\(intonationNow)"
        if !toneVariants.contains(candidate) { toneVariants.append(candidate) }
    }
    return toneVariants
}
```

#### 步驟 O-9：Typewriter — 更新 `readingKeyForQuery` 回傳型別

**檔案**：`vChewing_Typewriter/Sources/Typewriter/Typewriter/Typewriter_BPMFFullMatch.swift`

```swift
// 之前：
private func readingKeyForQuery(...) -> String? { ... }

// 之後：
private func readingKeyForQuery(...) -> [String]? { ... }
```

主體邏輯不變，僅回傳型別改變。當 `shouldUseToneInsensitivePinyinLookup` 為 false 時，回傳 `[readingKey]` 取代 `readingKey`。

#### 步驟 O-10：Typewriter — 更新 `insertKey` 前的存在性檢查

**檔案**：`vChewing_Typewriter/Sources/Typewriter/Typewriter/Typewriter_BPMFFullMatch.swift`

```swift
// 之前：
if !handler.currentLM.hasUnigramsForFast(keyArray: [readingKey]) { ... }

// 之後：
let hasAnyResult = readingKey.contains { alt in
    handler.currentLM.hasUnigramsForFast(keyArray: [alt])
}
if !hasAnyResult { ... }
```

#### 步驟 O-11：Typewriter — 更新拼音自動切割存在性檢查

**檔案**：`vChewing_Typewriter/Sources/Typewriter/Typewriter/Typewriter_BPMFFullMatch.swift`

```swift
// 之前：
guard choppedReadingKeys.allSatisfy({ handler.currentLM.hasUnigramsForFast(keyArray: [$0]) }) else { ... }

// 之後：
guard choppedReadingKeys.allSatisfy({ key in
    key.contains(where: { handler.currentLM.hasUnigramsForFast(keyArray: [$0]) })
}) else { ... }
```

#### 步驟 O-12：Typewriter — 更新 `insertKey` 呼叫點

**檔案**：`vChewing_Typewriter/Sources/Typewriter/Typewriter/Typewriter_BPMFFullMatch.swift`

`insertKey(readingKey)` 呼叫維持不變，因為 `readingKey` 現為 `[String]`，而 `insertKey` 已有接受 `[String]` 的過載。

其他傳遞 `String` 的呼叫點（自訂標點、空格等）由 `insertKey(_ key: String)` 過載處理。

#### 步驟 O-13：Typewriter — 檢查其他 Typewriter 變體

**檔案**：`Typewriter_Cassette.swift`、`InputHandler_*.swift`

- 磁帶 typewriter：`assembler.insertKey(handler.calligrapher)` — `calligrapher` 為 `String`，使用 `String` 過載。
- InputHandler：`assembler.insertKey(customPunctuation)`、`assembler.insertKey("_punctuation_list")`、`assembler.insertKey(" ")` — 皆為 `String`，使用 `String` 過載。
- 獨立聲調：`assembler.insertKey(existedIntonation.value)` — `value` 為 `String`，使用 `String` 過載。

無需更動。

#### 步驟 O-14：LMInstantiator — 自 `unigramsFor` 移除 `&` 偵測 ✅

**檔案**：`vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift`

已刪除：
```swift
if keyArray.joined().contains("&") {
    return mergedAlternativeBucketUnigrams(for: keyArray)
}
```

`unigramsFor` 現僅走精確 keyArray 路徑（LRU cache → 正常查詢）。任何包含 `&` 的 keyArray 會被 TrieKit 視為字面量讀音鍵處理（通常無結果），而非展開為多個替代項。

#### 步驟 O-15：LMInstantiator — 自 `hasUnigramsForFast` 移除 `&` 偵測

**檔案**：`vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift`

已完成。移除 `containsAlternatives` 變數並收攏兩個分支。

#### 步驟 O-16：LMInstantiator — 刪除 `mergedAlternativeBucketUnigrams` 及其輔助函式 ✅

**檔案**：`vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift`

已刪除：
- `mergedAlternativeBucketUnigrams(for:)`
- `expandAlternativeKeyArrays(from:)`
- `AlternativeKeyArrayIterator`

這些方法原為 LMInstantiator 層處理 `&` 展開的補丁。Omega-1 後，展開責任已上移至 Homa，`LMInstantiator` 不再需要承擔此職責。

#### 步驟 O-17：LMInstantiator — 檢查 `factoryChopped*` 函式

**檔案**：`vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator_TextMapExtension.swift`

`factoryChoppedCoreUnigramsFor` 與 `factoryChoppedUnigramsFor` 仍由 `hasUnigramsForFast`（步驟 O-15）呼叫。予以保留。

#### 步驟 O-18：LMInstantiator — 檢查 `hasUnigramsFor`

**檔案**：`vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift`

`hasUnigramsFor` 委託給 `unigramsFor`，後者已不再具有 `&` 處理（正常路徑）。無需更動。

#### 步驟 O-19：LMInstantiator — 檢查 `LookupHub`

**檔案**：`vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift`

`LookupHub.grams(for:)` 與 `hasGrams(for:)` 簽名維持 `([String]) -> ...`，因為 Homa 現傳遞精確陣列。無需更動。

#### 步驟 O-20：測試 — 更新 Homa 測試

**檔案**：`HomaTests_*.swift`

- `HomaTests_NodeOverrideStatus.swift`：`insertKeys(["a", "b", "c"])` → `insertKeys([["a"], ["b"], ["c"]])`
- `HomaTests_Advanced.swift`、`HomaTests_Basic.swift`：搜尋所有 `insertKey` 與 `insertKeys` 呼叫並更新。

#### 步驟 O-21：測試 — 更新 LMInstantiator 測試

**檔案**：`LMInstantiator_TextMapTests.swift`

**實際狀態**：已移除。`unigramsFor` 不再處理 `&` fallback，原有 5 個 tone-bucket 迴歸測試已從 `LMInstantiator_TextMapTests.swift` 移除。改由 Homa 層的 `testMultipleKeysCartesianProductMergesResults` 覆蓋 `multipleKeys` 的笛卡爾積合併行為。

#### 步驟 O-22：建置與測試

```bash
cd /Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_Homa && swift test
cd /Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_Typewriter && swift test
cd /Users/shikisuen/Repos/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly && swift test
```

接著建置主應用程式：
```bash
cd /Users/shikisuen/Repos/!vChewing/vChewing-macOS && swift build
```

### 1.3 風險評估

| 風險 | 等級 | 緩解措施 |
|------|------|----------|
| Homa `keys: [PossibleKey]` 破壞 Codable 序列化 | 低 | `PossibleKey` 實作 `Codable`。無需自訂序列化程式碼。 |
| Homa 內的笛卡爾積導致類似效能問題 | 低 | Alpha/Zeta 已加入快速路徑與排序修正。實際測試通過且效能可接受。 |
| Typewriter 存在性檢查現呼叫 `hasUnigramsForFast` N 次 | 低 | N = 聲調變體數（≤5）。可忽略開銷。 |
| 工廠 Trie `keysChopped:` 失去 `&` 最佳化 | 低 | `factoryChopped*` 函式於無 `&` 時 early-return 至正常路徑。無效能衰退。 |
| 跨套件破壞性變更 | 低 | 所有變更已於三倉庫同步並 squash，測試全數通過。 |

---

## 第二部分：希臘字母任務（Omega-1 後逐一實施）

### Alpha：條件式去重 + 無替代讀音快速路徑 ✅ (Wave 1)

**狀態**：已完成（commit `ff66f0e5c` / `7c53c36` / `2931d7b`）。

**內容**：於 `queryGramsForAlternatives` 中：
1. 移除 `insertedIntel` Set（`queryGrams` 內部已透過 `makeGramIdentityHash` 去重，跨組合再 dedup 冗餘）。
2. 加入無替代讀音時的快速路徑：若 `alternativesSlice.allSatisfy({ .singleKey })`，直接 `queryGrams(using: alternativesSlice.map(\.first))`，不執行笛卡爾積。

### Beta：`unigramsFor` 的 LRU 快取 ✅ (Wave 1)

**狀態**：已完成（commit `3bf306a57` / `002f05e`）。LibVanguard 無 LMInstantiator，無需實施。

**內容**：
- `unigramsFor` 對不含 `&` 的精確 keyArray 啟用 `[String: [Homa.Gram]]` LRU 快取。
- 快取上限 1024，超過時移除最舊 50% 條目。
- `computeConfigFingerprint()` 包含所有影響結果的 config 屬性（含 `numPadFWHWStatus`、`deltaOfCalendarYears`），確保 config 變更時快取自動失效。
- `&` fallback 已於 O-14/O-16 移除，所有 keyArray 均走統一精確路徑並受 LRU cache 保護。

### Zeta：Homa `assignNodes` 中的存在性預檢 ✅ (Wave 1)

**狀態**：已由 `queryGramsForAlternatives` 的無替代讀音快速路徑覆蓋大部分效益。`assignNodes` 層面已有空結果自然短路（`guard !queriedGrams.isEmpty else { return }`）。視為已完成。

### Eta：動態 `maxSegLength` 縮減 ❌ 已放棄 // ABANDONED

**狀態**：**已放棄**，未進入任何 commit。

**原因**：原設計的 `effectiveMaxSegLength`（高聲調密度時將 `maxSegLength` 縮減至 8）會影響未來「搜狗 style 不完全拼寫」的實作。該功能不只是聲調可省略，還涉及更複雜的動態長度調整與 partial match 行為。保留原始固定 `maxSegLength` 以避免限制未來設計空間。

### Gamma：批次查詢 API ⏸️

**狀態**：暫緩。

**內容**：於單次 `assignNodes` 遍歷中批次多個 `gramQuerier` 呼叫，減少函式呼叫開銷。

**觸發條件**：Profiling 顯示函式呼叫開銷顯著，且 LookupHub / TrieKit 層已實現真正的 `grams(forMany:)` 批次查詢。

### Delta：`LMCoreEX` 支援 `keysChopped` ⏸️

**狀態**：暫緩。

**內容**：賦予 `LMCoreEX`（使用者資料）`keysChopped:` 風格查詢 API，使 Homa 能一次查詢所有聲調替代項，無需逐一遍歷組合。

**觸發條件**：Profiling 顯示使用者資料雜湊查詢占主導。

### Epsilon：`LookupHub.grams` 中的 Bigram 上下文 ⏸️

**狀態**：暫緩。

**內容**：變更 `GramQuerier` 以傳遞 `previous: String?` 上下文，使 Homa 的 `Node.getScore` 能使用 bigram 機率。

**觸發條件**：長句準確度問題，而非效能。

### Theta：延遲 InputToken/DateTime/Cassette 展開 ⏸️

**狀態**：暫緩。

**內容**：將合成元圖生成（DateTime、InputToken、Cassette）由每幅節查詢移至候選字生成時機。

**觸發條件**：Profiling 顯示 DateTime/InputToken 解析位於熱門幀中。

---

## 第三部分：Omega-2 — 僅作備忘

**內容**：Typewriter 僅插入最可能的單一聲調，依賴 Homa DP 進行校正。

**狀態**：不實施。僅當所有希臘字母任務完成後仍持續嚴重停頓時才考慮。

**風險**：若 Homa 無法由上下文消歧聲調，可能降低準確度。

---

## 第四部分：跨倉庫同步檢查清單

變更必須鏡像至：
- [x] `vChewing-macOS`（主倉庫）
  - Omega-1: `1f2927c28` `Homa // Replacing [[String]] keys with [PossibleKey].`
  - Typewriter API 更新: `b294bd3d9` `Typewriter // Update Homa-related API usages.`
  - Alpha+Zeta: `37144c05c` `Homa // Optimize queryGramsForAlternatives().`
  - Beta: `e9294cd32` `LMAssembly // LMI: LRU cache + \`&\` fallback.`
  - O-14/O-16: `363ccac87` `LMInstantiator // Remove unused \`&\` fallback.`
- [x] `vChewing-OSX-Legacy`
  - Omega-1: `fc938c0` `Homa // Replacing [[String]] keys with [PossibleKey].`
  - Typewriter API 更新: `b6eaa8c` `Typewriter // Update Homa-related API usages.`
  - Alpha+Zeta: `a7f0adb` `Homa // Optimize queryGramsForAlternatives().`
  - Beta: `385e30f` `LMAssembly // LMI: LRU cache + \`&\` fallback.`
  - O-14/O-16: `b5ae20b` `LMInstantiator // Remove unused \`&\` fallback.`
- [x] `vChewing-LibVanguard`
  - Omega-1: `d2df162` `Homa // Replacing [[String]] keys with [PossibleKey].`
  - Alpha+Zeta: `2931d7b` `Homa // Optimize queryGramsForAlternatives().`
  - Beta / O-14/O-16: 無 LMInstantiator，無需實施。

各倉庫須執行：
1. 套用 Homa 變更
2. 套用 Typewriter 變更
3. 套用 LMInstantiator 變更
4. 更新測試
5. 於各子套件執行 `swift test`
6. 執行 `make lint; make format`

---

## 第五部分：提交模式

```
Homa // Phase 46 - Omega-1: Introduce PossibleKey enum, change keys from [String] to [PossibleKey].
Typewriter // Phase 46 - Omega-1: Pass structured tone arrays instead of & strings.
LangModelAssembly // Phase 46 - Omega-1: Remove mergedAlternativeBucketUnigrams and & handling.
Homa // Phase 46 - Alpha+Zeta: Optimize queryGramsForAlternatives().
LMAssembly // Phase 46 - Beta: LRU cache + & fallback.
```

---

## 第六部分：待商榷 / 未處理清單

> 以下為新對話接手時需優先關注的項目。

1. **Eta 已放棄，但未來「搜狗 style 不完全拼寫」需重新評估 `maxSegLength` 策略**
   - 當前 `maxSegLength` 為固定值。未來若實作「不完全拼寫」（如省略聲調、甚至省略韻母），可能需動態調整幅節長度限制。
   - **影響範圍**：`Homa_Assembler.swift` 的 `assignNodes`。

2. **`factoryChoppedCoreUnigramsFor` / `factoryChoppedUnigramsFor` 的清理**
   - 這些函式目前僅由 `hasUnigramsForFast` 使用（`mergedAlternativeBucketUnigrams` 已於 O-16 移除）。`hasUnigramsForFast` 中的 `factoryChopped*` 呼叫是為了處理 `&` 而引入的捷徑，現已無此需求，可考慮簡化為直接呼叫 `factoryUnigramsFor`。
   - **影響範圍**：`LMInstantiator_TextMapExtension.swift`、`LMInstantiator.swift` 的 `hasUnigramsForFast`。

3. **Delta / Theta 的觸發條件**
   - 均為效能最佳化，需實際 profiling 才能決定優先順序。目前無明確數據支持實施。
   - **建議**：先於實際輸入場景（長句、高聲調密度）收集 Instruments trace，再決定是否實施。

4. **Epsilon（Bigram 上下文）**
   - 非效能問題，而是準確度增強。屬於獨立功能，與 Phase 46 無直接關聯。
   - **建議**：另開 Phase 或獨立 Issue 追蹤。

---

## 第七部分：決策點

1. **是否保留 `factoryChoppedCoreUnigramsFor` / `factoryChoppedUnigramsFor`？**
   - **暫時保留**。它們仍由 `hasUnigramsForFast` 使用，且能正確處理精確索引鍵陣列（early-return 至正常路徑）。可於後續清理。

2. **是否於 LMInstantiator 新增 `hasUnigramsForAny(keyArrays: [[String]])` API？**
   - **暫時不新增**。Typewriter 可逐一遍歷替代項並個別呼叫 `hasUnigramsForFast`。若 profiling 顯示此為瓶頸，日後再新增。

3. **`Homa.Assembler.insertKeys` 是否應接受 `[String]` 並附加棄用警告？**
   - **是**。新增棄用過載以於過渡期維持向下相容。日後某 Phase 再行移除。
