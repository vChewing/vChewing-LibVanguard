# Phase 46 調查報告：拼音免聲調長句組字卡頓第三輪根因分析 (Chapter 10)

> 調查日期：2026-04-25
> 研究範圍：`vChewing-macOS`（為主）
> 研究員：Kimi（Moonshot）
> 觸發條件：拼音模式、免聲調輸入、組字區超過六個字
> 文檔狀態：完成、可用於後續 Phase 的開工依據。

---

## 十、First Principle 檢視：Tekkon → Typewriter → Homa → LMInstantiator 的架構設計問題

> 研究範圍限定 `vChewing-macOS` 倉庫。`vChewing-LibVanguard` 為實驗田，其設計可作為對照。

---

### 10.1 先釐清四層的「第一性」職責

從最原始的輸入法問題出發：用戶按下按鍵，系統需要將「讀音序列」轉換為「最可能的文字序列」。這個問題天然可拆解為四層：

| 層級 | 職責（第一性） | 類比 |
|------|---------------|------|
| **Tekkon** | 將物理按鍵轉換為單一、確定的讀音（聲介韻調）。不處理字典、候選詞、語境。 | 音韻編譯器（Phonetic Compiler） |
| **Typewriter** | 處理輸入狀態機（composing / selecting / committing），決定「何時」觸發組字，協調各子系統。 | 控制器（Controller） |
| **Homa** | 在「讀音序列」上建立搜尋空間（segment grid），以動態規劃（DP）求解最優分詞路徑。 | 組字引擎（Segmenter/Parser） |
| **LMInstantiator** | 給定一個**精確**的讀音片段（`[String]`），回答「這個讀音對應哪些詞、概率各是多少」。 | 語言模型介面（Lexicon Interface） |

**關鍵發現：Tekkon 的職責邊界極其純粹。**

`Tekkon.Composer` (`Tekkon_SyllableComposer.swift`) 只有四個 slot（`consonant`, `semivowel`, `vowel`, `intonation`），其輸出是單一確定的讀音字串（如 `jiang4` 或 `ㄐㄧㄤˋ`）。**Tekkon 從不產生 `&`，也從不處理「聲調不確定性」。**

這個設計本身是正確的——Tekkon 只回答「用戶目前按了什麼」，不回答「用戶可能想打什麼」。問題出在 Typewriter 如何處理 Tekkon 的輸出。

---

### 10.2 當前數據流的全景

以用戶輸入六個免聲調拼音音節為例，追蹤 `&`（tone bucket）從何而生：

```
[用戶按鍵 "shi"]
    ↓
Tekkon.Composer: 組成 "shi"（無聲調，intonation slot 為空）
    ↓
Typewriter.readingKeyForQuery():
    guard shouldUseToneInsensitivePinyinLookup(...) else { return readingKey }
    return makeToneInsensitivePinyinQueryKey(from: "shi")
    // → "shi&shi\u0301&shi\u030C&shi\u0300&shi\u0302"
    ← 這裡，Typewriter 製造了 &
    ↓
Typewriter: handler.assembler.insertKey("shi&shi\u0301&shi\u030C&shi\u0300&shi\u0302")
    ↓
Homa.Assembler.insertKey():
    keys.insert(key, at: cursor)   // Homa 把 & 字串原封不動存入 keys 陣列
    resizeGrid(...)
    assignNodes()
    ↓
Homa.Assembler.assignNodes():
    對每個位置 p、長度 l:
        let slice = keys[p..<p+l]   // slice 中包含帶 & 的字串
        queryGrams(using: slice)
    ↓
Homa → gramQuerier → LookupHub.grams(for: slice)
    ↓
LMInstantiator.unigramsFor(keyArray: slice)
    if keyArray.contains(where: { $0.contains("&") }) {
        return mergedAlternativeBucketUnigrams(for: keyArray)
        // 內部: expandAlternativeKeyArrays → 笛卡爾積
    }
    ↓
對單一 span 展開 5^l 個組合，每個組合查詢 user data hash map
```

