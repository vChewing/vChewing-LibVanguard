# Phase 32 術後調研報告：Perception Override 機制對比與 Homa 遷移策略評估

> 基礎版本：Phase 31 調研報告（2026-04-18, Claude Opus 4.6）
> 本版日期：2026-04-18（Phase 32 手術完成後重寫；同日修訂：補充特性吸收分析與遷移步驟調整）
> 調研範圍：`vChewing-macOS`（Megrez + LMPerceptionOverride）& `vChewing-LibVanguard`（Homa + LX_Perceptor）
> 調研員：Claude Opus 4.6

---

## 〇、Phase 32 手術摘要

Phase 31 調研報告提出了四個立即可做的低風險改動（P0–P3）。Phase 32 已將其全部實施並提交至 `vChewing-macOS`（main）與 `vChewing-OSX-legacy`（main）：

| 項目 | Phase 31 建議 | Phase 32 實作結果 |
|------|-------------|-----------------|
| **P0** | Megrez 引入 `BehaviorPerceptor` typealias + `PerceptionIntel` struct | ✅ Megrez 已有 `PerceptionIntel`；Compositor 新增 `public var perceptor: ((Megrez.PerceptionIntel) -> ())?` |
| **P1** | Compositor 新增 `perceptor` 屬性 + `overrideCandidate` 雙路分發 | ✅ `overrideCandidateAgainst` defer 區塊採 `perceptionHandler ?? perceptor` 雙路分發 |
| **P2** | 將 WAL 日誌系統抽離為獨立持久化層 | ✅ 新增 `PerceptionPersistor`，POM 核心模組退化為純觀測邏輯 + 委派 I/O |
| **P3** | `kDecayThreshold` 統一為 `-13.0` | ✅ 已從 `-9.5` 調整為 `-13.0` |
| **附加** | `calculateWeight()` 中 UserDefaults 讀取改為建構期注入 | ✅ 新增 `reducedLifetime` 注入欄位，`LMInstantiator.pomReducedLifetime` 轉發 |
| **附加** | 新增 POM 獨立測試 | ✅ `POMRapidForgetTests` 3/3，覆蓋急速遺忘啟用/停用 + LMInstantiator 轉發鏈 |

**本文是 Phase 31 報告的術後重寫版**——所有對比分析與遷移策略均以 Phase 32 完成後的現狀為前提。

---

## 一、調研任務摘要

1. 評估 Phase 32 術後的 `LMPerceptionOverride` 與 `LX_Perceptor` 之間的差距是否已縮小，以及仍存在的結構差異。
2. 評估 Megrez 新增的 Assembler 級 Perceptor Lambda API 是否達到了 Homa 同等設計水準。
3. 修訂從 Megrez + LMPerceptionOverride 體系遷移至 Homa + LXKit + LX_Perceptor 的施術路線。
4. 重新評估「漸進演化 vs 直接替換」策略。

---

## 二、架構對比總覽（Phase 32 術後）

### 2.1 組句器：Megrez vs Homa

| 維度 | Megrez（Phase 32 後） | Homa |
|------|---------------------|------|
| LM 介面 | `LangModelProtocol`（protocol，2 methods） | Lambda closures（`GramQuerier` / `GramAvailabilityChecker`） |
| 基礎單位 | `Unigram`（keyArray, value, score），**無 previous** | `Gram`（keyArray, current, probability, previous?），Unigram 與 Bigram 統一 |
| Bigram 支援 | **無** | **有**：`Node.getScore(previous:)` 在 DP 遍歷時隱式查詢 `bigramMap` |
| DP 演算法 | 前向 DAG-DP + 回溯（純 Unigram） | 前向 DAG-DP + 回溯（Unigram/Bigram 融合） |
| 上下文鞏固 | **無** | **有**：`consolidateCandidateCursorContext` dry-run 鏡像推算安全邊界後鎖定鄰近節點 |
| 候選字輪替 | 透過 overrideCandidate 實現（無獨立 API） | 獨立 `revolveCandidate` API，內建最多 20 次重試 + debug handler |
| Query Cache | `assignNodes()` 內局部 cache，每次 assign 重建 | `gramQueryCache`（bounded 512 筆），跨連續 `insertKey()` 重用 |
| **Perceptor 耦合** | ✅ **Assembler 級 `perceptor` + 呼叫級 `perceptionHandler`，雙路分發**（Phase 32 新增） | 內建 Assembler 級 `perceptor` + 呼叫級 `perceptionHandler`，雙路分發 |
| Consolidator Perceptor 隔離 | N/A（無 Consolidator） | 鞏固期間 `perceptor = nil`，defer 恢復，防假觀測 |

