import SwiftUI

/// Combines the immutable system accessibility preference with the local one.
/// The app can reduce motion further, but can never override the system's request.
@MainActor
@propertyWrapper
struct SpyReduceMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var wrappedValue: Bool {
        InterfacePreferences.shared.settings.effectiveReduceMotion(system: systemReduceMotion)
    }
}