**這條鏈路對單一 span 的查詢就已經極其沉重。** 而 Homa 對一個 6 音節句子會查詢約 36–60 個 spans（取決於 `maxSegLength` 與 cursor 位置）。每個 span 內部的 `mergedAlternativeBucketUnigrams` 都可能獨立展開數千至數萬個組合。

---

### 10.3 從 First Principle 發現的根本性設計問題

#### 問題零：Typewriter 用「字串編碼」替代「結構化傳遞」（ROOT CAUSE）

**File:** `Typewriter_BPMFFullMatch.swift` line 130–140

```swift
private func makeToneInsensitivePinyinQueryKey(from readingKey: String) -> String {
  var toneVariants = [String]()
  Tekkon.allowedIntonations.forEach { tone in
    let intonationNow = (tone != " ") ? String(tone) : ""
    let candidate = "\(readingKey)\(intonationNow)"
    if !toneVariants.contains(candidate) {
      toneVariants.append(candidate)
    }
  }
  return toneVariants.joined(separator: "&")
}
```

**First Principle 分析：**

這個函式的輸入是「5 個可能的聲調讀音」，輸出卻是一個 `&` 分隔的**扁平字串**。

從 first principle 來看，「用戶輸入了一個免聲調拼音，系統需要考慮 5 種聲調變體」是一個**結構化語義**：
- 位置 `p` 的讀音集合 = `{shi, shí, shǐ, shì, shi̇}`

但 Typewriter 把它編碼為：
- 位置 `p` 的讀音字串 = `"shi&shí&shǐ&shì&shi̇"`

這個編碼決策導致整個下游被迫「解析」這個字串：
1. **Homa** 必須把 `"shi&shí&shǐ&shì&shi̇"` 當作一個合法的 key 存入 `keys` 陣列（`Homa_Assembler.swift` line 170）
2. **Homa** 在建立 span 時，把帶 `&` 的字串傳給 `gramQuerier`（`Homa_Assembler.swift` line ~165）
3. **LMInstantiator** 必須檢測 `&`，解析它，做笛卡爾積展開（`LMInstantiator.swift` ~line 900+）
4. **LMInstantiator** 內部因此誕生了 `mergedAlternativeBucketUnigrams` 這個「補丁式」函式

**如果 Typewriter 以結構化方式傳遞這 5 個讀音，整個 `&` 機制根本不必存在。**

---

#### 問題一：Tone Bucket（&）的展開發生在「錯誤的抽象層」

**現狀**：`mergedAlternativeBucketUnigrams` 在 `LMInstantiator` 內部展開 tone bucket。Homa 對這個機制一無所知——它看到的就是一個帶有 `&` 的 `keyArray`。

**First Principle 分析**：

由於問題零的存在，tone bucket 的展開被迫下沉到最底層。但即使我們暫時接受 `&` 字串編碼，展開的位置仍然是錯的：

- **Homa 的 DP 算法天然適合處理「一個位置有多條並行邊」**。
- 如果 Homa 知道「第 0 個音節可能是 shí/shǐ/shì/shi̇/shi」，它可以在建立 Node 時就為這五個讀音各查一次（或共用查詢結果），然後把五組 grams 合併到同一個 Node。
- 目前卻是 LMInstantiator 在內部把 `["shi&shí&shǐ&shì&shi̇", "jian&jiǎn&jiàn&jiān&jián"]` 展開成 25 個精確 `keyArray`，再對每個精確 `keyArray` 查詢 user data。

**結果**：LMInstantiator 被迫成為一個「輸入特徵處理器」，而不是純粹的「語言模型介面」。它的介面被 tone bucket 的語義污染。

---

#### 問題二：Homa 的 Cache 語義與 Tone Bucket 互斥

