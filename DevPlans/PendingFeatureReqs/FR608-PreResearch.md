# FR608（FeatureRequest）手術前調查報告：連續鍵入錯誤自動切換英數模式（Auto-Switch to Alphanumerical on Consecutive Typing Errors）

> **文檔狀態**：PreResearch（**FR608（FeatureRequest）**；「產品需求固定」暫緩——Customer 暫以自家 branch 實機試用一週，反饋後再議。非實作藍圖）
> **狀態補充（2026-09-07）**：Customer 自評其 branch——① 中文忘切回（中文模式打英文）已解；② **英文模式下打中文未解**；③ **誤鍵過多致轉英文、需刪除重打**之誤切情境未解。本文件因此降級為 FR608，§二／§五 之需求內容待其實測反饋。
> **前置**：Phase 192（v4.7.3 SP1）
> **文檔脈絡**：本文件由 PullReq608 逆推而來。事主裁示該 PR 不收，本文件僅固定「該 PR 贊助者（下稱 Customer（客戶））原本想要的**產品需求**」，並附上事主已裁示的設計約束；**實際實作不得照搬該 PR 的邏輯**。
> **範疇**：vChewing-LibVanguard（Tekkon／LexiconKit／TrieKit 上游）、vChewing-macOS、vChewing-OSX-Legacy、vChewing-VanguardLexicon（資料面，視需要）。

---

## 一、背景：本功能想解決的產品問題

使用者處於**中文打字模式**（注音排列，繁體或簡體皆然）時，若實際上在鍵入英文／英數文字（例如 `cd ..`、`ls -la`、`git log`、路徑、網址、縮寫），目前會遭遇：

1. 英文按鍵序列被當作注音鍵位吸收，組字區出現破碎的注音或錯誤候選。
2. 使用者得手動切換輸入法（英數／中文），中斷打字節奏。

**產品期望**：輸入法能**偵測「使用者明顯在打英文／英數」的連續輸入**，累積達門檻後**自動把這段英數字串一次完整遞交、並將輸入切換到系統英數輸入源**，無需使用者手動切換。產品體驗基準為**仿華碩智慧輸入法（ASUS Smart IME）**的注音／英文混合智慧辨識——「連續誤鍵達門檻時自動轉 ABC 模式並送出英數字」。（此為 PullReq608 標題與內文所述之原始動機。）

**功能家族定位**：本功能屬 **MixedAlnum（中英混打）功能家族**——與「手動分流」（注音槽與 ASCII buffer 並存、按 Space 遞交）同為「在中文模式下輸入英數」的手段：前者**手動**、本功能**自動切源**。兩者共用同一處理路徑（注音 bopomofo keyblock）與設定區位，**開關應與 MixedAlnum 開關同列於「行為設定」頁、同一 Section**（見 §三）。

---

## 二、產品需求（功能本體）

### 2.1 核心功能

在**注音（bopomofo）鍵盤排列的打字路徑**（涵蓋繁體與簡體中文模式，見 §2.2）且**英數模式（isASCIIMode）未啟用**時，若同一輸入 session 內連續出現「無法被解析為**適用讀音**（applausible reading）的按鍵」，則：

- 累積到**閾值（threshold）**個連續按鍵錯誤後，將這段連續按鍵所代表的**英數字串**（含期間的字母、數字、標點、Space）**一次完整遞交**。
- 遞交後**自動切換到系統英數輸入源**（見 §4.3：切源目標不得假設為美規 ABC）。
- 若切換失敗，則**退回自身英數模式**（isASCIIMode = true），確保英數字串不被注音誤吞。

**承接優先序（與手動分流的關係）**：當 `kMixedAlphanumericalEnabled`（手動分流）啟用、且按鍵正被其 ASCII buffer 承接時，該按鍵**不會被注音誤吞**——自動切源的觸發前提不成立，故**不計數、不觸發**。兩機制同屬 MixedAlnum 家族（共用判定基礎與注音處理路徑），以「誰承接按鍵」自然分流，而非以 `!mixedAlphanumericalEnabled` 條件閘互斥（後者為 PullReq608 之缺陷，見 §七）。此承接優先序確保兩開關並存時，手動分流工作流不被自動切源劫持。

### 2.2 適用範圍（實作派遣——已核實的執行事實）

**先釐清兩個正交軸**：vChewing 的「輸入法模式（繁體／簡體）」與「鍵盤排列（注音／拼音）」彼此獨立。**簡體中文模式也能使用注音排列**——支持原生簡體中文注音打字是唯音輸入法的使命之一。因此「簡中」≠「拼音」。