**Phase 32 帶來的關鍵變化**：Megrez 的 Perceptor 耦合方式已從「外部手動協調」升級為與 Homa 等價的 Assembler 級 Lambda 注入。`overrideCandidateAgainst` 的 `defer` 區塊在組句變化發生後自動觸發 `(perceptionHandler ?? perceptor)?(intel)`，語義與 Homa 完全對齊。

**關於「Homa 獨有」的澄清**：上表中 Homa 的**上下文鞏固**（`consolidateCandidateCursorContext`）和**候選字輪替**（`revolveCandidate`）並非 Homa 發明的全新演算法——它們是 vChewing-macOS Typewriter 層 `InputHandler` 的既有特性被**向下吸收**至 Assembler 內部的結果。Megrez 本身雖無這些 API，但等價邏輯已存在於 `InputHandler_CoreProtocol.consolidateCursorContext()` 和 `InputHandler_HandleStates.revolveCandidate()` 中。詳見 §2.3。

### 2.2 觀測模組：LMPerceptionOverride（Phase 32 後） vs LX_Perceptor

| 維度 | LMPerceptionOverride（Phase 32 後） | LX_Perceptor |
|------|--------------------------------------|--------------|
| 程式碼行數 | ~1000 行（POM 本體）+ ~220 行（PerceptionPersistor） | ~786 行 |
| 衰減算法 | 二次曲線 `ageFactor = ageNorm^2`，`kWeightMultiplier` ≈ 0.114514 | 二次曲線 `ageFactor = ageNorm^2`，`kWeightMultiplier = 0.114514` |
| 時間窗 | 8 天（可經 `reducedLifetime` 注入銳減至 ≤12 小時） | 8 天（固定） |
| Unigram 衰減加速 | ×0.85（無前文）、×0.8（單字） | 相同 |
| 頻率因子 | `0.5√(p) + 0.5·log₁₀(1+count)` | 相同 |
| **Decay Threshold** | ✅ **-13.0**（Phase 32 統一） | **-13.0** |
| 持久化 | ✅ 已抽離至 `PerceptionPersistor`（JSON 快照 + WAL Journal + CRC32 + compaction） | 單層 Codable 快照（I/O 交由外部管理） |
| 鎖機制 | `NSLock`（`withLock`） | `DispatchQueue.sync`（serial queue） |
| **外部依賴** | ✅ **零 UserDefaults 熱路徑讀取**（`reducedLifetime` 由建構期注入） | 僅 Foundation + Homa 型別 |
| Bleach API | 三層 + bleachUnigrams | 相同三層 + bleachUnigrams |
### 2.3 特性吸收分析：Homa 與 Typewriter/InputHandler 的職責邊界重劃

Homa 相對於 Megrez 的 API 差異，本質上可分為四類——這對遷移步驟的規劃至關重要：

#### (A) 從 InputHandler 向下吸收至 Assembler 的特性

> Shiki Suen 按: Megrez 與 Homa 都是 Sentence Assembler。此前的舊稱 `compositor` 因為容易與 Tekkon Composer 混稱的原因而棄用。

這些特性在 vChewing-macOS 中**已經存在於 Typewriter 層**，但被 Homa 從上層「拉入」了組句器內部：

| Homa API | Typewriter 等價實作 | 吸收後的差異 |
|---------|-------------------|------------|
| `consolidateCandidateCursorContext(for:cursorType:)` | `InputHandler_CoreProtocol.consolidateCursorContext(with:explicitlyChosen:)` | Homa 增加了 `CandidateCursor` 參數化（前置/後置游標），以及 `throws(Exception)` 錯誤語義 |
| `revolveCandidate(cursorType:counterClockwise:)` | `InputHandler_HandleStates.revolveCandidate(reverseOrder:)` | Homa 提供了對應內建 API；Phase 33 follow-up 已把 Homa 自身 overlap/consolidation case 修通，因此 Typewriter 端已能完全直通，不再需要 parity fallback |
| `calculateConsolidationBoundaries()` (private) | `InputHandler_CoreProtocol.calculateConsolidationBoundaries(for:explicitlyChosen:)` | 演算法等價：乾操作鏡像 → 邊界推算 → 安全範圍合併 |
| `calculateNextCandidateIndex()` (private) | `InputHandler_HandleStates` 內的 `revolveAsIndex(with:clockwise:)` 迴圈 | 邏輯等價，Homa 封裝為獨立方法 |

**關鍵含義**：遷移至 Homa 時，InputHandler 中這些邏輯需要被**刪除**（因為 Homa 已包含），而非逐一映射。這意味著 Stage A 手術對 InputHandler 的改動量級中，很大一部分是**代碼精簡**而非新增代碼。

#### (B) 從 Megrez 繼承的 1:1 等價特性

Homa 的核心演算法與基礎設施直接繼承自 Megrez：

