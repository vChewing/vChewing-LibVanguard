# Phase 137 後續調查：Heap Storm 爆發點全面搜查報告（Post-Research）

> 調查日期：2026-08-08。範圍：LibVanguard / vChewing-macOS / vChewing-OSX-Legacy 三倉。
> 背景：Phase 137 完成 NotifierUI 由「multiple NSWindow / NSPanel」改為「單一常駐透明 NSWindow +
> 卡片堆疊」（卡片池重用記憶體位址、物件），與 Phase 136（Homa Assembler 的 `Node` class→struct、
> heap 風暴根治）同屬「重複利用記憶體位址與物件、減少 heap pressure」的脈絡。本報告在此脈絡下
> 繼續搜查其餘 heap storm 爆發點，以作為後續手術 Phase 的決策依據。

## 一、結論速覽

| 排名 | 爆發點 | 路徑 | 每操作分配 | 性質 | 建議 |
|---|---|---|---|---|---|
| 1 | `Homa.Node.getScore` 的 `grams.filter` 一次性陣列 | 每敲鍵 DP | ~55–100 個 `[Gram]` 陣列 / 組句 | value buffer 小陣列 | **手術候選 A**（Phase 136 殘留延伸） |
| 2 | `CandidatePool` 的 class cell 全面重建 | 候選窗開啟 / 磁帶快速選字 / Option+方向鍵 | N × class 實例 + keyArray 陣列 + 屬性字串測量 | reference type 中型 | **手術候選 B（事主已懷疑）** |
| 3 | `fetchCandidates` sort comparator 的字串插值 | 候選窗開啟 | O(n·log n) 個 `joined()` 字串 | 字串 | 順手清理（可併入 B） |
| 4 | `gramBorderPointDictPair` / `cursorRegionMap` 字典重建 | 游標移動 / consolidate 迴圈 | 每次存取 2 個 `[Int:Int]` dict | value buffer | 順手清理 |
| 5 | `PathFinder.run` DP 骨架 | 每敲鍵 | dp / parent / visitedNodes / result 4 陣列 | value buffer | 可緩（已受 struct 化庇蔭） |

- 已確認**非**爆發點：`FIUUID`（純 struct）、`Homa.Gram` / `Node` / `Segment` 值語義（COW）、
  TrieKit QueryBuffer + LRU entry cache + scratch buffer 重用、`TrieHighFrequencyDecoder` byte 級解析、
  `unigramsFor` LRU 快取（命中零分配）、`LMInstantiator` 雙層快取、Tekkon 少量字串、CandidateKit 的
  `CandidateCellData`（死碼，無消費端）。
- 舊的 `_ResearchScratch/_HeapResearchAboutSettings/*.txt` heap dump 標記「Outdated as of Phase 127's
  finish. Needs update.」——本調查為結構性分析（分配次數層面），量級驗證建議日後以 Instruments
  malloc 追蹤補測（與 Phase 136 結論一致：精簡版 `malloc_statistics_t` 無累計次數欄位）。

---

## 二、每敲鍵熱路徑（純打字，不開候選窗）

事件流：`triageInput → handleComposition → composer.receiveKey（Tekkon struct）→ assemble →
updateCompositionBufferDisplay → IMEStateParsed4Darwin → doSetMarkedText`；
LM 橋：`InputHandler.swift:39-47` 將 `assembler.gramQuerier` 接到 `LookupHub.grams(for:)` →
`LMInstantiator.unigramsFor`。

### 2.1 `Node.getScore(previous:)` 的 filter 陣列 —— 最熱的單一分配點

`Homa_Node.swift`：

- `unigramScore`（`:188-190`）：`grams.filter { ($0.previous ?? "").isEmpty }` —— 每次呼叫 1 個 `[Gram]` 陣列。
- `getScore(previous:)`（`:211-213`）：previous 非空時 `grams.filter { $0.previous == previous && $0.current == currentValue }` —— 每次呼叫 1 個 `[Gram]` 陣列。

`PathFinder.run` 對每個可達節點呼叫一次 `getScore`（`Homa_PathFinder.swift:67`），10–30 鍵的組字區約
30–60 個訪問節點 → **每組句 30–120 個一次性 `[Gram]` 小陣列**。`assemble()` 每敲鍵至少跑一次
（`Homa_Assembler.swift:419`），POM 開啟或覆寫時再 ×2–3（`Homa_CandidateAPIs_FetchAndApply.swift:184,235`）。

