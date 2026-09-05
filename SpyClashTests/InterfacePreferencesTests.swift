import XCTest
@testable import SpyClash

final class InterfaceSettingsTests: XCTestCase {
    func testDefaultsPreserveOriginalInterface() {
        let value = InterfaceSettings()
        XCTAssertFalse(value.reduceMotion)
        XCTAssertTrue(value.backgroundEffects)
        XCTAssertFalse(value.enhancedContrast)
        XCTAssertEqual(value.labelSize, .standard)
        XCTAssertFalse(value.dockLabels)
        XCTAssertEqual(value.haptics, .standard)
        XCTAssertEqual(value.interfaceScale, 1)
        XCTAssertEqual(value.matchingPreset, .original)
    }

    func testSystemMotionAlwaysTakesPriority() {
        for local in [false, true] {
            let value = InterfaceSettings(reduceMotion: local)
            XCTAssertTrue(value.effectiveReduceMotion(system: true))
            XCTAssertEqual(value.effectiveReduceMotion(system: false), local)
        }
    }

    func testPresetsAndCustomChanges() {
        let calm = InterfacePreset.calm.settings
        XCTAssertEqual(calm.matchingPreset, .calm)
        XCTAssertTrue(calm.reduceMotion)
        XCTAssertFalse(calm.backgroundEffects)
        XCTAssertEqual(calm.haptics, .off)
        let readable = InterfacePreset.readable.settings
        XCTAssertEqual(readable.matchingPreset, .readable)
        XCTAssertTrue(readable.enhancedContrast)
        XCTAssertEqual(readable.labelSize, .large)
        XCTAssertTrue(readable.dockLabels)
        var custom = readable
        custom.haptics = .soft
        XCTAssertNil(custom.matchingPreset)
    }

