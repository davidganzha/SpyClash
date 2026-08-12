import SwiftUI
import UIKit

enum SpyTheme {
    static let red = Color(red: 229 / 255, green: 53 / 255, blue: 53 / 255)
    static let redHot = red
    static let redDeep = Color(red: 204 / 255, green: 32 / 255, blue: 32 / 255)
    static let green = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255)
    static let amber = Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)
    static let black = Color(red: 0, green: 0, blue: 0)
    static let dark = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
    static let control = Color(red: 13 / 255, green: 13 / 255, blue: 13 / 255)
    static let card = Color(red: 15 / 255, green: 15 / 255, blue: 15 / 255)
    static let graphite = dark
    static let graphiteElevated = card
    static let panel = card
    static let panelDeep = dark
    static let stroke = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let inputBorder = Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255)
    static let strokeStrong = Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255)
    static let strokeDim = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
    static let text = Color.white
    static let bodyText = Color(red: 204 / 255, green: 204 / 255, blue: 204 / 255)
    static let muted = Color(red: 102 / 255, green: 102 / 255, blue: 102 / 255)
    static let dim = Color(red: 85 / 255, green: 85 / 255, blue: 85 / 255)
    static let faint = Color(red: 68 / 255, green: 68 / 255, blue: 68 / 255)

    static let title = Font.system(size: 42, weight: .black, design: .default)
    static let section = Font.system(size: 22, weight: .bold, design: .default)
    static let mono = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let micro = Font.system(size: 11, weight: .bold, design: .monospaced)

    static func brandFont(size: CGFloat) -> Font {
        .custom("Rajdhani-Bold", size: size)
    }

    static var commandRedGradient: LinearGradient {
        LinearGradient(
            colors: [red, red],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var commandRedStroke: LinearGradient {
        LinearGradient(
            colors: [
                red,
                red
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum SpyMotion {
    static let page = Animation.easeInOut(duration: 0.22)
    static let press = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.20)
    static let authStep = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.32)

    static func entrance(delay: Double = 0, duration: Double = 0.50) -> Animation {
        .timingCurve(0.22, 0.61, 0.36, 1, duration: duration)
        .delay(delay)
    }

    static func titleGlyph(index: Int, delay: Double = 0.20) -> Animation {
        .timingCurve(0.34, 1.56, 0.64, 1, duration: 0.45)
        .delay(delay + (Double(index) * 0.04))
    }

    static func heroGlyph(index: Int) -> Animation {
        .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.90)
        .delay(Double(index) * 0.12)
    }
}

private struct SpyEntranceMotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private struct SpyEntrancePresentationActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var spyEntranceMotionEnabled: Bool {
        get { self[SpyEntranceMotionEnabledKey.self] }
        set { self[SpyEntranceMotionEnabledKey.self] = newValue }
    }

    var spyEntrancePresentationActive: Bool {
        get { self[SpyEntrancePresentationActiveKey.self] }
        set { self[SpyEntrancePresentationActiveKey.self] = newValue }
    }
}

struct SpyWebPressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.98

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? pressedScale : 1))
            .animation(reduceMotion ? nil : SpyMotion.press, value: configuration.isPressed)
    }
}

private struct SpyWebEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.spyEntranceMotionEnabled) private var entranceMotionEnabled
    @Environment(\.spyEntrancePresentationActive) private var entrancePresentationActive
    @State private var isVisible = false

    let delay: Double
    let duration: Double
    let x: CGFloat
    let y: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        let shouldPresent = entranceMotionEnabled && entrancePresentationActive

        content
            .opacity(isVisible ? 1 : 0)
            .offset(
                x: reduceMotion || isVisible ? 0 : x,
                y: reduceMotion || isVisible ? 0 : y
            )
            .scaleEffect(reduceMotion || isVisible ? 1 : scale)
            .task(id: shouldPresent) {
                guard shouldPresent else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        isVisible = false
                    }
                    return
                }
                guard !isVisible else { return }
                await Task.yield()
                if reduceMotion {
                    isVisible = true
                } else {
                    withAnimation(SpyMotion.entrance(delay: delay, duration: duration)) {
                        isVisible = true
                    }
                }
            }
    }
}

extension View {
    func spyWebEntrance(
        delay: Double = 0,
        duration: Double = 0.50,
        x: CGFloat = 0,
        y: CGFloat = 20,
        scale: CGFloat = 1
    ) -> some View {
        modifier(SpyWebEntranceModifier(delay: delay, duration: duration, x: x, y: y, scale: scale))
    }
}

struct SpyWordmark: View {
    var fontSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 2) {
            Text("SPY")
                .foregroundStyle(SpyTheme.red)
            Text("CLASH")
                .foregroundStyle(.white)
        }
        .font(SpyTheme.brandFont(size: fontSize))
        .tracking(3)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("SpyClash")
    }
}

struct SpyBrandMark: View {
    var body: some View {
        Image("SpyClashLogo")
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

struct SpyButtonStyle: ButtonStyle {
    enum Variant {
        case red
        case outline
        case ghost
    }

    let variant: Variant

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .black, design: .monospaced))
            .tracking(0.12)
            .textCase(.uppercase)
            .lineLimit(2)
            .minimumScaleFactor(0.66)
            .allowsTightening(true)
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(background)
            .overlay(border)
            .clipShape(CutCornerShape(cut: 8))
            .contentShape(CutCornerShape(cut: 8))
            .shadow(color: shadow.opacity(configuration.isPressed ? 0.10 : 0.20), radius: configuration.isPressed ? 6 : 14, y: configuration.isPressed ? 2 : 7)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
            .animation(reduceMotion ? nil : SpyMotion.press, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch variant {
        case .red: .white
        case .outline: SpyTheme.red
        case .ghost: SpyTheme.muted
        }
    }

    @ViewBuilder
    private var background: some View {
        switch variant {
        case .red:
            SpyTheme.red
        case .outline:
            Color.clear
        case .ghost:
            Color.clear
        }
    }