**現狀**：Homa 有 `gramQueryCache`（512 entry LRU cache），cache key 是完整的 `[String] keyArray`。

**First Principle 分析**：
Cache 的核心前提是「相同的輸入會產生相同的輸出」。但在 tone bucket 場景下：
- Homa 傳入的 keyArray 是 `["shi&shí&shǐ&shì&shi̇", "jian&jiǎn&jiàn&jiān&jián"]`，這個 keyArray 本身不會被 cache（因為展開在 LMInstantiator 內部）。
- LMInstantiator 內部展開後的每個精確組合（如 `["shí", "jiān"]`）會被 Homa cache，但這些精確組合在 tone bucket 場景下幾乎不會重複出現。

**結果**：Homa 的 `gramQueryCache` 在 tone bucket 場景下幾乎完全失效。一個 512 entry 的 cache 卻在處理數萬個不重複的精確組合，這是 cache 設計與工作負載的嚴重錯配。

---

#### 問題三：Factory Trie 與 User Data 的查詢抽象不對稱

**現狀**：
- Factory trie（`TextMapTrie`）支持 `keysChopped`：一次查詢可以處理整個 tone bucket，返回所有匹配節點。
- User data（`LMCoreEX`）只支持精確 key 查詢：必須傳入 `"shí-jiān"` 才能拿到結果。

**First Principle 分析**：
兩個數據源回答的是同一個問題（「這個讀音對應哪些詞？」），但它們的查詢介面卻不同。這迫使 LMInstantiator 在 `mergedAlternativeBucketUnigrams` 中：
1. 對 factory 用「一次性 chopped 查詢」
2. 對 user data 用「逐個組合精確查詢」
3. 然後在內部合併兩者的結果

這種「不對稱抽象」是 `mergedAlternativeBucketUnigrams` 存在的唯一原因。如果兩個數據源都支持相同的 chopped 查詢介面，這個函式可以簡化為「並行查詢兩個數據源，合併結果」。

**結果**：LMInstantiator 背負了本應由數據源層解決的「介面適配」責任。

---

#### 問題四：Span 查詢的「重複計算」未被任何層級攔截

**現狀**：Homa 的 `assignNodes` 對每個 `(p, l)` span 獨立呼叫 `gramQuerier`。例如一個 6 音節句子：
- span (0,1): `["shi&shí&shǐ&shì&shi̇"]`
- span (0,2): `["shi&shí&shǐ&shì&shi̇", "jian&jiǎn&jiàn&jiān&jián"]`
- span (1,1): `["jian&jiǎn&jiàn&jiān&jián"]`

這些查詢之間有大量重疊，但架構中沒有任何一層會「記住」span (0,1) 的結果並在 span (0,2) 中複用。

**First Principle 分析**：
DP 求解過程中，每個 span 的結果在理論上是獨立的（因為長度不同，grams 也不同）。但 tone bucket 的「展開過程」是大量重疊的：span (0,2) 內部展開時，會重新計算 span (0,1) 和 span (1,1) 已經算過的 joined key、hash、user data 查詢。

**結果**：指數級的浪費被乘以 span 數量。6 音節句子約 36 個 spans，每個 span 內部獨立展開 tone bucket，總計算量 = 36 × 平均組合數 × 每組合成本。

---

#### 問題五：Bigram 資訊在 LookupHub 層被主動丟棄

**現狀**：`LookupHub.grams(for:)` 只回傳 unigrams（`previous: nil`）。Homa 的 `Node.getScore` 已經支持 bigram 查詢（若 grams 中有 `previous` 不為 nil 的項目，會自動選取更高分的 bigram），但生產環境中永遠收不到 bigram。

**First Principle 分析**：
Bigram 是語言模型的核心能力之一。輸入法組字是一個「序列標註」問題，bigram（上下文相關概率）本應是提升準確度的關鍵機制。但目前的介面設計（`GramQuerier = ([String]) -> [GramRAW]`）只接受 `keyArray`，無法接受 previous context。

