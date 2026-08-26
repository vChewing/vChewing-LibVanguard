# Phase 158 研究報告：POM 查詢彈性化與 Homa n-gram 體系（POM Query Tolerance & Homa N-Gram System）

> 研究任務（不施工）。命名仿 P148／P155 研究報告，僅 Phase 編號差異。
> 產出：本報告＋後續 Phase 規劃（S1／S2／S3／S4，如 P155 規劃出 P156／P157 之形式）。

---

## 一、結論速覽

1. **方向一（POM optional 容錯查詢 API）——可行、且為後續一切的解鎖前題。**
   POM 目前只有「exact-match ngramKey 查詢＋`alternateKeys` 等值/後綴比對」兩級；Furious 模式的聲調桶
   （`makeToneInsensitiveVariants` 首位＝無調形）與不完整讀音會使兩級皆落空，造成「完全查不到」。
   建議引入 **tone-insensitive prefix 查詢模式**（current／prev／anterior 三位置的讀音各自做
   「去聲調＋前綴」比對，values 仍 exact），成本與既有 `alternateKeys` 全掃描同級（容量 ≤500）。
   此 API 同時是 P151 待決 T1（copilot 組句套用 POM，設計已定稿）的啟用前題。

2. **方向二（POM 資料作 Homa bigram／trigram 來源）——資料就緒、注入點明確，建議以「外源開關＋bigram 先行」。**
   POM 的 ngramKey 本身就是三層結構（anterior&previous&head），perception 內每候選都帶 count／timestamp，
   天然就是 bigram／trigram 語料。注入點＝`LMInstantiator.unigramsFor`（組字器查詢的唯一咽喉）；Homa 的
   選字窗既有「排除帶 `previous` 的 grams」機制（`Homa_CandidateAPIs_FetchAndApply.swift:40`），POM 衍生
   bigram 不會污染候選窗、只影響路徑選取。需補：外源開關（UserDef＋Config＋syncPrefs＋l10n 四語）、
   unigramsFor 快取指紋納入 POM 世代計數、分數映射取捨。

3. **方向三（Homa trigram 支援）——引擎端可行且代價遠低於直覺，但「資料從哪來」才是真問題。**
   **關鍵發現**：Homa 的 DP 已是 1D、bigram 本就採用「最佳路徑前驅」近似（`Homa_PathFinder.swift:74-76`），
   trigram 只要再往回多看一跳（`parent[i - parent[i].segLength]`）即可、**DP 結構零改動**。真正的瓶頸是：
   現行 factory 詞典**沒有任何 bigram 資料**（實測 `VanguardFactoryDict4Typing.txtMap` 無第四欄）、且
   LMAssembly 的轉換層**把 trie 的 `previous` 欄直接丟棄**（`LMInstantiator_TextMapExtension.swift` 兩處
   `makeFactoryUnigrams`）——bigram 鏈路在生產環境是**休眠狀態**。trigram 支援若沒有資料源，就是第二條
   休眠鏈路；目前唯一現成的 trigram 語料正是 POM 本身。故合理順序：S1（容錯查詢）→ S2（POM→bigram 餵入）
   → S3（Homa trigram 支援＋POM→trigram 餵入）。

4. **方向四（DAG-DP 自動選取 vs override 錨定）——文書整理完成，無施工需求。**
   引擎端 n-gram 影響走 `Node.getScore(previous:)` → `.withTopGramScore` 自動覆寫 → 路徑層 DP 選取，
   屬「軟性、隨路徑、可被重切分推翻」；對照 POM 建議 API 的 `.withSpecified` 硬錨定（使用者顯式選字，
   `isExplicitlyOverridden = true`）。兩者不衝突，前者正是 DevReq 所述「更強靈活性」的來源。

5. **方向五（Typewriter 層「套用 POM 記憶」的部分可省略性）——部分紅利、非全額。** POM 導入 n-gram 體系後，
   「自動段」（solidify 後自動 apply、候選窗自動置頂）可交由 n-gram 承擔、刪掉大量 override／retokenization
   ／bleaching 複雜度；但「顯式段」（使用者當下選字釘住＋unigram 記憶＋切分深度修正＋候選窗置頂 UX＋
   寫入側觀察）**不能省**——unigram 記憶無上下文無法以 n-gram 表達、顯式選字需要確定性而非統計傾向。
   正確紅利＝「自動的那半沉進引擎、顯式的那半脫掉歷史包袱」。詳見 §八。

6. **Phase 規劃**：S1＝P159（POM 容錯查詢 API＋T1 copilot POM 套用，兩 IME 倉）、S2＝P160（POM→bigram
   餵入＋外源開關，兩 IME 倉）、S3＝P161（Homa trigram 支援＋Trie 格式延伸＋POM→trigram，三倉鏡像）、
   S4＝P162（Typewriter POM apply 路徑瘦身，可選收尾）。詳見 §九。

---

## 二、任務命題與方法

### 2.1 P158 的四項調研命題（DevReq 原文要旨）

1. POM 模組是否需要引入一套 optional 查詢 API、允許 current／prev／anterior 的讀音「全都是
   prefix-matching」的查詢——不至於在 Furious 模式、以及 assembler 出現 key bucket 的時候「完全查不到
   POM 的內容」。
2. POM 模組的資料是否可以作為一個可靠的 bigram／trigram 來源、供 Homa 引擎自動爬取；此專屬來源可引入
   外源開關（有人不想用臨時記憶）。
3. Homa 目前僅支援 bigram，檢討是否可以順勢實作 trigram 支援。
   - 注意：Homa 的 bigram／trigram 對 previous／anterior 的內容目前沒有讀音限定（沒那麼多現成語料）；
     若讀音限定機制有實作價值，記入報告。
4. Homa 算法自動 Assemble 過程讀到的 bigram（及未來的 trigram）不是以 override 形式被 node 錨定、
   而是 DAG-DP 路徑自動選取，因此有更強靈活性——記錄此性質。

### 2.2 方法

- 通讀 POM 引擎（`vChewing_LangModelAssembly/Sources/LangModelAssembly/SubLMs/LXPerceptor.swift`）、
  POM 對外介面（`LMInstantiator_POMRepresentable.swift`）、Typewriter 的 POM 消費端
  （`InputHandler_CoreProtocol.swift` 的 `retrievePOMSuggestions`／`fetchPOMSuggestion`）、
  Furious 固化路徑（`InputHandler_FuriousResegmentation.swift`）。
- 通讀 Homa 的 Gram／Node／PathFinder／Assembler（`Homa_Gram.swift`、`Homa_Node.swift`、
  `Homa_PathFinder.swift`、`Homa_Assembler.swift`、`Homa_CandidateAPIs_FetchAndApply.swift`）。
- 通讀 TrieKit 的詞條格式與查詢鏈路（`VanguardTrieIO.swift`、`VanguardTrie_Core.swift`、
  `TrieTextMap_Core.swift`、`TrieProtocol.swift`）與 LMAssembly 轉換層（`LMInstantiator.swift`、
  `LMInstantiator_TextMapExtension.swift`、`SubLMs/lmCoreEX.swift`）。
- 實測現行 factory 詞典的欄位結構（`VanguardFactoryDict4Typing.txtMap`），確認 bigram 資料存在與否。
- 追蹤 POM 容錯需求在 Furious 管線中的具體失效機制（聲調桶代表鍵＝無調形、LM 回傳具體調形）。

---

## 三、現況事實核對

### 3.1 POM（LXPerceptor）資料結構與查詢鏈路

- 儲存：`mutLRUMap: [String: KeyPerceptionPair]`＋LRU 順序表 `mutLRUKeySeqList`，容量預設 500
  （`LXPerceptor.swift:49-57`）。
- ngramKey 格式：`(anteReading,anteValue)&(prevReading,prevValue)&(headReading,headValue)`，
  parser 為 `parseDelimitedPerceptionKey`（`LXPerceptor.swift:736-783`）——**已是三層（trigram 級）結構**。
