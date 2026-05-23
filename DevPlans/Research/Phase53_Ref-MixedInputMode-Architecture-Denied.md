# Mixed Input Mode（混合輸入模式）— 關鍵邏輯與移植指南

## 核心概念：Delayed Evaluation（延遲辨識）

```
使用者按鍵 → 累積到 rawBuffer → 遇到「觸發鍵」→ 嘗試辨識為注音
                                                  ├─ 成功 → 查字典 → 送入組字器
                                                  └─ 失敗 → 當英文 commit
```

使用者不需要手動切換中英文模式，系統會在**按下聲調鍵或空白鍵時**自動判斷。

---

## 1. 兩層 Buffer 架構

| 層級 | 用途 | 範例 |
|------|------|------|
| **rawBuffer** (String) | 累積原始英文按鍵 | `"wu"` |
| **Assembler/Compositor** | IME 的組字引擎，管理已辨識的中文 | `「我」` |

顯示給使用者的是兩者串接：`「我」wu`

```
┌──────────────────────────────────────┐
│          使用者看到的輸入框            │
│                                      │
│   [已辨識的中文] + [rawBuffer 英文]    │
│   例: 「我的名字是」hello              │
│                                      │
└──────────────────────────────────────┘
```

---

## 2. 觸發辨識的時機（Trigger）

只有兩種 key 觸發注音辨識：

| 觸發鍵 | 對應聲調 | 大千鍵盤按鍵 |
|--------|---------|------------|
| 二聲 ˊ | 陽平 | `6` |
| 三聲 ˇ | 上聲 | `3` |
| 四聲 ˋ | 去聲 | `4` |
| 輕聲 ˙ | 輕聲 | `7` |
| 一聲（無調號）| 陰平 | `Space` |

其餘按鍵都只是累積到 rawBuffer。

---

## 3. 辨識流程（Validate）

```
步驟說明：

fullInput = rawBuffer + trigger
例: rawBuffer="wu" + trigger="3" → fullInput="wu3"

Step 1: 逐字餵入注音 Composer (大千鍵盤映射)
        w → ㄊ
        u → ㄧ
        3 → ˇ (三聲)

Step 2: 檢查是否為合法注音音節
        composer.isPronounceable → true (有聲母+韻母)
        composer.hasIntonation() → true (有聲調)

Step 3: 取得注音 reading
        composer.getComposition() → "ㄊㄧˇ"

Step 4: 用 reading 查字典
        assembler.insertKey("ㄊㄧˇ") → 體/提/題/替...

Step 5: 組字引擎用 Viterbi 演算法選最佳候選
        assemble() → 根據上下文選字

Step 6: (可選) 套用使用者選字記憶
        retrievePOMSuggestions(apply: true)
```

---

## 4. 辨識失敗的處理

```
情境 1: 英文單字 + 空白鍵
  rawBuffer="hello" + Space
  → validate("hello ") → 不是合法注音
  → commit "hello " 作為英文
  → 清空 rawBuffer → 使用者可立刻打注音

情境 2: 英文字母 + 聲調鍵
  rawBuffer="he" + "3"
  → validate("he3") → 不是合法注音
  → 將 "3" 加入 rawBuffer → rawBuffer="he3"
  → 使用者繼續打字（可能在打 "he3llo"）

情境 3: buffer 太長 (> 3 字元) + 空白鍵
  rawBuffer="hello" + Space
  → 直接跳過辨識（大千注音最多 3 鍵 + 1 聲調）
  → commit "hello " 作為英文
```

**關鍵設計**：空白鍵失敗時一定 commit 並清空，不卡住 buffer。

---

## 5. 大千鍵盤映射

### 允許進入 rawBuffer 的字元

```
字母:   a-z  (對應 26 個注音符號)
數字:   1, 2, 5, 8, 9, 0  (對應注音符號，3/4/6/7 是聲調)
特殊鍵: ;  →  ㄤ
        ,  →  ㄝ
        .  →  ㄡ
        /  →  ㄥ
        -  →  ㄦ
```