> 這是 Phase 136 刪除 `bigramMap` 派生字典之後的殘留：舊字典是「常駐每個節點 1 個 dictionary」、
> 新線性掃描是「每次查詢 1–2 個 transient filter 陣列」。分配次數從常駐轉為 transient，頻率反而更高。
> 兩份獨立調查（macOS 路徑 + LibVanguard 路徑）都將其列為第一名。

**修法方向**（候選 A）：單 pass 迴圈同時求 unigram 最高分與 bigram 最高分、不建 filter 陣列；
或於 Node 內緩存 unigramScore（`grams` setter 時重算一次）。皆為純值操作、無行為語義改變。

### 2.2 `assignNodes` × `queryGrams` 迴圈

`Homa_Assembler.swift`，每敲鍵掃描 ~55 個 (position, length) 組合：

| 位置 | 分配 | 數量/鍵 |
|---|---|---|
| `:482` | `Array(alternativesSlice)` —— 新 `[PossibleKey]` | ~55（每組合 1 個） |
| `:496` | `GramQueryCacheKey` struct 包裝（含 keyArray ref） | ~55 |
| `:501-505`（miss） | `sorted` 輸出 + `Set<Int> insertedIntel` + `compactMap` 陣列 | ~3 × miss（~10/鍵） |
| `:410-414` | 新節點 `queriedGrams.map { $0.withNewIdentity() }`（新 `[Gram]` + 每 gram 新 FIUUID = 2×`UInt64.random`） | ~10 節點 × N gram |
| `Homa_Node.swift:44` | `Node.init` → `Set(grams.map(\.keyArray))` | 每新節點 1 Set + 1 map 陣列 |

快取命中時 payload 為 COW 共享、不重分配；但「查快取」的包裝陣列每次都有。屬中等，可接受。

### 2.3 `PathFinder.run` DP 骨架

`Homa_PathFinder.swift:41,43,51,84,99`：`dp: [Double]`、`parent: [GramState?]`、`visitedNodes`
（完整 Node 值拷貝陣列）、`resultReversed` + `reversed()` + `newAssembledSentence` —— 每組句 4–5 個
transient 陣列。`visitedNodes` 寫回（`:79-81`）已驗證不觸發 dict COW（Phase 136 設計有效）。✅

### 2.4 LM `unigramsFor` 快取 miss 管線

`LMInstantiator.swift:647-877`，每新讀音鏈（每敲鍵約 10 個新組合）miss 一次：

- `rawAllUnigrams` + `factoryCoreUnigramsResult`（`:677-678`）
- `factoryUnigramsFor` × ~4 entry types + `supplyNumPadUnigrams` —— 每種內部再建 `grams` +
  `extraHalfWidthGrams` + `trie.getNodes` + `nodes.flatMap(\.entries)`（`LMInstantiator_TextMapExtension.swift:412-443`）
- `factorySingleReadingValueHashes: Set<Int>`（`:760`）
- `lmUserPhrases.unigramsFor`（`lmCoreEX.swift:233-293`，每筆 `String(decoding:)` from byte ranges）+
  `.reversed()` + `Array(...)`（`:774-782`）
- `expandedUnigrams` + InputToken 展開迴圈（`:801-816`）
- `dataAsFilter: Set<String>`（`:862-866`）
- `consolidate(filter:)` —— `[String: Double]` dict + `insertedArray`（`HomaCompatShims.swift:30-39`）
- `unigramLRUCache` 插入/淘汰（`:870-875`）

**每 miss ≈ 12–20 個 buffer + N 個 Gram struct（含每筆 fresh String）**。快取命中零分配。
已由 1024 上限的 LRU（fingerprint 失效，`:663-671`）與 Homa 512 上限 `gramQueryCache` 雙層庇蔭——
但「每敲鍵 ~10 個新組合 miss」是打字行為本質，無法靠快取消除；這是下一階段可考慮的次級目標。

### 2.5 顯示路徑

- `generateStateOfInputting`（`InputHandler_HandleStates.swift:35-99`）：逐字元 `String(char)` 拼接、
  `insertReadingIntoSegments` 陣列 —— 每鍵。
