# Phase 43 手術前調查報告：AfterPhase42 的 Typewriter 起點殘餘熱區

> 調查日期：2026-04-24
> 研究範圍：只看 Typewriter 起點與其依賴鏈（Tekkon / Homa / LangModelAssembly / TrieKit / QueryBuffer）
> 研究員：GPT-5.3-Codex
> 依據 trace：vChewing-macOS/tmp/TestResult_AfterPhase42.trace
> 文檔狀態：PreResearch（可直接作為 Phase 43 實作依據）

---

## 一、範圍界定（嚴格過濾）

本報告只採納下列「從 Typewriter 出發」的 call chain：

1. `BPMFFullMatchTypewriter.handle`
2. `BPMFFullMatchTypewriter.composeReadingIfReady`
3. `BPMFFullMatchTypewriter.consumeReadingInputIfNeeded`
4. `BPMFFullMatchTypewriter.performPinyinAutoChopIfNeeded`
5. 其向下依賴鏈：`Homa.Assembler.*`、`LMAssembly.LMInstantiator.*`、`VanguardTrie.TextMapTrie.*`、`QueryBuffer.*`、`Tekkon.*`

明確不納入：IMK / SessionCtl / AppKit / NSXPC / menu / tooltip / candidate window 等 UI 與框架噪訊。

---

## 二、AfterPhase42 觀測摘要（僅 Typewriter 相關）

從 `AfterPhase42` cpu-profile 匯出後，Typewriter 鏈條中最顯著的符號頻次如下（symbol 出現次數，非 cycles 直接占比）：

1. `LMAssembly.LMInstantiator.mergedAlternativeBucketUnigrams(for:)`：24
2. `specialized QueryBuffer.removeExpiredEntriesLocked(now:)`：15
3. `specialized QueryBuffer.set(hashKey:value:)`：11
4. `VanguardTrie.TextMapTrie.candidateNodeIDsForChoppedColumns(_:)`：10
5. `VanguardTrie.TextMapTrie.getNodeIDsForKeyArray(_:longerSegment:)`：7
6. `LMAssembly.LMInstantiator.factoryUnigramsFor(key:keyArray:column:)`：5
7. `specialized visit #1 in LMAssembly.LMInstantiator.expandAlternativeKeyArrays(from:)`：5
8. `BPMFFullMatchTypewriter.performPinyinAutoChopIfNeeded`：5

可見 Phase 42 已壓低舊熱點，但 Typewriter 鏈上仍集中在三段：

1. LMInstantiator 的 alternatives 合併與展開。
2. Trie 查詢時的 QueryBuffer 清理與寫入。
3. chopped path 的候選匹配與節點提取。

---

## 三、直接證據（Typewriter 起點鏈）

在 trace 可重複看到同一主鏈：

`BPMFFullMatchTypewriter.composeReadingIfReady`
→ `LMAssembly.LMInstantiator.unigramsFor`
→ `LMAssembly.LMInstantiator.mergedAlternativeBucketUnigrams`
→ `LMAssembly.LMInstantiator.factoryUnigramsFor`
→ `VanguardTrie.TextMapTrie.getNodes`
→ `QueryBuffer.set`
→ `QueryBuffer.removeExpiredEntriesLocked`

同時存在另一條並行支線：

`BPMFFullMatchTypewriter.performPinyinAutoChopIfNeeded`
→ `Tekkon.Composer.pinyinAutoChopResult`
→ `LMAssembly.LMInstantiator.hasUnigramsFor / unigramsFor`

這表示目前卡頓仍是「Typewriter 觸發查詢頻率」和「LM + Trie 內部每次查詢成本」的乘積問題，而非 UI 事件噪訊主導。

---

## 四、根因判斷（Root Causes）

### RC-1：`mergedAlternativeBucketUnigrams` 在單次輸入流程中重入頻率仍高（最高影響）

現象：`mergedAlternativeBucketUnigrams(for:)`、`expandAlternativeKeyArrays(from:)`、`factoryUnigramsFor(...)` 在同一段 keydown/compose 流程反覆出現。

判讀：

1. alternatives 展開與合併雖已優化，但仍有重複展開與中間容器生命週期成本。
2. `joined(separator:)` 仍是全域高頻符號，代表 key 組裝仍在高壓路徑。

### RC-2：`QueryBuffer` 清理策略與鎖粒度仍在熱路徑放大成本（高影響）

現象：`QueryBuffer.set` 與 `removeExpiredEntriesLocked(now:)` 經常同框出現，且後者在 Typewriter 主鏈中持續出現。

判讀：

