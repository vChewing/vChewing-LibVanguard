# Phase 42 手術前調查報告：AfterPhase41 殘餘熱區收斂計畫

> 調查日期：2026-04-24
> 研究範圍：vChewing-VanguardLexicon、vChewing-LibVanguard、vChewing-macOS、vChewing-OSX-Legacy
> 研究員：GPT-5.3-Codex
> 依據 trace：vChewing-macOS/tmp/TestResult_AfterPhase41.trace
> 文檔狀態：PreResearch（可直接作為 Phase 42 實作開工依據）

---

## 一、觀測摘要（AfterPhase41）

本輪已成功從 trace 匯出完整 cpu-profile row（非僅 TOC），可見熱點已從 Phase 41 前的「笛卡爾積展開 + Dictionary.filter」轉移到以下兩個主軸：

1. 拼音 chopped 查詢路徑中的字串逐字走訪與比對。
2. TextMap value line 的即時解析（尤其在 chopped 候選校驗後的 node parse）。

同時存在兩群「高噪訊但非本 phase 主要戰場」：

1. IMK 選單建構 / NSXPC 編碼。
2. AppKit 視窗交易（tooltip / candidate window / popup window）。

這些噪訊會拉高總 cycles，但與「拼音免聲調長句」主訴延遲的因果鏈較弱。

---

## 二、核心元兇（Root Causes）

### RC-A：TextMap chopped 比對仍高度依賴 Swift Grapheme 路徑（最高影響）

關鍵線索（trace）：