`InputHandler_HandleComposition.swift` 依 `typingMode` 派遣；`typingMode` 由 `cassetteEnabled`、狂拼開關（`furiousTypingEnabled && !useSCPCTypingMode`）、與 `composer.isPinyinMode`（鍵盤排列 parser ≥ 100）共同決定（見 `InputHandler_TypingMode.swift`）：

| typingMode | 判定 | 派遣 |
|---|---|---|
| `.bopomofoKeyblock` | 注音排列（parser < 100），**繁／簡中文模式皆然** | 連續錯誤判定 → `mixedAlphanumericalEnabled` 時走 `MixedAlphanumericalTypewriter`，否則 `BPMFFullMatchTypewriter` |
| `.pinyinKeyblock`／`.pinyinFuriousTyping` | 拼音排列（parser ≥ 100） | **直接 `BPMFFullMatchTypewriter`，不進混打／自動切源路徑** |
| `.cassette` | 磁帶／自訂鍵盤 | `CassetteTypewriter`，不在本功能作用域 |

結論：

1. **本功能作用域 = 注音（bopomofo）打字路徑，繁／簡中文模式都涵蓋**。
2. **拼音排列的打字路徑不受本功能影響**——pinyin keyblock 根本不進 MixedAlnum 路徑（現行分派下 pinyin 鍵路徑恆走 `BPMFFullMatchTypewriter`；縱有路徑進入 MixedAlnum handler，其內部 `!composer.isPinyinMode` guard 亦立即轉交 BPMF，等效不處理）。事主裁示：**拼音打字路徑長期不實作此類自動切源**（成本過高；搜狗／微信等中國內地大廠拼音輸入法皆未實作，見 §六）——本排除為範圍決定，非技術暫缺。
3. **注音鍵盤映射按美規（US）佈局鍵位定義**（keyCode 制）。因此注音路徑對鍵位一律以 US 映射處理是正確的設計，不是佈局假設問題；「不得假設美規 ABC」的約束（§4.3）只針對**自動切源要切到哪一個英數輸入源**，與注音鍵位映射無關。註：本功能**遞交的英數字串**是「使用者眼中的英文字」而非注音——鍵訊在進入 FSM 前已被轉譯為 US 字元（`InputSession_HandleEvent` 的 `layoutTranslated`），故遞交映射**遵從輸入法的「基礎鍵盤佈局」（`kBasicKeyboardLayout`）**：以捕捉到的鍵位（keyCode）依該佈局渲染遞交字元；**當且僅當基礎鍵盤佈局不是英數類鍵盤佈局**（例如 Apple 注音硬件佈局 `com.apple.keylayout.ZhuyinBopomofo`（大千傳統）／`ZhuyinEten` 等、`LatinKeyboardMappings` 無對應者）**時，才自動退回美規（US）映射**——與既有 `LatinKeyboardMappings(rawValue: basicKeyboardLayout) ?? .qwerty` 語義一致（預設 `ZhuyinBopomofo` 即走美規）。此規則與現行手動分流路徑（遞交 layout 轉譯後之 US 字元）不同；手動分流是否一併遵從，屬本需求範圍外（見 §六）。

### 2.3 「連續鍵入錯誤」的判定

判定單一按鍵是否為「錯誤鍵」（代表使用者偏離中文、意圖輸入英數）時，**唯一權威來源是當前載入的 Lexicon（LMAssembly）所給出的「適用讀音集合」**（見 §4.1，即「Tekkon 不能替 Lexicon 擦屁股」的核心原則），而非任何靜態、寫死於 Tekkon 的音節集合。

**判定對象（本版釐清）**：此處判定的對象是**自最近一次重置以來、連續鍵入的「原始鍵串」**（按鍵入順序映射成的注音鍵序），**不是注拼槽（composer）的即時狀態**。原因是 Tekkon 注拼槽對同類注音符號採**覆寫**語義（後鍵覆寫前鍵，見 `Tekkon_SyllableComposer.receiveKey`）——若以槽狀態判定，「cd ..」這類英文鍵串會因覆寫出單一合法前綴而永遠不構成錯誤、無法觸發；唯有以原始鍵串判定，「重複／越位覆寫聲介韻調槽」等情形才可被偵測。

判定的二元輸出：

- **繼續中文輸入**：本鍵併入原始鍵串後，該鍵串仍可能是某個**存在於 Lexicon 適用讀音集合**的讀音或其合法前綴——即「此序列仍可能成為一個適用讀音」。
- **按鍵錯誤**：本鍵併入後使鍵串不再可能成為任何適用讀音或其前綴（例如：重複／越位覆寫聲介韻調槽、破壞槽位順序、非該鍵盤排列的鍵、在未啟用前置聲調時鍵入聲調等），視為一次「錯誤」。

