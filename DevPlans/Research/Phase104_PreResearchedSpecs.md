# Homa Revolver — Soft Revolve 需求規格

## 一、背景

截至唯音輸入法 v4.5.3 為止，Homa 引擎的 candidate revolver 僅支援 hard revolve：輪替時會把候選列表中 segLength 最大者直接覆寫到組字區，即使該候選跨越了鄰近「已被使用者明確覆寫（explicit）」的節點，也照樣覆蓋。這會破壞「一個字一個字選」的使用者體驗。

## 二、欲解決的問題

### 情境一（最小重現）

語料：
```
ji4-gong1 技工 -5.266
ji4-gong1 濟公 -5.406
ji4-gong1 記功 -5.75
```

敲 `ji4-gong1` → 預設組字「技工」。使用者習慣「一個字一個字選」：先將游標挪到 `ji4` 正前方、手動選成「濟」（explicit），再把游標調到 `gong1` 正前方用 revolver 選字。

- Expected：被 revolve 的對象只是 `gong1`，已覆寫的「濟」不應受影響；首輪即得「濟 公」。
- Actual：「濟」在 assembled result 裡重新變成「技工」，需再 revolve 一次才得「濟公」。

### 情境二（real-world，更嚴重）

基於完整原廠辭典（以 ASCII SPACE 為 segment delimiter 示範）：

- 使用者原本想敲：`你 現在 要 搬 的話`
- 預設組字結果：`你 現在 耀斑 的話`
- 使用者選了「ㄧㄠˋ」選成「要」之後：`你 現在 要 斑 的話`
- 因本特性缺失，輪替 `斑`→`搬` 時，`要` 被回退，結果變回 `你 現在 耀斑 的話` 而非 `你 現在 要 搬 的話`。

> `你 現在 要 斑 的話` 這個中間結果是「上下文鞏固」特性使然——那是為另一個產品需求（「章太炎」→「章泰炎」這類保護選字範圍外上下文）而設計的特性，與本需求正交，不應被本需求破壞。

## 三、根因（已實證）

兩個情境同源，損害一律來自「多音節候選覆寫跨越鄰近 explicit 節點」，與上下文鞏固無關：

1. 覆寫某音節為 explicit 後，該音節獨立為 explicit 節點，鄰近音節為 auto 節點。
2. `fetchCandidates(filter: .endAt)` 的候選列表按 `(segLength, keyArray, weight)` 降序排列，涵蓋鄰近音節的雙音節候選排在單音節候選之前。
3. 當前被輪替節點是 auto（非 explicit）。`calculateNextCandidateIndex` 走 non-explicit 分支：`首候選 ≠ 當前 pair` → 直接回傳索引 0（即 segLength 最大的雙音節候選）。
4. `overrideCandidate(該雙音節候選, ...)` 的 `calculateTargetCandidateRange` 在 `.placedFront` 下為 `[cursorPos - segLength + 1, cursorPos + 1)`，跨越鄰近 explicit 節點位置並覆蓋之。

「鞏固」特性並非罪魁禍首：情境一首輪鞏固被跳過（游標在 assembler edge）、情境二首輪鞏固有執行（中段游標），兩者結局相同——鞏固的「凍結」擋不住隨後跨越範圍的候選覆寫。

關鍵程式碼點（`Homa_CandidateAPIs_Revolver.swift` / `Homa_CandidateAPIs_FetchAndApply.swift`）：`calculateNextCandidateIndex` non-explicit 分支、`calculateTargetCandidateRange`、`fetchCandidates` 排序。

## 四、API 變更

`Homa.Assembler.revolveCandidate` 新增力度參數：

```swift
public func revolveCandidate(
  cursorType: CandidateCursor,
  counterClockwise: Bool,
  softRevolve: Bool = false,               // 新增；預設 false 維持現行 hard 行為
  skipInitialConsolidation: Bool = false,
  debugIntelHandler: ((String) -> ())? = nil,
  candidateArrayHandler: (([Homa.CandidatePairWeighted]) -> ())? = nil
) throws -> (Homa.CandidatePairWeighted, current: Int, total: Int)
```

- `softRevolve == false`：現行 hard revolve 行為，不變。
- `softRevolve == true`：啟動 soft revolve 機制（見第五節）。

## 五、Soft Revolve 機制定義

當 `softRevolve == true` 時，在候選選擇層做損害防護：

1. 對候選列表做「安全子集」過濾。一個候選為「不安全」若：其 segLength > 1，且其 `calculateTargetCandidateRange` 與任何「非當前 candidate cursor position 所屬節點」的 **explicit** 節點範圍重疊。
2. 在安全子集上計算下一個輪替索引（沿用既有 `calculateNextCandidateIndex` 邏輯）。
3. 回傳值 `current` 仍為**原始候選列表**中該輪替結果的索引；`total` 仍為原始候選列表總數。這樣即使 safe subset 縮小，UI 層的「第 N / M 個候選」語義仍與完整候選窗一致。
4. 若安全子集為空或無可輪替對象，按既有無候選/單候選例外語義處理。

設計要點：

- **守衛必須前推到候選迭代 / 索引選擇層**，不能只擋最終 `overrideCandidate`。因為 non-explicit 分支會直接跳索引 0；只擋 override 會擋掉損害候選卻不知「退而求其次選誰」。
- **`segLength > 1` 作為短路門檻**（單音節候選一般不跨越鄰節點），但最終判據應為「target range 與非游標區 explicit 節點是否重疊」此一損害不變式，以兜住 retokenization 邊界情形。
- **不動鞏固邏輯**。soft revolve 與 `skipInitialConsolidation` 正交，獨立落地。

## 六、驗收測試

於 `vChewing-LibVanguard/Tests/_Tests4Components/HomaTests/HomaTests_Advanced.swift`：

| 測試 | 語料 | hard 期望（現行 bug，作對照） | soft 期望（落地後翻轉） |
|---|---|---|---|
| `testRevolverOverridesNeighboringExplicitNode_Scenario1` | `strLMSampleDataTechGuarden`（ji4-gong1） | 首輪→技工（濟被毀）；次輪→濟公 | 首輪即保留「濟」、僅 gong1 輪替 |
| `testRevolverMidBufferConsolidationActive_Scenario2Analogue` | `strLMSampleDataHutao`（liu2-yi4 留意） | 首輪→留意（流被毀）→ 能 留意 縷 | 保留「流」、僅 yi4 輪替 |

落地後應：

- 把上述兩測試的斷言翻成「期望 explicit 節點存活」作為 soft 驗收。
- 保留 hard 對照組（`softRevolve == false` 或不傳入時行為不變）。
- 回歸 Phase 51 的 `testRevolveCandidateAvoidsOverConsolidatingLeadingOverlap` 與 Typewriter `test_IH201`，確認 soft 模式不回退 `流一縷`/`留一縷` 修復。

## 七、範圍之外（待另開規格）

- **Typewriter 端啟用策略**：Homa 的 `softRevolve` 預設 `false` 維持現行行為；Typewriter 何時傳 `true`（恆為 soft / 依游標結構 / 新增使用者偏好）是產品決策，不在本規格內。考量「一個字一個字選」是注音使用者主流心智模型，值得評估讓 soft 成為 revolver 預設。
- **vChewing-macOS / vChewing-OSX-Legacy 同步**：Homa 三倉鏡像，實作完成後依既有同步流程處理。
