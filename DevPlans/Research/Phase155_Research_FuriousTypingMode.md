# Phase 155 研究報告：狂拼模式的簡拼與長詞瓶頸（Abbreviation & Long-Word Constraints）

> 調查日期：2026-08-28。範圍：vChewing-macOS（`vChewing_Typewriter`／`vChewing_Tekkon`／
> `vChewing_Homa`／`vChewing_LangModelAssembly`＋`TrieKit`）、vChewing-OSX-Legacy（鏡像位置核對）、
> VanguardTrie factory trie（`getEntryGroups(keysChopped:)`「&」查詢）。
>
> 性質：純研究任務，不施工。本報告回應 P155 的兩項調研命題——① 簡寫打長詞的
> cartesian product／`maxSegLength` 數學障礙能否繞開；② 目前只支援句子最前方
> （Frontest，即打字尖端）的省略拼寫、`ysxb`→「野獸先輩」這種整詞簡拼做不出來——
> 並重新盤點 P151 的待決行為清單（原清單混亂，含已過時項目）。
>
> 量化數據均以 Tekkon 漢語拼音表（`mapHanyuPinyin`，427 音節）離線模擬驗證；
> 行為斷言均以源碼逐行核對。

---

## 一、結論速覽

| # | 命題 | 現況 | 根因 | 建議 |
|---|---|---|---|---|
| 1 | 簡寫打長詞 | 打不出來。`ysxb` 停在注拼槽顯示原文拼音，連候選窗都沒有 | ① `pinyinAutoChopResult` 拒收不完整前綴（每段必須是完整音節）→ 多音節簡拼根本不進組字器；② 即使放寬，multipleKeys 桶塞進組字器會觸發既有防卡死縮短（`maxSegLength→4`，§5.1；>4 音節詞不可達）＋ user-phrase 路徑全量笛卡爾展開（`ysxb` 聲調桶乘積 ≈ **8.57×10⁷** ／單次查詢） | **方案 α：整詞簡拼查詢**——以既有 `deductChoppedPinyinToZhuyin`（initial-only 收斂）＋ factory trie「&」chopped 查詢（initial 桶索引，代價有界）直接找整詞，再把命中詞的**實際讀音以單鍵**寫回組字器（不產生桶位置 → 不觸發縮短） |
| 2 | Frontest-only | 簡寫僅限打字尖端（`cursor == length`）的**單一前綴桶**；游標一離開尖端，預覽／候選／固化／重切全部失效 | `furiousFrontContext` 的尖端守衛＋trail 尖端錨定＋copilot 只對「最後一個未完成片段」組句 | 中段簡寫＝獨立工程（牽動 copilot 上下文、trail、POM、游標規則）；`ysxb` 本身是命題一的實例（尖端多音節簡寫），不必等到中段簡寫 |

**建議路線（三階段，R1 可立即落地；查詢鏈路審計另見 §十）**：

1. **R1（γ，立即）**：在保留防卡死防禦（§5.1，2026-04 引入）的前提下，把
   `maxSegLength` 的縮短條件由「見桶即縮至 4」改為依「桶實際大小」條件化——只對真正
   大的桶縮短。現行狂拼每次提交都是 5 聲調桶、恆觸發縮短，**連全拼長詞（>4 音節）
   都組不出來**；這是防禦代價在狂拼下的常態化，純 Homa 側小改、兩倉鏡像。
   （§10.4：R1 併入 LM 層預算閘 B 與逐 span 預算 C、factory 優先早退 E——硬體無關。）
2. **R2（α，主菜）**：LM 層新增「簡拼整詞查詢」API＋Typewriter 狂拼管線接線——
   `ysxb`→「野獸先輩」可達，長度不受 4 音節限制。
3. **R3（δ，演化）**：`FuriousTypingSegmentor` 擴展為「簡拼感知」（用 α 的查詢
   當評分器），把「簡拼整詞」併入自動重切分；中段簡寫另案評估（見 §六）。

---

## 二、任務命題與方法

### 2.1 P155 的兩項調研命題（DevReq 原文要旨）

> 1. 沒辦法用簡寫打長詞：最短的不完全拼寫形態只有「對聲調的省略」。再短的話就會出現
>    cartesian product 壓力。目前在 Homa Assembler 內對此已有以半徑 10 為範圍的偵測
>    應對方案、偵測到 key bucket 就自動將 `maxSegLength` 縮短。但這會導致使用者打不了
>    長詞。應該探究是否有其他辦法繞開這個數學層面的障礙。
> 2. 目前只支持對句子最前方（Frontest）的漢字的省略拼寫。使用者可能會想藉由敲 `ysxb`
>    敲出「野獸先輩」這個詞。然而目前的實作還無法允許使用者做到這一點。

### 2.2 方法

- **靜態研讀**：狂拼管線（`InputHandler_FuriousResegmentation`／`HandleStates`／`TriageInput`／
  `Typewriter_BPMFFullMatch`）、Tekkon（`SyllableComposer.pinyinAutoChopResult`、
  `PinyinTrie.chop`／`zhuyinReadings`／`deductChoppedPinyinToZhuyin`）、Homa
  （`Assembler.assignNodes`／`insertKeys`／`PossibleKey`）、LM 層
  （`unigramsForWithAlternatives`／`expandPossibleKeyArrays`）、factory trie
  （`getEntryGroups(keysChopped:)`／`candidateNodeIDsForChoppedColumns`）。
- **資料表離線模擬**：以 `mapHanyuPinyin`（427 音節）用 Python 復刻 `chop`／`search`／
  `deductChoppedPinyinToZhuyin` 的邏輯，量化 `ysxb` 的每位置桶大小、笛卡爾乘積與
  「野獸先輩」的聲母級命中（詳見 §5.3、附錄 B）。
- **P151 清單重盤點**：逐項核對 `Reqs_0151-0160.md` Phase 151 實作結果與文末
  「未竟事項與備考待決（統一收錄）」，標出已完成／已過時項目（§三）。

---

## 三、P151 待決行為清單重新盤點

> P151 文末清單「比較混亂」（DevReq 原話）：部分項目已在 P151 內部落地卻仍列在待決、
> 部分項目彼此重疊。以下為重新盤點後的乾淨清單（核對至 2026-08-28 實作結果）。

### 3.1 已完成（P151 內部落地，應自待決清單移除）

- **copilot 選字窗 Shift 提示（T2）**——✅ 已於 P151 落地（`candidateToolTip` 狂拼分支
  ＋l10n 四語 key `i18n:CandidateWindow.Tooltip.HoldShiftToSelect`＋`test505`）。
  ⚠️ 原「候選窗體驗強化」待決項目內仍列「候選標籤 Shift 提示」→ **已過時，應刪**，
  僅餘「替代切分 Top-N 入窗」仍待決。

### 3.2 另立 Phase（有明確後續價值，維持）