**計數語義**：未出現錯誤鍵的合法注音鍵段**永不計數**；一旦鍵串出現首個錯誤鍵，計數對象即為**該段未遞交鍵串的整體長度**（自重置後首鍵起算、含錯誤發生前的按鍵），達閾值即以整段鍵串作為英數字串遞交（DoD1 之 `cd ..`＝5 鍵即以此語義於 threshold 5 全段觸發）。成功的注音確認（聲調鍵／Space 確認讀音／Enter）與 §五 DoD4 之重置鍵皆重置計數。計數／邊界細節（含 Space、以及大千系排列中同時為注音韻母鍵的 `,` `.` `/` `;` `-` 在錯誤段內的捕捉歸屬、達閾值當鍵與其後按鍵的去向）見 §六。

關鍵取捨（產品必須）：

1. **適用讀音集合是動態的**：包含原廠 TextMapTrie 載入時的讀音集合，**也包含使用者片語 Lexicon 新增的讀音**——使用者自行加詞產生的新讀音，同樣算「適用讀音」。
2. **前綴平穩性**：只要序列仍是「某個適用讀音的前綴」，就**不應**視為錯誤，避免在合法中文輸入中途誤切英數。
3. **模式感知**：以**當前載入辭典（繁或簡）的適用讀音集合**為準。繁／簡辭典的讀音集合不同，唯有 Lexicon 能依當前模式正確給出——這正是 §4.4「簡中（含簡中注音）適用」之所以必須依賴 Lexicon 判定的原因。

### 2.4 遞交後的行為（session 層）

- 遞交完成後，「後續按鍵由誰接收」依 §4.5 的落地方式而定：
  1. **內部英數落地**（唯音續留 active）：以既有英數模式（`isASCIIMode = true`）透傳按鍵，直到使用者以自身機制切回中文或本 session 被 deactivate。
  2. **系統輸入源落地**：啟動使用者偏好的系統拉丁輸入源後，唯音隨之 deactivate，其後按鍵自然由該輸入源接收，直到使用者以慣用機制（如 CpLk）切回。
- 下次 vChewing 被重新啟用（reactivation）時，若前次是因自動切源而離開中文模式，應**自動恢復為中文模式**，不殘留 ASCII 狀態。註：現行 `performServerActivation()` 並無此「回切中文」邏輯（僅採納 `IMEApp.currentInputMode`）——此語意屬淨新增；PullReq608 曾以 `performServerActivation()` 實作該語意，事主認為可接受、可保留，但實作面須按 §4.2／§4.5 重構。

---

## 三、功能開關與選項（Shared 層）

事主裁示：「Shared 層面的開關新增有些道理，暫不予否定；但內容還需研判。」故以以下為**需求建議；開關預設值經事主裁示為關閉（`false`），threshold 待研判**：

| UserDef key | 型別 | 建議預設 | 語意 |
|---|---|---|---|
| `kAutoSwitchToAlphanumericalOnConsecutiveErrors` | Bool | `false`（已裁示） | 總開關：啟用「連續鍵入錯誤自動切換英數」。 |
| `kConsecutiveTypingErrorsThreshold` | Int（3–8） | `5`（待研判；與 Customer（客戶）之實作預設一致） | 觸發切源的連續錯誤鍵數門檻（最小值 3）。 |

- 開關應同時在 `PrefMgrProtocol`／`PrefMgr_Core` 界接（Preference 屬性），與其它 `k...` 開關一致。
- **預設值（事主已裁示為 `false`）**：PullReq608 的 PR 內文載明「預設關閉（`defaultValue = false`），100% 保持向後相容」，但其後續 commit（`34621edb`）已把預設翻成 `true`——PR 內文與最終程式碼**不一致**。本次裁示採 PR 內文之向後相容主張（`defaultValue = false`）；PR 後續 commit 翻 `true` 之行為不得沿用。
- **設定 UI 位置（事主裁示）**：「行為設定」頁，與 `kMixedAlphanumericalEnabled` 同一個 Section。現況查核：macOS SwiftUI `VwrSettingsPaneBehavior.swift:29-31` 與兩倉（macOS／OSX-Legacy）AppKit `VwrSettingsPaneCocoaBehavior.swift`（Section 約 65-70 行）皆為「僅含 MixedAlnum 一個開關」的獨立 Section，可直接同列。**不得**放在「一般設定（General）」頁。
- 需提供四語（zh-Hant／zh-Hans／ja／en）的 `shortTitle`／`description` 文案（l10n）。

---

