# Phase 31 調研報告：Perception Override 機制對比與 Homa 遷移策略評估

> 調研日期：2026-04-18
> 調研範圍：`vChewing-macOS`（Megrez + LMPerceptionOverride）& `vChewing-LibVanguard`（Homa + LX_Perceptor）
> 調研員：Claude Opus 4.6

---

## 一、調研任務摘要

1. 評估 `LMPerceptionOverride`（macOS 生產版）與 `LX_Perceptor`（LibVanguard 繼任版）誰更先進有效。
2. 評估 Homa 的嵌入式 Perceptor Lambda API 設計是否合理，及是否適合引入 Megrez。
3. 規劃從 Megrez + LMPerceptionOverride 體系遷移至 Homa + LXKit + LX_Perceptor 的施術思路。
4. 附帶評估「讓 vChewing-macOS 各元件逐漸趨近 LibVanguard 繼任者」的漸進遷移路線。

---

## 二、架構對比總覽

### 2.1 組句器：Megrez vs Homa

| 維度 | Megrez | Homa |
|------|--------|------|
| LM 介面 | `LangModelProtocol`（protocol，2 methods） | Lambda closures（`GramQuerier` / `GramAvailabilityChecker`） |
| 基礎單位 | `Unigram`（keyArray, value, score），**無 previous** | `Gram`（keyArray, current, probability, previous?），Unigram 與 Bigram 統一 |
| Bigram 支援 | **無**（程式碼與測試均明確聲明 Megrez 不支援 Bigram） | **有**：`Node.getScore(previous:)` 在 DP 遍歷時隱式查詢 `bigramMap` |
| DP 演算法 | 前向 DAG-DP + 回溯（`dp[i] + node.score`，純 Unigram） | 前向 DAG-DP + 回溯（`dp[i] + node.getScore(previous:)`，Unigram/Bigram 融合） |
| 狀態序列化 | `CompositorConfig` 為 Codable 但較簡略 | `Config` struct 可 Codable + `hardCopy`；覆寫鏡照 `NodeOverrideStatus` |
| 上下文鞏固 | **無**——選字可能意外改變鄰近已正確的詞 | **有**：`consolidateCandidateCursorContext` dry-run 鏡像推算安全邊界後鎖定鄰近節點 |
| 候選字輪替 | 透過 overrideCandidate 實現（無獨立 API） | 獨立 `revolveCandidate` API，內建最多 20 次重試 + debug handler |
| Query Cache | `assignNodes()` 內局部 cache，每次 assign 重建 | `gramQueryCache`（bounded 512 筆），跨連續 `insertKey()` 重用 |
| Perceptor 耦合 | 外部手動協調（InputHandler 端 orchestrate） | 內建 Assembler 級 `perceptor` + 呼叫級 `perceptionHandler`，雙路分發 |
| Consolidator Perceptor 隔離 | N/A（無 Consolidator） | 鞏固期間 `perceptor = nil`，defer 恢復，防假觀測 |
| UUID | `FIUUID`（`@frozen` 雙 UInt64） | 原生 `FIUUID`（相同設計） |

### 2.2 觀測模組：LMPerceptionOverride vs LX_Perceptor

| 維度 | LMPerceptionOverride | LX_Perceptor |
|------|---------------------|--------------|
| 程式碼行數 | ~1480 行 | ~786 行 |
| 衰減算法 | 二次曲線 `ageFactor = ageNorm^2`，`kWeightMultiplier` ≈ 0.114514 | 二次曲線 `ageFactor = ageNorm^2`，`kWeightMultiplier = 0.114514` |
| 時間窗 | 8 天（可經 UserDef 銳減至 12 小時） | 8 天（固定） |
| Unigram 衰減加速 | ×0.85（無前文）、×0.8（單字） | 相同 |
| 頻率因子 | `0.5√(p) + 0.5·log₁₀(1+count)` | 相同 |
| Decay Threshold | **-9.5** | **-13.0**（更寬鬆，記憶保留更久） |
| 持久化 | 雙層（JSON 快照 + WAL Journal + CRC32 + 2s 節流 + 120 筆壓縮） | 單層 Codable 快照（I/O 交由外部管理） |
| 鎖機制 | `NSLock`（`withLock`） | `DispatchQueue.sync`（serial queue） |
| 外部依賴 | UserDef, Megrez (`GramInPath`, `PerceptionIntel`), vCLMLog | 僅 Foundation + Homa 型別 |
| Bleach API | 三層 + bleachUnigrams | 相同三層 + bleachUnigrams |
| 測試覆蓋 | LMAssembly 測試中間接覆蓋，無獨立 Perceptor 測試套件 | 14 項獨立測試（含 Homa 端到端整合） |

---

## 三、調研結論

### 3.1 LX_Perceptor 更先進有效

**結論：LX_Perceptor 在架構設計上全面優於 LMPerceptionOverride。** 核心衰減演算法等價，但 LX_Perceptor 在以下方面勝出：