- `IMEStateParsed4Darwin.attributedString`（`:48-70, 256-268`）：`displayTextSegments.map` +
  `NSMutableAttributedString` + 每 segment 一個 `NSAttributedString`（ObjC heap）—— 每鍵。
  註：此處僅設 `NSUnderline` / `NSMarkedClauseSegment` 屬性（無字型查詢），成本相對低；
  `doSetMarkedText` 的 `recentMarkedText` 相等性檢查（`InputSession_HandleStates.swift:137-161`）
  在構造之後才短路，屬每鍵不可避免的固有成本。
- `previouslyHandledEvents` 陣列（`InputSession_HandleEvent.swift:65-75`）—— 每鍵 1 個 `[KBEvent]`。

---

## 三、候選窗路徑

### 3.1 CandidatePool（TDK/GSI 共用 `CandidatePool4AppKit`）

**結構**：`CtlCandidateTDK4AppKit.swift:266` 與 `CtlCandidateGSI4AppKit.swift:323` 各持一個
`static let thePool` 單例 → pool 本體不重建；但 `reloadData()`（`:121-141` / `:140-160`）每次呼叫
`thePool.reinit(...)` → `construct(...)`（`CandidatePool4AppKit.swift:298-395`）時：

- **N × `CandidateCellData4AppKit` class 實例**（`CandidateCellData4AppKit.swift:18`，`final class`），
  每個實例再帶 `keyArray: [String]` 陣列、`_cachedAttributedStringPhrase: [Bool: NSAttributedString]`
  字典（`:343`）；
- 多字候選於建構子即做 `attributedString().getBoundingDimension()`（`:35-37`）—— 新建
  `NSMutableAttributedString`（header + phrase，`:198-226`）並 CoreText 測量；測量結果有全域快取
  （`AppKitImpl_Misc.swift:121-200`，`AttributedStringMeasurementCache`），但 NSAttributedString 物件
  本身每次建立即拋；
- `candidateLines` 巢狀陣列重建 + `highlight(at: 0)` 全量掃描 + `updateMetrics()`（`layoutCells` +
  `invalidateCache()` 逐 cell 清空已快取屬性字串 + peripherals badge 重建：
  `RoundedBadgeTextAttachmentCell` / NSTextAttachment / 屬性字串 ×（位置計數、tooltip、反查））。

**觸發頻率**（單一消費端 `showCandidates()` 的 `delegate = self` 重新賦值 → didSet → `reloadData()`）：

| 情境 | 頻率 |
|---|---|
| 空白鍵開啟候選窗（一般模式） | 每次開啟 1 次全量 reload |
| 磁帶快速選字（`.ofInputting` + candidates） | **每敲鍵 1 次全量 reload**（`Typewriter_Cassette.swift:196-210`、BackSpace 路徑 `InputHandler_HandleStates.swift:665-679`） |
| Option+方向鍵 / Option+Shift+方向鍵游標移動 | 每次 1 次全量 reload（`InputHandler_HandleCandidate.swift:215-244`） |
| 符號表節點下潛 / 關聯詞語進入 | 每節點 1 次 |
| 純方向鍵 / 翻頁 / Tab / 滾輪 | **不 reload**，僅 `updateDisplay()` → `updateMetrics()`（每步仍重建 badge 與屬性字串） |

> 也就是說：**CandidatePool 不是「純打字」路徑，但確是「磁帶快速選字」與「候選窗內游標移動」的
> 每敲鍵路徑**，且每次 reload 的單次成本高（class 實例 ×N + CoreText 測量 + 屬性字串 ×N）。

**GSI 是實際啟用者**（`TDKCandidates.swift:15` typealias + `SessionUI.swift:37`），TDK 為鏡像對照；
Legacy 倉結構相同（`vChewing-OSX-legacy/vChewing/Modules/CandidateControllers/`）。

**修法方向**（候選 B，事主已懷疑）：cell 由 `final class` 改 `struct`（與 Phase 136 Node 同型），
`candidateDataAll` / `candidateLines` 改值陣列；pool 本體已單例、無需池化。struct 化後每次 reload
消掉 N 個 class 實例 + N 個 keyArray 陣列 + N 個屬性字串快取字典。AppKit 渲染端（`VwrCandidate*`）
只讀 cell 的唯讀屬性、不持有引用，改動面可控制在 pool 內部。
⚠️ 需注意 `Self.shitCell` / `Self.blankCell` 是 static let class 實例、被各處以參考方式共用修改
（`isHighlighted` / `locale` 等），struct 化需改為 static 工廠或值副本。

