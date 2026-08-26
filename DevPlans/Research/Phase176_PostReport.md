# Phase 176 術後調查報告：Sessions 體系遷移至 Typewriter（OS-Independent Session）

> 調查日期：2026-09-02。範圍：vChewing-macOS / vChewing-OSX-Legacy / vChewing-LibVanguard 三倉。
> 背景：Phase 176 依需求「Sessions 體系或可遷移至 Typewriter package 內，這樣在 Linux / Windows 系統下便可實作那些有 Session 參與的開發」，
> 將 `InputSession`＋`SessionProtocol`＋IMEState factories＋`IMEStateParsed`＋具體 `InputHandler` 等自 `MainAssembly4Darwin` 遷入 `vChewing_Typewriter`，
> 所有 OS-dependent 動作改走 `SessionHost` 閉包注入（沿用 P175 `SettingsUIHost` 前例）。
> 本文為術後沉澱記錄：補足 Reqs 檔未寫的決策脈絡、跨平台陷阱與今後同步注意事項，供 Linux／WinNT 分支開發環境的後續 agent 參考。

---

## 一、結論速覽

| 項目 | 結果 |
|---|---|
| Session 體系遷移 | 11 檔遷入 Typewriter（Session 10 檔＋`InputHandler.swift`） |
| OS-dependent 解耦 | `SessionHost.shared` 單例，30+ 閉包屬性注入，未注入＝無操作預設 |
| Darwin 表面留守 | `InputSession_DarwinSurface.swift`＋`SessionHostWiring.swift`（MainAssembly4Darwin） |
| Linux／WinNT 可編譯 | ✅（CI 實證；含一次 `NSAttributedString` Darwin-ism 修復） |
| 兩倉鏡像一致 | portable 檔逐字節相同（僅 `@MainActor`／`nonisolated deinit` 方言差） |
| commit | macOS `539ee616`、Legacy `36b7fdb0`（LibVanguard 文件隨 HEAD aggregate） |

---

## 二、遷移決策脈絡（Reqs 檔未寫的部分）

### 2.1 為什麼遷的是「整個 Session 體系」而非只遷 protocol

遷移前 Typewriter 已有 `SessionCoreProtocol`（會話基底協定＋`switchState()`／`resetInputHandler()` 預設實作）與 `InputHandlerProtocol`＋FSM 全邏輯。
但真正「有 Session 參與的開發」所需的 `InputSession` 具體類別、`SessionProtocol`、IMEState factories、`IMEStateParsed`、具體 `InputHandler`
全留在 `MainAssembly4Darwin`——Linux 上只能測 FSM 的局部、無法建構完整 session 行為。

遷移範圍取捨：**一併遷走 IMEState factories 與 IMEStateParsed 是必要條件**，不是順手。原因：

- Session 顯示邏輯（`InputSession_HandleDisplay`／`HandleStates`）大量呼叫 `IMEState.ofInputting(...)` 與 `IMEStateParsed(...)`
  產生 NSAttributedString；若只遷 Session 類別而不遷 factories／Parsed，Typewriter 模組內這些呼叫會解析到 Shared 的
  baseline factories（無 hardening、無 currency numerals），與 Darwin 行為分叉。
- `IMEStateParsed4Darwin` 名稱雖帶 Darwin，實質僅依賴 Foundation（`NSAttributedString`／`NSRange`）＋`SessionHost` 閉包，
  故可直接改名 `IMEStateParsed` 遷入，無需保留 Darwin 名稱。

### 2.2 為什麼用 `SessionHost` 單例而非 per-session 注入

選 `SessionHost.shared` 全閉包注入（P175 同款）而非每個 session 實例帶注入參數，理由：

- 與 `SettingsUIHost` 模式一致，未來拆套件／同步 legacy 的既有慣例可沿用。
- Session 的 OS-dependent 動作（LMMgr、Notifier、SpeechSputnik、AppDelegate 等）絕大多數是**程序級單例服務**，
  本就與特定 session 無關；per-session 注入只是把參數轉手一次。
- 測試注入點單一（`SessionHost.wireUp()` 於測試套件 init 呼叫一次），不必每個測試案例重設。

### 2.3 沒遷走的東西與理由