| 項目 | 狀態 | 備註 |
|---|---|---|
| T1：copilot 組句結果套用 POM 建議（實作） | P151 僅設計定稿 | 需「唯讀 POM 查詢」（把 `fetchPOMSuggestion` 的提取與 `apply` 拆開）；POM 對投機尾段的語義已釐清（借用「讀音前綴＋候選字」相似性）。與本報告 α 方案的整合見 §7.5 |
| 跨音節數重切（`xian`→`xi'an` 類） | M4 評估為不施工 | 現有 scratch drop+insert 可涵蓋失敗路徑；原子 `replaceKeys(from:with:)` 的真正動機仍是此項。R3（簡拼感知重切）與此項同源，可合併設計 |
| 候選窗體驗強化（餘項：替代切分 Top-N 入窗） | 維持 | Shift 提示已落地（§3.1），僅餘 Top-N 入窗 |

### 3.3 長遠評估項

- **方案 C（SunPinyin 式字母級 lattice）**——維持暫不排程；本報告 α 方案能在不改
  Homa 的前提下取得簡拼整詞能力，方案 C 的價值再降。

### 3.4 備考待決（暫不施工）

- **折衷方案「低優先 override＋trail 重切分時 reset trail span」**——保留。屬
  「空格固化後顯示與 copilot 選讀一致」的釘選感與 trail 重切自由度的取捨；本報告
  不觸及，維持備考。

### 3.5 永久定案（不做）

- **雙拼**——維持（有需求的雙拼用戶自行以磁帶承載）。

### 3.6 本報告新增的待決觀察（記入，供未來 Phase）

- **簡拼整詞查詢（方案 α）**——本報告建議的下一階段主菜（§7.2）。
- **`maxSegLength` 偵測精化（方案 γ）**——R1，可獨立成小 Phase（§7.4）。
- **中段簡寫（游標非尖端時簡寫）**——獨立工程，本報告僅定性（§6.3）。

---

## 四、現況事實核對：現行狂拼管線的簡寫能力邊界

### 4.1 現行能力 =「尖端單音節前綴簡寫」

狂拼管線目前能支援的「簡寫」只有一種形態：**打字尖端（`cursor == length`）的注拼槽
裡留著一個「至多一個音節量」的不完整前綴**（如 `shijie` 打完 `shi` 提交後留下的 `j`），
由 `furiousFrontContext`（`InputHandler_HandleStates.swift:43-105`）把該前綴經
`zhuyinReadings(forPinyinFragment:)`（`Tekkon_PinyinTrie.swift:276-284`）展開成注音讀音桶
（不完整前綴＝`search()` 前綴展開；完整音節＝精確注音），再乘五聲調，成為 copilot
預覽＋候選窗＋固化的素材。

守衛鏈（任一不成立即停用整個狂拼前端）：

```
isFuriousTypingModeEffective          // 打字方法＋typingMode == .pinyinFuriousTyping
composer.intonation.isEmpty           // 無聲調暫存
!composer.romajiBuffer.isEmpty        // 注拼槽非空
assembler.isCursorAtAssemblerEdge(.front)   // 游標在打字尖端（cursor == length）
```

### 4.2 `ysxb` 完整追蹤：為什麼一個字都出不來

以現行狂拼模式依序敲 `y` `s` `x` `b`：

1. **`pinyinAutoChopResult(appending:)` 拒收**（`Tekkon_SyllableComposer.swift:262-288`）：
   `committedReadings = leadingSlices.compactMap { mapZhuyinPinyin[$0] }`，且要求
   `committedReadings.count == leadingSlices.count`——**每一段前綴都必須是完整音節**
   才會提交。對 `ysxb`：`chop("ysxb")`＝`["y","s","x","b"]`（模擬驗證），
   `leadingSlices`＝`["y","s","x"]`，三者皆非完整音節 → 每次嘗試都回傳 nil。
   ⇒ 四個字母全留在注拼槽，永不進組字器。
2. **`furiousFrontContext` 無料可組**：`zhuyinReadings(forPinyinFragment: "ysxb")`——
   非完整音節 → `search("ysxb")` 前綴查詢 → **沒有任何音節以 `ysxb` 開頭** → 回傳空桶
   → `furiousFrontContext` 回傳 nil → 預覽／候選窗／tooltip 全部關閉。
3. **可見結果**：組字區只顯示原始拼音 `ysxb`（`readingForDisplay`），無候選、無預覽、
   無重切。Enter／空格照常走「無讀音可固化」的退化路徑。

**結論：`ysxb` 卡在「多音節簡拼根本進不了組字器」這一層**，還沒走到笛卡爾障礙。

### 4.3 現行「簡寫」唯一可行的場合（對照）

`shi`＋`j`：`shi` 是完整音節 → 自動 chop 提交（`makeToneInsensitiveVariants` 五聲調桶）、
`j` 留在注拼槽 → `zhuyinReadings("j")`＝全部 j 起頭音節 → copilot 預覽「世界」＋
跨邊界候選（IH120A）。**這正是「尖端單音節前綴簡寫」**，也是 `shijie`→「世界」
（P150 跨邊界詞）的運作基礎。

---

## 五、問題一的數學障礙剖析

### 5.1 `maxSegLength` 半徑-10 偵測的機制（`Homa_Assembler.assignNodes`，:377-395）

```
var maxSegLength = maxSegLength                    // 預設 10
rangeOfPositions = max(0, cursor-10) ..< min(cursor+10, keys.count)
if maxSegLength > 4 {
  hasMultipleKeysInRange = rangeOfPositions.contains { keys[$0].isMultiple }
  if hasMultipleKeysInRange { maxSegLength = 4 }   // 半徑內見桶即縮至 4
}
```

- 「半徑 10」＝掃描窗以游標為中心 ±10 鍵（等於預設 `maxSegLength`）。
- `PossibleKey.isMultiple`＝`count > 1`（`multipleKeys` 桶）。**只要窗內任一位置是桶，
  動態 `maxSegLength` 直接降到 4** → 幅節（gram）長度只建 1–4 鍵 → **>4 音節的詞
  在組字器中永遠查不到**。這是 DevReq 所稱「偵測到 key bucket 就自動將 maxSegLength
  縮短」的實作。
- 注意縮短只發生在 `assignNodes` 的**局部變數**，不寫回 `config.maxSegLength`
  （Config 的 `didSet` 還強制 `≥ 6`）；語義是「本拍掃描時動態收斂」，非持久狀態。
- **防禦機制沿革（重要）**：此縮短是**刻意的防卡死防禦**，不是獨立問題——由 commit
  `bbe42490`（2026-04-26，「Homa // Reduce maxSegLength if polyKey appears in the radius.」）
  引入，**早於狂拼功能（2026-08）**。當時正值拼音免聲調功能（Phase 37）上線不久、Homa
  剛替換 Megrez 之後：實測出現 tone-bucket 笛卡爾積展開把輸入法（連帶整個桌面）卡死
  數秒的嚴重凍結（Phase 39 根因分析：6 音節免聲調可達 5⁶=15,625 次 `unigramsFor()`；
  Phase 44/45 尚有殘餘 Severe Hang 2.17 s）。此縮短即為對該凍結的應對——註解原文
  「若掃描半徑 > 4 且範圍內有複合讀音鍵，動態縮減 maxSegLength 以避免笛卡爾積爆炸」。
  它是「桶進組字器」模型的既有防線；本報告的 γ（§7.4）只精化其觸發條件、不撤防線。

