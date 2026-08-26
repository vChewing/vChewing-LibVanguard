# Phase 175 術後沉澱報告：SettingsUI SPM 抽取（`vChewing_SettingsUI`）

> 調查日期：2026-09-02。範圍：vChewing-macOS / vChewing-OSX-Legacy 兩倉。
> 背景：Phase 175 依需求「Settings 畫面對記憶體的佔用量實在太大，且佔用了就不會被釋放，或許值得單獨分割出來一個 Swift Package 然後藉由其他 executable bundle target 來做 debug」，
> 將偏好設定畫面（SettingsCocoa＋SettingsUI 兩套內容）自 `MainAssembly4Darwin` 抽取為獨立 Swift Package `vChewing_SettingsUI`，
> 所有對宿主（MainAssembly4Darwin）的動作依賴改走 `SettingsUIHost` 閉包注入。
> 本文為術後沉澱記錄：補足 Reqs 檔未寫的決策脈絡、踩過的坑與今後同步注意事項，供後續拆套件／跨平台開發的 agent 參考。
> 註：本抽取確立的「單例＋閉包注入」模式，即為 Phase 176 遷移 Sessions 體系至 Typewriter 時 `SessionHost` 所沿用的前例（見 `Phase176_PostReport.md`）。

---

## 一、結論速覽

| 項目 | 結果 |
|---|---|
| 抽取標的 | `MainAssembly4Darwin` 內 `Settings/` 全部 31 檔（SettingsCocoa 15＋SettingsUI 16） |
| 解耦機制 | `SettingsUIHost.shared` 單例＋lambda-expression property assignment（LMMgr 21 方法＋SessionUI／AppDelegate／InputSession 3 項＋`PhraseEditorDelegate`＋Notifier 1 項）；未注入＝無操作預設 |
| `PrefMgr.shared` | 自 MainAssembly4Darwin 遷至 `Shared_DarwinImpl`（含 `validate(candidateKeys:)`），Settings 檔約 120 處呼叫點零改動 |
| 第二波追加 | PhraseEditorUI 併入套件、NotifierUI 改 lambda、套件內建 `_ModuleReexport.swift`（剝離 44 行模組 import） |
| 套件最終規模 | 35 檔、7 個外部套件依賴、可獨立 `swift build`（含 debug 用 executable 情境） |
| 兩倉鏡像 | macOS `SettingsUIHost` 帶 `@MainActor`；legacy 去 `@MainActor` 方言；`PrefMgr_Singleton.swift` legacy 保留原位（行為等價） |
| 驗證 | macOS root build ✅、MainAssembly4Darwin 69/69 ✅、`vChewing_SettingsUI` 獨立 build ✅；Legacy `make debug-core` ✅ |
| commit | macOS `64ffa70a`、Legacy `3dde9410`（同訊息「SettingsUI // Put all assets into a single Swift package module.」） |

---

## 二、架構決策脈絡（Reqs 檔未寫的部分）

### 2.1 為什麼選 lambda-expression property assignment 而非 delegate protocol

Reqs 提供了兩案：①所有依賴走 lambda-expression property assignment；②在 `shared_darwinImpl` package 引入 delegate protocol 對 MainAssembly4Darwin 與 `vChewing_SettingsUI` 開放。最後採①，理由：

- **最大的依賴面是 `LMMgr`，而它是「靜態方法叢集」**（約 21 個方法全為 `static func`）。delegate protocol 若要涵蓋，不是寫 21 個 instance wrapper（`extension LMMgr` 逐個轉送 static），就是走 static requirement＋existential metatype（`host.lmService?.cassettePath()` 的呼叫語法彆扭且恆可空）。lambda 注入則宿主端只是 21 行平鋪的 closure assignment。
- **closure 的「未注入＝無操作預設」讓套件可以真的獨立跑起來**——本次動機就是要能拿別的 executable bundle target 去 debug Settings 視窗；delegate protocol 的 nil 狀態只會把「未注入」變成崩潰或 if-let 地獄。
- **與既有慣例同構**：`PrefMgr` 的 init 本就吃 `didAskForSyncingLMPrefs` 等閉包參數（見 `PrefMgr_Core.swift`），閉包注入不是新語言。
- delegate protocol 方案的真實價值（型別安全／可發現性）不足以抵消「為單一消費者把協議塞進 shared_darwinImpl」的擴散成本。

