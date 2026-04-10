# LibVanguard - 格物致知專用文件

> 本文檔供 AI Agent 在每次幹活前迅速了解專案全貌。
> 最後更新：2026-04-20（下游 Phase 33 Legacy transplant / mirror audit completion）
> AI Agent 得特別注意本文所提到的「Response Pattern」。

---

## 一、專案概述

**LibVanguard**（先鋒引擎）是 vChewing Project 下一代輸入法的引擎的核心套件庫，以 Swift Package 形式提供。專案採用 LGPL v3.0 授權，涵蓋從注音符號解析、辭典樹查詢、語言模型聚合、到組字引擎的完整輸入法管線（pipeline）。

- **Swift 工具版本**：6.1
- **最低平台支援**：macOS 15 / macCatalyst 18 / iOS 18 / visionOS 2
- **跨平台目標**：保持對 Linux 與 Windows 的可建置性（透過 `#if canImport(Darwin)` 條件編譯平台限制）。

> 該專案本身不應視為 vChewing 唯音輸入法的一部分，除非今後刻意有此安排。

---

## 二、專案架構

### 2.1 目錄結構

```
[REPO_ROOT]/
├── Package.swift                    # SPM 套件定義（含 @resultBuilder DSL）
├── makefile                         # lint / format / test / dockertest 指令
├── EVOLUTION_MEMO.md                # 各模組研發備忘錄
├── CSQLite3/                        # 本地 SQLite3 C 套件依賴
├── Sources/
│   ├── LibVanguard/
│   │   └── LibVanguard.swift        # 主模組（重新匯出所有子模組）
│   └── _Modules/
│       ├── BrailleSputnik/          # 盲文點字轉換
│       ├── CandidateKit/            # 候選字池資料型別
│       ├── Homa/                    # 護摩組字引擎
│       ├── LexiconKit/             # 語言模型聚合中樞
│       ├── SharedCore/             # 共用協定、型別、狀態機
│       ├── SwiftExtension/         # Swift 語言擴展與鍵盤映射
│       ├── Tekkon/                 # 注拼引擎（聲韻並擊）
│       └── TrieKit/                # 辭典樹（RAM Trie + SQLite Trie + TextMap Trie）
├── Tests/
│   ├── LibVanguardTests/           # 主模組佔位測試
│   └── _Tests4Components/          # 各子模組測試
│       ├── _HomaSharedTestComponents/   # Homa 測試共用元件
│       ├── _SharedTrieTestDataBundle/   # 預編譯 Trie 測試資料
│       ├── BrailleSputnikTests/
│       ├── CandidateKitTests/
│       ├── HomaTests/
│       ├── LexiconKitTests/
│       ├── SharedCoreTests/
│       ├── TekkonTests/
│       └── TrieKitTests/
├── DevPlans/                       # 開發計畫與 LLM 知識文件
│   ├── LibVanguard-KnowledgeMemo4LLM.md  # 本文件
│   ├── LibVanguard-DevReqsHistory.md     # 開發階段歷史
│   └── Reqs4LLM/                         # Phase 需求文件
└── LICENSES/                       # 授權文件
```

### 2.2 技術架構

模組依賴關係（上層依賴下層）：

```
LibVanguard (主整合模組)
├── CandidateKit ── SharedCore ── SwiftExtension
├── Tekkon
├── BrailleSputnik ── Tekkon
├── TrieKit ── CSQLite3
├── Homa
├── LexiconKit ── TrieKit + Homa
└── SharedCore
```

**公開產品（Products）**：LibVanguard、TrieKit、Tekkon、Homa、SharedCore、CandidateKit
**內部模組**（不匯出）：BrailleSputnik、SwiftExtension、LexiconKit

---

## 三、核心資料模型

| 型別 | 模組 | 用途 |
|------|------|------|
| `Homa.Gram` | Homa | 元圖單位（Unigram/Bigram），承載讀音、字詞、機率、前驗詞 |
| `Homa.Node` | Homa | 組字節點，含元圖陣列、覆寫狀態、Bigram 快取 |
| `Homa.Segment` | Homa | 字詞幅節，`[Int: Node]` 字典（鍵為幅節長度） |
| `Homa.Assembler` | Homa | 組字核心處理器，持有遊標、段落、配置、動態規劃演算法 |
| `VanguardTrie.Trie.TNode` | TrieKit | Trie 節點，含 id / readingKey / children / entries |
| `VanguardTrie.Trie.Entry` | TrieKit | Trie 詞條，含 value / typeID / probability / previous |
| `Tekkon.Phonabet` | Tekkon | 單注音符號（Unicode Scalar + PhoneType） |
| `Tekkon.Composer` | Tekkon | 音節合成器，逐字元組合注音 |
| `CandCellData` | CandidateKit | 候選字格資料型別 |
| `CandidateNode` | SharedCore | 候選字樹形結構（分層候選字） |
| `Lexicon.HomaGramTuple` | LexiconKit | Homa 元圖格式元組（keyArray + value + probability + previous） |

---

## 四、核心組件詳解

### 4.1 Tekkon — 注拼引擎

負責注音符號與拼音的解析、輸入法鍵盤映射。

- **`Tekkon.Composer`**：音節合成器，接收按鍵輸入並組合出完整的注音音節。
- **`Tekkon.MandarinParser`**：支援 11 種注音排列（大千、ETen、許氏、IBM、星光等）與 6 種拼音風格（漢語拼音、耶魯、韋氏等）。
- **`Tekkon.PinyinTrie`**：簡化版拼音辨析 Trie，用於狂拼輸入的 `chop()` 拆解。
- **轉換 API**：`cnvPhonaToHanyuPinyin`、`cnvHanyuPinyinToPhona` 等注音⇄拼音雙向轉換。

### 4.2 TrieKit — 辭典樹

支援對讀音的多音字首字元檢索配對，分三種實現：