- 查詢入口：`fetchSuggestion(assembledResult:cursor:timestamp:)`（`LXPerceptor.swift:299-347`）：
  1. 以 `assembledResult.generateKeyForPerception(cursor:)`（`Homa_GramInPath.swift:368-454`）生成
     ngramKey——讀音取自組句結果 gram 的具體 keyArray（`joinedCurrentKey(by: "-")`）；
  2. exact lookup `mutLRUMap[key]`；
  3. 落空後掃 `alternateKeys(for:)`（`LXPerceptor.swift:828-921`）——全 LRU 線性掃描，比對條件為
     **等值**（`compareContextPart`，`LXPerceptor.swift:785-826`，含「候選為原始後綴」的 suffix 比對）＋
     head 段集合比對；**無任何聲調容錯**。
- 候選提取：`getSuggestion(key:timestamp:)`（`LXPerceptor.swift:350-423`）只保留**最高分**候選（
  `overrideScore > currentHighScore` 時重置陣列），分數由 `calculateWeight`（`LXPerceptor.swift:968-1018`）
  給出：閾值 `kDecayThreshold = -13`（:70）、乘數＝野獸常數 `kWeightMultiplier`（實算 ≈ 0.171）、
  視窗 8 天（急速遺忘 0.5 天）。新鮮記憶分數 ≈ −0.171，隨時間衰減至 −12.999 下限。
- 消費端（Typewriter）：`retrievePOMSuggestions(apply:)`（`InputHandler_CoreProtocol.swift:781+`）——
  候選窗排序時把 POM 建議置頂（`generateArrayOfCandidates`，:635-654，須 `fetchRawQueriedCandidatesFromAssembler`
  的 raw 分數過濾 `filterPOMAppendables`，:740-777）；`apply: true` 時以 `.withSpecified`／`.withTopGramScore`
  覆寫組字器節點（:802+）。開關：`prefs.fetchSuggestionsFromPerceptionOverrideModel`；SCPC 模式完全禁用
  （:630-632、:788）。
- Furious 路徑：`solidifyFuriousFrontReading()` 固化後呼叫 `retrievePOMSuggestions(apply: true)`
  （`InputHandler_FuriousResegmentation.swift:95`）；**α 路徑 `solidifyAbbreviatedFrontReading()` 不呼叫 POM**
  （:102-113，POM 完全缺席）。

### 3.2 POM 在 Furious 模式「完全查不到」的機制

1. **聲調桶代表鍵＝無調形**：Furious 固化插入 `[.multipleKeys(makeToneInsensitiveVariants(zhuyin))]`
   （`Tekkon_Utilities.swift:12-22`，`[無調, 一聲…五聲]`）；`unigramsForWithAlternatives`
   （`LMInstantiator.swift:1104+`）以 `.first`（**無調形**）當 keyChain 代表鍵查詢，但回傳 grams 的
   keyArray 是 trie 命中的**具體調形**（factory「&」chopped 路徑）。
2. **POM 鍵為具體調形**：`generateKeyForPerception` 自組句結果取讀音（如 `(ma4,嗎)`）；若使用者先前在
   其他調形（或無調形 user phrase）下記憶過同一語境，exact lookup 與 `alternateKeys`（等值比對）雙雙落空。
3. **不完整讀音**：Furious 的簡拼前綴（如 `z`）與 α 整詞路徑產生的讀音，POM 鍵沒有對應條目，
   等值比對無從命中。
4. 結果：POM 對 Furious 使用者形同虛設——與 DevReq 所述「完全查不到」一致；`fetchPOMSuggestion` 的
   `alternateKeys` 只為「切分差異」（短詞／長詞互替）設計，未涵蓋調形與前綴容忍。

### 3.3 Homa bigram 鏈路全貌——**生產環境休眠**

- 引擎端完整支援 bigram：
  - `Homa.Gram.previous: String?`，**純文字值、不含讀音**（`Homa_Gram.swift:9,62` 註明）。
  - `Node.getScore(previous:)`（`Homa_Node.swift:211-255`）：在節點 gram 陣列內找
    `gram.previous == previous && gram.current == currentValue` 的最高權重 bigram，若高於現況則
    `.withTopGramScore` 自動覆寫——**DAG-DP 路徑層自動選取**，非節點錨定。
  - PathFinder 1D DP：`getScore(previous: parent[i]?.gram?.current ?? "")`（`Homa_PathFinder.swift:74-76`）
    ——bigram 前驅即**最佳路徑**的緊鄰前驅值（近似，非逐邊精確）。
  - 選字窗排除 bigram：`Homa_CandidateAPIs_FetchAndApply.swift:40` `guard gram.previous == nil`。
- 詞典格式支援 bigram：型別 C `value\tprobability\ttypeID[\tprevious]`（`VanguardTrieIO.swift:316-323`）、
  `Trie.Entry.previous`（`VanguardTrie_Core.swift:149-188`）、`Trie.queryGrams` 亦傳播 previous
  （`TrieProtocol.swift:247`）。
- **但 LMAssembly 轉換層把 `previous` 丟棄**：`makeFactoryUnigrams(entries:)`
  （`LMInstantiator_TextMapExtension.swift:419-457`）與 `makeFactoryUnigrams(queriedGrams:)`
  （:460-498）建構 `Homa.Gram` 時一律不帶 previous。
- **現行 factory 詞典無 bigram 資料**：實測 `vChewing-VanguardLexicon/Build/Release/vanguard-textmap/
  VanguardFactoryDict4Typing.txtMap`（44 萬行），欄位數分布為 1／2／3，**無任何 ≥4 欄的列**（第四欄
  previous 欄位零使用）。
- 結論：**Homa 的 bigram 機制是「引擎備好、資料缺席、轉換層斷鏈」的三重休眠**。這直接影響方向三的
  判讀——「順勢實作 trigram」若只是把休眠鏈路從 2-gram 變 3-gram，價值有限；真正的資料源只能來自 POM。

---

## 四、方向一：POM optional 容錯查詢 API（tone-insensitive prefix）

### 4.1 設計（S1）

在 `LXPerceptor` 新增查詢模式列舉，`fetchSuggestion` 增加可選參數（預設 `.exact`，現行行為零變更）：

```
POMQueryMode:
  .exact                    // 現行：ngramKey 等值 + alternateKeys 等值/後綴
  .toneInsensitivePrefix    // 新增（Furious 推薦）：三位置讀音「去聲調＋前綴」比對
```

- 比對語義（`toneInsensitivePrefix`）：
  - 三位置（head／previous／anterior）各自：stored 讀音在「去除聲調記號」後以 query 讀音（同樣去調）
    開頭（`stored.hasPrefix(query)`）；**values 維持 exact**（讀音才做前綴，符合 DevReq「讀音全都是
    prefix-matching」）。
  - unigram 鍵（無上下文）沿用現行「無上下文即接受」語義（`compareContextPart` 已如此，:791-794）。
  - 保留 `shouldIgnorePerception`（`_` 前綴讀音過濾）與 `threshold`／`calculateWeight` 既有邏輯。
- 實作位置：`LXPerceptor.fetchSuggestion` 加 `matchMode`；容錯路徑＝掃 `mutLRUKeySeqList`（≤500，
  與既有 `alternateKeys` 同級成本）以新 matcher 過濾；候選 keyArray 沿用 `getSuggestion` 的
  `effectiveKeyArray` 語義（:384）。
- 對外介面：`LMInstantiator_POMRepresentable.swift` 的 `fetchPOMSuggestion` 增加對應參數（預設 exact）。

### 4.2 與 T1（copilot 套用 POM）的關係

- P151 已定稿 T1 設計：copilot 組句結果要套用 POM 建議，需要「唯讀 POM 查詢」——把 `fetchPOMSuggestion`
  的提取與 `apply`（`memorizePerception`／`saveCallback`／`failureFlagForPOMObservation`）拆開。
