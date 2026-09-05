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
