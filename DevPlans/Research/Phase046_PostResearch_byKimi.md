# Phase 46 Post-Research：無聲調拼音六字卡頓根因分析

> 分析標的：`/Users/shikisuen/Repos/!vChewing/vChewing-macOS/tmp/TestResult_AfterPhase46.trace`
> 工具：Xcode Instruments CPU Profiler + Hangs（threshold >250ms）
> 錄製時長：18.07s

---

## 一、執行摘要

Instruments trace 證實：**無聲調拼音模式打到第六字時，主執行緒出現連續三處 hang，累計凍結約 9.15 秒（佔總 trace 51%）**。瓶頸不在 TrieKit 索引查詢本身，而在於「查詢次數 × 每筆查詢的 string operation 開銷」的乘積效應。

單次 `assignNodes` 的 keyArray 查詢量級約 24,405 次（6 音節 × 5 聲調變體，maxSegLength=10）。CPU profile 顯示：

- **86.5%** 的 hang 樣本位於 `Homa.Assembler.queryGrams(using:cache:)` 呼叫路徑
- **僅 22.5%** 的 hang 樣本觸及 `VanguardTrie.TextMapTrie.getNodes(...)`（實際 Trie  traversal）
- **38.8%** 的 hang 樣本的 leaf frame 為 Swift string operation（NFC 正規化、hashing、grapheme breaking、string comparison）

這意味著：**每筆查詢有超過一半的時間耗在 String 的 hash/compare/normalize，而非 Trie 節點遍歷**。乘以 24K 次查詢後，總時間從「可忽略」變成「數秒級凍結」。

---

## 二、Trace 基本資訊

| 項目 | 數值 |
|------|------|
| Template | CPU Profiler + Hangs |
| Hang threshold | >250ms |
| 總錄製時長 | 18.07s |
| 目標進程 | vChewing (pid: 1499) |
| 總 CPU 樣本數 | 6,274 |
| Hang 期間樣本數 | 5,722 (91.2%) |
| 非 hang 樣本數 | 552 (8.8%) |

---

## 三、Hang 事件明細

| # | 開始時間 | 持續時間 | 等級 | 主執行緒 |
|---|---------|---------|------|---------|
| 1 | 00:08.171 | 274.77 ms | Microhang | Main Thread |
| 2 | 00:08.518 | 1.36 s | Hang | Main Thread |
| 3 | 00:10.554 | **7.51 s** | **Severe Hang** | Main Thread |

三處 hang 全部發生在 Main Thread，時間遞增趨勢與音節數遞增導致的查詢量爆炸完全吻合：

- 第 1 處（~274ms）：約 4~5 音節，`assignNodes` 查詢量約 3,905 次
- 第 2 處（~1.36s）：約 5~6 音節，查詢量躍升至約 24,405 次
- 第 3 處（~7.51s）：6 音節已達，且包含後續所有按鍵的完整 re-composition

---

## 四、Hotspot 分析（CPU Profile）

### 4.1 業務函數出現頻率（hang 期間）

以下為「call stack 中出現該函數」的樣本數與佔比：

| 函數 | 樣本數 | 佔 hang 樣本 |
|------|--------|-------------|
| `Homa.Assembler.insertKey(_:)` | 5,705 | 99.7% |
| `Homa.Assembler.insertKeys(_:)` | 5,705 | 99.7% |
| `Homa.Assembler.queryGramsForAlternatives(_:cache:)` | 5,590 | 97.7% |
| `Homa.Assembler.queryGrams(using:cache:)` | 4,949 | 86.5% |
| `LMAssembly.LMInstantiator.LookupHub.grams(for:)` | 4,810 | 84.1% |
| `BPMFFullMatchTypewriter.composeReadingIfReady` | 3,890 | 68.0% |
| `LMAssembly.LMInstantiator.unigramsFor(keyArray:)` | 3,167 | 55.3% |
| `BPMFFullMatchTypewriter.consumeReadingInputIfNeeded` | 1,829 | 32.0% |
| `BPMFFullMatchTypewriter.performPinyinAutoChopIfNeeded` | 1,829 | 32.0% |
| `LMAssembly.LMInstantiator.factoryUnigramsFor(...)` | 1,349 | 23.6% |
| `VanguardTrie.TextMapTrie.getNodes(...)` | 1,286 | 22.5% |
| `LMCoreEX.unigramsFor(...)` closure | 555 | 9.7% |
| `LMInstantiator.queryDateTimeUnigrams` | 179 | 3.1% |
| `Homa.Assembler.GramQueryCacheKey.init(_:)` | 114 | 2.0% |

