# Phase 148 研究報告：狂拼模式（Furious Typing Mode）

> 調查日期：2026-08-25。範圍：vChewing-macOS（vChewing_Typewriter / vChewing_Tekkon / vChewing_Homa）、
> SunPinyin 2.0 原始碼快照（`_ResearchScratch/_PinyinResearch/SunPinyinLatestCommit`）、
> vChewing-OSX-Legacy（鏡像位置核對）。
>
> 性質：純研究任務，不施工。本報告探究「怎樣在 `vChewing_Typewriter` 層級、以模組化實作的思維，
> 給唯音實裝『狂拼模式』」，並把「事先更加模組化」的前置作業一起規劃進去。
>
> 歷史考證註記：本調查當下 WebSearch 配額已耗盡（HTTP 403），歷史段落原以事主提供的說法＋既有知識
> 撰寫並標記「待查證」；網路驗證已委由三個外部代理（Perplexity／豆包／Google Gemini Pro）執行，
> 彙整結果見同目錄 `Phase148_WebSearchedResources.md`，本報告 §2.4 已依驗證結果定稿。

---

## 一、結論速覽

| # | 面向 | 現況（唯音） | 狂拼模式所需 | 差距 |
|---|---|---|---|---|
| 1 | 輸入單位 | keyblock：1 鍵 → 1 音節（注音）或累積 1 拼音音節 | 1 鍵 → 1 個字母，音節長度不定（1–6 字母） | 需「字母流 → 音節切分」層 |
| 2 | 音節切分 | `PinyinTrie.chop`（greedy 最長前綴，單拍觸發） | 整段字母流的（重新）切分，最好以 LM／詞庫引導 | 現行 greedy 無回看、不可重切 |
| 3 | 組句 | Homa DAG-DP（以讀音鍵為單位） | 同（讀音鍵仍可餵 Homa） | 讀音鍵生成方式需升級 |
| 4 | 語言模型 | Homa 查詢層（unigram + bigram 加權、`LookupHub.grams`） | 音節／詞層的評分（unigram 乘積起步即可） | 現有 LM 橋可複用，缺「字母級 lattice」介面 |
| 5 | 模組化接縫 | `TypewriterProtocol`＋`handleComposition` 分派 | 新 `FuriousTypingTypewriter` 掛載 | 接縫已存在，但數個硬編碼點需鬆綁 |
| 6 | 雙拼 | **完全不存在**（`MandarinParser` 僅 100–105 六種全拼式） | 狂拼通常搭配全拼；雙拼是另一條正交軸 | 若要做雙拼狂拼需在 Tekkon 新增 parser 層 |

**建議路徑（三階段）**：

1. **前置模組化**（可獨立成一個或多個 Phase）——把「讀音鍵生成」「模式枚舉」「組字器重切 API」
   抽成乾淨介面，掃平插入新打字模式的障礙；
2. **方案 A′（事主提案，建議第一版）**——維持現行急切提交 ＋ 新增「main＋copilot 尾段預覽」
   （暫態組句、優雅降級）＋ Inputting 就地選字；對齊真實智能狂拼行為、改動最小。
   （備選：方案 A——改「整段延後提交」、每鍵整段重切，改動較 A′ 大。）
3. **方案 B（LM 引導）**——以 Homa 既有 LM 分數對「全部可能音節切分」做 Viterbi 評分，
   讓切分由詞彙與共現機率決定（對齊 SunPinyin 的精神）；方案 C（SunPinyin 式字母級 lattice
   引擎）列為長遠選項。

---

## 二、狂拼模式是什麼

### 2.1 定義與歷史脈絡

「狂拼」是拼音輸入法的一種打字模型：**使用者連續敲擊無分隔符的拼音字母流，輸入法即時把字母流
切成音節、再切成詞、再以語言模型組出句子**。使用者不需要在音節之間敲空白鍵或聲調鍵，
所有「切分」的決定權都交給輸入法，隨打字進度動態調整。

歷史脈絡（已由外部代理網路驗證，詳見 §2.4 與 `Phase148_WebSearchedResources.md`）：

- **「智能狂拼」是中文之星（北京中文之星科技有限公司）約 2000 年推出的商業產品名稱**，核心賣點
  是以 CLM（中文語言模型，號稱分析約 100 億字語料）驅動的「整句輸入」——一次鍵入長串拼音、
  不必以空格逐詞分界；但產品仍保留空格作為候選確認鍵，不宜表述成「絕不可敲空格」。
- **整句輸入的技術源頭早於智能狂拼**：哈爾濱工業大學自 1980 年代末起研究語句級智能輸入
  （王曉龍的「最小分詞問題」研究、哈工大智能計算中心稱實作出國內外第一個語句級智能拼音輸入
  系統）；1995 年微軟與哈工大成立聯合語言語音實驗室，1996 年前後推出微軟拼音 1.0（內置於
  Windows 95 OSR2／NT 4／Office 97 時期），是最早實現語句級輸入的系統級產品，比智能狂拼早約
  四年。**「狂拼」一詞可確認是中文之星的品牌命名，查無可靠來源證明由哈工大／微軟提出**。
- 現代拼音輸入法（搜狗拼音、微軟拼音、Google 拼音）預設即此種模式：連續輸入、即時整句上屏，
  並支援「簡拼」（只打聲母，如 `shjdaz` →「世界大戰」）與全拼混用。

### 2.2 與「簡拼」「雙拼」「keyblock」的關係

| 名詞 | 輸入內容 | 切分責任 | 與狂拼的關係 |
|---|---|---|---|
| 狂拼（Furious Typing） | **完整拼音音節的無分隔字母流**（`woshizhongguoren`；可另含聲調鍵） | 輸入法切音節＋切詞＋組句 | 本報告主角 |
| 簡拼（Abbreviated Pinyin） | 只打聲母（`shjdaz`） | 輸入法猜測完整音節 | **匹配層的一等公民、非獨立模式**：每個前綴同時是完整音節前綴與縮寫候選，同一管線以「完整匹配優先」排序（Rime `speller/algebra` 的 `abbrev` 語義） |
| 雙拼（Double Pinyin） | 每音節 2 鍵（聲母鍵＋韻母鍵） | 固定編碼表，鍵對 → 音節 | 正交軸：可與狂拼疊加（SunPinyin 有 `CHunpinSegmentor` 混拼） |
| 注音 keyblock | 每鍵 1–2 個注音符號（可並擊） | 音節即按鍵組合，無切分問題 | 唯音目前的「看家本領」 |

關鍵洞察：**狂拼的本質問題是「音節邊界不確定」**——`xian` 可以是「先」也可以是「xi'an」、
`fangan` 可以是「fan'gan」也可以是「fang'an」，必須靠語言模型（至少詞庫）決定。keyblock 式輸入
（注音／雙拼）沒有這個問題，因為音節邊界由按鍵結構固定。

> 定義釐清：狂拼的「歷史代表形態」是**完整音節的無分隔流**（外部驗證的一致結論）；但現代
> 微軟拼音／搜狗拼音**皆允許不完全拼寫**（事主確認）——輸入過程中的每個前綴同時是「完整音節
> 的候選」與「簡拼縮寫的候選」，由同一個前綴樹＋語言模型統一評分（Gemini 驗證：現代輸入法
> 透過同一個拼音前綴樹共存，將 `s` 同時視為簡拼聲母與 `shi/shu` 的前綴）。
> 事主另有**一手實測觀測**（智能狂拼 II 打字錄影；觀測描述可能不準確）：打字全程游標位於組字行
> 最前方、且最前方內容允許 partial-matching（如只打聲母）——與「不完整拼寫為一等公民」同向；
> Windows 3.x 中文之星（當時尚無智能狂拼之名）的簡拼輸入：敲 `dn` 自動拆成 `d n`、候選窗列出
> 全部 prefix-matched 雙音節詞（當年／大腦／電能／對內／動能／大年……）——即「每字母＝一個
> 音節聲母佔位、逐音節 prefix 匹配」的機制原型。
> 因此唯音的狂拼模式**不必把簡拼設成獨立開關**：切分層應把「完整音節」與「不完整音節前綴」
> 都當作候選（SunPinyin 的詞典 trie 即以 `threadNonCompletePinyin`／`combineInitialTrans`
> 內建不完整音節轉移，`pytrie_gen.cpp:368-432`），以「完整匹配優先級高於縮寫匹配」排序
> （Rime `abbrev` 語義）即可。

### 2.3 手機場景

事主指出「手機上的話，無論注音還是拼音，都是狂拼模式佔優」。原因（工程視角，已由外部驗證
補強）：

- 螢幕鍵盤無實體按鍵回饋、按鍵小、誤觸率高，逐音節確認／敲分隔鍵的觸控成本高；一次輸入較長
  字串、讓模型依前後文減少人工選字，是統計語言模型改善歧義的直接應用；
- 九宮格布局下多個字母共用單鍵，天然需要引擎自動切分音節與詞彙——本質就是狂拼式連續流；
- 滑動輸入等觸控交互與連續拼音流的技術架構高度契合；
- **代價**：錯誤可能跨音節、跨詞累積，修正時須重新解碼或重新選取較長片段；因此手機狂拼式
  輸入法必須提供游標定位、局部重轉與候選鎖定（智能狂拼當年就以此為賣點做「下標定位」局部修正）。

唯音目前以 macOS 桌面為主要平台，但已具備 iOS 目標（min iOS 18）；狂拼模式對手機端是
「打基礎」的正確投資。精確的對比語彙：與其說「注音 vs 拼音」或「keyblock vs 狂拼」，不如說
「顯式音節／符號輸入與逐段確認」對「隱式切分的語句級解碼」——現代拼音輸入法本就常接受
連續字母串，狂拼模式是在這個方向上把解碼品質做到位。

### 2.4 歷史考證結論（已由外部代理網路驗證）

> 驗證來源：Perplexity、豆包、Google Gemini Pro 三份獨立報告，彙整於同目錄
> `Phase148_WebSearchedResources.md`；以下為交叉比對後的定稿。三份報告結論一致，
> 個別出入（如智能狂拼正式發布日 2000-08-17、哈工大技術「授權」vs「收購」的表述）已標註。

1. **智能狂拼**：約 2000 年由中文之星推出（Ⅰ 版 2000-08-17 正式發布），以 CLM 驅動的
   「整句輸入」為核心賣點（不必以空格逐詞分界，但空格仍作候選確認鍵）；開發團隊後續與
   天索科技、核心開發者廖恆毅出走（「拼音加加」）等團隊變動有關。✅ 屬實
