// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

extension StringProtocol {
  func has(string target: any StringProtocol) -> Bool {
    let selfArray = Array(unicodeScalars)
    let targetArray = Array(target.description.unicodeScalars)
    guard !target.isEmpty else { return isEmpty }
    guard count >= target.count else { return false }
    for index in selfArray.indices {
      let range = index ..< (Swift.min(index + targetArray.count, selfArray.count))
      let ripped = Array(selfArray[range])
      if ripped == targetArray { return true }
    }
    return false
  }
}

// MARK: - Index Revolver (only for Array)

extension Int {
  /// 將整數作為陣列索引進行循環位移。
  /// - Parameters:
  ///   - target: 目標陣列
  ///   - clockwise: 是否順時針位移（向更大的索引方向）
  ///   - steps: 位移步數
  public mutating func revolveAsIndex<T>(with target: [T], clockwise: Bool = true, steps: Int = 1) {
    guard self >= 0, steps > 0, !target.isEmpty else { return }

    func revolvedIndex(_ id: Int, clockwise: Bool = true, steps: Int = 1) -> Int {
      guard id >= 0, steps > 0, !target.isEmpty else { return id }
      let count = target.count

      // 優化：使用取模運算直接計算最終位置，避免循環
      let effectiveSteps = steps % count
      if effectiveSteps == 0 { return id }

      let offset = clockwise ? effectiveSteps : -effectiveSteps
      let rawResult = id + offset

      // 使用取模運算處理邊界情況
      let result = ((rawResult % count) + count) % count
      return result
    }

    self = revolvedIndex(self, clockwise: clockwise, steps: steps)
  }
}

// MARK: - FIUUID

/// A simple UUID v4 implementation without Foundation.
/// Generates a random 128-bit UUID compliant with RFC 4122.
public struct FIUUID: Hashable, Codable, Sendable {
  // MARK: Lifecycle

  public init() {
    var rng = SystemRandomNumberGenerator()
    self.bytes = Self.randomBytes(count: 16, using: &rng)
    // Set version to 4
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    // Set variant to 1 (RFC 4122)
    bytes[8] = (bytes[8] & 0x3F) | 0x80
  }

  // MARK: Public

  /// Returns the UUID as a standard hyphenated string (e.g., "123e4567-e89b-12d3-a456-426614174000").
  public func uuidString() -> String {
    let hexDigits = bytes.map { byte in
      let hex = String(byte, radix: 16)
      return hex.count == 1 ? "0" + hex : hex
    }
    let hexString = hexDigits.joined()
    let part1 = hexString.prefix(8)
    let part2 = hexString.dropFirst(8).prefix(4)
    let part3 = hexString.dropFirst(12).prefix(4)
    let part4 = hexString.dropFirst(16).prefix(4)
    let part5 = hexString.suffix(12)
    return "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)"
  }

  // MARK: Private

  private var bytes: [UInt8]

  private static func randomBytes(
    count: Int,
    using rng: inout SystemRandomNumberGenerator
  )
    -> [UInt8] {
    var result = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
      let randomValue = rng.next()
      withUnsafeBytes(of: randomValue) { buffer in
        let bytesToCopy = min(8, count - offset)
        let byteCount = min(bytesToCopy, buffer.count)
        for i in 0 ..< byteCount {
          result[offset + i] = buffer[i]
        }
        offset += byteCount
      }
    }
    return result
  }
}
