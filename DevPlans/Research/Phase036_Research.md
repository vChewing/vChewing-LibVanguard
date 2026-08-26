# Phase 36 總結報告：LMInstantiator lookup facade 收斂、partial-match 總控、與 wrapper retirement

> 完成日期：2026-04-22
> 範圍：`vChewing-macOS`、`vChewing-OSX-legacy`，以 `vChewing-LibVanguard` Phase 35 / TrieHub 為對照基線
> 整理者：GPT-5.4

---

## 一、Phase 36 的真正問題

Phase 35 已經把 TrieKit 的 canonical baseline 定下來：

1. `VanguardTrieProtocol.getEntryGroups(...)` 已經是既成事實，不是待辦提案。
2. `queryGrams(...)`、`hasGrams(...)`、`queryAssociatedPhrasesAsGrams(...)` 也已建立在這條 canonical surface 之上。

因此，Phase 36 真正缺的從來不是「再替 Trie protocol 發明一層 abstraction」，而是下游 `LMInstantiator` 還沒有把既有能力收斂成一致的 lookup policy 與 caller-facing facade。

這個 phase 最終要解的問題只有四個：

1. 讓 downstream 有一個最小 partial-match 總控。
2. 把 strict-superset 與 true partial-match 徹底分清。
3. 把 factory、plain BPMF / 倚天 DOS、cassette 的 lookup vocabulary 收斂到同一層。
4. 讓 MainAssembly / Typewriter 不再自行保存一堆 lookup shaping glue，而改由 `LMInstantiator` 供應單一 canonical surface。

---

## 二、術前定論

在所有實作開始前，Phase 36 的正確判斷可濃縮成以下幾點：

1. `onlyFindSupersets` 與 `partialMatch` 不等價。前者是 strict-superset 查詢，後者才是 chopped-key / prefix-aware partial assembly。
2. `LMInstantiator_TextMapExtension` 不直接走 protocol 高階 API，不足以證明 protocol API 較慢；更合理的解釋是這條路徑仍保留著 factory-specific 後處理與歷史形狀。
3. 其他後端不是沒有 partial-match 能力，而是暴露方式不一致。plain BPMF 已有 prefix query 能力，cassette quick result 也已有 prefix scan；缺的是共通 vocabulary 與總控。
4. 對位 `vChewing-LibVanguard` 的正確方向不是硬改名稱，而是先把 `LMInstantiator` 做成像 `TrieHub` 那樣的 lookup facade 掛點。

---

## 三、實施總結

### P0：補 `partialMatchEnabled` 作為最小總控

`LMInstantiator.Config` 新增 `partialMatchEnabled = false`，並讓 factory dictionary 在旗標開啟時改走 TrieKit `queryGrams(..., partiallyMatch: true)` / `hasGrams(..., partiallyMatch: true)` 路徑。這一步只種下總控 primitive，不引入第二套 mode enum，也不把 strict-superset 混成 partial-match alias。

### P1：先把 caller-side lookup shaping 收回 `LMInstantiator`

第一輪 facade seed 把 assembler 需要的 gram lookup 與 Typewriter 需要的 associated candidate shaping 收回 LangModelAssembly。這一步的重點不是完成 hub 化，而是先讓 app-side 不必再自行做 `Homa.GramRAW` tuple mapping、suffix pair expansion、value de-dup 等 glue。

### P2：把 `onlyFindSupersets` 重新定位成 strict-superset strategy

factory dictionary 新增 `FactoryCoreLookupStrategy`，用 `.configuredLookup` 與 `.strictSuperset` 明確分流。`configuredLookup` 表示走既有 factory 路徑並尊重 `partialMatchEnabled`；`strictSuperset` 則只代表「完整鍵嚴格超集」，從此不再與 partial-match 語義混寫。

### P3：讓 supplemental lookup 說同一套 strategy vocabulary

plain BPMF / 倚天 DOS 與 cassette quick result 改以 `SupplementalLookupStrategy` 表達 `.configuredLookup` / `.exactMatch` / `.partialMatch`。這一步不是強迫所有後端共用同一套查詢演算法，而是讓它們至少在同一層 facade 上說同一套策略語言，同時保留 backend default：

1. plain BPMF 補上 prefix-based partial lookup helper。
2. cassette 的 `.configuredLookup` 仍尊重 `%flag_disp_partial_match`。
3. production call sites 一律改綁 `.configuredLookup`，不把 Phase 36 擴大成 UI / FSM surgery。

### P4：正式收斂到 `lookupHub`

`LMInstantiator` 最終新增 `LookupHub` 與 `lookupHub` property，把前述 facade methods 收攏成單一 hub-style public surface：

