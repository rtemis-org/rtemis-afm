// ImageDecoderTests.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import XCTest
@testable import RtemisAFM

/// A 1×1 transparent PNG as the AI SDK would send it.
let onePixelPNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

final class ImageDecoderTests: XCTestCase {
    func testDecodesADataURI() throws {
        let attachment = try ImageDecoder.attachment(from: onePixelPNG)
        XCTAssertEqual(attachment.cgImage.width, 1)
        XCTAssertEqual(attachment.cgImage.height, 1)
    }

    func testMediaTypeIsNotTrusted() throws {
        // ImageIO sniffs the bytes; a wrong or missing media type is fine.
        let mislabeled = onePixelPNG.replacingOccurrences(of: "image/png", with: "image/jpeg")
        XCTAssertEqual(try ImageDecoder.attachment(from: mislabeled).cgImage.width, 1)
        let untyped = onePixelPNG.replacingOccurrences(of: "image/png", with: "")
        XCTAssertEqual(try ImageDecoder.attachment(from: untyped).cgImage.width, 1)
    }

    func testPercentEncodedPayload() throws {
        XCTAssertEqual(String(decoding: try ImageDecoder.data(fromDataURI: "data:text/plain,a%20b"), as: UTF8.self), "a b")
    }

    func testRemoteURLIsUnsupported() {
        XCTAssertThrowsError(try ImageDecoder.attachment(from: "https://example.org/a.png")) { error in
            XCTAssertEqual((error as? BridgeError)?.code, "unsupported")
        }
    }

    func testNotAnImage() {
        for uri in ["data:image/png;base64,bm90IGFuIGltYWdl", "data:image/png;base64,", "data:image/png"] {
            XCTAssertThrowsError(try ImageDecoder.attachment(from: uri), uri) { error in
                XCTAssertEqual((error as? BridgeError)?.status, 400)
                XCTAssertEqual((error as? BridgeError)?.code, "invalid_image")
            }
        }
    }
}
