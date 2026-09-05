import SwiftUI

enum SpyLaserScanStyle {
    case home
    case onboarding
}

struct SpyLaserScanLayer: View {
    @Environment(\.scenePhase) private var scenePhase

    let style: SpyLaserScanStyle
    let reduceMotion: Bool

    init(style: SpyLaserScanStyle = .home, reduceMotion: Bool) {
        self.style = style
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        if InterfacePreferences.shared.settings.backgroundEffects {
            scanLayer
        }
    }

    private var scanLayer: some View {
        GeometryReader { proxy in
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 30.0,
                    paused: reduceMotion || scenePhase != .active
                )
            ) { timeline in
                let positions = scanPositions(at: timeline.date)

                ZStack(alignment: .topLeading) {
                    laserLine(horizontal: true)
                        .frame(width: proxy.size.width, height: lineContainerWidth)
                        .offset(y: proxy.size.height * positions.horizontal - (lineContainerWidth / 2))

                    laserLine(horizontal: false)
                        .frame(width: lineContainerWidth, height: proxy.size.height)
                        .offset(x: proxy.size.width * positions.vertical - (lineContainerWidth / 2))
                }
                .opacity(positions.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var lineContainerWidth: CGFloat {
        switch style {
        case .home:
            18
        case .onboarding:
            54
        }
    }

    private var blurRadius: CGFloat {
        switch style {
        case .home:
            0
        case .onboarding:
            10
        }
    }

    private var coreThickness: CGFloat {
        switch style {
        case .home:
            1
        case .onboarding:
            2.5
        }
    }

    private func scanPositions(at date: Date) -> (horizontal: CGFloat, vertical: CGFloat, opacity: Double) {
        if reduceMotion {
            return style == .home
                ? (horizontal: 0.5, vertical: 0.5, opacity: 0.425)
                : (horizontal: 0.28, vertical: 0.72, opacity: 0.38)
        }

        let absoluteTime = date.timeIntervalSinceReferenceDate

        switch style {
        case .home:
            let cycleDuration = 15.7
            let movementDuration = 8.4
            let cycleIndex = Int(floor(absoluteTime / cycleDuration))
            let routeSeed = cycleIndex &* 1_103_515_245 &+ 12_345
            let cycleTime = absoluteTime.truncatingRemainder(dividingBy: cycleDuration)
            let isMoving = cycleTime < movementDuration
            let progress = min(1, cycleTime / movementDuration)
            let edgeFade = min(1, min(progress / 0.08, (1 - progress) / 0.08))
            let horizontalProgress = routeSeed & 1 == 0 ? progress : 1 - progress
            let verticalProgress = routeSeed & 4 == 0 ? progress : 1 - progress

            return (
                horizontal: CGFloat(horizontalProgress),
                vertical: CGFloat(verticalProgress),
                opacity: isMoving ? 0.85 * edgeFade : 0
            )

        case .onboarding:
            let horizontalPhase = absoluteTime.truncatingRemainder(dividingBy: 12.8) / 12.8
            let verticalPhase = absoluteTime.truncatingRemainder(dividingBy: 16.4) / 16.4
            let horizontal = 0.5 - (0.5 * cos(horizontalPhase * .pi * 2))
            let vertical = 0.5 - (0.5 * cos((verticalPhase + 0.34) * .pi * 2))

            return (
                horizontal: CGFloat(horizontal),
                vertical: CGFloat(vertical),
                opacity: 0.82
            )
        }
    }

    private func laserLine(horizontal: Bool) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        .clear,
                        SpyTheme.red.opacity(style == .home ? 0.42 : 0.34),
                        SpyTheme.red.opacity(style == .home ? 1 : 0.96),
                        SpyTheme.red.opacity(style == .home ? 0.42 : 0.34),
                        .clear
                    ],
                    startPoint: horizontal ? .leading : .top,
                    endPoint: horizontal ? .trailing : .bottom
                )
            )
            .frame(
                maxWidth: horizontal ? .infinity : coreThickness,
                maxHeight: horizontal ? coreThickness : .infinity
            )
            .blur(radius: blurRadius)
            .shadow(color: SpyTheme.red.opacity(style == .home ? 0.48 : 0.42), radius: style == .home ? 3 : 9)
            .shadow(color: SpyTheme.red.opacity(style == .home ? 0.20 : 0.25), radius: style == .home ? 7 : 18)
    }
}