    @ViewBuilder
    private var border: some View {
        switch variant {
        case .red:
            CutCornerShape(cut: 8)
                .stroke(Color.clear, lineWidth: 1)
        case .outline:
            CutCornerShape(cut: 8)
                .stroke(SpyTheme.red, lineWidth: 1)
        case .ghost:
            CutCornerShape(cut: 8)
                .stroke(SpyTheme.strokeDim, lineWidth: 1)
        }
    }

    private var shadow: Color {
        switch variant {
        case .red: SpyTheme.red
        case .outline: SpyTheme.red
        case .ghost: .black
        }
    }
}

struct SpyActionLabel: View {
    let title: String
    let systemImage: String
    var fontSize: CGFloat = 12
    var iconSize: CGFloat = 15
    var tracking: CGFloat = 0.08
    var lines: Int = 2

    var body: some View {
            HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .black))
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: fontSize, weight: .black, design: .monospaced))
                .tracking(resolvedTracking)
                .lineLimit(lines)
                .minimumScaleFactor(resolvedScale)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .layoutPriority(1)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var resolvedTracking: CGFloat {
        let count = title.count
        if count >= 20 { return min(tracking, 0.0) }
        if count >= 14 { return min(tracking, 0.02) }
        if count >= 10 { return min(tracking, 0.05) }
        return min(tracking, 0.08)
    }

    private var resolvedScale: CGFloat {
        title.count >= 22 ? 0.58 : 0.66
    }
}

extension View {
    func spyFitted(lines: Int = 1, scale: CGFloat = 0.62, alignment: TextAlignment = .leading) -> some View {
        self
            .lineLimit(lines)
            .minimumScaleFactor(scale)
            .allowsTightening(true)
            .multilineTextAlignment(alignment)
    }

    func spyCompactLabel(lines: Int = 2, alignment: TextAlignment = .center) -> some View {
        self
            .lineLimit(lines)
            .minimumScaleFactor(0.66)
            .allowsTightening(true)
            .multilineTextAlignment(alignment)
    }

    func spyKicker(lines: Int = 1, alignment: TextAlignment = .leading) -> some View {
        self
            .lineLimit(lines)
            .minimumScaleFactor(0.66)
            .allowsTightening(true)
            .multilineTextAlignment(alignment)
    }

    func spyHitTarget(minSize: CGFloat = 44) -> some View {
        self
            .frame(minWidth: minSize, minHeight: minSize)
            .contentShape(Rectangle())
    }
}

struct CutCornerShape: Shape {
    var cut: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cut))
        path.closeSubpath()
        return path
    }
}

struct SpyPanel<Content: View>: View {
    var accent: Color = SpyTheme.red
    var motionDelay: Double = 0.08
    var animatesEntrance = true
    @ViewBuilder var content: Content

    @ViewBuilder
    var body: some View {
        if animatesEntrance {
            panelSurface
                .spyWebEntrance(delay: motionDelay, duration: 0.50, y: 20)
        } else {
            panelSurface
        }
    }

    private var panelSurface: some View {
        content
            .padding(18)
            .background(SpyTheme.panel, in: CutCornerShape(cut: 12))
            .overlay(
                CutCornerShape(cut: 12)
                    .stroke(
                        LinearGradient(
                            colors: [
                                SpyTheme.stroke,
                                SpyTheme.stroke,
                                SpyTheme.stroke
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(alignment: .topLeading) {
                CornerStroke(color: accent.opacity(0.9))
                    .padding(1)
            }
            .overlay(alignment: .bottomTrailing) {
                CornerStroke(color: accent.opacity(0.9))
                    .rotationEffect(.degrees(180))
                    .padding(1)
            }
            .shadow(color: accent.opacity(0.08), radius: 18)
            .shadow(color: .black.opacity(0.30), radius: 20, y: 10)
    }
}

enum SpyLobbyVisualLanguage {
    static let maxWidth: CGFloat = 480
    static let sectionSpacing: CGFloat = 14
    static let heroHeight: CGFloat = 270

    enum EntranceDelay {
        static let mission = 0.0
        static let hero = mission
        static let mode = 0.04
        static let roles = 0.06
        static let timing = 0.08
        static let players = 0.12
        static let intel = 0.16
        static let controls = 0.20
    }
}

struct SpyLobbyPanel<Content: View>: View {
    let accent: Color
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    @ViewBuilder var content: Content

    init(
        accent: Color = SpyTheme.muted,
        horizontalPadding: CGFloat = 24,
        verticalPadding: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) {
        self.accent = accent
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(SpyTheme.panel, in: CutCornerShape(cut: 12))
            .overlay(CutCornerShape(cut: 12).stroke(SpyTheme.stroke, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(accent.opacity(0.88))
                    .frame(width: 34, height: 3)
                    .padding(.top, 1)
                    .padding(.leading, horizontalPadding)
            }
            .shadow(color: accent.opacity(0.06), radius: 14)
            .shadow(color: .black.opacity(0.30), radius: 18, y: 9)
    }
}

struct SpyLobbySectionHeader: View {
    let systemImage: String
    let title: String

    init(systemImage: String, title: String) {
        self.systemImage = systemImage
        self.title = title
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(SpyTheme.dim)
                .frame(width: 16)

            Text(title)
                .font(SpyTheme.micro)
                .tracking(0.08)
                .foregroundStyle(SpyTheme.muted)
                .spyFitted(lines: 2, scale: 0.68)
        }
    }
}

struct SpyLobbyModeChoice: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let symbol: String
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    init(
        symbol: String,
        title: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.title = title
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Text(symbol)
                    .font(.system(size: symbol == "?" ? 22 : 20, weight: .black, design: .default))
                    .foregroundStyle(isSelected ? .white.opacity(0.82) : SpyTheme.dim)

                Text(title)
                    .font(.system(size: 11, weight: .black, design: .default))
                    .tracking(title.count > 10 ? 0 : 0.08)
                    .foregroundStyle(isSelected ? .white : SpyTheme.muted)
                    .spyFitted(lines: 2, scale: 0.62, alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 82)
            .background(isSelected ? SpyTheme.red : Color.clear, in: CutCornerShape(cut: 9))
            .overlay(
                CutCornerShape(cut: 9)
                    .stroke(isSelected ? SpyTheme.red : SpyTheme.stroke, lineWidth: 1)
            )
            .contentShape(CutCornerShape(cut: 9))
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(!isEnabled || isSelected)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct SpyLobbyHeroSurface<Content: View>: View {
    let accent: Color
    @ViewBuilder var content: Content

    init(
        accent: Color = SpyTheme.red,
        @ViewBuilder content: () -> Content
    ) {
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: SpyLobbyVisualLanguage.heroHeight)
            .background(SpyTheme.panel, in: CutCornerShape(cut: 12))
            .overlay(CutCornerShape(cut: 12).stroke(SpyTheme.stroke, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(accent.opacity(0.92))
                    .frame(width: 34, height: 3)
                    .padding(.top, 1)
                    .padding(.leading, 18)
            }
            .shadow(color: accent.opacity(0.06), radius: 14)
            .shadow(color: .black.opacity(0.30), radius: 18, y: 9)
    }
}

struct SpyLobbyHeroHeader: View {
    let title: String
    let status: String?
    let count: Int?
    let accent: Color
    let statusAccent: Color?

    init(
        title: String,
        status: String? = nil,
        count: Int? = nil,
        accent: Color = SpyTheme.red,
        statusAccent: Color? = nil
    ) {
        self.title = title
        self.status = status
        self.count = count
        self.accent = accent
        self.statusAccent = statusAccent
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("//")
                .foregroundStyle(accent)
            Text(title)
                .foregroundStyle(Color.white.opacity(0.56))

            Spacer(minLength: 8)

            if let status {
                Circle()
                    .fill(resolvedStatusAccent)
                    .frame(width: 7, height: 7)
                    .shadow(color: resolvedStatusAccent.opacity(0.42), radius: 5)
                Text(status)
                    .foregroundStyle(Color.white.opacity(0.52))
            }

            if let count {
                Text(String(format: "%02d", count))
                    .foregroundStyle(Color.white.opacity(0.90))
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 9, weight: .black, design: .monospaced))
        .tracking(0.08)
    }

    private var resolvedStatusAccent: Color {
        statusAccent ?? accent
    }
}

struct SpyLobbyFooter<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background {
            Color.black
                .opacity(0.97)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [SpyTheme.red.opacity(0.75), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .shadow(color: .black.opacity(0.48), radius: 16, y: -5)
    }
}

struct SpyLobbyActionRow<Leading: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                leading
                trailing
            }
        } else {
            HStack(spacing: 8) {
                leading
                trailing
            }
        }
    }
}