## 四、設計約束（事主裁示的原則，先決於需求）

以下為事主對 PullReq608 的否決理由所提煉出的**硬性原則**。實作必須遵循；任何偏離都應視為偏離產品需求。

### 4.1 「適用讀音」由 Lexicon（LMAssembly）給出，Tekkon 不得代勞

- 判定「哪些讀音是適用讀音（applausible）、哪些不是」，權威來源是 **Lexicon（LMAssembly）層**。
- **VanguardLexicon 的 TextMapTrie 格式在載入時即應能夠給出適用讀音集合**；使用者片語 Lexicon 若有添入新讀音，也能擴充此集合。
- **Tekkon 不得為此新增靜態資料**（例如 PullReq608 新增的 `allValidMandarinSyllables` 硬編碼集合，見 `vChewing-macOS/Packages/vChewing_Tekkon/Sources/Tekkon/Tekkon_Constants.swift`）：Tekkon 的 Static Data 已足夠多，構成建置時 LSP 分析負擔；且該集合**無法反映當前載入辭典（繁或簡）與使用者片語的實際讀音**。

### 4.2 邏輯集中於 Typewriter（MixedAlnum）層，InputHandler Protocol 保持乾淨

- 自動切源（及相關判定／遞交）邏輯應**集中處理於 MixedAlnum 家族層**——`Typewriter_MixedAlphanumerical.swift`（及其支撐型別）。註：現行分派僅於 `kMixedAlphanumericalEnabled` 啟用時將 bopomofo keyblock 送入該檔，否則走 `BPMFFullMatchTypewriter`（見 §2.2）；故自動切源若欲服務「手動分流未啟用」的預設路徑，分派須令 bopomofo 路徑在家族任一開關啟用時進入家族處理入口（該檔需支援未啟用手動分流的操作模式），或於 BPMF 路徑掛接偵測——確切落點屬實作決策（見 §六），然無論何者，InputHandler Protocol 不得為此擴張 transient 狀態。
- **犯不著給 InputHandler Protocol 施加太大壓力**：PullReq608 直接在此 Protocol 上新增 `consecutiveTypingErrors`、`inFlightComposerKeys` 兩個 transient buffer（見 `InputHandler_CoreProtocol.swift`、`InputHandler.swift`），並在 `clearComposerAndCalligrapher()`、`InputHandler_TriageInput.swift`、`Typewriter_BPMFFullMatch.swift` 散落清除。此做法使 Protocol 特性面擴張、FSM 狀態與 handler 生命週期耦合過深。
- 應**調整 InputHandler Protocol 自身的 properties 種類使其更整潔**：把上述 transient FSM 狀態收進 Typewriter 層級（獨立於 handler 的私有狀態／值型別），不污染共享 Protocol。

### 4.3 自動切源落地不得假設美規 ABC 鍵盤佈局

- 本約束只涉及「**切到哪個英數輸入源**」的落地選擇，與注音鍵位映射無關（注音映射本就是美規鍵位制，見 §2.2）。
- PullReq608 的 `IMKUtils/TISInputSourceExtension.swift::selectSystemABCInputSource()` 依序嘗試：現行 ASCII-capable 輸入源 → `com.apple.keylayout.ABC` → 任一非唯音 ASCII 源 → 未啟用之 `ABC`。雖會先試現行 ASCII 源（未必是 ABC），但**未依 `kAlphanumericalKeyboardLayout`／`allowedAlphanumericalTISInputSources` 白名單選源**，對預設僅有 ABC 的使用者淨效果仍＝強制美規 ABC。使用者打字時的英數輸入源可能是 QWERTZ／AZERTY／JIS 等（如小麥注音的 Lukhnos Liu 用 QWERTZ）。
- **應尊重使用者實際的英數鍵盤佈局偏好**（對應既有的 `kAlphanumericalKeyboardLayout`／`allowedAlphanumericalTISInputSources` 機制）。切源目標應是「使用者偏好的英數輸入源」，而非硬編碼 ABC。

### 4.4 必須涵蓋簡體中文（含原生的簡體中文注音）

- **簡體中文模式也能用注音排列**（bopomofo keyblock）——這是唯音的原生使命之一。本功能作用域是「注音打字路徑」，因此**繁、簡中文模式都應涵蓋**，不應以 `.imeModeCHT` 把關把簡中排除。
- PullReq608 的 `handleConsecutiveTypingErrorsSwitchIfNeeded()` 以 `session.inputMode == .imeModeCHT` 把關，等於把「簡體中文注音」排除在外 → **錯誤**。功能應以「注音排列路徑」為準（繁簡皆然）；拼音排列路徑本就不進混打路徑，維持不觸發即可。
- 此點再次凸顯 §4.1「Tekkon 不能替 Lexicon 擦屁股」：簡中辭典的適用讀音集合與繁中不同，唯有 Lexicon 能正確給出。

