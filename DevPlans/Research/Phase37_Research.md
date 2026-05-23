# Phase 37 結案研究報告：拼音無調查詢、tone bucket、與 continuous stem auto-chop

> 結案日期：2026-04-22
> 研究範圍：`vChewing-macOS`、`vChewing-LibVanguard`、`vChewing-OSX-Legacy`
> 研究員：GPT-5.4
> 文檔狀態：結案重整版，已併入實作驗證與 profiling 補記

---

## 一、任務摘要

Phase 37 的原始需求有兩條：

1. 讓 `BPMFFullMatchTypewriter` 在拼音模式下允許「不輸入聲調也能查詞」，亦即對同 stem 的不同聲調結果做容忍。
2. 順勢改善拼音使用者體驗，允許 `shijiedazhan` 這類連續無調 stem 拼寫，不必強制依賴空白鍵作為 syllable delimiter。

本輪結案後，這兩條需求都已落地，但最終落地方案與最初的 generic partial-match 想像不同：實作驗證證明，tone-less pinyin 的正解不是把 trie prefix partial-match 直接打開，而是維持 full-match 主路徑，改由 Typewriter 端展開 tone bucket，並在 Tekkon 端補最小 exact-leading auto-chop API。

---

## 二、最終定案

1. **不採 generic trie partial-match 當作 tone-less pinyin 的主方案。** `shi` 這類同時是完整 syllable 與更長 syllable 前綴的鍵，若直接走 partial-match，會把 `ㄕㄨㄞ` 等較長讀音一起拉進來；實測曾出現 `shi jie ` 誤得 `衰竭` 的 overmatch。
2. **保留 `BPMFFullMatchTypewriter` 的局部責任面。** Phase 37 不把 lookup policy 上推成 Tekkon / LM / Homa 的新共用抽象，也不把 `partialMatchEnabled` 當成 sticky runtime toggle 來回改寫。
3. **拼音無調查詢改走 tone bucket。** 當條件為「拼音模式 + 本次為確認組字 + confirm 前尚無顯式聲調」時，單一 syllable query 會展開成同 syllable 的 tone bucket，例如 `ㄕ&ㄕˊ&ㄕˇ&ㄕˋ&ㄕ˙`，再由 `LMInstantiator.unigramsFor(keyArray:)` 在 full-match 路徑展開 `&` alternatives。
4. **連續無調拼音以 exact-leading auto-chop 承接。** Tekkon `Composer` 只提供「leading exact syllables + array-last remainder」的狹窄 API；Typewriter 把前段完整 syllables 轉成 tone buckets 推進 assembler，尾段 remainder 留在 romaji buffer。
5. **未來若要做 generic chopped / fuzzy pinyin，另立獨立 phase 與專責 `BPMFPartialMatchTypewriter`。** Phase 37 不提早把未來 partial typewriter 的責任污染回 full-match typewriter。

---

## 三、為何 generic partial-match 不成立

Phase 36 之後，下游其實已具備 partial-match 能力：`LMInstantiator.Config.partialMatchEnabled`、`VanguardTrie.TextMapTrie.getNodes(...)`、以及 Homa 對 partial queried grams 的吸收能力都已存在。但這一條能力不能直接拿來當 Phase 37 答案，原因有三個：

1. **需求要的是「同 syllable、不同聲調」，不是「所有 prefix 命中」。** `shi` 的需求範圍是 `ㄕ / ㄕˊ / ㄕˇ / ㄕˋ / ㄕ˙`，不是 `ㄕㄨㄞ` 這類更長 syllable。
2. **拼音顯式聲調不應被放寬。** 使用者若已輸入 `bo4`，就應維持 full-match，而不應回頭把 `bo2`、`bo3` 等 peer 一起攤開。
3. **`partialMatchEnabled` 是 runtime config，不是單次查詢 flag。** 這個開關若被拿來做 event-by-event 切換，很容易變成 sticky state 問題，讓後續事件沿用錯誤 lookup mode。

因此，Phase 37 的關鍵不是「把 partial-match 打開」，而是「讓 full-match typewriter 在適當時機把 tone-less query 改寫成同 syllable 的 tone bucket」。

