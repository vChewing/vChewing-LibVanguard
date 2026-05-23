# Phase 53 — 中英文混輸（Typewriter 層）研究統整版

**文件定位**：Phase 53 的最終研究結論與實作規格書。內容已與落地程式碼對齊。
**落地狀態**：已在下游倉庫完成實作，且已 squash。

- vChewing-macOS: `af843292625c647e9b767d005d54bc0edd59952a`
- vChewing-OSX-Legacy: `51babc6d37dd4596df3a9285a54c737d82c85e09`

**沿革註記**：
- 舊稿 `Phase53_PreResearchDraft.md` 混合了大量術前假說與術後追記，僅留供存證。
- 本文件為統整後的單一可接手敘事，以「第一性原理→設計決策→實作規格→行為規則→已知限制」結構撰寫。

---

## 1. 問題定義與範圍

Phase 53 的目標是在 vChewing factory typing mode 下完成中英文混輸，且必須同時滿足：

1. 功能下放於 Typewriter/InputHandler 層，不侵入 Session 層。
2. 可由偏好設定開關控制，且預設關閉。
3. 與 cassette mode 互斥。
4. 拼音模式下自動退化至原有行為。
5. 可在 macOS 與 legacy 倉庫鏡像維護。

---

## 2. 為何拒絕早期 Session 耦合 PR

被否決參考設計（`Phase53_Ref-MixedInputMode-Architecture-Denied.md`）被拒絕的主因：

1. 將 mixed 狀態耦合於 Darwin Session 檔案（`InputSession*`），不利跨平台維護。macOS 專屬的 Darwin 層在 Linux 建置目標下無法編譯。
2. 設計基於 Homa 手術前語境（Megrez/Compositor API），與現行 `InputHandlerProtocol` → `Homa.Assembler` 的 API surface 差異甚大，直接套用毫無可能。
3. 對鍵盤布局與聲調鍵規則有過度硬編碼（大千 `3/4/6/7`），無法泛化到其他注音排列或拼音模式。

結論：正確插入點是 `.vChewingFactory` 既有分派下的 Typewriter 子分流，而非 Session 層。

---

## 3. 架構設計決策

### 3.1 Mixed 不是新 TypingMethod，而是行為旗標

Phase 53 **不新增** `TypingMethod` enum case。理由：

- 各 `TypingMethod` 案例之間是互斥的輸入模式（內碼、漢音符號、羅馬數字）；混輸並非與注音互斥，而是注音輸入的行為變體。
- 正確對應物是 `prefs.cassetteEnabled`——它決定了 `.vChewingFactory` 下使用哪個 Typewriter。混輸應以相同模式——偏好旗標——來決定在 `.vChewingFactory + !cassetteEnabled` 下使用 `BPMFFullMatchTypewriter` 還是 `MixedAlphanumericalTypewriter`。

最終分派邏輯（`InputHandler_HandleComposition.swift`）：

```swift
case .vChewingFactory where hardRequirementMet && !prefs.cassetteEnabled:
  if prefs.mixedAlphanumericalEnabled, !composer.isPinyinMode {
    return MixedAlphanumericalTypewriter(self).handle(input)
  }
  return BPMFFullMatchTypewriter(self).handle(input)
```

### 3.2 MixedAlphanumericalTypewriter 的型別設計

```swift
@frozen
public struct MixedAlphanumericalTypewriter<Handler: InputHandlerProtocol>: TypewriterProtocol {
  public let handler: Handler
  public init(_ handler: Handler) { self.handler = handler }
  public func handle(_ input: some InputSignalProtocol) -> Bool? { ... }
}
```

- 平台無關的泛型 struct，與 `BPMFFullMatchTypewriter` 平行。
- 兩倉庫（macOS 的 `Handler` vs Legacy 的 `InputHandler`）泛型參數名稱無需與 associatedtype 一致，宣告語法可共用。

### 3.3 核心模型：雙軌輸入

mixed mode 啟用時的狀態模型：

1. `composer`：繼續承擔注音組字語義，保存注音符號序列。
2. `mixedAlphanumericalBuffer`：保存 ASCII fallback 序列（新增於 `InputHandlerProtocol`）。

兩軌透過 auto-split 演算法動態劃分邊界。系統在每次鍵入時判定應留在注音路徑或回退 ASCII，不需要使用者手動切換。

