import SwiftUI

/// A small insignia rail on the profile; requirements appear only on selection.
struct SpyAchievementsView: View {
    let progress: [SpyAchievementProgress]
    let language: AppLanguage
    @SpyReduceMotion private var reduceMotion
    @State private var expanded = false
    @State private var selectedID: String?

    private var awards: [SpyAchievementProgress] {
        SpyAchievementCatalog.normalized(progress).sorted {
            if $0.isUnlocked != $1.isUnlocked { return $0.isUnlocked }
            return catalogIndex($0.id) < catalogIndex($1.id)
        }
    }
    private var unlockedCount: Int { awards.filter(\.isUnlocked).count }
    private var visibleAwards: [SpyAchievementProgress] { expanded ? awards : Array(awards.prefix(5)) }
    private var selectedAward: SpyAchievementProgress? { awards.first { $0.id == selectedID } }
    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.2) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(motion) {
                    expanded.toggle()
                    if !expanded, !visibleAwards.contains(where: { $0.id == selectedID }) { selectedID = nil }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("//").foregroundStyle(SpyTheme.red)
                    Text(localized("ACHIEVEMENTS", "ДОСТИЖЕНИЯ", "LOGROS", "ДОСЯГНЕННЯ"))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer(minLength: 6)
                    Text("\(unlockedCount)").foregroundStyle(.white)
                    Text("/ \(awards.count)").foregroundStyle(SpyTheme.muted)
                    AchievementChevron()
                        .stroke(SpyTheme.red, style: StrokeStyle(lineWidth: 1.5, lineCap: .square))
                        .frame(width: 8, height: 4)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .padding(.leading, 3)
                }
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .tracking(0.8)
                .monospacedDigit()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localized("Achievements, \(unlockedCount) of \(awards.count) unlocked", "Достижения: открыто \(unlockedCount) из \(awards.count)", "Logros: \(unlockedCount) de \(awards.count) desbloqueados", "Досягнення: відкрито \(unlockedCount) із \(awards.count)"))
            .accessibilityValue(expanded
                ? localized("All achievements", "Все достижения", "Todos los logros", "Усі досягнення")
                : localized("Featured achievements", "Избранные достижения", "Logros destacados", "Вибрані досягнення"))
            .accessibilityHint(localized("Show or hide the full collection", "Показать или свернуть всю коллекцию", "Mostrar u ocultar la colección", "Показати або згорнути колекцію"))
            .accessibilityIdentifier("achievements.expand")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 6) {
                ForEach(visibleAwards) { award in
                    if let definition = SpyAchievementID(rawValue: award.id) {
                        insignia(award, definition: definition)
                    }
                }
            }
            .padding(.bottom, 12)

            if let selectedAward, let definition = SpyAchievementID(rawValue: selectedAward.id) {
                detail(selectedAward, definition: definition)
                    .id(selectedAward.id)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .background(SpyTheme.card, in: CutCornerShape(cut: 8))
        .overlay(CutCornerShape(cut: 8).stroke(.white.opacity(0.09), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func insignia(_ award: SpyAchievementProgress, definition: SpyAchievementID) -> some View {
        let isSelected = selectedID == award.id
        return Button {
            withAnimation(motion) { selectedID = isSelected ? nil : award.id }
            HapticManager.shared.fire(.tabSelection)
        } label: {
            VStack(spacing: 6) {
                SpyAchievementGlyph(achievement: definition)
                    .foregroundStyle(isSelected ? SpyTheme.red : (award.isUnlocked ? .white.opacity(0.88) : .white.opacity(0.3)))
                    .frame(width: 32, height: 32)
                Rectangle()
                    .fill(award.isUnlocked ? SpyTheme.red : .white.opacity(0.18))
                    .frame(width: award.isUnlocked ? 12 : 6, height: 2)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(isSelected ? SpyTheme.red.opacity(0.08) : .clear, in: CutCornerShape(cut: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(definition.title(language))
        .accessibilityValue("\(definition.requirement(language)). \(award.boundedProgress) / \(award.target). \(award.isUnlocked ? earned : localized("Locked", "Не получено", "Bloqueado", "Не отримано"))")
        .accessibilityHint(localized("Show achievement details", "Открыть описание достижения", "Ver detalles del logro", "Відкрити опис досягнення"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("achievement.\(award.id)")
    }

    private func detail(_ award: SpyAchievementProgress, definition: SpyAchievementID) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Rectangle().fill(.white.opacity(0.09)).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(definition.title(language))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(award.isUnlocked ? earned.uppercased() : "\(award.boundedProgress) / \(award.target)")
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundStyle(award.isUnlocked ? SpyTheme.red : SpyTheme.muted)
                    .monospacedDigit()
                    .fixedSize()
            }
            Text(definition.requirement(language))
                .font(.caption)
                .foregroundStyle(SpyTheme.bodyText)
                .fixedSize(horizontal: false, vertical: true)
            if !award.isUnlocked {
                GeometryReader { geometry in
                    Rectangle().fill(.white.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(SpyTheme.red).frame(width: geometry.size.width * award.fraction)
                        }
                }
                .frame(height: 2)
                .accessibilityHidden(true)
            }
        }
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("achievements.detail")
    }

    private var earned: String { localized("Earned", "Получено", "Obtenido", "Отримано") }
    private func catalogIndex(_ id: String) -> Int { SpyAchievementID.allCases.firstIndex { $0.id == id } ?? 0 }
    private func localized(_ en: String, _ ru: String, _ es: String, _ uk: String) -> String {
        switch language { case .ru: ru; case .es: es; case .uk: uk; default: en }
    }
}

private struct AchievementChevron: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
    }
}