struct SpyLobbyFooterPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .offset(y: configuration.isPressed ? 1 : 0)
            .brightness(configuration.isPressed ? 0.035 : 0)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

struct SpyLobbySecondaryActionLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let systemImage: String
    let accessorySystemImage: String?
    let accent: Color

    init(
        title: String,
        systemImage: String,
        accessorySystemImage: String? = nil,
        accent: Color = SpyTheme.red
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessorySystemImage = accessorySystemImage
        self.accent = accent
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(accent)
                .frame(width: 19)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 11 : 9, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.80 : 0.58)

            Spacer(minLength: 0)

            if let accessorySystemImage {
                Image(systemName: accessorySystemImage)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white.opacity(0.58))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 72 : 58)
        .background(
            LinearGradient(
                colors: [accent.opacity(0.14), Color.white.opacity(0.035)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: CutCornerShape(cut: 9)
        )
        .overlay(CutCornerShape(cut: 9).stroke(accent.opacity(0.62), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            CornerStroke(color: accent.opacity(0.84))
                .frame(width: 14, height: 14)
        }
        .shadow(color: accent.opacity(0.10), radius: 12, y: 4)
        .contentShape(CutCornerShape(cut: 9))
    }
}

struct SpyLobbyPrimaryActionLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let detail: String
    let systemImage: String
    let isAvailable: Bool

    init(
        title: String,
        detail: String,
        systemImage: String,
        isAvailable: Bool = true
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.isAvailable = isAvailable
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .black))
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 11 : 9, weight: .black, design: .monospaced))
                    .foregroundStyle(isAvailable ? .white : SpyTheme.red.opacity(0.48))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.78 : 0.52)
                    .contentTransition(.opacity)

                Text(detail)
                    .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 8.5 : 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(isAvailable ? Color.white.opacity(0.72) : SpyTheme.dim)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.76 : 0.50)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(isAvailable ? Color.white : SpyTheme.red.opacity(0.48))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 72 : 58)
        .background(
            isAvailable ? SpyTheme.red : SpyTheme.red.opacity(0.035),
            in: CutCornerShape(cut: 9)
        )
        .overlay(
            CutCornerShape(cut: 9)
                .stroke(SpyTheme.red.opacity(isAvailable ? 1 : 0.24), lineWidth: 1)
        )
        .shadow(
            color: isAvailable ? SpyTheme.red.opacity(0.18) : .clear,
            radius: 12,
            y: 4
        )
        .contentShape(CutCornerShape(cut: 9))
    }
}

struct SpyLobbySetupFocusEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let dimmed: Bool

    init(dimmed: Bool) {
        self.dimmed = dimmed
    }

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.20 : 1)
            .scaleEffect(dimmed ? 0.94 : 1)
            .blur(radius: dimmed ? 2 : 0)
            .allowsHitTesting(!dimmed)
            .animation(
                reduceMotion ? nil : .smooth(duration: dimmed ? 0.20 : 0.24),
                value: dimmed
            )
    }
}

struct SpyInput: View {
    enum Kind {
        case text
        case secure
    }

