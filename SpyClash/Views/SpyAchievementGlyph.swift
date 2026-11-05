import SwiftUI

/// Original SpyClash insignia: angular line work with small solid stencil cuts.
/// The caller supplies color and size; no stock symbols or badge container are used.
struct SpyAchievementGlyph: View {
    let achievement: SpyAchievementID

    var body: some View {
        ZStack {
            SpyAchievementLinework(achievement: achievement)
                .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .square, lineJoin: .miter))
            SpyAchievementStencil(achievement: achievement)
                .fill()
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct SpyAchievementLinework: Shape {
    let achievement: SpyAchievementID

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func line(_ points: [(CGFloat, CGFloat)], closed: Bool = false) {
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.0, y: point.1))
            }
            if closed { path.closeSubpath() }
        }

        switch achievement {
        case .firstMission:
            // Dispatch dossier with a signal leaving its open corner.
            line([(9, 6), (23, 6), (29, 12), (29, 20)])
            line([(29, 29), (29, 34), (9, 34), (9, 6)])
            line([(23, 6), (23, 12), (29, 12)])
            line([(14, 17), (21, 17)])
            line([(14, 22), (19, 22)])
            line([(20, 29), (34, 15)])
            line([(27, 15), (34, 15), (34, 22)])
        case .fieldAgent:
            // Split shield, tapered like the application's clipped panels.
            line([(20, 5), (32, 10), (29, 25), (20, 35), (11, 25), (8, 10)], closed: true)
            line([(14, 15), (20, 11), (26, 15)])
            line([(14, 15), (15, 23), (20, 29)])
            line([(26, 15), (25, 23), (20, 29)])
        case .veteran:
            // Command star over three deliberately separated rank chevrons.
            line([(20, 4), (22.5, 10), (29, 12), (22.5, 14), (20, 20), (17.5, 14), (11, 12), (17.5, 10)], closed: true)
            line([(10, 22), (20, 26), (30, 22)])
            line([(10, 27), (20, 31), (30, 27)])
            line([(13, 33), (20, 36), (27, 33)])
        case .firstVictory:
            // A mission has been crossed off, not a generic winner's trophy.
            line([(10, 6), (25, 6), (31, 12), (31, 34), (10, 34)], closed: true)
            line([(25, 6), (25, 12), (31, 12)])
            line([(15, 22), (19, 26), (27, 17)])
            line([(15, 11), (20, 11)])
        case .winningRecord:
            // Broken laurel and a two-tier operational mark.
            line([(10, 7), (6, 15), (7, 25), (14, 33)])
            line([(30, 7), (34, 15), (33, 25), (26, 33)])
            line([(6, 15), (12, 17)])
            line([(7, 25), (13, 25)])
            line([(34, 15), (28, 17)])
            line([(33, 25), (27, 25)])
            line([(14, 15), (20, 9), (26, 15)])
            line([(14, 23), (20, 17), (26, 23)])
            line([(17, 31), (23, 31)])
        case .ghost:
            // Hooded operative, with the bottom edge dissolving into cuts.
            line([(10, 30), (10, 17), (14, 9), (20, 5), (26, 9), (30, 17), (30, 30)])
            line([(10, 30), (15, 27), (20, 32), (25, 27), (30, 30)])
            line([(13, 16), (20, 13), (27, 16)])
            line([(14, 23), (20, 26), (26, 23)])
        case .masterOfDisguise:
            // Wide, asymmetric masquerade mask; the two halves do not match.
            line([(5, 12), (14, 9), (20, 12), (26, 9), (35, 12), (32, 24), (26, 30), (20, 26), (14, 30), (8, 24)], closed: true)
            line([(20, 12), (18, 20), (21, 23)])
            line([(11, 25), (14, 26)])
            line([(26, 26), (29, 22)])
        case .sharpEye:
            // An angular eye with interrupted targeting lines.
            line([(5, 20), (12, 13), (20, 10), (28, 13), (35, 20), (28, 27), (20, 30), (12, 27)], closed: true)
            line([(20, 14), (26, 20), (20, 26), (14, 20)], closed: true)
            line([(20, 4), (20, 7)])
            line([(20, 33), (20, 36)])
            line([(2, 20), (7, 20)])
            line([(33, 20), (38, 20)])
        case .caseClosed:
            // Sealed intelligence case: clipped corners and central clasp.
            line([(6, 13), (30, 13), (34, 17), (34, 32), (10, 32), (6, 28)], closed: true)
            line([(14, 13), (14, 8), (26, 8), (26, 13)])
            line([(6, 21), (14, 21)])
            line([(26, 21), (34, 21)])
            line([(17, 18), (23, 18), (23, 25), (17, 25)], closed: true)
        case .doubleAgent:
            // Back-to-back profiles: one looking out, one looking in.
            line([(17, 7), (11, 7), (7, 12), (7, 18), (4, 22), (9, 23), (9, 28), (17, 28), (17, 34)])
            line([(23, 7), (29, 7), (33, 12), (33, 18), (36, 22), (31, 23), (31, 28), (23, 28), (23, 34)])
            line([(20, 10), (20, 16)])
            line([(20, 23), (20, 29)])
        case .loyalty3, .loyalty6, .loyalty12:
            // Interlocking angular links form the Loyalty family; the stencil
            // beneath the knot marks its first, second, or third tier.
            line([(19, 10), (12, 6), (5, 10), (5, 20), (12, 24), (19, 20), (19, 16)])
            line([(21, 20), (28, 24), (35, 20), (35, 10), (28, 6), (21, 10), (21, 14)])
            line([(13, 15), (27, 15)])
        }

        let scale = min(rect.width, rect.height) / 40
        return path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.midX - 20 * scale, y: rect.midY - 20 * scale)))
    }
}

private struct SpyAchievementStencil: Shape {
    let achievement: SpyAchievementID

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func cut(_ points: [(CGFloat, CGFloat)]) {
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.0, y: point.1))
            }
            path.closeSubpath()
        }

        switch achievement {
        case .fieldAgent:
            cut([(19, 15), (21, 15), (21, 25), (20, 27), (19, 25)])
        case .ghost:
            cut([(13, 18), (18, 19), (18, 21), (14, 21)])
            cut([(27, 18), (22, 19), (22, 21), (26, 21)])
        case .masterOfDisguise:
            cut([(9, 16), (16, 17), (15, 21), (11, 20)])
            cut([(24, 17), (31, 15), (29, 20), (25, 21)])
        case .sharpEye:
            cut([(20, 17), (23, 20), (20, 23), (17, 20)])
        case .doubleAgent:
            cut([(10, 15), (15, 16), (15, 18), (10, 18)])
            cut([(30, 15), (25, 16), (25, 18), (30, 18)])
        case .loyalty3, .loyalty6, .loyalty12:
            let rank = achievement == .loyalty3 ? 1 : (achievement == .loyalty6 ? 2 : 3)
            for index in 0..<rank {
                let x = 20 + CGFloat(index) * 6 - CGFloat(rank - 1) * 3
                cut([(x - 1, 29), (x + 1, 29), (x + 1, 35), (x - 1, 35)])
            }
        case .firstMission, .veteran, .firstVictory, .winningRecord, .caseClosed:
            break
        }

        let scale = min(rect.width, rect.height) / 40
        return path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.midX - 20 * scale, y: rect.midY - 20 * scale)))
    }
}
