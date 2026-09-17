// ImageDecoder.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import Foundation
import FoundationModels
import ImageIO

/// Turns an OpenAI `image_url` into the framework's image attachment.
///
/// Only `data:` URIs are accepted. A client that uploaded an image sends one
/// (the AI SDK encodes every image part as `data:<type>;base64,…`), and it
/// is the one form the bridge can decode without leaving the machine: an
/// `http(s)` address would have the bridge fetch from the network on the
/// page's behalf, which a loopback server for an on-device model has no
/// business doing. The framework sizes images itself, so `detail` is
/// ignored, and every format `ImageIO` reads (PNG, JPEG, HEIC, WebP, GIF,
/// TIFF, …) is accepted.
public enum ImageDecoder {
    /// Bytes of an image as `data:[<mediatype>][;base64],<data>` carries
    /// them. The media type is not consulted: `ImageIO` sniffs the format.
    static func data(fromDataURI uri: String) throws(BridgeError) -> Data {
        guard uri.hasPrefix("data:") else {
            throw .unsupported("image_url must be a data: URI; this bridge does not fetch remote images")
        }
        guard let comma = uri.firstIndex(of: ",") else {
            throw .invalidRequest("image_url is not a valid data: URI", code: "invalid_image")
        }
        let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]
        let payload = uri[uri.index(after: comma)...]
        let bytes: Data?
        if header.split(separator: ";").contains("base64") {
            bytes = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters)
        } else {
            bytes = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let bytes, !bytes.isEmpty else {
            throw .invalidRequest("image_url data could not be decoded", code: "invalid_image")
        }
        return bytes
    }

    /// The attachment for one `image_url`, oriented as the file says.
    public static func attachment(from url: String) throws(BridgeError) -> Transcript.ImageAttachment {
        let bytes = try data(fromDataURI: url)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw .invalidRequest("image_url data is not an image ImageIO can read", code: "invalid_image")
        }
        // EXIF orientation, so a phone photo is not read sideways. Absent
        // (the common case for screenshots and plots) the framework
        // assumes `.up`.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:))
        return Transcript.ImageAttachment(image, orientation: orientation)
    }
}