- 但沒有容錯查詢，copilot 組句的讀音（聲調桶代表鍵／不完整讀音）根本查不到 POM——**容錯查詢是 T1 的
  前置條件**。S1 應把兩者併為一體：容錯查詢 API＋T1 的唯讀提取＋copilot 窗置頂 POM 建議＋
  α 路徑 `solidifyAbbreviatedFrontReading` 補上 POM 提取（唯讀，不寫記憶——與「Enter 直遞／高亮預覽
  不寫 POM」的既有政策一致）。
- POM 建議為使用者顯式選字後才寫記憶（P151 永久定案）；容錯查詢僅提高**讀取**命中率，不改變**寫入**
  行為——兩者正交。

### 4.3 成本與風險

- 成本：容錯模式為線性掃描（容量 ≤500），與既有 `alternateKeys` 同級；僅在呼叫端指定時啟用。
- 風險：前綴比對可能過寬（`ma` 匹配所有 `ma*` 聲調記憶）——以「同音節候選聚類為一組、按權重取 top」
  控制；values exact 已擋掉跨詞前綴誤配。
- 測試：LMAssembly POM 測試（tone-insensitive 命中／前綴命中／三位置全前綴）、Typewriter IH 測試
  （Furious 固化後 POM 置頂）。

---

## 五、方向二：POM 資料作為 Homa n-gram 來源

### 5.1 資料就緒度

- POM 每筆 perception＝`(ngramKey, candidate → count/timestamp)`；ngramKey 已含
  anterior&previous&head 三層讀音＋值。作 bigram 語料：`P(candidate | prevValue)`；作 trigram 語料：
  `P(candidate | prevValue, anteValue)`——**POM 的鍵空間天生就是 n-gram 形態**（`generateKeyForPerception`
  `maxContext: 3` 已與之對齊）。
- 記憶事件＝使用者顯式選字（`memorizePerception` 呼叫點僅在顯式確認路徑）——品質高於隨意統計。

### 5.2 注入點與機制（S2）

- 注入點＝`LMInstantiator.unigramsFor`（組字器 `GramQuerier` 的唯一咽喉，`LMInstantiator.swift:647-887`
  與 `unigramsForWithAlternatives` :1104+）：對 head keyChain，以 POM 的 head 讀音（exact 或容錯）取回
  perception，將「candidate ＋ previous 值」展開為 `Homa.Gram(keyArray: 具體鍵, value: candidate,
  previous: prevValue, probability: 權重)` 附加進 rawAllUnigrams（consolidate 前）。
- 組字器側零改動：bigram 語義（value-only previous）由 `Node.getScore(previous:)` 直接消費；
  **選字窗零污染**（`Homa_CandidateAPIs_FetchAndApply.swift:40` 排除帶 previous 的 grams）。
- 快取失效：`unigramsFor` 的 LRU cache 有 config＋factory 世代指紋（`LMInstantiator.swift:674-679`）；
  POM 世代計數（`mutLRUMap` 變更時遞增的計數器）需併入指紋，否則新記憶不反映在已快取的查詢。
- 外源開關：新 `UserDef`（暫名 `kPOMAsNGramSourceEnabled`）＋`Config` 欄位＋`syncPrefs`
  （`LMInstantiator.swift:247-260`）＋l10n 四語 description（功能中性命名，仿 `kKeyboardParser4Pinyin`
  先例）；預設建議 off（DevReq 明言「可能有些人並不想使用臨時記憶的功能」）。

### 5.3 分數映射取捨

- POM `calculateWeight` 輸出 ≈ [−0.171 … −12.999]；factory 詞典權重為負的對數概率（約 −0.x … −11）。
  兩者在 `filterPOMAppendables`（`InputHandler_CoreProtocol.swift:772`：`suggestedUnigram.probability <
  rawScore → 丟棄`）已有直接比較先例，**量級相容**。
- 但新鮮記憶（≈ −0.171）會壓過幾乎所有詞典分數——作為「使用者偏好」這是目的，作為 n-gram 來源需防
  過度支配：S2 落地時可選擇（a）直接注入＋仰賴 8 天衰減自限；（b）施加天花板（如 clamp 至 −0.5）；
  （c）以 `log(count/totalCount)` 重算分數。建議先 (a) 搭配測試鎖定，視實測再收斂。

### 5.4 讀音限定機制（DevReq 指定記錄）

- 現況：`Homa.Gram.previous` 為 value-only，無讀音限定（`Homa_Gram.swift:9`）；trie 第四欄 previous
  同為純文字值（`VanguardTrieIO.swift:321`）。
- POM 語境是 `(reading, value)` 對——餵入 value-only 的 previous 會丟失讀音精度，多音字（同字異音）
  場景可能誤配（「行」xíng／háng 同字、不同讀音，value-only 無法區分）。
- **實作價值評估**：若 Homa 增設「帶讀音的 previous」（`Gram.previous` 改為 (reading,value) 或加
  `previousReading` 欄位），POM 可餵入讀音限定 bigram，精度更高；但這是一次引擎層 API 變更（影響
  `getScore`／`selectOverrideGram`／Codable／全部 bigram 消費點與測試），應作為獨立評估項（可併入 S3
  討論）。**記錄為「有價值、但需獨立引擎更動」**，不併入 S2 初版。

---

## 六、方向三：Homa trigram 支援可行性

### 6.1 引擎端改動盤點（S3，範圍明確）

1. `Homa.Gram`：新增 `anterior: String?`（與 `previous` 同規格，value-only）。波及 init（兩款）／Codable
   （encode/decode/`CodingKeys`）／`Hashable`／`==`／`description`／`descriptionSansReading`／`asTuple`／
   `withNewIdentity`／`isUnigram`（兩者皆 nil）。
2. `Node`：`getScore(previous:)` → `getScore(previous:anterior:)`；掃描條件加 `gram.anterior == anterior`；
   `selectOverrideGram` 增加 anterior 參數（`Homa_Node.swift:285-304`）。
3. **PathFinder：DP 結構零改動**——bigram 已採「最佳路徑前驅」近似（`Homa_PathFinder.swift:74-76`）；
   trigram 前驅之二＝`parent[i - (parent[i]?.segLength ?? 0)]?.gram?.current`，兩者皆在處理位置 i 時已
   finalize（1D DP 由左至右填表）。`getScore` 呼叫處只多傳一個參數。
   - 若日後需要「精確」trigram（不採最佳路徑近似），備案為 2-gram 狀態 DP（狀態＝(position, lastValue)，
     或更深的 (lastValue, secondLast)）——量級為「各邊界不同 gram 值數的乘積」，典型輸入下仍可管理，
     但**非本階段所需**（現行 bigram 本就是近似）。
4. 選字窗排除：`Homa_CandidateAPIs_FetchAndApply.swift:40` 的 `previous == nil` 判定擴展為
   `previous == nil && anterior == nil`。
5. Trie／格式：型別 C 增第五欄 `\tanterior`（`VanguardTrieIO.swift:316-323`）＋`Trie.Entry.anterior`
   ＋IO 解析＋`Trie.queryGrams` 傳播。
6. LMAssembly：`makeFactoryUnigrams` 兩處需開始攜帶 previous／anterior（**同時修掉 §3.3 的斷鏈**），
   `unigramsForWithAlternatives` 的 grams 展開同理；`hasUnigramsForFast`／排序／去重（
   `Homa_Assembler.sortGram` 的 `previous` 比較）需納入 anterior。

### 6.2 資料來源判讀——「順勢」實作需先有語料

- factory 詞典零 bigram（§3.3 實測）→ trigram 欄位短期內也無人寫入。
- **唯一現成 trigram 語料＝POM**（§5.1）：POM 鍵天生三層。因此 S3 的真正價值是「讓 POM→trigram 餵入
  成為可能」＋「為日後廠製 trigram 語料預鋪引擎」。
