# Phase 185–186 術後調查與研究報告：SettingsUI（SwiftUI）／SettingsCocoa（AppKit）偏好設定視窗記憶體佔用調研

> 調查日期：2026-09-04。範圍：`vChewing-macOS`（僅 macOS 倉實測；legacy 倉為逐字節鏡像，結論同源適用，唯系統差異另見 §8）。
> 調查對象：`Packages/vChewing_SettingsUI`（單 target `SettingsUI`，Phase 175 自 MainAssembly4Darwin 抽出之獨立套件）。
> 目的：解釋「開關偏好設定視窗後出現超過 50MB 的私有記憶體淨浪費、且不隨關窗歸還」之現象，定位成因並提出驗證與改善方向。Phase 185 純研究、零程式碼變更；Phase 186 承接施工（H3 內容生命週期 M2/M3、`pendingUnitTests` bypass）與隔離宿主量測（詳見附錄一~五）；本文件為兩 phase 之唯一彙總報告。

---

## 一、結論速覽

| 項目 | 結果 |
|---|---|
| vChewing 自身的視窗物件圖是否洩漏 | **否**。兩 flavor 的 controller 皆於關窗時拆 delegate／抽離 contentView／清空 `shared`；既有 in-process 測試（`test005_SettingsWindowDoesNotLeak`）證明 SwiftUI 開關一輪淨殘留 **<1MB**（`MainAssemblyTests_SettingsUI.swift:20-44`） |
| 真實 IME 進程關窗後為何仍殘留 50~90MB | 殘留幾乎全在 **malloc heap**（現場 `vmmap`：`Malloc Small` dirty ≈ 121.7MB），且量測前已呼叫 `malloc_zone_pressure_relief(nil, 0)`（`purgeMallocZones`）——判讀為「進程級一次性啟用成本／常駐 cache」＋「malloc arena 曾擴張未縮回（高水位、fragmentation）」兩者疊加，**非 vChewing 物件洩漏**（詳見 §5） |
| 為什麼第二種 flavor 翻頁「無論翻幾頁都平坦」 | 翻頁成長只發生在**該 flavor 於進程內首次啟用**時（控制項子系統／排版／繪圖 first-touch 一次性成本）；第二次（暖）開窗時同類成本已付清 → 平坦（詳見 §3、§5-H1） |
| 為何 SwiftUI 恆比 AppKit 高 ~50~60MB | SwiftUI runtime／AttributeGraph／`NSHostingView` 的匿名配置較重（dyld 頁不計入 `internal` 讀數，故差異落在 heap）；且兩 flavor 皆「首次開窗即全量預建 12 頁」策略使峰值極高（詳見 §4、§5-H4） |
| 最可疑的 vChewing 側放大因子 | Phrases pane：AppKit 於 `CtlSettingsCocoa.init → preload()` 即全文 `retrieveData` 進 NSTextView、`viewWillAppear` 每訪重取；SwiftUI 側編輯緩衝走 `static VwrPhraseEditorUI.txtContentStorage`，僅依賴 `.onDisappear` 清空（詳見 §4.4） |
| 建議下一步 | 不先動生產碼；以 DEBUG deinit log、`malloc_zone_statistics`、逐頁 lazy 化等實驗拆分殘留歸屬（詳見 §6） |

---

## 二、測量語義（「私有記憶體」到底是什麼）

本報告所有「私有記憶體」數字，語義皆為**輸入法選單內建的 RAM 讀數**，其定義與取樣方式如下（全部為既有程式碼，非本 phase 新增）：

- 讀數 API：`NSApplication.memoryFootprintAnonymous` ＝ `task_info(TASK_VM_INFO)` 的 `internal` 欄位（`Packages/vChewing_OSFrameworkImpl/.../AppKitImpl_Misc.swift:423-456`）。只計匿名私有頁面（malloc zone、stack、`VM_ALLOCATE`），**排除** dyld 檔案映射與 GPU 共享表面；IMK 物件分配仍在統計範圍內。Phase 99／125 曾由 ledger 扣除改至此單次讀取語義。
- 取樣前先 `NSApplication.purgeMallocZones()`（同檔 415-421）＝ `malloc_zone_pressure_relief(nil, 0)`——要求 allocator 把**未使用的頁面**歸還，使讀數儘可能貼近「實際存活」。**注意**：zone 可視情況選擇不釋放，故此讀數**仍可能含 freed-but-retained 的 arena 頁**（malloc 不必然把空閒區塊交還 OS；Phase 11 DFD 實驗已在本專案實證過此行為）。
- 讀數掛在輸入法選單固定項目（`IMEMenuSputnik.swift:105` 掛 `currentRAMUsageDescription`，482-496 組字串；選單每次 IMK `menu` 查詢時重建，`SessionControllerSputnik.swift:203-207`）。此項目**非 DEBUG 限定、恆顯示**。

因此事主數據（下述 §3）皆為「已先請 malloc 歸還空閒頁、再量匿名私有頁」的數值；關窗後仍不降，代表殘留的是**真正還活著的配置或 allocator 不願歸還的區塊**，不是單純 free-list 沒整理。

---

## 三、事主數據整理與初步推導

事主原始數據（mac mini M4／Apple Silicon／macOS 27，輸入法選單私有記憶體讀數；單位 MB）：

**基線**：閒置 38~42；剛啟動 52~62。

