# Phase 33 術後報告：Megrez → Homa 引擎替換（階段 A1）、InputHandler 精簡（階段 A2）與 LXPerceptor 對齊（階段 B）

> 本版日期：2026-04-20
> 手術範圍：`vChewing-macOS`（主體替換 + A2 精簡 + Stage B 對齊）、`vChewing-LibVanguard`（bug 同步修復、Perceptor parity、文件更新）、`vChewing-OSX-Legacy`（A1 / A2 / Stage B transplant、授權文件同步、mirror audit + build 驗證）
> 參與者：Shiki Suen、ChatGPT-5.4（主體替換、A2 精簡、Legacy transplant / audit）、Claude Opus 4.6（bug 修復與文件）

---

## 一、手術摘要

Phase 33 先完成了 Phase 32 調研報告（`Phase32_PostResearch.md`）所規劃的**階段 A1：引擎替換 Megrez → Homa**，並於 2026-04-20 補完了 **階段 A2：InputHandler 精簡** 與 **階段 B：`LMPerceptionOverride` → `LXPerceptor` / `LX_Perceptor` 對齊**。其後同日亦完成了 `vChewing-OSX-Legacy` 的對位 transplant、文件同步與 mirror audit 收尾。

### 1.1 主體替換（Shiki Suen & ChatGPT-5.4）

| 項目 | 內容 |
|------|------|
| Package.swift 依賴切換 | `vChewing_Megrez` → `vChewing_Homa` |
| LMInstantiator 適配層 | 新增 `HomaCompatShims.swift`（LMInstantiator → GramQuerier / GramAvailabilityChecker closure 適配） |
| InputHandler 型別映射 | `Megrez.Compositor` → `Homa.Assembler`、`Megrez.KeyValuePaired` → `Homa.CandidatePair`、`Megrez.GramInPath` → `Homa.GramInPath` |
| Homa 測試遷移 | Homa 完整測試套件遷移至 `vChewing-macOS/Packages/vChewing_Homa/` |
| Xcode project | 解除 Megrez 引用 |
| 總改動量 | 68 檔案，+7,158 / -529 行 |

### 1.2 Bug 修復（Claude Opus 4.6）

遷移後發現三個測試失敗，根因分析與修復如下：

#### Bug 1: `sliced(by: "")` 空分隔符號回傳空陣列

- **影響測試**：`testHardCopyAndWordSegmentation`
- **根因**：`StringProtocol.sliced(by:)` 未處理空分隔符號。當 `arrSeparator.count == 0` 時，每輪迴圈切出的 `ripped` 都是空陣列，立即被 `if ripped.isEmpty { continue }` 跳過，結果所有字元都無法進入 `buffer`。
- **修復**：新增 `guard !arrSeparator.isEmpty else { return selfArray.map { String($0) } }` 早期返回。
- **範圍**：僅 `vChewing-macOS`（LibVanguard 版本無 `sliced(by:)` 函式）。

#### Bug 2: 候選權重不應寄生在 `CandidatePair` 上

- **影響測試**：`test_IH301_POMBleacherIntegrationTest`、`test_IH303_POMIgnoresLowerWeightSuggestedUnigramMatchingRawQueriedUnigram`
- **根因**：先前的過渡實作把 LM 權重暫時塞進 `CandidatePair.score`，再由 Typewriter 透過 `.map(\.pair)` 萃取 raw candidates。這讓 `CandidatePair` 同時扮演「身份」與「帶權重候選」兩種角色，POM 過濾邏輯也因此被迫讀取錯誤的資料形狀。
- **修復**：本輪 follow-up 直接把 `score` 自 `CandidatePair` 移除，讓 `CandidatePair` 回到純 `(keyArray, value)` 語意；若需要保留權重，一律使用 `CandidatePairWeighted`，或由 `CandidatePair.weighted(_:)` 產生 weighted 包裝。`fetchCandidates()`、`revolveCandidate()`、Typewriter 的 `fetchRawQueriedCandidatesFromAssembler()` / `filterPOMAppendables()` 與相關測試皆同步改走 weighted 路徑。
- **範圍**：`vChewing-macOS` + `vChewing-LibVanguard` 同步修復。

#### Bug 3: `CandidatePair` Hashable/Equatable 合約違反

