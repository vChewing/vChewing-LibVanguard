> 本文只是出於好奇目的的研究，研究目的是想論證自然輸入法是否真的聰明。

# 研究任務

## 研究背景

姜天戩（barabbas）給 OpenVanilla 曾經製作過一套「菸草注音引擎（OVIMTobacco）」。這套引擎被自然輸入法採用之後，其 FOSS 分支終止了維護。OpenVanilla 後來另立了其他注音輸入法專案。

現有的很多 bigram trigram 輸入法似乎都是在文字書寫方向上「向後方採樣 (backward sampling)」。
這似乎很難解決「再」「在」的自動選字問題，因為這兩個同音字的 ngram 採樣反而需要「向前方採樣 (forward sampling)」。

這次的研究就是想順便知道姜天戩是否有嘗試解決這個問題。但主要研究的內容還有其他。

## 要研究搞清楚的事項

- 姜天戩用的組句算法是什麼。
- 姜天戩的組句引擎在原廠詞彙上用的是 bigram 語料還是 unigram 語料。
- 姜天戩是怎麼解決使用者打字習慣記憶的問題的。如果有用到 multi-gram 的話，搞清楚是 forward sampling 還是 backward sampling 還是 both。

-------------------

## 研究結果

### 0. Tobacco 引擎的版本演進

Tobacco 組句引擎經歷了三個主要階段（從舊到新）：

| 階段 | 目錄 | 算法 | 語料 | 方向 |
|------|------|------|------|------|
| **第一代** | `TobaccoOld/` (commit `cf9a2564^`) | Greedy Maximum Matching | tsi.src 原始頻率（additive freq） | **Forward + Backward** 雙向競標 |
| **第二代** | `TobaccoOld/` (commit `cf9a2564`) | Greedy Maximum Matching | 同上 | **Backward only**（forward 被註解停用） |
| **第三代** | `Experiments/Tobacco/` (commit `c7416538` 以後) | Viterbi 動態規劃 | SRILM unigram logProb | 6-char 視窗內全域最優（雙向隱含） |

> 說明：第一、二代程式碼在 `TobaccoOld/` 目錄，第三代在 `Experiments/Tobacco/`。Git 中 `TobaccoOld/` 已被清空，須 checkout 早期 commit 才能看到。關鍵 commit：`cf9a2564`（停用 forward matching）、`c7416538`（遷移到 SRILM Viterbi）。

---

### 1. 組句算法

#### 1a. 第一代：Greedy Maximum Matching（Forward + Backward 雙向競標）

**檔案：** `TobaccoOld/BiGram.cpp`（commit `cf9a2564^`）

核心方法 `BiGram::maximumMatching(dictionary, tokenVectorRef, index, stop, doBackward)`：

```
1. 若 doBackward=true → 先 reverse token 序列，再從右到左處理
   若 doBackward=false → 從左到右直接處理
2. Greedy 最長匹配：由當前位置向後（按處理方向）延伸，每次嘗試合併更多音節
   直到在字典中找到匹配的詞彙組合
3. 對找到的所有候選詞，取 frequency 相加起來作為組合分數：
   combinedVocabulary.freq = leftFreq + rightFreq （純加法）
4. 返回最高分數的詞組
```

**雙向競標機制（`PredictorSingleton::setTokenVectorByBigram()`）：**
```cpp
// 在同一段 token 上分別執行 forward 和 backward matching
vector<Token> forwardTokenVector(PredictorSingleton::tokenVector); // clone 一份
int backwardScore = biGram.maximumMatching(..., begin, end, true);   // backward
int forwardScore  = biGram.maximumMatching(..., forwardTokenVector, begin, end, false); // forward

// 取分數高者
if(forwardScore > backwardScore)
    PredictorSingleton::tokenVector = forwardTokenVector;
else
    forwardTokenVector.clear();
```

**本質：** 這並非真正的 "both sampling"，而是**分別獨立執行兩次 greedy matching（一次 forward、一次 backward），然後用 additive frequency 比大小，選贏的那組結果**。兩次匹配之間沒有交互影響，只是單純的「雙向競標」。

#### 1b. 第二代：Backward-only Maximum Matching

Commit `cf9a2564`（2007-02-15）：`"Disables 'forward' maximum matching of Tobacco. Uses 'backward' only."`

