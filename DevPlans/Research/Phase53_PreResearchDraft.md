# Phase 53 — 中英文混輸模式下放 Typewriter 層的前期研究

> ⚠️ **本文件已過期，僅留供存證。** 正式版本請洽 `Phase53_Research.md`。
> 本文件混合了大量術前假說、中間迭代虛擬碼與術後追記，接手閱讀體驗極差。
> Phase 53 的最終設計決策、實作規格與行為規則已統整於 `Phase53_Research.md`。

**研究日期**：2026-04-27（1st Research 完稿）/ 2026-04-27（2nd Research 修訂完稿）/ 2026-04-28（Post-Surgery 現況同步）  
**1st 研究人員**：Claude Sonnet 4.6 (via GitHub Copilot)  
**2nd 研究人員**：KIMI-K2.6
**稽核人員**：GPT-5.3-Codex & KIMI-K2.6
**作業範疇**：純研究，不進行任何程式手術

> **現況同步註記（2026-04-28）**：本文原始內容含大量「手術前設計假說」。本次已補上與現行程式碼一致的行為描述（特別是 Space fallback、大寫保留策略、`onLexiconMatchFailure` hook），以便後續需求評估能直接對照現況。

---

## 一、被否決 PR 方案分析（Phase53_Ref-MixedInputMode-Architecture-Denied.md）

被否決方案的核心設計是「兩層 Buffer 架構」：

- **rawBuffer**（`String`）：累積原始按鍵序列，存放在 `InputSession` 層
- **Assembler/Compositor**：管理已辨識中文的組字器，存放在 `InputHandler` 層

其問題在於：

1. **Session 高度耦合**：`rawBuffer` 的宣告、`Ctrl+Shift+M` 切換快捷鍵、`isInMixedMode` 狀態旗標、以及「commit 英文後清空 buffer」的行為，全都實作在 `InputSession.swift` / `InputSession_HandleMixedInput.swift` / `InputSession_HandleEvent.swift`，這三個檔案是 macOS 專屬的 Darwin 層，**無法在 Linux 建置目標下編譯**。

2. **Homa 已取代 Megrez**：被否決的 PR 是在 Homa 手術之前提出的，使用了當時的 Megrez/Compositor API。目前的 `InputHandlerProtocol` 已經對接 `Homa.Assembler`，API surface 差異甚大，直接套用毫無可能。

3. **拼音相容性問題**：被否決方案僅針對大千鍵盤設計，tone key 辨識邏輯（`3/4/6/7` 為聲調鍵）是硬編碼的，無法泛化到其他注音排列，更無法與拼音模式共存。

---

## 二、現行 Typewriter 層架構解析

### 2.1 TypewriterProtocol

**vChewing-macOS**（`Packages/vChewing_Typewriter/Sources/Typewriter/Typewriter/TypewriterProtocol.swift`）：

```swift
public protocol TypewriterProtocol {
  associatedtype Handler: InputHandlerProtocol
  typealias State = Handler.State
  typealias Session = Handler.Session
  var handler: Handler { get }
  init(_ handler: Handler)
  func handle(_ input: some InputSignalProtocol) -> Bool?
}
```

**vChewing-OSX-Legacy**（`Shared/vChewingComponents/Typewriter/Typewriter/TypewriterProtocol.swift`）：

```swift
public protocol TypewriterProtocol {
  associatedtype InputHandler: InputHandlerProtocol
  typealias State = InputHandler.State
  typealias Session = InputHandler.Session
  var handler: InputHandler { get }
  init(_ handler: InputHandler)
  func handle(_ input: some InputSignalProtocol) -> Bool?
}
```

> **跨倉庫注意**：兩個倉庫的 associatedtype 名稱不同（macOS 為 `Handler`、Legacy 為 `InputHandler`），但實作時的泛型參數名稱無需與 associatedtype 一致，只要 `handler` 屬性與 `init(_:)` 的型別滿足 `InputHandlerProtocol` 條件即可。兩倉庫可共用相同的 struct 宣告語法（`MixedAlphanumericalTypewriter<Handler: InputHandlerProtocol>`）。

這是一個平台無關的協定。現有五種實作型別：

| 型別 | 說明 | 啟動條件 |
|------|------|---------|
| `BPMFFullMatchTypewriter` | 注音全字元符合輸入 | `!prefs.cassetteEnabled` |
| `CassetteTypewriter` | 磁帶模式（CIN2 筆畫） | `prefs.cassetteEnabled` |
| `CodePointTypewriter` | Unicode 內碼輸入 | `currentTypingMethod == .codePoint` |
| `HaninSymbolTypewriter` | 漢音鍵盤符號 | `currentTypingMethod == .haninKeyboardSymbol` |
| `RomanNumeralTypewriter` | 羅馬數字輸入 | `currentTypingMethod == .romanNumerals` |

分派邏輯位於 `InputHandlerProtocol.handleComposition(input:)`（`InputHandler_HandleComposition.swift`）：

```swift
func handleComposition(input: InputSignalProtocol) -> Bool? {
  let hardRequirementMet = !input.text.isEmpty && input.charCode.isPrintableUniChar
  switch currentTypingMethod {
  case .codePoint where hardRequirementMet:
    return CodePointTypewriter(self).handle(input)
  case .romanNumerals where hardRequirementMet:
    return RomanNumeralTypewriter(self).handle(input)
  case .haninKeyboardSymbol where [[], .shift].contains(input.keyModifierFlags):
    return HaninSymbolTypewriter(self).handle(input)
  case .vChewingFactory where hardRequirementMet && prefs.cassetteEnabled:
    return CassetteTypewriter(self).handle(input)
  case .vChewingFactory where hardRequirementMet && !prefs.cassetteEnabled:
    return BPMFFullMatchTypewriter(self).handle(input)
  default: return nil
  }
}
```

### 2.2 InputHandlerProtocol 的 Buffer 屬性群

`InputHandlerProtocol` 目前已有三個「特殊用途字串緩衝區」：

| 屬性 | 用途 |
|------|------|
| `var composer: Tekkon.Composer` | 注拼槽（累積注音或拼音的 romajiBuffer） |
| `var calligrapher: String` | 磁帶組筆區 |
| `var strCodePointBuffer: String` | 內碼輸入組碼區 |

混輸模式如果下放到 Typewriter 層，需要在這個清單中加入第四個緩衝區：`var mixedAlphanumericalBuffer: String`。

### 2.3 TypingMethod enum

```swift
public enum TypingMethod: Int, CaseIterable {
  case vChewingFactory  // = 0
  case codePoint        // = 1
  case haninKeyboardSymbol  // = 2
  case romanNumerals    // = 3
}
```

混輸模式**不應該**成為第四個 `TypingMethod` 案例。原因見下節。

---

## 三、Typewriter 層的設計方向

### 3.1 核心判斷：不是 TypingMethod，而是子分派

被否決 PR 把混輸切換做成了 `Ctrl+Shift+M` 快捷鍵、`static var isInMixedMode` 旗標——這是一個「模式」（mode）的思路。但在現行架構下，`TypingMethod` 已不適合再擴充：

- 各 `TypingMethod` 案例之間是**互斥**的輸入模式（內碼輸入、漢音符號、羅馬數字）；混輸模式並非與注音輸入互斥，它是注音輸入的一個**行為變體**。
- 正確的對應物是：`prefs.cassetteEnabled` 這個旗標決定了在 `.vChewingFactory` 下使用哪個 Typewriter。混輸模式應該以相同的模式——**偏好設定旗標**——來決定在 `.vChewingFactory` + `!prefs.cassetteEnabled` 的情境下，使用 `BPMFFullMatchTypewriter` 還是 `MixedAlphanumericalTypewriter`。

因此，`handleComposition` 的分派邏輯應改為：

```swift
case .vChewingFactory where hardRequirementMet && !prefs.cassetteEnabled && prefs.mixedAlphanumericalEnabled:
  return MixedAlphanumericalTypewriter(self).handle(input)
case .vChewingFactory where hardRequirementMet && !prefs.cassetteEnabled:
  return BPMFFullMatchTypewriter(self).handle(input)
```