    var label: String?
    var placeholder: String
    @Binding var text: String
    var icon: String?
    var kind: Kind = .text
    var accent: Color = SpyTheme.red
    var isFocused = false
    var textContentType: UITextContentType?
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences
    var autocorrectionDisabled = true
    var height: CGFloat = 52
    var maxLength: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: label == nil ? 0 : 8) {
            if let label {
                Text(label)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker(lines: 2)
            }

            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(isFocused ? accent : SpyTheme.dim)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                }

                field
                    .font(SpyTheme.mono)
                    .tracking(0.04)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(SpyTheme.panelDeep, in: CutCornerShape(cut: 9))
            .overlay(
                CutCornerShape(cut: 9)
                    .stroke(isFocused ? accent : SpyTheme.inputBorder, lineWidth: 1)
            )
            .shadow(color: isFocused ? accent.opacity(0.20) : .clear, radius: 10)
            .animation(.smooth(duration: 0.18), value: isFocused)
        }
    }

    @ViewBuilder
    private var field: some View {
        switch kind {
        case .text:
            TextField("", text: boundedText, prompt: prompt)
                .textInputAutocapitalization(autocapitalization)
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .autocorrectionDisabled(autocorrectionDisabled)
        case .secure:
            SecureField("", text: boundedText, prompt: prompt)
                .textContentType(textContentType)
                .autocorrectionDisabled(autocorrectionDisabled)
        }
    }

    private var prompt: Text {
        Text(placeholder).foregroundStyle(SpyTheme.dim)
    }

    private var boundedText: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                guard let maxLength else {
                    text = newValue
                    return
                }
                text = newValue.boundedUnicodeScalars(maxLength)
            }
        )
    }
}

struct AIThemeSuggestionStrip: View {
    let language: AppLanguage
    let selectedTheme: String
    let accessibilityIdentifier: String
    let onSelect: (String) -> Void

    private struct Suggestion: Identifiable {
        let id: String
        let title: String
        let systemImage: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("// \(title)")
                    .foregroundStyle(SpyTheme.dim)

                Spacer(minLength: 8)

                Text(actionHint)
                    .foregroundStyle(SpyTheme.faint)
                    .multilineTextAlignment(.trailing)
            }
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .tracking(0.08)
            .lineLimit(1)
            .minimumScaleFactor(0.66)
            .accessibilityHidden(true)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(suggestions) { suggestion in
                        suggestionButton(suggestion)
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func suggestionButton(_ suggestion: Suggestion) -> some View {
        let isSelected = selectedTheme
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(suggestion.title) == .orderedSame

        return Button {
            HapticManager.shared.fire(.tabSelection)
            withAnimation(.smooth(duration: 0.18)) {
                onSelect(suggestion.title)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: suggestion.systemImage)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(isSelected ? SpyTheme.red : SpyTheme.dim)
                    .accessibilityHidden(true)

                Text(suggestion.title.uppercased())
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.04)
                    .foregroundStyle(isSelected ? .white : SpyTheme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 40)
            .background(
                isSelected ? SpyTheme.red.opacity(0.10) : SpyTheme.control,
                in: CutCornerShape(cut: 7)
            )
            .overlay(
                CutCornerShape(cut: 7)
                    .stroke(
                        isSelected ? SpyTheme.red.opacity(0.62) : SpyTheme.strokeStrong,
                        lineWidth: 1
                    )
            )
            .contentShape(CutCornerShape(cut: 7))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.94))
        .spyHitTarget()
        .accessibilityLabel(suggestion.title)
        .accessibilityHint(selectionHint)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(accessibilityIdentifier).\(suggestion.id)")
    }

    private var title: String {
        switch language {
        case .ru: "ИДЕИ ДЛЯ ТЕМЫ"
        case .es: "IDEAS DE TEMA"
        case .en: "THEME IDEAS"
        case .uk: "ІДЕЇ ДЛЯ ТЕМИ"
        }
    }

    private var actionHint: String {
        switch language {
        case .ru: "НАЖМИ, ЧТОБЫ ВСТАВИТЬ"
        case .es: "TOCA PARA USAR"
        case .en: "TAP TO USE"
        case .uk: "НАТИСНИ, ЩОБ ВИКОРИСТАТИ"
        }
    }

    private var selectionHint: String {
        switch language {
        case .ru: "Подставить эту тему в поле"
        case .es: "Usar este tema en el campo"
        case .en: "Use this theme in the field"
        case .uk: "Використати цю тему"
        }
    }

    private var suggestions: [Suggestion] {
        switch language {
        case .ru:
            [
                Suggestion(id: "marvel", title: "Герои Marvel", systemImage: "shield.fill"),
                Suggestion(id: "harry-potter", title: "Мир Гарри Поттера", systemImage: "sparkles"),
                Suggestion(id: "europe", title: "Страны Европы", systemImage: "globe.europe.africa.fill"),
                Suggestion(id: "music-2000s", title: "Хиты 2000-х", systemImage: "music.note"),
                Suggestion(id: "football", title: "Футболисты", systemImage: "soccerball"),
                Suggestion(id: "brands", title: "Известные бренды", systemImage: "tag.fill"),
                Suggestion(id: "world-food", title: "Мировая кухня", systemImage: "fork.knife"),
                Suggestion(id: "video-games", title: "Видеоигры", systemImage: "gamecontroller.fill"),
                Suggestion(id: "mythology", title: "Греческая мифология", systemImage: "building.columns.fill"),
                Suggestion(id: "movies-tv", title: "Фильмы и сериалы", systemImage: "film.fill")
            ]
        case .uk:
            [
                Suggestion(id: "marvel", title: "Герої Marvel", systemImage: "shield.fill"),
                Suggestion(id: "harry-potter", title: "Світ Гаррі Поттера", systemImage: "sparkles"),
                Suggestion(id: "europe", title: "Країни Європи", systemImage: "globe.europe.africa.fill"),
                Suggestion(id: "music-2000s", title: "Хіти 2000-х", systemImage: "music.note"),
                Suggestion(id: "football", title: "Футболісти", systemImage: "soccerball"),
                Suggestion(id: "brands", title: "Відомі бренди", systemImage: "tag.fill"),
                Suggestion(id: "world-food", title: "Кухні світу", systemImage: "fork.knife"),
                Suggestion(id: "video-games", title: "Відеоігри", systemImage: "gamecontroller.fill"),
                Suggestion(id: "mythology", title: "Грецька міфологія", systemImage: "building.columns.fill"),
                Suggestion(id: "movies-tv", title: "Фільми й серіали", systemImage: "film.fill")
            ]
        case .es:
            [
                Suggestion(id: "marvel", title: "Héroes de Marvel", systemImage: "shield.fill"),
                Suggestion(id: "harry-potter", title: "Mundo de Harry Potter", systemImage: "sparkles"),
                Suggestion(id: "europe", title: "Países de Europa", systemImage: "globe.europe.africa.fill"),
                Suggestion(id: "music-2000s", title: "Éxitos de los 2000", systemImage: "music.note"),
                Suggestion(id: "football", title: "Futbolistas", systemImage: "soccerball"),
                Suggestion(id: "brands", title: "Marcas famosas", systemImage: "tag.fill"),
                Suggestion(id: "world-food", title: "Cocina del mundo", systemImage: "fork.knife"),
                Suggestion(id: "video-games", title: "Videojuegos", systemImage: "gamecontroller.fill"),
                Suggestion(id: "mythology", title: "Mitología griega", systemImage: "building.columns.fill"),
                Suggestion(id: "movies-tv", title: "Cine y series", systemImage: "film.fill")
            ]
        case .en:
            [
                Suggestion(id: "marvel", title: "Marvel heroes", systemImage: "shield.fill"),
                Suggestion(id: "harry-potter", title: "Harry Potter universe", systemImage: "sparkles"),
                Suggestion(id: "europe", title: "European countries", systemImage: "globe.europe.africa.fill"),
                Suggestion(id: "music-2000s", title: "2000s hits", systemImage: "music.note"),
                Suggestion(id: "football", title: "Football players", systemImage: "soccerball"),
                Suggestion(id: "brands", title: "Famous brands", systemImage: "tag.fill"),
                Suggestion(id: "world-food", title: "World cuisine", systemImage: "fork.knife"),
                Suggestion(id: "video-games", title: "Video games", systemImage: "gamecontroller.fill"),
                Suggestion(id: "mythology", title: "Greek mythology", systemImage: "building.columns.fill"),
                Suggestion(id: "movies-tv", title: "Movies and TV", systemImage: "film.fill")
            ]
        }
    }
}