**結果**：Homa 的 DP 只能基於 unigram 概率做決策，長句準確度受限。更糟的是，因為缺少 bigram 的「上下文約束」，Homa 更依賴於「查詢大量 spans 來找到最優路徑」，側面加劇了查詢負擔。

---

#### 問題六：Homa 對「不可能 Span」毫無過濾

**現狀**：Homa 的 `assignNodes` 對每個 `(p, l)` 都發起查詢，無論這個讀音組合在語言中是否存在。LMInstantiator 內部雖然會返回空結果，但查詢的往返成本（function call、string concat、hash lookup）已經發生。

**First Principle 分析**：
組字引擎應該具備「快速排除不可能組合」的能力。人類在閱讀拼音時，不會嘗試把每個連續 10 個音節都當成一個詞來查——我們知道大多數長組合不存在。

目前 Typewriter 有 `hasUnigramsForFast` 可以在 `insertKey` 前做存在性檢查，但 Homa 在建立 span grid 時完全不做這種檢查。

**結果**：大量查詢注定返回空結果，但架構中沒有一層會攔截它們。

---

### 10.4 Trace 熱點與設計問題的對應關係

| 出現次數 | Leaf Frame | 對應設計問題 |
|---------|-----------|------------|
| 93 | `joined(separator:)` | 問題零、一（& 字串編碼與展開） |
| 76 | `_StringGutsSlice._fastNFCCheck`（hash） | 問題零、一、四 |
| 67 | `Set.contains` | 問題零、一、四 |
| 58 | `Set.insert`（`seen` 去重） | 問題零、一 |
| 40 | `stringCompare` | 問題二、四 |
| 33 | `malloc/free` | 問題四（Array 分配） |
| 29 | `makeFactoryUnigrams` | 問題零、一、四 |
| 21 | `getNodes` / `getEntryGroups` | 問題零、一、四 |

**總結**：Trace 中 top 的幾乎所有熱點，都可以追溯到 **Typewriter 的 `makeToneInsensitivePinyinQueryKey` 用字串編碼結構化語義**這個設計決策所引發的連鎖反應。

---

### 10.5 現狀改良方案

以下分為「治本」（修正問題零的根源）與「治標」（在現有 `&` 字串編碼下緩解症狀）兩類。

---

#### 【治本】方案 Omega：Typewriter 以結構化方式傳遞 Tone Alternatives（ROOT FIX）

**對應問題**：零（根源）、一、二、四

**First Principle 論證**：

既然 `makeToneInsensitivePinyinQueryKey` 把「5 個聲調讀音」編碼成字串是問題的根源，最直接的修正是：**讓這個資訊以結構化方式流經架構，直到 Homa 的 DP 層。**

具體做法有兩種變體：

**Omega-1：Homa 的 `keys` 改為 `[[String]]`（每位置多讀音）**

```swift
// 目前
var keys: [String]   // ["shi&shí&shǐ&...", "jian&jiǎn&jiàn&..."]

// 改為
var keys: [[String]] // [["shi", "shí", "shǐ", "shì", "shi̇"], ["jian", "jiǎn", "jiàn", "jiān", "jián"]]
```

- Typewriter 在 `insertKey` 時傳入 `[String]`（一個位置的所有可能讀音）。
- Homa 在 `assignNodes` 時，對每個 span 的每個可能組合查詢 `gramQuerier`，但**在 Homa 層面合併結果**到同一個 Node。
- `gramQuerier` 的介面保持不變（`([String]) -> [GramRAW]`），永遠只接收精確 keyArray。
- **LMInstantiator 完全不需要 `mergedAlternativeBucketUnigrams`**。

**Omega-2：Typewriter 只插入「最可能的單一讀音」，由 Homa 的 DP 糾正**