這樣完全不觸碰 `TypingMethod`，也不需要在 Session 層加任何狀態。

### 3.2 MixedAlphanumericalTypewriter 的設計

```swift
@frozen
public struct MixedAlphanumericalTypewriter<Handler: InputHandlerProtocol>: TypewriterProtocol {
  public let handler: Handler
  public init(_ handler: Handler) { self.handler = handler }
  public func handle(_ input: some InputSignalProtocol) -> Bool? { ... }
}
```

**緩衝區**：使用 `handler.mixedAlphanumericalBuffer: String`（需新增至 `InputHandlerProtocol`）。

**拼音保護門**：若 `handler.composer.isPinyinMode` 為 `true`，`handle` 直接返回 `nil`，讓 triage 流程繼續往下走（等同於退化到原有行為）。這是因為拼音模式的 `romajiBuffer` 已佔用所有 ASCII 字母鍵，無法在同一個 Tekkon composer 實例中區分「這幾個字母是在打拼音」與「這幾個字母是英文單字」。

```swift
guard !handler.composer.isPinyinMode else { return nil }
```

**按鍵分類**（僅處理 `hardRequirementMet == true` 的按鍵，即 `!input.text.isEmpty && input.charCode.isPrintableUniChar`）：

| 按鍵類型 | mixedAlphanumericalBuffer 為空 | mixedAlphanumericalBuffer 有內容 |
|---------|----------------------|----------------------|
| parser-aware ASCII 鍵（由 `composer.inputValidityCheck` 決定） | **雙軌並行**：若為合法注音鍵，同時餵給 `composer`（顯示注音）與 `buffer`（ASCII 後備）；若非法注音鍵，只進 `buffer` | 累積至 `buffer`，以 `trial composer` 判斷整體序列的注音可能性 |
| 聲調觸發鍵（layout 決定）| 依既有 BPMF 流程處理（回傳 `nil`） | **觸發辨識流程** |
| Space | 依既有 Space 流程處理（回傳 `nil`） | **由 MixedTypewriter 直接處理並回傳結果**（完整注音 → 組字；若辭典無匹配可走 `onLexiconMatchFailure` fallback；否則 → ASCII 提交） |

**關鍵修正說明**：Backspace、Enter、Escape **不滿足** `hardRequirementMet`（`charCode.isPrintableUniChar` 為 `false`），因此這些按鍵**不會**進入 `MixedAlphanumericalTypewriter`，而是直接由 `triageInput` 的 `triageByKeyCode()` 分派至 `handleBackSpace`、`handleEnter`、`handleEsc`。這三個函式必須在各自的開頭增加對 `mixedAlphanumericalBuffer` 的判斷（見 §3.5）。

**雙軌並行設計的核心思想**：
- `composer` 負責**注音顯示與組字**（與既有 BPMFFullMatchTypewriter 行為一致）
- `mixedAlphanumericalBuffer` 負責**保留原始 ASCII 序列**作為後備提交內容
- 當序列可明確解析為完整注音時，走中文組字路徑；否則回退為 ASCII 提交
- 這避免了 Codex 版 delayed evaluation 的單鍵注音 + Space 誤判為 ASCII 的問題

**「聲調觸發鍵」的抽象**：不同鍵盤排列的聲調鍵不同（大千的 `3/4/6/7`、倚天的 `6/3/4/7`、許氏的數字鍵等）。不應硬編碼。正確做法：嘗試讓 Tekkon composer 消化 `buffer + currentKey`，用 `composer.isPronounceable` 與 `composer.hasIntonation()` 的結果作為分支條件，而非直接比對 key code。

**關於「從 Tekkon 取得 ASCII Set」**：目前 Tekkon 已有 parser-aware 的 `inputValidityCheck(charStr:)`，可直接作為判斷真源；雖尚無現成 `Set<Character>` 公開屬性，但混輸層可用 `inputValidityCheck` 達到同等語義。若後續要減少逐鍵呼叫成本，可在 Tekkon 增設唯讀 API（例如 `allowedASCIIInputScalars`）並以當前 parser 懶載入快取。

> **注意**：`BPMFFullMatchTypewriter` 內部的 `consumeReadingInputIfNeeded` 為 `private` 方法，無法由 `MixedAlphanumericalTypewriter` 直接呼叫。`MixedAlphanumericalTypewriter` 需自行利用 `handler.composer.inputValidityCheck(charStr:)` 來判斷按鍵是否為合法注音鍵。

### 3.3 辨識流程虛擬碼

```
handle(input):
  guard !handler.composer.isPinyinMode else { return nil }
  var inputText = (input.inputTextIgnoringModifiers ?? input.text)
  inputText = inputText.lowercased().applyingTransformFW2HW(reverse: false)

  // 以 Tekkon parser 為單一真源判斷是否為注音鍵，避免硬編碼特定排列（如 ;,./-）。
  let isPhoneticKey = handler.composer.inputValidityCheck(charStr: inputText)
  // 混輸層額外接受一般 ASCII 可見字元，保留英文連續輸入能力。
  let isASCIIPrintable = inputText.range(of: "^[ -~]$", options: .regularExpression) != nil
  guard isPhoneticKey || isASCIIPrintable else {
    return nil
  }

  let isValidPhoneticKey = isPhoneticKey

  // ── Buffer 為空時：建立雙軌狀態 ──
  if handler.mixedAlphanumericalBuffer.isEmpty {
    if isValidPhoneticKey {
      // 合法注音鍵：同時餵給 composer（顯示注音）與 buffer（ASCII 後備）
      handler.composer.receiveKey(fromString: inputText)
      handler.mixedAlphanumericalBuffer = inputText
    } else {
      // 非注音鍵：只進 buffer，composer 保持為空
      handler.mixedAlphanumericalBuffer = inputText
    }
    handler.session?.switchState(handler.generateStateOfInputting())
    return true
  }

  // ── Buffer 有內容時：用 trial composer 判斷整體序列 ──
  let fullInput = handler.mixedAlphanumericalBuffer + inputText
  var trial = handler.composer
  trial.receiveSequence(fullInput, isRomaji: false)

  if trial.isPronounceable && trial.hasIntonation() {
    // 形成完整注音（含聲調）→ 清空 buffer，用 trial 取代 composer，走正常 BPMF 組字
    handler.mixedAlphanumericalBuffer.removeAll()
    handler.composer = trial
    return BPMFFullMatchTypewriter(handler).handle(input)
  }

  if input.isSpace {
    // Space 觸發最終判斷
    if !handler.composer.isEmpty {
      var typewriter = BPMFFullMatchTypewriter(handler)
      typewriter.onLexiconMatchFailure = { injectedHandler, _, injectedSession in
        // B49C0979（辭典無匹配）時，改為提交中文段 + ASCII buffer + 空白。
        let chineseText = injectedHandler.committableDisplayText(sansReading: true)
        let asciiText = injectedHandler.mixedAlphanumericalBuffer + " "
        injectedHandler.composer.clear()
        injectedHandler.mixedAlphanumericalBuffer.removeAll()
        injectedSession.switchState(State.ofCommitting(textToCommit: chineseText + asciiText))
        return true
      }
      let handled = typewriter.handle(input)
      if handled == true {
        handler.mixedAlphanumericalBuffer.removeAll()
      }
      return handled
    }
    // composer 為空（序列不是注音）→ 直接提交中文段 + ASCII + 空白
    let chineseText = handler.committableDisplayText(sansReading: true)
    let asciiText = handler.mixedAlphanumericalBuffer + " "
    handler.mixedAlphanumericalBuffer.removeAll()
    handler.session?.switchState(State.ofCommitting(textToCommit: chineseText + asciiText))
    return true
  }

  if trial.isPronounceable && !trial.hasIntonation() {
    // 可發音但無聲調 → 繼續累積
    // 同時讓實際 composer 跟進（保持注音顯示與 trial 一致）
    if isValidPhoneticKey {
      handler.composer.receiveKey(fromString: inputText)
    }
    handler.mixedAlphanumericalBuffer.append(inputText)
    handler.session?.switchState(handler.generateStateOfInputting())
    return true
  }

  // 不可發音 → 繼續累積 buffer，但清空 composer（不再顯示注音）
  if !handler.composer.isEmpty {
    handler.composer.clear()
  }
  handler.mixedAlphanumericalBuffer.append(inputText)
  handler.session?.switchState(handler.generateStateOfInputting())
  return true
```