代價（接受並記錄）：closure 屬性無簽名文件、新增依賴時容易漏 wire——靠 §五 的紀律補償。

### 2.2 單例閉包注入（`SettingsUIHost.shared`）而非 per-window 注入的取捨

Settings 視窗本體就是單例（`CtlSettingsCocoa.shared`／`CtlSettingsUI.shared`），它所呼叫的服務（LMMgr、SessionUI、AppDelegate、Notifier）也全是**程序級單例**——per-window 或 per-view 注入只是把參數轉手一次。`shared` 靜態單例＋單一 `wireUp()` 點：

- 生產端：`MainSputnik4IME.init()` 呼叫一次（早於任何 UI）；
- 測試端：`MainAssemblyTests` 套件 init 呼叫一次（所有案例共享）；
- 未 wire 時：閉包保持無操作預設，套件單獨 build／run 不炸。

### 2.3 `PrefMgr.shared` 遷到 `Shared_DarwinImpl`，而不是遷進 `Shared`

`PrefMgr` 型別在 `Shared`，但 `shared` 單例原在 MainAssembly4Darwin（`PrefMgr_Singleton.swift`）組裝——因為它的 init 閉包觸及 `LMMgr`（MainAssembly4Darwin）、`SpeechSputnik`（Shared_DarwinImpl）、`SessionUI`（MainAssembly4Darwin）。曾考慮「把單例搬進 `Shared`」，**不可行**：`Shared` 是跨平台套件（Linux 可編譯），不能依賴 `Shared_DarwinImpl` 的 `SpeechSputnik`、更不能依賴 MainAssembly4Darwin。

解法是折衷：單例遷入 **`Shared_DarwinImpl`**（macOS 專屬、兩邊都已依賴的套件）——
- 宣告期掛 `didAskForRefreshingSpeechSputnik`（`SpeechSputnik` 同模組）＋`candidateKeyValidator`（`validate` 亦同模組）；
- 涉及 `LMMgr`／`SessionUI` 的 `didAskForSyncingLMPrefs`／`didAskForSyncingShiftKeyDetectorPrefs` 改由宿主 `wireUp()` 啟動時注入（closure 屬性本身可後設，這正是該設計能拆開的關鍵）。

如此 Settings 檔約 120 處 `PrefMgr.shared.xxx` 逐字節零改動——這是抽取能「低噪音」的最大功臣。

### 2.4 `validate(candidateKeys:)` 為何不能下放跨平台 `Shared`

該 extension（原在 `PrefMgr_Singleton.swift`）依賴 `IMEApp.isKeyboardJIS`——它定義在 `Shared_DarwinImpl/IMEApp_DarwinImpl.swift`（讀 TIS 鍵盤狀態，Darwin 專屬）。`Shared` 要保持 Linux 可編譯，不能收容任何 Darwin 依賴；所以 `validate` 跟著單例一起進 `Shared_DarwinImpl`（`CandidateKey.validate` 與 `PrefMgrProtocol` 屬性雖在 `Shared`，但 `isKeyboardJIS` 是硬阻點）。

### 2.5 Settings 為何必須用「已掛 didSet 回呼」的 `PrefMgr.shared`、不能學其他套件用 `sharedSansDidSetOps`

其他套件（Typewriter、CandidateWindow、NotifierUI…）一律用 `PrefMgr.sharedSansDidSetOps`——但那是因為它們只**讀**偏好。Settings 的職責是**改**偏好，而 `PrefMgr_Core.swift` 的 `@AppProperty` didSet 會觸發真實副作用：

- `didAskForSyncingLMPrefs`（`phraseReplacementEnabled`／`associatedPhrasesEnabled`／`cassetteEnabled` 等 11 處 didSet）→ `LMMgr.loadUserPhraseReplacement()`＋`syncLMPrefs()`；
- `didAskForRefreshingSpeechSputnik`（`readingNarrationCoverage` didSet）→ 語音狀態刷新；
- `didAskForSyncingShiftKeyDetectorPrefs` → Shift 鍵偵測器重設；
- `candidateKeyValidator`（`candidateKeys` didSet）→ 非法選字鍵自動還原預設。

若 Settings 改用 `sharedSansDidSetOps`，在設定窗切換這些選項會**靜默失去副作用**——行為回歸。這是「為何要把單例搬出去共用、而非在套件內另起爐灶」的根本理由。

---

## 三、手術檔案地圖

