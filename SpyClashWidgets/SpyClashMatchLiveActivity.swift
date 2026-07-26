import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

struct SpyClashMatchLiveActivity: Widget {
    typealias Attributes = SpyClashMatchActivityAttributes

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: Attributes.self) { context in
            SpyClashMatchLockScreenView(
                attributes: context.attributes,
                state: context.state,
                isStale: context.isStale
            )
            .activityBackgroundTint(SpyClashActivityPalette.background)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(matchURL(for: context.attributes.roomID))
        } dynamicIsland: { context in
            let state = context.state.sanitized(
                for: context.attributes.viewerPlayerID
            )
            let copy = SpyClashLiveActivityCopy(
                languageCode: state.displayLanguageCode
            )

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(copy.round) \(state.round)")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundStyle(SpyClashActivityPalette.red)
                        Text(copy.modeLabel(state.mode))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(SpyClashActivityPalette.muted)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    SpyClashActivityTimer(state: state)
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(SpyClashActivityPalette.green)
                        .monospacedDigit()
                }

                DynamicIslandExpandedRegion(.center) {
                    SpyClashTurnSummary(state: state, compact: true)
                        .padding(.horizontal, 8)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    SpyClashPlayerRail(state: state)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Text(state.speaker?.avatarSymbol ?? "🎯")
                    .font(.system(size: 15))
                    .accessibilityLabel(state.speaker?.displayName ?? "SpyClash")
            } compactTrailing: {
                SpyClashActivityTimer(state: state)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(SpyClashActivityPalette.green)
                    .monospacedDigit()
            } minimal: {
                Text(state.speaker?.avatarSymbol ?? "🎯")
                    .font(.system(size: 14))
                    .accessibilityLabel(state.speaker?.displayName ?? "SpyClash match")
            }
            .keylineTint(SpyClashActivityPalette.red)
            .widgetURL(matchURL(for: context.attributes.roomID))
        }
    }

    private func matchURL(for roomID: String) -> URL? {
        let encoded = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        return encoded.flatMap { URL(string: "spyclash://match/\($0)") }
    }

}

private struct SpyClashMatchLockScreenView: View {
    typealias Attributes = SpyClashMatchActivityAttributes

    let attributes: Attributes
    let state: Attributes.ContentState
    let isStale: Bool

    private var sanitizedState: Attributes.ContentState {
        state.sanitized(for: attributes.viewerPlayerID)
    }

    var body: some View {
        let currentState = sanitizedState

        VStack(spacing: 5) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Text("SPY")
                        .foregroundStyle(SpyClashActivityPalette.red)
                    Text("CLASH")
                        .foregroundStyle(.white)
                }
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .tracking(1)

                Spacer(minLength: 12)

                SpyClashActivityTimer(state: currentState)
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundStyle(SpyClashActivityPalette.green)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 60, alignment: .trailing)
            }
            .frame(height: 19)
            .frame(maxWidth: .infinity)

            HStack(alignment: .center, spacing: 20) {
                SpyClashRoundTableView(state: currentState)
                    .frame(width: 136, height: 120)
                    .fixedSize()

                SpyClashLockScreenTurnSummary(state: currentState)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 156)
        .foregroundStyle(.white)
        .opacity(isStale ? 0.78 : 1)
        .accessibilityValue(isStale ? "Match data may be out of date" : "Live match data")
    }
}

private struct SpyClashRoundTableView: View {
    typealias Attributes = SpyClashMatchActivityAttributes

    let state: Attributes.ContentState

    private var visiblePlayers: [Attributes.Participant] {
        var players = Array(state.participants.prefix(8))
        guard state.participants.count > players.count,
              let speaker = state.speaker,
              !players.contains(where: { $0.id == speaker.id }),
              !players.isEmpty else {
            return players
        }
        players[players.count - 1] = speaker
        return players
    }