### 4.2 Leaf Function 排名（hang 期間）

Leaf function 代表「取樣時 CPU 正在執行的最內層函數」：

| Leaf Function | 樣本數 | 佔 hang 樣本 | 性質 |
|--------------|--------|-------------|------|
| `_stringCompareFastUTF8Abnormal` | 360 | 6.3% | String compare |
| `_swift_stdlib_getScalarBitArrayIdx` | 316 | 5.5% | String/hash |
| `_StringGutsSlice._fastNFCCheck` | 310 | 5.4% | Unicode NFC |
| `swift_release` | 238 | 4.2% | ARC |
| `_swift_stdlib_getNormData` | 183 | 3.2% | Unicode normalize |
| `specialized closure #1 in _StringGutsSlice._withNFCCodeUnits` | 175 | 3.1% | NFC iteration |
| `<deduplicated_symbol>` | 140 | 2.4% | vChewing binary |
| `UnsafeBufferPointer.hasNormalizationBoundary` | 139 | 2.4% | NFC boundary |
| `swift_bridgeObjectRelease` | 129 | 2.3% | ARC |
| `_stringCompareInternal` | 118 | 2.1% | String compare |
| `Unicode._GraphemeBreakProperty.init` | 105 | 1.8% | Grapheme break |
| `swift_retain` | 100 | 1.7% | ARC |
| `_swift_stdlib_getGraphemeBreakProperty` | 99 | 1.7% | Grapheme break |
| `Hasher._combine(_:)` | 98 | 1.7% | Hashing |
| `Hasher._finalize()` | 92 | 1.6% | Hashing |

**String operation 相關 leaf 合計：約 38.8%**
（含 `_stringCompare*`, `_StringGutsSlice.*`, `_swift_stdlib_getNormData/ScalarBitArrayIdx`, `Hasher.*`, `GraphemeBreakProperty.*`, `hasNormalizationBoundary`）

**ARC (retain/release) 相關 leaf 合計：約 8.2%**

### 4.3 層級歸因

| 層級 | 佔 hang 樣本 | 說明 |
|------|-------------|------|
| **Homa** (`insertKey`/`queryGrams`) | ~97% | 笛卡爾積展開與 cache lookup |
| **LMInstantiator** (`unigramsFor`/`LookupHub`) | ~55% | Config hash、Dictionary<String,*> lookup、filter |
| **TrieKit** (`TextMapTrie.getNodes`) | ~22.5% | 實際 trie traversal |

> 注意：層級數字有重疊（一個樣本可同時出現在 Homa + LMInstantiator + TrieKit），因此不總和為 100%。重點在於「TrieKit 僅佔 22.5%」，說明 77% 以上的時間耗在到達 Trie 之前的各層 string operation。

---

## 五、根因拆解

### 5.1 數學：為何第六字是臨界點

無聲調拼音模式下，每個音節產生 5 個聲調變體。`assignNodes` 對每個幅節長度 (1..maxSegLength) 都做笛卡爾積展開：

```
1 音節: 5^1 = 5
2 音節: 5^2 = 25
3 音節: 5^3 = 125
4 音節: 5^4 = 625
5 音節: 5^5 = 3,125
6 音節: 5^6 = 15,625
─────────────────────────
單次 assignNodes 總查詢 ≈ 19,530（maxSegLength=6）
若 maxSegLength=10: 5^1 + ... + 5^6 ≈ 24,405
```

第 5 字時約 3,905 次，尚在 250ms microhang 邊緣；第 6 字時躍升至 24,405 次，直接進入 severe hang（7.51s）。

### 5.2 每筆查詢的隱藏成本

Phase 41-45 優化了 Trie 單次查詢速度，但未降低「到達 Trie 之前的 string operation 稅」。Instruments 顯示每筆查詢的實際時間分布約為：