**序列 A（SwiftUI 先）**
| 步驟 | 讀數 | 相對剛啟動(+52~62)之增量 |
|---|---|---|
| 剛啟動 | 52~62 | — |
| 開 SwiftUI SettingsUI | ~205 | **+143~+153（冷）** |
| 翻幾頁 | 211+ | +6（翻頁成長） |
| 關 SwiftUI | ~144 | **殘留 +82~+92（>50，不歸還）** |
| 再開 SettingsCocoa | 184.5~194 | +40~50（暖，平坦） |
| 關 SettingsCocoa | ~132 | ≈ +70~80（甚至低於開前 144） |

**序列 B（AppKit 先）**
| 步驟 | 讀數 | 相對剛啟動之增量 |
|---|---|---|
| 剛啟動 | 52~62 | — |
| 開 SettingsCocoa | ~144 | **+82~+92（冷）** |
| 翻幾頁 | 160+ | +16（翻頁成長） |
| 關 SettingsCocoa | ~112 | **殘留 +50~+60（>50，不歸還）** |
| 再開 SwiftUI SettingsUI | 200.7~215 | +89~+103（暖，平坦） |
| 關 SwiftUI | ~135 | +73~+83（比開前 112 高 ~23） |

**可重複的規律（本文分析基準）：**

1. **冷 vs 暖成本差明顯**：SwiftUI 冷開 +148（A）vs 暖開 +89~103（B）；AppKit 冷開 +82~92（B）vs 暖開 +40~50（A）。任一 flavor 第二次開窗都便宜 ~45~60MB 且**翻頁平坦**。
2. **翻頁成長只發生在「進程內首次啟用的那一個 flavor」**（A-SwiftUI +6、B-Cocoa +16）；第二個啟用者無論翻幾頁皆平坦。→ 強烈指向「控制項／框架子系統 first-touch 一次性成本」，非每次開窗重複付出。
3. **關窗後的殘留**：單一 flavor 冷開關一輪後，殘留約為 SwiftUI +82~92（A 序列到 144）、AppKit +50~60（B 序列到 112）。**兩個 flavor 都開過一次後，最終態約 132~135**，且與順序無關（A 終 132、B 終 135）——殘留**不線性疊加**（A 中第二次開 Cocoa 後甚至從 144 降到 132）。
4. 事主對兩種序列都下了「超過 50MB 的淨浪費」的結論，與上表殘留增量一致。

第 3 點的「不線性疊加」＋第 1、2 點的「冷熱差」＋第 2 節的「讀數前已 purge」合起來的圖像：殘留主體不是「每次開窗各漏一份 vChewing 物件」，而是**進程層級一次性付出的成本（cache、子系統啟用）＋ malloc arena 在冷啟用大峰值後留下未縮回的高水位**（峰值越大、殘留越多，且 purge 只能回收 allocator 願意交還的部分）。詳見 §5。

---

## 四、程式碼面靜態診斷（什麼在建、何時建、誰持有）

### 4.1 兩種 flavor 都在「首次開窗」時把全部 12 頁一次建好

- **SwiftUI**：`VwrSettingsUI.detailView` 以 ZStack＋`ForEach(PrefUITabs.allCases)` **預渲染全部 page**，非當前頁僅 `opacity(0)`＋關閉 hit-testing（`Sources/SettingsUI/SettingsUI/VwrSettingsUI.swift:153-176`）。這是 Phase 75 為了「讓所有 `UserDefRendered.onAppear` 觸發、事前收集 UserDef→Tab 搜尋映射」的刻意設計（該處註解 153-154 明載）。副作用：開窗瞬間 12 頁的 view struct **全部實例化且全部觸發 `.onAppear`**（含 Phrases 的 retrieveData、Clients/Services 的 reloadList）——與「SwiftUI 開窗即 205MB」同向。`tab.suiView` 無快取，每次 body pass 重新求值（`PrefUITabs.swift:70-87`），但 pane `init` 目前幾乎不做重活，成本集中在首次版面與資料。
- **AppKit**：`CtlSettingsCocoa.init()` 內即 `panes.preload()`（`CtlSettingsCocoa.swift:38-40`）→ `SettingsPanesCocoa.preload()` 對 11 個 pane 逐個 `loadView()`（`VwrSettingsCocoaPanes.swift:44-57`，**唯一排除 About**）。12 個 pane 控制器以 stored `let` 常駐於 `SettingsPanesCocoa`（30-41），關窗隨 controller dealloc。翻頁時 `showContentForTab` 只是把**已建好的** `.view` 重新包進新的 NSScrollView／FlippedClipContainerView（546-599），故翻頁本身幾乎不建新內容——「平坦」與此吻合。
- 兩 flavor 此策略的**峰值代價**都是 12 頁全量；SwiftUI 另加自身 runtime。任何「只建當前頁」的改法都會直接砍開窗峰值（見 §7-M1/M2）。

### 4.2 關窗清理兩 controller 都有做（且埋好 deinit 探針）