- DAG-DP 前向遍歷 + 回溯（`PathFinder`）
- 節點插入/刪除（`insertKey` / `dropKey`）
- 游標導航（`moveCursorStepwise` / `jumpCursorBySegment` / `isCursorAtEdge`）
- 候選字獲取與篩選（`fetchCandidates` + `CandidateFetchFilter`）
- 基本覆寫（`overrideCandidate` / `overrideCandidateLiteral`）
- 覆寫狀態鏡像（`createNodeOverrideStatusMirror` / `restoreFromNodeOverrideStatusMirror`）——**Megrez 已有此 API**
- 強制重新分詞（`enforceRetokenization`）——**Megrez 已有此參數**
- 格柵縮放（`resizeGrid`）、DOT 視覺化（`dumpDOT`）

#### (C) Homa 真正新增的特性（Megrez + Typewriter 均無等價物）

| 特性 | 說明 |
|------|------|
| **Bigram 支援** | `Gram` 型別統一 Unigram/Bigram，`Node.getScore(previous:)` 在 DP 遍歷時查詢 `bigramMap` |
| **`CandidateCursor` 游標風格抽象** | 前置（macOS）/ 後置（微軟）游標的參數化支援——Typewriter 硬編碼為前置 |
| **`gramQueryCache`** | 256 筆有界快取，跨連續 `insertKey` 重用；Megrez 無 LM 查詢快取 |
| **`CandidatePair` 重設計** | `@frozen` + `Sendable`，僅承載 `(keyArray, value)` 身份；權重完全由 `CandidatePairWeighted` 承載 |
| **`Homa.Exception` 型別化錯誤** | 12 種具體例外（取代 Megrez 的 `Bool` 回傳） |
| **`PerceptionIntel` + `BehaviorPerceptor` 回呼** | 結構化觀測型別 + Assembler 級觀測注入（Phase 32 已反向移植至 Megrez） |
| **Consolidator Perceptor 隔離** | 鞏固期間 `perceptor = nil` + defer 恢復，防止假觀測 |

#### (D) Megrez 既有特性的增強版本

| 特性 | Megrez | Homa 增強 |
|------|--------|----------|
| `overrideCandidate` 回傳 | `Bool` | `throws(Exception)` + 更豐富的失敗語義 |
| 游標導航 | 回傳 `Bool` | `throws(Exception)` 包裝 |
| `Config` / `CompositorConfig` | 含 `separator` 欄位 | 移除 `separator`；新增 `hardCopy` computed property |
| `assignNodes()` | 回傳 `Int`（節點數） | `throws` if 無節點被指派 |

---

## 三、調研結論（Phase 32 術後修訂）

### 3.1 LMPerceptionOverride 與 LX_Perceptor 的差距已顯著縮小

Phase 31 調研報告判定 LX_Perceptor 在五個維度全面優於 LMPerceptionOverride。Phase 32 手術後，其中三個維度已被消弭：

| Phase 31 指出的差距 | Phase 32 改善 | 剩餘差距 |
|-------------------|-------------|---------|
| 職責分離不足（觀測 + I/O 耦合 ~1480 行） | ✅ WAL 抽離至 `PerceptionPersistor`，POM 本體退化為純觀測邏輯 | POM 本體仍 ~1000 行（含 LRU / bleach / `generateKeyForPerception`），LX_Perceptor ~786 行 |
| `kDecayThreshold` 過嚴（-9.5 vs -13.0） | ✅ 已統一為 -13.0 | **已消弭** |
| UserDefaults 熱路徑讀取 | ✅ `reducedLifetime` 改為建構期注入，`calculateWeight()` 為純函式 | **已消弭** |
| 缺少結構化測試 | ✅ `POMRapidForgetTests` 3/3 | LX_Perceptor 仍有 14 項測試 vs POM 3 項 |
| 無 Bigram 感知 | 未處理（屬 Homa 專有特性） | 需 Homa 遷移才能取得 |

### 3.2 雙端觀測記憶壽命行為已統一

Phase 32 的 `kDecayThreshold` 統一（-9.5 → -13.0）和 `reducedLifetime` 注入確保了：

- **正常模式**：8 天時間窗，`kDecayThreshold = -13.0`——兩端行為完全一致。
- **急速遺忘模式**：LMPerceptionOverride 現可透過 `reducedLifetime = true` 注入銳減至 0.5 天窗——語義上對應 LX_Perceptor 的固定 8 天窗（後者尚無 `reducedLifetime` 支援，但擴展為小幅改動）。
- **衰減曲線**：二次曲線 `ageFactor = ageNorm²` + Unigram 加速衰減（×0.85 無前文、×0.8 單字）——兩端完全一致。

### 3.3 Homa + LXKit + LX_Perceptor 遷移施術思路（修訂版，含特性吸收分析）

