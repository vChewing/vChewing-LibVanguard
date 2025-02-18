// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

@testable import BrailleSputnik
import Testing

@Suite(.serialized)
public struct BrailleSputnikTests {
  // MARK: Internal

  @Test("[BrailleSputnik] BasicBrailleConversion")
  func testBrailleConversion() throws {
    // 大丘丘病了二丘丘瞧，三丘丘採藥四丘丘熬。
    var rawReadingStr = "ㄉㄚˋ-ㄑㄧㄡ-ㄑㄧㄡ-ㄅㄧㄥˋ-ㄌㄜ˙-ㄦˋ-ㄑㄧㄡ-ㄑㄧㄡ-ㄑㄧㄠˊ-_，"
    rawReadingStr += "-ㄙㄢ-ㄑㄧㄡ-ㄑㄧㄡ-ㄘㄞˇ-ㄧㄠˋ-ㄙˋ-ㄑㄧㄡ-ㄑㄧㄡ-ㄠˊ-_。"
    let rawReadingArray: [KeyValueTuple] = rawReadingStr.split(separator: "-").map {
      let value: String = $0.first == "_" ? $0.last?.description ?? "" : ""
      return (key: $0.description, value: value)
    }
    let processor = BrailleSputnik(standard: .of1947)
    let result1947 = processor.convertToBraille(smashedPairs: rawReadingArray)
    #expect(result1947 == "⠙⠜⠐⠚⠎⠄⠚⠎⠄⠕⠽⠐⠉⠮⠁⠱⠐⠚⠎⠄⠚⠎⠄⠚⠪⠂⠆⠑⠧⠄⠚⠎⠄⠚⠎⠄⠚⠺⠈⠪⠐⠑⠐⠚⠎⠄⠚⠎⠄⠩⠂⠤⠀")
    processor.standard = .of2018
    let result2018 = processor.convertToBraille(smashedPairs: rawReadingArray)
    #expect(result2018 == "⠙⠔⠆⠅⠳⠁⠅⠳⠁⠃⠡⠆⠇⠢⠗⠆⠅⠳⠁⠅⠳⠁⠅⠜⠂⠐⠎⠧⠁⠅⠳⠁⠅⠳⠁⠉⠪⠄⠜⠆⠎⠆⠅⠳⠁⠅⠳⠁⠖⠂⠐⠆")
  }

  // MARK: Private

  private typealias KeyValueTuple = (key: String, value: String)
}