- **影響**：`CandidatePair` 在 `Set` / `Dictionary` 場景下的身份一致性遭破壞
- **根因**：先前的過渡模型讓 `CandidatePair` 同時攜帶身份資訊與 `score`，導致 `==` 與 `hash(into:)` 很容易出現語意分裂。
- **修復**：初始 follow-up 先以手動 `hash(into:)` 對齊 `raw` 身份；本輪則更進一步把 `score` 整個移出 `CandidatePair`。結果是 `CandidatePair` 的身份語意與 `Hashable` / `Equatable` 合約在資料模型層級重新一致，權重則完全交由 `CandidatePairWeighted` 承擔。
- **現況**：這個風險已被結構性消除；其後 follow-up 也補完了 Homa revolver / consolidator 與測試端的 identity 對位缺陷，因此 `Assember_TestCandidateRevolvementWithConsolidation` 已恢復通過。
- **範圍**：`vChewing-macOS` + `vChewing-LibVanguard` 同步修復。

### 1.3 A2 精簡（ChatGPT-5.4）

- `InputHandler_CoreProtocol.consolidateCursorContext(with:explicitlyChosen:)` 已改為直接委派 `assembler.consolidateCandidateCursorContext(for:cursorType:)`。
- Typewriter 端的 `calculateConsolidationBoundaries(for:explicitlyChosen:)` 與 `overrideNodeAsWhole(...)` 已刪除，不再自行維護上下文邊界推算。
- `InputHandler_HandleStates.revolveCandidate(reverseOrder:)` 現已完全直通 `assembler.revolveCandidate(cursorType:counterClockwise:)`，原先暫留在 Typewriter 的 parity fallback 已移除。
- `Homa.CandidatePair` 已移除 `score` 欄位，回到純詞音配對；需要帶權重時，統一以 `CandidatePairWeighted` 或 `weighted(_:)` 表述。Typewriter 的 raw candidate 過濾也因此改為直接消費 weighted candidates。
- 之所以現在能安全移除該 fallback，是因為 follow-up 已把 Homa 端的兩個根因一起補齊：`Assember_TestCandidateRevolvementWithConsolidation` 的 candidate identity 對位改為依 `pair + candidate span` 解析；`revolveCandidate()` / `consolidateCandidateCursorContext()` 也改為以「目標候選真正穩定成為 logical cursor 上的 explicit node」為成功條件，並用候選實際跨度計算 consolidation 邊界。

### 1.4 階段 B：`LMPerceptionOverride` → `LXPerceptor` 對齊（ChatGPT-5.4）

- `vChewing-macOS` 的 POM 主體已將所有 `LMAssembly.LMPerceptionOverride` Type Alias 全部移除，統一改為直接呼叫 canonical `LMAssembly.LXPerceptor`，`LMInstantiator` 也統一導出 canonical `lxPerceptor` property。
- `LMInstantiator_POMRepresentable`、LangModelAssembly 測試、Typewriter 測試與 `algorithm.md` 已同步切到 canonical `LXPerceptor` / `lxPerceptor` 命名；所有呼叫點均已更新，不再使用 deprecated alias。
- `vChewing-LibVanguard` 的 `LX_Perceptor` 補上了與 Phase 32 POM 對齊的 `reducedLifetime` 注入欄位，並新增獨立 regression test 鎖住「急速遺忘模式將觀測窗縮至約 0.5 天」的行為；先前遺留的 debug `print` 亦已移除。
- `vChewing-OSX-Legacy` 已同步完成 canonical `LXPerceptor` / `lxPerceptor`、POM forwarding 與持久化型別對齊，移除所有 deprecated alias；其後又將 Phase 33 的 Homa transplant 與 InputHandler 精簡一併鏡像到 Legacy，最終狀態已不再是「僅 Stage B」。

### 1.5 標點排序 follow-up（ChatGPT-5.4）

