import SwiftUI

/// Apply once at each presentation root, not to individual cards.
/// Layout gets the smaller logical viewport before the visual transform, so
/// scrollable content reflows and native controls keep their transformed hit areas.
private struct SpyInterfaceScaleModifier: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let scale = InterfacePreferences.shared.settings.interfaceScale
            let size = InterfaceScalePolicy.logicalSize(viewport: proxy.size, scale: scale)

            content
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .animation(nil, value: scale)
        }
    }
}

extension View {
    func spyInterfaceScale() -> some View {
        modifier(SpyInterfaceScaleModifier())
    }
}
