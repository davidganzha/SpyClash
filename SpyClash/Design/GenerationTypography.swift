import SwiftUI

private struct SpyUsesGameTypographyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var spyUsesGameTypography: Bool {
        get { self[SpyUsesGameTypographyKey.self] }
        set { self[SpyUsesGameTypographyKey.self] = newValue }
    }
}

extension View {
    /// Opt in only the generation/auth surface that is being updated. Shared
    /// controls retain their original typography outside this explicit scope.
    func spyGameTypography(_ enabled: Bool = true) -> some View {
        environment(\.spyUsesGameTypography, enabled)
    }
}
