import SwiftUI

struct SpyAchievementsView: View {
    let progress: [SpyAchievementProgress]
    let language: AppLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var awards: [SpyAchievementProgress] { SpyAchievementCatalog.normalized(progress) }
    private var unlockedCount: Int { awards.filter(\.isUnlocked).count }
    private var visibleAwards: [SpyAchievementProgress] {
        let sorted = awards.sorted {
            if $0.isUnlocked != $1.isUnlocked { return $0.isUnlocked }
            if $0.isUnlocked, $0.target != $1.target { return $0.target > $1.target }
            if $0.fraction != $1.fraction { return $0.fraction > $1.fraction }
            let first = $0.id, second = $1.id
            return (SpyAchievementID.allCases.firstIndex { $0.id == first } ?? 0) < (SpyAchievementID.allCases.firstIndex { $0.id == second } ?? 0)
        }
        return expanded ? awards : Array(sorted.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "seal.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(SpyTheme.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("SERVICE RECORD", "НАГРАДЫ АГЕНТА", "EXPEDIENTE", "НАГОРОДИ АГЕНТА"))
                        .font(SpyTheme.micro)
                        .tracking(1.2)
                        .foregroundStyle(SpyTheme.amber)
                    Text(localized("Achievements", "Достижения", "Logros", "Досягнення"))
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 4)
                Text("\(unlockedCount)/\(awards.count)")
                    .font(.system(size: 23, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .accessibilityLabel(localized("Unlocked \(unlockedCount) of \(awards.count)", "Открыто \(unlockedCount) из \(awards.count)", "Desbloqueados \(unlockedCount) de \(awards.count)", "Відкрито \(unlockedCount) із \(awards.count)"))
            }

            Text(localized("Earn your insignia in completed online missions. Team FAN victories count towards missions and wins.", "Знаки отличия за завершённые онлайн-игры. Командные победы в FAN-mode идут в зачёт игр и побед.", "Gana insignias en misiones en línea completadas. Las victorias de equipo en FAN cuentan para partidas y victorias.", "Відзнаки за завершені онлайн-ігри. Командні перемоги у FAN-mode враховуються в іграх і перемогах."))
                .font(.system(size: 12))
                .foregroundStyle(SpyTheme.bodyText)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(visibleAwards) { award in
                    if let definition = SpyAchievementID(rawValue: award.id) {
                        awardTile(award, definition: definition)
                    }
                }
            }

            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack {
                    Text(expanded
                         ? localized("SHOW LESS", "СВЕРНУТЬ", "VER MENOS", "ЗГОРНУТИ")
                         : localized("ALL ACHIEVEMENTS", "ВСЕ ДОСТИЖЕНИЯ", "TODOS LOS LOGROS", "УСІ ДОСЯГНЕННЯ"))
                        .font(SpyTheme.micro)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(SpyTheme.amber)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("achievements.expand")
        }
        .padding(16)
        .background(SpyTheme.card)
        .overlay(CutCornerShape(cut: 12).stroke(SpyTheme.amber.opacity(0.27), lineWidth: 1))
        .accessibilityIdentifier("achievements.collection")
    }

    private func awardTile(_ award: SpyAchievementProgress, definition: SpyAchievementID) -> some View {
        let accent = award.isUnlocked ? (definition.isRare ? SpyTheme.amber : SpyTheme.green) : SpyTheme.muted
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                ZStack {
                    AchievementInsigniaShape()
                        .fill(LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    AchievementInsigniaShape()
                        .stroke(accent.opacity(award.isUnlocked ? 0.8 : 0.25), lineWidth: 1)
                    Image(systemName: definition.symbol)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 51, height: 56)
                .shadow(color: award.isUnlocked ? accent.opacity(0.13) : .clear, radius: 9)
                Spacer(minLength: 0)
                Image(systemName: award.isUnlocked ? "checkmark.seal.fill" : "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
                    .padding(.top, 4)
            }
            Text(definition.title(language))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(award.isUnlocked ? .white : SpyTheme.bodyText)
                .fixedSize(horizontal: false, vertical: true)
            Text(definition.requirement(language))
                .font(.system(size: 11))
                .foregroundStyle(SpyTheme.bodyText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Text(award.isUnlocked
                     ? localized("EARNED", "ПОЛУЧЕНО", "OBTENIDO", "ОТРИМАНО")
                     : localized("PROGRESS", "ПРОГРЕСС", "PROGRESO", "ПРОГРЕС"))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                Spacer(minLength: 2)
                Text("\(award.boundedProgress)/\(award.target)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(accent)
            ProgressView(value: award.fraction)
                .tint(accent)
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(award.isUnlocked ? accent.opacity(0.045) : SpyTheme.dark)
        .overlay(CutCornerShape(cut: 7).stroke(accent.opacity(award.isUnlocked ? 0.25 : 0.15), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(definition.title(language)). \(definition.requirement(language)). \(award.boundedProgress) / \(award.target). \(award.isUnlocked ? localized("Earned", "Получено", "Obtenido", "Отримано") : localized("Locked", "Не получено", "Bloqueado", "Не отримано"))")
        .accessibilityIdentifier("achievement.\(award.id)")
    }

    private func localized(_ en: String, _ ru: String, _ es: String, _ uk: String) -> String {
        switch language {
        case .ru: ru
        case .es: es
        case .uk: uk
        default: en
        }
    }
}

private struct AchievementInsigniaShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.25))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.75))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.75))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.25))
            path.closeSubpath()
        }
    }
}