- `CtlSettingsUI`（`CtlSettingsUI.swift`）：`shared` 靜態（43）；`close()`（61-74）與 `windowWillClose(_:)`（101-108，紅鈕／⌘W 路徑）皆在 `autoreleasepool` 內 `window?.delegate = nil` → `contentView = nil` → `Self.shared = nil`。`windowDidLoad` 每次開窗新建 `SettingsUIViewModel()`（45-59）。DEBUG deinit 探針 `[CtlSettingsUI] deinit called`（19-23）。
- `CtlSettingsCocoa`（`CtlSettingsCocoa.swift`）：同款 `close()`（57-73）／`windowWillClose`（125-135），另清 `sidebarTableView.delegate/dataSource`、`previousView = nil`。DEBUG deinit 探針 `[CtlSettingsCocoa] deinit called`（47-51）。
- 亦即：**只要沒有任何 process-global 反指回 controller 圖，關窗後整個視窗＋12 頁都應 dealloc**。§4.3 盤點全域持有後，找不到能讓整圖存活的 global（唯一例外見 4.3-a 的 Phrases 靜態字串，但它不持有 controller）。

### 4.3 套件內 process-global／靜態持有盤點

| 全域 | 位置 | 內容／風險 |
|---|---|---|
| `SettingsUIHost.shared` | `SettingsUIHost.swift:27`（＋62 強持 `phraseEditorDelegate`） | 進程級注入樞紐；宿主 wiring 把 delegate 綁到 `LMMgr.shared`、所有 closure 綁到進程級單例（`MainAssembly4Darwin/Sources/.../SettingsUIHostWiring.swift:46`）。刻意長命，是 pane 動作觸發 LM 資料的通道 |
| `VwrPhraseEditorUI.txtContentStorage`（static String） | `PhraseEditor/PhraseEditorUI.swift:217` | **套件內唯一真正的靜態可變快取**。編輯緩衝的 `@Binding` 被客製接到此 static（25-31）；內容＝正在編輯的整個使用者詞庫文字。僅在 `.onDisappear` 清空（189-194）。若關窗時 SwiftUI 未送 `onDisappear`（contentView 被直接拔除，見 `CtlSettingsUI.swift:70`），此字串殘留到進程結束 |
| About pane EULA 靜態 | `SettingsCocoa/VwrSettingsPaneCocoaAbout.swift:12-17` | `static let` 自 `Bundle.main` 讀整份 EULA／版權文字，首次觸及即永久保留（幾 KB~數十 KB，小但永久） |
| `PrefUITabs.icon` | `SettingsCocoa/PrefUITabs.swift:102-145` | 每次呼叫新建 `NSImage`、無快取——每 render／每列都重造（小量瞬態） |

**反面盤點**（無風險項）：套件內**無任何** NotificationCenter observer、無 selector-based observer；Cocoa Phrases 的 KVO 用 `[weak self]`＋`deinit` invalidate（`VwrSettingsPaneCocoaPhrases.swift:17,21-27`）；所有 sheet/拖放 completion 皆 `[weak self]`；無 Timer／DispatchSource 殘留（唯一 Debouncer 屬 `@State`，隨 pane 身份釋放）；`SettingsUIViewModel` 只存小型狀態、搜尋結果為即時計算（`SettingsUIViewModel.swift:61-98`），每窗新建、不跨窗累積。→ **套件內無真正 retain cycle**，與既有 `test005` 互證。

### 4.4 Phrases pane：唯一的「內容級」放大因子

- **AppKit**：`loadView()` → `initPhraseEditor()` → `updatePhraseEditor()` → `SettingsUIHost.shared.retrieveData(mode:type:)`（`VwrSettingsPaneCocoaPhrases.swift:21-36,179-193`）。因為 `preload()` 在 `CtlSettingsCocoa.init` 就跑，**每次開窗（即使從不拜訪 Phrases 頁）都會把目前輸入模式的完整詞庫文字 retrieve 進 NSTextView**；且 `viewWillAppear` 又重跑一遍完整 `initPhraseEditor()`（34-36）＝**每次拜訪該頁再全文重取一次**；`viewWillDisappear` 才清空 text（38-40）。
- **SwiftUI**：Pane 嵌在 ZStack 全預建內，`.onAppear`（`PhraseEditorUI.swift:195-199 → 202-213 → delegate.retrieveData`）在開窗首次 render 即觸發；文字經 binding 寫入 4.3-a 的 static。切頁不會重取（Phrases 屬 `tabPagesNotSearchable`、ZStack 身份穩定），但**每次重新開窗都會重取一輪**。
- 此 pane 是**真實 IME（有真實使用者詞庫）才有的內容成本**，也是 in-process 測試主機（缺乏真實使用者詞庫資料與 IMK 環境）量不到的差異來源之一——請見 §5 對「測試主機乾淨 vs 真實 IME 殘留」的討論。

### 4.5 其他值得一提

- Keyboard pane 的輸入法佈局 picker 每次 render 都觸發 TIS 全掃（`IMKHelper.allowed…TISInputSources`，無快取，`Packages/vChewing_IMKUtils/.../IMKHelper.swift:53-99`）——CPU／瞬態，不殘留，但 SwiftUI 每次 body pass 多掃幾輪。
- 兩 flavor 的設定視窗都在 IME 進程內（IMK `showPreferences` 路徑，`InputSession_DarwinSurface.swift:104-117`；⌥+點選單切 SwiftUI 與 Cocoa），故其佔用直接反映在輸入法私有記憶體讀數上——這正是「把 Settings 抽成獨立套件以便集中診斷」（Phase 175）的用途。

---

## 五、成因假說（依可信度排序）與佐證

### H1（最強）：進程級「UI 子系統 first-touch」一次性啟用成本，不隨關窗歸還