2. **哈工大與微軟拼音**：部分屬實但表述需修正——哈工大自 1980 年代末研究語句級智能輸入
   （王曉龍「最小分詞問題」、語句級輸入系統），1995 年起與微軟成立聯合實驗室合作開發，
   微軟拼音 1.0 約 1996 年隨 Windows 95 OSR2／NT 4／Office 97 時期推出（非 1998）。
   「哈工大**發明狂拼**」與「微軟拼音 1.0 **率先使用狂拼**」均不精確：**「狂拼」可確認是
   中文之星的產品品牌命名，查無可靠來源證明由哈工大／微軟提出**。✅（有條件）
3. **式微原因**：版本開發中斷（Ⅱ 轉收費、Ⅲ 半途終止）、團隊分流、收費模式 vs 盜版環境、
   2005 年後搜狗等網際網路輸入法崛起——屬產品與商業因素；技術路線（連續拼音流→音節切分→
   LM 評分）被後續輸入法全面繼承，但應表述為「共享統計式整句輸入技術範式」而非直接程式碼
   繼承。✅ 屬實
4. **正式名稱**：行業與文獻通用的稱呼是「**整句輸入**」「語句級輸入」／英文 sentence-based
   input／sentence conversion（libpinyin 自述即 intelligent sentence-based）；「狂拼」不是
   產業標準術語，適合作為唯音的功能品牌名稱。✅（有條件）
5. **狂拼 vs 簡拼**：狂拼的歷史代表形態＝完整音節的無分隔連續輸入；簡拼＝首字母縮寫（另一層
   拼寫壓縮），兩者可共存（Rime `speller/algebra` 的 `abbrev` 是簡拼的正式機制）。✅ 屬實。
   ⚠️ **未記載**：三份資料**均未直接記載「智能狂拼產品本身是否支援簡拼／不完全拼寫」**——
   它們把狂拼的定義核心放在「完整音節流＋整句解碼」，但沒有斷言其產品不支援縮寫輸入。
   現代微軟拼音／搜狗拼音**皆允許不完全拼寫**（事主確認），並以同一個前綴樹＋LM 統一評分
   （Gemini 驗證）。
   📹 **事主一手實測觀測**（未經外部文獻交叉驗證，觀測描述可能不準確）：智能狂拼 II 打字錄影
   顯示游標在前方、最前方內容允許 partial-matching（只打聲母即可）——**但游標並非恆在最前方**
   （事主另見智能狂拼 2008 擷圖：游標可移至後方選字）；Windows 3.x 中文之星簡拼輸入 `dn` →
   `d n` → 候選窗列出全部 prefix-matched 詞（當年／大腦／電能／對內／動能／大年……）。
   此兩項與「狂拼系允許不完整拼寫」的方向一致。

---

## 三、唯音現況盤點：keyblock 輸入模型

> 路徑縮寫：`T` = `vChewing-macOS/Packages/vChewing_Typewriter/Sources/Typewriter`，
> `Tek` = `vChewing-macOS/Packages/vChewing_Tekkon/Sources/Tekkon`，
> `H` = `vChewing-macOS/Packages/vChewing_Homa/Sources/Homa`。

### 3.1 事件管線總覽

```
IMK handleEvent → KBEvent（InputSession_HandleEvent.swift:165-204）
  → triageInput（T/InputHandler/InputHandler_TriageInput.swift:15）
    → handleComposition（T/InputHandler/InputHandler_HandleComposition.swift:17）
      → TypewriterProtocol 實作（依 currentTypingMethod + prefs.cassetteEnabled 分派，:20-35）
        → Tekkon Composer 注拼槽（receiveKey / phonabetKeyForQuery）
        → LM 在庫驗證（currentLM.hasUnigramsForFast）
        → Homa Assembler.insertKey（H/Homa_Assembler.swift:165）
        → generateStateOfInputting → session.switchState（SessionCoreProtocol.swift:85-124）
```

- `TypewriterProtocol`（`T/Typewriter/TypewriterProtocol.swift:11-18`）只有三件事：
  `associatedtype Handler`、`init(_ handler:)`、`handle(_ input:) -> Bool?`。
- 目前有六個 typewriter 實作，全部是 `@frozen struct`：`BPMFFullMatch`（注音／拼音全匹配）、
  `Cassette`（磁帶）、`CodePoint`（內碼）、`RomanNumeral`（羅馬數字）、`HaninSymbol`（韓音漢字）、
  `MixedAlphanumerical`（中英混打）。

### 3.2 Tekkon 注拼槽（keyblock 核心）

- `Composer` struct 只有「聲介韻調」四格（`Tek/Tekkon_SyllableComposer.swift:59-68`），
  拼音模式另加 `romajiBuffer`（`:71`）。
- 注音（`parser.rawValue < 100`）：按鍵經 parser 查表 → 分配進四格；複合排列就地處理。
- 拼音（`parser.rawValue >= 100`）：字母直接累進 `romajiBuffer`（上限 6 字元）；數字 1–5 是聲調鍵。
- `phonabetKeyForQuery`（`:466-487`）**永遠回傳注音字串**——拼音在內部先被轉成注音鍵再餵 Homa。
  這是個重要的既有約定：Homa 的讀音鍵以注音為正規形式，狂拼模式若能維持這個約定，LM 端零改動。

### 3.3 拼音模式現況：兩條並存路徑

**路徑 1：逐音節確認**（`T/Typewriter/Typewriter_BPMFFullMatch.swift:241-318`）
- romajiBuffer 累積 → 聲調鍵（1–5）或確認鍵（Space/Enter）觸發 `composeReadingIfReady`；
- 無調確認時以 `makeToneInsensitivePinyinQueryKey`（`:144-154`）把單一讀音展開成同音節
  五聲調候選桶，交由 Homa 的 `PossibleKey.multipleKeys` 處理——**Homa 天生支援「一位置多讀音」**。

**路徑 2：連續字母自動 chop（已存在的「狂拼雛形」）**
- `pinyinAutoChopResult(appending:)`（`Tek/Tekkon_SyllableComposer.swift:262-288`）：
  當「romajiBuffer ＋ 新字元」整體不再是單一可唸讀音時，回傳
  `PinyinAutoChopResult(committedReadings: [String], remainingRomaji: String)`；
- 切割由 `Tek/Tekkon_PinyinTrie.swift:223-267` 的 `chop(_:)` 完成：**greedy 最長前綴匹配**，
  比對表是 `allPossibleReadings`（全部合法音節拼寫，依長度降序）；
- 消費端 `performPinyinAutoChopIfNeeded`（`T/Typewriter/Typewriter_BPMFFullMatch.swift:197-239`）：
  每個 chop 段先做 `hasUnigramsForFast` 在庫驗證（`:210-214`），全部通過才逐一 `assembler.insertKey`，
  殘留字串以 `composer.replacePinyinBuffer(with:)` 留著繼續打；
- 例：`"shjdaz"` → `["sh","j","da","z"]`（`PinyinTrie.swift:219-221` 註解明言是
  「智能狂拼/搜狗拼音」式簡拼切割）。

### 3.4 現行「狂拼雛形」與「真狂拼」的差距清單

> 先釐清差距的性質：現行 `PinyinTrie.chop` 本質是「**前綴匹配**」——同時接受不完整前綴
> （`sh`、`j`）與完整音節（`da`）。方向上這與現代輸入法一致（§2.2：不完整拼寫是匹配層的
> 一等公民、與完整音節共用同一管線），**真正的差距不在「要不要允許不完整拼寫」，而在
> 「解碼品質與可回看性」**：現行機制是「單拍貪婪、提交即鎖死、不經 LM 評分」，狂拼要求
> 「整段字母流的（重新）切分＋全句候選解碼」。

1. **單拍觸發、非持續流**：chop 只在「整體不可唸」時對**當前 buffer** 切一次、把前段提交、尾段留著。
   已經提交的音節進入 Homa 後**不再重新切分**。
2. **greedy 無回看**：`chop` 是確定性最長前綴，且「每段必須是完整音節（`mapZhuyinPinyin` 命中）」
   才會提交——例：打 `fanga` 時切出 `["fang","a"]`（提交「方」、留 `a`），但使用者意圖可能是
   `fan/gan`（「反感」）——等打出 `n` 湊成 `fangan` 時，`fang` 已提交、回不去了。
   這是「狂拼體驗」的核心缺陷（對完整音節流 `fangan` 的切分歧義，與對簡拼前綴的貪婪，同源）。
3. **切分不經 LM 評分**：chop 只看「音節拼寫前綴」，不看詞庫與共現機率；只有「在庫與否」的
   硬閘（`hasUnigramsForFast`），沒有「哪種切分更合理」的軟評分。
4. **無「整句／切分」候選層次**：SunPinyin 會把「整句候選／尾段候選／詞候選」分層列出
   （`getCandidateList`）；現行 vChewing 的 `"zh&z"`（`deductChoppedPinyinToZhuyin`）只有
   「同一 chop 段的多注音對應」，沒有「多種音節邊界」的候選與「整句重新解碼」的候選。
5. **無動態重切介面**：Homa 有 `dropKey`／`insertKey`／`insertKeys`，但沒有「以新讀音序列
   整段重寫」的單一 API（見 §5.4）。

### 3.5 雙拼現況

- 確認：`MandarinParser` 只有 100–105 六種**全拼式**拼音（漢語／國音二式／耶魯／華羅／通用／
  韋氏；`Tek/Tekkon_Phonabets.swift:32-37`）；Tekkon 全倉搜尋 `雙拼/shuangpin` 零命中。
- 唯音 README 提到「小鶴雙拼」只是比較文句，無對應實作。
- 影響：狂拼模式若限定全拼鍵盤，可完全繞開雙拼問題；若想支援雙拼（SunPinyin 的
  `CShuangpinSegmentor` 是現成參考），需在 Tekkon 新增 parser 層（`MandarinParser` case ＋
  `mapZhuyinPinyin` 表），這是與狂拼正交的獨立工作量。
- **事主決策（2026-08-26，P151 規劃）**：雙拼**確定不做**——有需求的雙拼用戶（小鶴雙拼、
  小鶴音形等）自行以磁帶模式（Cassette）準備對應磁帶方案，唯音不內建雙拼鍵盤；
  SunPinyin 的 `CShuangpinSegmentor` 參考價值僅存於研究層。