> **關於 `handler.composer` 的值複製**：`Tekkon.Composer` 為 `struct`（`Codable, Hashable, Sendable`），`var trial = handler.composer` 即為獨立副本。`receiveSequence` 內部會先呼叫 `clear()`，因此 trial 從空狀態開始解析 `fullInput`。實際 `handler.composer` 則持續跟進合法注音鍵的輸入，以維持組字區的注音顯示。

> **關於 Space 處理的返回值（現況）**：在 `mixedAlphanumericalBuffer` 非空時，Space 已由 `MixedAlphanumericalTypewriter` 直接提交（回傳 `true`）或交由 `BPMFFullMatchTypewriter` 回傳其結果；不再依賴 `triageByKeyCode()` 的 `.kSpace` 後續分支來完成 ASCII 提交。

### 3.4 generateStateOfInputting 的顯示

組字區顯示需要在 `generateStateOfInputting` 中兼顧 `mixedAlphanumericalBuffer` 的內容。具體修改方案有兩種：

**方案 A（推薦）：修改 `readingForDisplay`**

`readingForDisplay` 是 `InputHandlerProtocol` 的 extension property，目前定義為：

```swift
var readingForDisplay: String {
  if !prefs.cassetteEnabled {
    return composer.getInlineCompositionForDisplay(
      isHanyuPinyin: prefs.showHanyuPinyinInCompositionBuffer
    )
  }
  // ... cassette path
}
```

修改為：

```swift
var readingForDisplay: String {
  if !prefs.cassetteEnabled {
    // 雙軌顯示：composer 有注音內容時優先顯示注音；composer 為空但 buffer 有內容時顯示 ASCII
    let composerDisplay = composer.getInlineCompositionForDisplay(
      isHanyuPinyin: prefs.showHanyuPinyinInCompositionBuffer
    )
    if !composerDisplay.isEmpty {
      return composerDisplay
    }
    if !mixedAlphanumericalBuffer.isEmpty {
      return mixedAlphanumericalBuffer
    }
    return ""
  }
  // ... 原有 cassette path
}
```

這樣 `generateStateOfInputting` 內現有的讀音插入邏輯會維持既有行為：
- 當序列是合法注音前綴時，顯示 `composer` 的注音（與現況一致）
- 當序列不是注音時，`composer` 被清空，改顯示 `mixedAlphanumericalBuffer` 的 ASCII 內容
- 無需改動 `generateStateOfInputting` 的主體結構

**方案 B（備選）：修改 `generateStateOfInputting` 主體**

在 `displayTextSegments` 組裝完成後、插入 `reading` 之前，先將 `mixedAlphanumericalBuffer` 作為一個獨立的 segment 插入到 `displayTextSegments` 的末尾。但這會與現有的 cursor/reading 插入邏輯產生衝突，不如方案 A 簡潔。

> **結論**：採用方案 A，僅修改 `readingForDisplay`，對 `generateStateOfInputting` 的侵入最小。

### 3.5 Backspace / Enter / Escape 等功能按鍵的處理

這些按鍵不滿足 `hardRequirementMet`（`charCode.isPrintableUniChar` 為 `false`），因此不會進入 `MixedAlphanumericalTypewriter`，而是由 `triageInput` 的 `triageByKeyCode()` 分派至 `handleBackSpace`、`handleEnter`、`handleEsc` 等。

本研究在這裡採取明確規格（不再留白）：

1. `handleBackSpace`：若 `mixedAlphanumericalBuffer` 非空，優先刪除 buffer 最後一字，並更新 inputting state。
2. `handleEnter`：採「**注音遞交優先**」規則：
  - 若 assembler/composer 有待遞交的注音組字內容，維持既有 Enter 流程（不得被 mixed buffer 攔截）。
  - 僅在 assembler/composer 皆無待遞交內容、且 `mixedAlphanumericalBuffer` 非空時，才走英文 fallback commit（提交 raw ASCII buffer）。
3. `handleEsc`：若 `mixedAlphanumericalBuffer` 非空，清空 buffer（必要時連同 composer）並回到空狀態。

此設計讓 Space 維持「中文優先」語義，同時不破壞 Enter 作為注音組字區主要遞交鍵的既有語義。

### 3.6 大小寫與全形/半形問題

`BPMFFullMatchTypewriter.handle()` 中對所有輸入執行：

```swift
inputText = inputText.lowercased().applyingTransformFW2HW(reverse: false)
```

`MixedAlphanumericalTypewriter` 目前採「混合策略」：一般字元仍 lowercased+FW2HW，但單個 A-Z 保留原樣。這意味著：

- 一般 ASCII 仍會累積為小寫半形
- 單個大寫英文字母（A-Z）可保留原樣（例如 `This` 可維持首字大寫）
- 這已降低「Shift 起手被誤判注音」的風險，但不等同完整大小寫語義（例如 Caps Lock / 複合修飾鍵交互仍需更細緻規格）

**現況結論**：大寫起手問題已從「已知限制」轉為「部分修復」，但大小寫策略尚非最終定案。

---

## 四、與拼音輸入的相容性分析

**結論：MixedAlphanumericalTypewriter 原理上與拼音輸入不相容。**

詳細原因：

1. 在 Zhuyin 模式（`!composer.isPinyinMode`）下，每個按鍵與注音符號有一對一的映射關係。`mixedAlphanumericalBuffer` 累積的字母在 Tekkon 中對應確定的注音符號，所以「嘗試用 trial composer 辨識」是有意義的。

2. 在 Pinyin 模式（`composer.isPinyinMode`）下，Tekkon 的 `romajiBuffer` 已累積相同的字母序列。字母 `h` 可以是 `h`（單獨聲母）也可以是 `zh`、`ch`、`sh` 的一部分，`n` 可以是聲母也可以是 `an`、`en` 的一部分。辨識邊界由聲調鍵或下一個聲母確定。這個解析語義與「積累英文單字」的語義完全重疊，無法分離。

3. 即使強行實作，在拼音模式下「`abc` 是英文 abc」還是「`abc` 是拼音 ā+bc」是歧義問題，需要使用者額外的輸入手勢來消歧——這與「不需手動切換」的設計目標矛盾。

**處理方式**：在 `MixedAlphanumericalTypewriter.handle()` 的入口加一道保護閘：

```swift
guard !handler.composer.isPinyinMode else { return nil }
```

返回 `nil` 意味著 `handleComposition` 會繼續往下到 `default: return nil`，最終讓 `triageInput` 走標準注音路徑，行為完全退化為無混輸的原有邏輯。

---

## 五、與磁帶模式（Cassette）的相容性

**結論：不允許同時啟用。**

磁帶模式下，`calligrapher` 已扮演「原始按鍵緩衝區」的角色。筆畫序列（如 `sdfgh`）在語義上等同於 rawBuffer，而「花牌鍵」（wildcard）等同於觸發鍵。兩套 buffer 機制同時存在會造成邏輯衝突。

此外，磁帶模式的辭典本身就包含英文直接輸入的支援（`%keyname` 欄位），不需要額外的混輸邏輯。

分派保護在 `handleComposition` 內以 `!prefs.cassetteEnabled` 保證互斥，無需在 `MixedAlphanumericalTypewriter` 內部重複判斷。

---

## 六、需要新增/修改的協定與型別清單