- 佐證：冷開 vs 暖開差 ~45~60MB（§3 規律 1）；翻頁成長只發生於首次啟用者（§3 規律 2）；第二 flavor 開窗數值平坦。
- 機制：該 flavor 在 IME 進程內**第一次**使用的控制項類別／framework 子系統（SwiftUI 本體、AttributeGraph、NSScrollView+NSTextView 排版、NSSearchField／field editor、NSPopover、NSVisualEffectView sidebar material、CoreText font cascade、控制項影像）會留下進程級常駐 cache；候選窗／tooltip 等既有 UI 用不到的這些子系統，全部在此時才首次觸發。關窗只釋 vChewing 物件圖，**不釋子系統 cache**。

### H2（強）：malloc arena 高水位未縮回（fragmentation／allocator 保留）

- 佐證：現場 `vmmap`（2026-09-04 13:48，PID 52235）實測：**Physical footprint 147.2MB（peak 334.3MB）**、`Malloc Small` dirty ≈ 121.7MB（VIRTUAL 177.8MB、另有 empty 區 6.4MB dirty）——匿名 heap 是殘留唯一大桶，且讀數前已 purge 過。本專案 Phase 11 已實證過「malloc free-list 不立即歸還 OS、heap 持續膨脹（fragmentation）」的教訓（DFD 手術因此全面撤銷）。
- 機制：開窗造成大峰值（SwiftUI 205MB 級）使 zone 大幅擴張；關窗釋放大量小物件後，zone 保留空閒頁（`Malloc Small (empty)` 仍 dirty），`malloc_zone_pressure_relief(nil, 0)` 只歸還「zone 願意交還」的部分 → 殘留近似「曾達到的某個高水位」。
- 此假說能同時解釋：測試主機乾淨（峰值低→高水位低→無殘留）與真實 IME 殘留大（峰值高→高水位高），以及「殘留不線性疊加、第二次開關甚至略降」（purge／arena 動態）。

### H3（中）：真實內容成本——Phrases 全文 retrieve／編輯緩衝

- 佐證：§4.4；SwiftUI 側另疊 4.3-a 的 static 字串殘留風險。
- 定位：不是「洩漏」而是「長命內容」；放大 H1/H2 的量級，且是 vChewing **可自行控制**的因子（見 §7-M2/M3）。

### H4（中）：開窗峰值與「12 頁全量預建」策略正相關

- 佐證：§4.1。SwiftUI 開窗 205MB（vs AppKit 144MB）中，一部分是「12 頁同時 alive」的必然代價（兩 flavor 皆然），另一部分是 SwiftUI runtime 差額。
- 定位：影響的是**峰值與（若 H2 成立）高水位殘留**，不是逐頁內容洩漏。

### H5（次要）：Keyboard pane TIS 每 render 全掃、About EULA 靜態、`PrefUITabs.icon` 每 render 新建 NSImage

- 皆小量或瞬態；列為順手清理項，非殘留主因。

**綜合圖像**：真實 IME 的「關窗後 >50MB 淨浪費」≈ **H1（子系統常駐 cache）＋ H2（arena 高水位）為主、H3（真實內容）放大**；vChewing 自身的視窗物件圖**沒有**扮演殘留角色（§4.2／`test005` 佐證）。SwiftUI 比 AppKit 多出的 ~50~60MB 為 SwiftUI 子系統的 H1 成本差額。

> 誠實保留：`test005` 在**乾淨測試主機**上量到 SwiftUI 開關一輪 <1MB，這表示 H1 的殘留並非「SwiftUI 一載入就必然數十 MB」，而可能依賴真實環境因子（IMK／真實詞庫內容／長跑進程歷史）。這正是 §6 實驗要拆解的邊界——現階段不宜把 H1 講死。

---

## 六、建議驗證實驗（下一階段，暫不改生產碼）

1. **E1｜deinit 探針（最便宜）**：DEBUG build 實機（或 `swift test` host）＋`log stream --predicate 'process == "vChewing"'`（macOS 26+ 走 os.Logger；DEBUG 探針是 raw `NSLog`），分別以「程式化 close()」與「紅鈕／⌘W」關窗，確認 `[CtlSettingsUI]`／`[CtlSettingsCocoa] deinit called` 都出現——先釘死「controller 有 dealloc」。
2. **E2｜malloc zone 拆分殘留**：以 `test005` 為模板擴充成「雙 flavor × 真實資料」基準：開 → 逐頁巡 → 關，每步採樣 `malloc_zone_statistics(nil)`（`size_allocated` vs `size_in_use`）＋ `memoryFootprintAnonymous`。若 `size_in_use` 也高 → 殘留是「活著的 cache」（H1/H3）；若 `size_allocated ≫ size_in_use` → arena 高水位（H2）。
3. **E3｜殘留物件指認**：Instruments Allocations「Mark Generation」或 malloc stack logging，在關窗前後抓殘留 top allocations，分辨「框架 cache」與「vChewing 物件」。
4. **E4｜隔離變因**：(a) AppKit `preload()` 排除 Phrases（比照 About）重測；SwiftUI 側排除 Phrases 的 retrieve 重測——量化 H3。(b) SwiftUI detail 改「僅建當前頁」的實驗分支重測開窗峰值——量化 H4／驗證 §7-M1 的預期收益。(c) 全新進程只開 SwiftUI 一次 vs 只開 Cocoa 一次，各量殘留，建立 per-flavor cold-residue 基準表（現有數據只有 A/B 兩條交錯序列，殘留歸屬被 order 效應汙染）。
5. **E5｜VMM 層對照**：`vmmap -summary <pid>`（同使用者可讀）在開關前後對照 malloc 區段與「empty」區 dirty 頁變化；`footprint` 需權限，列為選配。

