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

/// A lightweight pseudo-UUID，採用兩個 UInt64 儲存 128 位元識別值，以維持標準 UUID 字串格式且降低陣列開銷。
@frozen
public struct FIUUID: Hashable, Codable, Sendable {
  // MARK: Lifecycle

  public init() {
    self.highBits = UInt64.random(in: UInt64.min ... UInt64.max)
    self.lowBits = UInt64.random(in: UInt64.min ... UInt64.max)
  }

  public init(highBits: UInt64, lowBits: UInt64) {
    self.highBits = highBits
    self.lowBits = lowBits
  }

  /// 與先前 64 位元版本相容：會將值儲存在低位元，並將高位元清零。
  public init(rawValue: UInt64) {
    self.highBits = 0
    self.lowBits = rawValue
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()

    if let stringValue = try? container.decode(String.self) {
      guard let decoded = FIUUID(uuidString: stringValue) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Invalid UUID string for FIUUID."
        )
      }
      self = decoded
      return
    }

    if let pair = try? container.decode([UInt64].self), pair.count == 2 {
      self.init(highBits: pair[0], lowBits: pair[1])
      return
    }

    if let legacyRaw = try? container.decode(UInt64.self) {
      self.init(rawValue: legacyRaw)
      return
    }

    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Unsupported FIUUID encoding."
    )
  }

  /// 依照 UUID 字串初始化識別值，支援大小寫。
  public init?(uuidString: String) {
    let filtered = uuidString.filter { $0 != "-" }
    guard filtered.count == 32 else { return nil }

    var bytes: [UInt8] = []
    bytes.reserveCapacity(16)

    var index = filtered.startIndex
    for _ in 0 ..< 16 {
      let highChar = filtered[index]
      index = filtered.index(after: index)
      let lowChar = filtered[index]
      index = filtered.index(after: index)

      guard let high = Self.hexValue(of: highChar),
            let low = Self.hexValue(of: lowChar)
      else { return nil }

      bytes.append((high << 4) | low)
    }

    self.init(bytes: bytes)
  }

  private init(bytes: [UInt8]) {
    self.highBits = Self.readBigEndian(from: bytes, offset: 0)
    self.lowBits = Self.readBigEndian(from: bytes, offset: 8)
  }

  // MARK: Public

  /// 高 64 位元與低 64 位元的原始識別值。
  public let highBits: UInt64
  public let lowBits: UInt64

  /// 以標準 UUID 字串形式返回識別值（預設為大寫）。
  public func uuidString(uppercase: Bool = true) -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    Self.write(bigEndian: highBits, to: &bytes, offset: 0)
    Self.write(bigEndian: lowBits, to: &bytes, offset: 8)

    let hexDigits = uppercase ? Self.upperHexDigits : Self.lowerHexDigits
    var characters: [Character] = []
    characters.reserveCapacity(36)

    for index in 0 ..< bytes.count {
      if index == 4 || index == 6 || index == 8 || index == 10 {
        characters.append("-")
      }
      let byte = bytes[index]
      characters.append(hexDigits[Int(byte >> 4)])
      characters.append(hexDigits[Int(byte & 0x0F)])
    }

    return String(characters)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(uuidString())
  }

  // MARK: Private

  private static let upperHexDigits: [Character] = Array("0123456789ABCDEF")
  private static let lowerHexDigits: [Character] = Array("0123456789abcdef")

  private static func write(bigEndian value: UInt64, to buffer: inout [UInt8], offset: Int) {
    for index in 0 ..< 8 {
      buffer[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * (7 - index)))
    }
  }

  private static func readBigEndian(from buffer: [UInt8], offset: Int) -> UInt64 {
    var result: UInt64 = 0
    for index in 0 ..< 8 {
      result = (result << 8) | UInt64(buffer[offset + index])
    }
    return result
  }

  private static func hexValue(of character: Character) -> UInt8? {
    switch character {
    case "0" ... "9":
      return UInt8(character.unicodeScalars.first!.value - Unicode.Scalar("0").value)
    case "a" ... "f":
      return UInt8(character.unicodeScalars.first!.value - Unicode.Scalar("a").value + 10)
    case "A" ... "F":
      return UInt8(character.unicodeScalars.first!.value - Unicode.Scalar("A").value + 10)
    default:
      return nil
    }
  }
}

#if canImport(Foundation)
  import Foundation

  extension FIUUID {
    /// 以 `UUID` 表示的識別值，僅在可匯入 Foundation 時提供。
    public var uuid: UUID {
      guard let result = UUID(uuidString: uuidString()) else {
        preconditionFailure("Invalid FIUUID state: unable to produce UUID string.")
      }
      return result
    }

    /// 透過 Foundation 的 `UUID` 初始化。
    public init(uuid: UUID) {
      guard let value = FIUUID(uuidString: uuid.uuidString) else {
        preconditionFailure("Unable to convert UUID to FIUUID.")
      }
      self = value
    }
  }
#endif
