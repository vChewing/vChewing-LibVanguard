// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
@testable import Homa
import Testing

struct HomaTests_NodeOverrideStatus: HomaTestSuite {
  @Test("NodeOverrideStatus Initialization")
  func testNodeOverrideStatusInitialization() {
    // Test default initialization
    let defaultStatus = Homa.NodeOverrideStatus()
    #expect(defaultStatus.overridingScore == 114_514)
    #expect(defaultStatus.currentOverrideType == .none)
    #expect(defaultStatus.currentUnigramIndex == 0)

    // Test custom initialization
    let customStatus = Homa.NodeOverrideStatus(
      overridingScore: 999.0,
      currentOverrideType: .withSpecified,
      currentUnigramIndex: 5
    )
    #expect(customStatus.overridingScore == 999.0)
    #expect(customStatus.currentOverrideType == .withSpecified)
    #expect(customStatus.currentUnigramIndex == 5)
  }

  @Test("NodeOverrideStatus Equality")
  func testNodeOverrideStatusEquality() {
    let status1 = Homa.NodeOverrideStatus(
      overridingScore: 100.0,
      currentOverrideType: .withTopGramScore,
      currentUnigramIndex: 2
    )

    let status2 = Homa.NodeOverrideStatus(
      overridingScore: 100.0,
      currentOverrideType: .withTopGramScore,
      currentUnigramIndex: 2
    )

    let status3 = Homa.NodeOverrideStatus(
      overridingScore: 200.0,
      currentOverrideType: .withTopGramScore,
      currentUnigramIndex: 2
    )

    #expect(status1 == status2)
    #expect(status1 != status3)
  }

  @Test("Node OverrideStatus Property")
  func testNodeOverrideStatusProperty() {
    let keyArray = ["ㄅ", "ㄧ"]
    let testData = [
      Homa.GramRAW(keyArray: keyArray, value: "逼", probability: -5.0, previous: nil),
      Homa.GramRAW(keyArray: keyArray, value: "比", probability: -8.0, previous: nil),
    ]

    let grams = testData.map { Homa.Gram($0) }
    let node = Homa.Node(keyArray: keyArray, grams: grams)

    // Test getting override status
    let initialStatus = node.overrideStatus
    #expect(initialStatus.overridingScore == 114_514)
    #expect(initialStatus.currentOverrideType == .none)
    #expect(initialStatus.currentUnigramIndex == 0)

    // Test setting override status
    let newStatus = Homa.NodeOverrideStatus(
      overridingScore: 500.0,
      currentOverrideType: .withSpecified,
      currentUnigramIndex: 1
    )
    node.overrideStatus = newStatus

    #expect(node.overridingScore == 500.0)
    #expect(node.currentOverrideType == .withSpecified)
    #expect(node.currentGramIndex == 1)

    // Test getting updated status
    let updatedStatus = node.overrideStatus
    #expect(updatedStatus.overridingScore == 500.0)
    #expect(updatedStatus.currentOverrideType == .withSpecified)
    #expect(updatedStatus.currentUnigramIndex == 1)
  }

  @Test("Node ID Uniqueness")
  func testNodeIDUniqueness() {
    let keyArray = ["ㄅ", "ㄧ"]
    let testData = [
      Homa.GramRAW(keyArray: keyArray, value: "逼", probability: -5.0, previous: nil),
    ]

    let grams = testData.map { Homa.Gram($0) }
    let node1 = Homa.Node(keyArray: keyArray, grams: grams)
    let node2 = Homa.Node(keyArray: keyArray, grams: grams)

    // Each node should have a unique ID
    #expect(node1.id != node2.id)

    // Copy should have a different ID
    let node3 = node1.copy
    #expect(node1.id != node3.id)
  }

  @Test("Assembler Node Override Status Mirroring")
  func testAssemblerNodeOverrideStatusMirroring() throws {
    let assembler = Self.makeAssemblerUsingMockLM()

    try assembler.insertKeys(["a", "b", "c"])

    // Generate mirror before any changes
    let originalMirror = assembler.generateNodeOverrideStatusMirror()
    #expect(!originalMirror.isEmpty)

    // Modify some node states (we'll modify the first available node we find)
    var modifiedNodeId: FIUUID?
    outerLoop: for segment in assembler.segments {
      for (_, node) in segment {
        node.overrideStatus = Homa.NodeOverrideStatus(
          overridingScore: 777.0,
          currentOverrideType: .withSpecified,
          currentUnigramIndex: 0
        )
        modifiedNodeId = node.id
        break outerLoop
      }
    }

    guard let nodeId = modifiedNodeId else {
      Issue.record("No nodes found to modify")
      return
    }

    // Generate new mirror after changes
    let modifiedMirror = assembler.generateNodeOverrideStatusMirror()

    // Verify the change is reflected in the mirror
    #expect(modifiedMirror[nodeId]?.overridingScore == 777.0)
    #expect(modifiedMirror[nodeId]?.currentOverrideType == .withSpecified)

    // Reset using original mirror
    assembler.restoreNodeOverrideStatusFromMirror(originalMirror)

    // Verify restoration
    let restoredMirror = assembler.generateNodeOverrideStatusMirror()
    #expect(restoredMirror[nodeId]?.overridingScore == originalMirror[nodeId]?.overridingScore)
    #expect(
      restoredMirror[nodeId]?.currentOverrideType == originalMirror[nodeId]?
        .currentOverrideType
    )
  }

  @Test("NodeOverrideStatus Codable")
  func testNodeOverrideStatusCodable() throws {
    let status = Homa.NodeOverrideStatus(
      overridingScore: 123.45,
      currentOverrideType: .withTopGramScore,
      currentUnigramIndex: 3
    )

    // Test encoding
    let encoded = try JSONEncoder().encode(status)

    // Test decoding
    let decoded = try JSONDecoder().decode(Homa.NodeOverrideStatus.self, from: encoded)

    #expect(decoded.overridingScore == 123.45)
    #expect(decoded.currentOverrideType == .withTopGramScore)
    #expect(decoded.currentUnigramIndex == 3)
  }
}
