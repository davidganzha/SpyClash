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

extension EnvironmentValues {
    var spyEntranceMotionEnabled: Bool {
        get { self[SpyEntranceMotionEnabledKey.self] }
        set { self[SpyEntranceMotionEnabledKey.self] = newValue }
    }
}

struct SpyWebPressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.98

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(SpyMotion.press, value: configuration.isPressed)
    }
}

private struct SpyWebEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.spyEntranceMotionEnabled) private var entranceMotionEnabled
    @State private var isVisible = false

    let delay: Double
    let duration: Double
    let x: CGFloat
    let y: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(
                x: reduceMotion || isVisible ? 0 : x,
                y: reduceMotion || isVisible ? 0 : y
            )
            .scaleEffect(reduceMotion || isVisible ? 1 : scale)
            .task(id: entranceMotionEnabled) {
                guard entranceMotionEnabled, !isVisible else { return }
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
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(SpyMotion.press, value: configuration.isPressed)
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
            TextField("", text: $text, prompt: prompt)
                .textInputAutocapitalization(autocapitalization)
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .autocorrectionDisabled(autocorrectionDisabled)
        case .secure:
            SecureField("", text: $text, prompt: prompt)
                .textContentType(textContentType)
                .autocorrectionDisabled(autocorrectionDisabled)
        }
    }

    private var prompt: Text {
        Text(placeholder).foregroundStyle(SpyTheme.dim)
    }
}

struct SpyWebSlider: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double

    let range: ClosedRange<Double>
    var step: Double = 1
    var accent: Color = SpyTheme.red
    var maxMarker: Double?
    var maxLabel: String? = nil
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onInteractionChanged: ((Bool) -> Void)? = nil
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
                accessibilityIdentifier: accessibilityIdentifier,
                onEditingChanged: onEditingChanged,
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

}

struct SpyPoolExpansionPicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var additionalWords: Double

    let range: ClosedRange<Double>
    let currentPoolCount: Int
    let poolLimit: Int
    let title: String
    let poolProgressTitle: String
    let confirmTitle: (Int) -> String
    let loadingTitle: (Int) -> String
    let closeAccessibilityLabel: String
    let accessibilityPrefix: String
    let isLoading: Bool
    let onClose: () -> Void
    let onConfirm: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.08)
                        .foregroundStyle(SpyTheme.red)
                        .spyKicker()

                    Text("\(poolProgressTitle) · \(currentPoolCount) → ≤\(projectedPoolCount) / \(poolLimit)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.02)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(lines: 2, scale: 0.58)
                }

                Spacer(minLength: 8)

                Text("+\(selectedCount)")
                    .font(.system(size: 23, weight: .black, design: .monospaced))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.red)
                    .contentTransition(.numericText())
                    .accessibilityLabel("+\(selectedCount)")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(SpyTheme.dim)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.04), in: Circle())
                        .overlay(Circle().stroke(SpyTheme.strokeStrong, lineWidth: 1))
                }
                .buttonStyle(SpyWebPressStyle())
                .spyHitTarget()
                .disabled(isLoading)
                .opacity(isLoading ? 0.42 : 1)
                .accessibilityLabel(closeAccessibilityLabel)
                .accessibilityIdentifier("\(accessibilityPrefix).close")
            }

            SpyWebSlider(
                value: $additionalWords,
                range: range,
                step: 1,
                accent: SpyTheme.red,
                accessibilityIdentifier: "\(accessibilityPrefix).slider"
            )
            .disabled(isLoading || range.lowerBound == range.upperBound)

            Button {
                onConfirm(selectedCount)
            } label: {
                if isLoading {
                    SpyLoadingLabel(title: loadingTitle(selectedCount), accent: .white)
                        .frame(height: 50)
                } else {
                    SpyActionLabel(
                        title: confirmTitle(selectedCount),
                        systemImage: "plus.circle.fill",
                        fontSize: 10.5,
                        iconSize: 13,
                        tracking: 0.02,
                        lines: 2
                    )
                }
            }
            .buttonStyle(SpyButtonStyle(variant: .red))
            .disabled(isLoading)
            .accessibilityIdentifier("\(accessibilityPrefix).confirm")
        }
        .padding(13)
        .background(SpyTheme.panelDeep, in: CutCornerShape(cut: 9))
        .overlay(
            CutCornerShape(cut: 9)
                .stroke(SpyTheme.red.opacity(0.72), lineWidth: 1)
        )
        .shadow(color: SpyTheme.red.opacity(0.10), radius: 14, y: 8)
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: selectedCount)
    }

    private var selectedCount: Int {
        let rounded = Int(additionalWords.rounded())
        return min(max(rounded, Int(range.lowerBound)), Int(range.upperBound))
    }

    private var projectedPoolCount: Int {
        min(poolLimit, currentPoolCount + selectedCount)
    }
}