Phase 32 的低風險手術已達成三個預期效果：
1. **降低了 Homa 遷移的介面落差**——Megrez 與 Homa 的 Perceptor API 已語義對齊，遷移時 `InputHandler` 端的觀測接線代碼可幾乎零修改複用。
2. **PerceptionPersistor 的抽離為 LX_Perceptor 替換鋪平了道路**——POM 核心已與 I/O 解耦，替換觀測模組時只需替換 POM 本體，持久化層可不變。
3. **`kDecayThreshold` 統一消除了雙端行為不一致風險**——遷移期間不再需要擔心觀測記憶壽命差異造成的使用者體感斷層。

此外，§2.3 的特性吸收分析揭示了一個改變遷移策略的關鍵事實：**Homa 的上下文鞏固和候選字輪替並非全新特性，而是 Typewriter/InputHandler 既有邏輯被向下吸收至 Assembler 的結果。** 這意味著：

- Stage A 手術對 InputHandler 的改動中，很大一部分是**刪除已被 Homa 內化的代碼**（consolidation 迴圈、revolve 重試邏輯），而非寫新接線代碼。
- Stage A 完成後，InputHandler 的職責將顯著收窄：只保留 POM 建議讀取/套用、關聯詞語、輸入法模式切換等 IME 應用層邏輯。
- 因此 Stage A 的**難度評估需要下修**——從「高」降至「中高」。

#### 影響範圍盤點（修訂，含特性吸收分析）

| 層級 | 涉及模組 | 改動性質 | 改動量級 | Phase 32 降低的風險 |
|------|---------|---------|---------|-------------------|
| 語言模型 | `LMInstantiator` → 需提供 `GramQuerier` 簽名的閉包 | **新增**適配層 | **中** | — |
| 組句器 | `Megrez.Compositor` → `Homa.Assembler` | **替換** | **大** | Perceptor 接線邏輯可直接複用 |
| 觀測模組 | `LMPerceptionOverride` → `LX_Perceptor` | **替換** | **中→低** | 持久化已獨立；`kDecayThreshold` 已對齊；`reducedLifetime` 注入模式可沿用 |
| InputHandler 鞏固邏輯 | `consolidateCursorContext()` + `calculateConsolidationBoundaries()` | **刪除**（Homa 已內化） | **中**（需驗證刪除正確性） | — |
| InputHandler 輪替邏輯 | `revolveCandidate()` 的 20 次重試迴圈 | **精簡**（委派 Homa） | **中** | — |
| InputHandler 選字流程 | `consolidateNode()` / `retrievePOMSuggestions()` | **重構** | **大→中** | Perceptor Lambda 已到位 |
| 候選字型別 | `Megrez.KeyValuePaired` → `Homa.CandidatePair` | **型別映射** | **小** | — |
| 組句結果型別 | `Megrez.GramInPath` → `Homa.GramInPath` | **型別映射** | **小** | — |

#### 施術路線（四階段，Phase 32 術後修訂）

> 與先前版本相比，階段 A 被拆分為 A1（組句器替換）和 A2（InputHandler 精簡）。這反映了特性吸收分析帶來的認知更新：Homa 替換不僅是「換引擎」，同時也是「從 InputHandler 刪除已被引擎吸收的邏輯」。

**階段 A1：Homa 替換 Megrez（引擎替換）**

1. `Package.swift`：將 `vChewing_Megrez` 依賴替換為 `vChewing_Homa`（或引入 LibVanguard 的 Homa 模組）。
2. `InputHandler` 層的組句器接線：
   - `Megrez.Compositor` → `Homa.Assembler`。
   - `langModel` 屬性替換為 `gramQuerier` / `gramAvailabilityChecker` closure 重綁定。
   - **Perceptor 接線可直接搬遷**——Phase 32 已使 Megrez 與 Homa 的 perceptor 介面語義一致，`compositor.perceptor = { … }` → `assembler.perceptor = { … }`。
   - `assembler.fetchCandidates()` — 回傳型別從 `[KeyValuePaired]` 改為 `[CandidatePair]`，需適配下游候選窗。
3. `LMInstantiator`：
   - 新增 `func gramsFor(keyArray:) -> [Homa.GramRAW]`，短期 `previous` 一律 `nil`。
   - `pomReducedLifetime` 轉發機制可直接沿用。
4. 型別映射：見第四章附錄 4.3。
5. **NodeOverrideStatus 鏡像 API**：Megrez 已有 `createNodeOverrideStatusMirror()` / `restoreFromNodeOverrideStatusMirror()`，與 Homa 語義一致——`previewCurrentCandidateAtCompositionBuffer()` 等使用鏡像的代碼可近乎零修改搬遷。

**階段 A2：InputHandler 精簡（刪除已被 Homa 吸收的邏輯）**

