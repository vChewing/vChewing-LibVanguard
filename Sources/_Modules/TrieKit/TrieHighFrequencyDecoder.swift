// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

/// High-performance specialized JSON decoder for frequently used data types in TrieKit.
/// This decoder is optimized for the specific JSON formats we encounter and avoids
/// the overhead of the general-purpose Foundation JSONDecoder.
public enum TrieHighFrequencyDecoder {
  // MARK: Public

  /// Decodes a JSON array of integers into a Set<Int>.
  /// This is optimized for arrays like [1,2,3,4,5] which are common in node_ids fields.
  /// Uses direct byte-level parsing for maximum performance.
  /// - Parameter jsonString: The JSON string to decode
  /// - Returns: Set<Int> if successful, nil if parsing fails
  public static func decodeIntSet(from jsonString: String) -> Set<Int>? {
    guard let data = jsonString.data(using: .utf8) else {
      return nil
    }
    return decodeIntSet(from: data)
  }

  /// Optimized decoding method that works directly with Data using byte-level parsing
  /// - Parameter data: UTF-8 encoded JSON data
  /// - Returns: Set<Int> if successful, nil if parsing fails
  public static func decodeIntSet(from data: Data) -> Set<Int>? {
    // Handle minimal cases - if only 2 bytes, must be "[]"
    if data.count < 2 {
      return nil
    }

    // Fast path for empty arrays "[]"
    if data.count == 2 {
      if data[0] == 0x5B, data[1] == 0x5D { // '[' and ']' in ASCII
        return Set<Int>()
      }
      return nil
    }

    // Check first and last bytes directly for '[' and ']'
    guard data.first == 0x5B, data.last == 0x5D else { // '[' = 0x5B, ']' = 0x5D
      return nil
    }

    // Create result set
    var result = Set<Int>()

    // Skip opening '[' and process until closing ']'
    let bytes = data.dropFirst().dropLast()

    // Handle empty content between brackets
    if bytes.isEmpty {
      return Set<Int>()
    }

    // Parse using byte-level iteration
    var buffer = [UInt8]()
    buffer.reserveCapacity(16) // Reserve space for typical integer lengths

    for byte in bytes {
      if byte == 0x2C { // ',' delimiter
        // Parse current buffer as integer
        if let intValue = parseBufferAsInt(buffer) {
          result.insert(intValue)
        } else {
          return nil // Invalid integer found
        }
        buffer.removeAll(keepingCapacity: true)
      } else if byte >= 0x30 && byte <= 0x39 { // '0'-'9'
        buffer.append(byte)
      } else if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { // whitespace
        // Skip whitespace
        continue
      } else {
        return nil // Invalid character
      }
    }

    // Parse final buffer (after last comma or single number)
    if !buffer.isEmpty {
      if let intValue = parseBufferAsInt(buffer) {
        result.insert(intValue)
      } else {
        return nil
      }
    }

    return result
  }

  // MARK: Private

  /// Parse a buffer of ASCII digit bytes as an integer
  /// - Parameter buffer: Array of ASCII digit bytes
  /// - Returns: Integer value if valid, nil otherwise
  private static func parseBufferAsInt(_ buffer: [UInt8]) -> Int? {
    if buffer.isEmpty {
      return nil
    }

    var result = 0
    for byte in buffer {
      guard byte >= 0x30, byte <= 0x39 else { // '0'-'9'
        return nil
      }
      let digit = Int(byte - 0x30)

      // Check for overflow
      if result > (Int.max - digit) / 10 {
        return nil
      }

      result = result * 10 + digit
    }

    return result
  }
}