### 完整大千鍵盤對應表

```
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ 1 │ 2 │ 3 │ 4 │ 5 │ 6 │ 7 │ 8 │ 9 │ 0 │ - │   │
│ ㄅ│ ㄉ│ ˇ │ ˋ │ ㄓ│ ˊ │ ˙ │ ㄚ│ ㄞ│ ㄢ│ ㄦ│   │
├───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┤
│ Q │ W │ E │ R │ T │ Y │ U │ I │ O │ P │   │   │
│ ㄆ│ ㄊ│ ㄍ│ ㄐ│ ㄔ│ ㄗ│ ㄧ│ ㄛ│ ㄟ│ ㄣ│   │   │
├───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┤
│ A │ S │ D │ F │ G │ H │ J │ K │ L │ ; │   │
│ ㄇ│ ㄋ│ ㄎ│ ㄑ│ ㄕ│ ㄘ│ ㄨ│ ㄜ│ ㄠ│ ㄤ│   │
├───┼───┼───┼───┼───┼───┼───┼───┼───┤
│ Z │ X │ C │ V │ B │ N │ M │ , │ . │ / │
│ ㄈ│ ㄌ│ ㄏ│ ㄒ│ ㄖ│ ㄙ│ ㄩ│ ㄝ│ ㄡ│ ㄥ│
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
```

---

## 6. 各按鍵的處理策略

| 按鍵 | rawBuffer 空 | rawBuffer 有內容 |
|------|-------------|-----------------|
| **字母/數字/`;,./-`** | 加入 buffer | 加入 buffer |
| **聲調鍵 `3,4,6,7`** | pass through 給 IME | **觸發辨識** |
| **空白鍵** | pass through 給 IME | **觸發辨識**（失敗→commit 英文） |
| **Enter** | pass through 給 IME | commit 組字內容 + buffer |
| **Backspace** | pass through 給 IME | 刪 buffer 最後一字 |
| **Escape** | pass through 給 IME | 清空全部 |
| **方向鍵/Tab** | pass through 給 IME | 先 commit buffer 為英文，再 pass through |
| **其他鍵** | pass through 給 IME | 先 commit 全部，再 pass through |

---

## 7. 狀態流程圖

```
              ┌─────────┐
              │  Empty   │ ← 初始狀態
              └────┬─────┘
                   │ 按下字母/數字/特殊鍵
                   ▼
              ┌─────────┐
         ┌───▶│ Buffering│ ← rawBuffer 累積中
         │    └────┬─────┘
         │         │ 按下聲調鍵 / 空白鍵
         │         ▼
         │    ┌──────────┐
         │    │ Validate │ ← 嘗試注音辨識
         │    └──┬───┬───┘
         │       │   │
         │  成功  │   │ 失敗
         │       ▼   ▼
         │  ┌────────┐  ┌──────────────┐
         │  │Assemble│  │ 空白鍵: commit│
         │  │ (組字)  │  │ 英文+清空    │
         │  └───┬────┘  │              │
         │      │       │ 聲調鍵: 加入  │
         │      │       │ buffer 繼續   │
         │      │       └──────┬───────┘
         │      │              │
         └──────┴──────────────┘
                   │
         Enter/Escape/其他鍵
                   │
                   ▼
              ┌─────────┐
              │ Commit   │ → 送字到應用程式
              └─────────┘
```

---

## 8. 移植到其他 IME

### 可直接複用的核心邏輯（與 IME 無關）

```
- rawBuffer 管理 (累積、刪除、清空)
- 觸發/辨識流程 (trigger → validate → 分流)
- 按鍵分類策略 (上表)
- buffer 長度 > 3 跳過辨識的優化
- 空白鍵失敗 → commit 英文的設計
```

### 需要替換的 IME 介面