Homa 內化了 Typewriter 的鞏固與輪替邏輯後，InputHandler 中的以下代碼可被刪除或大幅精簡：

| 待刪除/精簡的 InputHandler 代碼 | 替代方案 |
|-------------------------------|----------|
| `consolidateCursorContext(with:explicitlyChosen:)` (~100 行) | 直接呼叫 `assembler.consolidateCandidateCursorContext(for:cursorType:)` |
| `calculateConsolidationBoundaries(for:explicitlyChosen:)` (~80 行) | Homa 內部已包含等價邊界計算 |
| `revolveCandidate(reverseOrder:)` 的 20 次重試迴圈 (~90 行) | 直接委派 `assembler.revolveCandidate(cursorType:counterClockwise:)`；原先暫留的 parity fallback 已隨 Homa follow-up 一併移除 |
| `consolidateNode()` 中的 4 次覆寫 + POM 漂白迴圈 (~80 行) | Homa 的 `overrideCandidate` + Assembler 級 `perceptor` 自動處理觀測 |

預估 InputHandler 可淨刪除 250–350 行代碼，同時獲得 Homa 帶來的增強語義：
- `throws(Homa.Exception)` 取代 `Bool` 回傳，錯誤處理更精確。
- `CandidateCursor` 參數化取代硬編碼的 macOS 前置游標，為未來支援微軟風格後置游標留出空間。
- Consolidator Perceptor 隔離（鞏固期間自動禁用觀測）取代手動的 `skipObservation` 旗標傳遞。

**注意**：A2 與 A1 高度耦合，建議在同一手術週期內完成。拆分僅為了在規劃層面釐清「替換」與「精簡」的不同性質。

**階段 B：LX_Perceptor 替換 LMPerceptionOverride**

Phase 32 的架構整理使此階段的施術難度由「中」降至「低」：

1. **POM 核心替換**：將 `LMPerceptionOverride` 替換為 `LX_Perceptor`。核心演算法等價、`kDecayThreshold` 已統一、時間窗語義一致——切換近乎透明。
2. **持久化層保留**：`PerceptionPersistor` 已獨立存在，不依賴 POM 核心邏輯。替換 POM 時只需：
   - `LX_Perceptor.getSavableData()` 的輸出格式與現有 `[KeyPerceptionPair]` JSON 結構語義一致，`PerceptionPersistor` 可直接承接。
   - 或者簡化為單層快照（500 entries 的 JSON 延遲在微秒量級），棄用 WAL 日誌。
3. **`reducedLifetime` 注入模式沿用**：Phase 32 新增的 `reducedLifetime` 屬性注入模式可直接移植至 LX_Perceptor（後者目前為固定 8 天；擴展為可注入的 `reducedLifetime` 旗標是小幅改動）。
4. **舊資料遷移**：LMPerceptionOverride 的 JSON 快照格式與 LX_Perceptor 的 `[KeyPerceptionPair]` 結構語義一致，可直接讀取，無需格式轉換。

**階段 C：Bigram 啟用（長期）**

與 Phase 31 報告一致：

1. 確認 VanguardTextMap 格式是否已承載 Bigram 資料。
2. `LMInstantiator.gramsFor(keyArray:)` 開始填充 `previous` 欄位。
3. Homa 的 `Node.getScore(previous:)` 自動啟用 Bigram 路徑——無需組句器側改動。

#### 預估工作量（修訂，含特性吸收分析）

| 階段 | 檔案數 | 改動性質 | 關鍵風險 | 預估難度 |
|------|--------|---------|---------|--------|
| A1（Homa 替換 Megrez） | ~10-15 | 引擎替換 + 型別映射 | API 映射遺漏、候選窗型別適配 | **中高** |
| A2（InputHandler 精簡） | ~3-5 | 刪除被吸收的邏輯 | 刪除過多導致功能缺失 | **中**（需充分的回歸測試） |
| B（LX_Perceptor 替換 POM） | ~5-8 | POM 核心替換 | 舊資料格式相容 | **低** |
| C（Bigram 啟用） | ~2-3 | LM 層填充 | 辭典資料供給 | **低** |

### 3.4 「漸進演化」vs「直接替換」路線評估（修訂，含特性吸收修正）

Phase 31 列舉了六項漸進改動，Phase 32 已實施其中四項：