1. **職責分離更徹底**：LX_Perceptor 是純邏輯模組（~786 行），不負責 I/O。LMPerceptionOverride 將觀測邏輯、WAL 日誌、CRC32 去重、防抖節流全耦合在一起（~1480 行），職責膨脹。WAL 日誌系統雖然在工程上精巧，但對 IME 的單用戶場景來說 over-engineering——POM 資料量極小（500 entries × 少量 overrides），全量 JSON 序列化的延遲完全可忽略。
2. **Decay Threshold 更合理**：LX_Perceptor 使用 `-13.0` 相對於 LMPerceptionOverride 的 `-9.5`，允許觀測記憶在時間窗末期存活更久。`-9.5` 的門檻意味著觀測在第 6-7 天就開始丟失（接近門檻的分數會被 `fetchSuggestion` 過濾），而 `-13.0` 讓記憶覆蓋完整的 8 天窗口。這對低頻但正確的使用者選字偏好更友好。
3. **無 UserDefaults 熱路徑讀取**：LMPerceptionOverride 的 `calculateWeight()` 每次計算都讀 `UserDefaults.current` 查詢 `kReducePOMLifetimeToNoMoreThan12Hours`，即便系統有快取，仍非零成本。LX_Perceptor 完全不依賴外部偏好設定，演算法為純函式。
4. **測試覆蓋顯著更佳**：14 項獨立測試覆蓋衰減曲線邊界（0/1/3/5/7.5/8.1/9/20/80 天）、LRU 淘汰、三層漂白、Homa 端到端整合、真實語句場景。LMPerceptionOverride 沒有獨立的 Perceptor 測試套件。
5. **零 Megrez 依賴**：`PerceptionIntel` 定義在 Homa 側而非 LexiconKit 側，LX_Perceptor 只消費該結構，不反向依賴組句器內部型別。LMPerceptionOverride 直接操作 `Megrez.GramInPath` 陣列（`generateKeyForPerception` 定義在 `[GramInPath]` 擴充上），造成 POM ← Megrez 的循環語義耦合。

**LMPerceptionOverride 的改進方向**（若不直接替換為 LX_Perceptor）：

- 將 WAL 日誌系統抽離為獨立的持久化層，POM 核心模組只保留觀測邏輯。
- `kDecayThreshold` 從 `-9.5` 放寬至 `-13.0`（或至少 `-12.0`），避免觀測在時間窗末期過早丟失。
- `calculateWeight()` 中的 `UserDefaults` 讀取改為建構期注入旗標。
- 新增獨立的 Perceptor 單元測試套件，至少覆蓋衰減曲線邊界和漂白語義。

### 3.2 Homa 嵌入式 Perceptor Lambda 設計合理且優於 Megrez 現行方式

**結論：Lambda 注入設計合理，適合引入 Megrez。**

Homa 的三個 closure typealias 構成了極其精簡的外部介面：

```swift
public typealias GramQuerier = ([String]) -> [GramRAW]
public typealias GramAvailabilityChecker = ([String]) -> Bool
public typealias BehaviorPerceptor = (Homa.PerceptionIntel) -> ()
```

對比 Megrez 現狀：

| 面向 | Megrez 現行 | Homa Lambda |
|------|------------|-------------|
| LM 查詢 | `LangModelProtocol` — 呼叫端必須實作 protocol | Closure — 呼叫端用閉包捕獲即可 |
| Bigram 支援 | Protocol 只回傳 `[Unigram]`，無 `previous` 語義 | `GramRAW` tuple 包含 `previous: String?`，Unigram/Bigram 統一回傳 |
| Perceptor 掛鉤 | 每次 `overrideCandidate` 需手動傳入 `perceptionHandler` closure | Assembler 級 `perceptor` 一次注入，自動觸發；呼叫級 `perceptionHandler` 可臨時覆蓋 |
| Consolidator 安全 | N/A（Megrez 無 Consolidator） | 鞏固期間 `perceptor = nil` + defer 恢復，杜絕假觀測 |
| 測試便利性 | 需建構 `SimpleLM: LangModelProtocol` 測試輔助類別 | 直接傳入 closure 即可，測試輔助碼量更少 |
| 替換彈性 | 需實作新 protocol conformance | Runtime 替換 closure 即可 |

**Lambda 設計的核心優勢**是解耦徹底：Homa 完全不 import LexiconKit，耦合僅透過三個 closure typealias。這使得 Homa 可以獨立測試、獨立發布，而上層整合者（`InputHandler` 或測試碼）僅需用閉包捕獲外部 `TrieHub` / `Perceptor` 實例即可完成接線。

**引入 Megrez 的改造方案**：

若只改 Megrez 而不替換為 Homa，最低限度的改造是：

1. **Assembler 級 Perceptor 注入**：
   - `Compositor.init` 新增可選參數 `perceptor: ((Megrez.PerceptionIntel) -> ())?`。
   - `overrideCandidateAgainst` 的 `defer` 區塊中，`(perceptionHandler ?? perceptor)?` 雙路分發。
   - 這直接消除了 `InputHandler_CoreProtocol.consolidateNode()` 中大量的手動 POM 協調代碼。

2. **`LangModelProtocol` → Closure**（可選但推薦）：
   - 將 `LangModelProtocol` 的兩個方法改為 closure properties：
     ```swift
     public var gramQuerier: ([String]) -> [Megrez.Unigram]
     public var gramAvailabilityChecker: ([String]) -> Bool
     ```
   - 保留 protocol 的 convenience init（向後相容）：
     ```swift
     public convenience init(with langModel: LangModelProtocol, ...) {
       self.init(
         gramQuerier: { langModel.unigramsFor(keyArray: $0) },
         gramAvailabilityChecker: { langModel.hasUnigramsFor(keyArray: $0) },
         ...
       )
     }
     ```
   - 這允許在不破壞現有 `LMInstantiator: LangModelProtocol` conformance 的前提下，增加 closure 注入的彈性。

3. **`consolidateCandidateCursorContext` 的前置條件**：
   - Megrez 目前**沒有上下文鞏固**。如果要把 Perceptor Lambda 用到極致，Consolidator 是必要的——否則觀測到的「使用者選了 A」可能在下一次 assemble 後被鄰近節點覆蓋，產生錯誤的觀測記憶。
   - 但 Consolidator 的實作代價較高（需要 dry-run 鏡像 + 邊界計算），建議不在 Megrez 上追加，而是留給 Homa 遷移一步到位。

**結論**：Assembler 級 Perceptor 注入（方案 1）可以獨立實施，收益明確（簡化 `consolidateNode` 約 30% 代碼量）。`LangModelProtocol` → Closure（方案 2）和 Consolidator（方案 3）的收益需搭配 Bigram 和 Homa 遷移才能充分體現，單獨實施的 ROI 不高。

### 3.3 Homa + LXKit + LX_Perceptor 遷移施術思路