### 5.2 防禦機制的代價：狂拼每次提交都是聲調桶 → 縮短恆啟動 → 全拼也打不了長詞

狂拼管線的所有「提交讀音」動作（自動 chop、`solidifyFuriousFrontReading`、
`confirmFuriousFrontCandidate`）一律以 `makeToneInsensitiveVariants`（五聲調桶）插入
（`Typewriter_BPMFFullMatch.swift:224`、`InputHandler_FuriousResegmentation.swift:81`）。
⇒ **只要有 ≥1 個已提交音節，`isMultiple` 即為 true，防禦性縮短立刻把 `maxSegLength` 降為 4。**

後果：**現行狂拼模式下，任何 >4 音節的詞都組不出來**——包括全拼。
例：打「七見斷滅智論抄」（7 音節全拼），組字器只能以 ≤4 鍵幅節拼出，無法形成
7 音節單詞。`test_IH129` 只驗證了 2 音節「西安」的合併，未覆蓋長詞。
（註：非狂拼的無調拼音確認同樣插聲調桶、同樣受限，但使用者可用聲調鍵繞開；狂拼
**無聲調鍵可用**，因此這是狂拼的常態限制，不是例外。）

> 定性：縮短本身是**刻意的防卡死防禦**（§5.1 沿革），不是 bug、也不是本報告要修的
> 對象。但它是一個**全域啟發式**——只要窗內有桶就一律縮至 4，不看桶的實際大小；
> 狂拼因每讀音必插聲調桶而**恆處於縮短態**，於是防禦的「代價」變成狂拼的常態：
> **「打不了長詞」不只在簡寫場合，全拼也一樣**。方案 γ（§7.4）在保留防線的前提下
> 精化觸發條件，即可解除全拼長詞限制；簡拼大桶場合縮短仍會觸發（那正是防禦的目的）。

### 5.3 cartesian product 壓力量化（離線模擬，`mapHanyuPinyin`）

`ysxb` 各位置的注音桶大小（×5 聲調）：

| 位置 | 前綴 | 起頭讀音數（無調） | 聲調桶（×5） | initial 類 |
|---|---|---|---|---|
| 0 | `y` | 16 | 80 | ㄧ、ㄩ |
| 1 | `s` | 36 | 180 | ㄕ、ㄙ |
| 2 | `x` | 14 | 70 | ㄒ |
| 3 | `b` | 17 | 85 | ㄅ |

- **聲調桶笛卡爾乘積**：80×180×70×85 ≈ **8.57×10⁷**——這是把 4 個 multipleKeys 桶
  塞進組字器後，`unigramsForWithAlternatives`（`LMInstantiator.swift:1032`）的
  **user-phrase 路徑**（`expandPossibleKeyArrays` 全量展開，:1014-1028）每一次
  4 鍵 gram 查詢要跑的組合數。組字器每拍要對每個（位置, 長度）節點做一次這種查詢
  （`assignNodes` → `queryGramsForAlternatives`），實際成本 × 節點數——**天文數字，
  完全不可行**。
- **無調桶乘積**：16×36×14×17 ≈ **1.37×10⁵**——即使砍掉聲調維度仍過大。
- **factory「&」路徑**：把每位置候選以 `&` 連接（`choppedKeyArray`），
  `getEntryGroups(keysChopped:)`（`TrieTextMap_Core.swift:1291-1358`）以
  **initial 桶索引**（`candidateNodeIDsForChoppedColumns`，:1551-1565）＋逐節點
  `nodeMatchesChoppedColumns`（:1567-1597）驗證——**代價有界**（候選節點數 ×
  每節點 4 格的候選比對）。聲母級收斂後（`deductChoppedPinyinToZhuyin` 的
  `initialZhuyinOnly`，`Tekkon_PinyinTrie.swift:181-215`）每位置只剩 1–2 個 initial 類：
  `ysxb` → `["ㄧ&ㄩ","ㄕ&ㄙ","ㄒ","ㄅ"]`，初始模式組合僅 **2×2×1×1＝4 種**。

### 5.4 關鍵發現：「數學繞道」其實已存在於 factory trie 層

- `deductChoppedPinyinToZhuyin`（`Tekkon_PinyinTrie.swift:181-215`）**已實現**
  逐位置前綴展開＋`initialZhuyinOnly` 收斂（每位置至多 3 個 initial 類）＋`&` 連接——
  正是「聲母級簡拼」的標準產物（對齊 P148 §2.2 引述的中文之星 `dn`→`d n` 機制）。
- factory trie 的 `getEntryGroups(keysChopped:)` **已能消費**這個格式，且
  `nodeMatchesChoppedColumns` 的 `partiallyMatch` 就是為「每格前綴匹配」設計的。
- **野獸先輩（ㄧㄝ-ㄕㄡ-ㄒㄧㄢ-ㄅㄟ）逐格比對全部命中**（模擬驗證）：
  `ㄧㄝ` startswith `ㄧ` ✓、`ㄕㄡ` startswith `ㄕ` ✓（`s` 的桶含 ㄕ）、
  `ㄒㄧㄢ` startswith `ㄒ` ✓、`ㄅㄟ` startswith `ㄅ` ✓。
- 現況唯一問題：**這條路徑沒有任何生產消費端**——`deductChoppedPinyinToZhuyin`
  僅在測試（`TekkonTests_Basic`／`TrieJoinedTests`／`TrieKit_Tests`）中使用；
  `TrieJoinedTests.testTrieJoinedAssemblyingUsingPartialMatchAndChops` 甚至已驗證過
  「`chop`→`deduct`→`assembler.insertKey("&" 串)`」的整條組句可行（測試詞庫，無法
  暴露效能問題）。

### 5.5 障礙的正確定性

> **數學障礙不在「查詢詞庫」本身（factory「&」路徑已有界），而在「把每位置的多讀音
> 以 `multipleKeys` 桶塞進組字器」這個模型**：它同時觸發 ① `maxSegLength` 縮短
> （§5.1）與 ② user-phrase 全量笛卡爾展開（§5.3）。繞開的方式不是改良縮短偵測，
> 而是**別把桶放進組字器**——改用「整詞查詢＋實際讀音單鍵寫回」：
>
> 1. 字母流（`ysxb`）→ `chop` → 每段 `deduct`（initial-only 收斂）→ factory「&」查詢；
> 2. 命中整詞（野獸先輩）後，把該詞的**實際讀音**（ㄧㄝ-ㄕㄡ-ㄒㄧㄢ-ㄅㄟ）以
>    **單鍵**（`.singleKey`）插入組字器；
> 3. 組字器內**沒有桶** → `isMultiple` 全 false → `maxSegLength` 維持 10 → 任意長詞可達，
>    user-phrase 路徑也回到單鍵 fast path（零笛卡爾）。
>
> 這就是本報告的方案 α（§7.2）；`maxSegLength` 縮短（§5.1）在 α 的語義下退化成
> 既有防線的兜底，只對「真的把大桶放進組字器」的殘留場合觸發。

