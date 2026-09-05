import CoreGraphics

enum InterfaceScalePolicy {
    static let range = 1.0...1.2
    static let step = 0.05

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func logicalSize(viewport: CGSize, scale: Double) -> CGSize {
        let factor = clamped(scale)
        return CGSize(width: max(0, viewport.width) / factor, height: max(0, viewport.height) / factor)
    }
}