- **`VanguardTrie.Trie`**（記憶體型）：全 RAM 常駐、無 QueryBuffer、支援 Codable（Plist）序列化。亦支援 **Vanguard Pragma TextMap 格式**讀寫（見下方說明）。
- **`VanguardTrie.SQLTrie`**（SQLite 型）：DFD 硬碟直讀，僅用於原廠辭典，內建 7 秒 QueryBuffer 惰性清理快取。Phase 05 起單節點查詢會重用 cached prepared statement；在完整 Lexicon partial-match 場景下，剩餘性能瓶頸主要來自 SQLite fetch pattern 本身。
- **`VanguardTrie.TextMapTrie`**（TextMap 惰性型）：將原始 `.txtMap` 檔案以 `Data` 常駐記憶體（~15 MB），以 byte range 持有 KEY_LINE_MAP 索引而不持久化 `readingKey` 字串，僅在查詢時按需解析對應 VALUES 行。穩態記憶體約為全物化 Trie 的三分之一。內建 7 秒 QueryBuffer 快取已解析節點，並沿用既有字串快取避免熱路徑 allocation。（Phase 11 曾嘗試 DFD 模式以 `pread()` 取代常駐 Data，但實機測試記憶體反飆升 20~30 MB 而作廢；詳見 Reqs4LLM/Reqs_0011-0020.md。）
- **`VanguardTrieProtocol`**：統一查詢介面，支援 `getNodes(keyArray:, filterType:, partiallyMatch:, longerSegment:)`。
- **特殊功能**：部分比對（不完全讀音）、多音切割（分隔器 `&` 用於拼音→TrieKit 的多候選搜尋）。

#### TextMap 格式概要

`VanguardTrieIO` 提供 `parseTextMap` / `serializeToTextMap` / `loadFromTextMap` / `loadFromTextMapLazy`。`parseValueLine` 為共用的 VALUES 行解析方法，供全物化與惰性兩條路徑共用；RevLookup 由 MainTextMap 自動生成，不再讀取 external `.revlookup`。

TextMap 現行為單一 `.txtMap`（三段式 PRAGMA：HEADER / VALUES / KEY_LINE_MAP）。RevLookup 不再有獨立 sidecar，而是由 runtime 依 MainTextMap 自動構建。VALUES 行有三種型別：

- **型別 A 合併行** `>typeID\tencodedCell`：具有 DEFAULT_PROB 的 typeID 條目按讀音合併為單行，grouped cell 使用 escaped pipe 編碼。
- **型別 B CHS/CHT 機率分組行** `@probability\tchsCell\tchtCell`：僅限 `TYPE=TYPING`。`@` 前綴用來消除與一般三欄個體行的歧義，grouped cell 同樣使用 escaped pipe 編碼，BEL (`\u{7}`) 佔位空側。
- **型別 C 個體行** `value\tprobability\ttypeID[\tprevious]`：不具備 DEFAULT_PROB 或需要 Bigram `previous` 的條目。

完整格式規格引用：`DevPlans/Reqs4LLM/Reqs_0000-0010.md` Phase 02 格式規格段落。

### 4.3 Homa — 護摩組字引擎

Megrez 的繼任者，實現漢字組句動態規劃演算法。

- **Bigram 支援**：Gram 承載真實讀音；Bigram 描述僅以前驗字詞為準（不糾結前驗讀音）。
- **節點覆寫**：`OverrideType.withTopGramScore`（頂分覆寫）與 `.withSpecified`（明確指定）。
- **候選字輪替與鞏固**：內建 `CandidateAPIs_Revolver`（輪替）與 `ConsolidatorAPIs`（上下文鞏固）。
- **路徑搜尋**：`PathFinder` 以動態規劃 + Unigram/Bigram 結合評分產生最佳組句。
- 取消了舊版 `LangModelProtocol` 協定，改用回調函式（`gramQuerier` / `gramAvailabilityChecker`）。
- **Phase 05 熱路徑最佳化**：`Assembler` 具備跨連續 `insertKey()` 的 bounded gram query cache；`queryGrams(using:cache:)` 以結構化 comparator / hash 去除原本字串插值排序與去重成本。

### 4.4 LexiconKit — 語言模型聚合中樞

整合多種語言模型來源，向上層提供統一查詢介面。

- **`LX_TrieHub`**：Trie 資料庫中樞，管理多個 Trie（原廠辭典等），支援 SQL 與非 SQL 切換。
- **`LX_Perceptor`**：使用者習慣洞察器，基於 Ngram 的行為追蹤，時間衰減三次曲線。
- **`LX_LMPlainBPMF`**：最小化注音語言模型。
- **`LX_GramSupplierProtocol`**：統一所有語言模型來源的元圖供應協定。
- 不負責去重複化（交由 Homa 引擎處理）。

### 4.5 SharedCore — 共用核心

跨模組共用的協定、型別、工具。

- **狀態機**：`IMEApp.StateType`（ofDeactivated / ofEmpty / ofInputting / ofCandidates / ofMarking 等）。
- **協定集合**：`IMEStateProtocol`、`InputSignalProtocol`、`KBEvent`（含 FCITX 擴展）、`PrefMgrProtocol`、`SessionCoreProtocol`。
- **`ChineseConverter`**：繁簡轉換。
- **`CandidateNode`**：樹形候選字結構（符號表分類）。

### 4.6 BrailleSputnik — 盲文點字

- 支援 1947 與 2018 兩種盲文標準。
- 核心 API：`convertToBraille(smashedPairs:, extraInsertion:) -> String`。
- 內含聲介韻調完整映射表與標點符號映射。

### 4.7 SwiftExtension — Swift 語言擴展

- Bool / Double / String / Array / Set 等型別的便利運算符與擴展。
- `LatinKeyboardMappings`：拉丁字母鍵盤映射表。
- `SwiftFoundationImpl`：Foundation 相容實現（跨平台）。

---

## 五、已實作功能清單