private struct SpyNativeSlider: UIViewRepresentable {
    @Binding var value: Double

    let range: ClosedRange<Double>
    let step: Double
    let tint: Color
    let isEnabled: Bool
    let accessibilityIdentifier: String?
    let onEditingChanged: ((Bool) -> Void)?
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
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self

        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.minimumTrackTintColor = UIColor(tint)
        slider.isEnabled = isEnabled
        slider.accessibilityLabel = "Slider"
        slider.accessibilityValue = "\(Int(value.rounded()))"
        slider.accessibilityIdentifier = accessibilityIdentifier

        if !slider.isTracking {
            slider.setValue(Float(clamped(value)), animated: false)
        }

        if !isEnabled {
            context.coordinator.finishInteraction()
        }
    }

    static func dismantleUIView(_ slider: UISlider, coordinator: Coordinator) {
        coordinator.finishInteraction()
    }

    private func clamped(_ candidate: Double) -> Double {
        min(max(candidate, range.lowerBound), range.upperBound)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SpyNativeSlider
        private var isEditing = false
        private var lastTrackedSnappedValue: Double?

        init(parent: SpyNativeSlider) {
            self.parent = parent
        }

        @objc func touchDown(_ slider: UISlider) {
            guard !isEditing, parent.isEnabled else { return }
            isEditing = true
            lastTrackedSnappedValue = snappedValue(for: parent.value)
            parent.onInteractionChanged?(true)
            parent.onEditingChanged?(true)
        }

        @objc func valueChanged(_ slider: UISlider) {
            let snappedValue = snappedValue(for: Double(slider.value))

            if abs(Double(slider.value) - snappedValue) > 0.0001 {
                slider.setValue(Float(snappedValue), animated: false)
            }

            if isEditing,
               slider.isTracking,
               parent.isEnabled,
               let previousValue = lastTrackedSnappedValue,
               abs(previousValue - snappedValue) > 0.0001 {
                lastTrackedSnappedValue = snappedValue
                HapticManager.shared.fire(.tabSelection)
            }

            parent.value = snappedValue
            slider.accessibilityValue = "\(Int(snappedValue.rounded()))"
        }

        @objc func touchFinished(_ slider: UISlider) {
            finishInteraction()
        }

        func finishInteraction() {
            lastTrackedSnappedValue = nil
            guard isEditing else { return }
            isEditing = false
            parent.onInteractionChanged?(false)
            parent.onEditingChanged?(false)
        }

        private func snappedValue(for rawValue: Double) -> Double {
            let lowerBound = parent.range.lowerBound
            let upperBound = parent.range.upperBound
            let stepIndex = ((rawValue - lowerBound) / parent.step).rounded()
            return min(max(lowerBound + (stepIndex * parent.step), lowerBound), upperBound)
        }
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

struct SpyToast: View {
    enum Kind {
        case success
        case error
        case info
        case warning

        var accent: Color {
            switch self {
            case .success: SpyTheme.green
            case .error: SpyTheme.red
            case .info: SpyTheme.muted
            case .warning: SpyTheme.amber
            }
        }

        var icon: String {
            switch self {
            case .success: "checkmark.seal.fill"
            case .error: "exclamationmark.triangle.fill"
            case .info: "dot.radiowaves.left.and.right"
            case .warning: "exclamationmark.triangle.fill"
            }
        }
    }

    let text: String
    var kind: Kind = .info
    var isLoading = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isLoading {
                SpySpinner(size: 18, accent: kind.accent)
            } else {
                Image(systemName: kind.icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(kind.accent)
            }

            Text(text)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(kind.accent)
                .fixedSize(horizontal: false, vertical: true)
                .spyFitted(lines: 3, scale: 0.62)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(kind.accent.opacity(0.08), in: CutCornerShape(cut: 8))
        .overlay(CutCornerShape(cut: 8).stroke(kind.accent.opacity(0.30), lineWidth: 1))
        .spyWebEntrance(duration: 0.25, y: 8)
    }
}

struct SpyLoader: View {
    var label: String = "SYNC"
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

            Text(label)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.14)
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.58)
        }
        .frame(width: 96, height: 96)
        .shadow(color: SpyTheme.red.opacity(isAnimating ? 0.38 : 0.16), radius: isAnimating ? 22 : 10)
        .animation(.easeInOut(duration: 1.1), value: isAnimating)
        .accessibilityLabel("SpyClash loading")
    }
}

struct SpySpinner: View {
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
        .accessibilityLabel("Loading")
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