---

## 四、參考藍本：SunPinyin 的連續拼音架構

> 原始碼快照：`_ResearchScratch/_PinyinResearch/SunPinyinLatestCommit`（sunpinyin-2.0.3+，含混拼）。
> 注意：新版樹**沒有** `src/im/`，改為 `src/pinyin/`（segmentor）、`src/ime-core/`（lattice＋搜尋）、
> `src/slm/`（語言模型）、`src/lexicon/`（詞典 trie）。

### 4.1 整體分層

```
按鍵 → CIMIClassicView::onKeyEvent（imi_view_classic.cpp:148）
  → _insert（:462-481）→ IPySegmentor::push / insertAt（字母流 buffer）
  → CIMIContext::buildLattice（imi_context.cpp:146）
  → CIMIContext::searchFrom（:384，token-passing beam-Viterbi）
  → _backTracePaths（:546）→ 候選窗（getPreeditString :367 / getCandidateList :432）
```

四大組件：

| 組件 | 位置 | 角色 |
|---|---|---|
| `IPySegmentor`（含 `CQuanpinSegmentor`／`CShuangpinSegmentor`／`CHunpinSegmentor`） | `src/pinyin/segmentor.h`、`pinyin_seg.cpp` | 字母流 buffer ＋ 音節切分 |
| `CIMIContext`（lattice＋搜尋） | `src/ime-core/imi_context.*` | frame 級 lattice、詞典查詞、Viterbi、候選 |
| `CThreadSlm`（backoff bigram＋trigram） | `src/slm/slm.*` | 語言模型評分（`transfer(TState, wid, TState&)`） |
| `CPinyinTrie`（詞典） | `src/lexicon/pytrie.*` | 音節序列 → 詞（多音節詞逐音節累積） |

### 4.2 音節切分：`CQuanpinSegmentor`（倒序最長匹配）

- `_push`（`pinyin_seg.cpp:379-474`）核心一行：
  ```cpp
  int v = m_pytrie.match_longest(m_pystr.rbegin(), m_pystr.rend(), l);
  ```
  double-array trie（`src/pinyin/datrie_impl.h:140-160`）**從 buffer 尾端往回做最長匹配**；
  trie 資料以「反轉音節拼寫 → 音節 ID」產生（`python/quanpin_trie_gen.py:46`）。
- 音節表（`python/pinyin_data.py:69-100`）每個聲母都含空韻母（`b`、`zh`、`x` 都是合法節點）——
  **「不完整音節」因此天然可運作**。
- 依匹配長度分四種情況維護**單一**切分 `m_segs`：無匹配（`'` 分隔符／無效字元／英文）、
  新音節、延伸當前音節（`[xia]+n → [xian]`）、尾部重切（`[die]+r → [di][er]`）。
- **替代切分**來自兩處：模糊切分（`CGetFuzzySegmentsOp`，`pinyin_seg.h:72`；`fangan → fang'an /
  fan'gan`、`xian → xi'an`）＋ 手動 `'` 分隔符。

> ⚠️ 重要架構事實：**新版 SunPinyin 對整個 buffer 只維護一條貪婪切分，SLM 只對「詞序列」評分、
> 不對「音節切分」評分**（`imi_context.cpp:239-261` 的詞典 trie 以「已切好的 segment」為單位
> 逐音節走詞）。「哪種切分較好」由 segmentor 的貪婪匹配決定，而不是由 LM 決定。
> 舊版（2.0.0 之前）的 `pinyin_parser.*` 才是「列舉所有可能音節序列再挑選」的設計。

這對唯音的意義：**如果只想要「切分正確率」逼近現代輸入法，重點不是做字母級 lattice，而是
讓「切分」本身有回看與評分能力**——這正是 §6 方案 B 的主軸。

### 4.3 整句搜尋：beam-Viterbi ＋ trigram backoff

- 逐 frame、逐 lexicon state 取 top 詞（`MAX_LEXICON_TRIES`＝32，`imi_defines.h:43`）；
- `_transferBetween`（`imi_context.cpp:485-543`）＝ SLM 轉移 ＋ bigram 歷史快取插值
  （`:499-533`，個人化權重 `m_historyPower`）；
- Beam 剪枝：`CLatticeStates::add`（`lattice_states.cpp:172-205`），`beam_width`＝48；
- 分數型別 `TSentenceScore`（`portability.h:112-146`）＝ log-domain 大數，避免機率連乘下溢；
- `_backTracePaths`（`imi_context.cpp:546-615`）回溯 N-best。

### 4.4 增量與已選詞鎖定（對唯音 UI 的啟示）

- **增量三連**：`segmentor.updatedFrom()` → `buildLattice(updatedFrom+1)` → `searchFrom(rebuildFrom)`，
  只重建受影響的 frame，前面的 lattice states 原封不動（`imi_context.cpp:150,158,168`）；
- **已選詞鎖定**：`makeSelection`（`:929-940`）標 `USER_SELECTED`，之後重搜直接重放該詞並給
  `TSentenceScore(30000, 1.0)` 巨大加成（`:495-497`）；游標回到已選詞之前時 `cancelSelection`
  解除鎖定。
- 對唯音：vChewing 的「一邊吃一邊屙」溢出遞交（`SessionCoreProtocol.swift:85-124` 的
  `.ofInputting → textToCommit`）與 Homa 的 POM（Perception Override Memory）已具備類似的
  「鎖定前段、重組後段」語義，只是**單位是音節而非字母**。

### 4.5 給唯音的啟示

1. **ime-core 整層（lattice／SLM／候選）與「每鍵一音節」模式完全共用**；全拼／狂拼只差一個
   `IPySegmentor` 實作。這是「把 segmentor 抽成可替換介面」的極佳佐證。
2. **切分資料結構可簡化**：vChewing 不需要 double-array trie；`Tekkon.PinyinTrie.allPossibleReadings`
   就是現成的音節庫存（syllable inventory），切成有序陣列後即可做前綴匹配或 DP。
3. **LM 可以借現成的**：SunPinyin 用自帶 trigram；vChewing 的 Homa LM 層（`LookupHub.grams`）
   已提供 unigram／bigram 分數，切分評分不必新造語言模型。
4. **不建議照搬的部分**：字元級 `CLatticeFrame`（512 格）與 `TLexiconState` 的 C++ 記憶體佈局、
   以及「只對已切分 segment 評詞」的架構——對 Swift／Homa 而言，改採「切分 + 詞級 DAG」更貼合
   既有組字器。

---

## 五、Typewriter 的模組化現況與接縫

### 5.1 已存在的接縫

1. **`TypewriterProtocol` ＋ `handleComposition` 分派**（`T/InputHandler/InputHandler_HandleComposition.swift:20-35`）：
   目前依 `currentTypingMethod`（`TypingMethod` enum，四 case：`vChewingFactory / codePoint /
   haninKeyboardSymbol / romanNumerals`，`T/InputHandler/InputHandler_TypingMethod.swift:11`）
   ＋ `prefs.cassetteEnabled` 布林選 typewriter。**新增狂拼 typewriter 最自然的掛載點**。
2. **磁帶模式＝「任意字串當讀音鍵」的模範實作**：`CassetteTypewriter` 直接把組筆碼串當
   reading key 插入組字器（`T/Typewriter/Typewriter_Cassette.swift:253-266`），完全不經 Tekkon
   composer 的聲介韻調轉換——證明 **Homa 對 reading key 的字串格式沒有硬性要求**（注音鍵／
   磁帶碼皆可），狂拼的「字母流切分後轉注音鍵」同樣可行。
3. **Homa 支援「一位置多讀音」**：`PossibleKey`（`H/Homa_BasicTypes/Homa_PossibleKey.swift:11-13`）
   ＝ `.singleKey(String)` 或 `.multipleKeys([String])`（聲調替代桶）。拼音無調確認時已在使用
   （`makeToneInsensitivePinyinQueryKey`）——這是把「多種音節邊界替代」餵進組字器的現成管道雛形。

### 5.2 硬編碼點（不利插入新模式，需在前置模組化掃平）

| # | 位置 | 問題 |
|---|---|---|
| 1 | `InputHandler_HandleComposition.swift:20-35` | 分派 switch 寫死；`cassetteEnabled` 是布林，注拼與磁帶互斥，無法表達「狂拼＋注音」「狂拼＋雙拼」等組合 |
| 2 | `TypingMethod` enum（`TypingMethod.swift:11`） | 只有 4 case；`revolveTypingMethod` 用 rawValue 循環，新增 case 會改到循環語義 |
| 3 | 游標／讀音推導全假設「1 key ＝ 1 讀音字串」 | `previousParsableReading`（`CoreProtocol.swift:514`）、`KeyDropContext`（`:78-175`）、`convertCursorForDisplay`（`HandleStates.swift:202-231`）、`actualNodeCursorPosition`（`:463`）——若狂拼把「半個音節」留在緩衝區顯示，這些都要能處理「緩衝區 ≠ 組字器」的狀態 |
| 4 | `composer` 單一實例、顯示全靠 `readingForDisplay` | 狂拼需要「字母流緩衝區」與「已提交讀音」兩種顯示內容；`readingForDisplay` 目前只有注拼槽一種來源 |
| 5 | 候選 `keyArray` 以 `"-"` 分隔 | `HomaCompatShims.swift:71` `theSeparator`；多讀音語義已內建，但「字母級」顯示未定義 |
| 6 | `InputSession_HandleEvent.swift:173` 鍵盤佈局翻譯條件 | 依賴 `isComposerUsingPinyin`；狂拼模式應視同拼音（不翻譯美規佈局），需同步這面旗子 |
| 7 | `handleBackSpace/handleDelete` 對 `.codePoint/.romanNumerals` 的專屬分支 | 若狂拼有自己的緩衝區，退格需有專屬路徑（或確保走既有 composer 路徑） |

### 5.3 Homa 的輸入介面與重切缺口

- 輸入單位：`assembler.keys: [PossibleKey]`（`H/Homa_Assembler.swift:79-82`），**一個元素 ＝ 一個音節**。
- 輸入 API：`insertKey(_: String)`（`:165`）、`insertKey(_: [String])`（`:171`）、
  `insertKeys(_: [PossibleKey])`（`:178`）、`insertKeys(_: [[String]])`（`:216`）、
  `dropKey(direction:)`（`:235`）、游標 `cursor/marker`。