### 3.4 互斥條件完備性

三道互斥守衛均到位：

| 守衛位置 | 條件 | 層級 |
|----------|------|------|
| `handleComposition` | `!prefs.cassetteEnabled` | 路由分派層 |
| `MixedAlphanumericalTypewriter.handle` | `!handler.composer.isPinyinMode` | 執行期入口守衛 |
| `UserDef / PrefMgr` | `mixedAlphanumericalEnabled` 預設 `false` | 偏好控制 |

cassette 與 pinyin 的互斥在兩個獨立層級分別保證，無繞過風險。

### 3.5 Session 層最小介入

整個 Phase 53 對 Darwin Session 層的修改僅限一處：

`InputSession_CoreProtocol.resetInputHandler()` 新增一行 buffer 提交邏輯（CapsLock 切換、deactivate 時不遺失 pending buffer）：

```swift
if !inputHandler.mixedAlphanumericalBuffer.isEmpty {
  textToCommit += inputHandler.mixedAlphanumericalBuffer
}
```

`InputSession_HandleEvent` 無任何 Phase 53 專屬修改。符合「不侵入 Session 層」的設計約束。

---

## 4. `mixedAlphanumericalBuffer` 生命週期

### 4.1 宣告與初始化

```swift
// InputHandlerProtocol 新增
var mixedAlphanumericalBuffer: String { get set }
```

實作型別初始化時設為 `""`。

### 4.2 完整操作路徑

| 操作 | 涉及位置 | 語義 |
|------|---------|------|
| 初始化/清除 | `clearComposerAndCalligrapher()` | 與 composer/calligrapher 連動清除 |
| 首鍵寫入 | `MixedAlphanumericalTypewriter.handle` 空buffer分支 | 注音鍵同時寫入 composer + buffer；非注音鍵只寫 buffer |
| 後續鍵 append | `handle` 非空buffer分支 | 經 auto-split / fully-parser-covered / fallback 路徑追加 |
| Backspace 刪尾 | `handleBackSpace → dropLast() → syncComposerWithMixedAlphanumericalBuffer()` | 重建 composer 狀態 |
| Enter 提交 | `handleEnter` 的 mixed 分支 | 先提交中文段再提交 ASCII |
| Esc 清除 | `handleEsc` 的 `!mixedAlphanumericalBuffer.isEmpty` 分支 | 優先清 buffer |
| CapsLock reset | `resetInputHandler()` | 追加提交 pending buffer |
| `isComposerOrCalligrapherEmpty` | 含 `!mixedAlphanumericalBuffer.isEmpty` 判定 | 空值語義一致 |
| `readingForDisplay` | 空注音時 fallback 至 `mixedAlphanumericalBuffer` | 顯示邏輯正確 |
| `generateStateOfInputting` tooltip | 顯示 ASCII buffer 原文（`tooltipDuration = 0`，恆久顯示） | 使用者回饋到位 |

### 4.3 `syncComposerWithMixedAlphanumericalBuffer()`

Backspace 刪除 buffer 尾字後，需重建 composer 的注音狀態以保持顯示一致性：

1. 清空 `rebuiltComposer`。
2. 若 buffer 非空且 `isFullyParserCovered`，以 `receiveSequence` 重建注音狀態。
3. 若重建後 `!isPronounceable`，清空 composer。
4. 以 rebuiltComposer 取代 handler.composer。

---

## 5. `MixedAlphanumericalTypewriter.handle(_:)` 主流程

該方法為 Phase 53 的核心，約 200 行，依序處理：

### 5.1 入口守衛

拼音模式回退至 `BPMFFullMatchTypewriter`：
```swift
guard !handler.composer.isPinyinMode else {
  return BPMFFullMatchTypewriter(handler).handle(input)
}
```

### 5.2 Symbol menu physical key

buffer 非空時先 commit（中文+ASCII），再回傳 `nil` 放行至上層符號選單。確保「先 flush 再落入符號選單」的語義。

### 5.3 Space 鍵處理（最複雜的分支）

1. 若 `shouldPreferASCIIWordPath` 為 true → 純 ASCII 路徑，不嘗試注音。
2. 嘗試 `tryAutoSplitASCIIAndPhoneticSuffix(requiresWordLikePrefix: true)` — 將 buffer+space 拆成 ASCII 前綴 + 注音後綴。
3. 若 composer 有注音內容且非 ASCII word 偏好，交給 `BPMFFullMatchTypewriter` 處理，並設 `onLexiconMatchFailure` fallback：辭典查無結果時 commit 中文段 + ASCII buffer + 空白。
4. composer 為空時直接 commit 中文 + ASCII buffer + 空白。

