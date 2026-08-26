# 問訊內容

純諮詢，與 vChewing-macOS 有關。

macOS 的 activity monitor 裡面的「記憶體」與「專用記憶體」有什麼區別？

如果一個 app 希望測試自身的 ram 佔用與 real memory size 的話，用以測量兩者的 API 是什麼？

Swift 如果出現 cycled reference 或 SQLite API leak （比如 statement ptr 用完沒有finalize）等情況的話，會影響到 專用記憶體 嗎？

於是輸入法以「應對自身可能的記憶體洩漏狀況」之目的用來監測自身記憶體佔用的指標 僅使用「專用記憶體」就行了？phys_footprint 可能不準確。vChewing 目前在 apple silicon 的電腦上的記憶體佔用量是 intel mac 的兩倍。很奇怪。這個 2x 差異僅在 macOS 26 & 27 系統下存在。macOS 26 早期版本如果用 info plist 相容參數讓輸入法停用 Liquid Glass 的話，則沒有這個差異。但 macOS 26.4 開始不能用這種方法節省記憶體了（雖然 Liquid Glass 還是會因此停用），佔用量還是會有 2x 差異。// macOS 27 無法用這招停用 liquid glass，因為相關 info plist property 會被系統故意無視。）

# 調查結果（KIMI-K2.7）

下面以 vChewing-macOS 的語境為主，分四點回答。

## 1) Activity Monitor 的「記憶體」與「專用記憶體」差別

先釐清欄位名稱。Activity Monitor 預設的「記憶體」欄位對應的是 kernel ledger `physmem.phys_footprint`：

- **記憶體（Memory）＝ `phys_footprint`**
  蘋果用來代表「這個 process 對系統記憶體的總衝擊」。它包含：
  - 你的 heap / stack / malloc（`internal`）
  - 被壓縮或 swap 出去的匿名記憶體
  - IOKit 幫你映射的記憶體
  - page table、non-volatile purgeable 記憶體
  - 近年還包含 `graphics_footprint`、`neural_footprint` 等分類
  Xcode 的 Memory 曲線、`footprint` 指令顯示的也是這個值。

- **專用真實記憶體（Real Private Memory，RPRVT）**
  只算「**只屬於這個 process、且真的在實體 RAM 裡**」的頁面。
  它**不包含**被多個 process 共享的 dyld shared cache、`__TEXT`、shared mmap 等。
  換句話說，這個數字比較接近「你自己這支程式實際獨佔的 RAM」。

簡單講：`記憶體` 是蘋果定義的「總帳單」，會被系統框架、GPU/WindowServer 共享記憶體、壓縮/swapped 記憶體影響；`專用記憶體` 才是你這支程式真正獨佔的實體 RAM。

---

## 2) 測量 RAM 佔用與 real memory size 的 API

vChewing 現在的實作在：

vChewing-macOS/Packages/vChewing_OSFrameworkImpl/Sources/OSFrameworkImpl/AppKitImpl/AppKitImpl_Misc.swift

那邊用的是 `task_info(mach_task_self_, TASK_VM_INFO, ...)` 取 `phys_footprint`。
同一個 struct 裡還可以同時拿到其他值：

```swift
import Darwin

struct MemoryMetrics {
  let footprint: UInt64      // Activity Monitor「記憶體」
  let resident: UInt64       // Activity Monitor「真實記憶體」
  let `internal`: UInt64     // 匿名私有記憶體（heap / stack / SQLite 等）
  let compressed: UInt64     // 被壓縮的 internal
}

func currentMemoryMetrics() -> MemoryMetrics? {
  let count = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
  )
  let rev1Count = mach_msg_type_number_t(
    MemoryLayout.offset(of: \task_vm_info_data_t.min_address)! / MemoryLayout<integer_t>.size
  )
  var info = task_vm_info_data_t()
  var size = count
  let kr = withUnsafeMutablePointer(to: &info) { ptr in
    ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &size)
    }
  }
  guard kr == KERN_SUCCESS, size >= rev1Count else { return nil }
  return MemoryMetrics(
    footprint: info.phys_footprint,
    resident: info.resident_size,
    internal: info.internal,
    compressed: info.compressed
  )
}
```

也可以用 `proc_pid_rusage()` 取得 `ri_resident_size` 與 `ri_phys_footprint`，以及 peak 值：