---

## 六、問題二的 Frontest-only 剖析

### 6.1 尖端守衛與 trail 尖端錨定

- 狂拼的「前方（Frontest）」＝打字尖端（`cursor == length`，`Homa_Assembler.swift:281-291`；
  游標不在尖端時 `furiousFrontContext` 直接回 nil）。
- `furiousTrail` 錨定在尖端：自動 chop 提交的拼音 blob 逐段累積
  （`Typewriter_BPMFFullMatch.swift:242-254`），重切分
  （`resegmentFuriousTrailIfNeeded`）要求 `isCursorAtAssemblerEdge(.front)`
  （`FuriousResegmentation.swift:198`）且 trail span 與組字器尾端鍵逐一比對
  （:211-215）——trail 存續本身就是「尖端無 explicit override」的保證。
- 任何讓游標離開尖端的動作（方向鍵、標記）都會令 trail 失效（T2 紀律，
  `InputHandler_CoreProtocol.swift:233-235` 一帶）。

### 6.2 中段簡寫的牽連面（若要支援「游標在句中敲簡寫」）

若要在非尖端位置支援簡寫，以下全部都要重新設計：

| 面向 | 現行（尖端） | 中段所需 |
|---|---|---|
| copilot 上下文 | 以 `assembler.keys.last`＋尖端桶組跨邊界查詢 | 以游標前後鍵為錨（前鍵＋後鍵）重組邊界查詢 |
| 固化 | `solidifyFuriousFrontReading` 在尖端插入 | 在游標處插入＋`assignNodes` 重掃 |
| trail | 尖端錨定、重切只動尾端 | 中段插入破壞 trail 不變量 → trail 必須失效（＝簡寫與重切互斥） |
| POM | 顯式選字寫入 | 語義同（讀音序列覆寫），但游標錨點不同 |
| 游標規則 | T8：尖端讀音存在時方向鍵＝固化＋開窗 | 中段無對應規則 |

### 6.3 定性

- **`ysxb` 是命題一的實例，不是命題二**：它在句子開頭（= 尖端）敲入，卡在
  「多音節簡拼進不了組字器」（§4.2），與「只支援尖端」無關。α 方案（§7.2）解決後
  `ysxb` 立即可用。
- **真正屬於命題二的場景**是「句子打到一半、游標移回句中、想用簡寫補/改某字」——
  這是獨立且牽連面大的工程（§6.2），本報告建議**先以 α 滿足整詞簡拼，中段簡寫
  另案評估**；R3（簡拼感知重切）的架構（α 查詢當評分器）若做成「任意游標位置的
  局部重切」，可自然延伸覆蓋一部分中段場景。

---

## 七、繞開數學障礙的方案評估

### 7.1 方案 α（推薦）：整詞簡拼查詢 API

**資料流**：

```
字母流（ysxb）
  → Tekkon.chop → ["y","s","x","b"]
  → Tekkon.deductChoppedPinyinToZhuyin(_, initialZhuyinOnly: true)
      → ["ㄧ&ㄩ","ㄕ&ㄙ","ㄒ","ㄅ"]          // 每位置 1–2 個 initial 類
  → LM 層新 API「簡拼整詞查詢」：
      ├ factory：getEntryGroups(keysChopped:..., partiallyMatch: true)   // 有界（§5.4）
      └ user-phrase：有界展開（見 α-3）
  → 命中整詞候選（野獸先輩 …），按分數排序
  → 選中後：以該詞的實際讀音（ㄧㄝ-ㄕㄡ-ㄒㄧㄢ-ㄅㄟ）**單鍵**寫回組字器
```

**α-1（Tekkon）**：`deductChoppedPinyinToZhuyin` 已完備（聲母級收斂＋`&` 連接），
僅需確認輸出契約（`initialZhuyinOnly` 的 trim 上界 3 是否夠用——拼音表實測每位置
initial 類 ≤2，足夠）。

**α-2（LM 層新 API）**：新增 `LookupHub.abbreviatedWordCandidates(keysChopped:)` 一類
介面，內部：
- factory：走既有 `getEntryGroups(keysChopped:partiallyMatch: true)`（`TrieProtocol`
  已有此入口，`LMInstantiator_TextMapExtension.swift:277` 已是生產消費端）；
- 需注意 `partiallyMatch: true` 下 factory 的「每格前綴」語義與 `initial` 類收斂的
  一致性（`nodeMatchesChoppedColumns` 的 `hasPrefix` 對 initial 類直接成立）；
- 回傳的 gram 帶完整讀音＋分數，可直接排序取 Top-N。

**α-3（user-phrase 有界展開）**：`lmUserPhrases`（`LMCoreEX`）是「-」連接的排序鍵
二分查詢結構，**沒有 initial 索引**。簡拼整詞若要涵蓋使用者造詞，二選一：
- 設笛卡爾預算上限（如乘積 > 4096 就跳過 user-phrase 展開，只查 factory）——
  成本可控、實作最小；
- 或為 user-phrase 建 initial 索引（工程較大，列為後續）。
  `partialMatchEnabled`（預設 false）是既有「使用者造詞前綴匹配」開關，語義不同，
  不宜直接挪用。

**α-4（寫回語義）**：命中詞以單鍵寫回 ⇒ 組字器無桶 ⇒ `maxSegLength` 不縮短、
user-phrase 走 fast path（零笛卡爾）。確認後可直接覆寫該 span（仿既有
`applyFuriousFrontCandidate` 的跨邊界覆寫紀律），POM 政策沿用「顯式選字才寫入」。

### 7.2 整合方式（與現行狂拼管線的接線建議）

- **入口**：現行 copilot 候選窗（`furiousTypingFrontCandidates`）在「注拼槽整段
  無法展開成單一音節桶」時（如 `ysxb`），新增「簡拼整詞」候選分區——置頂整詞猜測、
  其後 factory「&」命中詞、其後 user-phrase 命中詞。選字手勢沿用 Shift＋選字鍵；
  空格固化語義可比照「整詞確認」。
- **觸發時機**：不只在尖端單音節前綴；只要注拼槽內容 `deduct` 後能產生 ≥2 個
  initial 類組合（即多音節簡拼候選）就觸發。
- **與 trail 的關係**：整詞確認＝使用者顯式干涉 → trail 失效（與就地選字同政策）；
  若走「自動預覽不確認」，則維持 trail 不變（copilot 是暫態試算）。
- **Homa 零改動**（理想態）：α-2/α-4 在 LM 層與 Typewriter 層完成；Homa 只負責
  收「實際讀音的單鍵序列」。

### 7.3 方案 β（桶進組字器＋放寬 chop 門檻）——量化後判定不可行