    private var hiddenPlayerCount: Int {
        max(0, state.participants.count - visiblePlayers.count)
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let nodeSize: CGFloat = 28
            let radius = max(18, (side - nodeSize) / 2)

            ZStack {
                Circle()
                    .stroke(SpyClashActivityPalette.ring, lineWidth: 0.8)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)

                ForEach(Array(visiblePlayers.enumerated()), id: \.element.id) { index, player in
                    let angle = ((Double(index) / Double(max(visiblePlayers.count, 1))) * 2 * Double.pi) - (Double.pi / 2)
                    let x = center.x + (CGFloat(cos(angle)) * radius)
                    let y = center.y + (CGFloat(sin(angle)) * radius)

                    SpyClashPlayerNode(
                        player: player,
                        isSpeaker: player.id == state.currentSpeakerID
                    )
                    .position(x: x, y: y)
                }

                if hiddenPlayerCount > 0 {
                    Text("+\(hiddenPlayerCount)")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(SpyClashActivityPalette.muted)
                        .position(center)
                        .accessibilityLabel("\(hiddenPlayerCount) more players")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Players around the SpyClash table")
    }
}

private struct SpyClashPlayerNode: View {
    let player: SpyClashMatchActivityAttributes.Participant
    let isSpeaker: Bool

    private var ringColor: Color {
        if isSpeaker { return SpyClashActivityPalette.green }
        return SpyClashActivityPalette.ring
    }

    private var turnLabel: String {
        isSpeaker ? "speaking" : "at table"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(SpyClashActivityPalette.panel)
                .overlay(Circle().stroke(ringColor, lineWidth: isSpeaker ? 2 : 1))
                .frame(width: 28, height: 28)
                .overlay {
                    Text(player.avatarSymbol)
                        .font(.system(size: 15))
                }

            if isSpeaker {
                Circle()
                    .fill(ringColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(SpyClashActivityPalette.background, lineWidth: 1))
            }
        }
        .opacity(player.status == .active ? 1 : 0.42)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(player.displayName), \(turnLabel)")
    }
}

private struct SpyClashLockScreenTurnSummary: View {
    typealias Attributes = SpyClashMatchActivityAttributes

    @Environment(\.locale) private var locale

    let state: Attributes.ContentState

    private var copy: SpyClashLiveActivityCopy {
        SpyClashLiveActivityCopy(
            languageCode: state.displayLanguageCode
                ?? locale.language.languageCode?.identifier
        )
    }

    private var topic: String {
        let value = state.publicTopic?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return copy.defaultTopic }
        if ["CLASSIC", "CLASICO", "CLÁSICO", "КЛАССИКА"].contains(value.uppercased()) {
            return copy.defaultTopic
        }
        return value.uppercased(with: locale)
    }

    var body: some View {
        Group {
            switch state.phase {
            case .preparing:
                status(title: copy.preparing, detail: copy.waiting, color: SpyClashActivityPalette.amber)
            case .voting:
                status(title: copy.voting, detail: copy.identifySpy, color: SpyClashActivityPalette.red)
            case .completed:
                status(title: copy.completed, detail: copy.openForResults, color: SpyClashActivityPalette.green)
            case .playing:
                if state.mode == .associations {
                    associationTurn
                } else {
                    questionTurn
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var questionTurn: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow(copy.question)

            (agentNameText(state.asker)
                + Text(" → ").foregroundColor(SpyClashActivityPalette.red)
                + agentNameText(state.responder))
            .font(.system(size: 17, weight: .black, design: .monospaced))
            .fontWidth(.condensed)
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .frame(maxWidth: .infinity, alignment: .leading)

            (Text("\(copy.topic) ").foregroundColor(SpyClashActivityPalette.red)
                + Text(topic).foregroundColor(.white))
            .font(.system(size: 12, weight: .black, design: .monospaced))
            .fontWidth(.condensed)
            .lineLimit(1)
            .minimumScaleFactor(0.68)
        }
    }

    private var associationTurn: some View {
        VStack(alignment: .leading, spacing: 7) {
            eyebrow(copy.speaking)

            agentName(state.speaker, size: 20)

            Text(copy.topic)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .fontWidth(.condensed)
                .foregroundStyle(SpyClashActivityPalette.red)

            Text(topic)
                .font(.system(size: 15, weight: .black, design: .monospaced))
                .fontWidth(.condensed)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
    }

    private func eyebrow(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11, weight: .black, design: .monospaced))
            .fontWidth(.condensed)
            .foregroundStyle(SpyClashActivityPalette.muted)
            .lineLimit(1)
    }

    private func agentName(_ player: Attributes.Participant?, size: CGFloat = 15) -> some View {
        Text(player?.compactName ?? copy.awaiting)
            .font(.system(size: size, weight: .black, design: .monospaced))
            .fontWidth(.condensed)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .layoutPriority(1)
    }

    private func agentNameText(_ player: Attributes.Participant?) -> Text {
        Text(player?.compactName ?? copy.awaiting)
            .foregroundColor(.white)
    }

    private func status(title: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .black, design: .monospaced))
                .foregroundStyle(color)
            Text(detail)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(SpyClashActivityPalette.muted)
                .lineLimit(2)
        }
    }
}