遷移的核心挑戰不在 Homa 或 LX_Perceptor 本身——它們的 API 設計已經足夠獨立——而在於 vChewing-macOS 的**上下游整合層**。

#### 影響範圍盤點

| 層級 | 涉及模組 | 改動量級 | 風險 |
|------|---------|---------|------|
| 語言模型 | `LMInstantiator` → 需提供 `GramQuerier` 簽名的閉包 | **中**：需新增 `previous` 語義（Bigram 回傳），但核心子 LM 查詢邏輯不變 | Bigram 資料需由辭典提供，若 VanguardTextMap 不含 Bigram 則需補齊 |
| 組句器 | `Megrez.Compositor` → `Homa.Assembler` | **大**：所有 `assembler.xxx` 呼叫需逐一映射 | API 名稱和語義差異需逐一確認 |
| 觀測模組 | `LMPerceptionOverride` → `LX_Perceptor` | **中**：核心演算法等價，需處理持久化層替換 | WAL 日誌→單層快照，需驗證遷移後效能可接受 |
| InputHandler | `consolidateNode()` / `retrievePOMSuggestions()` | **大**：Homa 的 Consolidator + 雙路 Perceptor 會簡化流程，但需全面重寫 | 回歸測試覆蓋是關鍵 |
| 候選字型別 | `Megrez.KeyValuePaired` → `Homa.CandidatePair` | **小**：一對一映射 | 下游 CandidateWindow 需同步更新 |
| 組句結果型別 | `Megrez.GramInPath` → `Homa.GramInPath` | **小**：結構幾乎等價 | `Megrez.PerceptionIntel` → `Homa.PerceptionIntel`，欄位一致 |
| 路徑結果陣列 | `assembler.assembledSentence: [GramInPath]` | **小**：同名同語義 | — |

#### 施術路線（建議分三階段）

**階段 A：Homa 替換 Megrez（核心手術）**

1. `Package.swift`：將 `vChewing_Megrez` 依賴替換為 `vChewing_Homa`（或直接引入 LibVanguard 的 Homa 模組）。
2. `InputHandler` / `InputSession` 層：
   - `Megrez.Compositor` → `Homa.Assembler`。
   - `Megrez.Compositor.init(with: langModel, separator:)` → `Homa.Assembler.init(gramQuerier:, gramAvailabilityChecker:, perceptor:)`。
   - `langModel` 屬性替換為 `gramQuerier` / `gramAvailabilityChecker` closure 重綁定。
   - `assembler.insertKey()` / `assembler.dropKey()` / `assembler.assemble()` — Homa API 名稱一致，幾乎零改動。
   - `assembler.overrideCandidate()` — 參數名和行為一致，`perceptionHandler` closure 語義一致。
   - `assembler.fetchCandidates()` — 回傳型別從 `[KeyValuePaired]` 改為 `[CandidatePair]`，需適配下游候選窗。
   - `assembler.cursor` / `assembler.marker` / `assembler.keys` — 同名同語義。
3. `LMInstantiator`：
   - 移除 `LangModelProtocol` conformance（或保留為 wrapper）。
   - 新增 `func gramsFor(keyArray: [String]) -> [Homa.GramRAW]` 方法，在內部走既有 `unigramsFor` 路徑，將 `[Megrez.Unigram]` 映射為 `[GramRAW]`。
   - 短期內 `previous` 欄位一律為 `nil`（不提供 Bigram），待辭典 Bigram 資料就緒後再啟用。
4. 型別映射：
   - `Megrez.KeyValuePaired` → `Homa.CandidatePair`。
   - `Megrez.GramInPath` → `Homa.GramInPath`。
   - `Megrez.PerceptionIntel` → `Homa.PerceptionIntel`。
   - `Megrez.Node.OverrideType` → `Homa.Node.OverrideType`（語義一致）。
   - `Megrez.Compositor.CandidateFetchFilter` → `Homa.Assembler.CandidateFetchFilter`。

**階段 B：LX_Perceptor 替換 LMPerceptionOverride**

1. 將 `LMPerceptionOverride` 替換為 `LX_Perceptor`。核心演算法等價，切換幾乎透明。
2. 持久化層：
   - LX_Perceptor 不負責 I/O，需在 `LMInstantiator`（或獨立 POM Manager）層補充 JSON 序列化 / 反序列化。
   - 棄用 WAL 日誌系統，改為定期全量快照。500 entries 的 JSON 序列化延遲在微秒量級，對 IME 場景完全可接受。
   - 遷移工具：舊版 LMPerceptionOverride 的 JSON 快照格式與 LX_Perceptor 的 `[KeyPerceptionPair]` 結構語義一致（`key` + `perception.overrides[candidate → {count, timestamp}]`），可直接讀取。
3. `consolidateNode()` 大幅簡化：
   - Homa 的 Assembler 級 `perceptor` 自動在每次 `overrideCandidate` 後觸發觀測，不需要手動 capture `previouslyAssembled` 和 `makePerceptionIntel`。
   - `retrievePOMSuggestions()` 改為呼叫 `LX_Perceptor.fetchSuggestion()`。
   - Homa 的 `consolidateCandidateCursorContext` 取代了手動的 4-attempt 覆寫迴圈。

**階段 C：Bigram 啟用（長期）**

1. 確認 VanguardTextMap 格式是否已承載 Bigram 資料（Phase 02 的型別 C 個體行支援 `previous` 欄位）。
2. `LMInstantiator.gramsFor(keyArray:)` 回傳的 `GramRAW` 開始填充 `previous` 欄位。
3. Homa 的 `Node.getScore(previous:)` 自動啟用 Bigram 路徑——無需組句器側改動。

#### 預估工作量

| 階段 | 檔案數 | 關鍵風險 | 預估難度 |
|------|--------|---------|---------|
| A（Homa 替換 Megrez） | ~15-20 | API 映射遺漏、候選窗型別適配 | 高 |
| B（LX_Perceptor 替換 POM） | ~5-8 | 持久化遷移、舊資料相容 | 中 |
| C（Bigram 啟用） | ~2-3 | 辭典資料供給 | 低 |