    func testAllSettingsRoundTrip() throws {
        let original = InterfaceSettings(reduceMotion: true, backgroundEffects: false,
                                         enhancedContrast: true, labelSize: .compact,
                                         dockLabels: true, haptics: .soft, interfaceScale: 1.15)
        let decoded = try JSONDecoder().decode(InterfaceSettings.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(original, decoded)
    }

    func testMissingFieldsKeepDefaultsAndPreserveKnownFields() throws {
        let data = Data(#"{"dockLabels":true}"#.utf8)
        let value = try JSONDecoder().decode(InterfaceSettings.self, from: data)
        XCTAssertEqual(value, InterfaceSettings(dockLabels: true))
    }

    func testUnknownEnumAndMalformedFieldsFallBackIndependently() throws {
        let data = Data(#"{"labelSize":"future","haptics":"future","reduceMotion":"bad","backgroundEffects":null,"enhancedContrast":true}"#.utf8)
        let value = try JSONDecoder().decode(InterfaceSettings.self, from: data)
        XCTAssertEqual(value, InterfaceSettings(enhancedContrast: true))
    }

    func testIntensityAndLabelScalesAreBounded() {
        XCTAssertEqual(InterfaceHaptics.off.intensity, 0)
        XCTAssertGreaterThan(InterfaceHaptics.soft.intensity, 0)
        XCTAssertLessThan(InterfaceHaptics.soft.intensity, InterfaceHaptics.standard.intensity)
        XCTAssertEqual(InterfaceHaptics.standard.intensity, 1)
        XCTAssertEqual(InterfaceLabelSize.standard.scale, 1)
        XCTAssertLessThan(InterfaceLabelSize.compact.scale, 1)
        XCTAssertGreaterThan(InterfaceLabelSize.large.scale, 1)
    }

    func testInterfaceScaleClampsInvalidValuesAndDirectMutations() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(InterfaceSettings(interfaceScale: value).interfaceScale, 1)
        }
        var settings = InterfaceSettings(interfaceScale: 4)
        XCTAssertEqual(settings.interfaceScale, 1.2)
        settings.interfaceScale = 0.5
        XCTAssertEqual(settings.interfaceScale, 1)
        settings.interfaceScale = .nan
        XCTAssertEqual(settings.interfaceScale, 1)
        settings.interfaceScale = 1.1
        XCTAssertEqual(settings.interfaceScale, 1.1)
        XCTAssertNil(settings.matchingPreset)
    }

    func testStoredInterfaceScaleRecoversIndependently() throws {
        for (json, expected) in [("null", 1.0), ("\"invalid\"", 1.0), ("0", 1.0), ("3", 1.2), ("1.15", 1.15)] {
            let data = Data("{\"interfaceScale\":\(json),\"dockLabels\":true}".utf8)
            let value = try JSONDecoder().decode(InterfaceSettings.self, from: data)
            XCTAssertEqual(value.interfaceScale, expected)
            XCTAssertTrue(value.dockLabels)
        }
    }

    func testLogicalViewportReflowsBeforeScalingWithoutCropping() {
        for viewport in [CGSize(width: 375, height: 667), CGSize(width: 402, height: 800), CGSize(width: 1024, height: 1366)] {
            for factor in [1.0, 1.05, 1.1, 1.15, 1.2] {
                let logical = InterfaceScalePolicy.logicalSize(viewport: viewport, scale: factor)
                XCTAssertEqual(logical.width * factor, viewport.width, accuracy: 0.001)
                XCTAssertEqual(logical.height * factor, viewport.height, accuracy: 0.001)
            }
        }
        XCTAssertEqual(InterfaceScalePolicy.logicalSize(viewport: .zero, scale: .nan), .zero)
        XCTAssertEqual(InterfaceScalePolicy.logicalSize(viewport: CGSize(width: -1, height: -1), scale: 1), .zero)
    }

    func testAllPresetsRestoreOriginalInterfaceScale() {
        for preset in InterfacePreset.allCases {
            XCTAssertEqual(preset.settings.interfaceScale, 1)
        }
    }
}

@MainActor
final class InterfacePreferencesTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "InterfacePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testNestedChangesPersistAcrossInstances() throws {
        try withDefaults { defaults in
            let first = InterfacePreferences(defaults: defaults)
            first.settings.dockLabels = true
            first.settings.haptics = .soft
            first.settings.labelSize = .large
            first.settings.interfaceScale = 1.2
            let next = InterfacePreferences(defaults: defaults)
            XCTAssertEqual(next.settings, first.settings)
            XCTAssertNotNil(defaults.data(forKey: InterfacePreferences.storageKey))
            let stored = try JSONDecoder().decode(InterfaceSettings.self, from: XCTUnwrap(defaults.data(forKey: InterfacePreferences.storageKey)))
            XCTAssertEqual(stored, first.settings)
        }
    }

    func testPresetPersistsAndResetOnlyRemovesOwnKey() {
        withDefaults { defaults in
            defaults.set("untouched", forKey: "unrelated")
            let prefs = InterfacePreferences(defaults: defaults)
            prefs.apply(.calm)
            XCTAssertEqual(InterfacePreferences(defaults: defaults).settings, InterfacePreset.calm.settings)
            prefs.settings.interfaceScale = 1.2
            prefs.reset()
            XCTAssertEqual(prefs.settings, .init())
            XCTAssertNil(defaults.object(forKey: InterfacePreferences.storageKey))
            XCTAssertEqual(defaults.string(forKey: "unrelated"), "untouched")
            XCTAssertEqual(InterfacePreferences(defaults: defaults).settings, .init())
        }
    }

    func testCorruptStorageRecoversOnNextChange() {
        withDefaults { defaults in
            defaults.set(Data("invalid json".utf8), forKey: InterfacePreferences.storageKey)
            let prefs = InterfacePreferences(defaults: defaults)
            XCTAssertEqual(prefs.settings, .init())
            prefs.settings.reduceMotion = true
            XCTAssertTrue(InterfacePreferences(defaults: defaults).settings.reduceMotion)
        }
    }

    func testPreviewStorageDoesNotChangeNormalPreferences() {
        withDefaults { defaults in
            let normal = InterfacePreferences(defaults: defaults)
            normal.apply(.readable)
            let preview = InterfacePreferences(defaults: defaults, storageKey: "spyclash.interface.preview.v1")
            preview.apply(.calm)
            preview.reset()
            XCTAssertEqual(InterfacePreferences(defaults: defaults).settings, InterfacePreset.readable.settings)
        }
    }

    func testInMemoryPreviewDoesNotNeedPersistentStorage() {
        let prefs = InterfacePreferences()
        prefs.apply(.readable)
        XCTAssertEqual(prefs.settings.matchingPreset, .readable)
        prefs.reset()
        XCTAssertEqual(prefs.settings.matchingPreset, .original)
    }
}