- 若 S2（POM→bigram）先行並驗證效果，S3 才有穩定的第二層語料動機；否則 S3 只是把休眠鏈路加深一層。
  **建議順序：S1 → S2 → S3**。

### 6.3 鏡像範圍

- Homa／TrieKit 更動 → **三倉鏡像**（macOS↔legacy 逐字節、LibVanguard 同步 Homa＋TrieKit＋測試）；
  LangModelAssembly 更動 → 兩 IME 倉。

---

## 七、方向四：DAG-DP 自動選取 vs override 錨定（文書整理）

DevReq 所述性質經核對成立，記錄如下（供今後設計參考，無施工需求）：

- **引擎端 n-gram（現在 bigram、未來 trigram）**：由 `Node.getScore(previous:)` 在節點 gram 陣列內
  選取匹配 bigram、以 `.withTopGramScore` 覆寫該節點的**當下選取**（`Homa_Node.swift:241-252`）；
  覆寫效力隨 DP 路徑而定——若該節點最終不在最佳路徑上，覆寫不影響結果；`overrideCandidate` 的
  `isExplicitlyOverridden` 不因此置 true（自動覆寫 ≠ 使用者意圖）。**軟性、路徑可逆、重切分自由**。
- **POM 建議 API（fetchSuggestion／retrievePOMSuggestions）**：以 `.withSpecified`（forceHighScoreOverride）
  或 `.withTopGramScore` 錨定到具體節點、且伴隨 POM 觀察（`makePerceptionIntel`）與記憶寫入——
  **硬性、錨定、顯式**。
- 兩者互補：n-gram 負責「長期穩定的統計偏好」，POM 建議負責「短期、針對性的使用者覆寫記憶」。
  方向二（POM→n-gram）本質上是把「短期記憶」也導入「統計路徑」——一旦落地，POM 記憶同時具備兩種
  消費形態，需注意雙重加成（同一條記憶同時以 n-gram 加分與 override 錨定）的邊際效應，S2 報告時評估。

---

## 八、方向五：Typewriter 層「對 assembler 套用 POM 記憶」的部分可省略性（DevReq 追加）

> DevReq 追加（Reqs_0151-0160.md Phase 158 要求清單第 5 條）：POM 資料導入 n-gram 體系（方向二／三）後，
> Typewriter 層「對 assembler 套用 POM 記憶」的**部分**內容可能不再重要、甚至可省略（能省很多問題）；
> 有些內容應該也是不能省的——皆納入討論範圍。

### 8.1 可省的部分（自動段，S2／S3 落地後可被 n-gram 體系取代）

對**有上下文（bigram／trigram）的記憶**，n-gram 餵入讓 DP 在路徑層自然選中記憶詞——「自動套用」那一半
可被取代：

- `solidifyFuriousFrontReading` 固化後呼叫的 `retrievePOMSuggestions(apply: true)`
  （`InputHandler_FuriousResegmentation.swift:95`）——只是「無使用者確認的最佳猜測」，本該走統計路徑；
- 候選窗自動置頂（`generateArrayOfCandidates` 的 POM 置頂段，`InputHandler_CoreProtocol.swift:635-654`）
  ——可降級或移除。

可刪除的複雜度（這些正是 P151–P157 反覆出問題之處）：

- 4 次 retokenization 重試迴圈＋`preConsolidate` 拆詞＋失敗 bleaching 邏輯＋`failureFlagForPOMObservation`
  ＋short→long 安全閘門（`pomShortToLongAllowed`）（`InputHandler_CoreProtocol.swift:288-334`、:828-834）；
- POM 建議的 `.withSpecified`／`.withTopGramScore` 自動覆寫路徑（`retrievePOMSuggestions(apply: true)`）。

語意核對：自動段的 POM 影響本就「非使用者顯式意圖」；由統計路徑承擔後語意更一致（
`isExplicitlyOverridden` 不再被自動機制誤觸）。

### 8.2 不能省的部分（顯式段＋語料源）

1. **無上下文（unigram）記憶**：POM 有 unigram perception（`bleachUnigrams` 的存在即證據，
   `LXPerceptor.swift:613-634`）；unigram 記憶沒有 previous 可條件化、無法以 bigram／trigram 表達；
   若改以「boosted unigram gram」餵入 `unigramsFor`，會**全語境過度支配**（同一讀音在任何前後文都搶贏）
   ——語意錯誤，不是偏好。
2. **顯式選字的「釘住」語意**：`.withSpecified`＋`isExplicitlyOverridden`（使用者明確選了、就保證這個）；
   n-gram 是「傾向」——長詞路徑分數更高時記憶詞會被壓掉。使用者顯式選過的詞該被保證，不是被統計一下
   （這正是方向四所述「更強靈活性」的反面：靈活＝不確定）。
3. **切分深度不匹配**：記憶「(是)&(媽媽)」為 split 形態、現況組字是 2-key 節點時，n-gram 以 head-key 查詢
   為單位夠不著——現行 retokenization 迴圈就是為此存在。S1 的容錯查詢解決「調形／前綴」不匹配，
   **不是**「切分深度」不匹配。
4. **候選窗置頂 UX**：n-gram 的 grams 帶 previous、被 `Homa_CandidateAPIs_FetchAndApply.swift:40` 排除在
   選字窗外，記憶詞不會置頂（若仍要置頂，需另留機制或改由 unigram 路徑承擔）。
5. **寫入側（觀察／`memorizePerception`）**：本來就不能省——它是 n-gram 語料的生產者；省掉觀察＝斷了
   S2／S3 的源頭。

### 8.3 結論：正確的紅利定義

- **不是**「Typewriter 層 POM 套用不再重要、整個省略」——那會同時丟掉 unigram 記憶、顯式釘住與深層
  切分修正三個能力。
- **而是**「自動的那半沉進引擎（n-gram）、顯式的那半脫掉歷史包袱（最簡 override）」：
  - 自動段（solidify 後自動 apply、候選窗自動置頂）→ 交還給 n-gram 體系（contextual 記憶）；
  - 顯式段（使用者當下選字釘住＋unigram 記憶）→ 保留最簡的單次 `overrideCandidate(.withSpecified)`，
    不再有 retokenization 迴圈。
- 落地條件：需 S2（POM→bigram 餵入）先生效，contextual 記憶才有統計承載；unigram 記憶與顯式釘住
  仍需既有 Typewriter 路徑（可簡化、不可刪除）。

---

## 九、建議路線圖與風險

### 9.1 Phase 規劃（仿 P155 規劃出 P156／P157）

| Phase | 主題 | 範圍 | 鏡像 | 前置 |
|---|---|---|---|---|
| **S1（P159）** | POM 容錯查詢 API（tone-insensitive prefix）＋T1 copilot 套用 POM（唯讀提取＋copilot 窗置頂＋α 路徑補 POM 提取） | LangModelAssembly（LXPerceptor＋LMInstantiator_POMRepresentable＋測試）＋Typewriter（retrievePOMSuggestions 接線＋IH 測試） | 兩 IME 倉 | 無（T1 設計已定稿於 P151） |
| **S2（P160）** | POM 資料作 Homa bigram 來源＋外源開關（UserDef＋Config＋syncPrefs＋l10n 四語）＋unigramsFor 快取指紋納入 POM 世代＋分數映射取捨 | LangModelAssembly（unigramsFor 注入＋測試）＋Shared（UserDef）＋Typewriter（prefs） | 兩 IME 倉 | S1（容錯查詢供 head 讀音匹配） |
| **S3（P161）** | Homa trigram 支援（Gram.anterior＋getScore＋PathFinder 1D 擴展＋選字窗排除＋Trie 型別 C 第五欄＋LMAssembly 攜帶 previous/anterior）＋POM→trigram 餵入變體 | Homa（三倉）＋TrieKit（三倉）＋LangModelAssembly（兩倉）＋測試 | **三倉** | S2（有第二層語料動機） |
| **S4（P162）** | Typewriter POM apply 路徑瘦身：自動段（solidify 後自動 apply、候選窗自動置頂）移交 n-gram 體系、刪除 retokenization 重試／preConsolidate 拆詞／bleaching／short→long 閘門等複雜度；顯式段保留最簡 `overrideCandidate(.withSpecified)`（使用者當下選字釘住）＋unigram 記憶處理 | Typewriter（`InputHandler_CoreProtocol` 重構＋IH 測試） | 兩 IME 倉 | S2（建議 S2＋S3 皆落地後） |