---

## 七、改善方向（供後續 phase 決定，本 phase 不動碼）

- **M1（SwiftUI）**：`detailView` 由 ZStack 全預建改為僅渲染當前 tab。Phase 75 的「onAppear 全頁註冊以建搜尋映射」需附帶遷移：搜尋索引改為於 `SettingsUIViewModel` 初始化時由 UserDef metadata 靜態建立，或改首訪註冊＋快取。預期大幅下修開窗峰值（205MB → 單頁量級）與 H2 高水位。
- **M2（AppKit）**：`preload()` 排除 Phrases（比照 About 已排除之前例）；Phrases 改首訪才 `retrieveData`，取消 `viewWillAppear` 的全量重取（或對內容做 per-window 快取），保留 `viewWillDisappear` 清空。直接砍掉「開窗即全文載入」與「每訪重取」。
- **M3（Phrases 編輯緩衝）**：`VwrPhraseEditorUI.txtContentStorage` 由 static 改為視窗生命週期綁定（controller 持有／environment 注入），並在 `CtlSettingsUI.close()`／`windowWillClose` 顯式清空，不再依賴 `.onDisappear` 時序。
- **M4（視 E2 結果）**：若證實 arena 高水位（H2）為主，大型內容（Phrases 全文）改用可歸還的配置策略或分段載入；並在文件明示「殘留＝子系統成本、非洩漏」，避免未來誤判為 regression。
- **M5（測量面）**：目前**沒有任何 pane** 顯示 RAM 讀數（讀數只在輸入法選單）。可考慮在 DevZone pane 加同一讀數（`NSApplication.memoryFootprintAnonymous`），方便關窗後在同一視窗內立即觀察殘留。
- **M6（順手）**：Keyboard pane 的 TIS 清單加短時快取（避免每 render 全掃）；`PrefUITabs.icon` 快取 NSImage；About EULA 靜態維持現狀即可（量小）。

---

## 八、適用範圍與鏡像註記

- 本調研以 `vChewing-macOS` 為準；`vChewing-OSX-Legacy` 為 source-level 逐字節鏡像（僅 Swift dialect／專案組織差異），**§4 的結構性結論與 §7 的改善方向同源適用**。
- 數據語境：Apple Silicon Mac mini M4／macOS 27（可反映 26~27）。Intel Mac（不限版本）與 Apple Silicon＋macOS ≤15 預期殘留**明顯較少**（framework/子系統成本與記憶體語義不同）；macOS ≤10.13（甚至 10.9）需另記 Swift runtime 佔用、且 10.9 無「私有記憶體」語義——該等平台須另行實測，不能直接套用本報告數值。

---

## 附：關鍵程式碼位置索引

| 主題 | 位置 |
|---|---|
| 私有記憶體讀數 API（`internal`） | `vChewing_OSFrameworkImpl/.../AppKitImpl_Misc.swift:423-456` |
| malloc purge | 同檔 415-421 |
| 選單 RAM 讀數掛載／組字 | `MainAssembly4Darwin/.../IMEMenuSputnik.swift:105,482-496` |
| 選單每查重建 | `SessionControllerSputnik.swift:203-207` |
| showPreferences 分流（⌥ 選 Cocoa） | `InputSession_DarwinSurface.swift:104-117` |
| SwiftUI 全頁 ZStack 預建 | `SettingsUI/SettingsUI/VwrSettingsUI.swift:153-176` |
| SwiftUI controller 關窗清理＋deinit 探針 | `SettingsUI/SettingsUI/CtlSettingsUI.swift:19-23,43,61-74,101-108` |
| AppKit pane 全量 let＋preload | `SettingsUI/SettingsCocoa/VwrSettingsCocoaPanes.swift:30-41,44-57` |
| AppKit controller init preload／關窗清理／deinit 探針 | `SettingsUI/SettingsCocoa/CtlSettingsCocoa.swift:38-40,47-51,55,57-73,125-135` |
| AppKit 翻頁換 view | 同檔 546-599 |
| Phrases Cocoa 全文 retrieve 時序 | `SettingsUI/SettingsCocoa/VwrSettingsPaneCocoaPhrases.swift:21-40,179-193` |
| Phrases SwiftUI static 緩衝 | `SettingsUI/PhraseEditor/PhraseEditorUI.swift:25-31,189-213,217` |
| SettingsUIHost 注入樞紐 | `SettingsUI/SettingsUIHost.swift:27,62` |
| in-process 開關不洩漏測試 | `vChewing_MainAssembly4Darwin/Tests/.../MainAssemblyTests_SettingsUI.swift:20-44` |


---

## 附錄：vChewingDebuggable 隔離宿主 serial 量測（2026-09-04 追加）

### 動機與方法

為把 §5 的假說（H1 框架/子系統 first-touch、H2 malloc arena 高水位、vChewing 物件是否殘留）釘到 per-class 層級，
以 `vChewingDebuggable.app`（獨立診斷宿主，僅 link `MainAssembly4Darwin`、unit-test 沙盒＋原廠辭典、不經 IMK）做**serial** 量測：