- **插入前在庫驗證**（`:187-200`）：`gramAvailabilityChecker`／`queryGrams` 找不到就 throw——
  半個音節（如 `"nih"`）直接餵入會失敗，**因此字母流必須先切成合法讀音鍵**。
- **重切缺口**：有 `dropKey`（單鍵）、`insertKey`（單鍵）、`insertKeys`（批量），但沒有
  「整段讀音序列替換」的原子 API。方案 B 需要「清除受影響區段 → 批量插入」的組合，
  可能要新增 `replaceKeys(from:with:)` 一類的介面（或驗證 `dropKey` 迴圈 ＋ `insertKeys`
  的既有組合已足夠）。

### 5.4 測試結構（可複用）

- `T/Tests/TypewriterTests/TestComponents/MockedInputHandlerAndStates.swift`：`MockInputHandler` ＋
  `MockSession`（`recentCommissions` 記錄遞交）＋ `MockCandidateController`；
- 基座 `InputHandlerTests_Basics.swift`：`typeSentence(_:)`（把字串逐字元轉 `KBEvent` 餵
  `triageInput`）、`makeTypingTextMap`（自訂小型測試詞庫）；
- Tekkon 側已有 `pinyinAutoChopResult` 的純 composer 測試
  （`Tek/Tests/TekkonTests/TekkonTests_Pinyin.swift:109-124`）。

---

## 六、狂拼模式實裝設計草案（模組化思維）

### 6.0 設計原則

1. **沿用「讀音鍵以注音為正規形式」的既有約定**——LM 端（`hasUnigramsForFast`、`LookupHub.grams`）
   零改動；狂拼只是「讀音鍵的產生方式」換一條更聰明的管線。
2. **延後提交、整段重切**——不學現行 `performPinyinAutoChopIfNeeded` 的「前段立即提交」，
   而是維持「字母流緩衝區 ＋ 整段切分」直到溢位／確認才提交前段（對齊 SunPinyin 的
   `updatedFrom → rebuildFrom` 增量語義與現代輸入法的「整句預覽」）。
3. **切分器抽成可替換介面**——`.greedyChop`（現行）與 `.lmScoredDP`（方案 B）是同一介面的
   兩種實作，方便逐步升級、A/B 對照。
4. **以 Homa 為最終組字器**——不重造輪子：切分與評分在 Typewriter 層完成，組句仍由 Homa 的
   DAG-DP 處理。
5. **功能定義（§2.2）**——狂拼＝「允許無分隔的羅馬字字母流、以全句候選解碼」；**不完整拼寫
   （簡拼）是匹配層的一等公民**：每個前綴同時是完整音節候選與縮寫候選，由切分／組字層統一
   評分，完整匹配優先級高於縮寫（對齊 SunPinyin trie 的不完整音節轉移與 Rime `abbrev` 語義）。
6. **參考實作優先序**：SunPinyin 與 **libpinyin**（GPL-3.0，自述 intelligent sentence-based
   pinyin 核心）是演算法參考；**Rime**（`speller/algebra` 的 `abbrev`／`derive` 拼寫代數、
   segmentor 機制）是「可配置拼寫規則＋詞典」的架構參考；Rime 生態的 rime-octagram、萬象拼音
   可作語句流方案的市場驗證（非核心能力等價證明）。

### 6.1 前置模組化（「事先更加模組化」——建議先做，可拆多個 Phase）

| 工作 | 內容 | 受影響檔案 |
|---|---|---|
| M1 | **打字模式枚舉化**：以 `enum TypingMode { .bopomofo, .pinyinKeyblock, .pinyinFuriousTyping }` 之類取代「`cassetteEnabled` 布林＋拼音布林」的隱式組合；`handleComposition` 分派改吃枚舉 | `InputHandler_HandleComposition.swift`、`InputHandler_TypingMethod.swift`、`PrefMgr`（新 pref） |
| M2 | **抽出讀音鍵產生 helper**：把 `makeToneInsensitivePinyinQueryKey`、`readingKeyForQuery` 從 `BPMFFullMatchTypewriter` 抽成共用型別（狂拼與全拼共用同一套「讀音鍵 → `PossibleKey`」轉換） | `T/Typewriter/Typewriter_BPMFFullMatch.swift` 重構、新增 `PinyinReadingKeyProvider` |
| M3 | **切分介面化**：新增 `protocol PinyinSegmenting { func segment(_ buffer: String) -> PinyinSegmentation }`；現行 `PinyinTrie.chop` 包成 `.greedyChop` 實作；`PinyinSegmentation` 含「前段已定讀音序列＋尾段殘留字母＋（可選）替代切分」 | `T/Typewriter/`（新檔）、`Tek/Tekkon_PinyinTrie.swift`（薄包裝） |
| M4 | **組字器重切 API**：評估並（若需）新增 `replaceKeys(from:with:)` 一類原子重寫；或驗證「`dropKey` 迴圈＋`insertKeys`」組合可安全實現整段重切（注意游標、覆寫狀態、POM 的一致性） | `H/Homa_Assembler.swift`（評估） |
| M5 | **顯示層鬆綁**：`readingForDisplay`／`generateStateOfInputting` 支援「字母流緩衝區＋半音節」的顯示來源；退格與游標邏輯補狂拼分支（或泛化） | `InputHandler_HandleStates.swift`、`InputHandler_CoreProtocol.swift` |
| M6 | **鍵盤佈局翻譯旗子**：`InputSession_HandleEvent.swift:173` 的條件補上狂拼模式（等同拼音、不翻譯） | `MainAssembly4Darwin/SessionController/InputSession_HandleEvent.swift`（＋Legacy 鏡像） |

M1–M3 是「狂拼模式的必要前置」；M4–M6 可隨方案 A′（或方案 A）一併進行。全部完成後，`handleComposition`
分派長這樣（示意）：

```swift
case .vChewingFactory where hardRequirementMet:
  switch prefs.typingMode {
  case .cassette:      return CassetteTypewriter(self).handle(input)
  case .furiousTyping: return FuriousTypingTypewriter(self).handle(input)  // 新
  case .keyblock:      // 既有 BPMF/MixedAlphanumerical 路徑
  }
```

### 6.2 方案 A：`FuriousTypingTypewriter`（最小可行，greedy 但「整段延後提交」）

**架構**（完全在 Typewriter 層，不動 Tekkon 的切分邏輯、不動 Homa）：

```
字母流緩衝區（可複用 Tekkon Composer.romajiBuffer 或獨立 String buffer）
  → 每鍵：buffer += letter
  → PinyinSegmenting.segment(buffer)          // 現行 PinyinTrie.chop（greedy）
  → 全部切片轉注音鍵（mapZhuyinPinyin）＋聲調候選桶展開
  → 整段（非單拍）組合成 [[String]]，待「確認／溢位」才餵 Homa
  → 確認（Space/Enter）：assembler.insertKeys(segments) → Homa 組句 → 提交
  → 退格：緩衝區 pop；若已有提交部分，走既有 dropKey 路徑
```

**行為對照現行**：

| 面向 | 現行自動 chop | 方案 A |
|---|---|---|
| 觸發 | 每鍵試算、「整體不可唸」才切 | 每鍵對**整段 buffer** 重切 |
| 提交時機 | 切完立即提交前段 | 延後到確認／溢位 |
| 切分演算法 | greedy 最長前綴 | 同（greedy） |
| 在庫驗證 | 每段 `hasUnigramsForFast` | 同，但失敗時可以「留著等更多字母」（不退場） |
| 重切能力 | 無（提交後鎖死） | 有（確認前整段重算） |

**優點**：改動面小（新 typewriter ＋ M1–M3 前置）；體驗已從「逐音節鎖死」變成「整句預覽」，
補上差距清單的第 1、5 項。
**缺點**：切分仍是 greedy 無評分（差距 2、3 未解）；`fanga` → `fang/a` 的錯切在確認前雖可被
「更多字母」救回（`fangan` 重切成 `fan/gan`），但單音節歧義（`xian` 是否為 `xi'an`）仍無解。

### 6.3 方案 A′（事主提案）：main＋copilot 尾段預覽

**概念**（事主 2026-08-26 提案）：維持現行「chop 前段急切提交」的 main 組字器不動；當 Tekkon
注拼槽尚未完成拼寫（romajiBuffer 非空）時，把 main 組字器的 config 複製一份、插入「當前
tekkon 暫態鍵」當尾段，在 copilot 組字器內組句——讓 preedit 直接顯示「已提交句＋尾段預覽句」
的實時預覽：

```
preview = FuriousTypingPreview(mainAssembler.config, tekkon.romajiBuffer)
  ├ 複製 config（Homa.Assembler 為 struct、COW 廉價）
  ├ 尾段鍵生成：
  │   ├ 完整音節無調（"ni"）→ makeToneInsensitivePinyinQueryKey（既有，五聲調桶）
  │   └ 不完整前綴（"nih"/"h"）→ Tekkon.PinyinTrie search/prefix 展開 → multipleKeys bucket
  ├ assembler.insertKey(尾段鍵) → assemble()
  └ 全無 LM 命中 → 退化回現行 raw 拼音尾段顯示（優雅降級）
```

**評估（本報告）**：

- **建議做成無狀態暫態組句（純函式），而非 handler 上的長駐 nullable 屬性**——copilot 的輸入
  （main config＋tekkon buffer）皆已在 handler 上，每拍重新推導即可、不需跨拍狀態，從根上免除
  同步／lifecycle bug，複雜度大減。
- **成本**：每拍多一次 Homa 組句（僅在 tekkon 有暫態內容時），微秒級、可忽略（§4 已論證）。
- **邊界**：copilot 修的是「**尾段**」，不修「**已提交的錯切**」——`fanga` 已提交「方」後，
  copilot 只能預覽「方…」的延續、不會自動變成「反感」。這正是**事主觀測到的真實智能狂拼行為**
  （游標可移動、前段 partial-match、手動干涉選字）——第一版走 A′ 等於對齊真品，把「句中重切」
  （方案 B）列為後續升級。
- **Inputting／Candidate 混合**：狂拼的 Inputting State 就地顯示候選窗＋Shift＋選字鍵干涉，
  確實是主要的 UI 工作量；但 codebase 已有先例——`handleTypewriterSCPCTasks`
  （`InputHandler_HandleComposition.swift:38-63`）在 SCPC 模式把 input 直接切進 CandidateState、
  磁帶模式有「快速選字」（Phase 129 quick-candidate），可仿照接線。
