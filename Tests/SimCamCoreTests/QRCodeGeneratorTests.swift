import XCTest

final class QRCodeGeneratorTests: XCTestCase {
    func testProducesNonEmptyImage() throws {
        let img = try XCTUnwrap(QRCodeGenerator.makeImage(payload: "AUTH_TOKEN_XYZ", size: 256))
        XCTAssertEqual(img.width, 256)
        XCTAssertEqual(img.height, 256)
    }

    func testEmptyPayloadStillEncodes() {
        // QR encoder accepts empty data; we just ensure no crash and a CGImage is produced.
        let img = QRCodeGenerator.makeImage(payload: "", size: 128)
        XCTAssertNotNil(img)
    }
}
