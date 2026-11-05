import SwiftUI

struct FanModeSettingsPanel: View {
    @Binding var settings: FanModeSettings
    let language: AppLanguage
    var editable = true
    var onChange: () -> Void = {}
    @State private var expanded = false
    @SpyReduceMotion private var reduceMotion
    private var copy: FanModeCopy { FanModeCopy(language: language) }

    var body: some View {
        SpyPanel(accent: SpyTheme.amber) {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "shuffle").foregroundStyle(SpyTheme.amber)
                        Text("FAN MODE").font(SpyTheme.brandFont(size: 24)).tracking(1.5)
                        Spacer()
                        Text(settings.isEnabled ? "ON" : "OFF")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(settings.isEnabled ? SpyTheme.amber : SpyTheme.dim)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .bold))
                    }.foregroundStyle(.white).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("fanMode.expand")
                if expanded {
                    Toggle(copy.text("System sabotage", "Саботаж системы", "Sabotaje del sistema", "Саботаж системи"), isOn: Binding(
                        get: { settings.isEnabled }, set: { settings.isEnabled = $0; onChange() }
                    )).tint(SpyTheme.amber).disabled(!editable).accessibilityIdentifier("fanMode.enabled")
                    Text(copy.rules).font(.system(size: 12)).foregroundStyle(SpyTheme.muted).fixedSize(horizontal: false, vertical: true)
                    if settings.isEnabled {
                        chance(.allSpies)
                        chance(.noSpies)
                        HStack {
                            Text(FanScenario.standard.title(language))
                            Spacer()
                            Text("\(settings.standardChance)%").monospacedDigit()
                        }.font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(SpyTheme.green)
                        Text(copy.text("All spies: nobody knows the word. No spies: everyone knows it. A wrong accusation or timeout in these rounds is a system win.", "Все шпионы: никто не знает слово. Шпионов нет: слово знают все. Ошибочное обвинение или конец времени в таком раунде — победа системы.", "Todos espías: nadie conoce la palabra. Sin espías: todos la conocen. Una acusación errónea o agotar el tiempo da la victoria al sistema.", "Усі шпигуни: ніхто не знає слово. Шпигунів немає: слово знають усі. Хибне звинувачення або кінець часу — перемога системи."))
                            .font(.system(size: 11)).foregroundStyle(SpyTheme.dim).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.accessibilityIdentifier("fanMode.settings")
    }

    private func chance(_ scenario: FanScenario) -> some View {
        let isAll = scenario == .allSpies
        let value = isAll ? settings.allSpiesChance : settings.noSpiesChance
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(scenario.title(language))
                Spacer()
                Text("\(value)%").monospacedDigit().foregroundStyle(SpyTheme.amber)
            }.font(.system(size: 11, weight: .bold, design: .monospaced))
            Slider(value: Binding(get: { Double(isAll ? settings.allSpiesChance : settings.noSpiesChance) }, set: { raw in
                let next = min(max(Int(raw.rounded()), 0), 99)
                if isAll {
                    settings.allSpiesChance = next
                    settings.noSpiesChance = min(settings.noSpiesChance, 100 - next)
                } else {
                    settings.noSpiesChance = next
                    settings.allSpiesChance = min(settings.allSpiesChance, 100 - next)
                }
                onChange()
            }), in: 0...99, step: 1)
            .tint(SpyTheme.amber).disabled(!editable)
            .accessibilityLabel(scenario.title(language))
            .accessibilityValue("\(value)%")
            .accessibilityIdentifier("fanMode.chance.\(scenario.rawValue)")
        }
    }
}

struct FanConceptBallot: View {
    let language: AppLanguage
    let selected: FanScenario?
    var isPending = false
    var disabled = false
    let onSelect: (FanScenario) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(FanModeCopy(language: language).unanimity)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(SpyTheme.amber).multilineTextAlignment(.center)
            ForEach(FanScenario.concepts, id: \.rawValue) { concept in
                Button { onSelect(concept) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: concept == .allSpies ? "person.3.fill" : "person.crop.circle.badge.checkmark")
                        Text(concept.title(language)).font(.system(size: 12, weight: .bold, design: .monospaced))
                        Spacer(minLength: 0)
                        if selected == concept {
                            if isPending { ProgressView().tint(SpyTheme.amber) }
                            else { Image(systemName: "checkmark.circle.fill") }
                        }
                    }.foregroundStyle(SpyTheme.amber).padding(12).frame(maxWidth: .infinity, minHeight: 48)
                        .background(SpyTheme.amber.opacity(selected == concept ? 0.16 : 0.06), in: CutCornerShape(cut: 8))
                        .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.amber.opacity(selected == concept ? 0.8 : 0.3), lineWidth: 1))
                }.buttonStyle(SpyWebPressStyle()).disabled(disabled)
                    .accessibilityIdentifier("fanMode.vote.\(concept.rawValue)")
                    .accessibilityAddTraits(selected == concept ? .isSelected : [])
            }
        }
    }
}
