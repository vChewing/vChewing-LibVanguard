// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - StringInternPool

/// String interning pool to reduce memory allocations for frequently used strings
@usableFromInline
final class StringInternPool: @unchecked Sendable {
  // MARK: Internal

  @usableFromInline
  static let shared = StringInternPool()

  @usableFromInline
  func intern(_ string: String) -> String {
    lock.withLock {
      if let interned = pool[string] {
        return interned
      }

      pool[string] = string
      return string
    }
  }

  @usableFromInline
  func clear() {
    lock.withLock {
      pool.removeAll(keepingCapacity: true)
    }
  }

  // MARK: Private

  private var pool: [String: String] = [:]
  private let lock = NSLock()
}

// MARK: - ObjectPool

/// Object pool for frequently allocated temporary objects
@usableFromInline
final class ObjectPool<T> {
  // MARK: Lifecycle

  @usableFromInline
  init(createObject: @escaping () -> T, resetObject: @escaping (T) -> () = { _ in }) {
    self.createObject = createObject
    self.resetObject = resetObject
  }

  // MARK: Internal

  @usableFromInline
  func borrow() -> T {
    lock.withLock {
      if let object = objects.popLast() {
        return object
      }
      return createObject()
    }
  }

  @usableFromInline
  func returnObject(_ object: T) {
    lock.withLock {
      resetObject(object)
      objects.append(object)
    }
  }

  // MARK: Private

  private var objects: ContiguousArray<T> = []
  private let createObject: () -> T
  private let resetObject: (T) -> ()
  private let lock = NSLock()
}

// MARK: - StringOperationCache

/// Cache for frequently computed string operations
@usableFromInline
final class StringOperationCache: @unchecked Sendable {
  // MARK: Internal

  @usableFromInline
  static let shared = StringOperationCache()

  @usableFromInline
  func getCachedSplit(_ string: String, separator: Character) -> [String] {
    let key = "\(string)|\(separator)"

    return lock.withLock {
      if let cached = splitCache[key] {
        return cached
      }

      let result = string.split(separator: separator).map(String.init)

      // Prevent unbounded cache growth
      if splitCache.count < maxCacheSize {
        splitCache[key] = result
      }

      return result
    }
  }

  @usableFromInline
  func getCachedJoin(_ strings: [String], separator: String) -> String {
    let key = strings.joined(separator: "|") + "|\(separator)"

    return lock.withLock {
      if let cached = joinCache[key] {
        return cached
      }

      let result = strings.joined(separator: separator)

      // Prevent unbounded cache growth
      if joinCache.count < maxCacheSize {
        joinCache[key] = result
      }

      return result
    }
  }

  @usableFromInline
  func clear() {
    lock.withLock {
      splitCache.removeAll(keepingCapacity: true)
      joinCache.removeAll(keepingCapacity: true)
    }
  }

  // MARK: Private

  private var splitCache: [String: [String]] = [:]
  private var joinCache: [String: String] = [:]
  private let lock = NSLock()
  private let maxCacheSize = 1_000
}