---

## 四、落地設計

### 4.1 Typewriter：維持 full-match routing，改做 tone bucket query

`BPMFFullMatchTypewriter` 新增局部 helper，負責三件事：

1. 判斷本次是否屬於「拼音模式 + confirm 組字 + 尚無顯式聲調」的 tone-insensitive lookup。
2. 把單一拼音 syllable 轉成 tone bucket query key。
3. 在 consume / compose 階段決定是否先做 pinyin auto-chop，再把已完成部分送進 assembler。

這讓查詢 policy 仍然留在 `BPMFFullMatchTypewriter`，不必把 Tekkon 或 LM surface 擴成新的共用 enum / strategy tree。

### 4.2 LMAssembly：只補最小共用能力，不回頭打開 generic partial-match

`LMInstantiator.unigramsFor(keyArray:)` 新增 `&` alternative key 展開支援，讓 full-match 路徑可以安全接受「單一位置多個 tone variants」這種 query 形狀。這是 Phase 37 真正需要的最小 LM 擴充；它不等於回到 Phase 36 的 generic partial-match runtime toggle。

### 4.3 Tekkon：只暴露 exact-leading auto-chop 形狀

Tekkon `Composer` 新增：

1. `PinyinAutoChopResult`
2. `pinyinAutoChopResult(appending:)`
3. `replacePinyinBuffer(with:)`

這個 API 故意限制成「前段完整 syllables + 尾段 remainder」，不直接暴露 fuzzy / partial policy。Typewriter 拿到結果後，只把前段 exact syllables 轉成 tone buckets 插入 assembler，餘下的 array last 留給 composer 繼續接受輸入。

### 4.4 Legacy transplant：只做對位鏡像，不另創分支設計

`vChewing-OSX-Legacy` 已同步移植：

1. Tekkon 的 `PinyinAutoChopResult` 與 buffer replacement API。
2. `BPMFFullMatchTypewriter` 的 tone bucket query helper 與 auto-chop routing。
3. `LMInstantiator` 的 `&` alternative key 展開支援。

因此 current tree 與 legacy tree 在 Phase 37 的設計語義上已重新對齊。

---

## 五、驗證結果

本輪結案時的 focused validation 如下：

1. `Packages/vChewing_Typewriter`
  - `test_IH110_IntonationKeyBehavior`
  - `test_IH114_PinyinTonelessQueryUsesStemPartialMatch`
  - `test_IH115_PinyinExplicitToneKeepsFullMatch`
  - `test_IH116_PinyinTonelessQueryDoesNotMatchLongerSyllableStem`
  - `test_IH117_PinyinContinuousStemAutoChopsLeadingReadings`
  - 結果：5/5 通過。
2. `Packages/vChewing_Tekkon`
  - `testPinyinAutoChopResult`
  - 結果：1/1 通過。
3. `vChewing-macOS`
  - `vChewingDebuggable` target build
  - button-driven profiling harness（SHI control case / YI hotspot case）
  - 結果：profiling 入口已自臨時測試檔移至 app-side target。
4. `vChewing-LibVanguard`
  - `testPinyinAutoChopResult`
  - 結果：1/1 通過。
5. `vChewing-OSX-Legacy`
  - `make debug-core`
  - 結果：BUILD SUCCEEDED。

功能面結論為：

1. 拼音無調查詢已可用。
2. 顯式拼音聲調仍維持 full-match。
3. `shi` 類 bare stem 不再誤吸 `shuai` 類更長 syllable。
4. 連續無調拼音已可在失配當拍自動 chop 並前推 leading syllables。

---

## 六、MainAssembly CPU Trace 補記

在功能落地之後，本輪又對 `vChewing-macOS/tmp/TestResult.trace` 與其匯出的 `vChewing-macOS/tmp/TestResult_AfterPhase37_cpu_profile.xml` 做了補充剖析。結論不是「只有一個單點瓶頸」，而是至少存在三個 CPU 高佔用區段，而且大戶不同。