### 3.1 新套件 `vChewing_SettingsUI`（`Packages/vChewing_SettingsUI/`，最終結構）

| 位置 | 內容 |
|---|---|
| `Sources/SettingsUI/SettingsCocoa/` | 15 檔（含 `PrefUITabs.swift`），自 MainAssembly4Darwin 遷入 |
| `Sources/SettingsUI/SettingsUI/` | 16 檔（含 `CtlSettingsUI`／`SettingsUIViewModel`／12 個 SwiftUI pane），自 MainAssembly4Darwin 遷入 |
| `Sources/SettingsUI/SettingsUIHost.swift` | 橋接單例（新寫）：LMMgr 21 閉包＋resync／updateDirectoryMonitorPath／recentClientBundleIdentifiers＋`phraseEditorDelegate`＋`notify` |
| `Sources/SettingsUI/_ModuleReexport.swift` | 套件級 reexport（第二波新寫）：`BookmarkManager`／`LangModelAssembly`／`Shared_DarwinImpl` |
| `Sources/SettingsUI/PhraseEditor/` | 2 檔（第二波併入）：`PhraseEditorDelegate.swift`＋`PhraseEditorUI.swift` |

合計 35 檔；`Package.swift` 最終 7 個 path 依賴：Shared、Shared_DarwinImpl、SwiftExtension、OSFrameworkImpl、IMKUtils、LangModelAssembly、Jad_BookmarkManager（第一波原為 9 個，第二波移除 NotifierUI、PhraseEditorUI）。

### 3.2 MainAssembly4Darwin 變動

| 動作 | 檔案 |
|---|---|
| 刪除（遷出） | `Sources/MainAssembly4Darwin/Settings/` 全 31 檔 |
| 刪除（遷出） | `PrefMgr_Singleton.swift`（單例＋validate 移至 Shared_DarwinImpl） |
| 新增 | `SettingsUIHostWiring.swift`（`SettingsUIHost.wireUp()`，含 PrefMgr 殘餘 didSet 回呼注入） |
| 修改 | `Package.swift`：＋`../vChewing_SettingsUI`／product `SettingsUI`；－`../vChewing_PhraseEditorUI`／product |
| 修改 | `_ModuleReexport.swift`：＋`@_exported import SettingsUI`；－`@_exported import PhraseEditorUI` |
| 修改 | `MainSputnik.swift`：`init()` 首行 `SettingsUIHost.wireUp()` |
| 修改 | `MainAssemblyTests_Core.swift`：套件 init 增 `SettingsUIHost.wireUp()`（還原 didSet 語義，見 4.4） |

macOS `vChewing.xcodeproj`：＋`vChewing_SettingsUI` package reference；－`vChewing_PhraseEditorUI` reference。

### 3.3 Shared_DarwinImpl 變動

| 動作 | 檔案 |
|---|---|
| 新增 | `Sources/Shared_DarwinImpl/PrefMgr_Singleton.swift`（`PrefMgr.shared` 單例＋`PrefMgrProtocol.validate(candidateKeys:)`） |

### 3.4 Legacy 鏡像（`vChewing/Modules/WindowControllers/SettingsUI/`）

| 動作 | 檔案 |
|---|---|
| 修改（橋接改造） | `SettingsCocoa/` 6 檔（Behavior／Cassette／Clients／Dictionary／General／Phrases；第一波 5 檔＋第二波 General 因 Notifier 改動）——LMMgr／SessionUI／AppDelegate／InputSession／Notifier 呼叫點改 `SettingsUIHost.shared.*`（59＋4 處） |
| 新增 | `SettingsUIHost.swift`（macOS 鏡像、**去 `@MainActor`**） |
| 新增 | `vChewing/Modules/SettingsUIHostWiring.swift`（`wireUp()`；legacy 的 `PrefMgr.shared` 已在 app 模組內宣告期掛載全部 didSet 回呼，故此處不含 PrefMgr 注入） |
| 遷移（git mv） | `Shared/vChewingComponents/Shared/PhraseEditorDelegate.swift` → SettingsUI 目錄（pbxproj group 同步；legacy 無 SwiftUI 語彙編輯器、僅需委派協定） |
| 保留原位（方言） | `PrefMgr_Singleton.swift`（單一 app target 無套件邊界，行為等價） |
| pbxproj | ＋2 檔（SettingsUIHost／SettingsUIHostWiring）＋delegate group 遷移 |

---

