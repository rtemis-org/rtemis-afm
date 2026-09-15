// GenerationGateTests.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import XCTest
@testable import RtemisAFM

final class GenerationGateTests: XCTestCase {
    func testLimitsConcurrencyAndQueues() async throws {
        let gate = GenerationGate(limit: 2)
        try await gate.acquire()
        try await gate.acquire()
        let active = await gate.active
        XCTAssertEqual(active, 2)

        let third = Task { try await gate.acquire() }
        try await Task.sleep(for: .milliseconds(50))
        let queued = await gate.queued
        XCTAssertEqual(queued, 1)

        await gate.release()
        try await third.value
        let stillActive = await gate.active
        XCTAssertEqual(stillActive, 2)
        await gate.release()
        await gate.release()
        let none = await gate.active
        XCTAssertEqual(none, 0)
    }

    func testCancelledWaiterLeavesTheQueue() async throws {
        let gate = GenerationGate(limit: 1)
        try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let queued = await gate.queued
        XCTAssertEqual(queued, 0)
        await gate.release()
        let active = await gate.active
        XCTAssertEqual(active, 0)
    }
}