- 注音符號與拼音的雙向解析與轉換（Tekkon）
- 11 種注音排列 + 6 種拼音風格支援（Tekkon）
- RAM 常駐 Trie + SQLite DFD Trie + TextMap 惰性 Trie 三模式辭典（TrieKit）
- Vanguard Pragma TextMap 格式讀寫（TrieKit / TrieIO）：三種 VALUES 行型別（`>typeID\tencodedCell` / `@probability\tchsCell\tchtCell` / 個體行），DEFAULT_PROB 壓縮，escaped pipe grouped cell，BEL 佔位空側；RevLookup 由主 `.txtMap` 自動生成
- TextMapTrie 惰性解析（TrieKit）：原始 Data 常駐 + 位元組層級索引，穩態記憶體約為全物化 Trie 的三分之一（Phase 11 DFD 嘗試已作廢）
- 完整 Lexicon partial-match 熱路徑最佳化（Phase 05）：Assembler 跨插入查詢快取、Trie split cache 重用、node.id 去重、SQL prepared statement reuse
- 下游驗證（Phase 06 / Phase 07 Review）：`vChewing-macOS/Packages/vChewing_LangModelAssembly` 已完成以 `vanguardTextMap` 取代 legacy SQLite，採 full-match-only TextMap 存取層（sorted-array key index + binary search + bounded NSCache）。Phase 07 最終規則為：runtime 與測試路徑都不再接受 external `.revlookup` payload；反查只索引 single-segment `@` 分組行內的 ideographic characters，並無條件納入全部 CNS 條目；輸出會將 ASCII phonabet key 還原為注音。
- 不完全讀音部分比對與多音切割查詢（TrieKit）
- Unigram + Bigram 動態規劃組句（Homa）
- 節點覆寫、候選字輪替、上下文鞏固（Homa）
- Homa rare-case candidate revolver / consolidator 修補（Phase 26）：`CandidatePairWeighted.weight` 明確退回語言模型 metadata 身分，不再被當成 `.withSpecified` explicit override score；`consolidateCandidateCursorContext()` 對 overlap range 改以真實 node range 錨定；`revolveCandidate()` 對 non-explicit 且 target span 改變的首輪情形新增條件式 consolidation，並以「句子確實改變 + 目標候選落到邏輯游標 + 節點成為 explicit」作為成功條件。新增 `JiHuQiKeng` rare-case 與 true-node-anchor regressions。
- 多語言模型來源聚合（LexiconKit）
- 使用者習慣 Ngram 洞察與時間衰減（LexiconKit / Perceptor）
- 1947 與 2018 盲文標準轉換（BrailleSputnik）
- 繁簡轉換（SharedCore）
- 完整的輸入法狀態機協定與鍵盤事件協定（SharedCore）
- 下游原廠 VanguardTextMap 非同步載入（Phase 10）：`connectFactoryDictionary` 依 `asyncLoadingUserData` 拆分同步/非同步雙路徑，生產環境在 `fileHandleQueue` 背景佇列完成 Data I/O + FactoryTextMapLexicon 初始化，避免輸入法載入時 1-2 秒 UI 凍結。跨 vChewing-macOS 與 vChewing-OSX-Legacy 兩倉庫。
- ~~下游 FactoryTextMapLexicon DFD 硬碟直讀（Phase 11，已作廢）~~：實機測試記憶體飆升 20~30 MB，全數撤銷。失敗根因：pread() 碎片化 heap allocation + 物化讀音鍵字串陣列開銷 + Data(contentsOf:) 隱性 mmap purgeable 優勢被低估。
- 下游 LMCassette（CIN2 磁帶模組）連續記憶體最佳化（Phase 12）：仿照 `FactoryTextMapLexicon` 模式，將 `charDefMap`、`charDefWildcardMap`、`symbolDefMap`、`reverseLookupMap` 四個大型 Dictionary 替換為 `CassetteSortedMap`（contiguous Data blob + sorted byte-range index + binary search）；`octagramMap` 與 `octagramDividedMap` 分別改為 `CassetteOctagramMap` 與 `CassetteOctagramDividedMap`。第二輪修正再將 builder 改為直接接受 grouped Dictionary，並以 lightweight prototype grouping 直接生成 wildcard / reverse lookup，移除 `tmpReverseLookup`、`tmpCharDefWildcard`、`tmpDict.map { ... }` 與 sort comparator 的短命 `Array(rawData[range])` allocation，針對載入期 HEAP 峰值進一步收斂。修改範圍跨 vChewing-macOS 與 vChewing-OSX-Legacy 兩倉庫。
- 下游 LMAssembly 共用 parser / cell tokenizer 最佳化（Phase 13）：未直接將 `lmAssociates` / `lmCoreEX` / `lmReplacements` 全面改為 `Data`，而是先將共用 `RangeParserAPI.parse()` 改為「單一 ASCII separator 走 `String.UTF8View` byte scan、非 ASCII separator 保留 `Character` fallback」，再新增 `parseCells(in:splitee:task:)` 收斂每行 space-separated token 掃描，移除三個 SubLM 內部的 `split(separator: " ")` allocation。`lmCoreEX`、`lmAssociates`、`lmReplacements` 因此都改為直接在 `Range<String.Index>` 上抽取所需 cell；其中 `lmAssociates` 仍維持 `(lineRange, cellIndex)` 索引語義，但改為需要時對該行重掃 cell，不再物化整行 token array。以約 13.7 MB UTF-8 文本測得 `String.parse(Character)` 約 158.9 ms、`String.UTF8View` 約 14.9 ms、純 `Data` byte scan 約 5.1 ms；replaceData profiling 亦指出 LMCoreEX 的下一個熱點是 `split(separator: " ")`、字串物化與 Dictionary 寫入，因此本階段正式把第二刀落在共用 tokenization，而非全面 `Data` 化。驗證期間曾出現 associated phrase 測試誤報，最終確認根因是 MainAssembly / Typewriter 單元測試 `UserDefaults` reset 順序不當造成的 stale `cassetteEnabled` 狀態，亦已一併修正。修改範圍跨 vChewing-macOS 與 vChewing-OSX-Legacy 兩倉庫。
- 下游 InputHandler 倚天 DOS 候選補缺字修復（Phase 14）：為解決 Issue 580，本輪不動 `LMInstantiator`，而是在 `vChewing-macOS` / `vChewing-OSX-Legacy` 的 `InputHandler_CoreProtocol.generateArrayOfCandidates()` 尾段新增 `segregateCandidatesForETenDOS(from:)` 與 `supplementalETenSingleKanjiCandidates(reading:existingSingleSegments:)`。當 `prefs.enforceETenDOSCandidateSequence` 開啟時維持既有單字重排；關閉時則只在單一讀音的單字候選情形下，查詢倚天中文 DOS 序列，將現有候選中缺席的 ideographic 單漢字以 `-9.5` 權重追加到尾端，避免組句模式比逐字選字模式少字。Review 後追加修正 `segregateCandidatesForETenDOS` 對空 `keyArray` 候選的防禦——`switch` 改為 `keyArray.count` pattern match（`case 1:` / `case 2...:` / `default: break`），空陣列候選不再落入 `singleSegments`。`vChewing-macOS` 另新增兩個最小 TextMap regression tests，以 reversed factory order fixture 驗證 tail-append 與 enforced reorder 兩種行為。驗證結果為 Typewriter package 30 項測試全數通過，Legacy `make debug-core` 建置成功。
- 下游 ButKo BPMFVS 特殊遞交（Phase 15）：`vChewing-macOS` 新增本地 package `ButKo_BPMFVS` 的 `phonic_table_Z.txt` parser、cached lookup table、`convert(value:reading:)` / `convert(value:readings:)` 與 `convertToBPMFVS(smashedPairs:)`，以 ButKo 的讀音順序直接決定 IVS slot：首讀音維持原字、次讀音起附加 `U+E01E0 + slot`。查表前會先把 Typewriter raw key 的後置輕聲（如 `ㄉㄜ˙`）正規化成教材式前置輕聲（`˙ㄉㄜ`），避免與 ButKo 資料格式錯位。`vChewing_Typewriter` 新增 `CommitableMarkupType.bpmfvsAnnotationButKo = 4` 並在 `specifyTextMarkupToCommit(behavior:)` 直接走該 transformer；後續追加 `UserDef.kReflectBPMFVSInCompositionBuffer`，使組字區、選字狀態與候選預覽只在 behavior 4 且開關啟用時才投影成 BPMFVS 顯示，避免污染一般 commit path。`UserDef` / `PrefMgr` / 設定面板 / 四語系文案同步擴充。其後將同一套邏輯同步到 `vChewing-OSX-Legacy`，但資源路徑改用 `Bundle.main`。驗證結果為 `ButKo_BPMFVS` package 6 項測試通過、Typewriter package 32 項測試通過、MainAssembly4Darwin 狀態測試子集 15 項通過、Legacy `make debug-core` 建置成功。Review（Claude Opus 4）通過，無需修正。
- `vChewing-VanguardLexicon` C-based 新酷音辭典純 Swift 生成器（Phase 16）：`chewingCBasedCHS` / `chewingCBasedCHT` 已改由 `ChewingCBasedDatabaseGenerator` 直接生成 `dictionary.dat` 與 `index_tree.dat`，不再依賴 precompiled `libchewing-database-initializer`。生成器本體依掛靠的 `libchewing-sans-tsi` C 原始碼重建 `phone.cin` / `tsi.src` 解析、例外詞條檢查、字串去重與 index tree 序列化流程；其中單字 `char-misc-nonkanji` 類的負詞頻行會直接忽略，避免把 libchewing 無法表達的權重調整語義誤塞進 C-based 產物，而 root node key 仍採 16-bit truncation 以對齊原版 C 行為。驗證結果除 `swift run VCDataBuilder chewingCBasedCHT chewingCBasedCHS` 與 `LibVanguardChewingDataTests` 通過外，亦已將產物回灌至 `libchewing-sans-tsi` 既有工具 / public API 做回讀與開候選 smoke test，確認 C-based libchewing 可正常利用該產物。**Performance follow-up (2026-04-14)**：builder 端改以 reserved `Data` 直接組裝 `tsi.src` / `phone.cin`，generator 端改用 `Substring` 解析、scalar-based word lookup、binary-searched internal children 與 append-only leaf collection，將同機器同語料下 `swift run VCDataBuilder chewingCBasedCHT chewingCBasedCHS` 的總耗時由約 30.56 s 壓到約 16.29 s；兩個 target 的追加建置階段則由 CHT 約 10.28 s / CHS 約 11.19 s 降至 CHT 約 3.54 s / CHS 約 3.50 s。 
- `vChewing-VanguardLexicon` HealthCheck duplicate 偵查修復（Phase 17）：確認 duplicate 偵查在 SPM 化後退化的根因是雙重的：舊版 `cook_mac.swift` 的 `value + "\t" + key` duplicate 掃描沒有移植進 `Collector.healthCheckPerMode()`，而 `prepareRawUnweightedUnigramsForPhrases()` 的 `processedPairs` / `handledHashes` 又會先吞掉部分 duplicate raw entries，使單純掃描最終 `getAllUnigrams()` 也會漏報。本輪修復改為在 `Collector_HealthCheck.swift` 直接重讀 raw source assets（`char-kanji-core`、`char-misc-bpmf`、`char-misc-nonkanji`、當前語系所有 `phrases-*`），以與 ingest 相同的 normalization 規則重建 occurrence 清單；只要 `phrase + reading` 相同即視為 duplication，不論 freq/count 是否一致，並將該組所有 occurrence 連同 `source:line` 完整彙總後寫入 `healthCheckException([String])` 再拋出失敗。另新增 2 項 synthetic tests 驗證 grouping 與 report summary。實測目前主語料沒有 duplicate 會觸發失敗，但 HealthCheck 已重新具備在 raw source 層完整列舉並中止建置的能力。**1st Review (Claude Opus 4.6)**：修正 `normalizedLinesForDuplicateScan` 行號偏移 bug（bulk-normalize + filter 後 enumerated index 不等於原始檔案行號），改為逐行正規化並保留原始行號；強化測試資料驗證 comment 行不影響行號追蹤。
- `vChewing-VanguardLexicon` Rust 版新酷音辭典純 Swift 生成器（Phase 18）：`chewingRustCHS` / `chewingRustCHT` 已改由 `ChewingRustDatabaseGenerator` 直接從 `tsi.src` / `word.src` 生成 libchewing-rust 可讀的 `tsi.dat` / `word.dat`，不再依賴外部 `chewing-cli`。生成器本體重建 libchewing-rust `TrieBuilder` 的 syllable `u16` 編碼、BFS trie index layout、DER `CHEW` 封裝、leaf phrase ordering 與 duplicate update semantics。實作過程另確認 `char-misc-nonkanji` 存在單字負詞頻（如 `ば -1 ㄅㄚ`），因此比照 Phase 16 採相容策略：單字負詞頻忽略、多字負詞頻拒絕。驗證結果為 `ChewingRustBuilderTests` 6 項測試通過、`swift run VCDataBuilder chewingRustCHS chewingRustCHT` 建置成功，且產物已回灌至 `libchewing-rust` 倉庫並由 `trieloader` 與 `chewing-cli info/dump` 成功讀取。另確認 `fuzzer/src/bin/fuzzer.rs` 目前在 Rust 2024 edition 下因 `gen` 保留字問題無法編譯，屬下游既存瑕疵，故未作為最終驗證路徑。**1st Review (Claude Opus 4.6)**：逐段比對 Swift 生成器與 Rust `TrieBuilder::write()` / `Syllable` bit layout / DER document spec，確認所有路徑一致（syllable 編碼、arena 結構、BFS serialization、leaf phrase ordering、DER 封裝含 IMPLICIT context-specific tag）。手算 syllable golden values 正確。觀察到 `appendUInt16BE`/`appendUInt32BE` 為 dead throws、`encodeUTF8String`/`encodeInteger` 以 `try?` 靜默吞錯但實務安全。**2nd Review (Claude Opus 4.6)**：追加修正——移除 dead throws 並清除 call site `try`、將 `encodeUTF8String`/`encodeInteger` 改為 properly throwing（fail-fast）、BFS 改為雙陣列層輪替（峰值記憶體 O(最大層寬)）。6/6 測試通過。**Performance follow-up (2026-04-14)**：children insertion/lookup 改為維持 syllable-sorted 陣列 + binary search、leaf duplicate 覆寫改用 `phraseIndicesByLeafID` 索引表、source parsing 改為串流灌入 builder，移除 encode 階段對每個 internal node 的重複排序。以同機器同資料對比 baseline commit `9fee096`，`writeArtifacts` 耗時由 CHS 約 20.31 s / CHT 約 20.60 s 降至 CHS 約 3.27 s / CHT 約 3.35 s，約 6x 改善。
- 下游 BPMFVS commit 洩漏修復與詞庫 Unicode 污染稽核（Phase 19）：修補 `prefs.reflectBPMFVSInCompositionBuffer` 導致 display projection 滲入一般 commit path 的問題，在 `vChewing-macOS` / `vChewing-OSX-Legacy` 新增 `committableDisplayText(...)` 作為統一 raw commit source，將一般 Enter、Space 邊界提交、候選與關聯詞提交、SCPC 選字、reset，以及 state 轉 `.ofEmpty` 的自動提交全部收斂到不含 BPMFVS 投影的原始字串。`vChewing-macOS` 新增 3 項回歸測試，鎖住 plain Enter、empty transition 與 SCPC commit 三條路徑。另對 `vChewing-VanguardLexicon` 執行 `4.3.3..HEAD` 的 components Unicode scalar 稽核，直接掃描 `U+FE00...U+FE0F` 與 `U+E0100...U+E01EF`：結果顯示歷史 diff 沒有任何 Variation Selector，現行 tree 唯一帶 VS 的 component file 是既有且未改動的 `common/data-symbols.txt`（內含 `U+FE0E` / `U+FE0F` emoji/text presentation selectors），因此未發現 `給` vs `給󠇡` 這類 Unicode identity-splitting 詞條污染。**1st Review (Claude Opus 4.6)**：逐一追蹤 Typewriter + Session 層全部 15 條 commit 路徑，確認每條都正確走 `committableDisplayText(...)` 而非 `displayedText`；唯一產出 BPMFVS 的路徑是刻意的 `commissionByCtrlOptionCommandEnter`。Legacy mirror 與所有 3 項 regression tests 通過。觀察到 `InputSession_HandleStates.swift` 的 `.ofEmpty` auto-commit 分支 `?? previous.displayedText` fallback 在理論上可傳回帶 BPMFVS 的文字；維護者據此追加修正，三處（macOS production、Legacy、Mock test session）統一改為 `if let inputHandler` 條件綁定，完全消除理論洩漏路徑。
- 下游 BPMFVS marking state 使用者詞語污染修復（Phase 20）：Phase 19 的 `committableDisplayText` 僅覆蓋 commit 路徑，但 marking state → user dictionary 加詞走的是 `state.displayTextSegments` → `displayedText` → `userPhraseKVPair` 管線，BPMFVS Variation Selectors 直接滲入使用者詞語。修復方式為在 `IMEStateData` 新增 `rawDisplayTextSegments: [String]?` 欄位實作 raw/display 雙軌分離：`displayTextSegments` 繼續持有投影文字供渲染，`rawDisplayTextSegments` 儲存保證未投影的原始字串；`userPhraseKVPair` 改從 `rawDisplayedText`（`rawDisplayTextSegments?.joined() ?? displayedText`）截取標記範圍。Typewriter 端新增 `rawDisplayTextSegmentsIfNeeded` 與 `insertReadingIntoSegments` helper，6 處 state 建構點全數填入 raw segments。同步移植至 `vChewing-OSX-Legacy`。**Review follow-up (GPT-5.4)**：補修 candidate preview 只更新 `displayTextSegments` 卻未同步 `rawDisplayTextSegments` 的一致性漏洞，新增 `test_IH103E_ButKoBPMFVSCandidatePreviewKeepsRawStateInSync`。最終驗證結果為 Typewriter 35/35、LangModelAssembly 55/55、MainAssembly4Darwin 50/50 通過，Legacy `make debug-core` BUILD SUCCEEDED。
- 下游 Hotenka 繁簡轉換引擎 v2.0.0 升級（Phase 21）：將 `vChewing-macOS` 與 `vChewing-OSX-Legacy` 的 Hotenka 繁簡轉換引擎從 SQLite 後端（v1.3.1）升級至 StringMap 後端（v2.0.0）。核心變更：`HotenkaChineseConverter` 移除 `CSQLite3Lib` 依賴，新增 `HotenkaStringMap.swift`（binary-search-based sorted text map）；`convdict.sqlite` 替換為 `convdict.stringmap`；`init(sqliteDir:)` 替換為 `init(stringMapPath:)` throwing initializer。`ChineseConverterBridge` 的 singleton 從直接建構改為 `Optional` + `try?`（graceful degradation on load failure），所有 `convert` call site 改為 optional chaining + `?? string` fallback。`vChewing-macOS` Hotenka Package 升級至 Swift 6.2 + `defaultIsolation(MainActor.self)`，測試從 XCTest 轉換至 Swift Testing（`@Suite struct` + `@Test`）。`vChewing-OSX-Legacy` 的 Xcode project 同步更新：新增 `HotenkaStringMap.swift` source ref、替換 `convdict.sqlite` → `convdict.stringmap` resource ref。驗證結果為 Hotenka 8/8、Typewriter 35/35、LangModelAssembly 55/55、MainAssembly4Darwin 50/50 通過，Legacy `make debug-core` BUILD SUCCEEDED。
- 下游 CNS11643 全字庫讀音過濾 UX 優化（Phase 22）：`kFilterNonCNSReadingsForCHTInput` 原先對所有不合規 Unigram 一律 `removeAll` 濾除，導致啟用該選項時「播」（CNS 僅收 ㄅㄛˋ）等常用漢字在 ㄅㄛ 讀音下完全消失。本輪改為：對單一讀音（`keyArray.count == 1`）的不合規 Unigram 以 `-9.5` 權重 demote（建構新 `Megrez.Unigram`，因 `score` 為 `let`），多讀音詞組仍維持濾除。同時為該 UserDef case 新增 `description` 欄位與四語系（en / zh-Hant / zh-Hans / ja）翻譯。既有 `testCNSMask()` 斷言更新為驗證 demote score。**Review follow-up (GPT-5.4)**：補 `test_IH113_FilterNonCNSReadingsStillAllowsSelectingDemotedSingleKanji()` Typewriter regression test，以最小 `bo` TextMap + CNS side entry 驗證 demoted `播` 仍可在候選窗被選取並成功覆寫組字結果。跨 vChewing-macOS 與 vChewing-OSX-Legacy 兩倉庫。最終驗證結果為 LangModelAssembly 54/54、Typewriter 36/36、MainAssembly4Darwin 50/50 通過，Legacy `make debug-core` BUILD SUCCEEDED。
- 下游 BookmarkManager 熱點快取修補（Phase 23）：根據 Instruments 可確認卡頓主因不是 userphrase write flow 本身，而是 `LMMgr.dataFolderPath(isDefaultFolder: false)` / `cassettePath()` 每次都會無條件 `BookmarkManager.shared.loadBookmarks()`，而舊版 `loadBookmarks()` 又會先 `stopAllSecurityScopedAccesses()` 再逐筆 `restoreBookmark(...)`。在 iCloud Drive 路徑與 macOS 26.4.1 下，這段 security-scoped bookmark restore 會放大成 `Security::CodeSigning::KernelCode::identifyGuest` / `_CFBundleCreate` / plist parse 熱點，進而拖慢 `initUserLangModels()` 與 userphrase write。修復方式是在 `Jad_BookmarkManager` 與 legacy copy 內新增 bookmark store signature 快取：當 bookmark 檔案未變且 access 尚在時直接返回；只有在書籤檔更新、access 被 stop、或 override 改變時才重新 restore。`vChewing-macOS` 另新增 `testLoadBookmarksSkipsRestoreWhenBookmarkStoreUnchanged()` regression test。驗證結果為 BookmarkManager 10/10、MainAssembly4Darwin `swift build` 成功、Legacy `make debug-core` BUILD SUCCEEDED。
- 下游沙盒卸除 Fallback UX 設計（Phase 24）：`vChewing-macOS` 與 `vChewing-OSX-Legacy` 在收緊 sandbox 後，已不再嘗試透過 NSOpenPanel 取得 `~/Library/Input Methods/` 目錄授權來自刪；改由 `AppDelegate.selfUninstall()` 顯示指引 NSAlert，並以 Finder 依序揭示使用者詞語資料夾、App Support 父資料夾與目前執行中的 bundle 位置，讓使用者手動完成卸除。CLI `uninstall` / `uninstall --all` 則直接輸出 wiki 與 `uninstall.sh` 提示。**Review follow-up (GPT-5.4)**：發現 GUI alert 與 CLI banner 仍沿用「未能取得目錄存取權限」舊敘述，與本 phase 已證實的 entitlement 根因不符；已修正 macOS / Legacy 兩倉庫 `Uninstaller.swift` 與四語系 `Localizable.strings`，統一改為說明 sandboxed IME 無法自行將自身 bundle 移到垃圾桶，並更正文檔中的 Finder 第三個揭示目標為 runtime `Bundle.main.bundleURL`（通常是 `~/Library/Input Methods/vChewing.app`）。驗證結果為 vChewing-macOS `swift build` 成功、Legacy `make debug-core` BUILD SUCCEEDED。
- 下游 iCloud Drive 磁帶書籤持久化失敗 workaround（Phase 25）：iCloud Drive 管理的 `~/Documents`、`~/Desktop` 等目錄中的 CIN2 磁帶檔案的 security-scoped bookmark 無法跨 reboot 持久化（macOS 26.4.1 資安升級加劇，但此行為已被開發者報告約十年）。修復方式為在 `LMMgr` 新增「Import to AppSupport cache」機制：使用者選取 CIN2 檔案時同步複製到 `~/Library/Application Support/vChewing/Cassettes/`（App Sandbox 天然可讀寫，不需 bookmark）；`cassettePath()` 在 bookmark 還原失敗時自動 fallback 至快取副本（私有 `isFileReadable()` 避免 `Broadcaster` side effect flash alert）；`loadCassetteData()` 在外部路徑可用時靜默重新整理快取副本保持最新；`resetCassettePath()` 新增快取檔案清理。所有 UI 入口（SwiftUI drag-drop/fileImporter、Cocoa drag-drop/NSOpenPanel）皆在 `saveBookmark` 後呼叫 `importCassetteFileToCache`。`toggleCassetteMode()` 與 SwiftUI toggle 的可用性判斷收斂為 `cassettePath().isEmpty`（走完整 fallback 解析）。**Review follow-up (GPT-5.4)**：快取目錄名稱統一為 `Cassettes`；`cassetteCacheDirectoryURL` 在 unit tests 下改走 unit-test sandbox，而不是實際 App Support；`resetCassettePath()` 不再誤刪使用者直接指定在 `Cassettes/` 目錄內的來源檔；`vChewing-macOS` 新增 4 項 regression tests。**UX/localization follow-up (GPT-5.4)**：新增 path-aware alert description helper，對 `~/Library/Mobile Documents/com~apple~CloudDocs/` 仍直接視為 iCloud 路徑；但對 `~/Documents` / `~/Desktop` 則改以 `getxattr` 檢查 `com.apple.icloud.desktop` / `com.apple.icloud.documents`，只在 mirror sync 真的開啟時才追加「移到本機位置、必要時可洽詢 Apple Support」提示。這套警告也同步到 macOS / Legacy 的 en / zh-Hant / zh-Hans / ja 設定 prompt，另新增 3 項 regression tests 鎖住 guidance 的顯示條件。**Symbolic link follow-up (GPT-5.4)**：新增 `resolveUserSpecifiedURL(_:)` 專門把 Phase 25 的使用者指定 URL 先做 symbolic link 解碼，再交給 path validity、bookmark、cache import 與 user-data folder 指定流程使用；涵蓋 Cocoa `NSOpenPanel`、Finder drag-drop 與 SwiftUI `fileImporter`，避免 App 只記住 symlink 殼層。另新增 2 項 regression tests 鎖住 symbolic link 檔案與目錄都會 resolve 到來源 URL。複驗結果為 MainAssembly4Darwin 59/59 通過，Legacy `make debug-core` BUILD SUCCEEDED。
- 下游 Perception Override / Megrez 低風險演進落地（Phase 32）：依 Phase 31 調研結果，先在 `vChewing-macOS` 與 `vChewing-OSX-Legacy` 落地 P0~P3。Megrez `Compositor` 新增 Assembler 級 `perceptor` 注入，`3_KeyValuePaired.swift` 以 `perceptionHandler ?? perceptor` dual-dispatch 自動送出 `PerceptionIntel`；`LMPerceptionOverride` 將 `kDecayThreshold` 由 `-9.5` 放寬至 `-13.0`，並把 WAL / JSON snapshot / CRC32 compaction 抽離至新 `PerceptionPersistor`，POM 只保留觀測與權重邏輯。`LMInstantiator_POMRepresentable` / `LMMgr_Core` 新增 `pomReducedLifetime` → `reducedLifetime` 注入鏈，移除權重熱路徑 `UserDefaults` 讀取；legacy 端同步移植並將 `lmPerceptionPersistor.swift` 納入 Xcode project。**Review follow-up (GPT-5.4)**：移除 macOS / legacy POM 內殘留的 debug `print`，並將 rapid-forget 測試改為直接驗證 `reducedLifetime` 注入與 `LMInstantiator` 轉發，不再依賴舊的 `UserDefaults` 路徑。驗證結果為 Typewriter 36/36、`POMRapidForgetTests` 3/3、Legacy `make debug-core` BUILD SUCCEEDED。
- 下游 Phase 33 Homa transplant / LXPerceptor 對齊（2026-04-20）：`vChewing-macOS` 完成 Megrez → Homa、InputHandler A2 委派化、`LMPerceptionOverride` → `LXPerceptor` canonical rename，並修補 `CandidatePair` 權重語義、Homa revolver / consolidator identity 對位與同分標點保序；`vChewing-LibVanguard` 同步補齊 `LX_Perceptor.reducedLifetime` parity 與 Homa mirror regression。其後 `vChewing-OSX-Legacy` 亦完成對位 transplant，包含 Homa runtime、LMAssembly compat / adapters、Typewriter / MainAssembly bridge、Xcode project 與 Homa 授權文件同步。repo-local dotnet audit 報告為 `Actionable = 0`（37 mirrored / 1 equivalent-noop / 10 no-counterpart / 23 test-only skip），Legacy `make debug-core` BUILD SUCCEEDED。

