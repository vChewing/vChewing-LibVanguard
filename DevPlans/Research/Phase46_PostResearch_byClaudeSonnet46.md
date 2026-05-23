# Phase 46 術後調查報告：拼音免聲調卡頓仍存 — 組合爆炸根因持續與熱路徑定位

> 調查日期：2026-04-25  
> 研究範圍：`vChewing-macOS`（主）、`vChewing-LibVanguard`（參照）  
> 研究員：Claude Sonnet 4.6（Anthropic）
> Trace 檔案：`vChewing-macOS/tmp/TestResult_AfterPhase46.trace`  
> Trace 對應版本：commit `363ccac`（`LMInstantiator // Remove unused & fallback`，即 Phase 46 最終狀態）  
> 文檔狀態：獨立調查，與 `Phase46_PostResearch.md` 並列，互不干涉。

---

## 一、Hang 量化結果

從 trace 的 `potential-hangs` 資料表提取：

| Hang 起始時間 | 持續時間 | 類型 |
|-------------|---------|------|
| `00:08.171` | 274.77 ms | Microhang |
| `00:08.518` | **1.36 s** | Hang |
| `00:10.554` | **7.51 s** | Severe Hang |

**Phase 46 總 Hang 時間：≈ 9.14 s**

相比 Phase 45 的 13.11 s，改善約 30%。改善來源為 Omega-1（移除 `mergedAlternativeBucketUnigrams` 的 `&` 字串拼接）與 Beta（LRU Cache）。然而卡頓並未消除，仍造成不可接受的使用體驗。

---

## 二、Phase 46 後的熱路徑 CPU 取樣

取樣方式：PMI（Performance Monitor Interrupt），每 **1,000,000 cycles** 一次取樣。M4 Mac mini 約 4 GHz，故每次取樣代表約 0.25ms 的 CPU 時間。

### 2-1. 全域 Top Frames（含 system frames）

```
  79  <deduplicated_symbol>
  71  specialized BidirectionalCollection<>.joined(separator:)
  52  _StringGutsSlice._fastNFCCheck(_:_:)
  47  _stringCompareFastUTF8Abnormal(_:_:expecting:)
  39  LMAssembly.LMInstantiator.unigramsFor(keyArray:)  ← 最熱 vChewing 入口
  32  _xzm_free
  24  _stringCompareInternal(_:_:expecting:)
  22  Hasher._combine(_:)
  21  specialized _StringGutsSlice._withNFCCodeUnits(_:)
  21  _StringGuts._opaqueComplexCharacterStride(startingAt:)
  20  String.Iterator.next()
  19  Hasher._finalize()
  16  specialized QueryBuffer.get(hashKey:)
  15  Homa.Assembler.queryGrams(using:cache:)
  14  specialized QueryBuffer.set(hashKey:value:)
```

### 2-2. vChewing 相關 Top Frames（過濾）

```
  39  LMAssembly.LMInstantiator.unigramsFor(keyArray:)
  16  specialized QueryBuffer.get(hashKey:)
  15  Homa.Assembler.queryGrams(using:cache:)
  14  specialized QueryBuffer.set(hashKey:value:)
  11  VanguardTrie.TextMapTrie.getNodes(keyArray:filterType:partiallyMatch:longerSegment:)
  11  partial apply for specialized closure #1 in QueryBuffer.get(hashKey:)
  10  specialized closure #1 in QueryBuffer.get(hashKey:)
  10  LMAssembly.LMInstantiator.factoryUnigramsFor(key:keyArray:column:)
  10  closure #2 in InputHandler.init(...)   ← gramQuerier 閉包（正常查詢路徑）
   9  LMAssembly.LMCoreEX.unigramsFor(key:keyArray:...)
   8  closure #2 in VanguardTrie.TextMapTrie.getNodes(...)
   6  BPMFFullMatchTypewriter.performPinyinAutoChopIfNeeded<A>(...)
   5  VanguardTrie.TextMapTrie.parsedEntries(for:)
   5  VanguardTrie.TextMapTrie.getNodeIDsForKeyArray(_:longerSegment:)
   5  outlined destroy of LMAssembly.LMCoreEX   ← 值型別被複製並銷毀
   4  InputHandlerProtocol.triageInput(event:)
   3  Homa.Assembler.queryGramsForAlternatives(_:cache:)
   3  Homa.Assembler.assignNodes(updateExisting:)
   3  VanguardTrie.TrieIO.decodeGroupedValues(_:)（×2 變體）
   2  specialized static Homa.Assembler.cartesianProduct<A>(_:)
   2  closure #2 in Homa.Assembler.fetchCandidates(at:filter:)
```