Forward matching 被註解掉，只留 backward：
```cpp
//vector<Token> forwardTokenVector(PredictorSingleton::tokenVector);
int backwardScore = biGram.maximumMatching(..., begin, end, true);
/*
int forwardScore = biGram.maximumMatching(..., forwardTokenVector, begin, end, false);
if(forwardScore > backwardScore)
    PredictorSingleton::tokenVector = forwardTokenVector;
*/
```

#### 1c. 第三代：Viterbi Unigram 解碼

Commit `c7416538`（2007-09-18）：`"Migrates Tobacco from Chewing's tsi.src to SRILM-generated language model."`

演算法改為 `BiGram::viterbi()`（在 `Experiments/Tobacco/BiGram.cpp`），使用動態規劃在 6 字視窗內找全域最優斷詞。評分從 additive frequency 改為 unigram logProb。Bigram backoff 框架存在但未真正啟用（leftGram 的 logProb 和 rightGram 的 backOff 均被註解）。

第一、二代的最大匹配程式碼被保留在 `#if 0` 區塊中（即現行 `Experiments/Tobacco/BiGram.cpp` 中的 `maximumMatching()` 和 `getVocabularyCombination()`），作為歷史參考。

#### 1d. Greedy Matching vs Viterbi DP：為什麼要換算法

前兩代的 `maximumMatching` 本質上是 **greedy longest-match-first with backoff**，完全不涉及 DAG-DP（有向無環圖 + 動態規劃）。其邏輯：

```
while (當前位置 < 終點) {
    1. 從當前位置往後延伸，嘗試最長匹配（合併所有音節 → 查字典）
    2. 找到了 → commit segment boundary，指針跳到該段之後，繼續
    3. 沒找到 → 縮短一個音節重試（backoff）
    4. 縮到只剩一個音節仍找不到 → 失敗
}
```

**致命缺陷：segment boundary 一旦 commit 就不再回溯。** 這導致 greedy matching 無法比較不同分割方案。舉例：

```
輸入: ㄒㄧㄢˋ-ㄗㄞˋ-ㄕˋ

Greedy forward:
  嘗試合併 3 個音節 → 查無 "現在是"
  嘗試合併 2 個音節 → 找到 "現在" ✅ → commit boundary
  指針移到 position 2，只剩 "是"
  → 結果: 現在/是

Viterbi DP:
  方案 A: 現在(2) + 是(1) → logProb(現在) + logProb(是)
  方案 B: 現(1) + 在(1) + 是(1) → logProb(現) + logProb(在) + logProb(是)
  → 選分數高的（可能是方案 B）
```

第一代的「雙向競標」並不能解決這個問題——它只是從兩個 greedy 結果中選一個，不是從所有可能分割方案中選最優。

**關於效能：** 這裡的「效能」需要區分兩種含義。

- **速度效能：** greedy matching 本身 O(n × w) 是很快的。commit history 中記錄的效能問題都不是算法瓶頸，而是工程問題：

  | Commit | 實際原因 |
  |--------|----------|
  | `8a6ccde3` | `#define OV_DEBUG` 導致 `murmur()` 每次寫 file I/O，**"slows down significantly"** |
  | `7843fcd0` | `vector::insert` 在中間插入為 O(n) shift，改用 `push_back` |
  | `76afe079` | 未 `reserve()` 導致 vector 反覆 reallocate |
  | `be9bbc56` | 在 C++ 端用 `std::sort` 而非 SQL `ORDER BY`，無法利用 DB index |

- **準確度效能：** 這才是 greedy matching 的真正瓶頸。由於無法比較不同分割方案，斷詞品質有根本性天花板。commit history 中從 `c7416538` 起大量出現 "improves accuracy" 的 commit，最終第三代達到約 91.5% accuracy（commit `1bcdfbb6`）。這是在改用 Viterbi DP 之後才實現的。

---

### 2. 語料類型

#### 第一、二代：tsi.src 原始頻率

- 資料來源：Chewing（新酷音）的 `tsi.src` 詞頻表
- 評分方式：`combinedVocabulary.freq = leftFreq + rightFreq` —— 簡單的頻率相加
- 本質上仍是 unigram 頻率的加法組合，沒有條件機率
- 使用門檻過濾：freq < 100 的候選會被捨棄（僅針對單字詞）

#### 第三代：SRILM Unigram logProb

- Commit `c7416538` 將語料從 tsi.src 遷移到 SRILM 產生的語言模型
- Schema 中儲存 `logProb`（unigram log probability）和 `backOff`（預留給 bigram backoff）
- 實際評分僅使用 unigram `logProb`，bigram backoff 未啟用（見上文）

