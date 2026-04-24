// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import SwiftExtension

/// 一個會在指定時間間隔後自動使快取條目失效的快取系統。
///
/// 最佳化（2026-04-24）：
/// - 將執行緒同步從 `DispatchQueue.sync` 改為 `NSMutex`，消除 GCD 基礎設施開銷。
/// - 將時間戳記從 `Date`（`gettimeofday` 系統呼叫）改為 `DispatchTime.uptimeNanoseconds`（單調時鐘，更輕量）。
/// - 以操作計數器（每 64 次才觸發一次清理檢查）取代每次操作都建立 `Date()` 的模式。
/// - 以到期佇列搭配時間閘門與分批回收，避免週期性對整張 Dictionary 做全量掃描。
public final class QueryBuffer<T> {
  // MARK: Lifecycle

  /// 以特定的過期時間間隔初期化 QueryBuffer
  /// - Parameter expirationInterval: 條目過期的秒數（預設值：7）
  public init(expirationInterval: TimeInterval = 7.0) {
    self.expirationNanoseconds = UInt64(expirationInterval * 1_000_000_000)
    self.cleanupThrottleNanoseconds = Swift.max(
      Self.minimumCleanupThrottleNanoseconds,
      Swift.min(expirationNanoseconds, Self.maximumCleanupThrottleNanoseconds)
    )
  }

  // MARK: Public

  /// 返回目前在緩衝區中的項目數量（包括尚未清理的過期項目）
  public var count: Int {
    mtxCache.withLockRead { $0.count }
  }

  /// 使用字串鍵值將值加入緩衝區
  /// - Parameters:
  ///   - key: 將被轉換為雜湊值的字串鍵值
  ///   - value: 要儲存的值
  public func set(key: String, value: T) {
    guard !key.isEmpty else { return }
    set(hashKey: key.hashValue, value: value)
  }

  /// 使用雜湊鍵值將值加入緩衝區
  /// - Parameters:
  ///   - hashKey: 整數雜湊鍵值
  ///   - value: 要儲存的值
  public func set(hashKey: Int, value: T) {
    let now = DispatchTime.now().uptimeNanoseconds
    let entry = CacheEntry(value: value, timestampNs: now)
    mtxCache.withLock {
      $0[hashKey] = entry
    }
    mtxExpirationQueue.withLock {
      $0.append(ExpirationMarker(hashKey: hashKey, timestampNs: now))
    }
    let shouldCheckCleanup = mtxOperationCount.withLock { operationCount in
      operationCount &+= 1
      return operationCount & (Self.cleanupCheckInterval - 1) == 0
    }
    if shouldCheckCleanup, shouldRunCleanupLocked(now: now) {
      removeExpiredEntriesLocked(now: now)
    }
  }

  /// 如果值存在且未過期，則從緩衝區擷取該值
  /// - Parameter key: 將被轉換為雜湊值的字串鍵值
  /// - Returns: 如果快取值可用且未過期則返回該值，否則返回 nil
  public func get(key: String) -> T? {
    guard !key.isEmpty else { return nil }
    return get(hashKey: key.hashValue)
  }

  /// 如果值存在且未過期，則從緩衝區擷取該值
  /// - Parameter hashKey: 整數雜湊鍵值
  /// - Returns: 如果快取值可用且未過期則返回該值，否則返回 nil
  public func get(hashKey: Int) -> T? {
    let now = DispatchTime.now().uptimeNanoseconds
    guard let entry = mtxCache.withLockRead({ $0[hashKey] }) else { return nil }
    if now &- entry.timestampNs > expirationNanoseconds {
      mtxCache.withLock { cache in
        if let currentEntry = cache[hashKey], currentEntry.timestampNs == entry.timestampNs {
          cache.removeValue(forKey: hashKey)
        }
      }
      return nil
    }
    return entry.value
  }

  /// 從緩衝區中移除特定條目
  /// - Parameter key: 將被轉換為雜湊值的字串鍵值
  /// - Returns: 如果條目存在則返回被移除的值，否則返回 nil
  @discardableResult
  public func remove(key: String) -> T? {
    guard !key.isEmpty else { return nil }
    return remove(hashKey: key.hashValue)
  }

  /// 從緩衝區中移除特定條目
  /// - Parameter hashKey: 整數雜湊鍵值
  /// - Returns: 如果條目存在則返回被移除的值，否則返回 nil
  @discardableResult
  public func remove(hashKey: Int) -> T? {
    mtxCache.withLock {
      $0.removeValue(forKey: hashKey)?.value
    }
  }

  /// 清除緩衝區中的所有條目
  public func clear() {
    mtxCache.withLock { $0.removeAll() }
    mtxExpirationQueue.withLock { $0.removeAll(keepingCapacity: false) }
    mtxExpirationQueueHead.value = 0
    mtxOperationCount.value = 0
    mtxLastCleanupTimestampNs.value = 0
    mtxCleanupInProgress.value = false
  }