- `grams(for:)`
- `hasGrams(for:)`
- `associatedCandidates(forPairs:)`
- `associatedCandidates(forPair:)`
- `supplementalValues(for:strategy:)`
- `cassetteQuickSets(for:strategy:)`

此時舊 `query*` / `cassetteQuickSetsFor(...)` 名稱仍暫留為 deprecated compatibility wrappers，目的是先讓 repo 內主流程完成 migration，再處理外部整合點與退場策略。

### P5：移除 compatibility wrappers，讓 public surface 完成收束

P4 術後盤點已證明 runtime repos 與 workspace-known downstream repos 沒有任何 code-level 舊呼叫點，因此 P5 被明確界定為 breaking cleanup，而不是行為手術。最終刪除的 wrapper 為：

- `queryGramsfor(_:)`
- `hasGramsfor(_:)`
- `queryAssociatedCandidates(withPairs:)`
- `queryAssociatedCandidates(withPair:)`
- `queryETenDOSSequence(reading:strategy:)`
- `queryETenDOSSequence(reading:)`
- `cassetteQuickSetsFor(key:strategy:)`
- `cassetteQuickSetsFor(key:)`

至此 current tree 的唯一 canonical public lookup surface 已收斂為 `LMInstantiator.lookupHub`。

---

## 四、Phase 36 結束時的 API 狀態

### 4.1 總控與策略

1. `LMInstantiator.Config.partialMatchEnabled` 是下游 partial-match 的總控旗標。
2. factory dictionary 以 `FactoryCoreLookupStrategy.configuredLookup` / `.strictSuperset` 區分「尊重既有設定的正常查詢」與「完整鍵嚴格超集查詢」。
3. plain BPMF / 倚天 DOS / cassette quick result 以 `SupplementalLookupStrategy.configuredLookup` / `.exactMatch` / `.partialMatch` 表達其 facade vocabulary。

### 4.2 對外 canonical surface

`LMInstantiator.lookupHub` 現在是唯一 canonical public lookup surface。MainAssembly 與 Typewriter 的所有 production caller 都已改綁這層 hub；舊 `query*` 名稱與 `cassetteQuickSetsFor(...)` 已完全離開 current tree。

### 4.3 與 LibVanguard Phase 35 的對位關係

Phase 36 並沒有再替 TrieKit 發明一個新 hub；它做的是把 downstream `LMInstantiator` 整理成與 `TrieHub` 同類型的 caller-facing facade。這個 phase 的成果不是名稱對齊，而是 responsibility 對齊。

---

## 五、驗證結果

Phase 36 落地時的最小驗證集合如下：

1. `vChewing-macOS/Packages/vChewing_LangModelAssembly`
   - `testAssociatedCandidateFacadePreservesExpansionAndDedupOrder`
   - `testETenDOSSequenceLookupStrategySeparatesConfiguredExactAndPartial`
   - `testCassetteQuickSetLookupStrategyPreservesConfiguredBackendDefault`
   - `testAssemblerFacadeMatchesLegacyUnigramSurface`
2. `vChewing-macOS/Packages/vChewing_Typewriter`
   - `test_IH104_CassetteQuickPhraseSelection`
   - `test_IH111_ETenExclusiveCandidatesAppendAtTailWithoutReordering`
   - `test_IH112_ETenSequenceEnforcementStillReordersCandidates`
3. `vChewing-OSX-legacy`
   - `make debug-core`

上述 focused validations 在落地過程中均已通過。之後維護者亦另行重跑 Typewriter 與 MainAssembly 全部單元測試，結果綠燈。

另外，workspace-level grep 已確認 `vChewing-macOS`、`vChewing-OSX-legacy`、`vChewing-LibVanguard`、`vChewing-VanguardLexicon`、`vChewing-HomePage.io` 這些 workspace-known repos 中，不再有任何舊 wrapper 名稱的 code-level 呼叫。

---

## 六、最終結論

Phase 36 的完成態可以直接概括為三句話：

1. `LMInstantiator` 現在終於擁有 downstream 自己的 partial-match 總控與 lookup strategy vocabulary。
2. strict-superset、supplemental partial-match、以及 caller-facing hub surface 現已各自就位，不再被混成數個模糊布林與散落的 glue。
3. `lookupHub` 已成為 current tree 中唯一 canonical public lookup surface；這一步是 `LMInstantiator` 向 `TrieHub` 對位的完成態，而不是另一輪 protocol surgery。

---

## 附錄 A：P5 wrapper retirement 準入清單

這份 appendix 保留作日後審計與類似 breaking cleanup 的 reusable gate。其角色是 entry gate，不是實作報告。