- 四階段互不硬綁：S1 驗收後若對「POM 深度整合」持保留態度，S2／S3 可獨立擱置；**S4 為可選收尾**——
  若自動段被 n-gram 取代的效果不如預期，可退回既有路徑、不影響 S1–S3 價值。
- S2 內含選項：讀音限定 previous（§5.4）視為獨立評估項，不併入 S2 初版。
- S4 同時是 §8.2 風險「雙重加成」的收斂手段（見 9.2 第 3 項）。

### 9.2 風險與待決

1. **前綴過寬**：tone-insensitive prefix 可能同時命中同音節多條記憶——以候選聚類＋top-N 控制（S1 測試鎖定）。
2. **POM n-gram 過度支配**：新鮮記憶分數 ≈ −0.171 對比詞典 −0.x～−11，直接注入可能壓過一切——
   S2 以「(a) 直接注入＋衰減自限」起步並以測試記錄，視實測決定是否加天花板。
3. **雙重加成**：S2 落地後同一條 POM 記憶同時以 n-gram 加分與 override 錨定——S2 驗證時檢查
   「使用者選過的詞再次出現時不會被雙重強化到僵化」；**S4 的「自動段移交」即為此風險的根治手段**
   （自動段不再走 override、只剩 n-gram 單一加成）。
4. **快取一致性**：`unigramsFor` LRU 快取須納入 POM 世代指紋，否則記憶更新不生效——S2 必做項。
5. **休眠鏈路**：S3 若在無語料下先行，trigram 與現行 bigram 同為休眠——以「S2 先行」消解此風險。

---

## 附錄 A：檔案索引（本次調查觸及的關鍵位置）

| 模組 | 檔案 | 相關位置 |
|---|---|---|
| POM | `vChewing_LangModelAssembly/Sources/LangModelAssembly/SubLMs/LXPerceptor.swift` | 資料結構 :46-101；`fetchSuggestion` :299-347；`getSuggestion` :350-423；`alternateKeys` :828-921；`parseDelimitedPerceptionKey` :736-783；`calculateWeight` :968-1018 |
| POM 介面 | `LMInstantiator_POMRepresentable.swift` | `fetchPOMSuggestion` :25-36 |
| POM 消費 | `vChewing_Typewriter/Sources/Typewriter/InputHandler/InputHandler_CoreProtocol.swift` | `retrievePOMSuggestions` :781+；候選窗置頂 :635-654；`filterPOMAppendables` :740-777 |
| Furious | `InputHandler_FuriousResegmentation.swift` | 固化＋POM :77-96；α 路徑 :102-113；重切 :226-324 |
| Tekkon | `vChewing_Tekkon/Sources/Tekkon/Tekkon_Utilities.swift` | `makeToneInsensitiveVariants` :12-22 |
| Homa | `Homa_BasicTypes/Homa_Gram.swift` | `previous`（value-only）:9,62；`isUnigram` :66 |
| Homa | `Homa_BasicTypes/Homa_Node.swift` | `getScore(previous:)` :211-255；`selectOverrideGram` :285-304 |
| Homa | `Homa_MainComponents/Homa_PathFinder.swift` | 1D DP＋最佳路徑前驅 :74-76 |
| Homa | `Homa_MainComponents/Homa_CandidateAPIs_FetchAndApply.swift` | 選字窗排除 bigram :40 |
| Homa | `Homa_BasicTypes/Homa_GramInPath.swift` | `makePerceptionIntel` :94-211；`generateKeyForPerception` :368-454 |
| Trie | `TrieKit/VanguardTrieIO.swift` | 型別 C 第四欄 previous :316-323 |
| Trie | `TrieKit/VanguardTrie_Core.swift` | `Trie.Entry.previous` :149-188 |
| LM | `LangModelAssembly/LMInstantiator.swift` | `unigramsFor` :647-887；`unigramsForWithAlternatives` :1104+；`syncPrefs` :247-260 |
| LM | `LMInstantiator_TextMapExtension.swift` | `makeFactoryUnigrams`（丟棄 previous）:419-457、:460-498 |
| LM | `SubLMs/lmCoreEX.swift` | unigramsFor／前綴掃描 |

## 附錄 B：量化事實

- POM 容量上限 500（`LXPerceptor.swift:49`）→ 容錯全掃描成本有界。
- POM 權重範圍實算：新鮮 ≈ −0.171（`kWeightMultiplier ≈ 0.171`），衰減至 −12.999 下限、閾值 −13。
- Factory 詞典（`VanguardFactoryDict4Typing.txtMap`，442,105 行）：欄位數分布 1／2／3，**零 ≥4 欄列**
  → 現行無任何 bigram 資料。

## 附錄 C：後續實作追蹤（P159–P165 完工，2026-08-30）

> 本附錄記錄本報告建議路線 S1（容錯查詢）→ S2（POM→bigram）→ S3（trigram）→ S4（自動段移交）
> → R3（δ：簡拼感知重切＋跨音節數重切）→ P164（重切候選 Top-N 入窗）→ P165（置頂候選首段重合
> 修復）的落地結果，以及截至 P165 完工後的未竟事項。由 Deepseek-v4-flash 施術，兩倉
> （＋LibVanguard 鏡像）同步。

### C.1 P159（S1）：POM 容錯查詢 API＋T1 copilot 套用 POM（兩倉）

- **S1-a**：`LMAssembly.POMQueryMode`（`.exact`／`.toneInsensitivePrefix`）＋`LXPerceptor.fetchSuggestion`
  增 `matchMode`（預設 `.exact`，現行行為零變更）；新 `getToneInsensitiveSuggestion`（LRU 全表掃描、
  容量 ≤500）——三位置讀音「逐段去聲調等值」（段數一致）、上下文 values exact＋query 無上下文萬用
  （同 `alternateKeys` 語義）、head values 放寬（容許建議替換當前最佳猜測）、`_` 前綴讀音與
  threshold／`calculateWeight` 保留、回傳 keyArray 採 query head 段。**語義定案**：DevReq「prefix-
  matching」在 query 讀音恆為完整音節下退化為去聲調等值（避免 `ma`↔`mang` 跨音節誤配）。
- **S1-b（T1）**：`retrievePOMSuggestions` 狂拼時用容錯模式（固化後自動 apply＋候選窗置頂皆受益）；
  `buildFuriousFrontCandidates` copilot 窗置頂 POM 建議（組字器副本＋虛擬尾段唯讀查詢、不套用不寫
  記憶）；α 路徑無需專碼（既有 `generateArrayOfCandidates` 置頂＋容錯涵蓋）。
- 測試：LMA ＋7（`POMTolerantQueryTests`）、TW ＋2（IH135 copilot 窗置頂、IH136 固化後容錯套用）。
- 驗證：LangModelAssembly 139/139、Typewriter 141/141、MainAssembly4Darwin 68/68；Legacy `make
  debug-core` ✅；兩倉 swiftformat 冪等。

### C.2 P160（S2）：POM 資料作 Homa bigram 來源＋外源開關（兩倉）