| 區段 | 代表時間 | 代表 heavy hitters | 目前判讀 |
|------|----------|--------------------|----------|
| 前段 | 約 `00:01.65` 到 `00:01.70` | `Notifier.init(_:)`、`NSVisualEffectView viewDidMoveToWindow`、`CA::Context::connect_remote`、`NSCGSWindow` / backdrop / layer 建立 | 這一段主要是 profiling harness 啟動時的視窗、視覺效果層、notifier 與 CoreAnimation 連線暖機，不屬於 tone bucket lookup 本體。 |
| 中段 | 約 `00:02.42` 到 `00:03.64` | `LMAssembly.LMInstantiator.unigramsFor(keyArray:)`、`factoryUnigramsFor(...)`、`factoryTrie.getter`、`VanguardTrie.TextMapTrie.getNodes(...)`、`PhonabetCipher.convertPhonabetToASCII(_)`、`TrieStringPool.internKey(_)`、`TrieStringOperationCache.getCachedFirstChar(_)`、`QueryBuffer.CacheEntry` copying、`LMPlainBopomofo.valuesFor(key:isCHS:)`、`LookupHub.grams(for:)` | 這一段才是目前最像「實際查詞熱路徑」的區段。除了 trie descent 以外，還明顯夾帶大量字串切片、grapheme traversal、hashing、substring compare、以及 cache entry 建立與複製成本。 |
| 後段 | 約 `00:03.74` 到 `00:04.79` | `Notifier.performDisplayLifetime()`、`NSWindow setFrame:display:animate:`、`CGImageGetColorSpace`、`CA::Context::commit_transaction(...)`、`LMMgr.resetAfterUnitTests()`、`LMPlainBopomofo.init()`、`LMInstantiator.resetSharedResources(...)`、`_free` / dealloc 相關 frame | 這一段是 UI 顯示、CoreAnimation commit、display link、測試 teardown、shared resource reset、以及物件釋放混在一起的尾段成本；同樣不能視為單一 lookup bug。 |

### 6.1 中段熱區的具體含義

目前最值得關注的是中段。從 project-bearing frames 看，熱點至少同時包含：

1. factory trie 節點查詢與 key path 前進。
2. `PhonabetCipher` 的鍵轉換。
3. `TrieStringPool` / `TrieStringOperationCache` 的快取命中與建檔行為。
4. `QueryBuffer.CacheEntry` 複製與短生命週期暫存物件成本。
5. `String.Iterator.next()`、`_StringGuts._opaqueComplexCharacterStride(startingAt:)`、`Substring.index(_:offsetBy:)`、`Hasher._finalize()` 等字串與 hashing primitive。

換言之，這裡不是單純的「TextMapTrie 慢」，而是查詞路徑與字串正規化 / 切片 / 快取週轉的混合成本。

### 6.2 對 Phase 37 的邊界判斷

這次 trace 補記有兩個重要結論：

1. **不能把 MainAssembly profiling 看到的 CPU 問題全數歸咎於 Phase 37 新功能。** 前段與後段明確含有 UI 建立、notifier 顯示生命週期、CoreAnimation commit、與測試 reset / teardown 成本。
2. **也不能假裝中段沒有真實的 lookup hot path。** `unigramsFor(...)`、`TextMapTrie.getNodes(...)`、`PhonabetCipher.convertPhonabetToASCII(_)`、`TrieStringPool.internKey(_)` 等符號已足以證明：查詞路徑本身確實仍有明顯優化空間。

因此，效能議題雖然已經被定位出主要戰場，但它的責任面超出 Phase 37 的功能手術範圍。

---

## 七、結論與後續建議

Phase 37 的功能目標已可結案：

1. tone-less pinyin 不再依賴 generic partial-match，而是以 tone bucket 形式安全落地。
2. continuous no-tone pinyin 已可透過 exact-leading auto-chop 前推已完成 syllables。
3. `vChewing-macOS`、`vChewing-LibVanguard`、`vChewing-OSX-Legacy` 三邊都已完成對位。

但 profiling 補記也說明：MainAssembly CPU 問題已不是單一補丁可以解決的局部缺陷。至少 lookup string path、notifier / visual effect UI path、以及 teardown / reset path 三條都值得獨立處理。**因此，效能議題應另立後續 phase 處理，不宜繼續塞進 Phase 37。**