| 位置 | 變更類型 | 內容 |
|------|---------|------|
| `InputHandlerProtocol` | 新增屬性 | `var mixedAlphanumericalBuffer: String { get set }` |
| `InputHandlerProtocol` 實作（`InputHandler_CoreProtocol.swift`） | 初始化 | 所有實作 `InputHandlerProtocol` 的型別（如 `InputHandler`）需在初始化時設定 `mixedAlphanumericalBuffer = ""` |
| `InputHandlerProtocol` extension | 修改 | `clearComposerAndCalligrapher()` 需加入 `mixedAlphanumericalBuffer.removeAll()` |
| `InputHandlerProtocol` extension | 修改 | `isComposerOrCalligrapherEmpty` 需加入 `mixedAlphanumericalBuffer.isEmpty` 的判斷 |
| `PrefMgrProtocol` + `PrefMgr` | 新增偏好 | `var mixedAlphanumericalEnabled: Bool { get set }` |
| `UserDef` | 新增 case | `.kMixedAlphanumericalEnabled = "MixedAlphanumericalEnabled"`，DataType 為 `.bool(false)` |
| `InputHandler_HandleComposition.swift` | 修改分派 | 加入 `prefs.mixedAlphanumericalEnabled` 的分支（兩倉庫） |
| `Typewriter/` | 新增檔案 | `Typewriter_MixedAlphanumerical.swift`（`MixedAlphanumericalTypewriter` 實作，兩倉庫） |
| `InputHandler_HandleStates.swift` | 修改 | `generateStateOfInputting` 的顯示：透過修改 `readingForDisplay` 來呈現 `mixedAlphanumericalBuffer`（兩倉庫） |
| `InputHandler_HandleStates.swift` | 修改 | `handleBackSpace` 開頭增加 `mixedAlphanumericalBuffer` 判斷（兩倉庫） |
| `InputHandler_HandleStates.swift` | 修改 | `handleEnter` 採注音優先、ASCII fallback 次之的條件式分支（兩倉庫） |
| `InputHandler_HandleStates.swift` | 修改 | `handleEsc` 開頭增加 `mixedAlphanumericalBuffer` 清空邏輯（兩倉庫） |

### `isComposerOrCalligrapherEmpty` 的修改細節

目前定義（兩倉庫一致）：

```swift
var isComposerOrCalligrapherEmpty: Bool {
  if !strCodePointBuffer.isEmpty { return false }
  return prefs.cassetteEnabled ? calligrapher.isEmpty : composer.isEmpty
}
```

修改後：

```swift
var isComposerOrCalligrapherEmpty: Bool {
  if !strCodePointBuffer.isEmpty { return false }
  if !mixedAlphanumericalBuffer.isEmpty { return false }
  return prefs.cassetteEnabled ? calligrapher.isEmpty : composer.isEmpty
}
```

這會正確影響 `isConsideredEmptyForNow`：

```swift
public var isConsideredEmptyForNow: Bool {
  assembler.isEmpty && isComposerOrCalligrapherEmpty && currentTypingMethod == .vChewingFactory
}
```

從而讓 `generateStateOfInputting` 不會在 `mixedAlphanumericalBuffer` 有內容時錯誤回傳 `.ofAbortion()`。

### `readingForDisplay` 的修改細節

```swift
var readingForDisplay: String {
  if !prefs.cassetteEnabled {
    let composerDisplay = composer.getInlineCompositionForDisplay(
      isHanyuPinyin: prefs.showHanyuPinyinInCompositionBuffer
    )
    if !composerDisplay.isEmpty {
      return composerDisplay
    }
    if !mixedAlphanumericalBuffer.isEmpty {
      return mixedAlphanumericalBuffer
    }
    return ""
  }
  // ... 原有 cassette path
}
```

---

## 七、不需要觸碰的清單

以下都**不需要修改**：

- `SessionCtl.swift`、`InputSession*.swift` — 整個 Darwin Session 層維持不動
- `TypingMethod` enum — 不新增 case
- `IMEState` FSM — 不新增 state
- Tekkon、Homa、LexiconKit — 下層模組均無需動
- `triageInput` 的主體流程 — 無需改動，僅需擴充 `handleBackSpace` / `handleEnter` / `handleEsc`

---

## 八、跨倉庫同步考量

本功能實作完成後需同步至：

1. **`vChewing-macOS`**（`Packages/vChewing_Typewriter/`）：主要實作場地
2. **`vChewing-OSX-Legacy`**（`Shared/vChewingComponents/Typewriter/`）：鏡像同步

**已知語法差異**：

| 項目 | vChewing-macOS | vChewing-OSX-Legacy |
|------|----------------|---------------------|
| `TypewriterProtocol` associatedtype | `Handler` | `InputHandler` |
| `InputHandlerProtocol` 標註 | `@MainActor` | 無 |

這些差異不影響 `MixedAlphanumericalTypewriter` 的實作語法，因為泛型參數名稱無需與 associatedtype 名稱一致（`public struct MixedAlphanumericalTypewriter<Handler: InputHandlerProtocol>` 在兩倉庫均可編譯）。但 `@MainActor` 標註在 macOS 端會影響 `InputHandlerProtocol` 的實作型別的 actor isolation，需確保 `MixedAlphanumericalTypewriter` 的 `handle` 方法不需要額外的 actor 標註。

Linux 建置目標（`vChewing_Typewriter`）因為整個 `Typewriter` package 本身就是 Linux 可建置的，只要 `MixedAlphanumericalTypewriter` 本身不引入 Darwin 專屬 API，就能自動相容。

> 上述 AssociatedType 差異已在 vChewing-OSX-Legacy 的 `c436fe8a3e0c6bee186a7749add4b0d63ca5cd58` commit 內抹平、與 vChewing-macOS 一致。

---

## 九、風險與待決事項

1. **試驗 Composer 的 `receiveSequence` 行為**：`receiveSequence` 對非注音字元（如 `q`, `x`, `v` 等在大千排列下無效的字元）會直接忽略。因此 `trial.receiveSequence("qqq", isRomaji: false)` 後，`trial.isEmpty` 仍為 `true`。這是預期行為，表示該輸入無法形成注音，應累積為英文。

2. **聲調觸發鍵的判定邊界**：`trial.isPronounceable && trial.hasIntonation()` 的組合條件僅在輸入形成「完整注音（含聲調）」時成立。對於「可發音但無聲調」的狀態（如 `ㄅㄚ`），`trial.isPronounceable` 為 `true` 但 `trial.hasIntonation()` 為 `false`，此時應繼續累積 buffer。

3. **組字區溢位（commitOverflownComposition）**：當 `assembler.length > 20` 時，`commitOverflownComposition` 會自動提交前方節點。此機制與 `mixedAlphanumericalBuffer` 無直接互動，因為 buffer 中的文字尚未進入 assembler。需特別驗證 `handleEnter` 的「注音優先、ASCII fallback 次之」分支下，不會出現 buffer 誤遺失或誤提前提交。

4. **SCPC 模式（逐字選字）**：`handleTypewriterSCPCTasks()` 在 `BPMFFullMatchTypewriter` 完成組字後被呼叫。`MixedAlphanumericalTypewriter` 在完成「合法讀音辨識」後交回既有組字路徑時，也會觸發相同路徑，因此 SCPC 模式無需額外修改。

5. **POM 與漸退記憶**：`mixedAlphanumericalBuffer` 中的 ASCII 文字不會進入 `assembler`，因此不會產生 POM 觀測。這是預期行為，但對重度依賴 POM 的使用者可能造成困擾——POM 無法學習混輸模式下頻繁輸入的 ASCII 單字（如人名、專業術語）。

6. **雙軌方案與 delayed evaluation 的根本權衡**：Codex 版 delayed evaluation（首鍵必進 buffer）會破壞單鍵注音 + Space 的既有行為；現行雙軌並行方案保留了單鍵注音，但導致以注音鍵開頭的英文短單字無法輸入。兩種方案存在不可調和的矛盾，目前選擇了「優先中文」的雙軌方案，但這是一個明確的產品決策，需維護者確認。