- **與方案 A／B 的關係**：A′ 比 A 更貼近現行急切提交模型（改動更小）；B 是 A′ 的「切分品質」
  升級路徑。建議路線：**M1–M3 → A′（含 copilot 預覽＋就地選字）→ B**。

### 6.4 方案 B：LM 引導的 DP 切分 ＋ Homa 同步（對齊 SunPinyin 精神）

**核心**：把差距 2、3 一次補上——對整段字母流**列舉全部可能音節切分**，以 Homa 既有 LM 分數
（`LookupHub.grams` 的 unigram／bigram）做 Viterbi 評分，選出最佳切分路徑。

```
FuriousTypingSegmentor（新，Tekkon 或 Typewriter 層）
  ├ 音節庫存：Tekkon.PinyinTrie.allPossibleReadings（現成，無需新資料）
  ├ DP：dp[pos] = max over 合法音節 s（buffer[pos..pos+len(s)] 為 s）
  │      ( dp[pos-len] 或 dp[pos+len]（往後） + score(s | 前一首節) )
  ├ score：unigram 權重（hasUnigramsFor → weight）＋可選 bigram（LookupHub.grams 的 previous 鍵）
  ├ 輸出：最佳路徑（音節序列）＋ Top-N 替代切分（供候選窗呈現「重切」選項）
  → 轉注音鍵（沿用 M2 的 helper）
  → 確認／溢位時：Homa.replaceKeys 或 dropKeys+insertKeys 同步
```

**與 SunPinyin 的對應**：

| SunPinyin | 方案 B 對應物 | 說明 |
|---|---|---|
| `CQuanpinSegmentor`（單一 greedy 切分） | `FuriousTypingSegmentor`（DP 最佳切分） | 更進一步：直接以 LM 評分切分 |
| `CGetFuzzySegmentsOp`（模糊切分替代） | DP 的 Top-N 路徑 | 替代切分天然存在，不必另做模糊表 |
| `CIMIContext::searchFrom`（詞級 Viterbi） | Homa DAG-DP | 組句仍交 Homa |
| `CThreadSlm`（trigram） | Homa LM 層（unigram＋bigram） | 可複用，無需新模型 |

**優點**：切分品質質變（詞庫引導、可重切、可呈現替代切分）；完全在「讀音鍵」層面上做，
Homa／LM 零破壞。
**缺點**：需要「整段列舉＋評分」的效能注意（音節數 ~400，buffer ≤ ~30 字母時 DP 成本極低，
可放寬）；需要 M4（重切 API）；替代切分的候選呈現需要 UI 配合。

> 備註：SunPinyin 新版**不對音節切分評分**（§4.2 ⚠️），方案 B 反而比 SunPinyin 更進一步——
> 直接把評分放進切分階段。這在 vChewing 是合理的，因為 Homa 的組句是「以已切分讀音為單位的
> 詞級 DAG」，切分錯誤會在組句前定型；把 LM 分數提前到切分階段，正是現代拼音輸入法的做法
> （切分與組句互相餵養）。

### 6.5 方案 C（長遠）：SunPinyin 式字母級 lattice 引擎

- 以字母為 frame 建字元級 lattice、`TLexiconState` 式的「詞典 trie 累積＋SLM 轉移」；
- 這是最忠實的「狂拼」，但與 Homa 的「音節線性」模型衝突最大：要麼 Homa 升級支援字母級
  lattice，要麼狂拼自帶組句器（重造 SunPinyin 的 ime-core）。
- **本報告不建議近期做**：Homa 的詞級 DAG 已是合格的組句器，方案 B 能在不改 Homa 的前提
  下拿到 90% 的體驗；方案 C 的 C++ 記憶體佈局（512-frame lattice、`TSentenceScore` log-domain
  大數）在 Swift 下重寫成本高、且與 Homa 重疊。

### 6.6 模式切換與 UI

- **切換管道**：仿磁帶模式（`prefs.cassetteEnabled`＋IME 選單熱鍵 Ctrl+Cmd+I，
  `MainAssembly4Darwin/SessionController/IMEMenuSputnik.swift:161-203`）——新增
  `prefs.pinyinFuriousTypingEnabled` 之類的 pref，選單／設定面板各加一項；或併入
  `KeyboardParser` 的選項語義（注意 `KeyboardParser` 在 Shared、`MandarinParser` 在 Tekkon，
  兩邊都要同步）。
- **顯示**：preedit 應仿 SunPinyin `getPreeditString`（`imi_view_classic.cpp:367-426`）——
  已定部分顯示候選句子、尾段顯示「字母流＋切分中的音節」；唯音的 `IMEStateParsed4Darwin`
  attributedString 已有 segment 屬性（底線／標記），可把「未確認尾段」標記成不同樣式。
- **游標與活動區語義**（事主實測觀測智能狂拼 II ＋ 智能狂拼 2008 擷圖）：打字時前段為活動區、
  允許 partial-matching；**游標並非恆在最前方**——2008 擷圖顯示游標可移至句中／後方選字
  （對應文獻提到的「下標定位」局部修正）。若比照此模型，顯示層要支援「整句預覽＋前段活動區＋
  可移動游標」，而非唯音現行「逐音節游標＝組字器位置」；這直接牽動 §5.2-3/4 的硬編碼點
  （游標推導 `convertCursorForDisplay`／`actualNodeCursorPosition`、`readingForDisplay`），
  是 M5 顯示層鬆綁的主要工作量。
- **候選窗**：方案 B 可加「重新切分」候選（如 `fanga` 時列出「fang/a」與「fan/ga」兩條切分
  供選），這是現行 Homa 候選流沒有的概念，需要新的候選型別或標記。

### 6.7 測試策略

1. **Tekkon 層**（純函式）：`FuriousTypingSegmentor` 的切分單元測試——歧義案例：
   `fangan`→`fan/gan`、`xian`→`xi'an` 或 `xian`、`zhong` 不切成 `zh/ong`、簡拼 `shjdaz`；
   以 `makeTypingTextMap` 自訂小型詞庫控制 unigram 權重，驗證 DP 選路。
2. **Typewriter 層**：複製 `MockInputHandler ＋ typeSentence` 模式，以 `typeSentence("fangan")`
   模擬連續字母流，斷言 `assembler.actualKeys`（切分後的讀音序列）與
   `assembledSentence.values`；另測退格、確認鍵、溢位遞交。
3. **回歸**：既有 `pinyinAutoChopResult` 測試保留；`BPMFFullMatchTypewriter` 的注音 keyblock
   路徑不得受 M2 重構影響（89/89 需保持）。

### 6.8 風險與待決問題

1. **M2 重構風險**：`BPMFFullMatchTypewriter` 是注音／拼音全匹配的骨幹，抽 helper 時需逐字節
   保持既有行為；建議先抽再引（test-first）。
2. **Homa 重切一致性**（M4）：整段重切會動到游標、覆寫狀態、POM 記憶鍵；Phase 134/136 已把
   Homa 的座標化寫回紀律做得很嚴，重切 API 必須沿用同一紀律（`dropKey` 的 `KeyDropContext`
   與 `actualNodeCursorPosition` 都假設 1 key＝1 讀音）。
3. **半音節顯示**：狂拼模式下「組字器」與「緩衝區」不同步是常態；游標、退格、聲調覆寫
   （`performRearIntonationOverrideIfNeeded`）等既有功能都以「組字器＝輸入真相」為前提，
   需要逐一檢視。
4. **效能**：方案 B 的 DP 在最長 buffer（~30 字母）下約 400 音節 × 30 位置，數量級 ~10⁴ 次
   LM 查詢——必須走 `hasUnigramsForFast`／LRU 快取路徑，且只在「確認前的最後一拍」跑全量，
   每鍵打字時可只重算尾段（對齊 SunPinyin 的 `updatedFrom` 增量）。
5. **雙拼**：若狂拼要涵蓋雙拼鍵盤，Tekkon 需新增 parser 層（§3.5）；建議首版限全拼。
6. **待決**：狂拼模式下聲調鍵（1–5）的語義（SunPinyin 不處理聲調、現代輸入法聲調是強提示）；
   不完整拼寫的處理——已定調：**共用同一條字母流、不設獨立開關**；切分層把完整與不完整音節
   都納入候選、以完整匹配優先（§2.2、§6.0-5）。剩餘待決：簡拼「只取聲母」與「任意前綴」的
   邊界——事主觀測：中文之星早期簡拼為「每字母＝一個音節聲母佔位」的嚴格聲母級（`dn`→`d n`）、
   SunPinyin 的 `combineInitialTrans` 同為聲母級；現代輸入法另有容錯前綴。

---

## 七、結論

1. 唯音**已有狂拼雛形**（`PinyinTrie.chop` ＋ `pinyinAutoChopResult` ＋
   `performPinyinAutoChopIfNeeded`），但其「單拍觸發、greedy 無回看、提交即鎖死」的性質
   與真正的狂拼體驗有明確差距；差距清單見 §3.4。
2. **模組化接縫已經存在**（`TypewriterProtocol`＋`handleComposition` 分派、磁帶模式的
   「任意字串當讀音鍵」先例、Homa 的 `PossibleKey` 多讀音支援），新增 `FuriousTypingTypewriter`
   的掛載點明確；剩下的工作是把 §5.2 的硬編碼點掃平（前置模組化 M1–M6）。
3. SunPinyin 提供了完整的參考藍本（segmentor／lattice／SLM 分層、增量重算、已選詞鎖定），
   但**不需要照搬 C++ 架構**；唯音可以在「讀音鍵」層面用 Homa 既有 LM 做 DP 切分
   （方案 B），以最小破壞換取質變。演算法參考另可並列 libpinyin（GPL-3.0）、架構參考可看
   Rime 的拼寫代數（`abbrev`／`derive`）與 segmentor 機制。
4. 建議路徑：**前置模組化（M1–M3）→ 方案 A′（copilot 尾段預覽＋Inputting 就地選字，第一版）
   → 方案 B（LM 引導切分）**分階段進行；雙拼確定不做（§3.5 事主決策：需求由磁帶承載）、
   字母級 lattice（方案 C）列為長遠評估。