private struct SpyClashLiveActivityCopy {
    let round: String
    let questionsMode: String
    let associationsMode: String
    let question: String
    let speaking: String
    let topic: String
    let defaultTopic: String
    let awaiting: String
    let preparing: String
    let waiting: String
    let voting: String
    let identifySpy: String
    let completed: String
    let openForResults: String
    let asks: String
    let answers: String
    let associationTurn: String
    let respondingNow: String
    let speakingNow: String
    let awaitingTurn: String
    let pending: String

    func modeLabel(_ mode: SpyClashMatchActivityAttributes.MatchMode) -> String {
        switch mode {
        case .questions: questionsMode
        case .associations: associationsMode
        }
    }

    init(languageCode: String?) {
        switch languageCode {
        case "ru":
            round = "РАУНД"
            questionsMode = "ВОПРОСЫ"
            associationsMode = "АССОЦИАЦИИ"
            question = "ВОПРОС"
            speaking = "ГОВОРИТ:"
            topic = "ТЕМА:"
            defaultTopic = "КЛАССИКА"
            awaiting = "ОЖИДАНИЕ"
            preparing = "ПОДКЛЮЧЕНИЕ"
            waiting = "ОЖИДАНИЕ ИГРОКОВ"
            voting = "ГОЛОСОВАНИЕ"
            identifySpy = "НАЙДИТЕ ШПИОНА"
            completed = "МИССИЯ ЗАВЕРШЕНА"
            openForResults = "ОТКРОЙТЕ SPYCLASH"
            asks = "СПРАШИВАЕТ"
            answers = "ОТВЕЧАЕТ"
            associationTurn = "ХОД АССОЦИАЦИИ"
            respondingNow = "ОТВЕЧАЕТ СЕЙЧАС"
            speakingNow = "СЕЙЧАС ГОВОРИТ"
            awaitingTurn = "ОЖИДАНИЕ ХОДА"
            pending = "ОЖИДАНИЕ"
        case "es":
            round = "RONDA"
            questionsMode = "PREGUNTAS"
            associationsMode = "ASOCIACIONES"
            question = "PREGUNTA"
            speaking = "HABLA:"
            topic = "TEMA:"
            defaultTopic = "CLÁSICO"
            awaiting = "ESPERANDO"
            preparing = "CONECTANDO"
            waiting = "ESPERANDO JUGADORES"
            voting = "VOTACIÓN"
            identifySpy = "IDENTIFICA AL ESPÍA"
            completed = "MISIÓN COMPLETADA"
            openForResults = "ABRE SPYCLASH"
            asks = "PREGUNTA"
            answers = "RESPONDE"
            associationTurn = "TURNO DE ASOCIACIÓN"
            respondingNow = "RESPONDIENDO"
            speakingNow = "HABLANDO AHORA"
            awaitingTurn = "ESPERANDO TURNO"
            pending = "PENDIENTE"
        default:
            round = "ROUND"
            questionsMode = "Q&A"
            associationsMode = "ASSOCIATIONS"
            question = "QUESTION"
            speaking = "SPEAKING:"
            topic = "TOPIC:"
            defaultTopic = "CLASSIC"
            awaiting = "AWAITING"
            preparing = "FIELD LINK"
            waiting = "WAITING FOR PLAYERS"
            voting = "VOTE ACTIVE"
            identifySpy = "IDENTIFY THE SPY"
            completed = "MISSION COMPLETE"
            openForResults = "OPEN SPYCLASH"
            asks = "ASKS"
            answers = "ANSWERS"
            associationTurn = "ASSOCIATION TURN"
            respondingNow = "RESPONDING NOW"
            speakingNow = "SPEAKING NOW"
            awaitingTurn = "AWAITING TURN"
            pending = "PENDING"
        }
    }
}