---

## 三、Phase 45 → Phase 46 熱路徑對照

| Frame | Phase 45 取樣次數 | Phase 46 取樣次數 | 變化 |
|-------|:---------------:|:---------------:|------|
| `BidirectionalCollection.joined(separator:)` | 93 | 71 | ↓ 24%（來源改變，見§4） |
| `_StringGutsSlice._fastNFCCheck` | 76 | 52 | ↓ 32% |
| `specialized Set.contains(_:)` | 67 | 0 | ✅ 消除（`AlternativeKeyArrayIterator.seen` 移除） |
| `specialized Set.insert(_:)` | 58 | 0 | ✅ 消除 |
| `_stringCompareInternal` | 40 | 24 | ↓ 40% |
| `makeFactoryUnigrams` / memoized 層 | 29 | 0 | ✅ 消除 |
| `LMInstantiator.unigramsFor(keyArray:)` | （掩蓋於以上 frames 中） | **39** | 瓶頸被揭露 |
| `QueryBuffer.get/set` | 0 | **30** | 新增（Beta LRU） |
| `TextMapTrie.getNodes` | 33（內 malloc/free） | 11 | ↓ 67% |
| `outlined destroy of LMCoreEX` | 0 | 5 | 新增（值型別複製） |
| `closure #2 in InputHandler.init(...)` = gramQuerier 閉包 | （掩蓋於其他 frames） | **10** | 正常查詢路徑，瓶頸揭露 |
| `Homa.Assembler.queryGramsForAlternatives` | 0 | 3 | 新增（Phase 46 Omega 路徑） |
| `Homa.Assembler.cartesianProduct<A>` | 0 | 2 | 新增 |

**結論**：Phase 46 成功消除了 `&` 拼接、`seen` Set、`memoizedFactoryUnigrams` 三個原始熱點，但「24,405 次序列查詢」的組合爆炸根因未動，主瓶頸轉移至 `unigramsFor(keyArray:)` 本身（39 samples）。

---

## 四、各熱路徑根因分析

### 根因 A：組合爆炸未解決（HIGHEST IMPACT）

**公式**：N 個音節的免聲調拼音輸入，span 長度 L 的笛卡爾積為 5^L 個組合。

| span L | 組合數 | 累積查詢數 |
|-------:|------:|----------:|
| 1 | 5 | 5 × N |
| 2 | 25 | 25 × (N-1) |
| 3 | 125 | 125 × (N-2) |
| 4 | 625 | 625 × (N-3) |
| 5 | 3,125 | 3,125 × (N-4) |
| 6 | 15,625 | 15,625 × 1 |

對 N=6：**總計 24,405 次 `unigramsFor(keyArray:)` 呼叫**（已去重後仍如此）。

Phase 46 Omega-1 將笛卡爾積展開從 LMInstantiator 移入 Homa，但展開後仍須對每個組合單獨查詢。查詢量完全未減少。

---

### 根因 B：LRU QueryBuffer 在組合爆炸規模下的命中率問題（MEDIUM）

Beta 引入了上限 1024 的 LRU cache（`QueryBuffer`）。trace 顯示 `QueryBuffer.get/set` 共 **30 samples**，說明 cache 在熱路徑中高頻被存取，但 6 音節的 24,405 個不同組合遠超 cache 容量，大量 cache miss 導致：

1. Cache 持續觸發 LRU eviction（最老 50% 清除）
2. 每次 `queryGrams` 都走 `QueryBuffer.get` → miss → `unigramsFor` → miss → `factoryUnigramsFor` → `TextMapTrie.getNodes` 全路徑

Beta 對 **重複輸入同一句子**有明顯效果；對**首次輸入 6+ 音節的新句子**幾乎無效。

---

### 根因 C：`BidirectionalCollection.joined(separator:)` 的來源轉移（MEDIUM）

Phase 45 的 71 samples 中的 `joined` 主要來自 `mergedAlternativeBucketUnigrams`（建構 `&` key）。Phase 46 移除了該路徑後，`joined` 降至 71 samples，**來源卻已轉移**：

1. **`Homa.Assembler.fetchCandidates(at:filter:)` 的排序比較器**（確認於 `Homa_CandidateAPIs_FetchAndApply.swift` line 64）：每次比較都呼叫 `joined(separator: "-")` 來建構候選字串進行排序。N=6 時可能有數百候選，排序做 O(n log n) 次比較即 O(n log n) 次 `joined`。