**`onLexiconMatchFailure` 閉包**（Space 路徑）：`BPMFFullMatchTypewriter` 詞庫查詢失敗時，回退為「中文段 + ASCII buffer + 空白」。此閉包注入模式乾淨地處理了 Space 確認時的歧義，未將回退邏輯耦合至 BPMFFullMatchTypewriter 本身。

**`shouldPreferASCIIWordPath` 的 `minimumOverwriteCount` 差異化**：Space 路徑採門檻 `1`（較寬鬆），其餘路徑採預設 `2`。此差異化合理，因 Space 是使用者明確表達「我要提交」的意圖。

### 5.4 Option+主鍵盤區 ASCII 直交

透過 `resolveLiteralASCIIMainAreaText` 提取純 ASCII（忽略 Option glyph substitution 如 `≠`、`Å`、`¿`，改回基礎 ASCII glyph），呼叫 `commitLiteralASCIIImmediately` 立即分兩次 commit（先 pending 中文+buffer，再 commit 該 ASCII 字元）。Shift 仍決定大小寫。

### 5.5 Reserved key / Numeric pad / Function key guard

僅放行標點字元穿透此 guard，其餘回傳 `nil`。

### 5.6 可見字元語義解析（`resolveVisibleInputText`）

- 大寫英文字母保留原大小寫（`This` 首字大寫不被 lowercased）。
- Shift+符號保留可見字元語義（如 `?` 不退化成 `/`）。
- 透過 `inferredLatinKeyboardLayout().mapTable` 查 keyCode 回填 shifted glyph（當 Shift 按住但事件未提供 shifted glyph 時）。

> 注意：`mapTable` 的正確性依賴 `inferredLatinKeyboardLayout()` 與 keyCode 的一致性。若使用者使用非拉丁布局（Dvorak、Colemak），取決於 `inferredLatinKeyboardLayout()` 的實作品質。目前引用既有基礎設施。

### 5.7 強制 ASCII 標點路徑（`forceASCIIPunctuationPath`）

當 buffer 已有 ASCII alnum 或非注音鍵，且新鍵不是合法注音鍵時，強制走 ASCII 標點路徑——不再嘗試將新鍵解讀為注音。

### 5.8 CJK 標點優先判斷

`matchesCJKPunctuation` 的三層判定：

1. 標點字元 + 非 phonetic key + 詞庫有命中 → flush + return nil（交給上層標點管線）。
2. `isShiftQuestionMark` 例外：Shift+? 強制保留 ASCII 語義。
3. `isPhoneticKeyRaw` 優先：合法注音鍵不走標點分流。

此三層判定正確解決了「`z; ` 仍可輸入 `芳`」與「Shift+? 不被誤導至 CJK 標點」的矛盾。

### 5.9 Control / Option / Command 修飾鍵

回傳 `nil`（Option 已在步驟 5.4 處理）。

### 5.10 首鍵進入（buffer 為空時）

- 注音鍵：同時餵給 composer（顯示注音）與 buffer（ASCII 後備）。
- 非注音鍵：清 composer，只進 buffer。

### 5.11 非空 buffer 後續鍵

依序嘗試以下路徑，首次成功即返回：

1. **Auto-split（`requiresWordLikePrefix: true`）**：嘗試將 fullInput 拆成 ASCII 前綴 + 注音後綴。要求前綴為 word-like（`^[A-Za-z]{3,}[A-Za-z0-9]*$`）。
2. **整段注音路徑**：若 `isFullyParserCovered` 且非 force ASCII 且非 shouldPreferASCIIWordPath，試組 trialComposer → 可發音且有詞庫命中 → insertKey 到 assembler → commit overflow → clear buffer。
3. **聲調前置封鎖**：`acceptLeadingIntonations = false` 時，若 fullInput 以獨立聲調鍵起頭，跳過注音路徑。
4. **Auto-split 第二次嘗試（`requiresWordLikePrefix: false`）**：不要求 word-like 前綴，支援 `hello你好` 類型。
5. **最終 fallback**：清 composer，fullInput 全部存入 buffer。

