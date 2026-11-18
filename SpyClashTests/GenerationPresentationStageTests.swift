import CoreText
import SwiftUI
import XCTest
@testable import SpyClash

@MainActor
final class GenerationPresentationStageTests: XCTestCase {
    func testBundledGameFacesRenderAllSupportedAlphabetsWithoutFontFallback() throws {
        let alphabet = "АБВГҐДЕЁЄЖЗИІЇЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
        let sample = alphabet + alphabet.lowercased() + " ABCxyz 0123456789 áéíóúüñÁÉÍÓÚÜÑ ¿¡+1 → · … 00:00 / «’» – — 12\u{202F}AM"
        for weight: Font.Weight in [.regular, .semibold, .bold] {
            let name = SpyTheme.gameFontName(weight: weight)
            let font = try XCTUnwrap(UIFont(name: name, size: 17))
            XCTAssertEqual(font.fontName, name)
            XCTAssertEqual(fontsRendering(sample, font: font), [name])
        }
        let counter = try XCTUnwrap(UIFont(name: "Rajdhani-Bold", size: 34))
        XCTAssertEqual(fontsRendering("LIMITLESS +1234567890", font: counter), [counter.fontName])
    }

    private func fontsRendering(_ text: String, font: UIFont) -> Set<String> {
        let string = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(string)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        return Set(runs.map { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let resolved = attributes[kCTFontAttributeName] as! CTFont
            return CTFontCopyPostScriptName(resolved) as String
        })
    }

    func testCreativeStartsOnBlackAndConsentKeepsItsOwnScreen() throws {
        let waiting = try frame(.preparing)
        let handoff = try frame(.readyToPresent)
        let showing = try frame(.presenting, confirmedAttempt: UUID())
        let consent = try frame(.requestingConsent)
        let confirmed = try frame(.idle, confirmedAttempt: UUID())
        let idle = try frame(.idle)

        XCTAssertLessThan(try visiblePixels(handoff), 5)
        XCTAssertLessThan(try visiblePixels(showing), 5, "An early confirmation must stay behind the SDK")
        XCTAssertGreaterThan(try visiblePixels(waiting), 30)
        XCTAssertGreaterThan(try visiblePixels(confirmed), 30)
        XCTAssertEqual(try visiblePixels(consent), try visiblePixels(idle))
        XCTAssertGreaterThan(try visiblePixels(consent), 6_000)
        for (name, frame) in [("generation-preparing", waiting), ("generation-confirmed", confirmed)] {
            let attachment = XCTAttachment(image: frame)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func frame(_ phase: GenerationRewardPresentationPhase, confirmedAttempt: UUID? = nil) throws -> UIImage {
        let renderer = ImageRenderer(content:
            Color.blue.overlay {
                GenerationPresentationStage(phase: phase, confirmedAttempt: confirmedAttempt,
                                            copy: .init(language: .ru), cancel: {}, dismiss: { _ in })
            }
            .frame(width: 393, height: 852)
        )
        renderer.scale = 2
        return try XCTUnwrap(renderer.uiImage)
    }

    private func visiblePixels(_ image: UIImage) throws -> Int {
        let size = 96
        var colors = [UInt8](repeating: 0, count: size * size * 4)
        let cgImage = try XCTUnwrap(image.cgImage)
        try colors.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: size, height: size,
                                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        return stride(from: 0, to: colors.count, by: 4).reduce(into: 0) { count, index in
            if colors[index...index + 2].max() ?? 0 > 35 { count += 1 }
        }
    }
}