---

## 附錄一、開發階段歷史

因該章節過於龐大，故挪至 `[REPO_ROOT]/DevPlans/LibVanguard-DevReqsHistory.md` 單獨管理。

---

## 附錄二、已知問題與注意事項

### A2.1 當前已知問題

1. `LXTests4TrieHub/testTrieHubAssemblyingUsingPartialMatchAndChops` 若暫時使用完整 Lexicon 測資，會因語料語義與 Tiny Sample 不同而出現 sentence expectation failure；目前應將 benchmark 視為有效信號、將 assertion mismatch 視為已知暫時狀態。

### A2.2 開發注意事項

1. 始終保持對 Linux 與 Windows 的可建置性（透過 `#if canImport(Darwin)` 處理平台差異）。
2. TrieKit 不計畫直接支援 Regex Fuzzy Match；不完全讀音檢索需先經 Tekkon 的 `chop()` 拆解。
3. Homa 引擎取消了舊版 `LangModelProtocol` 協定，改用回調函式。
4. LexiconKit 不負責查詢結果的去重複化，該工作由 Homa 引擎完成。
5. 下游 `vChewing_LangModelAssembly` 的 Phase 06 遷移刻意只採 TextMap full match；不要把 `TextMapTrie` 的 partial-match / longer-segment 能力誤判為 vChewing 端的現行需求。
6. 下游測試 fixture 的 typeID 必須與 VanguardLexicon 建置器的實際 typeID 分配一致（Phase 09 教訓：`_punctuation_list` 等 `_` 前綴 key 在 production 為 typeID=4，fixture 誤標為 5/6 導致漏洞）。