- 大量命中 `String.distance(from:to:)`、`_StringGuts._opaqueComplexCharacterStride(startingAt:)`、`_swift_stdlib_getGraphemeBreakProperty`。
- 主要堆疊落點在：
  - [Packages/vChewing_LangModelAssembly/Sources/TrieKit/TrieTextMap_Core.swift](Packages/vChewing_LangModelAssembly/Sources/TrieKit/TrieTextMap_Core.swift#L763)
  - [Packages/vChewing_LangModelAssembly/Sources/TrieKit/TrieTextMap_Core.swift](Packages/vChewing_LangModelAssembly/Sources/TrieKit/TrieTextMap_Core.swift#L941)

判讀：

Phase 41 雖已導入 chopped fast path，但目前 `parseChoppedColumns` / `nodeMatchesChoppedColumns` / `candidateNodeIDsForChoppedColumns` 仍以 `String` + `first` + `hasPrefix` + `split` 反覆走 Unicode 字素邊界。對於高頻查詢，這條路徑會被 Grapheme 邏輯放大。

### RC-B：TextMap node 解析與 grouped value decode 仍在熱路徑上即時發生（高影響）

關鍵線索（trace）：

- `VanguardTrie.TrieIO.parseValueLine(_:isTyping:defaultProbs:)`
- `VanguardTrie.TextMapTrie.parseNodeEntries(_:)`
- `StringProtocol.range(of:...)` / `_stringCompareFastUTF8Abnormal`

關鍵檔案：

- [Packages/vChewing_LangModelAssembly/Sources/TrieKit/VanguardTrieIO.swift](Packages/vChewing_LangModelAssembly/Sources/TrieKit/VanguardTrieIO.swift)
- [Packages/vChewing_LangModelAssembly/Sources/TrieKit/TrieTextMap_Core.swift](Packages/vChewing_LangModelAssembly/Sources/TrieKit/TrieTextMap_Core.swift#L684)

判讀：

chopped 候選落點確定後，仍有不少 node 會走 value line 解析與 grouped cell decode。若 parse 結果快取命中不足，會持續觸發字串掃描與配置。

### RC-C：拼音 auto-chop 過程仍可觸發 `Tekkon.PinyinTrie` 重建/排序成本（中高影響）

關鍵線索（trace）：

- `Tekkon.PinyinTrie.init(parser:)`
- 伴隨 `MutableCollection.sort(by:)`、`String.distance(from:to:)`。

關鍵檔案：

- [Packages/vChewing_Tekkon/Sources/Tekkon/Tekkon_PinyinTrie.swift](Packages/vChewing_Tekkon/Sources/Tekkon/Tekkon_PinyinTrie.swift#L12)
- [Packages/vChewing_Typewriter/Sources/Typewriter/Typewriter/Typewriter_BPMFFullMatch.swift](Packages/vChewing_Typewriter/Sources/Typewriter/Typewriter/Typewriter_BPMFFullMatch.swift#L189)

判讀：

`performPinyinAutoChopIfNeeded` 位於 keydown 熱路徑；若 parser/pinyin trie 在過程中反覆重建，初始化排序成本會直接進入打字延遲。

### RC-D：`LMInstantiator` 仍有殘餘字串拼接與展開訪問成本（中影響）

關鍵線索（trace）：

- `LMAssembly.LMInstantiator.mergedAlternativeBucketUnigrams(for:)` 仍在熱堆疊。
- 出現 `specialized visit #1 in expandAlternativeKeyArrays(from:)`、`joined(separator:)`。

關鍵檔案：

- [Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift](Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/LMInstantiator.swift)

判讀：

Phase 41 已大幅收斂 full-scan，但擴展 key array 與字串串接仍然高頻。其重要性低於 RC-A/B，但仍值得在 Phase 42 併刀處理。

---

## 三、非主戰場噪訊（避免誤判）

AfterPhase41 trace 仍有明顯高點來自：

1. IMK menu dictionary / NSXPC encode（`SessionCtl.makeMenu()` 相關）。
2. Tooltip / Candidate window 的 AppKit transaction。
3. debug callstack symbolization（`dyld...findClosestSymbol` 連動 `switchState(caller:line:)`）。

這些會汙染總體 CPU 觀感，但不是「拼音免聲調長句」最直接瓶頸。Phase 42 先不把它們當主要交付目標，僅記錄為後續 hygiene phase 候選。

---

## 四、Phase 42 修復藍圖（建議落刀順序）

### P42-A：把 chopped 比對內核改為 byte-oriented（最高優先）

目標：避開 Grapheme 邊界成本，讓「首字判定 + 前綴比對」回到 ASCII/BPMF byte 層。

建議做法：

1. 在 `TextMapTrie` 內新增私有 helper，針對 chopped cell 提供 UTF-8 bytes cache（query-scope）。
2. `candidateNodeIDsForChoppedColumns` 不再做 `String.first?.description`，改用預先取出的首 byte。
3. `nodeMatchesChoppedColumns` 的 `hasPrefix` 改為 byte prefix compare。
4. 保留舊 String 路徑作 fallback（防守非預期字元）。

預期收益：直接打掉 `_StringGuts` / `GraphemeBreak` 族群熱點。

### P42-B：提升 node parse 結果命中，減少 `parseValueLine` 重入（高優先）

目標：同一批 chopped 查詢中，降低 value line 重複 decode。

建議做法：

1. 檢查並擴充 node/entry group cache key 的 query-local reuse（避免同輪重入）。
2. `parseNodeEntries` 內對 grouped values 的 decode 走更輕量分支（已知無 escape 時直切）。
3. 在 `factoryChoppedCoreUnigramsFor` 入口加上最小化查詢去重，減少重複 node 觸達。

預期收益：壓低 `VanguardTrieIO.parseValueLine` 與 `_stringCompare*` 熱點。

### P42-C：鎖住 `PinyinTrie` 生命週期，避免熱路徑重建（高優先）

目標：確保 parser 未變時不重建 `PinyinTrie`。

建議做法：

1. 在 Tekkon parser/composer 層加「parser identity → trie」快取（或 lazy singleton）。
2. 只在輸入法方案切換（layout/style）時重建。
3. 為 auto-chop 場景補測試，鎖定多次 keydown 不應重複初始化。

預期收益：減少 `PinyinTrie.init` 造成的 sort + 字串距離成本。

### P42-D：縮減 `LMInstantiator` 殘餘字串串接成本（次優先）

目標：降低 `expandAlternativeKeyArrays` 與 `joined(separator:)` 高頻配置。

建議做法：

1. 對 tone-insensitive query key 追加短生命週期快取。
2. 避免在單次 triage 內重複建立相同 joined key。
3. 若可行，將 expanded key 的中間結構改為 interned representation。

---

## 五、四倉庫分工

1. vChewing-LibVanguard：先做 canonical 實作（P42-A/B 核心刀）。
2. vChewing-macOS：鏡像 TrieKit + LangModelAssembly + Tekkon/Typewriter 入口修補（P42-C/D 驗證主場）。
3. vChewing-OSX-Legacy：語義鏡像與編譯對位（必要時保留最小條件分歧）。
4. vChewing-VanguardLexicon：本 phase 不改格式；僅在需要時補最小 benchmark fixture。

---

## 六、驗收標準（DoD）

### 功能正確性

1. chopped / partial-match / longer-segment 結果集合與排序不回歸。
2. 原廠詞典 tone bucket 行為與目前語義一致。
3. 拼音 auto-chop 結果穩定，無誤切與漏切。

### 效能驗收

1. `TrieTextMap_Core` 相關 `_StringGuts*` / `_swift_stdlib_getGraphemeBreakProperty` 明顯下降。
2. `VanguardTrie.TrieIO.parseValueLine` 相關樣本占比下降。
3. `Tekkon.PinyinTrie.init(parser:)` 不再在連續 keydown 中反覆出現。
4. 同場景（AfterPhase41 重現腳本）下，主觀長句延遲再下降一級。

### 測試矩陣

1. LibVanguard：TrieKit + TextMap chopped regression + parse path tests。
2. macOS：LangModelAssembly + Typewriter auto-chop 熱路徑 regression。
3. Legacy：`make debug-core` 通過。

---

## 七、結論

Phase 42 的主戰略應該很明確：

1. 把 chopped fast path 從「語義上已避免笛卡爾積」再推進到「實作上避開 Grapheme 成本」。
2. 把 TextMap value parse 從「可用」壓到「高命中、低重入」。
3. 把 `PinyinTrie` 建構成本從 keydown 熱路徑移除。

Phase 41 已完成第一輪結構性止血；Phase 42 的任務是把剩餘熱點從字串內核與解析重入層面做第二輪精修，讓拼音免聲調長句輸入延遲進一步收斂到可接受範圍。