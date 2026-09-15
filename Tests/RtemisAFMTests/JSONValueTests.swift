// JSONValueTests.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import XCTest
@testable import RtemisAFM

final class JSONValueTests: XCTestCase {
    func testRoundTrip() throws {
        let text = #"{"a":[1,2.5,"x",true,null],"b":{"c":{}}}"#
        let value = try JSONValue(parsing: text)
        XCTAssertEqual(value["a"]?.arrayValue?.count, 5)
        XCTAssertEqual(value["a"]?.arrayValue?[0].intValue, 1)
        XCTAssertNil(value["a"]?.arrayValue?[1].intValue)
        XCTAssertEqual(value["a"]?.arrayValue?[1].doubleValue, 2.5)
        XCTAssertEqual(value["b"]?["c"], [:])
        XCTAssertEqual(value.jsonString, #"{"a":[1,2.5,"x",true,null],"b":{"c":{}}}"#)
    }

    func testLiterals() {
        let value: JSONValue = ["type": "object", "required": ["a"], "n": 3, "f": 1.5, "ok": true, "none": nil]
        XCTAssertEqual(value["type"]?.stringValue, "object")
        XCTAssertEqual(value["required"], ["a"])
        XCTAssertEqual(value["n"]?.intValue, 3)
        XCTAssertEqual(value["ok"]?.boolValue, true)
        XCTAssertTrue(value["none"]?.isNull == true)
    }

    func testWholeNumbersEncodeWithoutFraction() {
        XCTAssertEqual(JSONValue.number(8192).jsonString, "8192")
        XCTAssertEqual(JSONValue.number(0.5).jsonString, "0.5")
    }
}