---

## 九、關鍵檔案速查

| 檔案路徑 | 說明 |
|----------|------|
| `Package.swift` | SPM 套件定義（含 @resultBuilder DSL） |
| `makefile` | `make lint` / `make format` / `make test` / `make dockertest` |
| `EVOLUTION_MEMO.md` | 各模組研發備忘錄（人工維護） |
| `Sources/_Modules/Homa/Homa_MainComponents/Homa_Assembler.swift` | 組字核心引擎（Phase 05：跨插入 gram query cache / 熱路徑去 allocation） |
| `Sources/_Modules/Homa/Homa_MainComponents/Homa_PathFinder.swift` | 動態規劃路徑搜尋 |
| `Sources/_Modules/Tekkon/Tekkon_SyllableComposer.swift` | 音節合成引擎 |
| `Sources/_Modules/TrieKit/VanguardTrie_Core.swift` | Trie 核心資料結構 |
| `Sources/_Modules/TrieKit/TrieProtocol.swift` | Trie 共用查詢邏輯（Phase 05：split cache / node.id 去重） |
| `Sources/_Modules/TrieKit/TrieTextMap_Core.swift` | TextMapTrie 惰性解析 Trie（Phase 04） |
| `Sources/_Modules/TrieKit/TrieSQL_Core.swift` | SQLite Trie 核心 |
| `Sources/_Modules/TrieKit/VanguardTrieIO.swift` | Trie IO（Plist + TextMap 序列化/反序列化） |
| `Sources/_Modules/TrieKit/TK_QueryBuffer.swift` | 7 秒動態清理查詢快取 |
| `Sources/_Modules/LexiconKit/LexiconHub.swift` | 詞庫中樞型別定義 |
| `Sources/_Modules/LexiconKit/LX_Components/LX_TrieHub.swift` | Trie 資料庫中樞 |
| `Sources/_Modules/LexiconKit/LX_GramConcatAPI.swift` | 元圖查詢結果聚合（Phase 05 Review：結構化排序 / 具型雜湊） |
| `Sources/_Modules/LexiconKit/LX_Components/LX_Perceptor.swift` | 使用者習慣洞察器 |
| `Sources/_Modules/SharedCore/SharedCore.swift` | 共用命名空間與常數 |
| `Sources/_Modules/SharedCore/Protocols/` | 全部共用協定 |