放寬 `pinyinAutoChopResult` 讓不完整前綴也可提交、再把 y/s/x/b 以 multipleKeys 桶
塞進組字器：user-phrase 路徑每 4 鍵查詢 ≈ 8.57×10⁷ 次展開（§5.3），且 `maxSegLength→4`
直接封死 >4 音節。縱使加「笛卡爾預算上限」保住效能，長詞仍被 `maxSegLength=4` 卡死，
且簡拼整詞仍需單獨查詢——**β 是 α 的下位替代**，不值得做。僅在「每位置桶真的很小」
（如全拼 5 聲調桶）時可接受，而那正是現行（受限制的）狀態。

### 7.4 方案 γ（防禦條件精化）——R1，立即落地

- 原則：**防禦機制本身不是問題**（§5.1 沿革：刻意設計、防笛卡爾卡死），但它是全域
  啟發式——「見桶即縮至 4」不看桶的實際大小，對小桶（如 5 聲調桶）過度觸發、白白
  犧牲長詞（§5.2）。γ＝**在保留防線的前提下，把觸發條件由「見桶」精化為「實際笛卡爾
  乘積超標」**：例如只當「窗內桶的讀音數乘積 > 閾值（如 10⁴）」時才縮短；5 聲調桶
  （5⁴=625）遠低於閾值 → 不縮短 → 全拼長詞立即可得；簡拼大桶場合乘積超標 → 縮短
  照舊觸發（那正是防禦的目的、防線不撤）。
- 改動面：僅 `Homa_Assembler.assignNodes`（兩倉鏡像）＋Homa 測試；零 UI、零 LM 變更。
- 注意：γ 只解除「全拼長詞」的防禦代價，不解決簡寫（那需要 α）；狂拼/無調拼音的
  **全拼**長詞由 γ 解禁。
- 風險：需對照 PathFinder 的節點成本實測閾值（桶乘積在 10³–10⁴ 時 factory「&」路徑
  仍是有界可接受的）；閾值以「維持既有 54/54（Homa）／136/136（Typewriter）／35/35
  （Tekkon）／68/68（MainAssembly）等測試通過」為底線，且**不得讓
  §5.1 所述的卡死場景回歸**（需以 phase 37/39/44/45 的笛卡爾壓力案例做回歸對照）。
- **硬體下限校準（事主發問後補記，2026-08-28）**：笛卡爾展開屬分配/ARC 密集，
  牆鐘時間與 CPU 世代高度相關——2026 Apple Silicon 上 8.57×10⁷ 組合 ≈ 7–13 s，
  2006–2008 Core 2 Duo（macOS 10.9 硬體下限；10.9 官方要求 64-bit、初代 32-bit
  Core Duo 不在此列）粗估 60–250 s（IPC＋DDR2＋舊 Swift 5 runtime 合計約 1/8–1/20）。
  ⇒ γ 的閾值**必須以 Legacy 的硬體下限校準**、而非以開發機校準；熱路徑上
  user-phrase 全量展開（§5.3）無論如何不應放行——「有界」必須是硬體無關的
  語義（factory「&」路徑即此類），而非「現代機上跑得動」。

### 7.5 方案 δ（R3）：`FuriousTypingSegmentor` 擴展為簡拼感知

- 現行重切分器（`FuriousTypingSegmentor`）只比較「同音節數」的完整音節切分、且
  `isValidSyllable` 以完整音節為限（`FuriousTypingSegmentor.swift:33-39`）。
- R3：`isValidSyllable` 接受「前綴」（簡拼段），`syllableScore` 改為「以 α 的整詞查詢
  評分」——把簡拼整詞併入 trail 自動重切（`ysxb` 全程自動出「野獸先輩」，
  不必等使用者確認）。與「跨音節數重切」（P151 清單）同源，可合併設計。
- 依賴 α 先落地（α 的查詢是 δ 的評分器）。

---

## 八、與 P148 設計原則的對照

| P148 原則 | 現況（P155 調查） | 落差 |
|---|---|---|
| §2.2 簡拼是一等公民、完整匹配優先（同管線、前綴樹共存） | 現行僅「尖端單音節前綴」能簡拼；多音節簡拼進不了管線 | α 方案即為此原則的落地（factory「&」路徑＝同一前綴樹共存） |
| §6.4 方案 B（LM 引導切分；DP 評分） | 重切分器已落地但只處理完整音節 trail | δ（R3）把 α 查詢接成評分器，即方案 B 的簡拼擴展 |
| §6.6 候選窗（整句／尾段／詞三層） | copilot 窗只有「置頂＋跨邊界＋尾段單音節」三區 | α 的「簡拼整詞」分區正好補上「詞層」缺口 |

---

## 九、建議路線圖與風險

| 階段 | 內容 | 受影響模組 | 風險 |
|---|---|---|---|
| R1（γ） | `maxSegLength` 防禦條件精化（保留防卡死防線、依桶實際大小觸發） | Homa（assignNodes）＋測試；兩倉鏡像 | 低；需實測閾值、不得讓 §5.1 卡死場景回歸；Homa 是 LGPL、需同步 legacy |
| R2（α） | LM 新 API（整詞簡拼查詢）＋狂拼管線接線＋候選分區 | LangModelAssembly（新 API）＋Tekkon（契約確認）＋Typewriter（furious 分支）＋MainAssembly（l10n 若需提示） | 中；user-phrase 涵蓋需預算上限；`partiallyMatch` 語義需測試鎖定 |
| R3（δ） | 簡拼感知重切＋跨音節數重切合併 | Typewriter（FuriousTypingSegmentor）＋Homa（若需重切 API） | 中高；重切紀律（游標／覆寫／POM）與 Phase 134/136 座標化寫回需一致 |

**待決觀察**（供未來 Phase 記入 DevReq）：

1. 中段簡寫（§6.2）是否做、以何種架構做——建議在 R2 穩定後評估。
2. user-phrase 簡拼：預算上限（實作最小）vs initial 索引（體驗最完整）的取捨。
3. `partialMatchEnabled` 開關與 α 查詢的關係需釐清（語義不同、勿混用）。
4. α 的「整詞確認」與空格固化（`solidifyFuriousFrontReading` 只插聲調桶）的
   互動——整詞確認後 trail 失效與否需定案（建議：顯式選字＝失效，同就地選字政策）。
5. **l10n 連動（事主備註，2026-08-28）**：若笛卡爾問題經 γ／α 解決或改善，
   `i18n:UserDef.kKeyboardParser4Pinyin.description` 的**四語文本**需同步修訂、以反映
   實際情況——現文本描述「±10 掃描範圍內存在不完全拼寫（如聲調缺失）時，組字引擎
   可能套用『最長 4 個讀音』上限；僅當範圍內所有讀音皆為完整帶聲調拼寫時才不套用」
   （zh-Hant/zh-Hans/ja/en，`Sources/vChewingIME_macOS/Resources/*.lproj/Localizable.strings:420`
   ，legacy 倉鏡像）。γ（§7.4）把上限改為依實際笛卡爾乘積觸發後，此描述即與實作脫鉤。