7. **英文短單字的輸入封鎖（修訂）**：大千鍵盤下，`a`=`ㄘ`、`n`=`ㄣ`，故輸入 "an" + Space 會傾向走中文（如「恩」）。修訂提案改為：保留 Space 中文優先、保留 Enter 的注音遞交優先；僅在「沒有注音待遞交內容」時，Enter 才做 ASCII fallback。此規則避免破壞注音遞交語義，但也意味著部分短單字衝突 case 仍需額外手勢（例如未來增設 dedicated force-ASCII commit 鍵）來完整解決。

8. **Trial composer 的覆蓋行為導致顯示跳變**：`receiveKey(fromPhonabet:)` 對同類型注音符號採取覆蓋策略。範例：輸入 "ab"，trial 先解析 `a`=`ㄘ`，再接收 `b`=`ㄅ` 後覆蓋為 `ㄅ`；組字區顯示會從 `ㄘ` 跳變為 `ㄅ`。同理 "abc" 最終 trial = `ㄘ`（`c`=`ㄒ` 覆蓋 `ㄅ`），顯示持續跳變。這可能讓使用者感到困惑。

9. **顯示從注音跳變為 ASCII 的 UX 問題**：當序列從「可發音」變為「不可發音」時（如先輸入 `su` 使 composer=`ㄋㄧ`，再輸入 `q`），虛擬碼會清空 composer，導致組字區顯示從 `ㄋㄧ` 突然變為 "suq"。這種跳變可能讓使用者以為輸入法出了問題。

10. **`isComposerOrCalligrapherEmpty` 擴充的連帶影響**：此屬性被 `handleBackSpace`、`handleDelete`、`handleForward`、`handleBackward`、`handleHome`、`handleEnd`、`handleClockKey`、`callCandidateState`、`isConsideredEmptyForNow` 等大量函式依賴。當 `mixedAlphanumericalBuffer` 有內容時，所有依賴此屬性的操作都會被阻止（觸發 errorCallback）。例如：buffer 有內容時無法使用方向鍵移動游標、無法呼叫選字窗、無法使用 Home/End。這可能嚴重影響混輸模式下的使用者體驗，需逐個檢視這些函式的行為是否符合預期。

11. **功能鍵策略需測試鎖定**：雖然 §3.5 已明確定義 `Backspace / Enter / Esc` 行為，但仍需以回歸測試鎖住 Enter 的優先序（注音遞交優先、ASCII fallback 次之），避免後續重構重新引入語義衝突。

12. **Space 提交順序與游標位置**：`committableDisplayText(sansReading: true) + asciiText` 假設 cursor 位於組字區末尾。若 cursor 在中間位置，此順序不正確；但由於混輸 buffer 作為 reading 顯示於 cursor 處，正常情況下 cursor 應在末尾。需驗證：使用者在 buffer 有內容時移動游標後按 Space，提交順序是否仍正確。

13. **Shift + 大寫字母在混輸過程中的行為（已部分修復）**：目前單個 A-Z 會保留原樣並可寫入 mixed buffer（例如 `This`），不再是「必然全小寫」。但大小寫語義仍混合（一般字元仍 lowercased），需後續再確認產品規格是否要全面保留大小寫。

14. **數字鍵與 `handleNumPadKeyInput` 的交互**：`handleNumPadKeyInput` 在 `handleComposition` 之後執行。混輸模式下使用者按數字鍵，應累積進 buffer 還是走 NumPad 處理路徑？目前設計未明確規範。

15. **與 `commitOverflownComposition` 的潛在狀態不一致**：當 `assembler.length > 20` 時，前方節點會被自動提交。`mixedAlphanumericalBuffer` 不會進入 assembler，因此不會被自動提交。若 assembler 溢位發生於 buffer 有內容時，buffer 內容會留在原地，可能導致「已提交部分組字 + 未提交 buffer」的不直觀狀態。

16. **跨倉庫 associatedtype 差異的實際編譯風險** (已消除)：macOS 的 `TypewriterProtocol` associatedtype 名為 `Handler`，Legacy 為 `InputHandler`。雖然泛型參數名無需一致，但若存在 `some TypewriterProtocol` 的上下文型別推斷或明確 associatedtype 約束，仍可能存在編譯差異。需實際在兩倉庫編譯驗證。

17. **虛擬碼中多餘的按鍵檢查**：§3.3 虛擬碼中 `!input.isSpace`、`!input.isEnter` 等檢查在 `MixedAlphanumericalTypewriter` 內部是多餘的——這些按鍵本就不滿足 `hardRequirementMet`，不會進入此 Typewriter。保留無害，但增加冗餘；可在實作時簡化。

---

## 十、研究摘要

| 項目 | 結論 |
|------|------|
| 被否決方案的核心問題 | Session 層耦合，無法跨平台；且是在 Homa 手術前的設計 |
| 正確的下放層級 | Typewriter 層（`TypewriterProtocol`），不是 Session 層，也不是 TypingMethod |
| 實作型別 | 新增 `MixedAlphanumericalTypewriter<Handler>` struct，平行於 `BPMFFullMatchTypewriter` |
| 切換機制 | `PrefMgrProtocol` 偏好旗標 `mixedAlphanumericalEnabled`，不需要快捷鍵切換、不需要修改 FSM |
| 拼音相容性 | 不相容；以 `composer.isPinyinMode` 保護門讓功能退化到原有行為 |
| 磁帶模式相容性 | 不允許同時啟用；由 `handleComposition` 分派邏輯的 `!prefs.cassetteEnabled` 條件保證互斥 |
| Backspace/Enter/Escape 處理 | **不經過** `MixedAlphanumericalTypewriter`（因 `hardRequirementMet` 限制），需在 `handleBackSpace` / `handleEnter` / `handleEsc` 中增加對 `mixedAlphanumericalBuffer` 的判斷；其中 Enter 為注音優先、ASCII fallback 次之 |
| Space 處理 | buffer 為空時走既有 Space 路徑；buffer 非空時由 `MixedAlphanumericalTypewriter` 直接處理（含 `onLexiconMatchFailure` 的 B49 fallback），不再依賴 `triageByKeyCode()` 的續處理 |
| 顯示方案 | 修改 `readingForDisplay`：`composer` 有注音時優先顯示注音；否則回退顯示 `mixedAlphanumericalBuffer` |
| 協定擴充 | `InputHandlerProtocol` 新增 `mixedAlphanumericalBuffer: String`；`PrefMgrProtocol` 新增 `mixedAlphanumericalEnabled: Bool`；`isComposerOrCalligrapherEmpty` 擴充；`clearComposerAndCalligrapher` 擴充 |
| Darwin 層變更 | 零（Session/SessionCtl 無需動） |

---

## 十一、實作前驗收清單（Phase 53 Surgery Readiness Checklist）

### 11.1 命名與範圍

- [ ] 所有新 API、屬性與檔名均採用 `MixedAlphanumerical` / `mixedAlphanumerical*` 命名。
- [ ] 本次手術範圍僅限 `vChewing-macOS` 與 `vChewing-OSX-Legacy`，不改動 `vChewing-LibVanguard` 與 `vChewing-VanguardLexicon` 的產品程式碼。

### 11.2 功能開關（UserDef ~ Settings）

- [ ] `UserDef` 新增 `.kMixedAlphanumericalEnabled = "MixedAlphanumericalEnabled"`。
- [ ] 對應 `DataType` 設為 `.bool(false)`（預設關閉）。
- [ ] `PrefMgrProtocol`、`PrefMgr` 同步新增 `mixedAlphanumericalEnabled: Bool`。
- [ ] Settings UI（或對應偏好介面）能正確顯示並切換該選項。

### 11.3 Typewriter 分派與互斥條件

- [ ] `handleComposition(input:)` 在 `.vChewingFactory && !prefs.cassetteEnabled && prefs.mixedAlphanumericalEnabled` 時分派至 `MixedAlphanumericalTypewriter`。
- [ ] `prefs.cassetteEnabled == true` 時，仍只走 `CassetteTypewriter`，不得啟用混輸分支。
- [ ] `MixedAlphanumericalTypewriter` 入口含 `guard !handler.composer.isPinyinMode else { return nil }`。

