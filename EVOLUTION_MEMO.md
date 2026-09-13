# 研發備忘錄

本文記錄了先鋒引擎諸模組的開發備忘錄，供開發者自行備忘使用。

> [!IMPORTANT]
> 2026-09-14：本倉已完成改組——承載了 `vChewing-macOS` 的全部跨平台輸入邏輯。 `vChewing-macOS` 的 `vChewing_OSNeutral_LibVanguard` 套件與本套件是鏡照關係，原本散在 `Sources/_Modules/*` 的諸模組與其測試靶一併退場。套件名為 `LibVanguard`、出貨產品名為 `Vanguard`（故產物是 `libVanguard.dylib` 而非 `libLibVanguard.dylib`），聚合靶與其測試靶即 `LibVanguard` / `LibVanguardTests`；
> 其餘模組名（`Homa`、`TrieKit`、`LexiconAssembly` 等）不變。模組清單以 `Package.swift` 為準。

## 關於資訊電子術語

敝倉庫採台澎金馬資訊電子術語，但部分可能反而會引起歧義或狗屁不通的術語例外（此乃極端情形）。

## 各個元件的介紹與備忘錄

### TrieKit

辭典樹（Trie）類型模組，負責支援對每個讀音的首字元檢索配對。分為兩種：

- **VanguardTrie.Trie**: 原始形態，常駐於記憶體內，無 QueryBuffer，支援 Vanguard Pragma TextMap 格式的讀寫（含 read-write 往返）。
- **VanguardTrie.TextMapTrie**: Vanguard Pragma TextMap 形態，原始資料以 `Data` 常駐 ＋ 排序鍵索引 ＋ 二分搜尋，為原廠辭典的 canonical backend。

> [!NOTE]
> 注意：為了簡化實作，這個模組不計畫對 Regex Fuzzy Match 提供直接支援。
> 
> 對於智能狂拼、搜狗拼音、RIME等狂拼流拼音輸入法的情形而言，這種基於一串不完全讀音的原始讀音雜串（reading complex）需要使用 Tekkon Next 聲韻並擊引擎的 `chop()` 函式事先拆解。
> - 比如注音： `"ㄅㄩㄝㄓㄨㄑㄕㄢㄌㄧㄌㄧㄤ"` 就可以這樣拆解成 `"ㄅ", "ㄩㄝ", "ㄓㄨ", "ㄑ", "ㄕㄢ", "ㄌㄧ", "ㄌㄧㄤ"`，然後 TrieKit 在檢索的時候就可以據此檢索到 `ㄅㄚ ㄩㄝˋ ㄓㄨㄥ ㄑㄧㄡ ㄕㄢ ㄌㄧㄣˊ ㄌㄧㄤˊ`。
> - 拼音的話： `"byuezhqshll"` 就可以這樣拆解成 `"b", "yue", "zh", "q", "sh", "l", "l"`，然後 TrieKit 在檢索的時候就可以據此檢索到 `ba1 yue4 zhong1 qiu1 shan1 lin2 liang2`。

### Homa

護摩組字引擎，是天權星組字引擎（Megrez）的繼任者、擁有下述新特性：

1. 支援 Bigram，且每個 Gram 承載其真實讀音。由於 Bigram 的統計資料大多只有書面用語統計資料，所以對 Bigram 的描述方式僅限於某個 previous node 是怎樣的字詞、而不糾結這個 previous node 讀音。
2. 取消了對於語料來源模組的 LangModelProtocol 協定規束。
3. 為了對接那些有支援「部分配對（partial matching）」的語料來源模組，護摩引擎對「使用者鍵入的讀音串」與「經過組句之後的真實讀音串」做了分開處理、且在覆寫節點時就對應的候選字詞提出了真實讀音配對的要求。
4. 內建了對候選字輪替與上下文節點鞏固功能的支援。

### Tekkon

鐵恨注拼引擎的 Swift Concurrency 相容版，多了一些 API 用以滿足先鋒引擎的內部需求。

> [!NOTE]
> Tekkon Next 內建了一套 PinyinTrie，是 TrieKit 的 VanguardTrie 的簡化版。因為兩者彼此分化過度、且各自的 API 設計有差異，所以用 Generics 讓兩者使用同一個抽象基底 Class 的價值並不大。

### LexiconAssembly

辭典聚合與洞察（POM）模組，內含 `LXPerceptor`（洞察與衰退）、`LXFacade`（辭典查詢門面）、
`LXPlainBopomofo`（倚天中文 DOS 系統注音候選字排序資料）、以及各式語料解析器。`LXQuerier` 是 Homa 與本模組之間的正式介面。

#### PerceptionKit (absorbed by LexiconAssembly)

是針對護摩組字引擎的一套功能擴展、允許在指定時刻洞察使用者的組字習慣，且允許用 ngram 的形式以三次曲線隨時間衰減的方式管理洞察結果。

這套機制現在住在 `LexiconAssembly` 模組內的 `LXAssembly.LXPerceptor`。

#### LexiconKit (absorbed by LexiconAssembly)

辭典資料聚合模組。
該模組不負責對查詢結果的徹底去重複化與整理，因為相關的工作被交給護摩組字引擎來完成了。
對 CIN2 磁帶格式的支援暫緩執行，屆時直接引入 VanguardTrie 的一個外圍 class 來完成。

此模組現已更名為 `LexiconAssembly`，且與前述的 PerceptionKit 合流。

### LibVanguard

作業系統中立層：輸入控制器（`InputHandler`）、組字器與用戶端之間的橋接、以及各項與平台無關的
狀態機。此模組同時是唯一的聚合靶，`Package.swift` 的動態產品 `Vanguard` 即由其拉入整個依賴閉包。

### BPMFVS / BrailleSputnik / Shared / SwiftExtension / ResourceLocator

`BPMFVS` 是注音輸入法核心用的資產與存取器；`BrailleSputnik` 是盲文點字支援模組；
`Shared` 是全體共用型別與常數；`SwiftExtension` 是通用 Swift 擴充；
`ResourceLocator` 負責在執行期定位已載入模組的資源。後兩者採 MulanPSL-2.0 授權。

### LXAssemblyMaterials4Tests / vChewingSharedCLI

`LXAssemblyMaterials4Tests` 是單元測試專用的辭典素材靶（刻意獨立於出貨動態庫之外）；
`vChewingSharedCLI` 是跨模組的共享命令列工具。

$ EOF.