6. **查詢鏈路審計（§10，2026-08-29 事主授權）**：新手段 A–G 併入路線圖（R1：B/C/E；
   R2：A/D；R3：F 可選）。其中 **A（user-phrase 多前綴區間掃描）**為補完「factory 有界、
   user-phrase 仍全量」缺口的關鍵——R2 的實作優先項；**B（LMI 笛卡爾預算閘）**為
   硬體無關兜底、可先行。

---

## 十、查詢鏈路審計與其他繞道手段（2026-08-29 事主授權追加）

> 背景：事主授權檢討 Homa→Lexicon（Trie）的完整查詢鏈路、加上 Typewriter 查詢體系，
> 尋找除 §7 方案之外「其他可以應對或繞過笛卡爾問題的手段」。本節為審計結果：
> 全鏈路逐層核對（§10.1）、現存防禦/緩解點清單（§10.2）、新手段 A–G（§10.3）、
> 分級整合（§10.4）。

### 10.1 查詢鏈路全貌（Typewriter→Homa→LM→Trie）

```
Typewriter（狂拼＋一般拼音）
  ├ furiousFrontContext：zhuyinReadings(romajiBuffer) → 5 調桶 →
  │     copilot scratch insertKeys([.multipleKeys(桶)]) ／ buildFuriousFrontCandidates：
  │     grams([.multipleKeys(桶)])、grams([lastKey, .multipleKeys(桶)])   ← 1–2 位置桶
  ├ FuriousTypingSegmentor.syllableScore：grams([.multipleKeys(桶)])       ← 單位置
  ├ resegmentFuriousTrailIfNeeded：insertKeys(keyBuckets)                 ← N 位置桶（trail 全長）
  ├ readingKeyForQuery（無調確認）：insertKey(makeToneInsensitiveVariants)  ← 單位置 5 調桶
  └ associatedCandidates／supplementalValues／cassetteQuickSets             ← 非熱路徑
        ↓ currentLM.lookupHub.grams(for:)（LMInstantiator.swift:137-139）
Homa Assembler
  ├ insertKeys：每位置存在性檢查（gramAvailabilityChecker 線性，:195-211）
  ├ assignNodes：每 (位置,長度) span → queryGramsForAlternatives（gramQueryCache LRU，:515-534）
  │     └ 窗內有桶 → 防禦性 maxSegLength→4（:377-395，bbe42490）
  ├ PathFinder：對已建節點 DP（beam）
  └ fetchCandidates：游標重疊節點 grams 過濾＋排序（CandidateAPIs:19-77）
        ↓ gramQuerier = lookupHub.grams（unigramsFor）
LMInstantiator.unigramsFor(keyArray:partiallyMatch:)（:647）
  ├ 快路徑（無多鍵桶，:647-878）：factory＋userPhrases(單鍵)＋userSymbols＋ETen/plainBopomofo
  │     ＋dateTime＋replacements＋filtered＋cassette
  └ 替代路徑 unigramsForWithAlternatives（:1032）：
        ├ factory：choppedKeyArray（"&" 連接）→ getEntryGroups(keysChopped:)   ← 有界
        └ userPhrases／cassette／plainBopomofo／dateTime／filtered：
              for subKeyArray in expandPossibleKeyArrays(keyArray)（:1014-1028） ← 全量笛卡爾
  └ unigramLRUCache（LMI instance，:871-876）
        ↓
Trie 層
  ├ factory TextMapTrie：
  │     getEntryGroups(keysChopped:)（TrieTextMap_Core:1291-1358；parseChoppedColumns＋
  │       candidateNodeIDsForChoppedColumns（initial 桶索引）＋nodeMatchesChoppedColumns）
  │     getEntryGroups(keyArray:)（:1474-1519；exact／superset／partiallyMatched）
  │     getNodeIDsForKeyArray（initials buckets，:1360-1394）
  └ user LMCoreEX（lmCoreEX.swift）：
        排序鍵（replaceData :158-177）、entryRange(forKey:) 二分（:400-422）、
        keys(matchingPrefix:) 單前綴二分＋前向掃描（:317-360）、unigramsFor(keyPrefix:)（:369-388）、
        temporaryMap
```

### 10.2 現存防禦/緩解點（全部已核對）

| # | 機制 | 位置 | 性質 |
|---|---|---|---|
| 1 | `assignNodes` maxSegLength→4 縮短 | `Homa_Assembler.swift:377-395` | 全域啟發式防卡死（§5.1，bbe42490）；代價＝長詞受限（§5.2） |
| 2 | factory「&」chopped 有界路徑 | `TrieTextMap_Core.swift:1291-1358` | initial 桶索引＋逐格驗證；O(候選節點×格) 硬體無關 |
| 3 | chop 門檻（只提交完整音節） | `Tekkon_SyllableComposer.swift:281-282` | 多音節桶根本進不了組字器（§4.2）——因禍得福的防線 |
| 4 | `gramQueryCache`（Homa）＋`unigramLRUCache`（LMI） | :515-534 / :871-876 | 重複查詢命中；不解決爆炸本身 |
| 5 | `hasUnigramsForFast`／`gramAvailabilityChecker` | `insertKeys:195-211` | 存在性線性預檢；單鍵語義、無聯合預算 |
| 6 | `FuriousTypingSegmentor` 同音節數約束 | `FuriousTypingSegmentor.swift:50-82` | 重切候選有界（但只限完整音節） |
| 7 | `fetchCandidates` 的 `keyArray4Query` 粗過濾 | `CandidateAPIs_FetchAndApply.swift:44-51` | 候選窗過濾、非查詢端 |

### 10.3 其他手段（可應對／繞過笛卡爾）

**A. user-phrase 多前綴區間掃描（最重要的新手段）**

- 現況：替代路徑對 user-phrase 逐 combo 各做一次二分查詢（`expandPossibleKeyArrays` 全量
  笛卡爾 → `lmUserPhrases.unigramsFor(key: subKeyChain)`）→ O(乘積)。
- 手段：`LMCoreEX` 的 key 是**排序的「-」連接注音串**——對「每位置候選集 R₁…Rₙ」做
  **多位置前綴交集掃描**（在排序鍵陣列上遞迴前綴下潛，類似 sorted-array trie walk），
  只訪問「確實可能匹配」的鍵。複雜度 O(匹配鍵數 × 位置數)，而非 O(乘積)——取得與
  factory initial 桶同等的「有界」性質，**且不需要額外建 initial 索引**（排序鍵陣列
  本身即索引）。逐位置可先做 initial 字元集合收斂（對齊 `deductChoppedPinyinToZhuyin`
  的 `initialZhuyinOnly` 精神）。
- 影響面：`LMCoreEX` 新增一方法（如 `unigramsFor(keyArraysChopped:...)`，沿用既有
  byte 級比對）；`unigramsForWithAlternatives` 的 user-phrase 迴圈改走之。
- 這是把 Phase 39 方案 A（factory chopped，`bbe42490` 前後時代的解法）的同一思想
  推廣到 user-phrase——補上 §5.3 所述「factory 已有界、user-phrase 仍全量」的最後缺口。