### 11.4 Buffer 生命週期

- [ ] `InputHandlerProtocol` 新增 `mixedAlphanumericalBuffer: String` 並完成初始化。
- [ ] `clearComposerAndCalligrapher()` 會一併清空 `mixedAlphanumericalBuffer`。
- [ ] `isComposerOrCalligrapherEmpty` 已納入 `mixedAlphanumericalBuffer.isEmpty` 判斷。
- [ ] parser-aware 可接受鍵（由 `composer.inputValidityCheck` 決定）首鍵可正確進入 `mixedAlphanumericalBuffer`（避免首鍵被誤轉委）。

### 11.5 功能鍵與提交流程

- [ ] `handleBackSpace` 對 `mixedAlphanumericalBuffer` 有優先刪除分支。
- [ ] `handleEnter` 已實作注音遞交優先；僅在無注音待遞交內容且 `mixedAlphanumericalBuffer` 非空時才走 ASCII fallback。
- [ ] `handleEsc` 可正確清空 `mixedAlphanumericalBuffer`。
- [ ] Space 觸發辨識失敗時，確認是否由 `onLexiconMatchFailure` 接手 fallback，且行為符合「中文段 + ASCII + 空白」提交策略。

### 11.6 顯示一致性

- [ ] `readingForDisplay` 在 `composer` 有注音內容時優先顯示注音；`composer` 為空且 `mixedAlphanumericalBuffer` 非空時回傳該 buffer。
- [ ] `generateStateOfInputting()` 不因 mixed buffer 存在而錯誤回傳 `.ofAbortion()`。
- [ ] 游標、候選窗呼叫、SCPCTypingMode 在 mixed buffer 狀態下無明顯回歸。

### 11.7 跨倉庫同步

- [ ] `vChewing-macOS` 與 `vChewing-OSX-Legacy` 的 Typewriter 相關變更完整鏡像。
- [ ] 已確認兩倉庫的 `TypewriterProtocol` associatedtype 差異不影響 `MixedAlphanumericalTypewriter` 宣告。

### 11.8 最低驗證矩陣（手術後）

- [ ] Case A：`mixedAlphanumericalEnabled = false` 時，行為與現況一致。
- [ ] Case B：`mixedAlphanumericalEnabled = true` + `cassetteEnabled = false`，混輸可用。
- [ ] Case C：`mixedAlphanumericalEnabled = true` + `cassetteEnabled = true`，混輸不啟用。
- [ ] Case D：拼音模式下，mixed 邏輯自動退化，不破壞原有拼音輸入。
- [ ] Case E：Space/Backspace/Enter/Esc 在 mixed buffer 有內容時行為符合預期。

---

## 十二、Phase 53 實作順序建議（拆分為可提交單位）

> 目標：每一步都可單獨編譯、可單獨回滾，避免一次大改造成除錯困難。

### Step 1 — 偏好鍵與設定介面骨架

**變更檔案（兩倉庫對應位置）**
- `UserDef` 定義檔：新增 case `.kMixedAlphanumericalEnabled` (Bool, default: false)。
- `PrefMgrProtocol` / `PrefMgr` 定義與實作檔
- Settings 對應 UI 檔，放在「DevZone（開發道場）」頁面。

**內容**
- 新增 `kMixedAlphanumericalEnabled`（預設 `false`）。
- 新增 `mixedAlphanumericalEnabled: Bool` 存取面。
- 將設定項目掛到既有設定頁。

**完成條件**
- 不啟用功能時，所有輸入行為與現況完全一致。

### Step 2 — InputHandler 加入 mixed buffer 基礎能力

**變更檔案**
- `InputHandler_CoreProtocol.swift`（或同職責檔案）

**內容**
- 在 `InputHandlerProtocol` 新增 `mixedAlphanumericalBuffer` 屬性。
- 實作型別初始化該屬性。
- `clearComposerAndCalligrapher()` 納入 buffer 清空。
- `isComposerOrCalligrapherEmpty` 納入 buffer 判斷。

**完成條件**
- 專案可編譯。
- 尚未接線 Typewriter，不改變使用者可見行為。

### Step 3 — 新增 `MixedAlphanumericalTypewriter` 空殼

**變更檔案**
- `Typewriter/Typewriter_MixedAlphanumerical.swift`（兩倉庫）

**內容**
- 新增型別與 `handle(_:)` 空殼。
- 先放最小邏輯：一律 `return nil`。

**完成條件**
- 專案可編譯。
- 功能尚未生效（安全落地）。

### Step 4 — 接上分派邏輯（但先不攔截）

**變更檔案**
- `InputHandler_HandleComposition.swift`

**內容**
- 於 `.vChewingFactory && !prefs.cassetteEnabled && prefs.mixedAlphanumericalEnabled` 分派到 `MixedAlphanumericalTypewriter`。
- 由於 Step 3 仍 `return nil`，行為仍退化至既有流程。

**完成條件**
- 開關開/關都可正常輸入，無回歸。

### Step 5 — 實作混輸主流程（parser-aware 攔截 + 拼音保護門）

**變更檔案**
- `Typewriter_MixedAlphanumerical.swift`

**內容**
- `guard !handler.composer.isPinyinMode else { return nil }`。
- 以 `composer.inputValidityCheck(charStr:)` 作為注音鍵判斷真源，避免任何排列特化硬編碼。
- 混輸層另外接受 ASCII 可見字元，保持英文輸入連續性。
- 建立雙軌：`composer`（注音顯示）+ `mixedAlphanumericalBuffer`（ASCII 後備）。
- 處理 Space 觸發的最終分流（注音組字或 ASCII 提交）。

**完成條件**
- `mixedAlphanumericalEnabled=true` 時可進入混輸主流程。

### Step 6 — 顯示邏輯對齊

**變更檔案**
- `InputHandler_HandleStates.swift`（`readingForDisplay` 相關）

**內容**
- `composer` 有內容時優先顯示注音。
- `composer` 空且 `mixedAlphanumericalBuffer` 非空時顯示 buffer。

**完成條件**
- 組字區顯示不跳錯狀態，`generateStateOfInputting()` 正常。

### Step 7 — 功能鍵補強（Backspace / Enter / Esc）

**變更檔案**
- `InputHandler_HandleStates.swift`

**內容**
- `handleBackSpace` 先處理 mixed buffer 刪字。
- `handleEnter` 採注音遞交優先；僅在無注音待遞交內容時才走英文 fallback。
- `handleEsc` 清空 mixed buffer。

**完成條件**
- mixed buffer 存在時，三個功能鍵行為符合 §11.5。

### Step 8 — 鏡像同步與驗證收斂

**變更檔案**
- `vChewing-OSX-Legacy` 對應 Typewriter / InputHandler / Pref 檔案

**內容**
- 將 Step 1~7 同步至 Legacy。
- 跑最低驗證矩陣（§11.8 Case A~E）。
- 更新 DevPlans/Reqs4LLM 的 Phase 53 實作紀錄（依 Response Pattern）。

**完成條件**
- 兩倉庫行為一致，且能在預設關閉時維持零回歸。

---

## 十三、需求研究：英文後接中文（`hello你好`）不靠 Enter 切斷

### 13.1 實測觀察（ASUS 輸入法錄影）

- 參考錄影：`vChewing-macOS/tmp/AsusInputExample_HelloNihao.mov`。
- 觀察到的鍵入軌跡（由畫面逐步判讀）：`H` → `He` → `Hel` → `Hello` → `Hellos` → `Hellosu` → `Hello你...` → `Hello你好`。
- 核心現象：
  1. 英文前綴 `Hello` 不需先按 Enter，即可在後續注音鍵序進入時被保留。
  2. 後綴注音在形成可提交中文後，系統可將結果組為「英文前綴 + 中文後綴」（`Hello你好`）。
  3. 這更接近「前綴 ASCII 保留 + 後綴注音辨識」的單次切分模型，而非每個字元任意來回切換的無限輪切模型。