```swift
func rusageMemory() -> (resident: UInt64, footprint: UInt64, peak: UInt64)? {
  var rusage = rusage_info_v6()
  let kr = proc_pid_rusage(getpid(), RUSAGE_INFO_V6, rusage_info_t(&rusage))
  guard kr == KERN_SUCCESS else { return nil }
  return (
    rusage.ri_resident_size,
    rusage.ri_phys_footprint,
    rusage.ri_lifetime_max_phys_footprint
  )
}
```

至於 Activity Monitor 上那個精確的 **Real Private Memory**，public API 並沒有直接對應欄位；它來自 kernel ledger `tkm_private`，Activity Monitor 是透過 `sysmond` 拿取。程式裡最接近的代理值是 `task_vm_info.internal + compressed`，也就是「匿名私有記憶體」。

---

## 3) Swift cycle reference / SQLite statement leak 會影響專用記憶體嗎？

**會。**

- Swift 的 retain cycle 會讓 heap 上的物件無法釋放，這些都屬於 `internal`（匿名私有記憶體）。只要它們還 resident，就會同時增加：
  - `resident_size`
  - `internal`
  - `phys_footprint`
  - 專用記憶體（因為 heap 不會被共享）

- SQLite 的 `sqlite3_stmt*` 沒有 `sqlite3_finalize()`、資料庫連線沒關閉，也會把相關頁面留在自己 process 的 heap / SQLite private cache 裡，同樣是私有記憶體。

所以如果你的專用記憶體（或 `internal`）持續穩定成長，那就是真的在漏；如果只是 `phys_footprint` 在漲、`internal` 沒動，那通常不是 heap/SQLite leak。

---

## 4) 用「專用記憶體」監測 leak 就夠了嗎？以及 Apple Silicon 2x 現象

**結論：對 vChewing 來說，拿 `internal` / `resident_size` 當 leak 監測指標，比 `phys_footprint` 更穩定、更不容易被 Liquid Glass 騙。**

你提到的現象幾乎可以這樣解釋：

- `phys_footprint` 在 macOS 26/27 會把 **Liquid Glass / WindowServer / GPU 共享表面** 等系統渲染開銷算進去。
- Apple Silicon 是 unified memory，GPU/ANE/WindowServer 用的緩衝都從同一池記憶體分配，所以在 Activity Monitor 的 `記憶體` 欄位會顯得比 Intel 大很多。
- 這些開銷很多是 **shared / IOKit-mapped / graphics footprint**，不屬於你的 heap，所以不會反應在 `專用記憶體` 或 `internal` 上。
- macOS 26 早期用 plist 關掉 Liquid Glass 後差異消失，直接證明那 2x 是 Liquid Glass 相關開銷；26.4 後即使 UI 玻璃效果被關閉，底層 runtime/accounting 仍把這些成本算進來，macOS 27 更直接忽略該 plist。

vChewing 是 input method，會被載入到每個 host app 的 process 裡。Host app 的視窗渲染行為也會影響 vChewing「看到」的 `phys_footprint`，因此用 `phys_footprint` 做 1536 MB 自殺閥值，在 Apple Silicon + macOS 26/27 下會過度敏感。

建議的調整方向（不改變現有介面，只加指標）：

1. **監測 `internal` 或 `resident_size` 的成長趨勢**，而非只看 `phys_footprint` 絕對值。
   - 若 `internal` 長時間線性上升 → 真的有 leak（Swift cycle / SQLite / 大型 cache 沒清）。
   - 若只有 `phys_footprint` 飆高、`internal` 平穩 → 是系統/Liquid Glass 開銷，不該觸發自殺。

2. **保留 `phys_footprint` 作為輔助**，例如用來偵測「被 swap/compress 撐大的異常 footprint」，但主要閥值放在 `internal + compressed` 或 `resident_size`。

3. 繼續在取樣前呼叫 `malloc_zone_pressure_relief(nil, 0)`，避免 allocator 保留空閒頁面造成假性高 RSS。

4. 如果要做自動重啟，可以設成「連續多次取樣，且 `internal` 都超過某個平台相對穩定的閾值」，而不是單一 `phys_footprint` 瞬間爆高就重啟。

簡單說：`phys_footprint` 對終端使用者看 Activity Monitor 有意義，但對輸入法自我診斷 leak 來說，**專用 / 匿名記憶體（`internal`）才是對的指標**。