struct SpyWebSlider: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double

    let range: ClosedRange<Double>
    let language: AppLanguage
    var step: Double = 1
    var accent: Color = SpyTheme.red
    var maxMarker: Double?
    var maxLabel: String? = nil
    var animatesProgrammaticChanges = false
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onCommit: ((Double) -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var onInteractionChanged: ((Bool) -> Void)? = nil
    var accessibilityLabel: String? = nil
    var accessibilityIdentifier: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let marker = maxMarker, let maxLabel {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text(maxLabel)
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(0.08)
                        .foregroundStyle(isMaxZone ? SpyTheme.amber : SpyTheme.dim)
                    Text("\(Int(marker.rounded()))")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundStyle(isMaxZone ? SpyTheme.amber : SpyTheme.dim)
                }
                .accessibilityHidden(true)
            }

            SpyNativeSlider(
                value: $value,
                range: range,
                step: max(step, 0.0001),
                tint: isMaxZone ? SpyTheme.amber : accent,
                isEnabled: isEnabled,
                animatesProgrammaticChanges: animatesProgrammaticChanges,
                accessibilityLabel: accessibilityLabel ?? sliderAccessibilityLabel,
                accessibilityIdentifier: accessibilityIdentifier,
                onEditingChanged: onEditingChanged,
                onCommit: onCommit,
                onCancel: onCancel,
                onInteractionChanged: onInteractionChanged
            )
            .frame(height: 32)
        }
        .frame(minHeight: maxMarker == nil ? 32 : 42)
    }

    private var isMaxZone: Bool {
        guard let maxMarker else { return false }
        return value > maxMarker
    }

    private var sliderAccessibilityLabel: String {
        switch language {
        case .en: "Slider"
        case .es: "Control deslizante"
        case .ru: "Ползунок"
        case .uk: "Повзунок"
        }
    }

}

private struct SpyNativeSlider: UIViewRepresentable {
    @Binding var value: Double