- Typewriter 用簡單啟發式（如預設陰平或根據前文預測）選擇一個聲調，只插入單一讀音。
- Homa 的 DP 基於 unigram/bigram 概率自然糾正錯誤的聲調選擇。
- 若用戶需要手動選擇其他聲調，通過候選詞窗口實現。

**Omega-1 vs Omega-2**：
- Omega-1 保留了「免聲調 = 同時查詢所有聲調」的語義，只是將展開從 LMInstantiator 上移到 Homa。
- Omega-2 改變了語義，可能影響組字準確度（若 Homa 無法通過上下文確定正確聲調）。
- 建議實驗 Omega-1，因為它更保守且徹底消除 `&` 機制。

**預期收益**：
- `mergedAlternativeBucketUnigrams` 可以整個刪除。
- LMInstantiator 恢復為純粹的「精確 keyArray → grams」介面。
- Homa 的 cache 可以以「原始 span 的 keyArray」為 key（不含 `&`），命中率恢復正常。

**侵入性**：高（需改動 Typewriter-Homa 介面、Homa 的 `keys` 存儲、Homa 的 `assignNodes`）。

---

#### 【治標】方案 Alpha：條件式去重 + 迭代器回傳 joined key（Phase 46 第一輪）

**對應問題**：零、一（緩解）
**做法**：
1. 在 `AlternativeKeyArrayIterator` 中檢查每列 alternatives 是否互異；若互異則使用無 `seen` Set 的簡化迭代器。
2. 讓迭代器同時回傳 `(keyArray, joinedKey)`，消除迴圈內重複計算。

**預期收益**：在無法移除 `&` 機制的前提下，消除 15,625 次無意義的 joined + hash + Set.insert，以及迴圈內 15,625 次 string concat。

---

#### 【治標】方案 Beta：為 `unigramsFor(keyArray:)` 添加 LRU 快取（LMInstantiator 層）

**對應問題**：四
**做法**：
在 LMInstantiator 內部為 `unigramsFor`（特別是 `mergedAlternativeBucketUnigrams` 的結果）添加一個有上限的 LRU cache。Key 為原始帶 `&` 的 `keyArray`（以 `joined(separator: "&")` 或 hash 表示），Value 為 `[Homa.Gram]`。

由於 Homa 的 `gramQueryCache` 已經在更高層快取，但它是以「展開後的單一組合」為 key，對 tone bucket 場景幾乎無效。LMInstantiator 層的快取可以以「原始 tone bucket key」為 key，命中率高得多。

**風險**：需要處理 user data 變動時的 cache invalidation。
**預期收益**：對重複出現的 tone bucket pattern（如常用詞組），可將查詢時間從數百毫秒降至 <1 ms。

---

#### 【治標】方案 Gamma：Batch Query API（LookupHub 層）

**對應問題**：四
**做法**：
不修改 Homa，僅在 `LookupHub` 與 `LMInstantiator` 內部實現 batch 優化：

```swift
// 新增內部方法（不公開改變介面）
func unigramsFor(keyArrays: [[String]]) -> [[Homa.Gram]]
```

`LookupHub.grams(for:)` 仍保持單一查詢介面，但內部可將連續的查詢收集到一個小 buffer 中（例如 4–8 個），然後批量處理。批量處理時：
1. 一次性對所有 keyArrays 做 tone bucket 展開，共用 `seen` Set（若保留）與臨時記憶體。
2. 對所有 factory trie 查詢一次性執行（TrieKit 層可能已支持 batch）。
3. 對 user data 查詢，一次性計算所有需要檢查的 key 的 hash，減少 cache miss。

**風險**：需要確保「延遲批量」不會影響 UI 響應性。
**預期收益**：減少 function call overhead 與臨時記憶體分配，對短句提升 20–40%。

---

#### 【治標】方案 Delta：為 `LMCoreEX`（user data）添加 `keysChopped` 支持

**對應問題**：三
**做法**：
目前 factory trie 支持 `keysChopped`（一次性查詢所有 tone bucket 組合），但 `LMCoreEX` 不支持。如果為 `LMCoreEX` 添加類似的 chopped 查詢能力：