- `STANDARD (DACHEN)` 下 `Shift+Comma` 的錯序並不是 punctuation query key 組錯；實際查詢路徑仍是 `_punctuation_Standard_<`。
- 真正的 root cause 是 Homa `sortGramRAW` 對「同 `keyArray`、同 `probability`」的資料仍以 `value` 做 lexicographic tie-break，導致標點來源順序被洗掉；`previous` comparator 則必須保留，因為它負責區分帶有 Bigram context 的 grams。
- 修補方式因此是只移除 `value` tie-break，不動 `previous`；LangModelAssembly 端也撤回了先前的 equal-score epsilon workaround，只保留自動生成 half-width punctuation alias 的微量降權。
- `vChewing-macOS` 與 `vChewing-LibVanguard` 的 Homa mirror 都已補上 same-score punctuation ordering regression；`MainAssembly4Darwin` 也保留了 `STANDARD (DACHEN)` `Shift+Comma` 的 end-to-end regression。

### 1.6 Legacy transplant / audit follow-up（ChatGPT-5.4）

- `vChewing-OSX-Legacy` 已將 `vChewing-macOS` Phase 33 source commit `21d48636f534838773316481b4b6d1ae5f231567` 中所有有對位的非測試變更鏡像到 Legacy counterpart，範圍涵蓋 Homa runtime、LMAssembly compat / adapters、Typewriter InputHandler、MainAssembly bridge 與 Xcode project。
- Homa 元件所需的授權文件也已在 Legacy 補齊：`Shared/vChewingComponents/Homa/LICENSE` 與 `CUSTOM_LGPLv3_EXCEPTION.md` 已落地；Legacy `README.md` 的授權段落與 `LMInstantiator.swift` 的頂部說明亦已同步修訂。
- 以 repo-local dotnet 稽核腳本 `vChewing-OSX-Legacy/tmp/phase33_mirror_audit.cs` 驗證 mirror 完整性後，report 顯示 `Actionable` 區段為空；摘要為 37 個 mirrored counterpart、1 個 equivalent noop、10 個 no-counterpart、23 個 test-only skip。
- `LMInstantiator_CassetteExtension.swift` 被歸類為 equivalent noop，因 source commit 在該檔的實際差異僅是 `import Megrez` → `import Homa`，在 Legacy 單目標佈局下不構成額外語義變化。
- `TypewriterSPM.swift` 被歸類為 no counterpart，因其僅負責 SwiftPM export surface；Legacy Xcode 佈局沒有對位檔案需要鏡像。
- 收尾驗證為 `make debug-core` 再次 BUILD SUCCEEDED，表示 Legacy 端的 A1 / A2 / Stage B transplant、授權同步與 project wiring 已收斂到可建置狀態。

---

## 二、驗證結果

| 測試套件 | 結果 |
|----------|------|
| vChewing-macOS Typewriter | 36/36 ✅（A1 後全套）；A2 後針對性回歸 6/6 ✅ |
| vChewing-macOS LangModelAssembly | 57/57 ✅（含同分標點保序與半形 alias 降權 regression） |
| vChewing-macOS MainAssembly4Darwin | 59/59 ✅ |
| vChewing-macOS Homa | 39/39 ✅（含 `CandidatePairWeighted` / `CandidatePair` 回歸、`CandidateRevolvementWithConsolidation` 與同分標點保序 regression） |
| vChewing-LibVanguard Homa + LXTests4Perceptor | 54/54 ✅（Homa 39/39 + Perceptor 15/15；含 `reducedLifetime` 與同分標點保序 regression） |
| vChewing-OSX-Legacy | Phase 33 mirror audit `Actionable = 0`；37 mirrored / 1 equivalent-noop / 10 no-counterpart / 23 test-only skip；`make debug-core` BUILD SUCCEEDED ✅ |

---

## 三、Phase 32 調研預測 vs 實際

| Phase 32 預測 | 實際結果 |
|-------------|---------|
| 階段 A1 難度：中高 | ✅ 主體替換順利，但發現三個隱蔽 bug |
| Perceptor 接線可直接搬遷 | ✅ POM 接線代碼近乎零修改複用 |
| `assembler.fetchCandidates()` 回傳型別適配 | ⚠️ 型別適配成功，但後續證實 `CandidatePair` 不應承載權重，需再拆為純 `CandidatePair` + `CandidatePairWeighted` |
| NodeOverrideStatus 鏡像 API 零修改搬遷 | ✅ 確認 |
| 改動量級「大」 | ✅ 68 檔 +7158/-529 行 |

