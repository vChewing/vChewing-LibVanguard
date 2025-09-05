// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - Advanced Performance Optimizations

/// Specialized cache for bigram score calculations to avoid repeated sorting and lookup operations
@usableFromInline
final class BigramScoreCache: @unchecked Sendable {
  // MARK: Lifecycle

  private init() {}

  // MARK: Internal

  @usableFromInline
  static let shared = BigramScoreCache()

  @usableFromInline
  func getCachedBigramScore(for current: String, previous: String) -> Double? {
    lock.lock()
    defer { lock.unlock() }

    return cache[previous]?[current]
  }

  @usableFromInline
  func setBigramScore(_ score: Double, for current: String, previous: String) {
    lock.lock()
    defer { lock.unlock() }

    if cache.count >= maxCacheSize {
      // Simple LRU-like behavior: remove first entries when cache is full
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

  @usableFromInline
  func clear() {
    lock.lock()
    defer { lock.unlock() }
    cache.removeAll(keepingCapacity: true)
  }

  // MARK: Private

  private var cache: [String: [String: Double]] = [:]
  private let lock = NSLock()
  private let maxCacheSize = 5_000
}