1. 清理操作仍有「寫入即順帶掃描」的特徵。
2. 這會讓 Trie 查詢成本從「查詢」擴展成「查詢 + 清理」，在高頻 keydown 下放大延遲尾端。
3. 若多個屬性共享同一把鎖，會把彼此無關的讀寫序列化，額外放大尾延遲。

### RC-3：chopped path 仍有非必要節點解析與匹配重入（中高影響）

現象：`candidateNodeIDsForChoppedColumns`、`getNodes`、`parsedEntries`、`parseValueLine` 仍穩定出現在 Typewriter 鏈。

判讀：

1. Phase 42 已改善字串層，但仍有可再壓縮的節點讀取與查詢去重空間。
2. 在 alternatives 多分支時，這段成本會疊回 RC-1。

### RC-4：auto-chop 支線仍會觸發查詢鏈（中影響）

現象：`performPinyinAutoChopIfNeeded` 仍在熱鏈中可見，並透過 `hasUnigramsFor / unigramsFor` 進入 LM。

判讀：

1. 目前比重已低於 RC-1/2，但仍是查詢重入來源之一。
2. 適合在 Typewriter 入口加嚴觸發條件，避免不必要查詢。

---

## 五、Phase 43 修復方案（只針對 Typewriter 與依賴）

### P43-A：`QueryBuffer` 重構為「多 NSMutex 分屬性保護 + 限額漸進清理」（最高優先）

目標：把過期清理從每次 `set` 的重操作降為可攤提成本。

建議：

1. `set` 僅在達到時間門檻時啟動清理。
2. 單次清理加上 removal budget（例如每次最多清掉 N 筆）。
3. 移除 QueryBuffer 內部 `NSLock`，改用 `NSMutex`。
4. QueryBuffer 內每個 property 使用各自的 `NSMutex` 保護，不得以單一 mutex/lock 覆蓋全部 properties。
5. 清理與查詢路徑維持最小必要鎖定區間，避免長時間鎖內掃描。

預期：明顯壓低 `removeExpiredEntriesLocked(now:)` 在 Typewriter 主鏈中的可見度。

### P43-B：`mergedAlternativeBucketUnigrams` 增加「單輪查詢作用域快取」（高優先）

目標：在一次 compose/triage 內，避免相同 keyArray 重複展開與合併。

建議：

1. 以 `keyArray + column + strategy` 建立短生命週期 memo。
2. 對 `expandAlternativeKeyArrays(from:)` 結果做 request-scope reuse。
3. 對 `joined key` 增加局部 cache，減少重複字串拼接。

預期：降低 `mergedAlternativeBucketUnigrams`、`expandAlternativeKeyArrays`、`joined(separator:)` 熱點。

### P43-C：TextMap chopped 查詢增加「同輪去重與快取命中率」優化（高優先）

目標：避免同一 key 組合在短時間內多次走 `getNodes -> parse`。

建議：

1. 把查詢鍵正規化後再入 QueryBuffer，提升命中。
2. 將已解析 node entries 的短期緩存重用到同輪 alternatives 分支。
3. 僅在必要時進入 `parsedEntries`。

預期：降低 `candidateNodeIDsForChoppedColumns` 與 `getNodes` 相關重入。

### P43-D：Typewriter auto-chop 入口再加防抖條件（次優先）

目標：讓 `performPinyinAutoChopIfNeeded` 只在必要時觸發 LM 查詢。

建議：

1. 對同一 inputText + parser 狀態的連續事件做短時間短路。
2. 將 `hasUnigramsFor` 檢查與上次結果比對，避免重入。

預期：減少支線查詢放大主鏈壓力。

---

## 六、驗收標準（DoD）

### 效能驗收（Typewriter-only）

1. `QueryBuffer.removeExpiredEntriesLocked(now:)` 在 Typewriter 鏈的 symbol 出現次數顯著下降。
2. `mergedAlternativeBucketUnigrams(for:)` 與 `expandAlternativeKeyArrays(from:)` 出現次數下降。
3. `factoryUnigramsFor` 下游 `getNodes` 重入次數下降。
4. 連續拼音免聲調長句輸入時，主觀卡頓再收斂一級。

### 正確性驗收

1. 候選集合與排序語義不回歸。
2. alternatives 展開結果完整性不回歸。
3. auto-chop 行為不產生漏切或錯切。

---

## 七、結論

Phase 43 的主要任務不是再打 UI 或 IMK 噪訊，而是把 Typewriter 起點鏈中的兩個殘餘成本做掉：

1. `LMInstantiator` 單輪重入成本。
2. `QueryBuffer` 熱路徑清理成本。

只要這兩點落刀成功，`TextMapTrie` chopped 查詢的剩餘成本才會真正被壓到可接受範圍，長句免聲調輸入延遲才會再往下收斂。