### 3.1 未預見的風險

Phase 32 調研報告未預見以下兩類問題：

1. **Homa 純 Swift 實作的邊界行為差異**：`sliced(by: "")` 在 Foundation-free 環境下與 Foundation 的 `components(separatedBy:)` 行為不一致。Homa 為跨平台設計而使用純 Swift 字串操作，這類邊界差異需要逐案測試覆蓋。

2. **候選身份與權重混裝的語義陷阱**：把權重暫塞進 `CandidatePair` 雖能暫時修掉 POM 路徑，但會把「身份」與「分數」兩種概念混在一起，連帶放大 `Hashable`/`Equatable` 契約風險。本輪最終改為讓 `CandidatePair` 僅表達 `(keyArray, value)`，權重統一交由 `CandidatePairWeighted` 與 `weighted(_:)` 承擔，並補齊回歸測試與 POM / revolver / perceptor 路徑的型別修整。

---

## 四、剩餘待辦

| 階段 | 說明 | 狀態 |
|------|------|------|
| A2 | InputHandler 精簡——上下文鞏固與 inline revolver 均已完全委派 Homa；parity fallback 已移除 | ✅ |
| B | 同步替換 `LMPerceptionOverride` → `LXPerceptor` / `LX_Perceptor`，並保留 deprecated compatibility surface | ✅ |
| Legacy | vChewing-OSX-Legacy 的 A1 / A2 / Stage B transplant、授權文件同步、mirror audit 與 build verification 已完成；若需要可另補手動 smoke validation | ✅ |
| C | Bigram 啟用（長期） | ⬜ |

### 4.1 Legacy 同步收尾結果

先前列為 blocker 的 Swift 5.10 相容處理（typed throws → 普通 `throws` / 對等 API spellings）已先行完成；其後 Legacy transplant 亦已正式收尾。

1. **A1 / A2 / Stage B 已落地**：Legacy 現已具備 Homa runtime、`LXPerceptor` naming / API surface 對齊、InputHandler 委派化與相應的 MainAssembly bridge，不再是 Megrez 主幹 + Stage B only 的中途狀態。
2. **mirror audit 已清零**：repo-local dotnet 稽核腳本確認所有有對位的非測試變更皆已鏡像到 Legacy counterpart，`Actionable` 區段為空。
3. **兩個例外都已明確分類**：`LMInstantiator_CassetteExtension.swift` 為 equivalent noop；`TypewriterSPM.swift` 為 no counterpart。這兩項都不是漏鏡像。
4. **文件與授權同步已補齊**：Legacy `README.md`、Homa 授權檔與 `LMInstantiator.swift` 頂部說明都已與實際 transplant 狀態對齊。
5. **建置驗證已完成**：Legacy `make debug-core` 已重新通過。由於 Legacy 端沒有單元測試框架，若未來需要更高信心，仍可另補手動 smoke validation。

### 4.2 對後續階段的修訂建議

- **階段 A2 後續請維持 `CandidatePair` 的純語意**：本輪已將權重完全抽離至 `CandidatePairWeighted`；後續若需要攜帶分數，應優先使用 `weighted(_:)`，不要再把 `score` 回塞進 `CandidatePair`。
- **Stage B 已完成 canonical rename 且全部清除 deprecated alias**：macOS / Legacy 的 `LMPerceptionOverride` / `lmPerceptionOverride` type alias 已全數移除，所有呼叫點均已切換至 canonical `LXPerceptor` / `lxPerceptor`，不再有相容層殘留。
- **Homa 標點排序修補只移除 `value` tie-break**：`previous` 必須保留在 comparator 內，用來排序帶有 Bigram context 的 grams；後續 mirror / Legacy 移植時不應誤刪。
- **Swift 5.10 相容面請維持現狀**：`Homa.Exception` 的 typed throws / 對等 API spellings 已整理成 Swift 5.10 可接受的普通 `throws` 版本；後續 mirror / Legacy transplant 時應沿用這套相容面，不要重新引入 typed throws。
- **Homa revolver follow-up**：standalone `CandidateRevolvementWithConsolidation` 的 failure 已在本輪 follow-up 解決，Typewriter 端原先為了保險而保留的 parity fallback 也已隨之移除。