| 改動 | Phase 31 狀態 | Phase 32 後 | 特性吸收修正 |
|------|-------------|-----------|------------|
| Megrez 新增 Assembler 級 `perceptor` 注入 | 建議中 | ✅ 已完成 | — |
| Megrez `LangModelProtocol` 保留但新增 closure init | 建議中 | 未實施 | ROI 不高，留給 Homa 遷移一步到位 |
| Megrez `Unigram` 新增 `previous` + Bigram 支援 | 建議中 | 未實施 | (C) 類新增特性，留給 Homa + 階段 C |
| Megrez 新增 `consolidateCandidateCursorContext` | 建議中（標記為「代價過高」） | 未實施 | ⚠️ **Phase 31 的判斷需修正**——此邏輯已存在於 InputHandler，「在 Megrez 上重建 = 重寫 Homa 的一半」的說法不準確。實際只是將 InputHandler 邏輯下移至 Compositor 內。但考慮到 Homa 遷移後此代碼自然由 Homa 提供，在 Megrez 上追加仍屬短壽命改動。 |
| LMPerceptionOverride `kDecayThreshold` → -13.0 | 建議中 | ✅ 已完成 | — |
| LMPerceptionOverride WAL 抽離為純邏輯模組 | 建議中 | ✅ 已完成 | — |

**修訂結論**：Phase 32 已「摘完所有低垂的果實」。對剩餘項目的判斷修正如下：

- **`LangModelProtocol` → Closure**：仍不值得追加。Homa 的 Lambda 介面設計是為了配合 Bigram 語義（`GramRAW` 含 `previous`），在沒有 Bigram 的 Megrez 上做此改造收益為零。
- **Consolidator**：Phase 31 將其標記為「代價過高——在 Megrez 上重建等於重寫 Homa 的一半」。這不完全準確：鞏固邏輯已在 InputHandler 中實現（§2.3 Category A），下移至 Megrez 的工程量並不等於「重寫 Homa 的一半」。然而，考慮到 Homa 遷移後 InputHandler 中的鞏固代碼將被直接刪除、由 Homa 內建版本接管，此項追加仍屬短壽命改動。不做是正確的，但理由是「短壽命」而非「代價過高」。
- **Bigram**：此為 Homa 的 (C) 類真正新增特性，Megrez 無法漸進取得。

**修訂後的混合路線**：

1. ~~**立即可做**（已完成）~~：
   - ~~Megrez Perceptor 注入~~ ✅
   - ~~`kDecayThreshold` 統一~~ ✅
   - ~~WAL 抽離~~ ✅
   - ~~`reducedLifetime` 注入~~ ✅

2. **中期目標**（下一手術週期）：
   - **階段 A1**：引擎替換 Megrez → Homa。
   - **階段 A2**：InputHandler 精簡——刪除被 Homa 吸收的鞏固/輪替邏輯（~250-350 行），委派 Homa 內建 API。A1 與 A2 建議在同一週期完成。
   - **階段 B**：同步替換 LMPerceptionOverride → LX_Perceptor。
   - Phase 32 的 Perceptor 接線對齊 + 特性吸收帶來的代碼精簡，預計使 `InputHandler` 層的淨改動量（新增 - 刪除）顯著低於先前估計。

3. **長期**：
   - Bigram 啟用（階段 C）。
   - 評估將 `LMInstantiator` 遷移至 LXKit `TrieHub` 體系。

---

## 四、附錄

### 4.1 衰減公式與常數對照

$$f_{\text{age}} = \left(\max\left(0,\ 1 - \frac{\Delta_{\text{days}}}{T}\right)\right)^{2}$$

$$f_{\text{freq}} = \min\left(1,\ 0.5\sqrt{\frac{\text{count}}{\text{totalCount}}} + 0.5 \cdot \frac{\ln(1 + \text{count})}{\ln 10}\right)$$

$$T = W_{\text{base}} \times \begin{cases} 0.85 & \text{if unigram (no context)} \\ 0.85 \times 0.8 & \text{if single-char unigram} \\ 1.0 & \text{otherwise} \end{cases}$$

$$W_{\text{base}} = \begin{cases} 0.5 & \text{if } \texttt{reducedLifetime} = \text{true（急速遺忘模式）} \\ 8.0 & \text{otherwise（正常模式）} \end{cases}$$

| 常數 | LMPerceptionOverride（Phase 32 後） | LX_Perceptor |
|------|--------------------------------------|--------------|
| `kWeightMultiplier` | Beast Constant ≈ 0.114514 | 0.114514 |
| `kDecayThreshold` | **-13.0** | **-13.0** |
| 預設時間窗 | 8 天（可注入 `reducedLifetime` 銳減至 0.5 天） | 8 天（固定） |

### 4.2 Phase 32 PerceptionPersistor 架構