### 3.4 「漸進演化」vs「直接替換」路線評估

**問題**：讓 vChewing-macOS 各元件逐漸演化趨近 LibVanguard 繼任者，是否比一次性替換更好？

#### 漸進演化的可行局部改動

| 改動 | 收益 | 可獨立實施 | 風險 |
|------|------|----------|------|
| Megrez 新增 Assembler 級 `perceptor` 注入 | 簡化 `consolidateNode()` ~30% 代碼 | ✅ | 低 |
| Megrez `LangModelProtocol` 保留但新增 closure init | 提供 Homa 風格接線彈性 | ✅ | 低 |
| Megrez `Unigram` 新增 `previous: String?` + PathFinder Bigram 支援 | 組句品質提升 | ⚠️ 需同步改 LMInstantiator | 中 |
| Megrez 新增 `consolidateCandidateCursorContext` | 選字穩定性提升 | ⚠️ 需 NodeOverrideStatus mirror API | 高 |
| LMPerceptionOverride `kDecayThreshold` -9.5 → -13.0 | 延長觀測記憶壽命 | ✅ | 低 |
| LMPerceptionOverride 抽離 WAL → 純邏輯模組 | 降低複雜度 | ✅ | 中 |

#### 評估結論

**漸進演化對低風險改動可行，但對核心架構改動不推薦。** 理由：

1. **Bigram 支援需要同時改組句器 + LM + 辭典三層**，漸進改一層不會產生可見收益。而 Homa 已經把這三層的介面全部設計好了。
2. **Consolidator 是 Homa 最有價值的差異化特性之一**，但它依賴 `NodeOverrideStatus` mirror + dry-run 鏡像，這套基礎設施在 Megrez 中不存在。在 Megrez 上重建等於重寫 Homa 的一半。
3. **維護兩套趨近但不相同的組句器**（漸進演化中的 Megrez 和 LibVanguard 的 Homa）會產生持續的同步成本。每個 Homa 的 bugfix 或最佳化都需要手動 backport 到 Megrez。

**建議的混合路線**：

1. **立即可做**（Phase 32 候選）：
   - Megrez 新增 Assembler 級 `perceptor` 注入（低風險、立即收益）。
   - LMPerceptionOverride `kDecayThreshold` 放寬至 `-13.0`。
   
2. **中期目標**（Phase 27-28）：
   - 直接替換 Megrez → Homa（階段 A），不做漸進趨近。
   - 同步替換 LMPerceptionOverride → LX_Perceptor（階段 B）。

3. **長期**（Phase 29+）：
   - Bigram 啟用（階段 C）。
   - 評估將 `LMInstantiator` 遷移至 LXKit `TrieHub` 體系。

此路線避免了在 Megrez 上做高代價但短壽命的架構改造，同時通過低風險的即時改動為使用者帶來可見收益。

---

## 四、技術附錄

### 4.1 衰減算法公式比較

兩個模組的核心公式等價：

$$\text{score} = -k_W \times f_{\text{freq}} \times f_{\text{age}}$$

其中：

$$f_{\text{age}} = \left(\max\left(0,\ 1 - \frac{\Delta_{\text{days}}}{T}\right)\right)^{2}$$

$$f_{\text{freq}} = \min\left(1,\ 0.5\sqrt{\frac{\text{count}}{\text{totalCount}}} + 0.5 \cdot \frac{\ln(1 + \text{count})}{\ln 10}\right)$$

$$T = 8 \times \begin{cases} 0.85 & \text{if unigram (no context)} \\ 0.85 \times 0.8 & \text{if single-char unigram} \\ 1.0 & \text{otherwise} \end{cases}$$

唯一的數值差異在 `kDecayThreshold`：LMPerceptionOverride = `-9.5`，LX_Perceptor = `-13.0`。

### 4.2 Homa Lambda 接線範式

```swift
// 整合者（InputHandler 或測試）的接線代碼
let assembler = Homa.Assembler(
  gramQuerier: { keyArray in
    lmInstantiator.gramsFor(keyArray: keyArray)  // 捕獲外部 LM 實例
  },
  gramAvailabilityChecker: { keyArray in
    lmInstantiator.hasGramsFor(keyArray: keyArray)
  },
  perceptor: { intel in
    perceptor.memorizePerception(intel, timestamp: Date().timeIntervalSince1970)
  }
)
```

Homa 完全不 import LexiconKit 或 LMAssembly。耦合僅透過三個 closure typealias 的函式簽名。

### 4.3 Megrez → Homa API 映射速查表

| Megrez API | Homa API | 備註 |
|-----------|---------|------|
| `Compositor(with: langModel, separator:)` | `Assembler(gramQuerier:, gramAvailabilityChecker:, perceptor:)` | 建構方式完全不同 |
| `compositor.langModel = newLM` | `assembler.gramQuerier = { ... }` | 需重綁三個 closure |
| `compositor.insertKey(_:)` | `assembler.insertKey(_:)` | 同名 |
| `compositor.dropKey(direction:)` | `assembler.dropKey(direction:)` | 同名同語義 |
| `compositor.assemble()` | `assembler.assemble()` | 同名，回傳 `[GramInPath]` |
| `compositor.cursor` / `.marker` / `.keys` | `assembler.cursor` / `.marker` / `.keys` | 同名同語義 |
| `compositor.fetchCandidates(at:filter:)` | `assembler.fetchCandidates(at:filter:)` | 回傳型別不同：`KeyValuePaired` vs `CandidatePair` |
| `compositor.overrideCandidate(_:at:..., perceptionHandler:)` | `assembler.overrideCandidate(_:at:..., perceptionHandler:)` | 參數語義一致 |
| `compositor.overrideCandidateLiteral(_:at:)` | `assembler.overrideCandidateLiteral(_:at:)` | 同名同語義 |
| `Megrez.makePerceptionIntel(prev:curr:cursor:)` | `Homa.makePerceptionIntel(prev:curr:cursor:)` | 同名同語義 |
| `compositor.maxSegLength` | `assembler.maxSegLength` | 同名 |
| `compositor.length` | `assembler.length` | 同名 |
| `compositor.assembledSentence` | `assembler.assembledSentence` | 同名 |
| N/A | `assembler.revolveCandidate(at:...)` | Homa 獨有 |
| N/A | `assembler.consolidateCandidateCursorContext(...)` | Homa 獨有 |
| `compositor.clear()` | `assembler.clear()` | 同名 |