| 階段 | 估算佔比 | 主要開銷 |
|------|---------|---------|
| `GramQueryCacheKey` 雜湊（`[String]` key） | ~15% | String hashing + grapheme breaking |
| `LMInstantiator.Config` 雜湊（LRU fingerprint） | ~5% | Config 含大量 String，hash 昂貴 |
| `Dictionary<String, *>` lookup（LRU cache, user data） | ~25% | String hash + compare + NFC |
| `Sequence.starts(with:)`（TrieKit prefix match）| ~15% | String grapheme iteration |
| `TextMapTrie.getNodes`（實際 trie traversal）| ~22% | Node 遍歷 |
| ARC / retain-release | ~8% | 臨時物件生命週期 |
| 其他 | ~10% | DateTime filter、排序、去重 |

**關鍵發現**：`GramQueryCacheKey` 雖然已預先計算 hash（Phase D 最佳化），但 `[String]` 作為 Dictionary key 時，Swift 仍需對每個 String element 執行 hash + compare。更甚者，`LMInstantiator.Config` 在每次 `unigramsFor` 都重新計算 hash 作為 LRU fingerprint，而 Config 包含數十個 String/Enum 欄位。

### 5.3 為何 Gamma（batch map wrapper）無效

Gamma 嘗試在 InputHandler 層以 `keyArrays.map { lookupHub.grams(for: $0) }` 批次包裝，但 Instruments 證實：

- `LookupHub.grams(for:)` 僅出現在 84% 樣本中
- 真正佔時的 string operation 發生在 `grams(for:)` **內部**的 `unigramsFor` → `Dictionary` lookup → String hash/compare
- 簡單的 map 包裝無法減少 LM 層內部的 string operation 次數

因此 Gamma 必須以「減少總查詢次數」或「降低每筆查詢的 string cost」為目標，而非僅包裝閉包介面。

---

## 六、與既有假設的對照

| 既有假設 | Instruments 驗證結果 |
|---------|---------------------|
| 瓶頸在 TrieKit 索引查詢 | ❌ **否**。TrieKit 僅佔 22.5%，string operation 佔 38.8% |
| LRU cache 已解決重複查詢 | ⚠️ **部分**。24K 次查詢中大量為首次查詢（cache miss），且 cache key 本身的 hash 也是成本 |
| `GramQueryCacheKey` 預先 hash 已最佳化 | ⚠️ **部分**。單一 key 的 hash 已快取，但 `[String]` Dictionary 仍需逐 element hash/compare |
| Batch API（Gamma）可減少開銷 | ❌ **否**。單純 map wrapper 不減少 LM 內部 string operation |
| 問題在於「查詢次數過多」 | ✅ **是**。24K 次 × 每筆 string tax = 秒級凍結 |

---

## 七、建議方向（供下一 Phase 評估）

### 方向 A：減少查詢次數（最高 ROI）

**A-1：Typewriter 只插入最可能單一聲調（Omega-2）**
- 讓 Typewriter 在無聲調模式下只產生一個「最可能」聲調讀音（如輕聲或第一聲），而非 5 個變體
- Homa DP 的上下文校正機制會自動選出正確組合
- 可將查詢量從 24K 降回 ~6,000（6 音節 × 1 聲調）
- **風險**：若 Homa 無法由上下文消歧，可能降低選字準確度；需 A/B 測試

**A-2：限制無聲調模式的聲調變體數量**
- 非全 5 聲調，而是僅展開「常見 2~3 聲調」（如 1 聲 + 輕聲 + 原輸入聲調）
- 查詢量從 5^N 降為 3^N（6 音節時 3^6 = 729，總和約 1,092）
- **風險**：可能遺漏罕見讀音，但對日常輸入影響極小

**A-3：動態 `maxSegLength` 縮減（Eta 復活）**
- 高聲調密度（即 `.multipleKeys` 數量多）時縮減 `maxSegLength`
- 例如 6 音節時 maxSegLength 從 10 降至 6，查詢量從 24,405 降至 19,530
- **風險**：Eta 原設計已放棄，因會限制未來「不完全拼寫」設計空間；但若僅針對無聲調模式，影響較小

### 方向 B：降低每筆查詢的 string cost

**B-1：`LMInstantiator.Config` hash 快取**
- Config hash 在單次 `assignNodes` 內不變，應快取而非每次 `unigramsFor` 重新計算
- **預期收益**：每次 `unigramsFor` 省一次 Config hash（~5%）