> `isLeadingToneBlocked` 在 fully-parser-covered 路徑內以 trial composer 檢測聲調前置，與 `buildAutoSplitCandidate` 內的相同邏輯形成雙重防護。兩處邏輯一致，無矛盾。

---

## 6. Auto-Split 演算法

### 6.1 核心思想

auto-split 的目標是在不要求使用者手動切換的情況下，即時計算最優 ASCII/Phonetic 邊界。例如 `Hellosu3` 自動拆分為 ASCII 前綴 `Hello` + 注音後綴 `su3`（ㄋㄧˇ），提交 `Hello` 後讓 `su3` 進入正常注音組字。

### 6.2 搜尋範圍

suffix length ∈ [1, min(4, fullInput.count - 1)]。上限 4 對應 Tekkon 單音節最多 4 鍵的約束。

### 6.3 Reading key 去重

同 reading key 保留最短 suffix，避免多餘鍵位覆寫干擾（較長 suffix 只是多餘鍵位覆寫同一注音結果）。

### 6.4 過濾條件

- suffix 首鍵為 ASCII 標點 → `nil`：防止標點鍵混入注音後綴。
- `acceptLeadingIntonations = false` 時，後綴首鍵若為獨立聲調 → `nil`：偏好一致性。
- `readingKey.contains(keySeparator)` 或含空白 → `nil`：防止多音節 key 偽裝為單音節。

### 6.5 排序四層

選擇最優候選的 `max(by:)` 閉包內含四層 if-chain：

| 層級 | 比較項目 | 生效條件 |
|------|---------|---------|
| ① | `prefersDigitLeadingSuffix` | 僅 word-like prefix + 數字開頭後綴 |
| ② | `prefersLongerPureAlnumSuffix` | 僅 `requiresWordLikePrefix` 時純 alnum 後綴 |
| ③ | `bestProbability` | 詞庫最高機率 |
| ④ | `suffixLength` | tie-break |

### 6.6 `isWordLikeASCIIPrefix` 定義與 Auto-Split Guard 策略

`^[A-Za-z]{3,}[A-Za-z0-9]*$`——至少 3 個字母開頭。

Phase 55 的修正並未調整此門檻，而是改變了 `requiresWordLikePrefix: true` 路徑中 **hard gate 的邏輯**。最終版分層策略（經 `rul4` regression 修正後）：

1. **Word-like prefix**（`isWordLikeASCIIPrefix` 為 true）：一律允許，維持英文詞完整性（`This` / `Hello` / `tod` 等，皆 ≥ 3 字母）。
2. **純字母 prefix 且長度 ≥ 2 且 suffix 長度 ≥ 3**：允許進入候選池。這讓 `ai`+`jo6`（2 字母前綴 + 3 鍵後綴）能被評估，同時精準排除 `r`+`ul4`（前綴僅 1 字母，確定為注音的一部分）、`ru`+`l4`（suffix 僅 2 鍵，短後綴歧義過高）。
3. **其餘 prefix**（含標點、數字、單字母、或非純字母）：在 `requiresWordLikePrefix: true` 路徑中繼續被排除，保護 `?c96` 等標點前置輸入不被誤切。

此分層策略的核心思想是：**以「前綴最短長度」與「後綴最短長度」組合門檻，精準區分「英文詞起手」（≥2 字母）與「注音序列的一部分」（單字母）。** 單字母前綴放行是 Phase 55 初次嘗試的教訓——`r` 單字母在被 clean composer 重播時可產生不同於全序列的讀音，導致 LM 回傳非預期候選。

### 6.7 歧義案例覆蓋

| 輸入 | 預期切分 | 排序層級生效 |
|------|---------|-------------|
| `This5jp3` | `This` + `5jp3`(準) | ① digit-leading |
| `thisgjo6` | `this` + `gjo6`(誰) | ③ probability |
| `?c96` | `?` + `c96`(還) | ③ probability（prefix 非 word-like，① 不生效） |
| `Twinsu.4` | `Twins` + `u.4`(又) | ③ probability（su.4 機率低於 u.4） |
| `Hellosu3` | `Hello` + `su3`(你) | ② prefersLongerPureAlnumSuffix |

### 6.8 `applyAutoSplitCandidate`