private struct SpyClashTurnSummary: View {
    typealias Attributes = SpyClashMatchActivityAttributes

    let state: Attributes.ContentState
    let compact: Bool

    private var copy: SpyClashLiveActivityCopy {
        SpyClashLiveActivityCopy(languageCode: state.displayLanguageCode)
    }

    var body: some View {
        Group {
            switch state.phase {
            case .preparing:
                status(title: copy.preparing, detail: copy.waiting, color: SpyClashActivityPalette.amber)
            case .voting:
                status(title: copy.voting, detail: copy.identifySpy, color: SpyClashActivityPalette.red)
            case .completed:
                status(title: copy.completed, detail: copy.openForResults, color: SpyClashActivityPalette.green)
            case .playing:
                if state.mode == .associations {
                    associationTurn
                } else {
                    questionTurn
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var questionTurn: some View {
        VStack(alignment: compact ? .center : .leading, spacing: compact ? 3 : 5) {
            turnHeader

            HStack(spacing: 5) {
                agentName(state.asker, color: SpyClashActivityPalette.red)
                Image(systemName: "arrow.right")
                    .font(.system(size: compact ? 9 : 11, weight: .black))
                    .foregroundStyle(SpyClashActivityPalette.red)
                agentName(state.responder, color: .white)
            }

            if compact {
                HStack(spacing: 5) {
                    label(copy.asks, color: SpyClashActivityPalette.red)
                    Text("→")
                        .foregroundStyle(SpyClashActivityPalette.muted)
                    label(copy.answers, color: .white)
                }
            }
        }
    }

    private var associationTurn: some View {
        VStack(alignment: compact ? .center : .leading, spacing: compact ? 3 : 5) {
            Text(copy.associationTurn)
                .font(.system(size: compact ? 8 : 9, weight: .black, design: .monospaced))
                .foregroundStyle(SpyClashActivityPalette.muted)

            HStack(spacing: 6) {
                Text(state.speaker?.avatarSymbol ?? "🎯")
                    .font(.system(size: compact ? 17 : 22))
                agentName(state.speaker, color: SpyClashActivityPalette.green)
            }

            label(copy.respondingNow, color: SpyClashActivityPalette.green)
        }
    }

    private var turnHeader: some View {
        VStack(alignment: compact ? .center : .leading, spacing: 1) {
            Text(copy.speakingNow)
                .font(.system(size: compact ? 8 : 9, weight: .black, design: .monospaced))
                .foregroundStyle(SpyClashActivityPalette.muted)
            Text(state.speaker?.compactName ?? copy.awaitingTurn)
                .font(.system(size: compact ? 11 : 13, weight: .black, design: .monospaced))
                .foregroundStyle(SpyClashActivityPalette.green)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
    }

    private func status(title: String, detail: String, color: Color) -> some View {
        VStack(alignment: compact ? .center : .leading, spacing: 5) {
            Text(title)
                .font(.system(size: compact ? 11 : 13, weight: .black, design: .monospaced))
                .foregroundStyle(color)
            Text(detail)
                .font(.system(size: compact ? 8 : 9, weight: .bold, design: .monospaced))
                .foregroundStyle(SpyClashActivityPalette.muted)
                .lineLimit(2)
        }
    }

    private func agentName(_ player: Attributes.Participant?, color: Color) -> some View {
        Text(player?.compactName ?? copy.pending)
            .font(.system(size: compact ? 9 : 11, weight: .black, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
    }

    private func label(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.system(size: compact ? 7 : 8, weight: .black, design: .monospaced))
            .foregroundStyle(color.opacity(0.78))
            .lineLimit(1)
    }
}

private struct SpyClashPrivateIntelView: View {
    @Environment(\.redactionReasons) private var redactionReasons

    let intel: SpyClashMatchActivityAttributes.PrivateIntel
    let compact: Bool

    private var hidesPrivateContent: Bool {
        redactionReasons.contains(.privacy)
    }

    var body: some View {
        HStack(spacing: compact ? 5 : 8) {
            Image(systemName: hidesPrivateContent ? "lock.shield.fill" : "eye.trianglebadge.exclamationmark")
                .font(.system(size: compact ? 10 : 11, weight: .bold))
                .foregroundStyle(SpyClashActivityPalette.red)

            VStack(alignment: .leading, spacing: 0) {
                Text(hidesPrivateContent ? "PRIVATE ROLE" : intel.role.displayName)
                    .font(.system(size: compact ? 8 : 9, weight: .black, design: .monospaced))
                    .foregroundStyle(SpyClashActivityPalette.red)
                Text(hidesPrivateContent ? "LOCKED" : intel.wordForDisplay.uppercased())
                    .font(.system(size: compact ? 9 : 11, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }

            if !compact {
                Spacer(minLength: 4)
                Text("EYES ONLY")
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .foregroundStyle(SpyClashActivityPalette.muted)
            }
        }
        .padding(.horizontal, compact ? 0 : 8)
        .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? nil : 27, alignment: .leading)
        .background(compact ? Color.clear : SpyClashActivityPalette.panel)
        .overlay {
            if !compact {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(SpyClashActivityPalette.red.opacity(0.45), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Private role and word for this device")
    }
}

private struct SpyClashActivityTimer: View {
    let state: SpyClashMatchActivityAttributes.ContentState

    var body: some View {
        if let pausedSeconds = state.pausedSecondsRemaining {
            Text(formatted(seconds: pausedSeconds))
        } else if let endDate = state.timerEndsAt {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(
                    formatted(
                        seconds: Int(
                            max(0, endDate.timeIntervalSince(timeline.date))
                                .rounded(.down)
                        )
                    )
                )
            }
        } else {
            Text("--:--")
        }
    }

    private func formatted(seconds: Int) -> String {
        let safe = max(0, seconds)
        return String(format: "%d:%02d", safe / 60, safe % 60)
    }
}

private struct SpyClashPlayerRail: View {
    let state: SpyClashMatchActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: -3) {
            ForEach(Array(state.participants.prefix(6))) { player in
                Text(player.avatarSymbol)
                    .font(.system(size: 13))
                    .frame(width: 22, height: 22)
                    .background(SpyClashActivityPalette.panel, in: Circle())
                    .overlay(
                        Circle().stroke(
                            player.id == state.currentSpeakerID
                                ? SpyClashActivityPalette.green
                                : SpyClashActivityPalette.stroke,
                            lineWidth: 1
                        )
                    )
                    .opacity(player.status == .active ? 1 : 0.4)
            }
        }
        .accessibilityLabel("\(state.participants.count) players in match")
    }
}

private enum SpyClashActivityPalette {
    static let background = Color(red: 5 / 255, green: 5 / 255, blue: 5 / 255)
    static let panel = Color(red: 15 / 255, green: 15 / 255, blue: 15 / 255)
    static let table = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
    static let stroke = Color(red: 50 / 255, green: 50 / 255, blue: 50 / 255)
    static let ring = Color(red: 104 / 255, green: 104 / 255, blue: 104 / 255)
    static let muted = Color(red: 130 / 255, green: 130 / 255, blue: 130 / 255)
    static let red = Color(red: 229 / 255, green: 53 / 255, blue: 53 / 255)
    static let green = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255)
    static let amber = Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)
}