- **S2-a**：`LXPerceptor.perceptionsFor(headReading:timestamp:matchMode:)`（全量高於閾值記憶、不做
  top-1 篩選）；`unigramsFor` 兩路徑（fast path＋`unigramsForWithAlternatives`）開啟時對 head
  keyChain 注入 `Homa.Gram(keyArray: 記憶 head 讀音段, current: 候選, previous: 前驅值,
  probability: 衰減權重)`——附加於 consolidate＋sort 之後（不經去重互擾）、previous 非空故選字窗
  排除機制自動隔離；記憶 head 讀音段作 keyArray（避免 reading/value 錯配）。
- **S2-b**：`kPOMAsNGramSourceEnabled`（UserDef＋PrefMgr＋Config＋syncPrefs，預設 off）＋l10n 四語。
- **S2-c**：`mtxPOMGeneration` 世代計數器（變更 wrapper 遞增）納入 unigramsFor LRU fingerprint。
- **S2-d**：分數「直接注入＋8 天衰減自限」起步（未加天花板，視實測收斂）。
- 測試：LMA ＋4（`POMNGramSourceTests`）、TW ＋1（IH137 純統計路徑組句選中）。
- 驗證：LangModelAssembly 143/143、Typewriter 142/142、MainAssembly4Darwin 68/68；Legacy `make
  debug-core` ✅；兩倉 swiftformat 冪等。

### C.3 P161（S3）：Homa trigram＋Trie 第五欄＋POM→trigram（三倉）

- **S3-a（Homa）**：`Gram.anterior: String?`（兩款 init／Codable `ante`／Hashable／等值／
  `descriptionSansReading` 三元圖／`asTuple`／`withNewIdentity`／`isUnigram`＝previous＋anterior 皆
  nil）；`GramRAW` 5 欄＋`HomaCompatShims` convenience init 增 previous/anterior；`Node.getScore
  (previous:anterior:)` 掃描三元（anterior 語境存在才比對）與雙元、`selectOverrideGram` 增 anterior、
  `unigramScore` 判定擴展；`PathFinder` 1D DP **結構零改動**（trigram 前驅之二＝
  `parent[i - parent[i].segLength]` 沿最佳路徑回看）；選字窗排除擴展為 previous＋anterior 皆 nil；
  `sortGram`／`makeGramIdentityHash` 納入 anterior。
- **引擎語意精化**：`getScore` `default` 分數基線改為「top gram 匹配語境取其分數、否則退回最佳
  unigram」＋bonus 匹配不與 `currentGram` 綁定——修既有「未匹配 bigram 洩漏分數／留駐輸出」quirk
  （既存 bigram 測試全數維持綠燈為證）。
- **S3-b（TrieKit）**：`Entry.anterior`（序列化 legacy 路徑不承載、decode 置 nil）；`parseValueLine`
  型別 C `[\tprevious][\tanterior]`；SQLite 匯出／重建、`parsedEntries`、`queryGrams`／
  `queryAssociatedPhrasesAsGrams` 4-tuple→5-tuple 傳播。
- **S3-c／S3-d（LMAssembly）**：`makeFactoryUnigrams(queriedGrams:)` 攜帶 previous/anterior（斷鏈
  修復、無資料零變更）；`perceptionsFor` 回傳加 anterior、`unigramsFor` 兩處注入帶 previous＋anterior
  （POM→trigram 餵入）。
- 測試：Homa ＋3（`HomaTests_Trigram`：路徑選取／前驅二位不匹配退回／不出現在選字窗）；測試 LM＋
  `SimpleTrie.Entry` 增 anterior（第 5 欄）；`GramRAW` 5 欄修正。
- 驗證：macOS Homa 61/61、LangModelAssembly 143/143、Typewriter 142/142、MainAssembly4Darwin 68/68；
  Legacy `make debug-core` ✅；LibVanguard build＋test ✅（Homa 61、TrieKit 18 全目標，含 LexiconKit
  `HomaGramTuple` 等 4-tuple 消費者修正）；三倉 swiftformat 冪等。

### C.4 P162（S4）：Typewriter POM apply 路徑瘦身（兩倉）

- **S4-a（雙重加成收斂）**：`retrievePOMSuggestions(apply:)` 在 `apply == true` 且
  `isFuriousTypingModeEffective && prefs.pomAsNGramSourceEnabled` 時**跳過自動套用**（override 錨定）
  並回傳唯讀提取——contextual 記憶已由 DP 以 n-gram 加分自然選中，不再以 `.withTopGramScore`／
  `.withSpecified` 錨定；涵蓋所有狂拼自動 apply 路徑（solidify 固化等）；開關關閉時行為與現行
  完全一致（IH136 維持綠燈）。
- **S4-b（範圍收斂）**：retokenization 重試／preConsolidate／bleaching／short→long 閘門**維持現狀**
  ——該迴圈位於顯式選字路徑（`handleSelectingCandidate`）、為「切分深度不匹配（split 記憶 vs 2-key
  節點）」必要機制（§8.2 第 3 項），不屬自動段；`pomShortToLongAllowed` 隨 S4-a 閘門在「狂拼＋
  n-gram」組合下自然繞過。
- **S4-c**：顯式段（`.withSpecified` 釘住）、unigram 記憶套用、POM 觀察寫入側全部維持。
- 測試：TW ＋1（IH138：狂拼＋n-gram＋POM 同時開啟時固化選取來自 n-gram 統計路徑——最後節點
  `gram.previous == "是"`、非 bare unigram override）。
- 驗證：Typewriter 143/143、LangModelAssembly 143/143、MainAssembly4Darwin 68/68；Legacy `make
  debug-core` ✅；兩倉 swiftformat 冪等。

### C.5 P163（R3＝δ）：狂拼簡拼感知重切＋α 自動套用（兩倉）

- **R3-a（簡拼感知＋α 自動套用）**：`FuriousTypingSegmentor` 的「簡拼感知」由呼叫方閉包注入
  （`isValidSyllable` 接受「完整音節 OR 合法簡拼前綴」、`syllableScore` 對簡拼段以 α 整詞查詢
  評分），結構體零預設；新增 `autoApplyFuriousAbbreviationIfClearWinner(appending:)`——
  auto-chop（完整音節路徑）不可行時，以 α 整詞查詢評分注拼槽整段（**含本拍字元**），頂級候選
  「明確勝出」（①讀音數與簡拼段數一致＝整詞完全匹配，攔「ysx」只命中四字詞前綴；②唯一匹配
  或與次級 log-prob 差 ≥ 3.0，攔「一世雄霸」類近分競爭者）時自動把實際讀音以單鍵序列寫入
  組字器——`ysxb` 全程自動出「野獸先輩」不必等 Shift+選字鍵；`furiousAbbreviatedCells` 拆
  「可帶給定字母流」版本（`furiousAbbreviatedCells(romaji:)`）、接線於
  `performPinyinAutoChopIfNeeded` 的 auto-chop 失敗分支。
- **R3-b（跨音節數枚舉能力＋重切安全範圍）**：`candidateSegmentations
  (of:syllableCount:limit:)` 的 `syllableCount` 改可選（nil＝不限音節數，既有傳 Int 呼叫
  零改動）——跨音節數枚舉能力（`xian`→`[xi, an]`、「xian」可切出「x|ian」）保留於
  Segmentor 純函式層、供今後經設計的觸發條件使用。**重切安全範圍**：`resegmentFuriousTrailIfNeeded`
  維持「同音節數」枚舉（`syllableCount: furiousTrail.count`）＋ trail 閘門「≥ 2」＋整句路徑
  總分比較、`solidifyFuriousFrontReading` 不觸發重切——設計依據（打字流安全性驗證）：
  「拆開型」跨音節數重切在打字中途即把單音節 trail 拆開（「xiansheng」中「xian」剛被
  auto-chop 提交就被拆成「西」「安」、後續「生」只能接在其後→誤切「西岸生」），且
  「每音節平均」正規化偏好多音節切分（普通單字平均分高於合併詞「先生」）——P150 取捨
  「路徑分長度偏差無法正規化」的實證、故不採納；`fangan`→`[fan, gan]` 類 greedy 邊界
  修正由 auto-chop 路徑的同音節數重切提供（不受影響）。
