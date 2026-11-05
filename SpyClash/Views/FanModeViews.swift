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

/// A fixed-height choice menu; the roster never pushes a FAN answer off screen.
struct FanVoteMenu: View {
    let language: AppLanguage
    let selectedTarget: String?
    let selectedPlayerName: String?
    let isPending: Bool
    let disabled: Bool
    let onChoosePlayer: () -> Void
    let onChooseConcept: (FanScenario) -> Void

    private var copy: FanModeCopy { FanModeCopy(language: language) }
    private var selectedConcept: FanScenario? { selectedTarget.flatMap(FanScenario.init(voteTarget:)) }
    private var playerSelected: Bool { selectedTarget != nil && selectedConcept == nil }

    var body: some View {
        VStack(spacing: 9) {
            choice(copy.voteForPlayer, icon: "person.crop.circle.badge.questionmark",
                   selected: playerSelected, subtitle: selectedPlayerName, opensList: true,
                   accent: .white, id: "fanMode.vote.player", action: onChoosePlayer)
            choice(copy.voteNoSpies, icon: "person.crop.circle.badge.checkmark",
                   selected: selectedConcept == .noSpies, accent: SpyTheme.amber,
                   id: "fanMode.vote.no_spies") { onChooseConcept(.noSpies) }
            choice(copy.voteAllSpies, icon: "person.3.fill",
                   selected: selectedConcept == .allSpies, accent: SpyTheme.amber,
                   id: "fanMode.vote.all_spies") { onChooseConcept(.allSpies) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fanMode.vote.menu")
    }

    private func choice(
        _ title: String, icon: String, selected: Bool, subtitle: String? = nil,
        opensList: Bool = false, accent: Color, id: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    if selected, let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    if isPending { ProgressView().tint(accent) }
                    else { Image(systemName: "checkmark.circle.fill").foregroundStyle(SpyTheme.green) }
                } else if opensList {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(accent.opacity(selected ? 0.13 : 0.045), in: CutCornerShape(cut: 9))
            .overlay(CutCornerShape(cut: 9).stroke(accent.opacity(selected ? 0.8 : 0.3), lineWidth: 1))
            .contentShape(CutCornerShape(cut: 9))
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(disabled)
        .accessibilityIdentifier(id)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? (subtitle ?? "") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct FanPlayerBallotSheet: View {
    @Environment(\.dismiss) private var dismiss
    let language: AppLanguage
    let candidates: [Player]
    let disabled: Bool
    let onSelect: (String) -> Void

    private var copy: FanModeCopy { FanModeCopy(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(copy.choosePlayer)
                    .font(SpyTheme.brandFont(size: 26))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(SpyTheme.control, in: CutCornerShape(cut: 7))
                }
                .buttonStyle(SpyWebPressStyle())
                .accessibilityLabel(copy.close)
                .accessibilityIdentifier("fanMode.vote.players.close")
            }
            Text(copy.playerVoteHint)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 9) {
                    ForEach(candidates) { player in
                        Button {
                            guard !disabled else { return }
                            onSelect(player.email)
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                Text(player.avatar)
                                    .font(.system(size: 28))
                                    .frame(width: 42, height: 42)
                                Text(player.name)
                                    .font(SpyTheme.brandFont(size: 19))
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(SpyTheme.dim)
                            }
                            .foregroundStyle(.white)
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                            .background(SpyTheme.control, in: CutCornerShape(cut: 9))
                            .overlay(CutCornerShape(cut: 9).stroke(SpyTheme.strokeStrong, lineWidth: 1))
                        }
                        .buttonStyle(SpyWebPressStyle())
                        .disabled(disabled)
                        .accessibilityIdentifier("fanMode.vote.players.\(player.email)")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("fanMode.vote.players.list")
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fanMode.vote.players")
    }
}
