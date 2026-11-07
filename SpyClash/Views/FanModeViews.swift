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
                    )).font(.system(size: 14, weight: .bold, design: .monospaced))
                        .tint(SpyTheme.amber).disabled(!editable).accessibilityIdentifier("fanMode.enabled")
                    Text(copy.rules).font(.system(size: 12, design: .monospaced)).foregroundStyle(SpyTheme.muted).fixedSize(horizontal: false, vertical: true)
                    if settings.isEnabled {
                        chance(.allSpies)
                        chance(.noSpies)
                        HStack {
                            Text(FanScenario.standard.title(language))
                            Spacer()
                            Text("\(settings.standardChance)%").monospacedDigit()
                        }.font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(SpyTheme.green)
                        Text(copy.scenarioHint)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(SpyTheme.dim).fixedSize(horizontal: false, vertical: true)
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

/// Player-only voting keeps the hidden surprise a surprise.
struct FanVoteMenu: View {
    let language: AppLanguage
    let selectedTarget: String?
    let selectedPlayerName: String?
    let isPending: Bool
    let disabled: Bool
    let onChoosePlayer: () -> Void

    private var copy: FanModeCopy { FanModeCopy(language: language) }
    private var playerSelected: Bool { selectedTarget != nil }

    var body: some View {
        VStack(spacing: 9) {
            choice(copy.voteForPlayer, icon: "person.crop.circle.badge.questionmark",
                   selected: playerSelected, subtitle: selectedPlayerName, opensList: true,
                   accent: .white, id: "fanMode.vote.player", action: onChoosePlayer)

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
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
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
                .font(.system(size: 13, design: .monospaced))
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
                                    .font(.system(size: 19, weight: .bold, design: .monospaced))
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

/// The same terminal reveal is used on the shared phone and every online client.
struct FanDrawRevealView: View {
    let scenario: FanScenario
    let language: AppLanguage
    @SpyReduceMotion private var reduceMotion
    @State private var revealedCount = 0
    @State private var showOutcome = false

    private var copy: FanModeCopy { FanModeCopy(language: language) }
    private var accent: Color { scenario == .allSpies ? SpyTheme.amber : SpyTheme.green }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("FAN MODE").tracking(2)
                Image(systemName: "sparkles")
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(accent)

            Text(showOutcome ? copy.drawTitle : copy.revealTitle)
                .font(.system(size: 25, weight: .black, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .accessibilityIdentifier("fanMode.result.title")

            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    roleCard(index)
                }
            }
            .frame(height: 100)
            .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text(showOutcome ? copy.revealedScenario(scenario) : copy.revealSubtitle)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fanMode.result.scenario")
                if showOutcome {
                    Text(copy.drawSubtitle)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(SpyTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .accessibilityIdentifier("fanMode.result.drawExplanation")
                }
            }
        }
        .padding(.vertical, 26)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background {
            CutCornerShape(cut: 18)
                .fill(accent.opacity(0.055))
                .overlay(CutCornerShape(cut: 18).stroke(accent.opacity(0.45), lineWidth: 1))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fanMode.result.draw")
        .task(id: scenario) {
            revealedCount = 0
            showOutcome = false
            if reduceMotion {
                revealedCount = 3
                showOutcome = true
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(320))
                for count in 1...3 {
                    try Task.checkCancellation()
                    withAnimation(.easeInOut(duration: 0.4)) { revealedCount = count }
                    try await Task.sleep(for: .milliseconds(240))
                }
                try await Task.sleep(for: .milliseconds(220))
                try Task.checkCancellation()
                withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) { showOutcome = true }
                HapticManager.shared.fire(.navigation)
            } catch {
                // Leaving the result cancels the reveal without a delayed haptic.
            }
        }
    }

    private func roleCard(_ index: Int) -> some View {
        let revealed = index < revealedCount
        return ZStack {
            cardFace(icon: "questionmark", revealed: false)
                .opacity(revealed ? 0 : 1)
            cardFace(icon: scenario == .allSpies ? "eye.slash.fill" : "person.fill.checkmark", revealed: true)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(revealed ? 1 : 0)
        }
        .frame(maxWidth: 76)
        .frame(height: 96)
        .rotation3DEffect(.degrees(revealed ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .rotationEffect(.degrees(Double(index - 1) * (showOutcome ? 8 : 3)))
        .offset(y: showOutcome && index == 1 ? -5 : 0)
    }

    private func cardFace(icon: String, revealed: Bool) -> some View {
        ZStack {
            CutCornerShape(cut: 9)
                .fill(revealed ? accent.opacity(0.18) : SpyTheme.control)
            CutCornerShape(cut: 9)
                .stroke(revealed ? accent : Color.white.opacity(0.22), lineWidth: 1.5)
            Image(systemName: icon)
                .font(.system(size: 29, weight: .bold))
                .foregroundStyle(revealed ? accent : SpyTheme.dim)
        }
    }
}