```
┌─────────────────────────────────────────────────┐
│              可移植的核心邏輯 (不變)               │
│                                                  │
│  rawBuffer 管理 → 觸發判斷 → 辨識分流 → 按鍵策略   │
│                                                  │
└──────────────────────┬──────────────────────────┘
                       │
          依賴以下 5 個可替換介面
                       │
   ┌───────────────────┼───────────────────┐
   ▼                   ▼                   ▼
┌────────┐      ┌───────────┐      ┌────────────┐
│Composer│      │ Assembler │      │ Language   │
│注音引擎 │      │ 組字引擎   │      │ Model 字典 │
│        │      │           │      │            │
│目前用:  │      │目前用:     │      │目前用:      │
│ Tekkon │      │ Megrez    │      │ vChewing   │
│        │      │ Compositor│      │ LM         │
└────────┘      └───────────┘      └────────────┘

   ┌───────────────────┐      ┌────────────────┐
   ▼                   │      ▼                │
┌────────────┐         │  ┌──────────────┐     │
│ State      │         │  │ Commit       │     │
│ 狀態機制    │         │  │ 送字方式      │     │
│            │         │  │              │     │
│目前用:      │         │  │目前用:        │     │
│ IMEState   │         │  │ switchState  │     │
│ .ofInputting│        │  │ .ofCommitting│     │
└────────────┘         │  └──────────────┘     │
                       │                       │
                       └───────────────────────┘
```

### 最小移植介面 (Protocol)

```swift
/// 任何 IME 實作此 protocol 即可套用混合輸入邏輯
protocol MixedInputIMEBridge {

    // MARK: - 注音驗證
    /// 驗證按鍵序列是否為合法注音
    /// - Parameter keys: 原始按鍵序列，如 "wu3"
    /// - Returns: (是否合法, 注音 reading 如 "ㄊㄧˇ")
    func validate(keys: String) -> (isValid: Bool, reading: String?)

    // MARK: - 組字引擎
    /// 將 reading 送入組字引擎查字典
    /// - Returns: 是否在字典中找到對應候選字
    func insertReading(_ reading: String) -> Bool

    /// 取得目前組字引擎的顯示文字（已辨識的中文）
    func assembledText() -> String

    /// 組字引擎是否有內容
    var hasAssembledContent: Bool { get }

    /// 清空組字引擎
    func clearAssembler()

    // MARK: - 輸出
    /// Commit 文字到應用程式
    func commit(text: String)

    /// 更新輸入框顯示
    /// - Parameters:
    ///   - segments: 顯示文字片段 [組字中文, rawBuffer英文]
    ///   - cursor: 游標位置
    func updateDisplay(segments: [String], cursor: Int)

    /// 設定為空白狀態
    func setEmpty()
}
```

---

## 9. 原始碼檔案對照

| 檔案 | 角色 | 行數 |
|------|------|------|
| `MixedInputHandler.swift` | rawBuffer 管理 + 注音驗證 | ~60 行 |
| `InputSession_HandleMixedInput.swift` | 按鍵事件處理 + 辨識流程 | ~210 行 |
| `InputSession.swift` | 模式開關 (static var 跨 session 持久) | 修改 ~13 行 |
| `InputSession_HandleEvent.swift` | Ctrl+Shift+M 熱鍵 toggle | 修改 ~23 行 |
| `InputHandler_CoreProtocol.swift` | `retrievePOMSuggestions` 改 public | 修改 1 行 |

**核心邏輯只有 ~270 行**，其中與 vChewing 耦合的部分主要在 Assembler 操作和 State 管理。

---

## 10. 已知限制與未來改進方向

- 目前僅支援**大千鍵盤**配列，許氏/倚天等需要調整 Composer 和 tone key 映射
- 選字記憶 (POM) 依賴 vChewing 的 `retrievePOMSuggestions`，其他 IME 需自行實作
- buffer 長度上限硬編碼為 3（大千注音最多 3 鍵 + 1 聲調 = 4），其他配列可能不同