若組字區已有中文，先 commit 中文、清空 assembler。然後 insert readingKey 到 assembler、commit overflow + ASCII 前綴、clear buffer，觸發 SCPC tasks。

---

## 7. ASCII Word 啟發式（`shouldPreferASCIIWordPath`）

### 7.1 問題

大千鍵盤下，純英文字如 `tod`、`film`、`the`、`hell` 逐字送入 composer 會不斷覆寫 slot（destructive overwrite），但 Tekkon 的 `inputValidityCheck` 仍會判定為「合法注音鍵」，導致 Space 時被誤判為注音提交（如 `tod ` → `剋`、`film ` → `瘀`）。

### 7.2 解法

以 Tekkon composer 槽位覆寫次數作為「這串 ASCII 更像是英文詞」的啟發式指標：

```
for each char in fullInput:
    receiveKey(char)
    if slot consumption is non-advancing: destructiveOverwriteCount++
return destructiveOverwriteCount >= minimumOverwriteCount
```

- Space 路徑採門檻 `1`（較寬鬆，因 Space 是明確提交意圖）。
- 其餘路徑採門檻 `2`（預設）。

此啟發式簡潔有效：它捕捉了 `the`、`hell`、`tod`、`film` 等英文詞在 Dachen 布局下因槽位覆寫而產生的 digestion trace，且不依賴外部詞典。缺點是它是基於鍵位層級的啟發式，對極短詞（2 字元）和罕見覆寫模式的詞可能不足——此為已知限制，不是意外回歸。

---

## 8. 提交語義

### 8.1 Enter 提交

採「注音遞交優先、ASCII fallback 次之」規則：

1. 清 composer，提取 ASCII text。
2. commit `chineseText + asciiText`。

### 8.2 Space 提交

Space 觸發結構化判斷序列（見第 5.3 節），不再盲目偏向注音分支。fallback 提交時，先提交既有中文段，再提交 ASCII buffer + 空白。

### 8.3 CapsLock / Session Reset

`resetInputHandler()` 追加提交 pending mixed ASCII buffer，不再遺失。

---

## 9. 標點與修飾鍵一致性

### 9.1 Shift 可見字元回填

`resolveVisibleInputText` 確保 Shift+符號保留「眼睛看到的字元」而非 `inputTextIgnoringModifiers` 的基底鍵。例如 `?` 不退化成 `/`，`!` 不退化成 `1`。

### 9.2 Scalar-based 標點分流

CJK 標點判定以字元 scalar 屬性為基礎，而非正則表達式，避免 regex char-class 在事件正規化後遺漏符號。

### 9.3 Symbol menu physical key

先 flush mixed 內容（commit 中文+ASCII），再回落既有 menu 管線。確保「先提交再開選單」的語義。

### 9.4 合法注音鍵優先

標點分流不凌駕合法注音鍵。若按鍵同時是合法注音鍵且在標點詞庫有命中，注音語義優先。

### 9.5 Option+主鍵盤區 ASCII 直交

除了 `input.isSymbolMenuPhysicalKey` 例外鍵之外，主鍵盤所有數字鍵/字母鍵/符號鍵只要 Alt 被摁著，就直接以 keyCode + `LatinKeyboardMappings` 還原 raw ASCII，先 flush assembler / buffer 既有內容，再把當前 ASCII 直接 commit。Shift 仍決定大小寫。

---

## 10. 偏好一致性

### 10.1 `acceptLeadingIntonations = false`

在 mixed mode 下被正確尊重，涵蓋兩個路徑：
- fully-parser-covered 路徑（`isLeadingToneBlocked` 以 trial composer 檢測）
- auto-split 候選建構（`buildAutoSplitCandidate` 內同樣檢測）

### 10.2 `mixedAlphanumericalEnabled` 預設關閉

不啟用時所有行為與現況完全一致。

### 10.3 Cassette 互斥

`handleComposition` 路由層級保證 cassette 啟用時不進入 mixed 分支。

---

## 11. 顯示邏輯

### 11.1 `readingForDisplay`

```swift
return currentReading.isEmpty ? mixedAlphanumericalBuffer : currentReading
```

當 composer 無注音內容時，以 buffer 內容作為 reading 顯示（讓 buffer 內容出現在組字區游標位置）。

### 11.2 `generateStateOfInputting` tooltip

