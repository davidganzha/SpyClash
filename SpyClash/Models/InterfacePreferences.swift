import Foundation
import Observation

enum InterfaceLabelSize: String, Codable, CaseIterable, Identifiable {
    case compact, standard, large
    var id: Self { self }
    var scale: Double {
        switch self { case .compact: 0.9; case .standard: 1; case .large: 1.15 }
    }
}

enum InterfaceHaptics: String, Codable, CaseIterable, Identifiable {
    case off, soft, standard
    var id: Self { self }
    var intensity: Double {
        switch self { case .off: 0; case .soft: 0.45; case .standard: 1 }
    }
}

enum InterfacePreset: String, CaseIterable, Identifiable {
    case original, calm, readable
    var id: Self { self }
    var settings: InterfaceSettings {
        switch self {
        case .original: .init()
        case .calm: .init(reduceMotion: true, backgroundEffects: false, haptics: .off)
        case .readable: .init(enhancedContrast: true, labelSize: .large, dockLabels: true)
        }
    }
}

struct InterfaceSettings: Codable, Equatable {
    var interfaceScale: Double = 1 {
        didSet { interfaceScale = InterfaceScalePolicy.clamped(interfaceScale) }
    }
    var reduceMotion = false
    var backgroundEffects = true
    var enhancedContrast = false
    var labelSize: InterfaceLabelSize = .standard
    var dockLabels = false
    var haptics: InterfaceHaptics = .standard

    init(
        reduceMotion: Bool = false, backgroundEffects: Bool = true,
        enhancedContrast: Bool = false, labelSize: InterfaceLabelSize = .standard,
        dockLabels: Bool = false, haptics: InterfaceHaptics = .standard,
        interfaceScale: Double = 1
    ) {
        self.reduceMotion = reduceMotion
        self.backgroundEffects = backgroundEffects
        self.enhancedContrast = enhancedContrast
        self.labelSize = labelSize
        self.dockLabels = dockLabels
        self.haptics = haptics
        self.interfaceScale = InterfaceScalePolicy.clamped(interfaceScale)
    }

    private enum CodingKeys: String, CodingKey {
        case reduceMotion, backgroundEffects, enhancedContrast, labelSize, dockLabels, haptics, interfaceScale
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Missing/unknown fields never make an old install lose the original UI.
        reduceMotion = (try? values.decode(Bool.self, forKey: .reduceMotion)) ?? false
        backgroundEffects = (try? values.decode(Bool.self, forKey: .backgroundEffects)) ?? true
        enhancedContrast = (try? values.decode(Bool.self, forKey: .enhancedContrast)) ?? false
        labelSize = (try? values.decode(InterfaceLabelSize.self, forKey: .labelSize)) ?? .standard
        dockLabels = (try? values.decode(Bool.self, forKey: .dockLabels)) ?? false
        haptics = (try? values.decode(InterfaceHaptics.self, forKey: .haptics)) ?? .standard
        interfaceScale = InterfaceScalePolicy.clamped((try? values.decode(Double.self, forKey: .interfaceScale)) ?? 1)
    }

    func effectiveReduceMotion(system: Bool) -> Bool { system || reduceMotion }
    var matchingPreset: InterfacePreset? { InterfacePreset.allCases.first { $0.settings == self } }
}

@MainActor
@Observable
final class InterfacePreferences {
    static let storageKey = "spyclash.interface.v1"
    static let shared: InterfacePreferences = {
#if DEBUG
        let key = ProcessInfo.processInfo.arguments.contains("--spyclash-ui-preview")
            ? "spyclash.interface.preview.v1" : storageKey
#else
        let key = storageKey
#endif
        return InterfacePreferences(defaults: .standard, storageKey: key)
    }()

    var settings: InterfaceSettings {
        didSet {
            guard settings != oldValue, let data = try? JSONEncoder().encode(settings) else { return }
            defaults?.set(data, forKey: storageKey)
        }
    }
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let storageKey: String

    init(defaults: UserDefaults? = nil, storageKey: String = InterfacePreferences.storageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults?.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(InterfaceSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .init()
        }
    }

    func apply(_ preset: InterfacePreset) { settings = preset.settings }

    func reset() {
        settings = .init()
        defaults?.removeObject(forKey: storageKey)
    }
}
