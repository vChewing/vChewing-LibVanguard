// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

/// High-performance specialized JSON decoder for frequently used data types in TrieKit.
/// This decoder is optimized for the specific JSON formats we encounter and avoids
/// the overhead of the general-purpose Foundation JSONDecoder.
public final class TrieHighFrequencyDecoder {
  
  /// Decodes a JSON array of integers into a Set<Int>.
  /// This is optimized for arrays like [1,2,3,4,5] which are common in node_ids fields.
  /// - Parameter jsonString: The JSON string to decode
  /// - Returns: Set<Int> if successful, nil if parsing fails
  public static func decodeIntSet(from jsonString: String) -> Set<Int>? {
    // Fast path for empty arrays
    let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "[]" {
      return Set<Int>()
    }
    
    // Verify it starts and ends with brackets
    guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else {
      return nil
    }
    
    // Extract the content between brackets
    let content = String(trimmed.dropFirst().dropLast())
    
    // Handle empty content
    if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return Set<Int>()
    }
    
    // Split by commas and parse integers
    var result = Set<Int>()
    let components = content.split(separator: ",")
    
    for component in components {
      let trimmedComponent = component.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let intValue = Int(trimmedComponent) else {
        return nil // Invalid integer found
      }
      result.insert(intValue)
    }
    
    return result
  }
  
  /// Alternative decoding method that works directly with Data
  /// - Parameter data: UTF-8 encoded JSON data
  /// - Returns: Set<Int> if successful, nil if parsing fails
  public static func decodeIntSet(from data: Data) -> Set<Int>? {
    guard let jsonString = String(data: data, encoding: .utf8) else {
      return nil
    }
    return decodeIntSet(from: jsonString)
  }
}