---

## 十、建置與開發

### 10.1 建置要求

- Xcode 16.0+
- Swift 6.1+
- macOS 15+ / iOS 18+ / visionOS 2+

### 10.2 建置指令

```bash
swift build
```

### 10.3 測試指令

```bash
make test          # Release 模式測試
make test-debug    # Debug 模式測試
make dockertest    # Docker 容器測試（Linux）
```

### 10.4 程式碼格式化

```bash
make lint          # SwiftLint 自動修正
make format        # SwiftFormat（縮排 2 空格）
```

> 交差前兩道命令按順序都跑。注意 lint+format 可能將 `count == 0` 轉為 `.isEmpty`，需確認對應型別確有此屬性，否則改用 `.count * 1 == 0`。

---

## 十一、參考資料

- 詳見 `[RepoRoot]/DevPlans` 目錄的其餘 Markdown 檔案。
- `[RepoRoot]/EVOLUTION_MEMO.md` 記錄了各模組的原始設計備忘錄。

---

> ⚠️ **注意**: 本文檔需要定期更新以反映最新程式碼狀態。最後更新：Phase 33 Legacy transplant / mirror audit completion（2026-04-20）。


---

## 十二、AI Agent 反應模式（Response Pattern）

> 本節供 AI Agent 參考，當用戶提出新的 Phase 開發任務時，應遵循以下標準流程。