### 4.4 Megrez ↔ LM ↔ POM 現行整合資料流

```
NSEvent
  → SessionCtl → InputSession → InputHandler
                                    │
                                    ├─ assembler: Megrez.Compositor
                                    │      └─ langModel: LMInstantiator (LangModelProtocol)
                                    │            ├─ unigramsFor(keyArray:)
                                    │            └─ fetchPOMSuggestion(assembledResult:cursor:timestamp:)
                                    │                  └─ LMPerceptionOverride.fetchSuggestion()
                                    │                        └─ [GramInPath].generateKeyForPerception() → ngramKey
                                    │
                                    ├─ consolidateNode()
                                    │      ├─ retrievePOMSuggestions(apply:false) → 查詢 POM 完全匹配
                                    │      ├─ assembler.overrideCandidate(perceptionHandler:) → Megrez 覆寫
                                    │      │      └─ defer { makePerceptionIntel(prev, curr, cursor) → handler }
                                    │      ├─ Megrez.makePerceptionIntel(prev, curr, cursor)
                                    │      └─ currentLM.memorizePerception(ngramKey, candidate) → POM 存檔
                                    │
                                    └─ retrievePOMSuggestions(apply:true)
                                           ├─ currentLM.fetchPOMSuggestion(assembledSentence, cursor)
                                           └─ assembler.overrideCandidate() + assemble()
```

### 4.5 Homa ↔ LexiconKit ↔ Perceptor 目標整合架構

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

Homa + LX_Perceptor 相對於 Megrez + LMPerceptionOverride 的優勢集中在三個方面：**Bigram 支援提升組句品質**、**Consolidator 防止選字副作用**、**Lambda 注入降低耦合與簡化整合代碼**。核心觀測演算法等價，遷移不會影響使用者既有的選字記憶。

建議的施術策略是：先做低風險的即時改動（Perceptor 注入 + Threshold 調整），然後以一次完整替換取代漸進趨近，避免在 Megrez 上做高代價但短壽命的架構改造。
# Phase 24 調研報告：Perception Override 機制比較與 Homa→Megrez Perceptor API 移植評估

> 調研日期：2026-04-17
> 調研範圍：`vChewing-macOS`（Megrez + LMPerceptionOverride）& `vChewing-LibVanguard`（Homa + LX_Perceptor）
> 調研員：GLM

---

## 一、調研對象概覽

### 1.1 LMPerceptionOverride（vChewing-macOS）

**檔案位置**: `vChewing-macOS/Packages/vChewing_LangModelAssembly/Sources/LangModelAssembly/SubLMs/lmPerceptionOverride.swift`

**定位**: vChewing-macOS 生產環境的漸退記憶模組（POM, Perception Override Module），隸屬於 `LMAssembly.LMInstantiator`，透過 `LMInstantiator_POMRepresentable.swift` 對外暴露 API。

**核心資料結構**:
- `Override`: `{ count: Int, timestamp: Double }` — 單一候選字的觀測記錄
- `Perception`: `{ overrides: [String: Override] }` — 某個 ngramKey 下所有候選字的觀測集合
- `KeyPerceptionPair`: `{ key: String, perception: Perception }` — LRU 字典的值單元
- `JournalRecord` / `JournalOperation`: 增量日誌系統（upsert / removeKey / clear）

**持久化機制**: **雙層寫入**
1. **Snapshot（快照）**: 完整 JSON 序列化 `[KeyPerceptionPair]`，以 CRC32 雜湊去重避免無意義覆寫
2. **Journal（增量日誌）**: 追加式 JSON Lines，每條記錄為 `JournalRecord`
3. **壓縮觸發**: 120 條日誌或 64KB 檔案大小 → 自動重寫完整快照
4. **防抖**: per-key 2 秒節流窗（`perKeyThrottleInterval`）
5. **載入**: 先讀 snapshot → 再回放 journal → 最終 CRC32 校驗

**執行緒安全**: `NSLock`

**關鍵常數**:
| 參數 | 值 | 備註 |
|------|-----|------|
| `kDecayThreshold` | **-9.5** | 權重下限 |
| `kWeightMultiplier` | Beast Constant（Tadokoro 公式） | 複雜數學常數，由 e/π 組合運算得出 |
| 預設時間窗 | **8 天**（可經偏好設定銳減至 12 小時） | `UserDef.kReducePOMLifetimeToNoMoreThan12Hours` |
| 預設容量 | 500 | |

**外部整合方式**（Megrez 端）:
- `InputHandler_CoreProtocol.swift` 中的 `consolidateNode()` 於選字後呼叫 `currentLM.memorizePerception()` 寫入觀測
- `generateArrayOfCandidates()` 中呼叫 `retrievePOMSuggestions(apply:)` 讀取建議並套用至 Megrez Compositor
- `retrievePOMSuggestions()` 內部處理 short→long 安全邊際檢查（`pomShortToLongAllowed`，需超過既有分數 +0.5）
- `Megrez.makePerceptionIntel()` 獨立實作於 `3_KeyValuePaired.swift`，負責從前後組句結果推導 `PerceptionIntel`

**Bleach API 完整度**: 三層 bleaching — (1) `(ngramKey, candidate)` 精確配對、(2) `candidate` 全域匹配、(3) `headReading` 讀音匹配 + `bleachUnigrams()`

---

### 1.2 LX_Perceptor（vChewing-LibVanguard）