- 驅動：URL scheme（`vchewingdbg://…`）下達 open/close/sample/heap，全程單一設定視窗（serial，避免「one process with multiple tabs」混淆）。
- 總量 telemetry：語義與輸入法選單讀數一致——先 `malloc_zone_pressure_relief(nil,0)` 再取 `task_vm_info.internal` 與預設 zone `size_in_use/size_allocated`。
- per-class：自律執行 `/usr/bin/heap -sortBySize <self-pid>`（app 未沙盒化，`/usr/bin/heap` 自帶 entitlement，實測可行），輸出存檔。
- 機台：Apple Silicon Mac mini M4／macOS 27（與本報告 §3 數據同機）。

### 方法學修正（重要，先記）

初版宿主用 SwiftUI **`WindowGroup`**（＝多窗/多分頁應用）；反覆 `open` 會在同一個 process 內疊出多個 `ContentView`，
使「baseline」隨啟動次數漂移（internal 47→65→95→121MB），跨 launch 絕對值失真。改為**單一 `Window` scene** 後：
process 恆為 1（二次 `open` 不增生實例、實測 1 process）、baseline 回到 57.8MB。
→ 教訓：此類記憶體診斷宿主**必須禁用 multi-window/multi-tab**，否則量到的是「多窗疊加」而非單一設定窗成本。

### 乾淨輪數據（單一 Window scene、serial）

| 階段 | internal | inUse | allocated | heap nodes | heap bytes |
|---|---|---|---|---|---|
| 01 baseline（env ready 後） | 57.8 | 27.1 | 72.8 | 213k | 29.0MB |
| 02 open SettingsUI (SwiftUI) | 196.7 | 100.6 | 154.1 | 1144k | 126.2MB |
| 03 close SettingsUI | 118.1 | 48.8 | 153.7 | 310k | 50.1MB |
| 04 open SettingsCocoa (AppKit) | 167.3 | 76.3 | 169.2 | 793k | 90.3MB |
| 05 close SettingsCocoa | 109.6 | 49.4 | 169.2 | 316k | 52.3MB |

per-class 彙整（heap bytes 分群，MB；「vChewing-pane」= Settings/CtlSettings/Vwr/Phrase 類別）：

| 群組 | 01 | 02 | 03 | 04 | 05 |
|---|---|---|---|---|---|
| vChewing-pane 物件 | 0.00 | 0.26 | 0.01 | 0.02 | 0.01 |
| SwiftUI runtime（含 SwiftUICore） | 0.7 | 28.4 | 1.0 | 14.4 | 1.0 |
| AppKit controls（NSView/Button/Text/Scroll/Table/Window…） | 0.2 | 1.8 | 0.3 | 2.1 | 0.4 |
| Swift Metadata／class methodCache | 1.0+0.7 | 5.3+? | 5.3+1.1 | 5.5+1.8 | 5.5+1.8 |
| 未具名／non-object 桶 | 4.5 | 32.5 | 13.3 | 21.9 | 13.9 |

（lexicon 底層恆定：KeyEntry 6.29＋UInt32 4.85＋UInt8 2.59MB，為原廠辭典載體，與設定窗無關。）

### 結論

1. **vChewing 自身的設定物件≈零**：即使視窗開著也只有 0.26MB（SUI）／0.02MB（Cocoa），關窗後 0.01MB。
   直接排除「vChewing 物件洩漏／NSObject 顆數太多」兩類假說（§5-H3 已於 Phase 186 處理；NSObject 之問由 ObjC 全類別僅 ~3MB 佐證）。
2. **開窗成本穩定且全屬框架側**：SUI open 使 internal +138.9／heap bytes +97.2MB；Cocoa open（疊於殘留之上）+49.2／+40.2MB。
   主要成分：未具名/non-object 桶（開窗時 32.5MB，內含 PropertyList.Element ~8MB＝SwiftUI plist 解碼）、SwiftUI runtime、Swift Metadata／class methodCache（class 首次使用的一次性資料）。
3. **關窗歸還 live、但不歸還 zone（H2 ratchet 證實）**：SUI close 使 inUse 100.6→48.8（live 幾乎全釋），但 allocated 154.1→153.7 幾乎不動；
   Cocoa 段 allocated 169.2 全程恆定。關窗後 internal 殘留 = 57.8→109.6（+51.8），inUse 僅 +22.3——差額即 allocator 保留的空閒頁（slack ≈ allocated−inUse ≈ 120MB）。
4. **殘留成分（heap 52.3 vs baseline 29.0，live +23MB）**：Swift Metadata／methodCache 一次性地板（+4.4MB）、**未具名/non-object 桶（4.5→13.9MB，最大單項）**、CT glyph/font cache、SwiftUI 殘留 ~1MB。
   未具名桶無型別標籤，需 malloc stack logging（Instruments Allocations 或 `MallocStackLogging`）方能進一步拆解。
5. **與真實 IME 同形**：host「SUI open 196 / close 118 / 兩 flavor 皆訪 109.6」vs 真實 IME「205 / 144 / ~132-144」——
   走向一致、絕對值低 ~10-25MB（host 無 IMK／輸入 session）。日後可用本宿主做快速 A/B（framework 版本、UI 改動）而不必動真 IME。

### 附錄再補：MallocStackLogging 歸位（2026-09-04）

**工具路徑（Xcode 15 Instruments 不可用後之替代）**：以 `env MallocStackLogging=1 <binary>` 由**已帶 env 的 shell** 啟動宿主（`launchctl setenv` 不會回頭更新已存在 shell、其子代拿不到變數），再用同使用者 `/usr/bin/malloc_history <pid> -callTree`（另有 `-allBySize/-allByCount/-allEvents/-fullStacks`）與 `/usr/bin/leaks --fullStackHistory` 取 stack。實測 macOS 26/27 可用、無需 Instruments GUI。
注意：開 stack logging 後 app 內 `malloc_zone_statistics` 歸零、`internal` 被 log buffer 灌爆（baseline 即 60+MB）——**此模式下只看 malloc_history，telemetry 失準**。