## 四、踩過的坑／決策轉折實錄

### 4.1 Swift 函式型別不承載 argument label（第一波即踩）

初版 `SettingsUIHost` 的閉包型別寫成帶 label 的形式（如 `dataFolderPath(isDefaultFolder: Bool) -> String`），目的想讓呼叫點 sed 只需換 receiver。編譯器直接報 **「function types cannot have argument labels」**（附 FixIt：改 `_`）——函式**宣告**可以有 label、函式**型別**不行。於是多參數閉包一律無 label，呼叫點（`retrieveData(mode:type:)` 等約 10 處）除了換 receiver 還得手動去 label。
**教訓**：做閉包屬性注入時，從第一版就把參數寫成無 label；要保留 label 只能走 method／protocol。

### 4.2 blanket sed 的雙重誤替與 i18n key 保護

用 `LMMgr\.shared\.`→`SettingsUIHost.shared.` 再 `LMMgr\.`→`SettingsUIHost.shared.` 兩段式 sed 時，`delegate: LMMgr.shared, window:`（`shared` 後接逗號非句點）被第二段命中變成 `SettingsUIHost.shared.shared`——靠編譯錯誤抓出、手動修正。另一險情：i18n key `"i18n:LMMgr.accessFailure.cassette.title"` 內含 `LMMgr.`，sed 會連字串一起換掉——用 negative lookbehind `(?<!i18n:)LMMgr\.` 保護，實測 key 完好。
**教訓**：全域 sed 前先確認字串字面值是否夾帶符號前綴；sed 順序（長 pattern 先）與斷言都要驗。

### 4.3 git revert 誤「復活」已刪檔案（兩波各踩一次）

依 KnowledgeMemo 慣例，交差前跑 `make lint; make format`——本機 SwiftLint 版本漂移會對幾百個無關檔案下 `--fix`（P159 已有前例）。還原無關 churn 時用 `git checkout -- $(git diff --name-only | grep -v 手術檔)`，但 `git diff --name-only` 會列出**已刪除**的檔案（Settings 31 檔＋PrefMgr_Singleton）——它們不在 grep -v 排除名單內，被 `git checkout` 整批「復活」，兩次都造成 MainAssembly4Darwin 與新套件同時含 `UserDefRenderableImpl`、編譯報 `ambiguous use of 'render()'`。
**教訓**：還原前後都必須用 `git status` 核對刪除檔計數（應為 32）；還原名單要顯式排除刪除路徑（或改用 `--diff-filter=ACMR`）。

### 4.4 didSet 回呼語義與測試 init（`wireUp()` 必須在測試端也呼叫）

把 `didAskForSyncingLMPrefs` 等 wiring 從 `PrefMgr.shared` 的**宣告期**移到 `wireUp()` **啟動期**後，MainAssembly4Darwin 測試立刻紅一盞：`test013_LMMgr_CassettePathFallsBackToCachedCopy` 依賴「設 `cassettePath` → didSet → `LMMgr.syncLMPrefs()` 記錄路徑失效警示」，而測試進程不經過 `MainSputnik4IME.init`。修法：測試套件 init 補 `SettingsUIHost.wireUp()`（69/69 復綠）。
**教訓**：把 didSet 回呼的掛載時機從「型別初始化」挪到「bootstrap」時，測試端要有對應的注入點；`wireUp()` 要設計成冪等、可被測試與生產雙重呼叫。

### 4.5 legacy 的 `@MainActor` 方言

macOS 的 `SettingsUIHost` 標 `@MainActor`（Swift 6 default isolation）；legacy 是 Swift 5（Xcode 15）非隔離環境，原樣鏡像後 `MainSputnik.init()` 呼叫 `wireUp()` 報「call to main actor-isolated static method in a synchronous nonisolated context」。legacy 版 `SettingsUIHost` 去 `@MainActor`（純閉包容器、無 UI 狀態，安全），檔頭註解標明方言差異。
**教訓**：legacy 鏡像的既有方言清單（`nonisolated` 剝離、`flatMap`、import 剝離…）要再加入「actor isolation 剝離」一項。

### 4.6 第二波追加三項的各自成因