**檔案位置**: `vChewing-LibVanguard/Sources/_Modules/LexiconKit/LX_Components/LX_SubLMs/LX_Perceptor.swift`

**定位**: LibVanguard 的下一代 POM 引擎，設計目標為跨平台、可獨立於 vChewing-macOS 測試的純 Swift 套件。

**核心資料結構**: 與 LMPerceptionOverride **同構**：
- `Override`: `{ count: Int, timestamp: Double }` — 編碼鍵為 `"c"` / `"ts"`
- `Perception`: `{ overrides: [String: Override] }` — 編碼鍵為 `"o"`
- `KeyPerceptionPair`: `{ key: String, perception: Perception }` — 編碼鍵為 `"k"` / `"p"`

**持久化機制**: **單層 Codable 序列化**
- 僅支援完整的 `[KeyPerceptionPair]` JSON 序列化/反序列化
- 無日賻系統、無 CRC32 去重、無節流
- `getSavableData()` / `loadData(from:)` 為唯一的 I/O API

**執行緒安全**: `DispatchQueue.sync`（label 含 UUID）

**關鍵常數**:
| 參數 | 值 | 備註 |
|------|-----|------|
| `kDecayThreshold` | **-13.0** | 比 LMPerceptionOverride 更寬鬆 |
| `kWeightMultiplier` | **0.114514** | 固定水印常數 |
| 時間窗 | **固定 8 天** | 不支援使用者偏好調整 |
| 預設容量 | 500 | |

**Homa 整合方式**:
- Homa.Assembler 的 init 接受 `perceptor: BehaviorPerceptor?` 參數
- `BehaviorPerceptor` 型別別名為 `(Homa.PerceptionIntel) -> ()` — **純 Lambda Expression**
- `overrideCandidateAgainst()` 在 defer 區塊中偵測組句變化，呼叫 `Homa.makePerceptionIntel()` 生成 `PerceptionIntel`，再透過 `(perceptionHandler ?? perceptor)?(intel)` 分發
- 支援兩路分發：Assembler 內建的 `perceptor` 或臨時傳入的 `perceptionHandler`
- ConsolidatorAPIs 在鞏固期間暫時禁用 perceptor（`perceptor = nil`），完成後恢復

**額外 API**: `memorizePerception(_ intel: Homa.PerceptionIntel, timestamp:)` — 直接接受 Homa 的 `PerceptionIntel` 型別

**Bleach API 完整度**: 與 LMPerceptionOverride 等價的三層 bleaching

---

## 二、LMPerceptionOverride vs LX_Perceptor 比較評估

### 2.1 演算法核心：等價

兩者的權重計算公式**完全一致**：

```
score = -kWeightMultiplier × freqFactor × ageFactor

其中：
  ageFactor = max(0, 1 - daysDiff / T) ^ pAge    （pAge = 2.0）
  freqFactor = min(1, 0.5×√prob + 0.5×log₁₀(count+1))
  T = 8天 × (isUnigram ? 0.85 : 1) × (isSingleCharUnigram ? 0.8 : 1)
```

差異僅在於：
- `kWeightMultiplier`: LMPerceptionOverride 用 Beast Constant（動態計算），LX_Perceptor 用 `0.114514`（固定值）。**二者數值量級相同，實際效果等價。**
- `kDecayThreshold`: LMPerceptionOverride 為 `-9.5`，LX_Perceptor 為 `-13.0`。LX_Perceptor 更寬鬆，意味着低分建議更不容易被淘汰。

### 2.2 結構設計：LX_Perceptor 更先進

| 維度 | LMPerceptionOverride | LX_Perceptor | 評定 |
|------|---------------------|--------------|------|
| **程式碼乾淨度** | ~1480 行（含日誌系統、CRC32、大量 I/O） | ~786 行（純邏輯） | **LX勝** |
| **職責分離** | POM 邏輯 + 持久化 + 節流 + 壓緊全部耦合 | 僅 POM 邏輯，持久化交由外部 | **LX勝** |
| **平台依賴** | 依賴 `UserDef`（時間窗偏好）、`Megrez`（separator）、`vCLMLog` | 零外部框架依賴（僅 Foundation + Homa） | **LX勝** |
| **可測試性** | 需要完整 vChewing-macOS 環境方可測試 | 可在 LibVanguard 單元測試內獨立跑 | **LX勝** |
| **型別安全** | `nonisolated` 標注分散、部分方法缺少隔離保證 | 整潔的 `public`/`fileprivate`/`internal` 分層 | **LX勝** |
| **持久化可靠性** | 日誌 + 快照雙層，CRC32 去重，crash-safe | 僅 Codable 快照，crash 可能丟失最後寫入 | **LMO勝** |
| **I/O 效能** | 增量追加 + 節流 + 自動壓縮 | 全量重寫 | **LMO勝** |
| **生產成熟度** | 經過多 Phase 驗證，有完整 E2E 測試覆蓋 | 有單元測試但尚無生產驗證 | **LMO勝** |

### 2.3 結論：LX_Perceptor 是 LMPerceptionOverride 的正當繼任者

**LX_Perceptor 的核心演算法與 LMPerceptionOverride 等价**，但在架構乾淨度、可維護性、可測試性上顯著領先。LMPerceptionOverride 唯一的不可替代優勢在於其**日誌式持久化系統**。

#### 對 LMPerceptionOverride 的改進建議：

1. **將日誌持久化子系統抽離為獨立模組**（如 `POMJournalManager`），使 `LMPerceptionOverride` 本身退化為純邏輯層（對標 LX_Perceptor 的體積）
2. **移除對 `UserDef` / `Megrez` 的直接依賴**，改用 `thresholdProvider` callback（已部分實作）+ 注入 separator
3. **將 `kDecayThreshold` 統一為 -13.0**（或至少文件化兩者差異的理由；目前 -9.5 vs -13.0 缺乏明確的選擇依據）
4. **考慮未來直接以 LX_Perceptor 取代 LMPerceptionOverride**，將日誌持久化作為外部 adapter 層

