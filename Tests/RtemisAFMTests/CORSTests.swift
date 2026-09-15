// CORSTests.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import XCTest
@testable import RtemisAFM

final class CORSTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(OriginRule.parse("https://Live.rtemis.org"), .exact("https://live.rtemis.org"))
        XCTAssertEqual(OriginRule.parse("http://localhost:*"), .anyPort(scheme: "http", host: "localhost"))
        XCTAssertEqual(OriginRule.parse("http://localhost:3000"), .exact("http://localhost:3000"))
        XCTAssertNil(OriginRule.parse("localhost"))
        XCTAssertNil(OriginRule.parse("https://x.org/path"))
        XCTAssertNil(OriginRule.parse("http://:*"))
    }

    func testDefaults() {
        let allowed = { (origin: String) in OriginRule.defaults.contains { $0.matches(origin) } }
        XCTAssertTrue(allowed("https://live.rtemis.org"))
        XCTAssertTrue(allowed("http://localhost:3000"))
        XCTAssertTrue(allowed("http://localhost"))
        XCTAssertTrue(allowed("http://127.0.0.1:5173"))
        XCTAssertFalse(allowed("https://localhost:3000"))
        XCTAssertFalse(allowed("http://localhost.evil.com"))
        XCTAssertFalse(allowed("http://localhost:abc"))
        XCTAssertFalse(allowed("https://live.rtemis.org.evil.com"))
        XCTAssertFalse(allowed("null"))
    }
}