    let range: ClosedRange<Double>
    let step: Double
    let tint: Color
    let isEnabled: Bool
    let animatesProgrammaticChanges: Bool
    let accessibilityLabel: String
    let accessibilityIdentifier: String?
    let onEditingChanged: ((Bool) -> Void)?
    let onCommit: ((Double) -> Void)?
    let onCancel: (() -> Void)?
    let onInteractionChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider(frame: .zero)
        slider.isContinuous = true
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchDown(_:)), for: .touchDown)
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.touchFinished(_:)),
            for: [.touchUpInside, .touchUpOutside]
        )
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.touchCancelled(_:)),
            for: .touchCancel
        )
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self

        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.minimumTrackTintColor = UIColor(tint)
        slider.isEnabled = isEnabled
        slider.accessibilityLabel = accessibilityLabel
        slider.accessibilityValue = "\(Int(value.rounded()))"
        slider.accessibilityIdentifier = accessibilityIdentifier

        let targetValue = Float(clamped(value))
        if !slider.isTracking,
           abs(slider.value - targetValue) > 0.0001 {
            slider.setValue(
                targetValue,
                animated: SpySliderProgrammaticUpdatePolicy.shouldAnimate(
                    isTracking: slider.isTracking,
                    allowsAnimation: animatesProgrammaticChanges,
                    transactionHasAnimation: context.transaction.animation != nil &&
                        !context.transaction.disablesAnimations,
                    reduceMotion: UIAccessibility.isReduceMotionEnabled
                )
            )
        }

        if !isEnabled {
            context.coordinator.cancelInteraction(slider)
        }
    }

    static func dismantleUIView(_ slider: UISlider, coordinator: Coordinator) {
        coordinator.cancelInteraction(slider)
    }

    private func clamped(_ candidate: Double) -> Double {
        min(max(candidate, range.lowerBound), range.upperBound)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SpyNativeSlider
        private var interaction = SpySliderInteractionState()

        init(parent: SpyNativeSlider) {
            self.parent = parent
        }

        @objc func touchDown(_ slider: UISlider) {
            guard parent.isEnabled,
                  interaction.begin(at: snappedValue(for: parent.value)) else { return }
            parent.onInteractionChanged?(true)
            parent.onEditingChanged?(true)
        }

        @objc func valueChanged(_ slider: UISlider) {
            let snappedValue = snappedValue(for: Double(slider.value))

            if abs(Double(slider.value) - snappedValue) > 0.0001 {
                slider.setValue(Float(snappedValue), animated: false)
            }

            if interaction.isEditing,
               slider.isTracking,
               parent.isEnabled,
               let previousValue = interaction.lastTrackedValue,
               abs(previousValue - snappedValue) > 0.0001 {
                HapticManager.shared.fire(.tabSelection)
            }

            interaction.track(snappedValue)
            parent.value = snappedValue
            slider.accessibilityValue = "\(Int(snappedValue.rounded()))"

            if interaction.commitsValueChangeImmediately(isTracking: slider.isTracking),
               parent.isEnabled {
                parent.onCommit?(snappedValue)
            }
        }

        @objc func touchFinished(_ slider: UISlider) {
            guard let committedValue = interaction.commit(
                snappedValue(for: Double(slider.value))
            ) else { return }

            slider.setValue(Float(committedValue), animated: false)
            parent.value = committedValue
            parent.onCommit?(committedValue)
            parent.onInteractionChanged?(false)
            parent.onEditingChanged?(false)
        }

        @objc func touchCancelled(_ slider: UISlider) {
            cancelInteraction(slider)
        }

        func cancelInteraction(_ slider: UISlider) {
            guard let restoredValue = interaction.cancel() else { return }
            slider.setValue(Float(restoredValue), animated: false)
            slider.accessibilityValue = "\(Int(restoredValue.rounded()))"
            parent.value = restoredValue
            parent.onInteractionChanged?(false)
            parent.onEditingChanged?(false)
            parent.onCancel?()
        }

        private func snappedValue(for rawValue: Double) -> Double {
            let lowerBound = parent.range.lowerBound
            let upperBound = parent.range.upperBound
            let stepIndex = ((rawValue - lowerBound) / parent.step).rounded()
            return min(max(lowerBound + (stepIndex * parent.step), lowerBound), upperBound)
        }
    }
}

enum SpySliderProgrammaticUpdatePolicy {
    static func shouldAnimate(
        isTracking: Bool,
        allowsAnimation: Bool,
        transactionHasAnimation: Bool,
        reduceMotion: Bool
    ) -> Bool {
        !isTracking &&
            allowsAnimation &&
            transactionHasAnimation &&
            !reduceMotion
    }
}

struct SpySliderInteractionState: Equatable {
    private(set) var initialValue: Double?
    private(set) var lastTrackedValue: Double?

    var isEditing: Bool {
        initialValue != nil
    }

    mutating func begin(at value: Double) -> Bool {
        guard !isEditing else { return false }
        initialValue = value
        lastTrackedValue = value
        return true
    }

    mutating func track(_ value: Double) {
        guard isEditing else { return }
        lastTrackedValue = value
    }

    func commitsValueChangeImmediately(isTracking: Bool) -> Bool {
        !isEditing && !isTracking
    }

    mutating func commit(_ value: Double) -> Double? {
        guard isEditing else { return nil }
        reset()
        return value
    }

    mutating func cancel() -> Double? {
        guard let initialValue else { return nil }
        reset()
        return initialValue
    }

    private mutating func reset() {
        initialValue = nil
        lastTrackedValue = nil
    }
}

struct SpyCommandCard: View {
    let title: String
    var subtitle: String?
    var systemImage: String
    var accent: Color = SpyTheme.red
    var highlighted = false
    var accessory: String? = "chevron.right"
    var minHeight: CGFloat?
    var motionDelay: Double = 0.05
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(highlighted ? accent : .white)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .tracking(title.count > 14 ? 0.04 : 0.10)
                        .foregroundStyle(highlighted ? accent : .white)
                        .spyFitted(lines: 2, scale: 0.58)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(0.08)
                            .foregroundStyle(SpyTheme.dim)
                            .spyFitted(lines: 2, scale: 0.58)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let accessory {
                    Image(systemName: accessory)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(highlighted ? accent : SpyTheme.muted)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(minHeight: minHeight ?? (subtitle == nil ? 58 : 68))
            .background((highlighted ? accent.opacity(0.06) : SpyTheme.control), in: CutCornerShape(cut: 10))
            .overlay(CutCornerShape(cut: 10).stroke(highlighted ? accent.opacity(0.50) : SpyTheme.strokeStrong, lineWidth: 1))
        }
        .buttonStyle(SpyWebPressStyle())
        .contentShape(CutCornerShape(cut: 10))
        .spyWebEntrance(delay: motionDelay, duration: 0.45, y: 16)
    }
}