5. 歷史考證已完成：智能狂拼約 2000 年由中文之星推出；哈工大與微軟的語句級輸入技術合作
   早於其（微軟拼音 1.0 約 1996 年）；「狂拼」可確認是中文之星的品牌命名（非哈工大／微軟
   首創術語）。驗證詳見 §2.4 與 `Phase148_WebSearchedResources.md`。

---

## 八、施術定稿（2026-08-26 覆議：Kimi K3 接手，覆議 Deepseek 原方案）

> 背景：原研究的建議路徑以方案 B（LM 引導 DP 切分）為最終目標。接手覆議後的結論：
> **第一刀採「方案 A′ 核心子集」——隱藏 pref ＋ copilot 尾段預覽**，且對原 A′ 提案做三處修正。

### 8.1 覆議結論：P149 的施術範圍

| 項目 | 定稿 | 理由 |
|---|---|---|
| copilot 尾段預覽 | ✅ 施術 | 狂拼體驗的核心（實時預覽）；`Homa.Assembler` 為 `final class` 且內建 `copy`（`Homa_Assembler.swift:127`，值語義深拷貝、節點互不干擾），暫態組句天然可行 |
| 隱藏 pref 開關 | ✅ 施術 | `UserDef`＋`PrefMgrProtocol`＋`PrefMgr_Core` 三檔案模式；**後續於同一 Phase 補齊設定面板（行為選項卡 Ｅ／SwiftUI 行為頁最底端）＋四語 L10n＋IME 選單項** |
| 獨立 `FuriousTypingTypewriter` | ❌ 不施術 | 狂拼的基礎按鍵行為（自動 chop 急切提交）與 `BPMFFullMatchTypewriter` 完全一致；預覽屬於「狀態生成層」而非「按鍵處理層」。**過早建立空殼 typewriter 是過度模組化**；待出現狂拼專屬按鍵行為（就地選字）再切出 |
| nullable copilot compositor 屬性 | ❌ 修正為無狀態函式 | 長駐屬性需跨拍同步 main 組字器與注拼槽，是 bug 溫床；copilot 的全部輸入（`assembler.config`＋`composer.romajiBuffer`）皆已在 handler 上，**每拍重新推導、用完即棄**，同步問題從根上消失 |
| Inputting／Candidate 視窗混合 | ❌ 延後 | 既有 `revolveCandidate`（Inputting 狀態下 Shift+Space 就地輪替）已提供最低限度就地干涉；候選窗常駐顯示是 MainAssembly／Session 層的 UI 工作，另立 Phase |
| 方案 B（LM 引導 DP 切分） | ❌ 維持後續升級 | 需要 M4 重切 API 與切分器介面化（M3）；A′ 核心子集已能交付可觀察的狂拼體驗 |

### 8.2 修正點對照（相對於原 A′ 提案）

1. **無狀態暫態組句**：`var copilot = assembler.copy` → `insertKeys([尾段桶])` → 讀
   `assembledSentence` → 丟棄。無任何跨拍狀態。
2. **尾段桶生成規則**：`composer.romajiBuffer` 恆為「至多一個音節量」的暫存（完整音節或合法前綴）
   ——完整音節查 `parser.mapZhuyinPinyin` 取精確注音、不完整前綴以 `PinyinTrie` 前綴查詢展開全部
   可能注音，各自再乘上五聲調變體（沿用既有 `makeToneInsensitivePinyinQueryKey` 的展開語義）。
   `PinyinTrie.search` 原為 Tekkon 內部 API，需新增一個 public 前綴→注音桶介面。
3. **啟用閘門**（全部成立才預覽）：pref 開啟 ＋ 非磁帶 ＋ 拼音模式 ＋ romajiBuffer 非空 ＋
   無聲調暫存 ＋ 游標在組字區最前端。關閉時零行為差異（既有測試必須原樣通過）。
4. **遞交語義**：狂拼模式下 Enter 遞交＝main 組句結果 ＋ 尾段預覽猜測（預覽即遞交，狂拼本意）；
   預覽啟用時 tooltip 顯示原始拼音字母流，保留使用者對實際敲鍵內容的可見性。

### 8.3 實作清單（檔案級）

| 套件 | 檔案 | 變更 |
|---|---|---|
| vChewing_Tekkon | `Tekkon_PinyinTrie.swift` | 新增 public 前綴→注音桶 API `zhuyinReadings(forPinyinFragment:)`（完整音節取精確、否則前綴展開、去重排序保證輸出穩定） |
| vChewing_Shared | `UserDef/UserDef.swift`、`Protocols/PrefMgrProtocol.swift`、`PrefMgr_Core.swift` | 新增 `furiousTypingEnabled`（預設關閉、metaData 為 nil） |
| vChewing_Typewriter | `InputHandler/InputHandler_HandleStates.swift` | 新增預覽計算屬性 `furiousTypingPreviewedReading`；`generateStateOfInputting`／`committableDisplayText` 以預覽取代原文顯示；tooltip 顯示原始拼音 |
| vChewing_Typewriter | `Typewriter/Typewriter_BPMFFullMatch.swift` | 狂拼模式專屬分支：注拼槽有暫存拼音時 Enter 直接遞交「組字區內容＋尾段預覽」（狂拼的定義性遞交手勢） |
| vChewing_Typewriter | `Tests/TypewriterTests/` | 新增狂拼預覽測試（pref 開啟時尾段顯示組句猜測、關閉時維持原文、Enter 直遞預覽） |

### 8.4 已知取捨（語義差異記錄）

- copilot 組句會以尾段 bigram 重估前段末節點的顯示猜測——屬預覽的正確行為（整句預覽本應如此），
  但**遞交時 main 組字器的句面可能與預覽在邊界處略有出入**；v1 接受、記錄在此。
- POM 不觀察尾段（尾段未進 main 組字器）；使用者對尾段預覽的覆寫需透過就地輪替或 BackSpace
  重打，學習行為與既有逐音節確認一致。
- 游標不在最前端時（使用者把游標移進句子中間）預覽停用、回到原文顯示。
- 聲調暫存時預覽停用（與 `pinyinAutoChopResult` 的防衛條件一致）。

### 8.5 P149 施術後備忘（2026-08-26 補記）

P149 已完工（macOS `8347ea2c`／Legacy `1da063ec`）：方案 A′ 核心子集落地——隱藏 pref
`furiousTypingEnabled`、Tekkon `zhuyinReadings(forPinyinFragment:)`、Typewriter
`furiousTypingPreviewedReading`（無狀態暫態組句）＋ Enter 直遞預覽；詳見
`Reqs_0141-0150.md` Phase 149。

**已知缺口（備忘）——copilot candidate window**：P149 完成形態**缺乏「Inputting 狀態下針對
尾段讀音桶的常駐候選窗」**，僅有「尾段組句預覽＋tooltip 顯示原文」與 `revolveCandidate`
（Shift+Space）就地輪替。SunPinyin（`getCandidateList`：整句／尾段／詞三層候選）、智能狂拼
（前段 partial-match 候選窗）、搜狗拼音（輸入中候選條）皆具備此要件；屬 §6.6 與 §8.1 所記
「Inputting／Candidate 視窗混合」的具體形態，**另立 Phase 施作（與方案 B 正交，可先行）**。

---

## 九、P150 施術定稿（2026-08-26：copilot 候選窗＋方案 B 落地；Kimi K3 設計、Deepseek-v4-flash 施術）

> 本節記錄 §8.5 所列兩項後續任務的**實作定稿與重要取捨**。詳細檔案級變更見
> `Reqs_0141-0150.md` Phase 150。

### 9.1 copilot 候選窗（Inputting 狀態常駐候選＋Shift＋選字鍵就地干涉）

- **掛載點採「仿磁帶 quick-candidate」路線**（不仿 SCPC 切 state）：`generateStateOfInputting`
  在狂拼閘門成立時直接把尾段候選附加到 Inputting state 的 `candidates`；
  `IMEState.isCandidateContainer` 對 `.ofInputting` 的既有定義（`!candidates.isEmpty`）讓
  候選窗顯示／隱藏／每拍重載全部走既有機制，**零新 UI 機制**。
- **候選清單**：置頂＝copilot 預覽猜測值（`keyArray`＝尾段桶）；其餘＝
  `lookupHub.grams(for: [.multipleKeys(尾段桶)])` 依原序、按 value 去重、剔除與置頂重複者。
  與 SunPinyin「整句／尾段／詞三層」的差異：整句層由 preedit 預覽本體與 Enter 直遞承擔，
  不重複進候選窗（刻意簡化）。
- **選字手勢**：Shift＋選字鍵（不帶 Shift 的數字鍵維持聲調鍵原語義）。`shaltShiftHold`
  增列狂拼條件使 Shift+1 的 `inputTextIgnoringModifiers` 能比對選字鍵；路由仿磁帶
  `processCassetteQuickSelection` 在 `BPMFFullMatchTypewriter.handle` 最前端攔截。
  滑鼠點選走既有 `candidatePairSelectionConfirmed` 委派（`.ofInputting` case 新增狂拼分支）。
- **確認寫回**：`confirmFuriousTailCandidate`——置頂候選插入單一 `multipleKeys` 位置
  （與 copilot 同構），其餘候選逐讀音插入 `.singleKey`（**簡拼語義**：使用者只打前綴、
  選中詞的全部讀音進組字器），然後對新 span 做 `.withSpecified` 覆寫（仿 `consolidateNode`
  的 POM 觀察接法），清空注拼槽。
- **已知取捨**：置頂候選的覆寫必然靜默失敗（其 keyArray＝尾段桶、非具體詞音配對，Homa
  `overrideCandidate` 找不到對應 keyArray）——但插入的桶與 copilot 完全同構、同一 LM 組句
  結果一致，實效等同覆寫成功；方向鍵維持 Inputting 游標語義（不導航候選窗），候選窗
  標籤顯示無 Shift 提示（皆記為 v1 取捨）。

### 9.2 方案 B：LM 引導重切分（generate-and-test）

- **不動 greedy chop 輸入路徑**：自動 chop 照舊急切提交；handler 新增 `furiousTrail`
  （每個 chop 提交的讀音鍵記一筆原始拼音字母 blob）。每次 chop 提交後對 trail 字母流
  重新求最佳切分，勝出才替換。
