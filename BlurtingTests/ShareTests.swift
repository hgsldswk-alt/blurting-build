import CoreImage
import ImageIO
import XCTest

final class ShareTests: XCTestCase {
    @MainActor
    func testSharePNGIs1080By1440AndContainsScannableDirectQRCode() throws {
        let link = DownloadLink.url(appStoreID: "1234567890")
        XCTAssertEqual(link.absoluteString, "https://apps.apple.com/app/id1234567890")
        XCTAssertEqual(DownloadLink.url(appStoreID: "").absoluteString, "https://apps.apple.com/")
        let qr = try XCTUnwrap(ShareArtwork.qr(for: link))
        for content: ShareContent in [.score(85), .milestone(.streak), .milestone(.fifty)] {
            let data = try XCTUnwrap(ShareArtwork.png(content: content, qr: qr))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 1080)
            XCTAssertEqual(image.height, 1440)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
            XCTAssertNil(properties[kCGImagePropertyIPTCDictionary])
            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal])
                XCTAssertNil(exif[kCGImagePropertyExifLensModel])
            }

            let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                                                   options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
            XCTAssertEqual(features.compactMap(\.messageString), [link.absoluteString])
        }
    }
}