  // MARK: Private

  /// 用於追蹤快取值及其時間戳記的內部結構（使用單調奈秒時間戳）
  private struct CacheEntry {
    let value: T
    let timestampNs: UInt64
  }

  private struct ExpirationMarker {
    let hashKey: Int
    let timestampNs: UInt64
  }

  /// 每 64 次操作才觸發一次清理（64 = 2^6，使用位元 AND 判斷，避免除法）。
  private static var cleanupCheckInterval: UInt64 { 64 }

  /// 每輪清理最多處理的到期條目數量，避免單次 set 夾帶長時間清掃。
  private static var cleanupRemovalLimit: Int { 32 }

  /// 避免高頻輸入時在極短時間內連續進入清理路徑。
  private static var minimumCleanupThrottleNanoseconds: UInt64 { 1_000_000 }

  /// 預設情況下，超過 250ms 再次清理已足夠；更短的過期間隔則跟隨實際 expiration。
  private static var maximumCleanupThrottleNanoseconds: UInt64 { 250_000_000 }

  /// 主要快取儲存空間 - 使用 Int（雜湊值）作為鍵值
  private let mtxCache: NSMutex<[Int: CacheEntry]> = .init([:])

  /// 按寫入時間排列的到期佇列，供清理路徑增量回收使用。
  private let mtxExpirationQueue: NSMutex<[ExpirationMarker]> = .init([])

  /// 到期佇列目前尚未處理的頭部索引。
  private let mtxExpirationQueueHead = NSMutex(0)

  /// 條目過期的奈秒時間間隔
  private let expirationNanoseconds: UInt64

  /// 清理節流時間，避免在高頻 set 下反覆做無效 cleanup pass。
  private let cleanupThrottleNanoseconds: UInt64

  /// 操作計數器（使用溢位加法，讓其自然環繞而不越界）
  private let mtxOperationCount = NSMutex<UInt64>(0)

  /// 上次完成清理嘗試的時間戳記。
  private let mtxLastCleanupTimestampNs = NSMutex<UInt64>(0)

  /// 防止多條執行緒同時進入清理迴圈。
  private let mtxCleanupInProgress = NSMutex<Bool>(false)

  /// 判斷目前是否該進入清理流程。
  private func shouldRunCleanupLocked(now: UInt64) -> Bool {
    let lastCleanupTimestampNs = mtxLastCleanupTimestampNs.value
    return now &- lastCleanupTimestampNs >= cleanupThrottleNanoseconds
  }

  /// 嘗試進入清理流程；若已有清理流程在跑則返回 false。
  private func beginCleanupPass(now: UInt64) -> Bool {
    let shouldEnter = mtxCleanupInProgress.withLock { cleanupInProgress in
      if cleanupInProgress {
        return false
      }
      cleanupInProgress = true
      return true
    }
    guard shouldEnter else { return false }
    mtxLastCleanupTimestampNs.value = now
    return true
  }

  /// 結束清理流程。
  private func endCleanupPass() {
    mtxCleanupInProgress.value = false
  }

  /// 讀取目前到期佇列頭部對應的 marker。
  private func currentExpirationMarker() -> ExpirationMarker? {
    let head = mtxExpirationQueueHead.value
    return mtxExpirationQueue.withLockRead { queue in
      guard head < queue.count else { return nil }
      return queue[head]
    }
  }

  /// 將到期佇列頭部索引往前推進一格。
  private func advanceExpirationQueueHead() {
    mtxExpirationQueueHead.withLock { $0 &+= 1 }
  }

  /// 視情況壓縮已掃描過的隊列頭段，避免隊列無界成長。
  private func compactExpirationQueueIfNeeded() {
    let head = mtxExpirationQueueHead.value
    guard head > 0 else { return }
    let queueCount = mtxExpirationQueue.withLockRead { $0.count }
    guard head >= queueCount / 2 else { return }
    mtxExpirationQueue.withLock { queue in
      if head >= queue.count {
        queue.removeAll(keepingCapacity: false)
      } else {
        queue.removeFirst(head)
      }
    }
    mtxExpirationQueueHead.value = 0
  }

  /// 在持有清理權的前提下移除過期條目（分批回收）。
  private func removeExpiredEntriesLocked(now: UInt64) {
    guard beginCleanupPass(now: now) else { return }
    defer { endCleanupPass() }

    var removedCount = 0
    while removedCount < Self.cleanupRemovalLimit {
      guard let marker = currentExpirationMarker() else { break }
      if now &- marker.timestampNs <= expirationNanoseconds {
        break
      }
      let didRemove = mtxCache.withLock { cache in
        guard let currentEntry = cache[marker.hashKey],
              currentEntry.timestampNs == marker.timestampNs else {
          return false
        }
        cache.removeValue(forKey: marker.hashKey)
        return true
      }
      if didRemove {
        removedCount &+= 1
      }
      advanceExpirationQueueHead()
    }

    compactExpirationQueueIfNeeded()
  }
}