### 4.5 必須涵蓋「只用系統 CpLk 切換中英文輸入源」的使用者（不得以 `isASCIIMode` 作為「英數模式」的唯一定義）

- **系統存在兩種互不相關的「中／英」切換模型**：
  1. **模型 1——唯音內部英數模式**：`isASCIIMode = true` 時，唯音**仍 active**、只在內部以英數模式透傳 ASCII。此旗標僅能經 Shift 切換（`toggleAlphanumericalMode`）、JIS 鍵盤英數鍵（Eisu）、或唯音自身 CpLk 處理（系統 CpLk 輸入源切換**被關閉**時）被設為 true。
  2. **模型 2——系統 CpLk 輸入源切換**（macOS「用 Caps Lock 在輸入法間切換」）：按 CpLk 時系統**直接換掉整個輸入源**——進英文時唯音被**完全 deactivate**、按鍵送至系統拉丁輸入源，「英文」狀態根本不反映在 `isASCIIMode` 上。故對**只用系統 CpLk 切換中英**的使用者（非 JIS 鍵盤）而言，`isASCIIMode` 永遠 false、**從無 on 的機會**。（切源時由 IMK 以 `commitComposition`→`deactivateServer` 處理、唯音即刻 deactivate——機制已確認，見 §六。）
- **PullReq608 的缺陷**：其自動切源邏輯（觸發、遞交後狀態機、`performServerActivation` 以 `isASCIIMode` 重置回中文、`isPassThroughUntilDeactivated` 透傳）**完全建立在模型 1（`isASCIIMode`）上**，等同無視模型 2 的使用者。「切英文」的結果被描繪成「設 `isASCIIMode = true`」，對系統 CpLk 使用者是錯誤語義——他們要的是**實際把輸入源換到系統拉丁鍵盤、之後仍用系統 CpLk 切回**。
- **產品要求**：本功能必須兼容兩種切換模型，且**不得以 `isASCIIMode` 作為「使用者處於英數」的判準**：
  - 觸發時機僅在「唯音 active 且正接收中文模式按鍵」——這對兩種模型皆成立（即「使用者忘了切換、直接在唯音裡打英文」）。
  - **落地方式依使用者的慣用回切機制二選一**（不得一律 OS 切源、也不得一律內部英數——兩者各會破壞另一模型使用者的回切習慣）：
    1. **系統 CpLk 使用者**：落地＝**真實啟動**使用者偏好的系統拉丁輸入源（尊重佈局，見 §4.3；啟動後唯音 deactivate、按鍵自然由該源接收），其後以 CpLk 切回；切源成功後**不得殘留**與系統 CpLk 語義衝突的狀態（例如 vChewing 保持 active 且 `isASCIIMode = true`、或 pass-through 吞掉 CpLk 回切鍵）。
    2. **唯音內部英數使用者**（Shift／Eisu／內部 CpLk 切換者）：落地＝**設 `isASCIIMode = true` 續留內部英數**（不啟動他源），以自身機制（Shift 等）切回即復位中文。
  - 落地方式的**判別訊號**只能是唯音**自身可觀察**者：是否 JIS 鍵盤、`kBypassNonAppleCapsLockHandling`、本 session 是否曾以內部機制切換、以及「按 CpLk 後唯音是否遭系統 deactivate」等行為觀察。macOS **無公開 API** 可供查詢「系統 CpLk 切源」開關，且 App Sandbox 不允許讀取該系統偏好網域（即使知道其 userdefaults domain／key 亦然）——**不得以系統開關狀態為判準**。判別訊號之選定需於手術前定案（見 §六）；模型 2「切源即遭系統 deactivate」之前提已由事主確認（機制：IMK `commitComposition`→`deactivateServer`）。

---

## 五、驗收準則（Definition of Done）

以下為「功能正確性」層面的驗收要點；測試策略本身另列於 §六。

