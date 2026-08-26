# Phase 112 後續調研：InputSession 快取 Client 唯一性識別

> 日期：2026-07-24。本文為 Phase 112 後續對 CpLk toggle 場景下 InputSession 快取命中率改善的調研記錄。本次嘗試最終回滾，留作記錄供日後參考。

---

## 一、背景

Phase 112 完成後，`sessionsByClient` 快取以 client proxy 的記憶體位址（`UInt(bitPattern: Unmanaged.passUnretained(clientObj).toOpaque())`）為鍵。逆向 IMK 10.9/10.15 的 `activateServer:` 與 `_clientForController:` 實作確認：

- IMKServer 的 `_controllers` dictionary 以 `[NSNumber numberWithUnsignedLong:proxyAddr]` 為鍵
- 每次 CpLk toggle 時，IMKServer 建立的 DO/XPC proxy 物件**記憶體位址均不同**
- 故舊 controller 永遠無法被查詢命中，`sessionFinished:` 也永遠不會為舊 proxy 觸發
- 對應地，`sessionsByClient` 快取在每次 CpLk toggle 時**命中率為零**

Phase 112「七、後續修正」的 orphan controller 主動掃除機制解決了 controller 端的記憶體洩漏，但 InputSession 端的快取仍舊每次 toggle 都新建。

---

## 二、方案：以 `processIdentifier` 作為快取鍵

### 2.1 思路

`NSXPCConnection.processIdentifier`（PID）在同一 process 生命週期內為定值。若以 PID 為鍵，CpLk toggle 後快取可命中。

### 2.2 跨版本可用性調查

逆向 IMK 10.9（Mavericks）、10.11（El Capitan）、10.13（High Sierra）、10.14（Mojave）、10.15（Catalina）共六版 Framework：

| macOS | `IPMDServerClientWrapper._xpcConnection` | `IPMDServerClientWrapper.processIdentifier` | raw client 型別 | PID 可用 |
|-------|:--:|:--:|------|:--:|
| 10.9 | ❌ | ❌ | NSDistantObject | ❌ |
| 10.11 | ✅ | ❌ | NSXPCConnection / NSDistantObject | XPC: ✅ DO: ❌ |
| 10.13 | ✅ | ❌ | 同上 | 同上 |
| 10.14 | ✅ | ❌ | 同上 | 同上 |
| 10.15 | ✅ | ✅ | 同上 | XPC: ✅ DO: ❌ |

`NSXPCConnection.processIdentifier` 自 10.9 起即為 Foundation 外部符號。raw client 在 XPC 模式下就是 `NSXPCConnection` 本身，可直接取得 PID。DO 模式下為 `NSDistantObject`，不支援。

### 2.3 實作策略

在 `callCoreAtLeastOnce` 與 `registerInCache` 兩處，以 `responds(to: #selector(processIdentifier))` 動態偵測——可用則以 `UInt(PID)` 為鍵，不可用則退回 `UInt(proxyAddr)`。

---

## 三、失敗記錄

### 3.1 `performSelector:` primitive return type crash

初版以 `nsobj.perform(Selector("processIdentifier"))?.takeUnretainedValue() as? Int` 取得 PID。實機測試觸發 SIGSEGV：

```
Exception: EXC_BAD_ACCESS / SIGSEGV
Faulting addr: 0x12bf1 (= PID 76785)
Frame 0: swift_unknownObjectRetain
Frame 1: SessionControllerSputnik.swift:65  closure #1 in callCoreAtLeastOnce
```

**根因**：`-[NSObject performSelector:]` 的 contract 要求 selector 必須回傳 `id`（物件指標）。但 `-[NSXPCConnection processIdentifier]` 回傳 `int`（32-bit primitive）。ARM64 上 `int` 回傳值放在 `w0`（32-bit），但 `performSelector:` 把整個 `x0`（64-bit）當作物件指標解讀 → PID 值被傳入 `swift_unknownObjectRetain` 當作 retain target → SIGSEGV。這是 Apple 官方文件明確記載不可為之的 classic pitfall。

**修復**：改用 `value(forKey:)`——KVC 自動將 primitive boxing 為 `NSNumber`。