**B. LMI 笛卡爾預算閘（budget cap，硬體無關兜底）**

- `unigramsForWithAlternatives` 開頭算乘積；超過閾值（如 10⁴）時，逐 combo 迴圈
  （userPhrases／cassette／plainBopomofo／dateTime／filtered）跳過，只留 factory「&」
  有界路徑；或「每位置截斷至 K 個讀音」把乘積壓進預算。
- 犧牲部分覆蓋率、換「**任何硬體都不凍結**」——閾值以 Legacy 硬體下限校準（§7.4
  硬體下限條目）。這是 γ 的 LM 層對應物：γ 管組字器掃描、B 管 LM 查詢。

**C. Homa 逐 span 笛卡爾預算（γ 的精化）**

- 取代「見桶即縮至 4」的全域縮短：對每個 (位置, 長度) span 算「桶乘積」，**超標才**
  對該 span 做有界處理（factory-only 或跳過），而非整個窗一律縮短。全拼長詞不再被
  誤傷；maxSegLength 縮短退居「最後防線」。
- 與 B 組合後，防禦從「縮短幅節長度」變成「查詢層面有界」——這是 §7.4 γ 的實作細化。

**D. 「&」-singleKey 編碼（讓桶與縮短徹底脫鉤）**

- 每位置候選以 `&` 塞進**單一** PossibleKey → `isMultiple == false` → 不觸發 maxSegLength
  縮短 → 長詞可達；factory 直接吃 `&`（`getEntryGroups(keysChopped:)` 偵測 `&`），
  user-phrase 靠 A 處理。即「桶進組字器但不受縮短限制」的形態（§5.4 的「&」機制
  正式化）。注意：`PossibleKey.singleKey` 不拆分 `&`、`isMultiple` 不受影響，已核對
  （`Homa_PossibleKey.swift`）。

**E. factory 優先＋早退**

- 替代路徑先跑 factory「&」（有界、通常已含目標詞）；若 factory 候選已 ≥ N 個且乘積
  超預算，跳過 user-phrase 展開——以覆蓋率換凍結。注意使用者造詞命中不能因此被吞：
  早退門檻保守（僅在超預算時早退）。

**F. lazy 展開**

- `expandPossibleKeyArrays` 改 lazy generator＋早退（找到足夠結果即停），避免物化
  8.57×10⁷ 個陣列。對「前 K 個就夠」的候選窗／beam 語義合理（PathFinder 本有 beam）。

**G. Typewriter 側維持「單桶查詢原則」**

- copilot／候選窗查詢維持「1 桶＋（可選）1 固定鍵」形態（乘積 ≤ 桶大小，可控）；
  多位置桶只出現在 ① α 的整詞查詢（factory「&」＋A/B 有界）與 ② trail 重切
  （`resegmentFuriousTrailIfNeeded` 的 `insertKeys(keyBuckets)`，受 γ/C 防禦罩住；
  γ 放寬後必須以 B/C 兜底、重切每候選試算也有界）。

### 10.4 分級整合（併入 §九 路線圖）

| 階段 | 原內容 | 本審計追加 | 說明 |
|---|---|---|---|
| R1（γ 擴充） | γ 防禦條件精化 | **C**（逐 span 預算）＋**B**（LMI 預算閘）＋**E**（factory 優先早退） | 全部硬體無關、Homa＋LM 層小改、兩倉鏡像；B/C/E 互補、可先行 |
| R2（α） | 整詞簡拼查詢 | **A**（user-phrase 多前綴掃描）＋**D**（「&」編碼） | A 讓 user-phrase 也有界，補完 §5.3 缺口；D 讓桶與縮短脫鉤 |
| R3（δ） | 簡拼感知重切 | F（lazy 展開，可選） | 重切試算每候選有界（B/C 兜底） |

### 10.5 驗證方法

- A：以離線模擬（排序鍵陣列＋多前綴掃描）對 `ysxb` 類查詢計數「訪問鍵數」——
  應 ≈ 實際匹配詞數（而非乘積）。
- B/C/E：既有測試（54/54 Homa／136/136 Typewriter／35/35 Tekkon／68/68 MainAssembly 等）
  ＋ phase 37/39/44/45 笛卡爾壓力案例回歸；
  閾值以 Legacy 硬體下限校準（§7.4 硬體下限條目）。

---

| 檔案 | 角色 |
|---|---|
| `T/InputHandler/InputHandler_HandleStates.swift:43-105` | `furiousFrontContext`（尖端守衛＋讀音桶＋copilot 試算＋跨邊界偵測） |
| `T/InputHandler/InputHandler_FuriousResegmentation.swift` | `solidifyFuriousFrontReading`／`applyFuriousFrontCandidate`／`resegmentFuriousTrailIfNeeded`（trail 重切） |
| `T/Typewriter/Typewriter_BPMFFullMatch.swift:214-254` | 自動 chop 消費＋trail 累積 |
| `Tek/Tekkon_SyllableComposer.swift:262-288` | `pinyinAutoChopResult`（完整音節門檻） |
| `Tek/Tekkon_PinyinTrie.swift:181-284` | `chop`／`search`／`deductChoppedPinyinToZhuyin`／`zhuyinReadings` |
| `H/Homa_MainComponents/Homa_Assembler.swift:377-395` | `assignNodes` 的 `maxSegLength` 半徑-10 縮短（防笛卡爾卡死防禦，2026-04-26 `bbe42490` 引入、早於狂拼） |
| `H/Homa_BasicTypes/Homa_PossibleKey.swift` | `PossibleKey`（single／multiple） |
| `LangModelAssembly/LMInstantiator.swift:1014-1128` | `expandPossibleKeyArrays`（user-phrase 全量笛卡爾）＋`unigramsForWithAlternatives` |
| `LangModelAssembly/TrieKit/TrieTextMap_Core.swift:1291-1597` | `getEntryGroups(keysChopped:)`「&」查詢（initial 桶索引＋逐格驗證） |
| `LangModelAssembly/SubLMs/lmCoreEX.swift:234-293` | `lmUserPhrases`（「-」排序鍵，無 initial 索引） |
| Legacy 鏡像 | `vChewing-OSX-legacy/Shared/vChewingComponents/Typewriter/`（R1 涉及 Homa、R2/R3 涉及 Typewriter，需同步） |

## 附錄 B：量化數據（模擬自 `mapHanyuPinyin`，427 音節）

| 量 | 值 |
|---|---|
| `chop("ysxb")` | `["y","s","x","b"]` |
| `deduct(..., initialZhuyinOnly: true)` | `["ㄧ&ㄩ","ㄕ&ㄙ","ㄒ","ㄅ"]` |
| 各位置無調讀音數 | y:16、s:36、x:14、b:17 |
| 各位置聲調桶（×5） | y:80、s:180、x:70、b:85 |
| 聲調桶笛卡爾乘積 | **85,680,000 ≈ 8.57×10⁷** |
| 無調笛卡爾乘積 | **137,088 ≈ 1.37×10⁵** |
| initial 類組合數 | 2×2×1×1 = **4** |
| 野獸先輩（ㄧㄝ-ㄕㄡ-ㄒㄧㄢ-ㄅㄟ）逐格 initial 命中 | 全中（4/4） |