- **切分器** `FuriousTypingSegmentor`：純閉包注入（`isValidSyllable`／`syllableScore`），
  DP/beam 枚舉 top-8。**v1 約束：僅比較與當前 trail 音節數相同的切分**——跨音節數的
  路徑總分有系統性長度偏差（少一鍵少一項負分），無生成式模型可正規化，記為已知邊界
  （`xian`→`xi'an` 類跨數重切不涵蓋；`fangan`→`fan/gan` 類同數邊界歧義涵蓋）。
- **排名**：用 Homa 自己評分（切分與組句互相餵養的直譯）——Homa 新增最小 API
  `Assembler.mostRecentPathScore`（PathFinder DP 末端值，assemble 時寫回）；逐候選以
  `assembler.copy`＋drop trail 鍵＋插候選鍵試算，嚴格高於當前路徑分才對真 assembler 替換。
- **安全網**：trail 於任何使用者顯式干涉時失效（clear／consolidateNode／revolveCandidate／
  游標移動／手動確認讀音／聲調覆寫／就地選字／溢出遞交），BackSpace 精確 pop；
  重切入口另做強不變量檢查（組字器尾端 keys 與 trail 桶不一致即自癒失效）——
  **重切絕不動到使用者確認過的內容**。
- **SCPC 守衛**（事主指定）：SCPC 模式啟用時狂拼完全無效（預覽、候選窗、Enter 直遞、
  重切全部關閉），三處閘門皆加 `!prefs.useSCPCTypingMode`。
- **已知取捨**：重切生效當拍的顯示滯後一拍刷新（測試以組字器狀態為準斷言）；
  每鍵成本＝top-8 候選 ×（assembler.copy＋drop/insert＋assemble），µs–ms 級、可忽略。

### 9.3 第二波修訂（2026-08-26：觸發鍵固化＋tooltip 抑制；事主與 Deepseek 私聊結論）

事主回饋兩個使用層問題，定稿修法如下（仍歸 P150）：

- **問題一（tooltip 與 copilot 候選窗重疊，直排更嚴重）**：狂拼候選窗顯示時**抑制 tooltip**
  ——原始拼音不再以 tooltip palette 顯示；其可見性改由固化後正常選字窗的 revlookup 承擔
  （`generateStateOfInputting` 的 tooltip 條件加 `candidates.isEmpty`；預覽停用時行為不變）。
- **問題二（打 `shijie` 時 copilot 候選窗沒有跨邊界詞「世界」）**：根因是候選清單只查尾段
  單音節桶。採用**事主提出的「觸發鍵固化」機轉**取代「copilot 窗補跨邊界查詢」——
  狂拼閘門成立且候選窗顯示中，按下「會叫出選字窗的按鍵」（查證定案：Space（±Shift）、
  PageUp／PageDown、橫排 Down、直排 Left／Right 等會導向 `callCandidateState` 的鍵；
  排除 Enter／數字／字母／BackSpace／ESC／Shift+選字鍵）時，`triageInput` 早段先把尾段
  投機讀音**固化**進 assembler（`solidifyFuriousTailReading`：插入尾段桶＋清注拼槽＋
  完整音節 append trail／不完整前綴則 trail 失效＋POM apply），然後**原事件不重入、
  直接續走正常流程**——正常流程對已提交讀音序列開出正常選字窗，「世界」自然在列，
  且方向鍵導航／翻頁／revlookup／直排佈局全部由既有機制免費提供（MainAssembly 層
  零新交互程式碼）。
- **手勢分工定稿**：Shift+選字鍵＝不固化就地選字（保持投機、可繼續打字母）；
  觸發鍵＝固化進正常選字窗；Enter＝狂拼直遞預覽（不變）。
- **連帶修正**：IH116A 的 tooltip 斷言隨行為變更更新（改斷言 tooltip 為空＋候選非空）。

### 9.4 第三波修訂（2026-08-26：跨邊界候選＋copilot 窗 revlookup；事主回饋）

事主實測再抓兩個問題，定調**必須在 P150 收掉**（§9.3 把跨邊界候選定調為「冗餘」是錯的——
直接按 Enter 遞交的使用者不經固化，copilot 窗缺跨邊界詞對他們是實害）：

- **copilot 窗補跨邊界候選**：`buildFuriousTailCandidates` 在置頂預覽與尾段單音節查詢之間
  追加雙鍵查詢 `grams(for: [assembler.keys.last, .multipleKeys(尾段桶)])`（「最後提交鍵＋
  尾段」邊界，如 `shijie` 的「世界」）；全程同一去重。`confirmFuriousTailCandidate` 新增
  跨邊界分支：結構性判定（`keyArray.count == 2` 且首讀音 ∈ 最後提交鍵 `allValues`）→
  僅插尾段單鍵、覆寫錨點改 `anchor-1` 的雙鍵 span（其餘覆寫／POM／失敗防禦共用既有段）。
  Enter 直遞語義不變；assembler 為空（首音節在注拼槽）時不查跨邊界。
- **copilot 窗 revlookup 顯示未固化讀音**：既有反查僅磁帶供給
  （`InputSession_Delegates.reverseLookup(for:)`），拼音狂拼窗恆空。在總開關
  （`showReverseLookupInCandidateUI`）與縱排守衛之後插入狂拼分支：狂拼閘門＋注拼槽非空
  → 回傳 `[romajiBuffer]`（使用者敲入的原始拼音字母流，如 `jie`／`z`）。磁帶專用守衛
  （空字串／含 `_`）在狂拼分支之後、不誤傷。（後於 §9.5 再修訂位置。）

### 9.5 第四波修訂（2026-08-26：置頂跨界詞＋讀音回顯繞過反查守衛；事主實測回饋）

- **置頂候選＝copilot 跨界節點完整詞**：打 `shijie` 時置頂原本是「界」（越界尾段 suffix）、
  「世界」排第二。`furiousTailContext` 擴充回傳 `crossingPair`——copilot assembledSentence
  最後節點若橫跨邊界（`totalKeyCount - lastGram.keyArray.count < mainLength`），置頂候選
  用該節點的完整詞音配對（「世界」）；無橫跨節點時維持尾段桶置頂。preedit 的尾段 suffix
  顯示不變。確認端三路徑判定順序：`keyArray == bucket`（置頂無橫跨）→ 前 n-1 讀音逐位
  隸屬最後 n-1 提交鍵桶（跨邊界 n≥2，僅插尾段單鍵、錨點 anchor-(n-1)）→ 尾段單音節
  grams；`== bucket` 必須先行排除（桶 count≥2 且桶首讀音可能隸屬提交鍵桶，否則泛化
  判定誤判）。
- **讀音回顯不受反查守衛節制**：§9.4 把狂拼 revlookup 分支放在磁帶反查總開關與縱排守衛
  **之後**是錯的——事主關閉總開關或用縱排就永遠看不到。狂拼的讀音顯示**不是反查**：
  它是使用者敲入字母流的即時回顯，且是 tooltip 抑制（§9.3）後敲鍵內容的唯一可見管道。
  分支移至 `reverseLookup(for:)` 函式最頂端（所有守衛之前），刻意繞過
  `showReverseLookupInCandidateUI` 與 `isVerticalTyping` 兩道守衛（註解已寫明理由）。

### 9.6 第五波修訂（2026-08-26：顯示與遞交改為 copilot 全句同源＋方向鍵固化；事主回饋）

- **composition buffer 與 Enter 遞交改為 copilot 全句組句同源**：§8.4 第一條取捨（「遞交時
  main 組字器的句面可能與預覽在邊界處略有出入」）就此消解——現況顯示是「main 自己組句＋
  尾段 suffix」拼接（`shijie` 顯示「是界」、Enter 遞出「是界」），改為：狂拼啟用時
  `displayTextSegments` 的主段取自 **copilot 聯合組句的主段範圍擷取**（完全在主段的節點
  取全部 value、橫跨邊界節點按覆蓋鍵數取 prefix——與尾段 suffix 擷取同一次遍歷、嚴格
  鏡像，含「value 長度≠讀音數」節點紀律），尾段 suffix 維持 reading 槽位樣式；
  `committableDisplayText` 同源（Enter 遞出「世界」）。分段數可能與 main 不同，故狂拼
  分支下游標恆置主段末端、BPMFVS 的 rawSegments 退位 nil（狂拼關閉零行為差異）。
- **前／後方向鍵納入固化觸發鍵**：`isCursorForward`／`isCursorBackward` 加入 T3 掛鉤
  （Shift 組合不排除，固化後續走正常標記流程）。縱橫排映射後全方向鍵皆有合理語義：
  時鐘向（開選字窗）四键 T3 已入，前後向（游標移動）本波補齊——縱排 Down 從「不觸發」
  變「固化＋游標前移」。固化後游標移動依 T2 紀律令 trail 失效（游標離開最前端），
  屬設計行為。

### 9.7 第六波修訂（2026-08-26：閘門共用 API＋高亮預覽＋方向鍵新規則；事主回饋）

- **閘門抽象**：散落的同一條件鏈抽象為三個共用 API——`InputHandlerProtocol` 的
  `isFuriousTypingModeEffective`（TypingMethod＋三 pref＋拼音模式）與 `hasFuriousTailPending`
  （＋注拼槽非空），`SessionCoreProtocol` 的 `isFuriousCopilotCandidateWindowVisible`
  （`.ofInputting`＋`isCandidateContainer`＋tail pending；生產 Session 與 MockSession 共用）。
  十一處呼叫點（閘門／掛鉤／shaltShiftHold／reverseLookup／Enter／confirm／resegmentation／
  委派雙分支／W2-W3 新碼）全部改用，行為保持。
- **copilot 窗高亮即時反映組字區（不計 POM）＋ Enter 確認高亮（遞交計 POM）**：
  「套用候選」邏輯抽為 `applyFuriousTailCandidate`（三路徑、可對任意 assembler 施作、
  三態 outcome 精確區分插入失敗／覆寫失敗／成功——覆寫失敗保留插入且不觀察 POM 的既有
  語義靠三態保住）；`candidatePairHighlightChanged` 狂拼分支以 scratch 套用構建預覽 state
  （繞過 switchState、保留 candidates、不碰真組字器／POM／trail／注拼槽），override 於
  下次真按鍵（`generateStateOfInputting`）歸零。狂拼 Enter 統一為「確認當前高亮候選
  （預設置頂）＋遞交」——**§8.4「POM 不觀察尾段」的取捨對狂拼 Enter 就此改寫**：
  遞交時對確認候選做 POM 記憶（受 `fetchSuggestionsFromPerceptionOverrideModel` 節制；
  置頂 bucket 候選覆寫靜默失敗時不觀察，遞交文字不變）。