```swift
func unigramsFor(keysChopped: [String]) -> [(keyArray: [String], grams: [Homa.Gram])]
```

內部實現可類似 factory trie：對每個位置，取 `rangeMap` 中所有 key 的前綴集合，與 alternatives 做交集，然後只查詢交集內的 key。這樣就完全不需要笛卡爾積展開。

**風險**：需要改動 `LMCoreEX` 的數據結構，可能需要預建前綴索引。
**預期收益**：徹底消除 user data 查詢的指數級展開，這是最大瓶頸。

---

#### 【治標】方案 Epsilon：在 `LookupHub.grams(for:)` 中傳遞 bigram context

**對應問題**：五
**做法**：
這是介面層的小改動，但可以釋放 Homa 已有的 bigram 能力：

```swift
// Homa 已有的介面
public var gramQuerier: ([String]) -> [GramRAW]

// 改為
public var gramQuerier: (keyArray: [String], previous: String?) -> [GramRAW]
```

`LookupHub.grams(for:previous:)` 內部查詢 bigram（若數據源支持），並在 `GramRAW` 中填入 `previous`。Homa 的 `Node.getScore` 已經會檢查 bigram，只是目前收到的都是 `previous: nil`。

**風險**：需要確認各數據源（factory trie, user data）是否存儲了 bigram 信息。
**預期收益**：提升長句組字準確度，可能減少對「嘗試多種分段」的依賴。

---

#### 【治標】方案 Zeta：Homa 的 `assignNodes` 加入「存在性預檢」

**對應問題**：六
**做法**：
在 Homa 的 `assignNodes` 中，對每個 `(p, l)` span，先檢查「這個 span 的所有可能讀音組合中，是否至少有一個在原廠詞典中存在」。這可以通過一個極輕量的 `hasGramsFor` 批量查詢完成。

若「完全不存在」，則不建立該 Node（或建立一個空的 placeholder），跳過後續的 `unigramsFor` 完整查詢。

**風險**：若 user data 中有該詞但 factory 沒有，會被誤判為不存在。解決方案：預檢時同時查詢 factory + user data 的 `hasUnigramsFor`（這是 O(1) 的）。
**預期收益**：對長句中大量「不可能組合」的 span，可節省 90% 以上的查詢時間。

---

#### 【治標】方案 Eta：動態 `maxSegLength` 縮減

**對應問題**：六
**做法**：
在 tone bucket 密度高的區域（每個音節 alternatives 數量 > 3），動態降低 `maxSegLength`。例如：

```swift
let toneDensity = keyArray.map { $0.contains("&") ? $0.components(separatedBy: "&").count : 1 }
let localMaxSegLength = min(defaultMaxSegLength, max(3, 6 - toneDensity.max()!))
```

這確保長 span 不會產生爆炸性的組合數。

**風險**：可能錯過超過 3 個音節的長詞。但實際上，超過 4 個音節的詞在中文中極少，且若存在，其機率通常遠低於短詞組合。
**預期收益**：對 8–10 音節長句，可將總查詢次數降低 50% 以上。

---

#### 【治標】方案 Theta：將 InputToken / DateTime / Cassette 擴展延遲到「首次需要時」

**對應問題**：四
**做法**：
目前 `unigramsFor` 每次被呼叫都執行 DateTime 檢查、InputToken 擴展等。這些結果對於相同的 keyArray 是確定的，但呼叫次數極多。

改為：只在「最終回傳給 Typewriter 的 candidates」中執行這些擴展，而不是在 Homa 的每個 span 查詢中都執行。

更具體地說：
- Homa 查詢 span 時，只查詢「實體詞典」內容（factory + user + filtered）。
- InputToken / DateTime / Cassette 的 synthetic grams，在 `generateStateOfCandidates()` 或 `generateStateOfInputting()` 時才按需生成，且只針對「當前 cursor 位置」的 keyArray。