### 13.2 對現行設計的意義

- 這份實測支持「前綴保留 + 後綴注音辨識」方向的可行性，但真正落地時不能只寫成抽象的 suffix-first；排序規則必須能避開短後綴搶先命中的問題。
- 產品規格可先鎖定為：
  1. 單次切分（ASCII prefix + Zhuyin suffix）優先。
  2. 不承諾無限輪切與任意多段自動分割。
  3. 遇到歧義時仍以明確手勢（Enter/Space/專用 commit）兜底。

### 13.3 Phase 53B 落地後的排序修正結論

- 實作過程確認，若只做「由右向左找第一個可成字後綴」的寬鬆 suffix-first，會在真實詞庫歧義下過早命中較短後綴。
- 具體案例：`Hellosu3cl3` 曾因 `u3 -> ㄧˇ -> 以` 比 `su3 -> ㄋㄧˇ -> 你` 更早被接受，而暫時走成 `Hellos以好`。
- 因此目前實作已改為：
  1. 只在單一注音音節的合理鍵長內搜尋後綴（現階段上限 4 鍵，對應聲、介、韻、調）。
  2. 在該範圍內優先採用較長後綴，讓 `su3` 優先於 `u3`。
  3. auto-split 只負責決定「第一個」中文音節切點；後續音節仍交回既有 zhuyin composition 路徑累積。
- 這個策略較符合 ASUS 錄影觀察到的 blue underline 組字區行為：先保留完整英文前綴，再在後綴足夠明確時啟動第一個中文音節，而不是被最短可成字後綴搶先切斷。

- **現況成因**：mixed 流程目前以「整段 `fullInput = buffer + currentKey`」做單次判斷；當 buffer 前綴已累積英文時，後續注音鍵會與整段一起判斷，缺少「自動切斷邊界」機制，導致英文後接中文難以成立。
- **可行性判斷**：可行，但比「中文後接英文」明顯更複雜，因為需要在每拍輸入時動態尋找最佳切分點（英文前綴 / 注音後綴），本質接近增量分詞。
- **建議方向（雙向匹配）**：
  1. 以「單音節鍵長受限 + 長後綴優先」方式掃描：先在單音節合理鍵長內，由長到短尋找可發音且可查詞的後綴。
  2. 命中後將前綴視為 ASCII 直接提交，後綴作為第一個中文音節注入既有 zhuyin composition 流程。
  3. 若未命中則維持既有累積（不強切）。
- **成本與風險**：每鍵需要額外 trial + lexicon 檢索，若不做快取可能有明顯效能成本；且要處理游標、SCPCTasks、commitOverflownComposition 的一致性。
- **結論**：雙向自動切斷是可做的，但 Phase 53B 的實作經驗已證明，不能只寫成抽象的「suffix 最長匹配」。更精確的結論應是：先以「單音節鍵長受限 + 長後綴優先 + 僅決定第一個中文音節切點」落地；後續若要擴充成多候選或多段切分，再另行設計快取與切分評分策略。

### 13.4 Phase 53B 額外修補：純注音 Space 確認的尾巴殘留

- 新增回歸案例（IH115J）：`xm3z; `（預期為 `呂方`）。
- 觀察到的故障：在 mixed mode 下，Space 經注音確認後 displayText 曾出現 `呂方z;`。
- 根因：`BPMFFullMatchTypewriter` 的 Space 委派成功時，若 `mixedAlphanumericalBuffer` 尚未清空，`generateStateOfInputting()` 會把殘留 buffer 重新拼進顯示字串。
- 修補策略：
  1. 委派 `BPMFFullMatchTypewriter.handle(Space)` 前先暫存並清空 `mixedAlphanumericalBuffer`。
  2. 若委派成功，維持清空狀態；若委派未處理，再回填原 buffer。
  3. `onLexiconMatchFailure` fallback 改讀暫存副本，避免依賴已清空的 live buffer。
- 修補後行為：`xm3z; ` 經 Space 確認後 displayText 正確為 `呂方`，不再殘留 `z;`。

---

## 十四、需求研究：標點輸入體系（含 Shift 與非 Shift）近乎癱瘓

### 14.1 問題定義與症狀輪廓

- 使用者回報：以 Shift 為修飾鍵的標點輸入（例如 `!@#$%^&*()_+{}|:\"<>?`）在 mixed mode 下大量失效、誤判、或被吞鍵。
- 補充回報：即使不按 Shift，部分標點也受影響；例如 US Keyboard + 大千排列下的 `=` 與 `\`。
- 這不是單一按鍵 mapping 問題，而是「混輸層字元正規化策略」與「注音判斷策略」交疊後的系統性偏移。
- 從體感上會呈現為：
  1. Shift+標點送入後，組字區顯示與預期符號不一致。
  2. 某些鍵被當成注音流程的一部分，導致符號輸入中斷。
  3. 在已有 mixed buffer 時，Shift+標點可能意外觸發 auto-split 或 composer 更新。

### 14.2 現行流程的高機率根因（對照程式現況）

- mixed typewriter 目前採「大寫 A-Z 保留，其餘多數走 `inputTextIgnoringModifiers ?? input.text` 再 lowercased + FW2HW」的策略。
- 這個策略對英文字母有利，但對 Shift+標點有副作用：
  1. `inputTextIgnoringModifiers` 會把 Shift 後符號還原為基底鍵（例如 `! -> 1`、`@ -> 2`、`_ -> -`）。
  2. 還原後的字元可能落入 parser-aware 判斷或後續 trial composer 判斷，造成「本來要輸入符號，卻被當作注音/分割候選」。
  3. mixed 路徑又允許 ASCII 可見字元，導致誤判後仍會被緩衝、顯示、或參與後續切分，形成連鎖錯誤。
- 非 Shift 標點（如 `=`、`\`）的額外風險：
  1. 在大千等 parser 下，部分標點鍵本身就是 parser-aware key。
  2. 一旦進入 `isPhoneticKey` / `isFullyParserCovered` 路徑，就可能被當成注音序列的一部分，而非 ASCII 標點。
  3. 因此故障並非僅由 Shift 觸發，而是「標點鍵被過度傾向注音語義」的普遍問題。
- 結論：目前故障核心可拆成兩層：
  1. Shift 路徑的語義抹平（modifier 還原過早）。
  2. 非 Shift 路徑的語義偏置（parser-aware 標點被優先解讀為注音）。

### 14.3 解法提案（建議採最小侵入、可快速回歸）

#### 方案 A（建議優先）：改為「語義保留型」輸入字元正規化

- 核心原則：先保留使用者真正輸入出的可見字元語義，再決定是否進注音判斷。
- 具體規則：
  1. 若輸入字元為單個 A-Z：保留原字元（延續既有大寫修補）。
  2. 若 `input.isShiftHold == true` 且字元為非字母可見字元：優先採 `input.text`（不可用 ignoringModifiers 回退）。
  3. 僅在「非 Shift 特例」時才採 `inputTextIgnoringModifiers ?? input.text`。
  4. lowercased 僅作用於字母路徑；符號路徑不做 lowercased。
- 效果：Shift+標點會以實際符號進入 mixed buffer，不再被還原成數字或基底鍵。

#### 方案 B（搭配 A）：Shift+符號走 ASCII 直通，不參與注音覆蓋判斷

- 當偵測到「Shift 修飾 + 非字母可見字元」時：
  1. 略過 `isPhoneticKey` / `isFullyParserCovered` / `tryAutoSplitASCIIAndPhoneticSuffix`。
  2. 直接把符號視為 ASCII 字元累積（或在特定 commit 條件下直接提交）。
- 目的：避免符號鍵被錯誤捲入「注音可發音性」推導，降低副作用面積。

#### 方案 B2（補強非 Shift）：parser-aware 標點採「上下文門檻」再進注音

- 針對 `=`、`\\` 這類「同時可能是標點也可能是注音鍵」的按鍵，加入上下文門檻：
  1. 若當前輸入上下文已明確是 ASCII 片段（例如前序已存在非注音語義或使用者正在輸入英文/符號串），優先走 ASCII。
  2. 僅在「注音上下文明確成立」時（例如 composer 已有有效注音骨架，或使用者已在注音組字流）才允許該鍵作為注音延伸。
  3. 不把「鍵位可被 parser 接受」當成唯一進注音條件，避免標點鍵被無條件吸入注音路徑。
- 目的：修正非 Shift 標點在 mixed 模式下被 parser-aware 覆蓋語義的問題。

#### 方案 C（可延後）：抽出單一 helper 以封裝輸入正規化策略

- 建議新增（或等效抽象）函式，集中定義 mixed 路徑字元來源決策：
  - 輸入：`input`。
  - 輸出：`normalizedText` + `kind`（字母 / Shift 符號 / 一般 ASCII / 其他）。
- 好處：
  1. 降低日後再次引入「大寫修補 vs Shift 符號修補」互踩的機率。
  2. 測試可針對 helper 做 table-driven 驗證。

### 14.4 建議的回歸測試矩陣（IH116 系列：MixedAlphanumerical 標點處理）

- IH116A：mixed mode 下，純符號序列（`!@#$`）可正確進入顯示與提交，不被注音化。
- IH116B：英文 + Shift 符號 + 英文（例如 `Hello!World `）提交結果保持原字面。
- IH116C：中文組字後接 Shift 符號（例如 `su3cl3` 組字後再輸入 `!`）不污染 composer 狀態。
- IH116D：Shift+數字符號與未 Shift 數字分流正確（`1` 與 `!` 不可互相覆蓋語義）。
- IH116E：`=` 存在於 ASCII 前綴時，auto-split 與標點提交順序行為可預測。
- IH116F：USKeyboard + 大千下，`=` 在 mixed mode 具可預測標點語義。
- IH116G：USKeyboard + 大千下，`\\` 在 mixed mode 具可預測標點語義。
- IH116H：`abc=def `、`abc\\def ` 類片段在 mixed mode 下提交結果可預測。
- IH116I：modifier-aware（例如 Option）標點按鍵，能透過動態 query key 命中詞庫並走 CJK 標點分流。
- IH116J：一般（無修飾鍵）標點按鍵，能透過動態 query key 命中詞庫並走 CJK 標點分流。

