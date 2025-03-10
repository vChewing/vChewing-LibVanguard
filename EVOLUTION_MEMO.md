# 研發備忘錄

本文記錄了先鋒引擎諸模組的開發備忘錄，供開發者自行備忘使用。

## TrieKit

字典樹（Trie）類型模組，負責支援對每個讀音的首字元檢索匹配。

> [!NOTE]
> 注意：為了簡化實作，這個模組不計畫對 Regex Fuzzy Match 提供直接支援。
> 
> 對於智能狂拼、搜狗拼音、RIME等狂拼流拼音輸入法的情形而言，這種基於一串不完全讀音的原始讀音雜串（reading complex）需要使用 Tekkon Next 聲韻並擊引擎的 `chop()` 函式事先拆解。
> - 比如注音： `"ㄅㄩㄝㄓㄨㄑㄕㄢㄌㄧㄌㄧㄤ"` 就可以這樣拆解成 `"ㄅ", "ㄩㄝ", "ㄓㄨ", "ㄑ", "ㄕㄢ", "ㄌㄧ", "ㄌㄧㄤ"`，然後 TrieKit 在檢索的時候就可以據此檢索到 `ㄅㄚ ㄩㄝˋ ㄓㄨㄥ ㄑㄧㄡ ㄕㄢ ㄌㄧㄣˊ ㄌㄧㄤˊ`。
> - 拼音的話： `"byuezhqshll"` 就可以這樣拆解成 `"b", "yue", "zh", "q", "sh", "l", "l"`，然後 TrieKit 在檢索的時候就可以據此檢索到 `ba1 yue4 zhong1 qiu1 shan1 lin2 liang2`。

## Homa

護摩組字引擎，是天權星組字引擎（Megrez）的繼任者、擁有下述新特性：

1. 支援 Bigram，且每個 Gram 承載其真實讀音。由於 Bigram 的統計資料大多只有書面用語統計資料，所以對 Bigram 的描述方式僅限於某個 previous node 是怎樣的字詞、而不糾結這個 previous node 讀音。
2. 取消了對於語料來源模組的 LangModelProtocol 協定規束。
3. 為了對接那些有支援「部分匹配（partial matching）」的語料來源模組，護摩引擎對「使用者鍵入的讀音串」與「經過組句之後的真實讀音串」做了分開處理。

## TekkonNext

鐵恨注拼引擎的 Swift Concurrency 相容版，多了一些 API 用以滿足先鋒引擎的內部需求。

> [!NOTE]
> Tekkon Next 內建了一套 PinyinTrie，是 TrieKit 的 VanguardTrie 的簡化版。因為兩者彼此分化過度、且各自的 API 設計有差異，所以用 Generics 讓兩者使用同一個抽象基底 Class 的價值並不大。

## BrailleSputnik

盲文點字支援模組。

$ EOF.
