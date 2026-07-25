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

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ROUND \(state.round)")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundStyle(SpyClashActivityPalette.red)
                        Text(state.mode.shortLabel)
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
                .font(.system(size: 15, weight: .black, design: .monospaced))
                .tracking(1.2)

                Text("R\(currentState.round)")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(SpyClashActivityPalette.muted)

                Text(currentState.mode.shortLabel)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(SpyClashActivityPalette.red)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if isStale {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SpyClashActivityPalette.amber)
                        .accessibilityLabel("Match data may be out of date")
                }

                SpyClashActivityTimer(state: currentState)
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(SpyClashActivityPalette.green)
                    .monospacedDigit()
            }
            .frame(height: 17)

            HStack(spacing: 10) {
                SpyClashRoundTableView(state: currentState)
                    .frame(maxWidth: 132)
                    .frame(height: 82)

                SpyClashTurnSummary(state: currentState, compact: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("ROLE & WORD STAY PROTECTED IN SPYCLASH")
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(SpyClashActivityPalette.muted)
            .frame(maxWidth: .infinity, minHeight: 27)
            .background(SpyClashActivityPalette.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(SpyClashActivityPalette.stroke, lineWidth: 1)
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .opacity(isStale ? 0.78 : 1)
    }
}

private struct SpyClashRoundTableView: View {
    typealias Attributes = SpyClashMatchActivityAttributes

    let state: Attributes.ContentState

    private var visiblePlayers: [Attributes.Participant] {
        Array(state.participants.prefix(8))
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = max(18, (side / 2) - 15)

            ZStack {
                Circle()
                    .fill(SpyClashActivityPalette.table)
                    .overlay(
                        Circle()
                            .stroke(SpyClashActivityPalette.stroke, lineWidth: 1)
                    )
                    .frame(width: side - 20, height: side - 20)
                    .position(center)

                VStack(spacing: 0) {
                    Text(state.speaker?.avatarSymbol ?? "🎯")
                        .font(.system(size: 19))
                    if state.participants.count > visiblePlayers.count {
                        Text("+\(state.participants.count - visiblePlayers.count)")
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .foregroundStyle(SpyClashActivityPalette.muted)
                    }
                }
                .position(center)

                ForEach(Array(visiblePlayers.enumerated()), id: \.element.id) { index, player in
                    let angle = ((Double(index) / Double(max(visiblePlayers.count, 1))) * 2 * Double.pi) - (Double.pi / 2)
                    let x = center.x + (CGFloat(cos(angle)) * radius)
                    let y = center.y + (CGFloat(sin(angle)) * radius)

                    SpyClashPlayerNode(
                        player: player,
                        isSpeaker: player.id == state.currentSpeakerID,
                        isAsker: player.id == state.currentAskerID,
                        isResponder: player.id == state.currentResponderID
                    )
                    .position(x: x, y: y)
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
    let isAsker: Bool
    let isResponder: Bool

    private var ringColor: Color {
        if isSpeaker { return SpyClashActivityPalette.green }
        if isAsker { return SpyClashActivityPalette.red }
        if isResponder { return .white }
        return SpyClashActivityPalette.stroke
    }

    private var turnLabel: String {
        var roles: [String] = []
        if isSpeaker { roles.append("speaking") }
        if isAsker { roles.append("asking") }
        if isResponder { roles.append("answering") }
        return roles.isEmpty ? "at table" : roles.joined(separator: ", ")
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(SpyClashActivityPalette.panel)
                .overlay(Circle().stroke(ringColor, lineWidth: isSpeaker ? 2 : 1))
                .frame(width: 27, height: 27)
                .overlay {
                    Text(player.avatarSymbol)
                        .font(.system(size: 14))
                }

            if isSpeaker || isAsker || isResponder {
                Circle()
                    .fill(ringColor)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(SpyClashActivityPalette.background, lineWidth: 1))
            }
        }
        .opacity(player.status == .active ? 1 : 0.42)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(player.displayName), \(turnLabel)")
    }
}

private struct SpyClashTurnSummary: View {
    typealias Attributes = SpyClashMatchActivityAttributes

    let state: Attributes.ContentState
    let compact: Bool

    var body: some View {
        Group {
            switch state.phase {
            case .preparing:
                status(title: "FIELD LINK", detail: "WAITING FOR PLAYERS", color: SpyClashActivityPalette.amber)
            case .voting:
                status(title: "VOTE ACTIVE", detail: "IDENTIFY THE SPY", color: SpyClashActivityPalette.red)
            case .completed:
                status(title: "MISSION COMPLETE", detail: "OPEN SPYCLASH FOR RESULTS", color: SpyClashActivityPalette.green)
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

            HStack(spacing: 5) {
                label("ASKS", color: SpyClashActivityPalette.red)
                Text("→")
                    .foregroundStyle(SpyClashActivityPalette.muted)
                label("ANSWERS", color: .white)
            }
        }
    }

    private var associationTurn: some View {
        VStack(alignment: compact ? .center : .leading, spacing: compact ? 3 : 5) {
            Text("ASSOCIATION TURN")
                .font(.system(size: compact ? 8 : 9, weight: .black, design: .monospaced))
                .foregroundStyle(SpyClashActivityPalette.muted)

            HStack(spacing: 6) {
                Text(state.speaker?.avatarSymbol ?? "🎯")
                    .font(.system(size: compact ? 17 : 22))
                agentName(state.speaker, color: SpyClashActivityPalette.green)
            }

            label("RESPONDING NOW", color: SpyClashActivityPalette.green)
        }
    }

    private var turnHeader: some View {
        VStack(alignment: compact ? .center : .leading, spacing: 1) {
            Text("SPEAKING NOW")
                .font(.system(size: compact ? 8 : 9, weight: .black, design: .monospaced))
                .foregroundStyle(SpyClashActivityPalette.muted)
            Text(state.speaker?.compactName ?? "AWAITING TURN")
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
        Text(player?.compactName ?? "PENDING")
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
            Text(
                timerInterval: Date.now...max(Date.now, endDate),
                countsDown: true
            )
        } else {
            Text("--:--")
        }
    }

    private func formatted(seconds: Int) -> String {
        let safe = max(0, seconds)
        return String(format: "%02d:%02d", safe / 60, safe % 60)
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
    static let muted = Color(red: 130 / 255, green: 130 / 255, blue: 130 / 255)
    static let red = Color(red: 229 / 255, green: 53 / 255, blue: 53 / 255)
    static let green = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255)
    static let amber = Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)
}