**B-2：TrieKit keyArray 改用 `[UInt8]` / `Data` 而非 `[String]`**
- 拼音 key 僅含 ASCII（a-z, 1-5），理論上不需要 Unicode NFC/grapheme 語意
- 若 keyArray 以 `[UInt8]` 或自訂 `ASCIIString` 表示，可消除 NFC/hash/compare 開銷
- **影響範圍**：Homa `PossibleKey`、TrieKit API、LMInstantiator 全層
- **預期收益**：理論上極大（string operation 38.8% → 接近 0%）
- **歷史教訓**：⚠️ **此前對注音讀音做過類似的 encode/decode（加密/壓縮）嘗試，結果在 hot path 額外增加的 transformation 開銷遠大於省下的 string operation 成本**。Swift String 的 UTF-8 底層已經相當快，額外一層 encode/decode 反而使情況更糟。B-2 若涉及 run-time 轉換，極可能重蹈覆轍。
- **可行前提**：必須是「從源頭就儲存為 UInt8，全程無 run-time 轉換」，而非「輸入時 String → UInt8 → 查詢 → 再轉回」。這意味著 TextMap 建構階段就要改格式，影響範圍極大。

**B-3：`LMCoreEX` 改用 `Set<UInt64>` 或完美雜湊**
- 使用者資料 `rangeMap` / `temporaryMap` 目前以 `String` 為 key
- 若改以 pre-hashed `UInt64` 為 key，可消除 user data lookup 的 string iteration
- **預期收益**：`LMCoreEX.unigramsFor` 佔 9.7%，其中 string iteration 為主要 leaf

### 方向 C：非同步化（最不建議）

- 將 `assignNodes` 移至 background thread
- **風險**：IMK 輸入法架構要求主執行緒同步回應；background 化會引入 race condition 與狀態同步複雜度

---

## 八、結論

Phase 46（Omega-1/Alpha/Beta/Zeta）成功移除了 `&` 字串編碼並優化了單次查詢的 LRU cache，但**無法解決「查詢次數 × 每筆 string operation 稅」的乘積效應**。

Instruments trace 明確指出下一個最佳化目標應是：

1. **優先評估方向 A-1（Omega-2）或 A-2**：減少無聲調模式的聲調變體數量，從源頭降低查詢量。這是風險最低、ROI 最高的路徑。
2. **方向 B-2 暫不執行**：歷史經驗證明 run-time encode/decode 會引入更大開銷；若要做到「全程 UInt8 無轉換」，需改動建構管線與所有 LM 介面，成本過高。
3. **方向 B-1（Config hash 快取）與 B-3（LMCoreEX key 改用 UInt64 hash）**可作為輔助最佳化，在 A-1/A-2 實施後評估剩餘瓶頸時再考慮。
4. **Gamma 暫不復活**：除非 LookupHub/TrieKit 實現真正的多 keyArray 共享索引批次查詢。

建議下一 Phase（Phase 47）以「無聲調拼音查詢量削減」為主軸，先以 Omega-2 或變體數限制做原型，搭配 Instruments 再次驗證改善幅度。

---

## 九、補充：無解死局分析（2026-04-25 後續討論結論）

### 9.1 Omega-2 為何是死局

Omega-2（Typewriter 只插入最可能的單一聲調，依賴 Homa DP 校正）的根本問題在於：**沒有人能保證被剪枝的聲調變體恰好不是 pathfinder 需要的最頻繁 gram 的讀音**。Homa DP 的上下文消歧能力基於「所有可能路徑都可被查詢」，一旦在輸入層面預先剪掉某個聲調變體，該變體對應的 gram 將永遠不會進入組字圖，pathfinder 再強也無從校正。

這不是實作瑕疵，而是資訊論上的限制：若輸入系統在組字前丟棄了聲調資訊，組字器就無法憑空恢復它。

### 9.2 指數增長是數學宿命

Homa `assignNodes` 的查詢量公式為 `5^1 + 5^2 + ... + 5^N`（無聲調拼音，N 音節）：

| N | 總查詢量 | Instruments 實測 hang |
|---|---------|---------------------|
| 4 | ~780 | — |
| 5 | ~3,905 | 274 ms（microhang） |
| 6 | **24,405** | **1.36 s → 7.51 s** |

Phase 41-46 的單次查詢最佳化（LRU cache、移除 `&` 拼接、`PossibleKey` 結構化）只是把臨界點從「N=4」推到了「N=5」，無法改變 `O(5^N)` 的指數本質。無論單次查詢多快，24,405 次 × 任何非零開銷 = 秒級凍結。