- **PhraseEditorUI 併入**：清查後它是「只有 Settings 在用的單一套件」——`VwrPhraseEditorUI` 僅 `VwrSettingsPanePhrases` 引用、`PhraseEditorDelegate` 僅 MainAssembly4Darwin 的 `LMMgr` conformance 引用；2 檔極小。併入後少一層套件邊界、delegate 與其消費者同模組，MainAssembly4Darwin 的 conformance 經 `@_exported import SettingsUI` 繼續可見。legacy 端沒有 SwiftUI 編輯器，只需遷移委派協定檔。
- **NotifierUI 改 lambda**：Settings 內 `Notifier.notify` 僅 8 處呼叫，是「顯性套件依賴換 1 個閉包」的最划算交易——套件 manifest 少一個依賴、與其餘動作依賴同構。
- **`_ModuleReexport.swift`**：第一波為讓 31 檔能在獨立模組編譯，逐檔補了 44 行 `import Shared_DarwinImpl` 等——這讓 macOS 檔面與 legacy（單一 target、本無模組 import）產生 44 行結構性差異，往後同步得反覆剝離。套件內建 reexport（`Shared_DarwinImpl` 已轉匯出 Shared／SwiftExtension／OSFrameworkImpl／IMKUtils，故只需再補 BookmarkManager＋LangModelAssembly）後全部剝掉，兩倉檔面趨近、利於逐字節同步。

---

## 五、今後同步維護注意事項

1. **SettingsUI 套件內新增檔案：除非用到 `_ModuleReexport.swift` 未 re-export 的模組，否則不需再寫 vChewing 模組 import**——只保留 AppKit／SwiftUI／UniformTypeIdentifiers／Foundation／Combine。新增模組依賴時，先想清楚要直接 import 還是擴充 reexport 清單（後者對 legacy 同步更友善）。
2. **`SettingsUIHost` 新增閉包時，wire 點有兩倉共 3 處**：macOS 生產端 `MainAssembly4Darwin/SettingsUIHostWiring.swift`（`wireUp()`，經 `MainSputnik4IME.init()` 觸發）、macOS 測試端 `MainAssemblyTests_Core.swift` 套件 init、legacy `vChewing/Modules/SettingsUIHostWiring.swift`。漏 wire 不會編譯失敗、只會靜默 no-op——加閉包時把三處當 checklist。
3. **legacy 鏡像方言清單（本手術新增／確認）**：`SettingsUIHost` 去 `@MainActor`；無模組 import；`PrefMgr_Singleton.swift` 留在 app 模組（macOS 則在 Shared_DarwinImpl＋宿主 bootstrap 注入）；`PrefUITabs.swift` 位置 legacy 在 SettingsUI 根、macOS 在 SettingsCocoa/（既存漂移）。
4. **`PrefMgr.shared` 的 didSet 回呼只在宿主 wire 後才完整**——任何直接 new `PrefMgr` 或改用 `sharedSansDidSetOps` 的程式碼都會失去 LM 重載等副作用；Settings 系列一律走 `PrefMgr.shared`。
5. **Swift 函式型別無 label**——往 `SettingsUIHost`（或任何閉包注入容器）加多參數閉包時，呼叫點是無 label 語法。
6. **模式已成為前例**：P176 遷移 Session 體系至 Typewriter 時 `SessionHost` 沿用本設計（單例＋閉包注入＋`wireUp()` 雙端呼叫＋`_ModuleReexport` 剝離 import）——今後拆套件直接沿用此骨架。

---

## 六、驗證與 commit

- macOS：root `swift build` ✅、`vChewing_SettingsUI` 獨立 `swift build` ✅（35 檔）、MainAssembly4Darwin **69/69** ✅（含測試端 `wireUp()`）
- Legacy：`make debug-core` BUILD SUCCEEDED ✅（含 pbxproj 新檔與 delegate group 遷移）
- 兩倉 `make lint; make format` 後還原無關 churn（本機 SwiftLint 版本漂移、P159 前例）、diff 僅含手術檔案；新檔 swiftformat 冪等（0/34）
- commit：macOS `64ffa70a`、Legacy `3dde9410`（同訊息「SettingsUI // Put all assets into a single Swift package module.」，兩波內容皆併入）
- LibVanguard：P175 文件記錄（Reqs／DevReqsHistory／KnowledgeMemo／本 PostReport）皆位於 DevPlans 目錄、隨 LibVanguard HEAD aggregate，不另記 commit hash
- 本報告（`Phase175_PostReport.md`）為新檔，commit 待事主確認
- 註：對話進行中所見 macOS commit 一度為 `566f2a33`，經事主 amend 後為現況 `64ffa70a`，以現況為準