### A.1 預定移除範圍

- `queryGramsfor(_:)`
- `hasGramsfor(_:)`
- `queryAssociatedCandidates(withPairs:)`
- `queryAssociatedCandidates(withPair:)`
- `queryETenDOSSequence(reading:strategy:)`
- `queryETenDOSSequence(reading:)`
- `cassetteQuickSetsFor(key:strategy:)`
- `cassetteQuickSetsFor(key:)`

### A.2 準入條件

- G1. Workspace-known downstream repos 已無任何 code-level 舊呼叫點。
- G2. Out-of-workspace consumers 狀態已被明確判定。
- G3. 至少經過一個 deprecation 緩衝週期，或由 maintainer 明確接受直接 break。
- G4. 非歷史性文件已全面以 `lookupHub` 為 canonical surface。
- G5. surgery diff 被限制在 compatibility layer 與必要文件更新。
- G6. focused validation commands 已預先列好，且可在當前 toolchain 執行。

### A.3 完工定義

1. wrapper 在 macOS 與 legacy 兩邊全部刪除。
2. repo 內 grep 對舊名稱只剩歷史文件，或已完全歸零。
3. LangModelAssembly focused regressions、Typewriter focused regressions、legacy `make debug-core` 全數通過。
4. 文件已明確記錄 `lookupHub` 是唯一 canonical public surface。

---

## 附錄 B：P5 開工模板

這份 appendix 保留的是 release-manager 風格的術前證據包格式。未來若遇到類似 wrapper retirement 類工作，可直接照此模板填寫。

### B.1 基本資訊

- 開工日期：`[YYYY-MM-DD]`
- 執行者：`[Name / Agent]`
- 目標 repo：`vChewing-macOS` / `vChewing-OSX-legacy`
- 預定移除版本：`[vX.Y.Z]`
- deprecation 首次對外版本 / commit：`[fill here]`

### B.2 零舊呼叫點盤點

建議命令：

```zsh
cd '[WORKSPACE_ROOT]/!vChewing'
rg -n 'queryGramsfor\(|hasGramsfor\(|queryAssociatedCandidates\(|queryETenDOSSequence\(|cassetteQuickSetsFor\(' \
  vChewing-macOS \
  vChewing-OSX-legacy \
  vChewing-LibVanguard \
  vChewing-VanguardLexicon \
  vChewing-HomePage.io
```

記錄欄位：

- grep 日期：`[YYYY-MM-DD]`
- 結論：`[zero code-level usages / not ready]`
- 例外：`[only historical docs / other]`
- 證據摘要：`[fill here]`

### B.3 外部 consumer 判定

- 狀態：`[all migrated / breakage accepted / unknown]`
- 維護者確認方式：`[issue / release note / direct confirmation]`
- 風險備註：`[fill here]`

### B.4 文件與版本條件

- 已經過至少一個 deprecation release cycle：`[yes/no]`
- README / migration notes / DevPlans 已全面改用 `lookupHub`：`[yes/no]`
- 歷史文件中的舊 API 已明確標示 historical context：`[yes/no]`

### B.5 驗證命令

```zsh
cd '[WORKSPACE_ROOT]/!vChewing/vChewing-macOS/Packages/vChewing_LangModelAssembly'
swift test --filter 'testAssociatedCandidateFacadePreservesExpansionAndDedupOrder|testETenDOSSequenceLookupStrategySeparatesConfiguredExactAndPartial|testCassetteQuickSetLookupStrategyPreservesConfiguredBackendDefault|testAssemblerFacadeMatchesLegacyUnigramSurface'
```

```zsh
cd '[WORKSPACE_ROOT]/!vChewing/vChewing-macOS/Packages/vChewing_Typewriter'
swift test --filter 'test_IH104_CassetteQuickPhraseSelection|test_IH111_ETenExclusiveCandidatesAppendAtTailWithoutReordering|test_IH112_ETenSequenceEnforcementStillReordersCandidates'
```

```zsh
cd '[WORKSPACE_ROOT]/!vChewing/vChewing-OSX-legacy'
make debug-core
```

### B.6 Go / No-Go 判定

- G1 零舊呼叫點：`[pass/fail]`
- G2 外部 consumer 判定：`[pass/fail]`
- G3 deprecation 緩衝期：`[pass/fail]`
- G4 文件狀態：`[pass/fail]`
- G5 surgery scope：`[pass/fail]`
- G6 驗證命令：`[pass/fail]`
- 最終決定：`GO / NO-GO`
- 決定理由：`[fill here]`
- 維護者覆核：`[Name / date / note]`
