// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - 進階效能最佳化

/// 專門用於雙字組評分計算的快取，避免重複的排序與查找操作
@usableFromInline
final class BigramScoreCache: @unchecked Sendable {
  // MARK: Lifecycle

  private init() {}

  // MARK: Internal

  @usableFromInline
  static let shared = BigramScoreCache()

  @usableFromInline
  func getCachedBigramScore(for current: String, previous: String) -> Double? {
    lock.withLock {
      cache[previous]?[current]
    }
  }

  @usableFromInline
  func setBigramScore(_ score: Double, for current: String, previous: String) {
    lock.withLock {
      if cache.count >= maxCacheSize {
        // 簡易 LRU 式行為：當快取滿時移除最早的條目
        let keysToRemove = Array(cache.keys.prefix(maxCacheSize / 4))
        for key in keysToRemove {
          cache.removeValue(forKey: key)
        }
      }

      if cache[previous] == nil {
        cache[previous] = [:]
      }
      cache[previous]![current] = score
    }
  }

  @usableFromInline
  func clear() {
    lock.withLock {
      cache.removeAll(keepingCapacity: true)
    }
  }

  // MARK: Private

  private var cache: [String: [String: Double]] = [:]
  private let lock = NSLock()
  private let maxCacheSize = 5_000
}