```
LMPerceptionOverride（純觀測邏輯）
├── memorizePerception()  → markKeyForUpsert() → 委派 persistor.saveData()
├── bleachXxx()           → markKeyForRemoval() → 委派 persistor.saveData()
├── loadData()            → 委派 persistor.loadData()
└── clearData()           → 委派 persistor.clearDataOnDisk()

PerceptionPersistor（純 I/O 邏輯）
├── saveData(dataProvider:mapProvider:keyValidator:)
│   ├── 增量路徑：追加 WAL journal entries（upsert / removeKey）
│   └── 壓縮路徑：120 條日誌或 64KB → 全量 JSON snapshot + CRC32 去重
├── loadData(loadCallback:replayApplicator:keyValidator:)
│   ├── 讀取 snapshot → 交由 loadCallback 還原
│   └── 重播 WAL journal → 交由 replayApplicator 增量套用
├── clearDataOnDisk()
├── markKeyForUpsert(_:)
├── markKeyForRemoval(_:)
└── resetPendingState()
```

### 4.3 Megrez → Homa API 映射速查表

| Megrez API | Homa API | 備註 |
|-----------|---------|------|
| `Compositor(with: langModel, separator:)` | `Assembler(gramQuerier:, gramAvailabilityChecker:, perceptor:)` | 建構方式完全不同 |
| `compositor.langModel = newLM` | `assembler.gramQuerier = { … }` | 需重綁三個 closure |
| `compositor.perceptor = { … }` | `assembler.perceptor = { … }` | ✅ **Phase 32 後語義一致** |
| `compositor.insertKey(_:)` | `assembler.insertKey(_:)` | 同名 |
| `compositor.dropKey(direction:)` | `assembler.dropKey(direction:)` | 同名同語義 |
| `compositor.assemble()` | `assembler.assemble()` | 同名，回傳 `[GramInPath]` |
| `compositor.cursor` / `.marker` / `.keys` | `assembler.cursor` / `.marker` / `.keys` | 同名同語義 |
| `compositor.fetchCandidates(at:filter:)` | `assembler.fetchCandidates(at:filter:)` | 回傳型別不同：`KeyValuePaired` vs `CandidatePair` |
| `compositor.overrideCandidate(…, perceptionHandler:)` | `assembler.overrideCandidate(…, perceptionHandler:)` | ✅ **Phase 32 後參數語義一致** |
| `compositor.overrideCandidateLiteral(…, perceptionHandler:)` | `assembler.overrideCandidateLiteral(…, perceptionHandler:)` | ✅ **Phase 32 後參數語義一致** |
| `Megrez.makePerceptionIntel(prev:curr:cursor:)` | `Homa.makePerceptionIntel(prev:curr:cursor:)` | 同名同語義 |
| `compositor.maxSegLength` | `assembler.maxSegLength` | 同名 |
| `compositor.length` | `assembler.length` | 同名 |
| `compositor.assembledSentence` | `assembler.assembledSentence` | 同名 |
| N/A | `assembler.revolveCandidate(at:…)` | Homa 獨有 |
| N/A | `assembler.consolidateCandidateCursorContext(…)` | Homa 獨有 |
| `compositor.clear()` | `assembler.clear()` | 同名 |

### 4.4 Phase 32 術後資料流

**現狀（Phase 32 後，Megrez 架構）：**

```
NSEvent
  → SessionCtl → InputSession → InputHandler
                                    │
                                    ├─ assembler: Megrez.Compositor
                                    │      ├─ langModel: LMInstantiator (LangModelProtocol)
                                    │      │     ├─ unigramsFor(keyArray:)
                                    │      │     └─ fetchPOMSuggestion(assembledResult:cursor:timestamp:)
                                    │      │           └─ LMPerceptionOverride.fetchSuggestion()
                                    │      │
                                    │      └─ perceptor: ((PerceptionIntel) -> ())?  ← Phase 32 新增
                                    │            └─ 由 InputHandler 注入 POM 觀測 closure
                                    │
                                    ├─ consolidateNode()                          ← 將被 Homa 吸收
                                    │      ├─ consolidateCursorContext()           ← 將被 Homa 吸收
                                    │      ├─ retrievePOMSuggestions(apply:false)
                                    │      ├─ assembler.overrideCandidate(perceptionHandler:)
                                    │      │      └─ defer { makePerceptionIntel → (handler ?? perceptor)? }
                                    │      └─ assembler.assemble()
                                    │
                                    ├─ revolveCandidate()                         ← 將被 Homa 吸收
                                    │      └─ 20 次重試 + consolidateNode(preConsolidate:)
                                    │
                                    └─ retrievePOMSuggestions(apply:true)
                                           ├─ currentLM.fetchPOMSuggestion(assembledSentence, cursor)
                                           └─ assembler.overrideCandidate() + assemble()
```

**目標（Homa 遷移後）：**