2. **`TextMapTrie.getNodes` 內部的 closure #3**（`source line 906`）：建構內部字串時使用 `DefaultStringInterpolation.appendLiteral`，間接觸發字串分配。

---

### 根因 D：`LMCoreEX` 值型別在熱路徑中被複製（LOW）

`outlined destroy of LMAssembly.LMCoreEX` 出現 **5 samples**，`outlined init with copy of LMAssembly.LMCoreEX` 出現 3 samples。

`LMCoreEX` 是 struct，包含 `VanguardTrie` 指標、字典、設定項等。在某些閉包捕獲或傳遞路徑上，整個 struct 被複製再銷毀，造成不必要的 ARC 操作。

---

### 根因 E：`TextMapTrie.getNodes` 每次查詢仍須字串解析（MEDIUM）

Trace 中可見：
```
specialized Collection.split(maxSplits:omittingEmptySubsequences:whereSeparator:)
specialized static VanguardTrie.TrieIO.decodeGroupedValues(_:)
specialized static VanguardTrie.TrieIO.splitEscapedGroupedValues(_:)
VanguardTrie.TextMapTrie.parseNodeEntries(_:)
```

每次 `getNodes` 呼叫若 NSCache miss，就須走完整的字串解析路徑（`decodeGroupedValues` → `splitEscapedGroupedValues` → `parseNodeEntries` → `String.hasPrefix` / `_stringCompareInternal`），涉及大量 Unicode 正規化（`_fastNFCCheck`）。NSCache 容量有限，24,405 次查詢中大量 miss。

---

## 五、為何 Phase 46 後仍卡

總結：Phase 46 的各 task 效果評估。

| Task | 實際效果 | 卡頓根源是否移除 |
|------|---------|:----------:|
| Omega-1：移除 `&` 拼接 | ✅ 消除 `AlternativeKeyArrayIterator`、`seen` Set | 否 |
| Alpha+Zeta：all-singleKey 快速路徑 | ✅ 對「有聲調」輸入幾乎消除 overhead | **否**（免聲調路徑走 `.multipleKeys`）|
| Beta：LRU cache | ⚠️ 對重複句子有效，對 24,405-combination 首次查詢幾乎無效 | 否 |

**根本原因仍為**：每次 `assignNodes(updateExisting:)` 仍須向 `LMInstantiator.unigramsFor(keyArray:)` 發出 24,405 次序列呼叫，每次呼叫走 `QueryBuffer.get` → miss → `factoryUnigramsFor` → `TextMapTrie.getNodes` → 字串解析。

---

## 六、已知的下一步選項（供 Phase 47 參考）

以下分析為觀察所得，並非指令。

### 選項 1：TextMapTrie 真正批次查詢 API（Estimated: HIGH IMPACT）

實作 `TextMapTrie.getNodeIDsForKeyArrays(_ keyArrays: [[String]]) -> [[NodeID]]`，讓單次 binary search 掃描服務多個 key，共用排序索引掃描上下界。可讓 24,405 次個別 binary search 降為一次有序掃描，理論複雜度從 O(24405 × log N) 降為 O(24405 + N)。

需同步實作 `LMInstantiator.grams(forMany:)` 呼叫批次 `TextMapTrie` API，以及 Homa 層的 `GramBatchQuerier` 回調介面讓批次結果能傳入組字器。

### 選項 2：Homa 側機率剪枝（Estimated: MEDIUM IMPACT）

在 `queryGramsForAlternatives` 的笛卡爾積展開時，若某個部分組合的累積「最高可能分數」已低於當前已知最佳路徑的分數閾值，可提前剪枝，無須向 LM 發出查詢。但需要先有分數估計器，實作較複雜。

### 選項 3：增量計算（Estimated: MEDIUM IMPACT）

`assignNodes(updateExisting: false)` 每次從頭重算所有 span。可改為 `updateExisting: true` 路徑只重算含新增位置的 span，避免重算舊位置。但需確認 Homa 的 `gramQueryCache` 是否能正確跨呼叫持久。

### 選項 4：`fetchCandidates` 排序器去除 `joined` 呼叫（Estimated: LOW-MEDIUM）

改以 `keyArray` 直接比較（`[String]` lexicographic）取代 `joined(separator: "-")` 字串比較，消除排序過程中的 string allocation。

---

## 七、結論

Phase 46 完成了 Omega-1 / Alpha / Zeta / Beta 四個有效任務，卡頓總時間從 13.1s 降為 9.1s（改善 ~30%）。

