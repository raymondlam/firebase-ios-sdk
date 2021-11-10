// Copyright 2021 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import XCTest
@testable import HeartbeatLogging

class HeartbeatControllerTests: XCTestCase {
  // 2021-11-01 @ 00:00:00 (EST)
  let date = Date(timeIntervalSince1970: 1_635_739_200)

  func testFlushWhenEmpty() throws {
    // Given
    let controller = HeartbeatController(storage: HeartbeatStorageFake())
    // Then
    assertHeartbeatControllerFlushesEmptyPayload(controller)
  }

  func testLogAndFlush() throws {
    // Given
    let clock = SystemClock(date: date)

    let controller = HeartbeatController(
      storage: HeartbeatStorageFake(),
      dateProvider: { clock.date }
    )

    assertHeartbeatControllerFlushesEmptyPayload(controller)

    // When
    controller.log("dummy_agent")
    let heartbeatPayload = controller.flush()

    // Then
    assertEqualPayloadStrings(
      heartbeatPayload.headerValue(),
      """
      {
        "version": 0,
        "payload": [
          {
            "agent": "dummy_agent",
            "dates": ["2021-11-01"]
          }
        ]
      }
      """
    )

    assertHeartbeatControllerFlushesEmptyPayload(controller)
  }

  func testLoggingDifferentAgentsInSameTimePeriodOnlyStoresTheFirst() throws {
    // Given
    let clock = SystemClock(date: date)

    let controller = HeartbeatController(
      storage: HeartbeatStorageFake(),
      dateProvider: { clock.date }
    )

    assertHeartbeatControllerFlushesEmptyPayload(controller)

    // When
    controller.log("dummy_agent")
    controller.log("some_other_dummy_agent")
    let heartbeatPayload = controller.flush()

    // Then
    assertEqualPayloadStrings(
      heartbeatPayload.headerValue(),
      """
      {
        "version": 0,
        "payload": [
          {
            "agent": "dummy_agent",
            "dates": ["2021-11-01"]
          }
        ]
      }
      """
    )

    assertHeartbeatControllerFlushesEmptyPayload(controller)
  }

  func testLogAtEndOfTimePeriodAndAcceptAtStartOfNextOne() throws {
    // Given
    let clock = SystemClock(date: date)

    let controller = HeartbeatController(
      storage: HeartbeatStorageFake(),
      dateProvider: { clock.date }
    )

    assertHeartbeatControllerFlushesEmptyPayload(controller)

    // When
    // - Clock time 2021-11-01 @ 00:00:00 (EST)
    controller.log("dummy_agent")

    // - Advance to 2021-11-01 @ 23:59:59 (EST)
    do { clock.advance(by: 60 * 60 * 24 - 1) }

    controller.log("dummy_agent")

    // - Advance to 2021-11-02 @ 00:00:00 (EST)
    do { clock.advance(by: 1) }

    controller.log("dummy_agent")

    // Then
    let heartbeatPayload = controller.flush()

    assertEqualPayloadStrings(
      heartbeatPayload.headerValue(),
      """
      {
        "version": 0,
        "payload": [
          {
            "agent": "dummy_agent",
            "dates": ["2021-11-01", "2021-11-02"]
          }
        ]
      }
      """
    )

    assertHeartbeatControllerFlushesEmptyPayload(controller)
  }

  func testDoNotLogDuplicate() throws {
    // Given
    let clock = SystemClock(date: date)

    let controller = HeartbeatController(
      storage: HeartbeatStorageFake(),
      dateProvider: { clock.date }
    )

    // When
    controller.log("dummy_agent")
    controller.log("dummy_agent")

    // Then
    let heartbeatPayload = controller.flush()

    assertEqualPayloadStrings(
      heartbeatPayload.headerValue(),
      """
      {
        "version": 0,
        "payload": [
          {
            "agent": "dummy_agent",
            "dates": ["2021-11-01"]
          }
        ]
      }
      """
    )
  }

  func testDoNotLogDuplicateAfterFlushing() throws {
    // Given
    let clock = SystemClock(date: date)

    let controller = HeartbeatController(
      storage: HeartbeatStorageFake(),
      dateProvider: { clock.date }
    )

    // When
    controller.log("dummy_agent")
    let heartbeatPayload = controller.flush()
    controller.log("dummy_agent")

    // Then
    assertEqualPayloadStrings(
      heartbeatPayload.headerValue(),
      """
      {
        "version": 0,
        "payload": [
          {
            "agent": "dummy_agent",
            "dates": ["2021-11-01"]
          }
        ]
      }
      """
    )

    // Below assertion asserts that duplicate was not logged again.
    assertHeartbeatControllerFlushesEmptyPayload(controller)
  }
}

func assertHeartbeatControllerFlushesEmptyPayload(_ controller: HeartbeatController) {
  XCTAssertEqual(controller.flush().headerValue(), "")
}

// MARK: - Fakes

extension HeartbeatControllerTests {
  class HeartbeatStorageFake: HeartbeatStorageProtocol {
    private var heartbeatInfo: HeartbeatInfo?

    func async(_ transform: @escaping HeartbeatInfoTransform) {
      heartbeatInfo = transform(heartbeatInfo)
    }

    func getAndReset(using transform: HeartbeatInfoTransform?) throws -> HeartbeatInfo? {
      let oldHeartbeatInfo = heartbeatInfo
      heartbeatInfo = transform?(heartbeatInfo)
      return oldHeartbeatInfo
    }
  }

  /// Simulates the device system time.
  class SystemClock {
    private(set) var date: Date

    init(date: Date = .init()) {
      self.date = date
    }

    func advance(by timeInterval: TimeInterval) {
      date = date.advanced(by: timeInterval)
    }

    var formattedDate: String {
      HeartbeatsPayload.dateFormatter.string(from: date)
    }
  }

  // TODO: - Revisit below assertion implementation.
  // This can be simplified further by making HeartbeatsPayload conform to Equatable...
  func assertEqualPayloadStrings(_ encoded: String, _ literal: String) {
    let encodedData = Data(base64Encoded: encoded)!
    let literalData = literal.data(using: .utf8)!

    let payloadFromEncoded = try! JSONDecoder().decode(HeartbeatsPayload.self, from: encodedData)
    let payloadFromLiteral = try! JSONDecoder().decode(HeartbeatsPayload.self, from: literalData)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

    let payloadDataFromEncoded = try! encoder.encode(payloadFromEncoded)
    let payloadDataFromLiteral = try! encoder.encode(payloadFromLiteral)

    let jsonObjectFromEncoded = try! JSONSerialization
      .jsonObject(with: payloadDataFromEncoded) as? [String: Any] ?? [:]
    let jsonObjectFromLiteral = try! JSONSerialization
      .jsonObject(with: payloadDataFromLiteral) as? [String: Any] ?? [:]

    XCTAssert(
      NSDictionary(dictionary: jsonObjectFromEncoded).isEqual(to: jsonObjectFromLiteral),
      """
      Mismatched payloads!

      Payload 1:
      \(String(data: payloadDataFromEncoded, encoding: .utf8) ?? "")

      Payload 2:
      \(String(data: payloadDataFromLiteral, encoding: .utf8) ?? "")

      """
    )
  }
}