### 14.5 風險與取捨

- 風險 1：若完全放寬 Shift 鍵，可能影響既有某些「Shift 作為功能修飾」的歷史快捷路徑。
- 風險 2：不同鍵盤 layout 對某些符號輸出的 key-level 表示不同，測試需使用「輸出字元語義」而非 keyCode 假設。
- 風險 3：若只做方案 A 不做方案 B，仍可能有少數符號序列被 `isFullyParserCovered` 偶發捲入。
- 建議取捨：先落地 A+B，確保 NIGHTLY 可快速止血；C 可在穩定後再抽象重構。

### 14.6 章節結論

- 「標點體系癱瘓」本質上是兩個問題疊加：
  1. Shift 路徑在正規化時過度偏向 ignoringModifiers，造成語義失真。
  2. 非 Shift parser-aware 標點（如 `=`、`\\`）被過度優先解讀成注音鍵。
- 最實用的修補路徑是：
  1. 保留 Shift 後實際符號字元語義。
  2. 對 parser-aware 標點加入上下文門檻，避免無條件注音化。
  3. 將 Shift+非字母符號從注音判斷鏈路中隔離。
  4. 以 IH116A~IH116J 回歸測試鎖住行為（專職 MixedAlphanumerical 標點處理）。
- 這組策略與既有 Phase 53A/52B 的方向一致：維持「中文優先」與「可預測 fallback」，但避免把符號鍵誤導入注音路徑。

### 14.7 現況補遺（Phase 53C Implementation Sync）

- `MixedAlphanumericalTypewriter` 已新增「KBEvent 動態標點判定前置層」：
  1. 先依當前 `KBEvent`（含修飾鍵）產生 `punctuationQueryStrings(input:)`。
  2. 若命中詞庫，視為 CJK 標點行為，優先回到既有標點管線。
  3. 若當前有 mixed buffer，先 flush（中文段 + ASCII buffer），再交由標點流程處理當前按鍵。
- 這個行為已同步到 macOS 與 Legacy 的 mixed typewriter。
- 測試命名已整理：標點混輸案例統一使用 IH116A~IH116J。

### 14.8 後續修補補遺（Phase 53D Follow-up Fixes）

- IH115K / IH115L：mixed auto-split 現已改為「先按 reading key 去重、同 key 保留最短 raw suffix，再從去重結果中取最長 suffix」。
  1. 這可避免 `Hellod93`、`Thisd93` 這類輸入被 `od93` / `sd93` 之類的較長 raw suffix 回吃尾字。
  2. auto-split 命中後，若組字區前段已有既成中文，會先 commit 該中文段並自 assembler front 端移除對應 keys，再 commit ASCII 前綴；不再出現 `Hell` 先送出、`留意` 殘留在組字區的錯序。
  3. 相關回歸測試：IH115K、IH115L。
- IH116K：MixedAlphanumerical mode 的 CJK 標點前置層現已改為「合法注音鍵優先」。
  1. 若當前 key 在現行 parser 下本身就是合法注音鍵，則不得被 IH116 新增的動態 CJK 標點支援攔走。
  2. 這修正了 `;`（大千下可作 `ㄤ` 組音鍵）被誤判成標點、導致所有含 `ㄤ` 的讀音無法輸入的 regression。
  3. 既有 IH116I / IH116J 的動態標點 lexicon 命中行為保持成立；新回歸測試為 IH116K。

### 14.9 後續修補補遺（Phase 53E Token-level English Follow-up）

- IH117A / IH117B：MixedAlphanumerical mode 現已對「全由 ASCII 字母構成、且仍屬 parser-covered」的 token 做 Tekkon replay digestion 檢查。
  1. 若 replay 過程中至少兩次出現「按鍵被消化，但 syllable 槽位沒有前進」的情形，則視為 English-like token，跳過 zhuyin-first 路徑並回退 ASCII。
  2. 這修正了 `the`、`hell` 這類最終仍可被看成可發音注音、但實際只是靠 repeated overwrite / non-advancing consumption 殘留成形的 regression。
  3. 這個 heuristic 只落在 `MixedAlphanumericalTypewriter` 內部，不侵入 Tekkon；既有 auto-split 路徑仍保留，因此不影響 `Hellod93` / `Thisd93` 這類「ASCII 前綴 + 注音後綴」場景。
  4. macOS 與 Legacy 已同步；新回歸測試為 IH117A、IH117B。

### 14.10 後續修補補遺（Phase 53F Shift Symbol Follow-up）

- IH117C：修正 mixed mode 下 `Shift+/` 在「事件只攜帶 base glyph `/`」時會退化成 `/` 的問題。
  1. `MixedAlphanumericalTypewriter` 新增 keyCode 映射回填：當事件同時滿足 `isShiftHold == true` 且 `text == inputTextIgnoringModifiers`（代表 shifted glyph 遺失），使用 `LatinKeyboardMappings.mapTable` + `keyCode` 還原可見字元語義。
  2. 這使 `What?` 類型輸入不再被降級成 `What/`。
- IH117C 連帶修補：原先 ASCII 標點 regex 在此案例對 `?` 判定失敗，已改為 scalar-based 判定（ASCII + `CharacterSet.punctuationCharacters`/`CharacterSet.symbols`），避免 regex 差異造成誤分流。
- IH116 非回歸防護：force ASCII 標點條件細化為「Shift 永遠強制；非 Shift 僅在 base key 不是合法注音鍵時才強制」，避免重演 `;`（大千 `ㄤ`）被誤攔截成標點的回歸。
- IH117D / IH117E：新增 `[` / `]` 動態 CJK 標點命中回歸測試，確認 mixed mode 下仍可命中 `「` / `」` 類型 lexicon key。
- macOS 與 Legacy 已同步；本回合回歸測試新增 IH117C、IH117D、IH117E。
