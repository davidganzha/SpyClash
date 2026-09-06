import XCTest
import Vision
import UIKit
@testable import SpyClash

final class QRScannerTests: XCTestCase {
    func testUnrelatedQRDoesNotStopSubsequentRoomRecognition() {
        var received: [String] = []
        let scanner = QRScannerRepresentable.Coordinator(isScanningEnabled: true) { received.append($0) }
        scanner.receivePayloads(["https://example.com/menu"])
        scanner.receivePayloads(["https://example.com/menu"])
        XCTAssertTrue(scanner.isScanningEnabled)
        scanner.receivePayloads(["spyclash://join/ABC123"])
        XCTAssertEqual(received.last, "spyclash://join/ABC123")
        XCTAssertFalse(scanner.isScanningEnabled)
        scanner.receivePayloads(["spyclash://join/ABC123"])
        XCTAssertEqual(received.count, 3, "A valid QR submits only one join while it is in flight")
        scanner.isScanningEnabled = true
        scanner.receivePayloads(["spyclash://join/ABC123"])
        XCTAssertEqual(received.count, 4, "A failed join can re-enable the scanner")
    }

    func testRoomQRWinsOverUnrelatedCodeInSameCameraFrame() {
        var received: [String] = []
        let scanner = QRScannerRepresentable.Coordinator(isScanningEnabled: true) { received.append($0) }
        scanner.receivePayloads(["https://example.com/?code=MENU12", "https://spyclash.com/?join=ABC123"])
        XCTAssertEqual(received, ["https://spyclash.com/?join=ABC123"])
    }

    func testQueuedCameraFramesCannotJoinWhileCaptureIsInactive() {
        var received: [String] = []
        let scanner = QRScannerRepresentable.Coordinator(isScanningEnabled: true) { received.append($0) }
        scanner.receivePayloads(["https://example.com/menu"])
        scanner.isCaptureActive = false
        scanner.receivePayloads(["spyclash://join/ABC123"])
        scanner.receivePayloads(["https://example.com/menu"])
        XCTAssertEqual(received, ["https://example.com/menu"])
        XCTAssertTrue(scanner.isScanningEnabled)
        scanner.isCaptureActive = true
        scanner.receivePayloads(["spyclash://join/ABC123"])
        XCTAssertEqual(received.last, "spyclash://join/ABC123")
        XCTAssertFalse(scanner.isScanningEnabled)
    }

    func testForegroundingDoesNotResubmitAJoinAlreadyInFlight() {
        var received: [String] = []
        let scanner = QRScannerRepresentable.Coordinator(isScanningEnabled: true) { received.append($0) }
        scanner.receivePayloads(["spyclash://join/ABC123"])
        scanner.isCaptureActive = false
        scanner.isCaptureActive = true
        scanner.receivePayloads(["spyclash://join/ABC123"])
        XCTAssertEqual(received.count, 1)
        scanner.isScanningEnabled = true
        scanner.isCaptureActive = false
        scanner.receivePayloads(["spyclash://join/ABC123"])
        XCTAssertEqual(received.count, 1, "A late failed-join redraw cannot reactivate a dismissed camera")
    }

    func testCameraRejectsMalformedAndForeignRoomLinks() {
        XCTAssertNil(SpyLinkParser.scannedRoomCode(from: "https://example.com/?join=ABC123"))
        XCTAssertNil(SpyLinkParser.scannedRoomCode(from: "spyclash://join/AB-C123"))
        XCTAssertEqual(SpyLinkParser.scannedRoomCode(from: "spyclash://join?code=ABC123"), "ABC123")
        XCTAssertEqual(SpyLinkParser.scannedRoomCode(from: "https://spyclash.com/#/Home?join=ABC123"), "ABC123")
        XCTAssertEqual(SpyLinkParser.scannedRoomCode(from: "ABC123"), "ABC123")
    }

    @MainActor
    func testRenderedRoomCodesDecodeAtDisplayedSizeAfterRotation() throws {
        let payloads = [
            "spyclash://join/ABC123",
            "https://spyclash.com/?join=ABC123&target=ios",
            "https://spyclash.base44.app/?join=ABC123"
        ]
        for payload in payloads {
            let code = QRCodeFactory.image(from: payload)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let photographed = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320), format: format).image { context in
                UIColor.darkGray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
                context.cgContext.translateBy(x: 160, y: 160)
                context.cgContext.rotate(by: .pi / 12)
                context.cgContext.interpolationQuality = .none
                code.draw(in: CGRect(x: -112, y: -112, width: 224, height: 224))
            }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            // Simulator has no camera/Neural Engine; the first CPU barcode
            // decoder exercises the actual rendered pixels deterministically.
            request.revision = VNDetectBarcodesRequestRevision1
            request.usesCPUOnly = true
            try VNImageRequestHandler(cgImage: XCTUnwrap(photographed.cgImage)).perform([request])
            XCTAssertEqual(request.results?.first?.payloadStringValue, payload)
        }
    }
}