struct SpySceneStage<Content: View>: View {
    var accent: Color = SpyTheme.red
    var motionDelay: Double = 0.08
    var minHeight: CGFloat = 168
    var isSubtle = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, isSubtle ? 18 : 20)
            .padding(.vertical, isSubtle ? 15 : 18)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background {
                ZStack {
                    SpyTheme.black.opacity(isSubtle ? 0.18 : 0.34)

                    RadialGradient(
                        colors: [
                            accent.opacity(isSubtle ? 0.075 : 0.17),
                            accent.opacity(isSubtle ? 0.018 : 0.035),
                            .clear
                        ],
                        center: UnitPoint(x: 0.16, y: 0.28),
                        startRadius: 0,
                        endRadius: 260
                    )

                    LinearGradient(
                        colors: [.clear, SpyTheme.black.opacity(isSubtle ? 0.38 : 0.58)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(isSubtle ? 0.38 : 0.78),
                                accent.opacity(isSubtle ? 0.08 : 0.16),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                accent.opacity(isSubtle ? 0.09 : 0.20),
                                SpyTheme.strokeDim
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
            }
            .overlay(alignment: .topLeading) {
                CornerStroke(color: accent.opacity(isSubtle ? 0.48 : 0.92))
                    .frame(width: isSubtle ? 14 : 18, height: isSubtle ? 14 : 18)
            }
            .shadow(
                color: accent.opacity(isSubtle ? 0.045 : 0.12),
                radius: isSubtle ? 14 : 26,
                y: isSubtle ? 6 : 10
            )
            .spyWebEntrance(
                delay: motionDelay,
                duration: isSubtle ? 0.46 : 0.56,
                y: isSubtle ? 12 : 18,
                scale: isSubtle ? 0.99 : 0.985
            )
    }
}

struct SpySceneKicker: View {
    let title: String
    var status: String?
    var accent: Color = SpyTheme.red

    var body: some View {
        HStack(spacing: 8) {
            Text("//")
                .foregroundStyle(accent)
            Text(title.uppercased())
                .foregroundStyle(SpyTheme.muted)

            Spacer(minLength: 8)

            if let status {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                    .shadow(color: accent.opacity(0.72), radius: 6)
                Text(status.uppercased())
                    .foregroundStyle(accent)
            }
        }
        .font(.system(size: 9, weight: .black, design: .monospaced))
        .tracking(0.14)
        .lineLimit(1)
        .minimumScaleFactor(0.66)
    }
}

struct SpyPrimaryCommandLabel: View {
    let title: String
    var detail: String?
    var systemImage: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .black))
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: detail == nil ? 0 : 3) {
                Text(title.uppercased())
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .tracking(0.10)
                    .spyFitted(lines: 2, scale: 0.64)

                if let detail {
                    Text(detail.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.07)
                        .foregroundStyle(.white.opacity(0.68))
                        .spyFitted(lines: 2, scale: 0.62)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 14, weight: .black))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: detail == nil ? 58 : 66)
    }
}

struct SpyPrimaryCommandStyle: ButtonStyle {
    var accent: Color = SpyTheme.red

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(accent, in: CutCornerShape(cut: 10))
            .overlay {
                CutCornerShape(cut: 10)
                    .stroke(.white.opacity(configuration.isPressed ? 0.18 : 0.04), lineWidth: 1)
            }
            .shadow(
                color: accent.opacity(configuration.isPressed ? 0.16 : 0.32),
                radius: configuration.isPressed ? 8 : 20,
                y: configuration.isPressed ? 3 : 9
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(SpyMotion.press, value: configuration.isPressed)
    }
}

struct SpyModal<Content: View>: View {
    let title: String
    var message: String?
    var systemImage: String = "exclamationmark.triangle.fill"
    var accent: Color = SpyTheme.red
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            SpyTheme.black.opacity(0.72)
                .ignoresSafeArea()
                .spyWebEntrance(duration: 0.18, y: 0)

            SpyPanel(accent: accent, motionDelay: 0, animatesEntrance: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: systemImage)
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(accent)

                        Text(title.uppercased())
                            .font(.system(size: 18, weight: .black, design: .monospaced))
                            .tracking(0.08)
                            .foregroundStyle(.white)
                            .spyFitted(lines: 2, scale: 0.58)
                    }

                    if let message {
                        Text(message)
                            .font(SpyTheme.mono)
                            .foregroundStyle(SpyTheme.muted)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    content
                }
            }
            .padding(.horizontal, 24)
            .spyWebEntrance(duration: 0.25, y: 16, scale: 0.92)
        }
    }
}

extension View {
    func spyGlobalToastLayer() -> some View {
        overlay(alignment: .bottomTrailing) {
            GlobalToastLayer()
                .zIndex(1_000_000)
        }
    }
}

private struct GlobalToastLayer: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(appState.toastNotices) { notice in
                GlobalToastNoticeView(notice: notice) {
                    dismiss(notice)
                }
                .transition(toastTransition)
            }
        }
        .padding(.trailing, 12)
        .padding(.bottom, 92)
        .accessibilityElement(children: .contain)
        .animation(
            reduceMotion ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.34),
            value: appState.toastNotices.map(\.id)
        )
    }

    private var toastTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }

    private func dismiss(_ notice: AppToastNotice) {
        HapticManager.shared.playToastDismissFeedback()
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.26)) {
            appState.dismissToast(notice.id)
        }
    }
}

private struct GlobalToastNoticeView: View {
    @Environment(AppState.self) private var appState

    let notice: AppToastNotice
    let onDismiss: () -> Void

    private var accent: Color {
        switch notice.kind {
        case .success: SpyTheme.green
        case .warning, .info: SpyTheme.amber
        case .error: SpyTheme.red
        }
    }

    var body: some View {
        Button(action: onDismiss) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if let avatar = notice.avatar {
                        Text(avatar)
                            .font(.system(size: 14))
                    } else {
                        Image(systemName: notice.systemImage)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(accent)
                    }
                }
                .frame(width: 24, height: 24)
                .background(SpyTheme.control, in: CutCornerShape(cut: 5))

                VStack(alignment: .leading, spacing: 3) {
                    Text(notice.title)
                        .font(.system(size: 9, weight: .black, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.72)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(accent)
                            .frame(width: 4, height: 4)
                        Text(notice.detail)
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .tracking(0.10)
                            .foregroundStyle(accent)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(minHeight: 42)
            .frame(width: toastWidth, alignment: .leading)
            .background(SpyTheme.panelDeep.opacity(0.98), in: CutCornerShape(cut: 7))
            .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.stroke, lineWidth: 1))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 2, height: 18)
            }
            .contentShape(CutCornerShape(cut: 7))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.98))
        .shadow(color: accent.opacity(0.12), radius: 7)
        .shadow(color: .black.opacity(0.46), radius: 8, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(notice.title), \(notice.detail)")
        .accessibilityHint(dismissAccessibilityHint)
    }

    private var dismissAccessibilityHint: String {
        switch appState.language {
        case .en: "Tap to dismiss"
        case .es: "Toca para cerrar"
        case .ru: "Нажмите, чтобы закрыть"
        case .uk: "Натисніть, щоб закрити"
        }
    }

    private var toastWidth: CGFloat {
        let titleFont = UIFont.systemFont(ofSize: 9, weight: .black)
        let detailFont = UIFont.monospacedSystemFont(ofSize: 7, weight: .black)
        let titleWidth = (notice.title as NSString)
            .size(withAttributes: [.font: titleFont]).width
            + CGFloat(max(0, notice.title.count - 1)) * 0.36
        let detailWidth = (notice.detail as NSString)
            .size(withAttributes: [.font: detailFont]).width
            + CGFloat(max(0, notice.detail.count - 1)) * 0.70

        // Icon, spacing, status dot, and horizontal padding around the text.
        return min(236, max(112, max(titleWidth, detailWidth + 9) + 50))
    }
}