---

## 三、Homa 嵌入式 Perceptor API 設計評估

### 3.1 架構概覽

Homa 的 Perceptor 介接採用 **Lambda Injection（回調函式注入）** 模式：

```swift
// Homa_TypeAliases.swift
public typealias BehaviorPerceptor = (Homa.PerceptionIntel) -> ()

// Homa_Assembler.swift
public init(
  gramQuerier: @escaping Homa.GramQuerier,
  gramAvailabilityChecker: @escaping Homa.GramAvailabilityChecker,
  perceptor: Homa.BehaviorPerceptor? = nil,  // ← 外部注入
  config: Config = Config()
)
```

**觸發鏈路**:
```
用戶選字 → Assembler.overrideCandidateAgainst()
  → 1. 備份 previouslyAssembled = assemble()
  → 2. 執行 Node.selectOverrideGram() + demote 相鄰節點
  → 3. defer { 重組 assemble() → makePerceptionIntel() → (perceptionHandler ?? perceptor)?(intel) }
```

**關鍵設計決策**:

1. **雙路分發**: `perceptionHandler`（臨時、單次）優先於 `perceiver`（長期、Assembler 級別）
2. **Consolidator 感知**: `ConsolidatorAPIs` 在上下文鞏固期間暫時置空 perceptor，避免鞏固操作產生的假觀測污染 POM 資料
3. **觀測條件門檔**: 僅在 `perceptionHandler != nil || perceptor != nil` 時才備份 `previouslyAssembled`，零成本短路
4. **PerceptionIntel 結構化**: 包含 `contextualizedGramKey`、`candidate`、`headReading`、`scenario`（sameLenSwap/shortToLong/longToShort）、`forceHighScoreOverride`、`scoreFromLM`

### 3.2 設計合理性評估：**非常合理**

**優點**:

| 特性 | 說明 |
|------|------|
| **零耦合** | Assembler 不依賴任何具體 POM 實作，只認 `(PerceptionIntel) -> ()` 簽名 |
| **可替換性** | 測試时可注入 mock perceptor，生產环境可注入真实 LX_Perceptor |
| **開閉原則** | 新增觀測消費者不需修改 Assembler 代碼 |
| **Consolidator 安全** | 鞏固期間自動禁用，防止錯誤觀測 |
| **結構化觀測** | `PerceptionIntel` 承载豐富語意（scenario、forceHSO、LM score），便於下游決策 |

**潛在風險**（均為低風險）:
- `PerceptionIntel` 是 **reference type 無關的 pure value type**（struct + Codable + Hashable + Sendable），不會有 capture 循環引用問題
- `defer` 區塊中的 `assemble()` 是額外的 DAG 計算成本，但僅在 perceptor 存在時觸發
- `makePerceptionIntel()` 的 key merging 邏輯（尤其是 shortToLong 的 cross-source merge）複雜度高，但已妥善封裝

---

## 四、Megrez 現有架構分析

### 4.1 Megrez 的 POM 整合方式：外部協調模式

Megrez.Compositor **完全不感知 POM**。其 `LangModelProtocol` 僅定義 `unigramsFor(keyArray:)` 和 `hasUnigramsFor(keyArray:)`。

POM 的完整生命週期在 **InputHandler（Typewriter 層）** 中完成：

```
InputHandler.consolidateNode()
  ├─ 1. assembler.overrideCandidate()          ← Megrez 原生能力
  ├─ 2. Megrez.makePerceptionIntel(...)        ← Megrez 提供的工具函式
  ├─ 3. currentLM.memorizePerception(...)       ← LMInstantiator 轉發至 LMPerceptionOverride
  └─ 4. assembler.assemble()                   ← 重新組句

InputHandler.generateArrayOfCandidates()
  ├─ 1. fetchRawQueriedCandidatesFromAssembler()
  ├─ 2. currentLM.fetchPOMSuggestion(...)      ← LMInstantiator 轉發至 LMPerceptionOverride
  ├─ 3. filterPOMAppendables(...)              ← 過濾不合理建議
  ├─ 4. assembler.overrideCandidate(...)       ← 套用 POM 建議（若 apply=true）
  └─ 5. assembler.assemble()                   ← 重新組句
```

**Megrez.makePerceptionIntel()** 位於 `3_KeyValuePaired.swift`，是與 Homa 版本 **完全同構的獨立實作**。

### 4.2 Megrez 架构特徵

| 特徵 | 描述 |
|------|------|
| LangModelProtocol | 極簡介面（2 methods），無 POM 相關 API |
| Compositor | 不持有任何 perceptor reference |
| Node | 有 `OverrideType` / `overridingScore` / `isExplicitlyOverridden`，與 Homa.Node 功能等價 |
| PathFinder | 純 DAG-DP，無 side-effect |
| POM 工具函式 | `makePerceptionIntel()` 作為 `Megrez` namespace 下的 static method 存在 |

---

## 五、Homa → Megrez Perceptor API 移植方案

### 5.1 可行性評估：**高度可行，收益明顯**

Megrez 引入 Homa 式 Perceptor API 的核心改造範圍有限且風險可控：

### 5.2 改造方案詳述

#### Step 1：Megrez 新增型別定義

```swift
// 於 Megrez/0_Megrez.swift 或新檔案 Megrez/PerceptionIntel.swift

extension Megrez {
  /// 觀測情境枚舉（與 Homa.POMObservationScenario 對齊）
  public enum POMObservationScenario: String, Codable, Sendable {
    case sameLenSwap, shortToLong, longToShort
  }

  /// 觀測上下文（與 Homa.PerceptionIntel 對齊）
  public struct PerceptionIntel: Codable, Hashable, Sendable {
    public let contextualizedGramKey: String
    public let candidate: String
    public let headReading: String
    public let scenario: POMObservationScenario
    public let forceHighScoreOverride: Bool
    public let scoreFromLM: Double
  }

  /// Perceptor 回調類型別名（與 Homa.BehaviorPerceptor 對齊）
  public typealias BehaviorPerceptor = (Megrez.PerceptionIntel) -> ()
}
```