| 留守 MainAssembly4Darwin | 理由 |
|---|---|
| `SessionControllerSputnik.swift` | IMK controller 位址↔session 對照、`class_addMethod` 掛鉤——純 IMK 生命週期 |
| `IMEMenuSputnik.swift` | NSMenu 建構，Darwin 專屬 |
| `SessionUI.swift` | 實作 `SessionUIProtocol` 的 AppKit UI（選字窗、tooltip、PCB） |
| `InputSession_DarwinSurface.swift`（新） | IMK surface：`init(controller:)`、`recognizedEvents`、`showPreferences`、IMKInputController surface、NSEvent→KBEvent 轉換、`toggleInputMode`（TIS 邏輯） |
| `SessionHostWiring.swift`（新） | `SessionHost.wireUp()`，於 `MainSputnik4IME.init()`＋測試套件 init 呼叫 |

### 2.4 `langModel` 延伸為何必須遷移

`Shared.InputMode.langModel`（含 `LangModelCache`）原定義於 MainAssembly 的 `LMMgr_Core.swift`。Session 程式碼大量使用
`inputMode.langModel.cassetteSelectionKey`／`cassetteReverseLookup`／`insertTemporaryData` 等。遷移後 Typewriter 無法看到 MainAssembly 的延伸，
故整個延伸（含 cache 邏輯）遷入 Typewriter 的 `SessionHost.swift` 檔內，POM 資料路徑改走 `SessionHost.shared.pomDataURL` 閉包；
兩倉 `LMMgr_Core.swift` 移除原延伸區塊。**教訓**：凡「Session 程式碼會用到的 Shared 型別延伸」都要一併遷移或改走閉包，
否則會出現「編譯過但行為分叉」的靜默問題。

---

## 三、手術檔案地圖

### 3.1 Typewriter 新增（Sources/Typewriter/）

| 檔案 | 內容 |
|---|---|
| `Session/SessionHost.swift` | `SessionHost.shared` 單例＋30+ 閉包＋`Shared.InputMode.langModel` 延伸（含 cache） |
| `Session/SessionClientProxy.swift` | 跨平台客戶端 proxy 抽象（8 方法） |
| `Session/SessionProtocol.swift` | 自 `InputSession_CoreProtocol.swift` 遷入（去 Darwin） |
| `Session/InputSession.swift` | 自遷入（portable 核心；去 IMK surface／NSAlert／clientProxy 位址解析） |
| `Session/InputSession_Delegates.swift` 等 4 檔 | 遷入（去 LMMgr／IMEApp／NS*／Notifier／SpeechSputnik 依賴） |
| `Session/IMEState.swift`、`IMEStateParsed.swift` | 遷入（原 `IMEStateParsed4Darwin.swift` 改名） |
| `InputHandler/InputHandler.swift` | 遷入（具體 handler，去 IMEApp／SpeechSputnik 依賴） |

### 3.2 SessionHost 閉包清單（依職責分組）

- **IMEApp**：`isKeyboardJIS`、`buzz`
- **LMMgr**：`isCoreDBConnected`／`syncLMPrefs`／`flushTrieCaches`／`isStateDataFilterableForMarked`／`savePerceptionOverrideModelData`／
  `writeUserPhrasesAtOnce`／`bleachSpecifiedSuggestions`／`checkIfPhrasePairExists`／`checkIfPhrasePairIsFiltered`／`userDictDataURL`／`pomDataURL`／`validateCandidateKeys`
- **Notifier**：`notify`
- **SpeechSputnik**：`narrate`、`narrator`
- **AppDelegate**：`checkUpdate`、`checkMemoryUsage`
- **NS* 系列**：`isElectronBasedApp`／`findAccentColor`／`isAccentColorCustomized`／`openURL`／`isVoiceOverEnabled`／`soundBuzz`／`setPasteboardString`
- **IMKHelper**：`isDynamicBasicKeyboardLayoutEnabled`
- **Broadcaster**：`postEventForClosingAllPanels`
- **IMKControllerLifetimeTracker**：`isControllerAddressAlive`、`resolveClientProxy`
- **SessionUI**：`ui`
- **PrefMgr**：`prefs`
- **ChineseConverter 橋**：`crossConvert`、`kanjiConversionIfRequired`
- **UserPhrase／CandidateTextService 延伸**：`updateUserPhraseWeight`、`responseFromSelector`

### 3.3 MainAssembly4Darwin 變動