```
NSEvent
  → SessionCtl → InputSession → InputHandler
                                    │
                                    ├─ assembler: Homa.Assembler
                                    │      ├─ gramQuerier: ([String]) -> [GramRAW]    ← closure 捕獲 LMInstantiator
                                    │      ├─ gramAvailabilityChecker                ← closure 捕獲 LMInstantiator
                                    │      ├─ perceptor: ((PerceptionIntel) -> ())?  ← Phase 32 接線直接沿用
                                    │      │
                                    │      ├─ consolidateCandidateCursorContext()    ← 引擎內建（取代 InputHandler 邏輯）
                                    │      └─ revolveCandidate()                     ← 引擎內建（取代 InputHandler 邏輯）
                                    │
                                    ├─ consolidateNode()                          ← 大幅精簡
                                    │      ├─ assembler.consolidateCandidateCursorContext()  ← 一行取代 ~100 行
                                    │      ├─ retrievePOMSuggestions(apply:false)
                                    │      ├─ assembler.overrideCandidate()  ← perceptor 自動觸發觀測
                                    │      └─ assembler.assemble()
                                    │
                                    └─ retrievePOMSuggestions(apply:true)
                                           ├─ currentLM.fetchPOMSuggestion(assembledSentence, cursor)
                                           └─ assembler.overrideCandidate() + assemble()
```

注意：理想情況下，Homa 遷移後 InputHandler 的 `revolveCandidate()` 方法體可精簡為約 20 行（候選字獲取 + `assembler.revolveCandidate()` 呼叫 + 狀態更新）。這個目標已在 Phase 33 follow-up 實現：`consolidateCursorContext()` 已縮成單行委派，`revolveCandidate()` 也已完全直通 Homa。先前暫留的 parity fallback 已在 Homa standalone revolver 與 consolidation span bug 修復後移除。

### 4.5 Homa ↔ LexiconKit ↔ Perceptor 目標整合架構（不變）

```
┌─────────────┐   captures   ┌──────────────────────┐
│ Perceptor   │◄─────────────┤ BehaviorPerceptor λ  │
│ (LexiconKit)│              │ { perceptor.memorize… }│
└─────────────┘              └──────────┬───────────┘
                                        │
┌─────────────┐   captures   ┌──────────┴───────────┐
│ TrieHub     │◄─────────────┤ GramQuerier λ        │
│ (LexiconKit)│              │ { hub.queryGrams(…) } │
│             │◄─────────────┤ GramAvailChecker λ   │
│             │              │ { hub.hasGrams(…) }   │
└─────────────┘              └──────────┬───────────┘
                                        │
                             ┌──────────▼───────────┐
                             │   Homa.Assembler      │
                             │ .gramQuerier          │
                             │ .gramAvailabilityChk  │
                             │ .perceptor            │
                             └───────────────────────┘

Homa 完全不 import LexiconKit。耦合只透過三個 closure typealias。
```

---

## 五、結語

Phase 32 完成了所有低風險的架構對齊手術。Megrez 的 Perceptor Lambda API 已與 Homa 語義一致；LMPerceptionOverride 的 I/O 已解耦至獨立持久化層；觀測衰減行為在兩端完全統一。

本次修訂的特性吸收分析（§2.3）修正了先前對 Homa 特性的認知偏差：

- **先前認知**：Homa 的上下文鞏固（Consolidator）和候選字輪替（Revolver）是「Homa 獨有的新特性」，Megrez 無法漸進取得；在 Megrez 上重建等於「重寫 Homa 的一半」。
- **修正認知**：這些是 Typewriter/InputHandler 既有邏輯被向下吸收至 Assembler 的結果。Megrez 本身沒有這些 API，但等價演算法已在 InputHandler 中運行多年。遷移至 Homa 時，InputHandler 中的這些代碼應被**刪除**（委派 Homa），而非「重寫」。

因此，**剩餘的 Megrez↔Homa 差距應重新分類**：

| 差距類型 | 具體項目 | 遷移策略 |
|---------|---------|----------|
| **(C) 真正新增特性** | Bigram 支援、`gramQueryCache`、`CandidateCursor` 游標抽象、`Homa.Exception` 型別化錯誤 | Homa 遷移自然取得 |
| **(A) 吸收自 InputHandler 的特性** | Consolidator、Revolver 重試邏輯、邊界計算 | Homa 遷移 + 刪除 InputHandler 冗餘代碼 |
| **(D) 增強版本** | `CandidatePair` 重設計、`throws` 語義、Config 精簡 | 型別映射 + 錯誤處理適配 |

其中只有 **(C) 類**是 Megrez 無法漸進取得的——而這些正是遷移至 Homa 最有價值的收益所在（尤其是 Bigram 支援對組句品質的提升）。

Phase 32 的戰術價值在於：它讓「直接替換」的手術風險降低了——Perceptor 接線已驗證、閾值已統一、持久化已解耦——使得中期的 Homa 遷移可以專注於引擎替換 + InputHandler 精簡兩個核心主題，而非同時處理觀測體系的結構性差異。