### 12.1 工作流程（Workflow）

當用戶提出新的 Phase 需求時，按以下順序執行：

```
┌─────────────────────────────────────────────────────────────────┐
│  Step 1: 讀取相關檔案                                            │
│  - 讀取用戶指定的 Phase 描述         │
│  - 讀取需要修改的原始碼檔案                                       │
│  - 確認現有實作與新需求的關聯                                     │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  Step 2: 程式碼實作                                              │
│  - 根據需求實作功能                                              │
│  - 遵循專案現有程式碼風格（Swift 6, @MainActor, 層級結構）         │
│  - 複用既有組件和工具函數                                        │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  Step 3: 編譯驗證                                                │
│  - cd SPMPackages/LibVanguardSPM && swift build                     │
│  - 確保無錯誤、無警告                                           │
│  - 如有錯誤立即修復                                              │
│  - 然後用 Xcode build 觸發 localized strings key 生成           │
│  - 完成 localization 之後再次重試編譯                           │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  Step 4: 文件同步（並行執行）                                     │
│  ├─ DevPlans/Reqs4LLM 當中對應的 Phase 檔案: 添加 Phase 規格與實作備忘錄 │
│  ├─ LibVanguard-KnowledgeMemo4LLM.md: 更新開發階段歷史表格           │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  Step 5: 彙總報告                                                │
│  - 列出所有變更的檔案                                            │
│  - 說明核心實作邏輯                                              │
│  - 確認編譯狀態                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 12.2 文件更新規則

| 檔案 | 更新時機 | 內容格式 |
|------|---------|----------|
| **Alpha1-DevReqs-Archive.md** | 每個 Phase 必須 | `# Phase XX` 標題 + 規格說明 + `## Phase XX 實作結果` 小節 |
| **LibVanguard-KnowledgeMemo4LLM.md** | 每個 Phase 必須 | 在「開發階段歷史」表格中添加一行 `\| Phase XX \| 簡短描述 \|` |
| **UserGuide (4語言)** | 影響使用者操作時 | 在對應章節添加功能說明（鍵盤熱鍵、滑鼠操作等） |