**歸位結果**（call tree 上溯至首個非 allocator frame；open-SUI 狀態與雙窗皆關後 final）：

| 歸屬 | open-SUI | final 殘留 |
|---|---|---|
| Swift heap 漏斗（`swift_slowAllocTyped`；型別層見 heap 的 `_ContiguousArrayStorage<UInt8/UInt32>`、TrieKit Entry、DisplayList 等） | 47.5MB | 16.9MB |
| AttributeGraph `grow_region`（SwiftUI 狀態圖） | 19.8MB | ~0.4MB |
| CA Render Shmem（視窗內容 render shared memory） | 14.5MB | 1.8MB |
| IOSurface／IOGPU（GPU surface） | 10.8+1.2MB | 0.33+0.73MB |
| Swift runtime metadata／witness table／generic value/class metadata（一次性 class-load 地板） | ~6.5+1.4MB | ~6.7+1.4MB |
| objc `cache_t::insert`（method cache） | 2.1MB | 2.7MB |
| CG::Path reserve（視窗/玻璃形狀 path） | 3.3MB | 3.3MB |
| CoreText/CG glyph（TFont shaping、CGGlyphBitmap、fontExtraData cache、CoreUI rendition） | ~3MB | ~3.5MB |
| AutoLayout table、CFString、weak table… | 各 ≤2MB | 各 ≤1.5MB |

**結論**：殘留全屬框架/OS 層——Swift/ObjC runtime 的一次性 metadata＋method cache、CG::Path、CoreText/font 常駐、CA/IOGPU 表面。先前 heap「未具名/non-object 桶 ~14MB」之廬山真面目＝ CG::Path＋CoreText/CoreUI/CFString 等無型別 C++/CF 配置。vChewing 零參與（與上文 per-class 0.26MB→0.01MB 互證）。

**自動化**：宿主新增 URL `mh`（自律 `/usr/bin/malloc_history -callTree`，輸出 `~/Library/Logs/vChewingDebuggable-mh-<ts>.txt`）＋ `Sources/vChewingDebuggable/RunStackLogRound.sh`（`env MallocStackLogging=1` 啟動、serial 五階段、每階段 sample＋mh、以 dump 檔數輪詢確保 capture 完成才進下一階段）；unattended 一輪產 4 份 call tree（open-SUI 狀態檔可達 ~1.3GB，用完即清）。

### 附錄三補：跨機對比（Intel x86-64／macOS 26.6.2 (25G83)，2026-09-04）

**資料來源**：`_ResearchScratch/tmp/Debug-IntelMac-macOS26/`（同 `RunStackLogRound.sh` 流程在 Intel Mac 實跑帶回；mh 檔 header 確認 `X86-64 / macOS 26.6.2 (25G83)`）。Intel 側 mh 檔行數：baseline 216k、open-SUI 2.36M、close-SUI 1.66M、final 820k。

| 指標（malloc_history TOTAL／歸位） | AS arm64 macOS27 | Intel x86-64 macOS26.6 |
|---|---|---|
| baseline | — | 26.0M（physical 47.0M） |
| open-SUI | 157M／152.3MB | 140M／135.2MB |
| close-SUI | — | 114M |
| final 殘留 | 59.2M／57.7MB | 53.6M／51.6MB |
| GPU surface（open） | IOSurface 10.8MB | IOAccelResourceCreate 3.1MB |

**發現**：
1. **跨機器／架構／OS 高度再現**：Intel 的 open-SUI 與 final 歸位 top sites 與 AS 同一家族、同一順序（`swift_slowAllocTyped` 漏斗 39.7 vs 47.5／14.7 vs 16.9、AttributeGraph `grow_region` 19.7≈19.8、CA Render Shmem 14.1≈14.5、CG::Path 3.1 兩邊恆在、objc method cache、Swift metadata、font/CoreText cache…）——「殘留＝框架/OS 一次性＋常駐、vChewing≈0」的結論與架構無關、可一般化。
2. **Intel 整體小 ~8-10%**（final 51.6 vs 57.7、open 135 vs 152），呼應「Intel 明顯較少」；主要來源是 **GPU surface 路徑不同**（AS 走 `IOSurface` 10.8MB、Intel 走 `IOAccelResourceCreate` 3.1MB，差 ~7MB）。
3. **baseline 校準**：Intel baseline TOTAL 26.0M／physical 47.0M，與 AS 無 logging baseline（~47MB）同量級——兩邊起點一致，差異純來自開窗後的框架成本。

**操作提醒**：Intel 上 `-callTree` 擷取慢很多（open-SUI 一發 ~160s vs AS ~30s），且 session 拖長後 physical peak 衝到 4.2GB（stack-log history 累積）——full stack logging 下勿讓 process 長活，capture 完即關（Intel 尤甚）。

### 附錄四補：系統高壓（UE5 3A 遊戲運行）下之對照量測（2026-09-04）

**情境**：鳴潮（native Mac、UE5）運行中（~2.5GB RSS／CPU ~148%，系統 compressor ~1.87GB stored）；同機 vChewing IME process 未被 kill、idle 4h 後選單讀數跌回 ~62MB。於此壓力下以**不開 MallocStackLogging** 的一般 telemetry serial round 重跑 vChewingDebuggable。