### 3.2 `fetchCandidates` sort comparator 字串插值

`Homa_CandidateAPIs_FetchAndApply.swift:62-72`：`result.sorted` 的 comparator 內
`$0.pair.keyArray.joined(separator: "-")` —— **每次比較都新建 1 個 String** ⇒ 每次候選窗開啟 /
revolve O(n·log n) 個字串分配。修法：預先算好 joined key 再排序，或改用
`(segLength, keyArray, weight)` tuple 比對 + `lexicographicallyPrecedes`。低成本、可直接併入候選 B。

### 3.3 `gramBorderPointDictPair` / `cursorRegionMap` 字典重建

`Homa_GramInPath.swift:214-232`：`cursorRegionMap` 為 computed var，每次存取重建兩個
`[Int: Int]` 字典（`gramBorderPointDictPair`）。消費端：`Revolver.swift:73`（每次 revolve 1 次）、
`Homa_ConsolidatorAPIs.swift:52`（**consolidate while 迴圈內每節點 1 次**）、
`GramInPath.contextRange` / `findGram`（每呼叫 4–6 次字典建構）、`isCursorCuttingChar` /
`jumpCursorBySegment`（每游標移動）。修法：每操作算一次並穿針引線、或對值做 memoize。

### 3.4 其餘小項

- `TrieStringOperationCache.getCachedSplit` key 插值 `"\(string)|\(separator)"`（`TrieKit_PerformanceUtils.swift:108`）—— 每 split 快取存取 1 個 String，改複合鍵即可。
- `ChineseConverter.kanjiConversionIfRequired` 未 memoize（`InputSession_Delegates.swift:216-226`）—— 候選窗開啟時 CHT/CHS 轉換模式逐候選轉換。
- `shouldResetNode` 的 `has(string:)`（`Homa_CandidateAPIs_FetchAndApply.swift:315-319` + `Homa_SwiftImpl.swift:13-24`）—— 覆寫路徑 O(n) 切片陣列。
- `overrideCandidateAgainst` 雙重 `assemble()`（`:184,235`）—— POM/覆寫時 DP 成本 ×2。

---

## 四、已確認非問題（既有修復有效）

- **`FIUUID`**：`@frozen struct`（2×`UInt64`），無 heap 分配（`Homa_SwiftImpl.swift:62-68`）。
- **`Gram` / `Node` / `Segment` 值語義**：COW 共享，`Node` 修改不觸發深拷貝（`PathFinder.swift:67` 驗證）。
- **TrieKit**：QueryBuffer 命中零分配、TextMapTrie `cachedEntries` LRU(256) + `scratchNodeIDs` 重用、
  `TrieHighFrequencyDecoder` byte 級解析 —— 結構性良好。
- **`unigramsFor` 快取命中**：直接 COW 回傳、零分配（`LMInstantiator.swift:672-674`）。
- **CandidateKit 的 `CandidateCellData`**：全倉零消費端（死碼），非爆發點。
- **TrieSQL**：僅第三方輸入法資料讀取用，不在 IME 打字熱路徑。
- **Tekkon**：每鍵少量 String，非重點。

---

## 五、後續手術對象建議（待拆分為多個 Phase）

| 選項 | 內容 | 範圍 | 每操作消除 | 風險 |
|---|---|---|---|---|
| **A** | `Node.getScore` 單 pass 掃描 + Node 緩存 unigramScore | LibVanguard Homa + 兩鏡像 | 每組句 30–120 個 `[Gram]` 陣列 | 低（純值運算、無語義改變） |
| **B** | CandidatePool cell struct 化 + `fetchCandidates` sort 字串消除（順手） | macOS TDK/GSI + Legacy | 每次 reload N 個 class 實例 + 屬性字串 + O(n·log n) 字串 | 中（需處理 shitCell/blankCell 參考共用語義） |
| C | `cursorRegionMap` / `gramBorderPointDictPair` memoize | LibVanguard Homa + 兩鏡像 | 每存取 2 個 dict | 低 |

**說明**：A、B、C 三者互不干擾，可自由組合分配至各 Phase。依規劃，後續手術將拆分為兩個
（或更多）Phase 依序進行，具體分刀由事主另行規劃 Dev Phase。