- **方向鍵新規則**（事主重新規定）：注拼槽有未完成讀音（`!composer.isEmpty`）時 Inputting
  不受理前後方向鍵游標移動——非狂拼（或狂拼窗不可見）→ error callback；狂拼窗可見 →
  固化＋`switchState(generateStateOfCandidates())` 開正常選字窗＋同一事件 `handleCandidate`
  重 triage 導航高亮。落點 `handleForward/handleBackward` 入口新守衛，僅攔無修飾方向鍵
  （Shift＋方向鍵標記模式不變）；T3/T6 triage 掛鉤觸發集**移除**前後方向鍵（時鐘向保留）。
  追蹤定案：現況吞鍵點即 `handleForward/handleBackward` 的 `!isComposerOrCalligrapherEmpty`
  守衛（errorCallback B3BA5257/6ED95318），新規則在同一扼點接管。
- **覆議補記**（Kimi K3 對事主思路的審查）：補上「狂拼開啟但窗不可見（游標非最前端）→
  error callback」的未定義分支；Shift＋方向鍵維持現況；triage 掛鉤與新規則的觸發集衝突
  必須移除前後方向鍵（已執行）。

### 9.8 第七波修訂（2026-08-26：Shift＋方向鍵的補述規定；事主補述）

事主補述「有未完成讀音」時 **Shift＋前後方向鍵**的行為：**將讀音插入 main compositor →
同一事件續走（重新 triage）→ 直接觸發 marking state**。落點與 W3 守衛同扼點
（`handlePendingReadingCursorKeys` 擴充，修飾鍵攔截從含 Shift 改為 Shift 進專屬分支）：

- 狂拼窗可見 → `solidifyFuriousTailReading()`（完整與不完整前綴皆可）→ 放行續走標記流程；
- 非狂拼（或窗不可見）→ 新增 `commitPendingReadingIfCompletable()`：複用 Space 確認讀音
  的判定語義（無調拼音展聲調桶＋`hasUnigramsForFast` 在庫驗證＋insertKey＋清注拼槽），
  但**無調拼音以 `mapZhuyinPinyin` 完整音節命中為門檻**（比 Space 的
  `composeReadingIfReady` 嚴格——後者會把不完整前綴如 `z` 以部分音節 ㄗ 插入；不完整
  前綴不該被盲目猜測插入）——插入成功放行進標記、失敗（不完整前綴）維持 error callback。
- 放行後注拼槽已空，`handleForward/handleBackward` 的 Shift 分支自然生成 `.ofMarking`，
  無遞迴；trail 於標記進入點依 T2 紀律失效。縱排 Shift+Left/Right 屬時鐘向鍵（輪替語義），
  不在本規則範圍。

### 9.9 第八波修訂（2026-08-26：Shift+方向鍵堆疊溢位崩潰修復＋T8 範圍收斂；事主回報）

- **崩潰根因**（事主提供 .ips；Kimi K3 分析定案）：EXC_BAD_ACCESS／KERN_PROTECTION_FAILURE
  ＝無限遞迴。循環鏈：① `triageInput` 的 `.ofInputting` 分支中 **`handleComposition` 先於
  `triageByKeyCode` 執行**，Shift+方向鍵先到 typewriter；② T1 路由器
  `furiousShiftCandidateSelection` 對**任意** Shift 壓住鍵路由進 `handleCandidate`；
  ③ `handleCandidate` 的「取消選字」分支（本是給正常 ofCandidates 窗的設計）命中
  Shift+前後方向鍵 → `switchState(generateStateOfInputting())`（注拼槽未動、候選重新
  附掛）→ `return triageInput(event:)` → 回到①，無限循環。**自第一波（T1）即潛伏**，
  第七波的功能促使使用者按下 Shift+方向鍵而暴露；既有測試沒抓到是因為 `handleCandidate`
  入口有 `ctlCandidate.visible` 守衛而 Mock 候選控制器預設不可見。
- **修復**：路由器加「該鍵確為選字鍵」預篩（`inputTextIgnoringModifiers` ∈
  `session.selectionKeys`，與 `checkSelectionKey` 同語義、不寫死數字）——Shift+方向鍵
  落回正常流程（typewriter 回 nil → triageByKeyCode → handleBackward → T8 守衛）。
  dismiss 分支本身不動（正常選字窗的既有行為；修復點在路由器）。回歸測試以
  `mockCandidateController(visible: true)` 復現生產條件：修復前實測測試進程 SIGSEGV、
  修復後通過（紅綠對照成立）。
- **T8 範圍收斂**（事主明確）：Shift+方向鍵「讀音插入→重 triage→標記」規定**僅狂拼
  有效**；非狂拼的 `commitPendingReadingIfCompletable()` 路徑屬行為溢出，刪除——非狂拼
  Shift+方向鍵遇未完成讀音恢復既有 `!isComposerOrCalligrapherEmpty` 守衛的 errorCallback
  行為（errorCallback ID 隨之回到既有 ID）。`furiousToneInsensitiveBucket` 改回 private。
- **連帶修正**：§9.8 記述的非狂拼 `commitPendingReadingIfCompletable()` 路徑以此節為準
  （已廢除）；非狂拼的 Shift+方向鍵行為維持 T8 之前原樣。

---

## 附錄 A：檔案地圖（唯音側）

| 檔案 | 角色 |
|---|---|
| `T/Typewriter/TypewriterProtocol.swift` | 打字器協定（模組化接縫） |
| `T/Typewriter/Typewriter_BPMFFullMatch.swift` | 注音／拼音全匹配（狂拼雛形的消費端） |
| `T/Typewriter/Typewriter_Cassette.swift` | 磁帶打字器（「任意字串當讀音鍵」先例） |
| `T/InputHandler/InputHandler_HandleComposition.swift` | 分派 switch（掛載點） |
| `T/InputHandler/InputHandler_TypingMethod.swift` | `TypingMethod` enum（模式枚舉） |
| `T/InputHandler/InputHandler_CoreProtocol.swift` | `InputHandlerProtocol`（ensureKeyboardParser、游標推導） |
| `T/InputHandler/InputHandler_HandleStates.swift` | 狀態生成／退格／游標顯示 |
| `Tek/Tekkon_SyllableComposer.swift` | 注拼槽（聲介韻調＋romajiBuffer、`pinyinAutoChopResult`） |
| `Tek/Tekkon_PinyinTrie.swift` | `PinyinTrie`（`chop`、`deductChoppedPinyinToZhuyin`、音節庫存） |
| `Tek/Tekkon_Phonabets.swift` | `MandarinParser`（100–105 全拼；無雙拼） |
| `H/Homa_Assembler.swift` | 組字器（`insertKey(s)`／`dropKey`、在庫驗證） |
| `H/Homa_BasicTypes/Homa_PossibleKey.swift` | `PossibleKey`（單／多讀音） |
| `MainAssembly4Darwin/SessionController/InputSession_HandleEvent.swift` | 鍵盤佈局翻譯條件 |
| `MainAssembly4Darwin/SessionController/IMEMenuSputnik.swift` | 模式選單／熱鍵 |
| Legacy 鏡像 | `vChewing-OSX-legacy/Shared/vChewingComponents/Typewriter/`（逐字節鏡像，手術時需同步） |

## 附錄 B：SunPinyin 檔案地圖

| 檔案（`SunPinyinLatestCommit/` 下） | 角色 |
|---|---|
| `src/pinyin/pinyin_seg.cpp:379-474` | `CQuanpinSegmentor::_push`（倒序最長匹配、尾部重切） |
| `src/pinyin/segmentor.h` | `IPySegmentor` 介面（`push/pop/insertAt/deleteAt/updatedFrom`） |
| `src/pinyin/datrie_impl.h:140-160` | double-array trie 最長匹配 |
| `src/pinyin/shuangpin_seg.cpp:285-337` | `CShuangpinSegmentor`（每 2 字母 1 音節） |
| `src/pinyin/hunpin_seg.h` | 混拼 |
| `src/ime-core/imi_context.cpp:146/384/485` | `buildLattice`／`searchFrom`（beam-Viterbi）／`_transferBetween` |
| `src/ime-core/lattice_states.cpp:172-205` | `CLatticeStates`（beam 剪枝，寬 48） |
| `src/slm/slm.h:50-71` | `CThreadSlm`（backoff bigram＋trigram、量化、threaded backoff） |
| `src/lexicon/pytrie.h` | `CPinyinTrie`（詞典、多音節詞累積、不完整音節支援） |
| `src/ime-core/imi_view_classic.cpp:367-426` | `getPreeditString`（整句＋尾段顯示） |
| `src/ime-core/imi_context.cpp:929-940/495-497` | `makeSelection`（已選詞鎖定） |
| `python/quanpin_trie_gen.py:46`、`python/pinyin_data.py:69-100` | 音節表與反轉 trie 資料產生 |

## 附錄 C：歷史考證的外部代理驗證

- 執行方式：把研究 prompt（A：歷史考證／B：技術內涵／C：參考實作三節、逐條附來源網址、允許
  「查無可靠來源」）交付事主，由三個外部代理（Perplexity、豆包、Google Gemini Pro）各自以
  網路搜尋執行；原始結果全文見同目錄 `Phase148_WebSearchedResources.md`。
- 交叉比對後已定稿於 §2.4；三份報告結論一致，個別出入（發布日、授權 vs 收購表述）已在
  §2.4 標註。

## 附錄 D：本次調查的執行方式

- 探索代理 ×2（背景）：SunPinyin 架構分析（thorough）、Typewriter 管線與模組化分析（thorough）；
- 第一手研讀：`Typewriter_BPMFFullMatch.swift`、`Tekkon_PinyinTrie.swift`、
  `Tekkon_SyllableComposer.swift`（`PinyinAutoChopResult`／`pinyinAutoChopResult`）、
  `TypewriterProtocol.swift`、`InputHandler_HandleComposition.swift`、`InputHandler_TypingMethod.swift`、
  `HomaAssemblerCompat.swift`；
- 事實核對：`MandarinParser` case 清單（100–105 全拼）、Tekkon 全倉「雙拼」零命中、
  Legacy 鏡像路徑（`vChewing-OSX-legacy/Shared/vChewingComponents/Typewriter/`）；
- 歷史考證：外部代理網路驗證（`Phase148_WebSearchedResources.md`）。