### 3.2 CpLk toggle 後無法正常打字（"menu needed" issue）

修復 3.1 後，PID 快取在非 CpLk 場景運作正常。但在 CpLk toggle 切回後，IME 無法處理按鍵——所有輸入以英數直接通過——直到使用者手動開啟 IME 選單後才恢復正常。

#### 嘗試的修復路徑

1. **cache lookup guard 復原**：將 `cachedSession(for:)` 呼叫移回 `if let clientObj` guard 內部（避免 `clientObj` 為 nil 時查詢 key 0）——無效。

2. **block 內 fresh Sputnik 解析**：將 `onActivatingServer` block 從 `core?.activateServer($1)`（依賴被捕獲的 `addrPair`）改為以 call-time controller 建立 fresh `SessionControllerSputnik` 解析 session，與 `IMEMenuSputnik` 的 menu 解析路徑一致——無效。

3. **完全回滾**：將 `callCoreAtLeastOnce` 與 `registerInCache` 的快取鍵恢復為 `proxyAddr`，block 恢復為原始 `core?.activateServer($1)`。問題消失。

#### 根因推測（未驗證）

menu 能 fix 的原因：`IMEMenuSputnik.build()` 在每次開啟選單時建立 fresh Sputnik 並建立/重新連接 session。這暗示 `activateServer:` block 的路徑中，session 未能正確初始化 `inputHandler`。

可能原因：
- macOS 27.0 的 `_IMKServerLegacy` + `IMKSignPostInputController` / `IMKLoggingInputController` / `IMKTracingInputController` 包裝層改變了事件時序，`activateServer:` 被呼叫時 `client()` 尚未就緒
- PID 鍵在某種條件下回傳 0 或錯誤值，導致 `registerInCache` 與後續查詢使用不同鍵
- `value(forKey: "processIdentifier")` 在 client 為 DO proxy（`NSDistantObject`）時 forward 到遠端並觸發意外的 RPC 行為
- 因無法在 macOS 27.0 實機上調試，未能最終定位根因

---

## 四、相關逆向發現（保留下來供日後參考）

### 4.1 `bundleIdentifier` 的跨進程 RPC 實作

- **10.9**：`[IPMDServerClientWrapper bundleIdentifier]` → `[_realClient bundleIdentifier]`（DO sync RPC），exception 被 catch → 永不回傳 nil
- **10.15**：XPC 路徑使用 `_bundleIdentifier_Cache` + async semaphore；DO fallback 同 10.9

`bundleIdentifier` 與 `uniqueClientIdentifierString` 均為跨進程 RPC，不適合做快取鍵。

### 4.2 `IPMDServerClientWrapper` 結構演進

| 版本 | ivars | 備註 |
|------|-------|------|
| 10.9 | `_realClient`（DO proxy） | 無 XPC 支持 |
| 10.11+ | `_clientDOProxy`、`_xpcConnection`、`_usesXPC` | XPC 引入，DO 仍可用 |
| 10.15+ | 同上 + `processIdentifier` method | wrapper method 封裝 |

### 4.3 IMKServer controller 生命週期

- `initWithServer:delegate:client:` → 加入 `_controllers`（由 `_clientForController:` 調用）
- `deactivateServer:` → 僅清除 `_currentController`，**不碰** `_controllers`
- `sessionFinished:` → `removeObjectForKey:NSNumber(proxyAddr)` → controller 被移出 `_controllers`
- CpLk toggle 不會觸發 `sessionFinished:` → controller 永久孤兒化 → Phase 112 的 prune 機制解決

---

## 五、結論

`processIdentifier` 作為快取鍵的方案在根本上是可行的（跨版本可用性確認），但在 macOS 27.0 實機上出現 CpLk toggle 後 session 無法正常啟動的問題，經過多種嘗試後未能修復。最終回滾至 `proxyAddr` 快取鍵。Phase 112 的 orphan controller 主動掃除機制確保了舊 session 的記憶體清理，proxyAddr 快取命中率為零的問題（每次 CpLk toggle 新建 session）目前可接受。