- **R3-c（評估不施工）**：lazy 展開（本報告 §10.3 手段 F）——枚舉有 DP beam（limit=8）每位置
  截斷兜底、α 整詞查詢有界（factory「&」＋user-phrase 多前綴交集掃描），無展開量失控實例。
- **Homa 預設零改動**：沿用 scratch drop+insert 試算＋真組字器 drop+insert＋失敗回滾；原子
  `replaceKeys` 評估後確認無必要（既有 drop+insert 可涵蓋鍵數變化）。
- **重切紀律**：trail 不變量（游標 frontest edge／trail span 無 explicit override／組字器尾鍵
  與 trail 逐段對應）維持；顯式干涉（選字／輪替／游標離開前端／BackSpace 彈出）後 trail 失效
  沿用（12 處失效點＋`popFuriousTrail` 精確同步）。
- 測試：Segmentor ＋2（跨音節數枚舉「xian」1/2 音節混列、指定音節數行為不變／簡拼感知枚舉
  「ysxb」切成 4 簡拼段、「xian」可切出「x|ian」且簡拼段分數參與排序、完整音節閉包行為不受
  影響）；IH132-134 注入改模稜兩可場景（R3-a 後「唯一整詞匹配」自動套用——加近分競爭者
  「一世雄霸」／「星期人」保留「候選窗顯示／Shift+選字鍵／空格固化」確認路徑語義）＋新增
  IH139（ysxb 自動出整詞：實際讀音單鍵寫回、trail 失效）／IH142（模稜兩可不自動、copilot 窗
  保留候選）／IH143（「先生」回歸防護——刻意讓「西岸生」每音節平均高於「先生」，鎖定拆開型
  重切不得回歸）。
- 驗證：Typewriter 148/148、LangModelAssembly 143/143、MainAssembly4Darwin 68/68；Legacy `make
  debug-core` ✅（BPMF 保留既有 `self.onLexiconMatchFailure = nil` 行、其餘三檔逐字節一致）；
  LibVanguard build＋test ✅；兩倉 swiftformat 冪等。

### C.6 P164：重切候選以 Top-N 形式入選字窗（copilot 窗聯合重切，兩倉）

- **設計定案（範圍收斂）**：重切候選僅入 **copilot 窗**（打字中、注拼槽非空）——正常選字窗
  （固化後）語義為「對已確認讀音選字」，顯示「另一組讀音」的切分結果會造成讀音標記不一致與
  選取行為混雜（選字 vs 改讀音）；打字中的 copilot 窗才是「邊打邊調整切分」的正確場所，故
  `generateArrayOfCandidates`／`consolidateNode` 零改動。
- **共用枚舉**：`enumerateFuriousResegmentationCandidates()` 自 `resegmentFuriousTrailIfNeeded`
  的候選生成段抽出（閘門＝狂拼有效＋trail ≥ 2＋組字器尾鍵與 trail 逐段對應＋游標 frontest
  edge；同音節數枚舉＋桶存在性驗證＋scratch drop+insert 試算；按 scratch 整句路徑總分降冪、
  含組句時 trail 段最後節點讀音／詞值；trail 自癒失效語義保留）；自動重切重構為「共用枚舉＋
  嚴格勝出（總分高於現狀基線）替換」、行為與既有一致（IH118A 等維持綠燈）。
- **copilot 窗聯合重切**：`buildFuriousCoSegmentedOffers()` 把 trail 字母流與注拼槽字母流
  合併、枚舉「同音節數」（trail 段數＋1——copilot 語義下注拼槽整段為一音節）切分，每替代
  切分以「整詞查詢」（切分全部段的音節桶、只取整段匹配完整詞）取組句 top-1 為 offer
  （keyArray＝詞讀音、value＝詞值、blobs＝切分）——「fangan」連打（trail=fang、注拼槽=an）
  即呈現「反感」（fan|gan）；同音節數約束不產生拆開型（「xiansheng」→「xi, an, sheng」為
  3 音節被過濾、不重現「先生→西岸生」）；候選追加於 `buildFuriousFrontCandidates` 尾、offers
  暫存 `furiousCoSegmentedOffers`（protocol 新屬性、conformer 兩倉各補一行）。
- **選取**：`confirmFuriousFrontCandidate` 開頭攔截——被選 copilot 候選匹配 offer 時
  `applyFuriousCoSegmentedOfferIfAny` drop trail 全長＋insert 替代切分音節桶＋清空注拼槽＋
  trail 更新為新切分（顯式採納、非失效）；不遞交、不寫 POM 觀察；失敗防禦復原 trail 鍵。
- **候選排序（P164 補修）**：copilot 窗候選（置頂組句預覽除外）按「詞長（segLength）降冪、
  再查詢分數（weight）降冪」stable-sort——替代切分整詞（「反感」2 段）浮於大量單音節
  候選之前、僅次於置頂預覽（實測回饋：未排序前被擠到選字窗末頁、滑鼠滾輪才可見）；
  `FuriousCoSegmentedOffer` 增 `weight`、跨邊界／尾段候選帶 `gram.probability` 參與排序。
- 測試：IH147（fangan 連打 copilot 窗含「反感」、keyArray＝[ㄈㄢˇ,ㄍㄢˇ]、offers 非空）／
  IH148（選取「反感」→ 組字器 keys 換 fan|gan 音節桶、trail＝["fan","gan"]、注拼槽清空、
  組句「反感」）／IH149（排序：置頂預覽「安」首位、「反感」index＝1、浮於所有 1 段候選
  之前）。
- 驗證：Typewriter 151/151（150＋1）、LangModelAssembly 143/143、MainAssembly4Darwin 68/68；
  Legacy `make debug-core` ✅（CoreProtocol 保留 `@MainActor` 剝離方言、conformer 補
  `furiousCoSegmentedOffers` 屬性）；兩倉 swiftformat 冪等。

### C.7 P165：狂拼 copilot 窗置頂候選就地選字的重複首段修復（兩倉）

> 由使用者實測回饋（2026-08-30）啟動的缺陷修復——根源不在 P158 的待決清單（未竟事項），而是
> P159 落地「copilot 窗置頂 POM 建議」＋P150 就地選字路徑交疊後暴露的套用路徑缺口；因屬
> P158 規劃的狂拼候選窗體系（P159–P164）衍生的實作缺陷，故與 P159–P164 並列追蹤於本附錄。

- **症狀**：`tama`（ta-ma 連打）＋POM「他媽的」記憶（`fetchSuggestionsFromPerceptionOverrideModel`
  開啟）時，copilot 窗置頂候選為「他媽的」（keyArray `[ㄊㄚ,ㄇㄚ,ㄉㄜ˙]` 3 段）；就地選中後
  組字器變「他他媽的」——「他」重複（keys 4）。對照 `tamade`（完整 ta-ma-de）顯示「他媽的」正常。
- **根因**：`applyFuriousFrontCandidate` 的三路徑判定（置頂無橫跨＝keyArray==bucket／跨邊界＝
  前 n-1 段隸屬組字器尾 n-1 鍵／前方單音節）皆不命中「候選首段ㄊㄚ 與組字器尾鍵（ㄊㄚ桶）重合」
  的結構——組字器僅 1 鍵（`ta` 已固化）時跨邊界需要 n-1≥2 鍵、置頂無橫跨需 keyArray==注拼槽桶，
  故落入 else 分支**插入完整 keyArray**（[ㄊㄚ,ㄇㄚ,ㄉㄜ˙] 3 單鍵）到「他」之後 →「他」＋
  「他媽的」＝「他他媽的」。IH150 重現：選中後 `assembledSentence == ["他","他媽的"]`、keys 4。