### 12.3 程式碼實作原則

1. **最小變更原則**：只做必要的修改，不改動無關程式碼
2. **風格一致性**：
   - 使用 `// Phase XX:` 註解標記新代碼
   - 遵循現有命名慣例（如 `handleXxx`, `onXxx`）
   - 保持縮排和空行風格
3. **平台相容性**：
   - (今後會按需求補充)
4. **狀態管理**：
   - (今後會按需求補充)

### 12.4 常見任務類型

| 任務類型 | 典型檔案 | 注意事項 |
|----------|----------|----------|

### 12.5 回報格式範本

```markdown
## 變更總結

### 程式碼變更

**檔案名稱.swift**:
- 變更項目 1
- 變更項目 2

### 文件更新

| 檔案 | 更新內容 | 注意事項 |
|------|---------|---------|
| DevPlans/Reqs4LLM/Reqs_????.md | 新增 Phase XX 規格與實作備忘錄 | 注意優先編輯以數字為 filename stem suffix 的分卷檔案，每個分卷最多 10 個 Phase，超出了就請新增分卷檔案。如果完成的任務剛好是當前分卷的最後一個任務（第十個任務）的話，請以新的分卷命名創建空白 markdown 檔案（除非該檔案已存在）。 |
| DevPlans/LibVanguard-KnowledgeMemo4LLM.md | 根據專案實際情況更新內容（如適用） | 參考既往記錄的文書風格。 |
| DevPlans/LibVanguard-DevReqsHistory.md | 新增 Phase XX 到開發階段歷史 | 參考既往記錄的文書風格。 |

### 編譯狀態

✅ 編譯通過 / ❌ 有錯誤（說明）
```

### 12.6 工作細節附註

- 交差前注意與 L10n 有關的內容是否全部補齊。
- 如果要使用 tmp 目錄的話，請使用 `[REPO_ROOT]/tmp` 目錄、而非 `/tmp/`。使用 `/tmp/` 這種 out-of-workspace 的路徑會迫使事主每次都得手動設定存取權限，非常麻煩。
- 如果事主丟給您 Xcode Instruments Profile 檔案的話，可能會是二進位檔案，請先嘗試用 `xctrace export` 解讀成 XML 再分析。
- 每次交差之前運行 `make lint; make format`。如果事主明確要你對某些工作單獨 commit 的話，每次 commit 之前也請運行 `make lint; make format`。事主謀求的格式整理結果乃 **這兩道命令按順序達成的修改效果之總和**，且這兩條命令必須得先 lint 後 format 且不得顛倒順序。但注意在運行之後也請 build 一次，因為這兩道命令對 `count == 0` 的範式會頑固地轉換成 `.isEmpty` 而不會檢查相關 type 是否有 `isEmpty` 這個 read-only property。發現這種情況的話，可以用 `.count * 1 == 0` 取代之。commit 的 title 格式是 `ModuleName // WhatHasBeenFixed`、且在 commit 的 description 的末尾單獨一行寫明 `(Phase XXX - Task YYY)`。Commit Titles 始終以 ASCII Period `.` 結尾，除非是疑問句時才使用 `?` 結尾。
- 給 ChatGPT、Codex、Raptor 的特殊指令：Do not intentionally stop with tasks incompleted to ask me whether you do the next step I already told you. Just do it. I have backups, hence no worry. // Claude、Kimi、GLM、QwenCoder 從來不用問這些問題，就能把這些事情全部做好。唯獨 ChatGPT、Codex、Raptor 不這樣，就很奇怪很令人窩火。

---

> ⚠️ **注意**: 本文檔需要定期更新以反映最新程式碼狀態。如有發現過期內容，請及時修正。