**風險**：若 Homa 的 DP 需要這些 synthetic grams 的分數來決定路徑，延遲擴展會改變組字結果。但 InputToken / DateTime 的分數通常是極低的（作為 fallback），不會影響主路徑。
**預期收益**：消除每次 span 查詢中的 macro 解析與 DateTime 檢查，約 5–10% 的 CPU。

---

### 10.6 優先順序總結

| 優先級 | 方案 | 類型 | 對應問題 | 侵入性 | 預期收益 |
|--------|------|------|---------|--------|---------|
| P0 | Alpha：條件去重 + 迭代器回傳 joined key | 治標 | 零、一 | 極低 | 消除 60%+ 的 string/hash 開銷 |
| P1 | Omega-1：Homa keys 改為 [[String]] | 治本 | 零（根源）、一、二、四 | 高 | 徹底消除 & 機制與 mergedAlternativeBucketUnigrams |
| P2 | Zeta：Homa assignNodes 存在性預檢 | 治標 | 六 | 低 | 跳過大量無意義 span 查詢 |
| P3 | Delta：LMCoreEX 支持 keysChopped | 治標 | 三 | 中 | 徹底消除 user data 的指數展開 |
| P4 | Beta：unigramsFor LRU cache | 治標 | 四 | 低 | 對重複 pattern 降至 <1 ms |
| P5 | Gamma：Batch Query API | 治標 | 四 | 中 | 減少 overhead 20–40% |
| P6 | Eta：動態 maxSegLength | 治標 | 六 | 低 | 長句查詢次數降 50% |
| P7 | Theta：延遲 InputToken/DateTime | 治標 | 四 | 低 | 5–10% CPU |
| P8 | Epsilon：Bigram context 傳遞 | 治標 | 五 | 中 | 準確度提升，非效能 |

**Phase 46 建議執行組合**：
- **第一輪（治標）**：Alpha + Zeta + Eta（低侵入性、高回報）
- **第二輪（治標）**：Delta（需要改動 LMCoreEX 結構）
- **LibVanguard 實驗（治本）**：Omega-1（重構 Typewriter-Homa 介面，徹底移除 & 機制）

---

### 10.7 長遠架構反思：LibVanguard 實驗田的啟示

從 first principle 來看，當前架構的最大設計缺陷是 **Typewriter 用 `&` 字串編碼了結構化的「聲調不確定性」**。這個看似微小的決策（`makeToneInsensitivePinyinQueryKey` 中的 `joined(separator: "&")`）引發了整個下游的連鎖反應：

1. Homa 被迫存儲和傳遞無法理解的字串
2. LMInstantiator 被迫誕生 `mergedAlternativeBucketUnigrams` 這個補丁
3. Cache 機制在 tone bucket 場景下集體失效
4. 數萬次不必要的 string concat、hash、lookup 在每次按鍵時重複執行

`vChewing-LibVanguard` 的實驗性質提供了一個重構空間。值得追蹤的長遠方向：

1. **Omega-1 驗證：Homa `keys` 改為 `[[String]]`**
   讓 Homa 原生理解「一個位置有多個可能讀音」，DP 直接在多讀音圖上運行，`gramQuerier` 永遠只接收精確 keyArray。

2. **「增量組字」替代「全量重建」**：
   目前每次按鍵都觸發 `assignNodes` 重建整個 grid。可以改為只更新受影響的局部區域，並重用未變動 spans 的 Node。

3. **「模糊匹配索引」替代「精確 keyArray 查詢」**：
   為 factory trie 和 user data 建立統一的「前綴/模糊匹配索引」，讓查詢介面直接支持「給定一組 alternatives，返回所有匹配結果」，由 caller 自行合併。

這些方向都已超出 Phase 46 的範圍，但值得在 LibVanguard 中作為獨立實驗追蹤。