### 9.3 Homa 的設計原罪

Homa Assembler 的核心假設是「每個位置有一個確定的 key」。Omega-1 只是把「一個位置有多個 key」的情況從 LMInstantiator 的 `&` 字串 hack 搬到了 Homa 內部的笛卡爾積展開，但「一個位置有多個 key」這個事實本身並未消失。

這裡有一個鮮明的對比：只要使用**完整讀音輸入**（無 partial matching），目前 DAG-DP 即使 composition buffer 內塞上幾千個讀音都能正常組句子。因為每個位置只有 1 個 key，查詢量與音節數呈線性關係 `O(N)`，而非指數關係。

| 模式 | 每位置 key 數 | N 音節總查詢量 | 能否組長句 |
|------|-------------|--------------|-----------|
| 完整注音 / 有聲調拼音 | 1 | `~N`（線性） | ✅ 幾千音節也沒問題 |
| 無聲調拼音 | 5 | `5^1 + ... + 5^N`（指數） | ❌ 6 音節即 severe hang |

無聲調拼音輸入長句，本質上是「在不確定每個音節聲調的情況下做全局最佳化」。這個問題的計算複雜度遠高於「每個音節聲調已確定」的注音輸入。Homa 的 DP 架構可以處理它，但前提是查詢次數必須在可接受範圍內。

**結論：如果不接受組字區長度限制，無聲調拼音輸入長句的卡頓確實是「這個需求本身的宿命」。**

### 9.4 唯一務實的出路：「一邊吃一邊屙」

Typewriter 已存在 `commitOverflownComposition` 機制（`InputHandler_CoreProtocol.swift:954`），俗稱「蒼蠅一邊吃一邊屙」：

- 當 `assembler.length > compositorWidthLimit`（目前為 20）時，從前端逐 node 移除並自動提交
- 目前只在 `clientMitigationLevel >= 2`（黑名單 App / Electron / security hardened）時啟用
- 用途是限制浮動組字窗尺寸

**建議調整**：

1. 拼音輸入模式（特別是無聲調拼音）啟用類似的溢出提交機制
2. `compositorWidthLimit` 從 20 降到 5（或新增獨立的 `pinyinCompositorWidthLimit = 5`）
3. 這樣組字區永遠不超過 5 音節，查詢量封頂在 ~3,905 次，不會觸及 severe hang

**為何這比 Omega-2 更可靠**：

- Omega-2 是「猜一個聲調，賭 pathfinder 能救回來」——準確度無法保證
- 「一邊吃一邊屙」是「前面的字已經 commit 出去了，後面的字再慢慢組」——準確度由用戶自己控制（按空格或標點手動斷句）
- 不改動 Homa / TrieKit / LMInstantiator 任何核心邏輯，僅在 Typewriter 層調用既有機制

### 9.5 Phase 47 實際採用的解法：動態 `maxSegLength`

Phase 47 未採用「一邊吃一邊屙」，而是選擇了更精細的**動態 `maxSegLength`** 方案：

1. **`Homa.PossibleKey` 新增 `count` 與 `isMultiple` 屬性**：提供快速判斷某位置是否包含多個聲調變體的能力
2. **`assignNodes` 動態縮減掃描半徑**：當 `rangeOfPositions` 內存在 `isMultiple` 的 key 且 `maxSegLength > 4` 時，將 `maxSegLength` 就地調整為 4
3. **效果**：
   - 完整注音 / 有聲調拼音（無 `.multipleKeys`）：`maxSegLength` 保持 10，長詞（如「巴布亞新幾內亞」6 字）完全不受影響
   - 無聲調拼音（有 `.multipleKeys`）：每次插入新 key 的最大新增查詢量封頂在 780 次（5^1 + ... + 5^4），不會觸及 5^5 = 3,125 的 severe hang 臨界點
   - 用戶可以繼續輸入長句，只是組字時不會嘗試組出超過 4 個音節的詞

4. **優勢**：
   - 不改動 Typewriter / Session 層的任何邏輯
   - 不需要自動提交打斷用戶輸入
   - 對注音模式零影響
   - 改動量極小（僅 Homa 內部兩處）

這是一個「承認限制、順勢而為」的解法，而不是「對抗數學」的解法。
