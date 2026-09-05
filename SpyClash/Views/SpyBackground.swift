import SwiftUI

struct SpyBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                SpyTheme.black

                if InterfacePreferences.shared.settings.backgroundEffects {
                    layoutAmbient(size: size)
                    pageAmbient(size: size)
                    gridLayer(size: size)
                    scanlines(size: size)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func layoutAmbient(size: CGSize) -> some View {
        ZStack {
            RadialGradient(
                colors: [
                    SpyTheme.red.opacity(0.04),
                    .clear
                ],
                center: UnitPoint(x: 0.20, y: 0.50),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.60
            )

            RadialGradient(
                colors: [
                    Color(red: 100 / 255, green: 100 / 255, blue: 150 / 255).opacity(0.03),
                    .clear
                ],
                center: UnitPoint(x: 0.80, y: 0.20),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.50
            )
        }
        .allowsHitTesting(false)
    }

    private func pageAmbient(size: CGSize) -> some View {
        ZStack {
            RadialGradient(
                colors: [
                    SpyTheme.red.opacity(0.07),
                    .clear
                ],
                center: UnitPoint(x: 0.30, y: 0.40),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.55
            )

            RadialGradient(
                colors: [
                    Color(red: 100 / 255, green: 100 / 255, blue: 200 / 255).opacity(0.04),
                    .clear
                ],
                center: UnitPoint(x: 0.70, y: 0.60),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.55
            )
        }
        .allowsHitTesting(false)
    }

    private func gridLayer(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let spacing: CGFloat = 50
            var path = Path()

            stride(from: CGFloat.zero, through: canvasSize.width, by: spacing).forEach { x in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: canvasSize.height))
            }

            stride(from: CGFloat.zero, through: canvasSize.height, by: spacing).forEach { y in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvasSize.width, y: y))
            }

            context.stroke(path, with: .color(SpyTheme.red.opacity(0.032)), lineWidth: 1)
        }
        .mask {
            RadialGradient(
                stops: [
                    .init(color: .black, location: 0.20),
                    .init(color: .clear, location: 0.75)
                ],
                center: .center,
                startRadius: min(size.width, size.height) * 0.20,
                endRadius: max(size.width, size.height) * 0.75
            )
        }
        .allowsHitTesting(false)
    }

    private func scanlines(size: CGSize) -> some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            SpyTheme.red.opacity(0.08),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .offset(y: -size.height * 0.22)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            SpyTheme.red.opacity(0.055),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 1)
                .offset(x: size.width * 0.26)
        }
        .allowsHitTesting(false)
    }

}

struct PageChrome<Content: View>: View {
    @Environment(AppState.self) private var appState
    @SpyReduceMotion private var reduceMotion

    let eyebrow: String
    let status: String
    let showsPageTopEdge: Bool
    let topReserve: CGFloat
    let scrollTarget: String?
    @ViewBuilder var content: Content

    init(
        eyebrow: String,
        status: String,
        showsPageTopEdge: Bool = true,
        topReserve: CGFloat = 80,
        scrollTarget: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.status = status
        self.showsPageTopEdge = showsPageTopEdge
        self.topReserve = topReserve
        self.scrollTarget = scrollTarget
        self.content = content()
    }

    private var bottomContentPadding: CGFloat { 28 }

    var body: some View {
        GeometryReader { _ in
            // AppShell content already begins below the system safe area.
            // The web Layout reserves only its 80px nav bar here.
            let topShellReserve = max(0, topReserve)

            ZStack {
                SpyBackground()
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: topShellReserve)

                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 0) {
                                if !eyebrow.isEmpty {
                                    SpyPageStatusLine(eyebrow: eyebrow, status: status)
                                        .spyWebEntrance(delay: 0.05, duration: 0.45, y: -10)
                                }

                                content
                                    .padding(.top, 6)
                                    .padding(.bottom, bottomContentPadding)
                            }
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: scrollTarget) { _, target in
                            scrollToTarget(target, proxy: proxy)
                        }
                        .overlay(alignment: .top) {
                            if showsPageTopEdge {
                                SpyPageTopEdge()
                            }
                        }
                    }
                }
            }
        }
    }

    private func scrollToTarget(_ target: String?, proxy: ScrollViewProxy) {
        guard let target else { return }
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }
}

typealias SpyPageChrome<Content: View> = PageChrome<Content>

struct SpyPageTopEdge: View {
    var body: some View {
        Color.clear.frame(height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct SpyPageStatusLine: View {
    let eyebrow: String
    let status: String

    var body: some View {
        HStack(spacing: 12) {
            Text(eyebrow)
                .foregroundStyle(SpyTheme.faint)

            HStack(spacing: 6) {
                Circle()
                    .fill(SpyTheme.red)
                    .frame(width: 6, height: 6)

                Text(status)
                    .foregroundStyle(SpyTheme.red)
            }
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .tracking(3)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .frame(maxWidth: .infinity)
        .frame(height: 34, alignment: .top)
        .padding(.top, 14)
        .accessibilityElement(children: .combine)
    }
}

struct AnimatedTitle: View {
    @SpyReduceMotion private var reduceMotion
    @State private var isVisible = false

    let text: String
    var redPrefixCount = 0
    var delay: Double = 0.20
    var fontSize: CGFloat = 36
    var letterSpacing: CGFloat = 3

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                SpyAnimatedTitleGlyph(
                    character: character,
                    index: index,
                    color: index < redPrefixCount ? SpyTheme.red : .white,
                    isVisible: isVisible,
                    reduceMotion: reduceMotion,
                    delay: delay
                )
            }
        }
        .font(SpyTheme.brandFont(size: fontSize))
        .tracking(letterSpacing)
        .minimumScaleFactor(0.62)
        .lineLimit(1)
        .task {
            guard !isVisible else { return }
            await Task.yield()
            isVisible = true
        }
    }
}

private struct SpyAnimatedTitleGlyph: View {
    let character: Character
    let index: Int
    let color: Color
    let isVisible: Bool
    let reduceMotion: Bool
    let delay: Double

    var body: some View {
        Text(String(character))
            .foregroundStyle(color)
            .shadow(color: color.opacity(0.24), radius: 8)
            .opacity(isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : 20)
            .rotation3DEffect(
                .degrees(reduceMotion || isVisible ? 0 : 90),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.7
            )
            .animation(reduceMotion ? nil : SpyMotion.titleGlyph(index: index, delay: delay), value: isVisible)
    }
}