**結論：** 三代 Tobacco 全部使用的是 **unigram 語料**。即使在第三代 schema 中有 backOff 欄位預留 bigram 擴展，從未真正實現 bigram 條件機率的計算。

---

### 3. 使用者打字習慣記憶

三代 Tobacco 均**未實際實作**使用者學習功能：

- **第一、二代（TobaccoOld）：** 完全沒有任何學習/記憶的程式碼。`Profile`、`Cache`、`ProfileManager` 等類別均不存在。
- **第三代（Tobacco）：** 設計了完整的學習架構（`ProfileManager` → `Cache` → `ProfileFetcher`），但 `ProfileFetcher::fetch()` 是 stub（永遠回傳 0），`ProfileManager::writeBack()` 是空的。學習功能從未上線。

> commit `2df11a56`（"Begins refactoring Tobacco APIs to add learning mechanism"）和 `95166c9d`（"Adds cache-management codes... but not used yet"）證實這是在第三代才開始設計的架構，但未完成。

---

### 4. 關於 forward/backward sampling 與「再/在」問題

| 階段 | Forward sampling? | Backward sampling? | 能否處理「再/在」? |
|------|:---:|:---:|------|
| **第一代** | ✅ 有（獨立 greedy matching） | ✅ 有（獨立 greedy matching） | ❌ 不能。只是雙向各自 greedy match 後選分數高的，沒有真正的 conditional context |
| **第二代** | ❌ 停用 | ✅ 有 | ❌ 更不能 |
| **第三代** | Viterbi 隱含（視窗內全域） | Viterbi 隱含（視窗內全域） | ⚠️ 有限。只能在「再/在」與前後字構成已知多字詞（如「現在」「再見」）時透過 unigram 詞頻區分 |

**關鍵分析：**

第一代的 "forward + backward" 不應被理解為 modern NLP 意義上的 forward/backward sampling（即用前文或後文來計算條件機率 P(w|context)）。它只是：
1. 把同一個 token 序列分別從左到右和從右到左各做一次 greedy maximum matching
2. 把兩個結果的 additive frequency 拿來比大小
3. 選贏的那組

這對「再/在」問題幫助極其有限，因為：
- 「再」和「在」是單音節同音字，在 greedy matching 階段就會被分別匹配為獨立的單字 token
- Forward 和 backward matching 的差別只在於合併相鄰音節的優先順序（先看左邊還是右邊），不涉及「根據前後文選擇同音字」的 conditional probability
- 唯一的影響是：forward matching 傾向把字和右邊的字合併成詞（有利於識別「再見」），backward matching 傾向把字和左邊的字合併成詞（有利於識別「現在」）。雙向競標後，如果某一方向的合併分數較高，會影響斷詞邊界，但**不會直接影響同音字的選擇本身**。

**結論：** 姜天戩**探索過**雙向處理（第一代），但這只是雙向 greedy matching 的競標機制，並非真正意義上的 forward sampling。Commit `cf9a2564` 顯示他最終認為 backward matching 單獨使用效果更好（或至少不差），因此停用了 forward 方向。這說明他**嘗試過但未解決**「再/在」這類單向依賴問題。第三代的 Viterbi 算法在這個問題上的表現和第一代本質相似 —— 僅靠 unigram 無法區分同音字。

---

## 總結

| 研究項目 | 第一代 (TobaccoOld, 早期) | 第二代 (TobaccoOld, 後期) | 第三代 (Tobacco, 最終版) |
|----------|------|------|------|
| **組句算法** | Greedy Maximum Matching | Greedy Maximum Matching | Viterbi 動態規劃 |
| **DAG-DP** | ❌ 無（greedy，不回溯） | ❌ 無（greedy，不回溯） | ✅ Viterbi DP（6-char 視窗內全域最優） |
| **語料類型** | tsi.src unigram frequency（加法） | 同上 | SRILM unigram logProb |
| **採樣方向** | Forward + Backward 雙向競標 | Backward only | Viterbi 6-char 雙向隱含（但僅 unigram） |
| **使用者記憶** | ❌ 無 | ❌ 無 | ⚠️ 架構已設計，未實作完成 |
| **「再/在」問題** | 無法解決（雙向競標不涉及 conditional prob） | 更無法解決 | 無法解決（unigram 無前後文條件機率） |