`mixedAlphanumericalEnabled && !mixedAlphanumericalBuffer.isEmpty` 時，設 `result.tooltip = mixedAlphanumericalBuffer`、`tooltipDuration = 0`（恆久顯示直到混打結束）。

### 11.3 `isComposerOrCalligrapherEmpty`

納入 `mixedAlphanumericalBuffer.isEmpty` 判斷。此屬性被 `isConsideredEmptyForNow`、`handleBackSpace`、`handleDelete`、`handleForward`、`handleBackward` 等大量函式依賴，擴充後 mixed buffer 有內容時這些操作會被正確阻止。

---

## 12. 功能鍵行為

Backspace / Enter / Escape **不經過** `MixedAlphanumericalTypewriter`（因 `charCode.isPrintableUniChar` 為 false，不滿足 `hardRequirementMet`），而是由 `triageByKeyCode()` 分派至對應 handler。

### 12.1 Backspace

若 `mixedAlphanumericalBuffer` 非空，優先刪除 buffer 最後一字，再呼叫 `syncComposerWithMixedAlphanumericalBuffer()` 重建 composer 狀態，視 emptiness 決定切換至 inputting 或 abortion。

### 12.2 Enter

清 composer，提取 ASCII text → commit `chineseText + asciiText`。

### 12.3 Esc

若 `mixedAlphanumericalBuffer` 非空，呼叫 `clearComposerAndCalligrapher()`（一併清空 buffer），依 `escToCleanInputBuffer` 偏好決定 abort 或保留組字區。

---

## 13. 已納入最終版本的關鍵邊界案例

Phase 53 最終版已明確處理以下回歸：

| 案例 | 問題描述 | 修復機制 |
|------|---------|---------|
| `Hello你好` | 連續輸入的結構化切分 | auto-split（word-like prefix + 注音後綴） |
| `This5jp3` | 數字前綴後綴的邊界保留 | ① digit-leading suffix 排序 |
| `thisgjo6` | boundary drift 防止 | ③ probability 排序 |
| `?c96` | 非 word-like prefix 的 digit-leading 誤判 | ① 僅 word-like prefix 生效 |
| `tod ` | Space finalize 誤判注音提交（`剋`） | `shouldPreferASCIIWordPath` 啟發式 |
| `film ` | Space finalize 誤判注音提交（`瘀`） | `shouldPreferASCIIWordPath` 啟發式 |
| `3su` | `acceptLeadingIntonations = false` 被繞過 | 雙重防護（fully-parser-covered + auto-split） |
| `?` vs `/` | Shift+符號可見語義退化 | `resolveVisibleInputText` 保留 shifted glyph |
| `aijo6` | `ai` 前綴被擋在 word-like guard 外，導致誤切 `aij`+`o6`(ㄟˋ→欸) | Phase 55 分層 guard：「純字母前綴 ≥ 2 + suffix ≥ 3」放行 `ai`+`jo6`，`prefersLongerPureAlnumSuffix` 讓 `jo6` 勝出 |
| `AIjo6` | 同上，大寫前綴 `AI` 同樣被擋住 | Phase 55 同上修正 |
| `rul4` | 自動拆分為 `r`+`ul4`(&apm;要)，但預期是全注音 `叫` | Phase 55 分層 guard 以 `prefixText.count >= 2` 排除單字母前綴，讓全序列進入 fully-parser-covered 路徑 |
| `?c96` | 無條件放寬 guard 時 `c`+`96` 被誤切，導致 `?` 與 `c` 分離 | Phase 55 分層 guard 保留標點前綴的保護 |
| `4gjo4` vs `4Gjo4` | 大寫字母被塞入 Tekkon composer 導致大小寫無差別 | Phase 55 大寫字母阻斷：buffer 空時 `isPhoneticKey` 排除大寫，`isFullyParserCovered` 路徑新增 `fullInputHasUppercase` 檢查 |
| `4gj;3` | 全段注音路徑提交 `數`，但預期 `4`+`爽` | Phase 55 leading digit 阻斷：`startsWithASCIIDigit` 跳過全段注音，讓 auto-split 處理 |
| `3su`（mixed mode） | 聲調前置在 mixed mode 下仍進入注音路徑 | Phase 55 leading digit 阻斷後 `3su` 留在 ASCII buffer（聲調前置應在非 mixed mode 使用） |
| CapsLock | buffer 內容遺失 | `resetInputHandler()` 追加提交 |