**對照表**（MB；「無壓力」＝同日 16:58 clean round）：

| 階段 | 壓力下 internal / inUse / allocated / heapBytes | 無壓力 internal / inUse / allocated / heapBytes |
|---|---|---|
| baseline | 52.6 / 26.4 / 68.8 / 28.3 | 57.8 / 27.1 / 72.8 / 29.0 |
| open SUI | 195.9 / 99.4 / 162.3 / 125.1 | 196.7 / 100.6 / 154.1 / 126.2 |
| close SUI | 120.5 / 46.7 / 161.9 / 49.7 | 118.1 / 48.8 / 153.7 / 50.1 |
| open Cocoa | 148.6 / 75.8 / 173.4 | 167.3 / 76.3 / 169.2 |
| final | 109.7 / 48.8 / 177.4 / 51.8 | 109.6 / 49.4 / 169.2 / 52.3 |

**結論**：
1. 系統高壓對本量測協定**幾乎零影響**（inUse 差 <1MB、heapBytes 差 <1MB、final internal 109.7 vs 109.6）；allocated ratchet（zone 保留）與殘留照舊。
2. IME 跌回 62MB 與此不矛盾：IME **idle 4h、頁面全冷**，壓力下 kernel 將冷頁壓縮/換出（writable resident 62.6MB、swapped 54.7MB），但 **live malloc 仍 76.4MB allocated、只是不在 resident**（會隨使用 fault 回來）。量測當下 debuggable 頁面全熱、kernel 不壓熱頁 → 數字不變。
3. 即：壓力回收的是「冷頁的 resident 狀態」，不是 allocator 的 logical 保留；allocated ratchet 與框架地板在任何情況下都搬不走 → **vChewing 側再無優化餘地**（與 §5-H1/H2 判定一致、經跨架構/跨 OS/跨壓力三向驗證）。

### 附錄五補：被否決的記憶體優化途徑（架構級評估，2026-09-04）

針對「降低設定窗記憶體」所評估的替代架構，全部**否決**；記錄理由供日後不再重蹈：

1. **LibSDL 重寫設定窗（整窗當遊戲畫面）**：無效。量測顯示要替換的 widget 層僅 vChewing-pane 0.26MB＋AppKit controls 1.8~4.6MB；開窗 +140~150MB 的 95% 在 SwiftUI runtime／CA Render shmem／GPU surface／text/CG/plist／Swift metadata——SDL 避不掉，且 zone ratchet 是 allocator 行為與 toolkit 無關。文字/i18n CJK fallback、PhraseEditor 的 NSTextView 級編輯（undo/IME marked text）、Accessibility 全要重造，自建 glyph cache 通常比 CoreText 共享 cache 更肥。「不用 SwiftUI」的 premium 已由 SettingsCocoa 兌現（真實 IME：SUI 205 vs Cocoa 144 首開／144 vs 112 殘留）。
2. **獨立 settings.app（跨 process 設定窗）**：sandbox 下不可行——security-scoped bookmark 綁 creator 的 code signature，獨立 app（不同 bundle id）無法 resolve，需各自 Powerbox 授權；且把專案釘在 Developer ID／entitlements 基建，喪失 FOSS「誰都能 compile」自由。
3. **同 bundle 內嵌 XPC service**：sandbox 面可行（同簽名、同 container、bookmark 可經 app group 共用），但仍要求 signing/entitlements 設定（多一份 binary＋profile），FOSS compile 門檻同 2。
4. **同 bundle buddy executable（IME spawn 的 sibling Mach-O，同 container）**：最輕的分離形態——child 繼承 sandbox、同 container（預設資料夾免 bookmark）、自選資料夾 bookmark 因同簽名可 resolve、仍是一顆 .app 一份簽名（不新增 Developer ID 義務）。代價：手寫 IPC／生命週期／crash 處理、視窗 activation 語意跨 process、`PrefMgr` 即改即生效要序列化；記憶體只是搬家（IME 選單數字降、系統總成本不變）。
5. **設定窗 web 化（IME 內建 web server／單一 WKWebView）**：rendering 由 WebKit 自動移到 WebContent process（IME 數字降）——但 WebKit framework 首次載入會在 **IME process 永久新增一層 one-time 地板**（機制同 SwiftUI 的 +22MB，WebKit 更大）→ post-close 殘留不降反升，與目標相反。另有 bridge（NSOpenPanel／拖放／PhraseEditor／PrefMgr didSet 回推）、安全（勿開 socket，應用 `WKURLSchemeHandler`）、以及 **legacy 兩倉鏡像裂開**（macOS 10.9 無 WKWebView）三大成本。

**共同結論**：記憶體住在 framework／allocator／rendering 層；所有「換渲染宿主／搬 process」都只是選擇「哪個 process 扛＋是否多疊一層永久地板」，無免費午餐。vChewing 側無 allocation 可省之結論（主文 §5 與附錄一~四）維持不變。

### Follow-ups

- 未具名/non-object 桶（關窗後仍 ~14MB）以 malloc stack logging 定位（本報告 §6-E3 的實作路徑）。
- 每輪結束 `resetUnitTestSandbox()` 未呼叫，`$TMPDIR/vChewing-UnitTests/` 會累積 per-process 暫存目錄（不影響量測數值，可於宿主退出時清理）。
