import SwiftUI

/// A compact selector using the same cut corners and red selected state as lobby controls.
struct InterfaceChoiceStrip<Value: RawRepresentable & Hashable>: View where Value.RawValue == String {
    let values: [Value]
    @Binding var selection: Value?
    let title: (Value) -> String
    var symbol: ((Value) -> String)? = nil
    let identifier: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.rawValue) { value in
                let selected = selection == value
                Button { selection = value } label: {
                    VStack(spacing: 8) {
                        if let symbol {
                            Image(systemName: symbol(value))
                                .font(.system(size: 16, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        Text(title(value).uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundStyle(selected ? .white : SpyTheme.muted)
                    .padding(.horizontal, 3)
                    .frame(maxWidth: .infinity, minHeight: symbol == nil ? 48 : 68)
                    .background(selected ? SpyTheme.red : SpyTheme.black, in: CutCornerShape(cut: 8))
                    .overlay(CutCornerShape(cut: 8).stroke(selected ? SpyTheme.red : SpyTheme.strokeStrong, lineWidth: 1))
                    .contentShape(CutCornerShape(cut: 8))
                }
                .buttonStyle(SpyWebPressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).\(value.rawValue)")
            }
        }
    }
}

/// Custom visual surface with native Toggle semantics for VoiceOver and Switch Control.
struct InterfaceSwitchStyle: ToggleStyle {
    let onTitle: String
    let offTitle: String

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 5) {
                    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                        CutCornerShape(cut: 5)
                            .fill(configuration.isOn ? SpyTheme.red.opacity(0.12) : SpyTheme.black)
                        CutCornerShape(cut: 5)
                            .stroke(configuration.isOn ? SpyTheme.red : SpyTheme.strokeStrong, lineWidth: 1)
                        Rectangle()
                            .fill(configuration.isOn ? SpyTheme.red : SpyTheme.muted)
                            .frame(width: 17, height: 16)
                            .padding(.horizontal, 5)
                    }
                    .frame(width: 50, height: 26)
                    Text(configuration.isOn ? onTitle : offTitle)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(configuration.isOn ? SpyTheme.red : SpyTheme.muted)
                }
                .frame(width: 54)
                .accessibilityHidden(true)
            }
            .frame(minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
        .accessibilityRepresentation {
            Toggle(isOn: Binding(get: { configuration.isOn }, set: { configuration.isOn = $0 })) {
                configuration.label
            }
            .toggleStyle(.switch)
        }
    }
}