---

## 14. 驗證覆蓋

### 14.1 測試族群分佈

| 族群 | 案例數 | 覆蓋面向 |
|------|--------|---------|
| IH401A–IH411D | 24 | mixed buffer 基本生命週期、Enter/Space/Esc/Backspace 分支、auto-split 排序、Space finalize 邊界、偏好旗標一致性 |
| IH412–IH423 | 12 | 符號可見語義、ASCII 標點提交、Option 標點直交、合法注音鍵優先、symbol menu flush-then-fallthrough |
| IH404、IH411、IH420–IH422、IH424 | 8 | English-like token heuristic、Shift 可見字元、動態 CJK 標點命中、Option+數字/字母/符號直交 |
| test504 | 1 | CapsLock reset 提交 pending mixed buffer |

**總計 42 個測試斷言族**。

### 14.2 最終驗證結果

- IH401–IH411 focused regressions：24/24 PASS
- Legacy debug core build：success

---

## 15. 已知限制

1. **全 parser-covered 短英文 token**：對「全由 parser-covered ASCII 構成且缺乏明確 non-advancing digestion trace」的短英文 token，持續鍵入階段仍可能維持 zhuyin-first 行為。此為設計取捨（優先中文的雙軌方案），不是意外回歸。

2. **`handle(_:)` 的認知負荷**：該方法含 7 個以上 early-return 分支、2 個 auto-split 呼叫點（差異僅在 `requiresWordLikePrefix`）、1 個 fully-parser-covered 分支。若後續維護中再增加分支，建議將「非空 buffer 後續鍵」區段拆為私有方法（如 `handleBufferedInput(fullInput:input:session:)`），以降低單一方法的行數與分支深度。

3. **`AutoSplitCandidate` 排序的四層比較**：`bestAutoSplitCandidate` 的 `max(by:)` 閉包內含四層 if-chain，可讀性尚可但擴展時需小心。若日後排序層級增加，建議改為明確的 `SortKey` 元組或 `Comparable` 結構。

4. **POM 與漸退記憶**：`mixedAlphanumericalBuffer` 中的 ASCII 文字不會進入 `assembler`，因此不會產生 POM 觀測。對重度依賴 POM 的使用者，POM 無法學習混輸模式下頻繁輸入的 ASCII 單字。

---

## 16. 後續維護守則

Phase 53 之後若要延伸 mixed mode，請視下列為硬性邊界：

1. **不得**把 mixed 狀態重新耦合回 Session 層。
2. split 策略維持「單音節、結構有界」；除非另有性能/UX 設計核准。
3. 必須維持偏好一致性（`acceptLeadingIntonations`、mixed toggle、cassette exclusion）。
4. macOS 與 legacy 必須同窗鏡像更新。
5. 行為變更時，三份敘事文件必須同步更新：
   - `DevPlans/Reqs4LLM/Reqs_0051-0060.md`
   - `DevPlans/LibVanguard-KnowledgeMemo4LLM.md`
   - `DevPlans/LibVanguard-DevReqsHistory.md`

---

## 17. 跨倉庫同步差異

`vChewing-OSX-Legacy` 的 `Typewriter_MixedAlphanumerical.swift` 核心邏輯與 macOS 端完全一致。差異僅在於：

1. Legacy 端缺少 `resolveLiteralASCIIMainAreaText` / `commitLiteralASCIIImmediately` 的獨立方法（其邏輯內聯在 `handle(_:)` 的 Option 分支中）。
2. 兩倉庫 `TypewriterProtocol` 的 associatedtype 名稱已統一為 `Handler`（Legacy 的 `InputHandler` 差異已於 `c436fe8a3e0c6bee186a7749add4b0d63ca5cd58` 抹平）。

建議：若 Legacy 端後續維護允許，可考慮將 Option 直交邏輯也抽取為獨立方法，以降低與 macOS 端的程式碼漂移風險。

---

## 18. 交叉參照

- `DevPlans/Reqs4LLM/Reqs_0051-0060.md`（Phase 53 區段）
- `DevPlans/LibVanguard-KnowledgeMemo4LLM.md`（Phase 53 條目）
- `DevPlans/LibVanguard-DevReqsHistory.md`（Phase 53 表格列）
- `Phase53_PreResearchDraft.md`（已過期存證，含術前假說與虛擬碼）