- **修復（`applyFuriousFrontCandidate` 第四路徑「首段重合」）**：候選前 k 段讀音（k ≥ 1、
  k < keyArray.count）逐位隸屬組字器**最後一鍵**的讀音桶時（與跨邊界互斥：後者需「最後 n-1 鍵」
  逐位承接、鍵數不足 span 時不成立；本路徑僅以單一尾鍵承接）——**只插入第 k+1 段起的讀音
  （單鍵）**、並覆寫「組字器尾鍵起（anchor-1，重合讀音全部落於最後一鍵）的候選全長 span」。
  「他媽的」案例：k=1 → 插入 [ㄇㄚ,ㄉㄜ˙] → 組字器 `[ㄊㄚ桶,ㄇㄚ,ㄉㄜ˙]`（3 鍵）→ 覆寫自
  index 0（anchor-1）的全長 span → 組句「他媽的」（單節點）。`isExplicitlyOverridden`／POM 觀察
  語義沿用（僅使用者顯式選字寫入）。Homa 零改動。
- 測試：**IH150** `test_IH150_FuriousTypingTamaPreviewNoDuplicate`（tama＋三條使用者環境 POM
  記憶注入＋`pomAsNGramSourceEnabled`＋`fetchSuggestionsFromPerceptionOverrideModel`：就地選中
  「他媽的」→ keys 3、`assembledSentence.map(\.value) == ["他媽的"]`、無「他他」；修復前紅燈）。
  既有狂拼就地選字（IH132-136）／重切（IH118A、IH147-149）全綠（無回歸）。
- 驗證：Typewriter **152/152**（151＋IH150）、LangModelAssembly 143/143、MainAssembly4Darwin
  68/68、LibVanguard 全量綠燈、Legacy `make debug-core` ✅；兩倉 swiftformat 冪等；commit
  macOS `9cc2ec66`／Legacy `f5617894`（Homa 零改動無分離 commit）。詳見
  `DevPlans/Reqs4LLM/Reqs_0161-0170.md` Phase 165。
- **P165 補修（copilot 窗候選去重，2026-08-30）**：P165 完工後實測 `tamad`／`tamade` 時
  copilot 選字窗出現**兩個「他媽的」**——`buildFuriousFrontCandidates` 置頂段的 POM 建議
  （`fetchPOMSuggestion` toneInsensitivePrefix）與組句橫跨節點（crossingPair）對同一詞各
  回傳一次，而置頂段僅 POM 建議迴圈按 value 去重、crossingPair／preview 的追加無
  `seenValues` 守衛。修復：置頂段追加亦以 `seenValues.insert(...).inserted` 守衛、同值跳過
  （保留先出現的 POM 建議、置頂語義不變；preedit 顯示不走候選清單、不受影響）。測試
  **IH151**（tamade＋POM 記憶：置頂仍為「他媽的」、全窗僅一次；fail-first 已驗——無修復時
  count==2）。Typewriter 153/153、LMA 143/143、MainAssembly 68/68、LibVanguard ✅、Legacy
  build ✅；commit macOS `48976c9d`／Legacy `0b045675`。

## 附錄 D：截至 P165 完工後的未竟事項（2026-08-30 整理）

> 「另立 Phase（有明確後續價值）」目前**無餘項**——候選窗體驗強化清單已全數落地（方向鍵
> 導航由 P150 固化機轉取代、Shift 提示由 P151 落地、簡拼感知重切由 P163 落地、替代切分
> Top-N 入窗由 P164 落地）；下列為暫不排程的備考／長遠／體系開放項。

### D.1 備考待決（暫不施工）

1. **低優先 override＋trail 重切分時 reset trail span**——「空格固化後顯示與 copilot 選讀一致」
   的釘選感 vs trail 重切自由度的取捨（需動 Homa 層重切分前提），維持備考。
2. **中段簡寫（游標非尖端時簡寫）**——獨立工程（牽動 copilot 上下文／trail／POM／游標規則）；
   R2 已完工，**此項可重新評估**。

### D.2 長遠評估／體系開放（未排程）

1. **方案 C（SunPinyin 式字母級 lattice）**——α 落地後價值再降，維持暫不排程。
2. **POM n-gram 分數天花板決策**——S2-d 以「直接注入＋8 天衰減自限」起步、未加天花板；**待真實
   使用實測後決定是否收斂**（若新鮮記憶過度支配需加 clamp）。
3. **讀音限定 previous（獨立引擎更動評估）**——Homa `Gram.previous` 現為 value-only；若要 POM
   n-gram 保留讀音精度（多音字同字異音不誤配），需引擎層「帶讀音的 previous」變更。未排程。
4. **詞典 n-gram 資料缺席**——S3-c 已修通「trie→LMA→Homa」攜帶鏈路，但現行 factory 詞典無任何
   bigram/trigram 資料（第四欄零使用）；若要詞典供 n-gram 統計，需 VanguardLexicon 產生端投入。
5. **條件式 l10n 修訂**——若笛卡爾積問題獲改善，`kKeyboardParser4Pinyin.description` 四語需同步
   修訂以反映實際情況（目前防禦仍以「乘積預算＋`maxSegLength→4`」形式存在，未觸發）。
6. **非狂拼自動 apply 路徑**——S4 只閘了「狂拼＋n-gram」組合；BPMF／磁帶／混雜模式的
   `retrievePOMSuggestions(apply: true)` 仍照舊執行。**為何維持原判（不全面移交 n-gram，2026-08-30
   定案）**：① `pomAsNGramSourceEnabled` 預設 off——移交收益僅在使用者開啟開關時兌現，未開啟者
   行為完全不變；② override 是「強制覆寫」（記憶詞必出）而 n-gram 是「統計加分」（僅 DP 勝出時
   浮現）——一般拼音用戶依賴「打字中記憶詞直接浮現」，移交會退化為統計性浮現；③ 磁帶（quick-
   candidate／逐字語義）的組句查詢是否吃 POM n-gram 注入、混雜（中英混打）的 POM 語義皆未實作
   驗證；④ 範圍界定成本（S4-b/c 教訓：顯式選字路徑必須維持，非狂拼移交需精確只動自動段）。日後
   若再起此念頭，先驗證「磁帶查詢是否吃 POM n-gram 注入」與「一般拼音對記憶詞強制浮現的依賴」。

### D.3 已收束（非待辦）

- **Beam Search 檢討**——已記錄為「現在不值得」（搜索空間有硬上限；未來對症手段是 k-best DP），
  待「Homa 輸出 N-best 路徑」需求出現再評估。
- **工具鏈漂移**——本機 SwiftLint 與 HEAD 基線不符（`make lint` 會漂移 158 檔），非程式待辦但
  注意勿在整倉執行 `make lint`。

### D.4 已由 P159–P164 解決（自待決清單移除）

- T1 唯讀 POM 查詢與 copilot 套用（P159）、容錯查詢（P159）、POM→bigram（P160）、外源開關＋快取
  指紋（P160）、Homa trigram＋Trie 第五欄＋斷鏈修復（P161）、getScore 語意精化（P161）、雙重加成
  收斂（P162）。
- **R3（δ）：簡拼感知重切＋跨音節數重切合併（P163）**——`isValidSyllable` 接受「完整音節 OR
  合法簡拼前綴」＋α 整詞查詢當評分器（`ysxb` 全程自動出整詞、明確勝出防誤自動）；跨音節數
  重切（`xian`→`[xi, an]`）＋每音節平均正規化；lazy 展開（手段 F）評估後不施工；Homa 原子
  `replaceKeys` 評估後確認無必要（既有 drop+insert 可涵蓋）。詳見附錄 C.5。
- **候選窗體驗強化餘項：替代切分 Top-N 入窗（P164）**——重切候選以替代切分整詞候選形式入
  copilot 窗（打字中即時呈現「trail＋注拼槽」聯合重切、`confirmFuriousFrontCandidate` 攔截
  選取替換；正常選字窗零改動）；共用枚舉 `enumerateFuriousResegmentationCandidates` 自自動
  重切抽出。詳見附錄 C.6。