1. **含式閉環**：注音模式（繁或簡）輸入一段連續英文（如 `great`、`cd ..`、`ls -la`），累積達門檻後整段英数字串被完整遞交、並已切至系統英數輸入源。
2. **前綴不誤傷**：合法中文輸入過程中，只要序列仍是某適用讀音的前綴，就**不觸發**切源。
3. **非錯誤情境不受干擾**：合法中文輸入不誤切——例如 `su3` 正常輸出「你」；未被當前注音排列吸收為注音鍵的標點鍵（如 `[`／`]`／`\`／`=`）單獨按下時維持既有中文全形標點輸出（「」、、—、＝）。註：部分排列把 `-`／`,`／`.`／`/`／`;` 映射為注音韻母鍵（ㄦ／ㄝ／ㄡ／ㄥ／ㄤ），此類按鍵在該排列下屬注音鍵、不適用全形標點清單——本條之具體按鍵集合依排列而定，驗收時須以實際排列對照（此為 PullReq608 實機測試載明的回歸案例之一般化）。
4. **取消／邊界鍵**：Enter／Tab／Esc／Backspace／方向鍵／功能鍵等**不計入錯誤數**，且應重置連續錯誤累積。
5. **繁簡皆適用**：繁體注音與**簡體注音**（CHS + 注音排列）皆可觸發、判定準確；拼音排列打字路徑不觸發（見 §2.2／§4.4）。
6. **佈局落地正確**：使用者英數輸入源為 QWERTZ／AZERTY／JIS 時，切源目標是**使用者偏好的英數輸入源**而非美規 ABC（§4.3）；**遞交字元映射遵從「基礎鍵盤佈局」**——英數類佈局（QWERTZ／AZERTY…）遞交該佈局字元；Apple 注音類佈局（如大千傳統）則退回美規字元（見 §2.2 結論 3）。
7. **遞交後回切（兩種切換模型）**：自動切源後「回中文」與使用者慣用機制一致——① 唯音內部英數使用者以自身機制（Shift 等）切回、`isASCIIMode` 正確復位；② 只用系統 CpLk 的使用者切源後實際落在系統拉丁輸入源、以 CpLk 切回即恢復中文，且不殘留衝突的 `isASCIIMode`／pass-through 狀態。（見 §4.5）
8. **使用者詞彙**：使用者片語 Lexicon 新增的讀音應被視為「適用讀音」而不誤判為錯誤。
9. **與手動分流並存**：`kMixedAlphanumericalEnabled` 與自動切源同時啟用時，鍵入英數由手動分流承接、自動切源不計數不觸發（見 §2.1）；手動分流關閉時自動切源照常運作。

---

## 六、範圍之外／待研判

> **收斂註記（2026-09-06）**：本節已依 **Customer（客戶）**（即 PullReq608 之 PR 提出者，見首段定義）之實作 branch `feat/smart-zh-en-auto-switch` 複核。該 branch 代表「Customer（客戶）自認的 expected behavior」，**僅作行為基準參考——實作仍不得照搬**（§四 約束與 §七 差異對照仍為準；其最終將開關預設翻 `true` 之 commit 亦不隨之，§三 已裁示 `false`）。標 **【已收斂】**：以該 expected behavior 為基準已可定案或大幅收斂；標 **【仍待…】**：需外部實測／事主裁示。

**【已收斂——以 Customer（客戶）之 expected behavior 為基準】**

- **計數／邊界語義（原「待 ASUS 實測」項，收斂為體驗校準）**：Customer（客戶）之行為基準已確認、且與 §2.3「計數語義」一致——① 錯誤鍵累積 ≥2 後，其後 Space 與標點（含大千系亦為注音韻母鍵的 `,` `.` `/` `;` `-`）一律**捕捉入英數字串**、不再被注拼槽吸收（`cd ..`／`sudo `／`git log` 皆以此運作）；② 達閾值當鍵即為第 threshold 鍵並納入遞交，其後按鍵（如 `git log` 第 6 鍵起）以 pass-through／切源後輸入源承接；③ 注拼槽為空時的首鍵永不判錯、且**錯誤發生前的合法前綴鍵全數計入**（長前綴＋單一錯誤可一次達標）。threshold 實作預設 5、可設 3–8，與 §三 建議一致。ASUS Smart IME 之 Windows 對照**降級為「手感／體驗校準」（非定案必要）**；若事主仍要實測比對再補。
- **狂拼／符號輸入等其它入口（收斂）**：已確認——詞庫有定義的標點／符號鍵與符號選單實體鍵，於非錯誤段不計錯並重置（`[` 單按仍輸出「」全形，DoD3）；狂拼／拼音屬拼音路徑、本就排除（§2.2）。原「需另行研判」無需另列。
- **與 MixedAlnum 的關係（DoD9 觀察等價）**：Customer（客戶）以 `!mixedAlphanumericalEnabled` 硬閘將自動切源整個關閉（§七 缺陷）；其觀察結果（manual 啟用 → 不觸發，測試 `MixedAlphanumericalIgnored`）與 §2.1 承接優先序／DoD9 一致。判定基礎共用與否仍屬實作決策（§4.2）。
- **自動切源於 bopomofo 路徑的掛接點（收斂為入口確定）**：Customer（客戶）將偵測掛於 `handleComposition` 之 `.bopomofoKeyblock` 分派最前（BPMF／MixedAlnum 之前）——確認**偵測入口必在任何注音吸收之前攔截原始鍵**（與 §4.2 註之分派調整一致）；惟其實作將 transient 狀態放 Protocol buffers、於 BPMF／triage／`clearComposerAndCalligrapher()` 散落清除（§4.2 缺陷）——結構仍須收進 MixedAlnum 家族層，屬手術規劃事項。
- **遞交映射（已裁示）**：自動切源之遞交字元遵從「基礎鍵盤佈局」，僅在基礎鍵盤佈局非英數類（Apple 注音類佈局）時退回美規——見 §2.2 結論 3／DoD6。現行手動分流路徑遞交的是 layout 轉譯後之 US 字元、與本規則不同；手動分流是否一併遵從，屬本需求範圍外，另議。
- **拼音排列打字路徑之自動切源（已裁示：不實作）**：事主裁示（Customer（客戶）亦排除）——**拼音打字路徑斷然不實作此類「熱切源」**，成本過高；此需求雖確實存在，但若可行，搜狗／微信輸入法早已支持——訊飛、豆包等語音輸入法皆已問世，中國大陸大廠仍無任何一家拼音輸入法實作此功能（RIME 亦然，目前尚無人提出可行方案）。本排除為**長期範圍決定**，不列為待議延伸（§2.2 結論 2）；日後若環境條件改變，需另起爐灶、另行設計。

**【仍待外部實測／事主裁示】**

- **觸發當下「未遞交組字內容」之處置（ASUS 實測指向「並存待使用者確認」；確切規則待事主裁示）**：Customer（客戶）之行為＝**直接捨棄**（`assembler.clear()`，僅遞交錯誤鍵串；測試 `PriorAssemblerContentDiscarded`）。**ASUS 實測（事主於 Windows 確認，2026-09-06／09-07）**：① `u. great` → preedit `優great`、未遞交、未捨棄（與唯音 MixedAlnum 手動分流一致）；② `u. greate` → preedit `優greate`（尾鍵 e 灰色保留、注拼槽 `ㄍ` 並存、英文關聯提示 `r`＝疑打 "greater"）；③ `u. great!` → preedit `優great!`、committed 仍為無——連明確邊界「!」都只是併入英數段、不觸發遞交。結論：**ASUS 於組字區已有未遞交中文時，不捨棄、不自動遞交、不切源，一切並存、待使用者以確認鍵遞交** → Customer 之「捨棄」及「遇標點即 flush」均與 ASUS 基準相悖、不予沿用；三種候選處置（捨棄／先遞交再切源／並存待確認）中以**並存**為準。唯音在「手動分流關閉」下無並存能力，manual-off 之確切處置（並存呈現、確認鍵行為、或改由家族處理承接）仍待事主裁示並補進 DoD（支持 §4.2「集中於 MixedAlnum 家族層」）。註（英文 lexicon 依賴，不列入 FR608）：上述 ② 之尾鍵歧義灰色保留與英文關聯／完成提示，乃至 ASUS 英數段之詞級決策，均以其**內建英文 lexicon** 為輔助；唯音**沒有英文 lexicon**，此類行為在唯音上不可行、亦非 FR608 所能補——若要追齊需另立「英文詞庫／英文關聯提示」需求。故 **FR608 之偵測不得假設有英文詞級資訊**，只能以「連續鍵入錯誤」之啟發式為之（§2.3）。「! 不作遞交邊界」是否亦依賴英文 lexicon 尚不確定；唯音 MixedAlnum 現況於 `!` 會 flush 已組內容並輸出全形 `！`，該差異不列入 FR608。
- **落地選模（OS 落地機制已確認；依慣用回切機制二選一待事主裁示）**：Customer（客戶）之落地語義已確認＝**OS 切源優先**（TIS `selectSystemABCInputSource`：現行 ASCII-capable 源 → `ABC` → 任一非唯音 ASCII 源 → 未啟用之 `ABC`）＋失敗退內部 `isASCIIMode`＋pass-through 至 deactivate（≤2 秒窗口）＋reactivation 自動回中文。**OS 落地之 deactivate 機制（事主已確認）**：切源至英文時，IMK 會呼叫 `commitComposition` 後 `deactivateServer`——唯音**即刻 deactivate**；介於 TIS select 與 deactivation callback 之間的 pass-through 窗口僅涵蓋該極短暫區間，其中間流程細節需對 IMK 逆向工程。此「一律 OS-first」對模型 2（系統 CpLk）使用者相容，但**未依 §4.3 白名單／`kAlphanumericalKeyboardLayout` 選源、且模型 1（唯音內部英數，Shift／Eisu）使用者會被 OS 落地而失去自身回切機制**——§4.5「依慣用回切機制二選一」及其判別訊號仍待事主裁示（系統 CpLk 切源開關狀態仍不可查：無公開 API、沙盒不允許讀其偏好網域）。
- **單元測試策略（待事主指示）**：Customer（客戶）之 534 行測試（`InputHandlerTests_AutoSwitchOnErrors.swift`；情境：`great`／`cd ..`／`sudo `／`mkdir`／`git log`／`su3`＋`cl3` 不觸發／Backspace 重置／threshold 3／CHS 不觸發／拼音不觸發／manual 啟用不觸發／前組字捨棄／`[` 全形／切回唯音即中文／切源失敗退 ASCII；另有 `MainAssemblyTests_Test5.swift::test508`）可作 **DoD／測試情境種子**——惟其中「CHS 不觸發」與 §4.4 衝突、不得沿用；其餘斷言標的（Protocol transient buffers、`InputSession.isAutoSwitchedToABC` static、pass-through 旗標、mock session `inputMode`）隨 §4.2／§4.5 重構而需重寫，**不得照搬**。
- **「前綴可成為適用讀音」的判定成本（實作研究）**：逐鍵查 Lexicon「是否存在以該前綴開頭的讀音」需權衡效能；如何以 Lexicon 的載入期適用讀音集合（或等效索引）**近 O(1) 判定**，屬實作層面研究重點，不在本產品需求範圍內拍板。註：Customer（客戶）以 Tekkon 靜態全音節核心集合判定（`allValidMandarinSyllables`，§4.1 違反），未能提供 Lexicon 權威版本之成本方案。

---

## 七、附註（逆推來源：PullReq608 的關鍵差異，勿照搬）

以下記錄 PullReq608 實際動的手術，作為「為何不收」的對照，避免未來重蹈覆轍：

- **Tekkon**：新增 `Tekkon.allValidMandarinSyllables`（硬編碼注音音節集合）→ 違反 §4.1（適用讀音應由 Lexicon 給出）。
- **Typewriter InputHandler**：Protocol 新增 `consecutiveTypingErrors`／`inFlightComposerKeys`，並在 `InputHandler_CoreProtocol.swift`、`InputHandler_TriageInput.swift`、`Typewriter_BPMFFullMatch.swift`、`clearComposerAndCalligrapher()` 散佈清除與判定 → 違反 §4.2（應集中於 MixedAlnum 層、Protocol 保持整潔）。
- **IMKUtils**：`TISInputSourceExtension::selectSystemABCInputSource()` 未依 `allowedAlphanumericalTISInputSources` 白名單／`kAlphanumericalKeyboardLayout` 選源（現行 ASCII 源 → `ABC` → 任一 ASCII 的 ad-hoc 順序，淨效果偏向美規 ABC）→ 違反 §4.3。
- **作用域把關**：`handleConsecutiveTypingErrorsSwitchIfNeeded()` 以 `session.inputMode == .imeModeCHT` 把關，排除簡體中文注音 → 違反 §4.4（繁簡注音皆應涵蓋）；又以 `!prefs.mixedAlphanumericalEnabled`（mixedAlnum 未啟用時才觸發）把功能做成與 MixedAlnum 路徑相反的獨立機制 → 違反「屬 MixedAlnum 功能家族」的定位（§一／§4.2）。註：§2.1 之「承接優先序」是以按鍵實際落入同一家族處理路徑與否自然分流，非以條件閘預先排除——兩者結構上不同。
- **Session**：`InputSession`／`SessionCoreProtocol`／`SessionHost` 增加 `isPassThroughUntilDeactivated`、`passThroughUntilDeactivatedTimestamp`、`InputSession.isAutoSwitchedToABC`、`switchToSystemABCInputSource`；`performServerActivation()` 自動恢復中文 → 語意（回切中文）事主接受，但實作面建立在 `isASCIIMode` 模型上（§4.5），待按 §4 重構。
- **Settings**：開關與閾值放在「一般設定（General）」頁（branch 實作即如此）→ 違反 §三（應在「行為設定」頁、與 MixedAlnum 同 Section）。

---

> **備註**：文中「applausible（適用）讀音」為事主用語，非既有程式碼字彙；指「當前載入 Lexicon（繁或簡）中實際存在／可用的讀音集合」，用以區分「音節結構上合法」與「詞庫中確實可用」。