vChewing 免聲調拼音的卡頓根本原因從未改變：每次組字呼叫產生 O(5^N) 個序列 LM 查詢。Phase 47 的首要任務是在 `TextMapTrie` / `LMInstantiator` 層實現真正的批次查詢能力，搭配 Homa 的 `GramBatchQuerier` 回調介面，讓單次 binary search 掃描服務所有組合。

---

## 八、補記：無解死局與 Phase 47 實際建議方向

> 本節為與 Kimi 的 `Phase46_PostResearch_byKimi.md` 交叉討論後所得，補記於此。

### 8.1 Omega-2（聲調剪枝）的根本缺陷

Kimi 的報告建議 Omega-2：讓 Typewriter 在無聲調模式只產生一個「最可能」聲調，將 O(5^N) 查詢量削減為 O(1^N)。這在工程數字上誘人，但存在無法迴避的正確性問題：

**Homa PathFinder 只能從 Assembler 提供的 gram pool 裡尋找最佳路徑。** 若聲調剪枝砍掉的恰好是某多音字在當前句子語境下的正確讀音，PathFinder 永遠拿不到那個 gram，正確候選徹底消失，且無法 recover。這不是「準確度稍低」的問題，而是「靜默輸出錯字」的問題。

多音字密度越高的情境（新聞標題、文言、專有名詞），剪枝誤傷的機率越高。沒有任何一個聲調選擇策略能保證「被剪掉的永遠是不需要的讀音」——這是需求本身決定的，不是工程問題。

**Omega-2 是死路。**

### 8.2 架構與需求的根本矛盾

這裡有一個很能說明問題的對比：**只要使用完整讀音輸入（不用 partial matching），哪怕 composition buffer 塞上幾千個音節，Homa DAG-DP 都能正常組句且不卡頓。** 原因就在於完整讀音模式下每個音節位置只有 1 個讀音候選，DAG 每個 span 的展開是 O(1)，整條 DP 是 O(N)，跟 buffer 長度成線性關係。

免聲調部分匹配讓每個位置從 1 膨脹到 5，span 展開從 O(1) 變 O(5)，整條 DP 變 O(5^N)。卡頓的肇因 100% 在查詢生成層（Typewriter → LMInstantiator），Homa 本身的 DAG-DP 從頭到尾沒有問題。Omega-2 的本質就是用人工方式把免聲調模式偽裝回完整讀音模式，代價是犧牲多音字的正確率——注音模式不需要這個把戲，因為使用者輸入的聲調本身就是那根「把 5 壓回 1」的指標。

Homa DAG-DP 的設計前提是「每個讀音位置的候選集是有限且明確的」。完整聲調拼音讓每個位置通常只有 1 個讀音（注音模式）或少數幾個（有聲調拼音模式）。免聲調輸入將每個位置的候選集從 1 膨脹到 5，讓 span 長度為 N 的組合數從線性變成 O(5^N) 的指數爆炸。

這個複雜度本身沒有架構上的快捷方式：
- 剪枝（Omega-2）以正確性為代價，不可接受。
- 批次查詢（TextMapTrie 批次 API）治標，N=6 時即使每筆查詢加速 10 倍，24,405 次仍可能超標。
- 非同步化在 IMK 架構下引入競態，不適用。

### 8.3 唯一有 usability 保證的方向：限制組字區長度

從 trace 數據看：

| 組字區音節數 N | 單次 `assignNodes` 查詢量 | 實測體感 |
|:---:|---:|---|
| 4 | ~780 | 幾乎無感 |
| 5 | ~3,905 | 接近 trace 第一個 274ms Microhang 的邊緣 |
| 6 | ~24,405 | Severe Hang 7.51s |

Typewriter 本身已有「蒼蠅一邊吃一邊屙」的 auto-commit 機制（即組字區超過設定長度時自動交付前段）。該機制目前服役於浮動組字窗模式。**拼音模式強制啟用此機制、將組字區上限設為 4 或 5 個音節**，是目前唯一對使用者體驗有完整保證的方案，且無正確性風險。

Phase 47 的核心任務應是：**為拼音免聲調模式加掛組字區長度上限**，借用現有 auto-commit 路徑，而非試圖從演算法層面解決這個本質上屬於需求複雜度的問題。

TextMapTrie 批次查詢優化（若後續要做）可作為獨立任務在此之後進行，以改善其他場景下的 LM 查詢延遲，但不應被視為拼音卡頓問題的解法。