- 新增 `SessionController/InputSession_DarwinSurface.swift`、`SessionHostWiring.swift`
- 刪除 `IMEState.swift`、`IMEStateParsed4Darwin.swift`、`InputHandler/InputHandler.swift`、`SessionController/InputSession*.swift`（9 檔）
- `LMMgr_Core.swift` 移除 `Shared.InputMode.langModel` 延伸區塊
- `MainSputnik.swift`、測試套件 init 各呼叫 `SessionHost.wireUp()` 一次

### 3.4 Legacy 鏡像

- portable 11 檔遷入 `Shared/vChewingComponents/Typewriter/`（Session／InputHandler 子目錄；去 `@MainActor`／`nonisolated deinit` 方言、去模組 import）
- `InputSession_DarwinSurface.swift`＋`SessionHostWiring.swift` 入 `vChewing/Modules/SessionController/`
- `LMMgr_Core.swift` 移除 langModel 延伸；`MainSputnik.swift` 呼叫 `SessionHost.wireUp()`
- pbxproj 增 13 檔（含新 Session group）、刪 9 檔

---

## 四、跨平台陷阱實錄（Linux CI 抓出）

### 4.1 `NSAttributedString()` 零參數 init

- **症狀**：Linux（swift-corelibs-foundation）編譯 `InputSession_HandleStates.clearInlineDisplay()` 失敗：
  `missing argument for parameter 'string' in call`。
- **根因**：Darwin 的 `NSAttributedString` 有零參數 init（預設空字串）；Linux 只有 `init(string:)`。
- **修復**：`NSAttributedString()` → `NSAttributedString(string: "")`。

### 4.2 optional `isEqual(to:)`

- **症狀**：`string.isEqual(to: recentMarkedText.text)`——`recentMarkedText.text` 是 `NSAttributedString?`。
- **根因**：Darwin 的 `isEqual(to:)` 接受 optional（ObjC 橋接）；Linux 需要非 optional。
- **修復**：`recentMarkedText.text.map { string.isEqual(to: $0) } ?? false`（nil 視為不相等，語義與 Darwin 一致）。

### 4.3 一般性檢查清單（供 Linux 分支開發參考）

遷移 Darwin 程式碼到 Typewriter（Linux 可編譯目標）時，除上述兩例外，還應檢查：

- 零參數 Foundation／AppKit init（`NSAttributedString()`、`NSMutableAttributedString()` 等）——一律改顯式 `init(string:)`。
- optional 傳給不接受 optional 的方法（`isEqual(to:)` 為典型）——先 `map`／`??` 解包。
- 依賴 `Bundle.main`／`UserDefaults.standard` 以外的 Darwin 專屬單例（`NSWorkspace`、`NSApp`、`NSRunningApplication` 等）——全部改走 `SessionHost` 閉包。
- `#available`／`canImport(Darwin)` 守衛——portable 檔不應需要，需要的話代表有東西沒遷乾淨。

---

## 五、imports 清單簡化（事主提示後補做）

沿用 P175「`_ModuleReexport` 剝離模組 import」前例：Typewriter 的 `TypewriterSPM.swift` 本已
`@_exported import BPMFVS`／`BrailleSputnik`／`Homa`／`LangModelAssembly`／`Shared`／`SwiftExtension`／`Tekkon`，
故遷入之 11 檔內重複的模組 import 一律剝離、僅留 `import Foundation`——檔面與 legacy 鏡像（單一 target、本無模組 import）
達成逐字節一致（Session 9 檔＋`SessionCoreProtocol` 逐字節相同；`InputSession.swift`／`InputHandler.swift` 僅存
`@MainActor`／`nonisolated deinit` 方言差）。**今後在 Typewriter 內新增檔案時，除非用到 `TypewriterSPM.swift`
未 re-export 的模組，否則不需再寫 `import Shared`／`import SwiftExtension` 等。**

---

## 六、驗證與 commit

- macOS root `swift build` ✅、Typewriter **156/156** ✅、MainAssembly4Darwin **69/69** ✅
- Legacy `make debug-core` BUILD SUCCEEDED ✅
- Linux（`x86_64-unknown-linux-gnu`，Swift 6.3.3）／WinNT CI 全數通過 ✅（Linux 實編實證第四節修復）
- macOS 26 / Xcode 26.6 CI ✅
- 兩倉 `make lint; make format` 後重建 ✅、diff 僅含手術檔案
- commit：macOS `539ee616`、Legacy `36b7fdb0`（同訊息「Typewriter // Absorb the OS-independent part of Session.」）；
  LibVanguard 文件隨 HEAD aggregate、不另記 commit hash