## 附錄 C：本次調查的執行方式

- 第一手研讀：狂拼管線五檔、`pinyinAutoChopResult`、`PinyinTrie` 三函式、Homa
  `assignNodes`／`insertKeys`／`PossibleKey`、`unigramsForWithAlternatives`／
  `expandPossibleKeyArrays`、factory trie「&」查詢全鏈、`lmUserPhrases` 結構。
- 離線模擬：以 Python 復刻 `chop`／`search`／`deductChoppedPinyinToZhuyin`，量化
  `ysxb` 桶大小、笛卡爾乘積與「野獸先輩」聲母級命中（附錄 B）。
- 行為核對：`test_IH116–131` 測試清單（確認現行能力邊界）、`TrieJoinedTests`（確認
  「&」整鏈曾於測試層驗證）、Legacy 鏡像路徑核對。
- 未做：未修改任何源碼、未運行任何測試套件（純研究任務）。

## 附錄 D：後續實作追蹤（P156／P157 完工，2026-08-28）

> 本附錄記錄本報告建議路線 R1（γ）→ R2（α）的落地結果，以及截至 R2 完工後
> Furious 模式的已知待決事項。兩倉（＋LibVanguard 鏡像）同步。

### D.1 P156（R1 防禦體系精化）完工

- **γ（Homa）**：`Homa_Assembler.assignNodes` 以「窗內各鍵讀音數乘積 > 10,000（飽和、
  早停）」取代「任一 isMultiple 即縮短」——全拼長詞與免聲調 5 音節以下（5⁵=3,125）
  整詞可組，免聲調 6 音節以上（5⁶=15,625）防線保留（防卡死回歸）。三倉鏡像。
- **B／E（LMI 預算閘）**：`unigramsForWithAlternatives` 開頭算笛卡爾乘積、超閾時放棄
  `expandPossibleKeyArrays` 展開（記憶體爆量防禦）、逐 combo 迴圈短路、保留 factory「&」
  有界路徑、CNS 過濾超閾跳過、早退不吞使用者造詞。
- **附帶修復（三倉 TrieKit）**：`decodeUTF8ScalarValue`／`decodeUTF8Scalar` 缺 ASCII
  `case 1`（`41a99834` 引入）→ `getEntryGroups(keysChopped:)` 對 ASCII 讀音鍵恆空，
  補分支＋回歸測試。
- **l10n**：`kKeyboardParser4Pinyin.description` 四語改寫（§7.2 待決觀察第 5 項）。
- 驗證：Homa 58/58、Typewriter 136/136、LangModelAssembly 127/127、MainAssembly 68/68、
  Legacy `make debug-core` ✅、LibVanguard build＋test ✅。

### D.2 P157（R2 簡拼整詞能力）完工

- **A（user-phrase 多前綴交集掃描）**：`LMCoreEX.keys(matchingPrefixesByPosition:)`／
  `unigramsFor(keyPrefixesByPosition:)`——排序鍵陣列即索引（位置 0 首字元二分收斂＋逐位置
  byte 前綴比對及早退出＋temporaryMap 線性掃描）；語義＝舊「逐 combo 前綴查詢」聯集的
  超集（每位置前綴命中，R2 目標所需；per-key 下游與舊路徑逐字節一致）。§10 待決觀察
  第 2 項（預算上限 vs initial 索引）由此解決（免建索引、比預算上限完整）。
- **α（整詞簡拼查詢）**：`LookupHub.abbreviatedWordCandidates(keysChopped:)`（factory
  「&」恆 partial＋user-phrase 多前綴掃描；分區＝置頂整詞猜測→factory→user-phrase）；
  Typewriter `furiousAbbreviatedCells`（chop＋deductChoppedPinyinToZhuyin）＋
  `generateStateOfInputting` 單音節桶失效時附整詞簡拼候選＋confirm/preview 守衛放寬
  （α 候選走既有 `applyFuriousFrontCandidate`＝實際讀音單鍵寫回、Homa 零改動）；
  整詞確認＝顯式選字→trail 失效。§10 待決觀察第 3、4 項由此定案。
- **D／G**：「&」cells 僅用於 LM 直接查詢、不進組字器（組字器桶形態／trail／候選窗
  過濾／tone-fuzzy 零改動）；copilot 窗「1 桶＋1 固定鍵」紀律維持。
- **補修（α 空格固化）**：α 時 pre-triage 固化因 `furiousFrontContext` nil 而 no-op、
  空格流入 `receiveKey(" ")`（中性聲調）→ `composer.clear()` 丟失前方整詞——新增
  `solidifyAbbreviatedFrontReading()`（取整詞候選之首實際讀音單鍵插入、不覆寫、trail
  失效）＋pre-triage 注拼槽殘留時直接消費空格；IH134 鎖定。
- 驗證：Typewriter 139/139、LangModelAssembly 132/132、MainAssembly 68/68、
  Legacy `make debug-core` ✅、兩倉 lint/format 冪等、鏡像逐字節一致。

### D.3 截至 P157 完工的待決事項（6 項）

**另立 Phase（有明確後續價值，維持）**

1. **T1：copilot 組句結果套用 POM 建議（實作）**——設計已定稿（需「唯讀 POM 查詢」：
   把 `fetchPOMSuggestion` 的提取與 `apply` 拆開），實作另立 Phase。
2. **R3（δ）：簡拼感知重切＋跨音節數重切合併**——`FuriousTypingSegmentor` 擴展為簡拼
   感知（`isValidSyllable` 接受前綴、以 α 的整詞查詢當評分器，`ysxb` 全程自動出整詞）；
   與跨音節數重切（M4 評估為不施工）同源可合併；可選併入 F（lazy 展開）、可能需
   Homa 重切 API。
3. **候選窗體驗強化餘項：替代切分 Top-N 入窗**——Shift 提示已落地（P151），僅餘此項。

**備考待決（暫不施工）**

4. **低優先 override＋trail 重切分時 reset trail span**——「空格固化後顯示與 copilot
   選讀一致」的釘選感 vs trail 重切自由度的取捨，維持備考。
5. **中段簡寫（游標非尖端時簡寫）**——獨立工程（牽動 copilot 上下文／trail／POM／游標
   規則）；原建議 R2 穩定後評估——R2 已完工，可重新評估。

**長遠評估（暫不排程）**

6. **方案 C（SunPinyin 式字母級 lattice）**——α 落地後價值再降，維持暫不排程。

**已解決（自待決清單移除）**：γ／α／B/C/E／A/D 全部落地；l10n 四語；整詞確認／空格
固化 trail 政策；`partialMatchEnabled` 與 α 的關係；user-phrase 簡拼策略；Shift 提示；
雙拼（永久不做）。