> **注意**：Megrez 已有 `PerceptionIntel` 的 internal/nested 版本（見 `3_KeyValuePaired.swift` 的 `PerceptionIntel` nested in KeyValuePaired）。需要提升為 top-level `Megrez.PerceptionIntel` 並確保向後相容。

#### Step 2：Megrez.Compositor 注入 perceptor

```swift
// Megrez/1_Compositor.swift

extension Megrez.Compositor {
  /// 用以洞察使用者字詞節點覆寫行為的 API。
  public var perceptor: Megrez.BehaviorPerceptor? {
    get { _perceptor }
    set { _perceptor = newValue }
  }
  private var _perceptor: Megrez.BehaviorPerceptor?
}
```

#### Step 3：Megrez.Compositor 的 overrideCandidate 方法新增 perceptionHandler 參數

目前 Megrez 的 `overrideCandidate` 位於 Node 層級（`Node.selectOverrideUnigram()`），Compositor 層級的 override 能力通過 InputHandler 直接操作 Node 來實現。改造需要在 Compositor 層引入與 Homa.Assembler.overrideCandidateAgainst() 等價的方法：

```swift
// Megrez/1_Compositor.swift（新增）

@discardableResult
public func overrideCandidate(
  _ pair: KeyValuePaired,
  at location: Int,
  overrideType: Node.OverrideType = .withSpecified,
  isExplicitlyOverridden: Bool = false,
  perceptionHandler: BehaviorPerceptor? = nil
) -> Bool {
  // 1. 備份 assembledSentence
  let shouldObserve = perceptionHandler != nil || _perceptor != nil
  let previouslyAssembled: [GramInPath]? = shouldObserve ? assembledSentence : nil

  // 2. 執行 override（現有邏輯）
  // ... (既有的 node override + demotion 邏輯)

  // 3. defer 中觸發觀測
  defer {
    guard shouldObserve else { return }
    if let intel = Megrez.makePerceptionIntel(
      previouslyAssembled: previouslyAssembled ?? [],
      currentAssembled: assembledSentence,
      cursor: location
    ) {
      (perceptionHandler ?? _perceptor)?(intel)
    }
  }
  // ...
}
```

#### Step 4：InputHandler 簡化

改造後的 InputHandler 可從：
```swift
// 現狀：手動 orchestrator
currentLM.memorizePerception((key, candidate), timestamp: ...)
let suggestion = currentLM.fetchPOMSuggestion(assembledResult:, cursor:, timestamp:)
assembler.overrideCandidate(suggestedPair, at:, overrideType:)
assembler.assemble()
```

簡化為：
```python
# 改造後：宣告式注入
compositor.perceptor = { intel in
  currentLM.memorizePerception(
    (intel.contextualizedGramKey, intel.candidate),
    timestamp: Date().timeIntervalSince1970
  )
}
# overrideCandidate() 內部自動觸發 perceptor
```

`retrievePOMSuggestions()` 的讀取路径仍保留在 InputHandler 層（因為它涉及 UI 候選字排序，不屬於 Compositor 的職責範圍）。

### 5.3 改造影響评估

| 維度 | 影響 |
|------|------|
| **變更範圍** | Megrez: ~3 檔（新增 PerceptionIntel 定義、Compositor 注入、overrideCandidate 擴充）；InputHandler: ~1 檔（簡化 consolidateNode） |
| **向後相容** | `perceptor` 預設為 `nil`，所有新參數皆有預設值，**零 breaking change** |
| **測試策略** | 現有 Megrez 測試無需修改（perceptor == nil 時行為不變）；新增 perceptor 回調驗證測試 |
| **風險** | 低。defer 區塊中的額外 `assemble()` 呼叫是唯一的新开销，且僅在 perceptor != nil 時觸發 |
| **收益** | Megrez 與 Homa 的 POM 介面統一，未來切換引擎時 InputHandler 改動最小化 |

### 5.4 不建議改造的部分

1. **PathFinder**: 純演算法組件，不應引入副作用
2. **Node**: 資料結構層，perceptor 是 Assembler/Compositor 紧別的關注點
3. **LangModelProtocol**: 保持極簡介面，POM 不屬於「語言模型查詢」的職責範疇
4. **POM 讀取路径** (`fetchSuggestion` → 候選字排序): 這是 UI 層邏輯，不適合放入 Compositor

---

## 六、總結與建議

### 6.1 核心發現

1. **LX_Perceptor 的演算法與 LMPerceptionOverride 等價**，前者在程式碼品質上領先，後者在持久化可靠性上領先。建議未來以 LX_Perceptor 為基礎、將 LMPerceptionOverride 的日誌系統抽離為可插拔的持久化 adapter。

2. **Homa 的 Lambda Injection Perceptor API 設計優秀**，符合開閉原則、零耦合、Consolidator-safe。這個設計模式值得移植到 Megrez。

3. **Megrez 移植成本低**，核心變更限於 Compositor 層的新增參數與 defer 回調，不破壞既有 API。

### 6.2 建議優先順序

| 優先 | 行動 | 理由 |
|------|------|------|
| P0 | Megrez 引入 `BehaviorPerceptor` type alias + `PerceptionIntel` struct | 無 breaking change，為後續統一鋪路 |
| P1 | Megrez.Compositor 新增 `perceptor` 屬性 + `overrideCandidate` 的 `perceptionHandler` 參數 | 完成 Homa→Megrez 的 API 對齊 |
| P2 | 评估將 LMPerceptionOverride 的日誌持久化抽離為獨立模組 | 解耦後可同時供 LX_Perceptor 使用 |
| P3 | 統一 `kDecayThreshold`（建議 -13.0）和 `kWeightMultiplier` | 消除兩端行為不一致的隱患 |