struct SpyLoader: View {
    @Environment(AppState.self) private var appState

    var label: String? = nil
    var isAnimating: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(SpyTheme.stroke.opacity(0.95), lineWidth: 1)
                .frame(width: 74, height: 74)

            ForEach(0..<4, id: \.self) { index in
                Rectangle()
                    .fill(index == 0 ? SpyTheme.red : SpyTheme.red.opacity(0.34))
                    .frame(width: index == 0 ? 34 : 18, height: 2)
                    .offset(x: index == 0 ? 28 : 34)
                    .rotationEffect(.degrees(Double(index) * 90 + (isAnimating ? 28 : -28)))
            }

            CutCornerShape(cut: 7)
                .fill(SpyTheme.red.opacity(isAnimating ? 0.22 : 0.10))
                .frame(width: isAnimating ? 38 : 30, height: isAnimating ? 38 : 30)
                .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.red.opacity(0.7), lineWidth: 1))

            Text(resolvedLabel)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.14)
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.58)
        }
        .frame(width: 96, height: 96)
        .shadow(color: SpyTheme.red.opacity(isAnimating ? 0.38 : 0.16), radius: isAnimating ? 22 : 10)
        .animation(.easeInOut(duration: 1.1), value: isAnimating)
        .accessibilityLabel(loaderAccessibilityLabel)
    }

    private var resolvedLabel: String {
        if let label { return label }
        return switch appState.language {
        case .en: "SYNC"
        case .es: "SINCRONIZAR"
        case .ru: "СИНХРОНИЗАЦИЯ"
        case .uk: "СИНХРОНІЗАЦІЯ"
        }
    }

    private var loaderAccessibilityLabel: String {
        switch appState.language {
        case .en: "SpyClash loading"
        case .es: "SpyClash cargando"
        case .ru: "SpyClash загружается"
        case .uk: "SpyClash завантажується"
        }
    }
}

struct SpySpinner: View {
    @Environment(AppState.self) private var appState

    var size: CGFloat = 22
    var accent: Color = SpyTheme.red
    @State private var isSpinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(SpyTheme.stroke.opacity(0.9), lineWidth: 1)

            ForEach(0..<3, id: \.self) { index in
                Rectangle()
                    .fill(index == 0 ? accent : accent.opacity(0.38))
                    .frame(width: size * 0.38, height: max(1, size * 0.085))
                    .offset(x: size * 0.31)
                    .rotationEffect(.degrees(Double(index) * 120 + (isSpinning ? 360 : 0)))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: accent.opacity(0.32), radius: size * 0.38)
        .onAppear {
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                isSpinning = true
            }
        }
        .accessibilityLabel(loadingAccessibilityLabel)
    }

    private var loadingAccessibilityLabel: String {
        switch appState.language {
        case .en: "Loading"
        case .es: "Cargando"
        case .ru: "Загрузка"
        case .uk: "Завантаження"
        }
    }
}

struct SpyLoadingLabel: View {
    let title: String
    var accent: Color = SpyTheme.red

    var body: some View {
        HStack(spacing: 10) {
            SpySpinner(size: 18, accent: accent)
            Text(title)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .tracking(0.10)
                .lineLimit(2)
                .minimumScaleFactor(0.62)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SpyConfirmDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    let cancelTitle: String
    var isBusy = false
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        SpyModal(title: title, message: message) {
            VStack(spacing: 10) {
                Button {
                    HapticManager.shared.fire(.buttonPress)
                    onConfirm()
                } label: {
                    if isBusy {
                        SpyLoadingLabel(title: confirmTitle, accent: .white)
                    } else {
                        SpyActionLabel(title: confirmTitle, systemImage: "trash.fill", tracking: 0.02, lines: 2)
                    }
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(isBusy)

                Button {
                    HapticManager.shared.fire(.buttonPress)
                    onCancel()
                } label: {
                    SpyActionLabel(title: cancelTitle, systemImage: "xmark", tracking: 0.02)
                }
                .buttonStyle(SpyButtonStyle(variant: .ghost))
                .disabled(isBusy)
            }
        }
    }
}

extension View {
    @ViewBuilder
    func spyGlass(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        let cut = max(8, min(cornerRadius * 0.58, 16))

        self
            .background(
                SpyTheme.panel,
                in: CutCornerShape(cut: cut)
            )
            .overlay(
                CutCornerShape(cut: cut)
                    .stroke(interactive ? SpyTheme.red.opacity(0.30) : SpyTheme.stroke, lineWidth: 1)
            )
            .shadow(color: SpyTheme.red.opacity(interactive ? 0.10 : 0.04), radius: interactive ? 16 : 10)
    }

    func spyCutCard(
        cut: CGFloat = 10,
        fill: Color = SpyTheme.panelDeep,
        stroke: Color = SpyTheme.stroke.opacity(0.95),
        lineWidth: CGFloat = 1
    ) -> some View {
        self
            .background(fill, in: CutCornerShape(cut: cut))
            .overlay(CutCornerShape(cut: cut).stroke(stroke, lineWidth: lineWidth))
    }
}

struct CornerStroke: View {
    let color: Color

    var body: some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 18, y: 0))
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: 18))
        }
        .stroke(color, lineWidth: 1)
        .frame(width: 18, height: 18)
    }
}
