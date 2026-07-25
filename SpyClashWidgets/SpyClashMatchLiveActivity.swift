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
                        HStack(spacing: 1) {
                            Text("SPY")
                                .foregroundStyle(SpyClashActivityPalette.red)
                            Text("CLASH")
                                .foregroundStyle(.white)
                        }
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.5)

                        Text("R\(state.round) // \(state.mode.shortLabel)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(SpyClashActivityPalette.muted)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    SpyClashActivityTimer(state: state)
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(SpyClashActivityPalette.red)
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
                Image(systemName: "scope")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(SpyClashActivityPalette.red)
                    .accessibilityLabel("SpyClash")
            } compactTrailing: {
                SpyClashActivityTimer(state: state)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(SpyClashActivityPalette.red)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "scope")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(SpyClashActivityPalette.red)
                    .accessibilityLabel("SpyClash match")
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

        ZStack {
            SpyClashActivityBackdrop()

            VStack(spacing: 7) {
                SpyClashActivityHeader(state: currentState, isStale: isStale)

                HStack(spacing: 7) {
                    SpyClashActiveAgentPanel(state: currentState)
                        .frame(width: 126, height: 79)

                    SpyClashTurnSummary(state: currentState, compact: false)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 79, alignment: .leading)
                        .background(
                            SpyClashActivityPalette.panel,
                            in: SpyClashActivityCutCornerShape(cut: 8)
                        )
                        .overlay {
                            SpyClashActivityCutCornerShape(cut: 8)
                                .stroke(SpyClashActivityPalette.stroke, lineWidth: 1)
                        }
                        .overlay(alignment: .topLeading) {
                            Rectangle()
                                .fill(SpyClashActivityPalette.red)
                                .frame(width: 28, height: 2)
                        }
                }

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(SpyClashActivityPalette.red)
                    Text("ROLE + WORD REMAIN INSIDE SPYCLASH")
                    Spacer(minLength: 4)
                    Text("SECURE")
                        .foregroundStyle(.white)
                }
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundStyle(SpyClashActivityPalette.muted)
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 25)
                .background(
                    SpyClashActivityPalette.panelElevated,
                    in: SpyClashActivityCutCornerShape(cut: 6)
                )
                .overlay {
                    SpyClashActivityCutCornerShape(cut: 6)
                        .stroke(SpyClashActivityPalette.stroke, lineWidth: 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .foregroundStyle(.white)
        .opacity(isStale ? 0.78 : 1)
    }
}

private struct SpyClashActivityHeader: View {
    typealias Attributes = SpyClashMatchActivityAttributes

    let state: Attributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 2) {
                Text("SPY")
                    .foregroundStyle(SpyClashActivityPalette.red)
                Text("CLASH")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 15, weight: .black, design: .monospaced))
            .tracking(1.1)

            Rectangle()
                .fill(SpyClashActivityPalette.red)
                .frame(width: 2, height: 13)

            Text("LIVE MATCH")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundStyle(SpyClashActivityPalette.muted)

            Text("R\(String(format: "%02d", state.round))")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.white)

            Text(state.mode.shortLabel)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundStyle(SpyClashActivityPalette.red)
                .lineLimit(1)

            Spacer(minLength: 4)

            if isStale {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(SpyClashActivityPalette.red)
                    .accessibilityLabel("Match data may be out of date")
            }

            HStack(spacing: 5) {
                Rectangle()
                    .fill(SpyClashActivityPalette.red)
                    .frame(width: 4, height: 4)

                SpyClashActivityTimer(state: state)
                    .monospacedDigit()
            }
            .font(.system(size: 15, weight: .black, design: .monospaced))
            .foregroundStyle(.white)
        }
        .frame(height: 17)
    }
}

private struct SpyClashActiveAgentPanel: View {
    typealias Attributes = SpyClashMatchActivityAttributes

    let state: Attributes.ContentState

    private var visiblePlayers: [Attributes.Participant] {
        Array(state.participants.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("// ACTIVE AGENT")
                    .foregroundStyle(SpyClashActivityPalette.red)
                Spacer(minLength: 2)
                Text("\(state.participants.count) ONLINE")
                    .foregroundStyle(SpyClashActivityPalette.muted)
            }
            .font(.system(size: 7, weight: .black, design: .monospaced))

            HStack(spacing: 7) {
                Text(state.speaker?.avatarSymbol ?? "🕵️")
                    .font(.system(size: 25))
                    .frame(width: 39, height: 39)
                    .background(
                        SpyClashActivityPalette.background,
                        in: SpyClashActivityCutCornerShape(cut: 6)
                    )
                    .overlay {
                        SpyClashActivityCutCornerShape(cut: 6)
                            .stroke(SpyClashActivityPalette.red.opacity(0.82), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("SPEAKING")
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                        .foregroundStyle(SpyClashActivityPalette.muted)
                    Text(state.speaker?.compactName ?? "AWAITING")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.66)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 3) {
                ForEach(visiblePlayers) { player in
                    Text(player.avatarSymbol)
                        .font(.system(size: 10))
                        .frame(width: 20, height: 16)
                        .background(
                            player.id == state.currentSpeakerID
                                ? SpyClashActivityPalette.red.opacity(0.22)
                                : SpyClashActivityPalette.background,
                            in: SpyClashActivityCutCornerShape(cut: 3)
                        )
                        .overlay {
                            SpyClashActivityCutCornerShape(cut: 3)
                                .stroke(
                                    player.id == state.currentSpeakerID
                                        ? SpyClashActivityPalette.red
                                        : SpyClashActivityPalette.stroke,
                                    lineWidth: 1
                                )
                        }
                        .opacity(player.status == .active ? 1 : 0.4)
                }

                if state.participants.count > visiblePlayers.count {
                    Text("+\(state.participants.count - visiblePlayers.count)")
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                        .foregroundStyle(SpyClashActivityPalette.muted)
                }
            }
        }
        .padding(7)
        .background(
            SpyClashActivityPalette.panel,
            in: SpyClashActivityCutCornerShape(cut: 8)
        )
        .overlay {
            SpyClashActivityCutCornerShape(cut: 8)
                .stroke(SpyClashActivityPalette.stroke, lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            Rectangle()
                .fill(SpyClashActivityPalette.red)
                .frame(width: 24, height: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Active agent \(state.speaker?.displayName ?? "awaiting turn")")
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
                status(title: "FIELD LINK", detail: "WAITING FOR PLAYERS", color: SpyClashActivityPalette.red)
            case .voting:
                status(title: "VOTE ACTIVE", detail: "IDENTIFY THE SPY", color: SpyClashActivityPalette.red)
            case .completed:
                status(title: "MISSION COMPLETE", detail: "OPEN SPYCLASH FOR RESULTS", color: .white)
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
                agentName(state.speaker, color: .white)
            }

            label("RESPONDING NOW", color: SpyClashActivityPalette.red)
        }
    }

    private var turnHeader: some View {
        VStack(alignment: compact ? .center : .leading, spacing: 1) {
            Text("SPEAKING NOW")
                .font(.system(size: compact ? 8 : 9, weight: .black, design: .monospaced))
                .foregroundStyle(SpyClashActivityPalette.muted)
            Text(state.speaker?.compactName ?? "AWAITING TURN")
                .font(.system(size: compact ? 11 : 13, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
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
                SpyClashActivityCutCornerShape(cut: 6)
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
                    .background(
                        player.id == state.currentSpeakerID
                            ? SpyClashActivityPalette.red.opacity(0.22)
                            : SpyClashActivityPalette.panel,
                        in: SpyClashActivityCutCornerShape(cut: 4)
                    )
                    .overlay(
                        SpyClashActivityCutCornerShape(cut: 4).stroke(
                            player.id == state.currentSpeakerID
                                ? SpyClashActivityPalette.red
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

private struct SpyClashActivityCutCornerShape: Shape {
    let cut: CGFloat

    func path(in rect: CGRect) -> Path {
        let resolvedCut = min(max(cut, 0), min(rect.width, rect.height) * 0.28)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - resolvedCut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + resolvedCut))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + resolvedCut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - resolvedCut))
        path.closeSubpath()
        return path
    }
}

private struct SpyClashActivityBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                SpyClashActivityPalette.background

                RadialGradient(
                    colors: [
                        SpyClashActivityPalette.red.opacity(0.16),
                        SpyClashActivityPalette.red.opacity(0.035),
                        .clear
                    ],
                    center: UnitPoint(x: 0.24, y: 0.42),
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.78
                )

                Canvas { context, size in
                    var grid = Path()
                    let spacing: CGFloat = 25

                    stride(from: CGFloat.zero, through: size.width, by: spacing).forEach { x in
                        grid.move(to: CGPoint(x: x, y: 0))
                        grid.addLine(to: CGPoint(x: x, y: size.height))
                    }

                    stride(from: CGFloat.zero, through: size.height, by: spacing).forEach { y in
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }

                    context.stroke(
                        grid,
                        with: .color(SpyClashActivityPalette.red.opacity(0.055)),
                        lineWidth: 0.7
                    )
                }

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                SpyClashActivityPalette.red.opacity(0.68),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
                    .offset(y: (proxy.size.height * 0.5) - 1)

                Rectangle()
                    .fill(SpyClashActivityPalette.red.opacity(0.65))
                    .frame(width: 1)
                    .offset(x: -(proxy.size.width * 0.31))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private enum SpyClashActivityPalette {
    static let background = Color(red: 5 / 255, green: 5 / 255, blue: 5 / 255)
    static let panel = Color(red: 15 / 255, green: 15 / 255, blue: 15 / 255)
    static let panelElevated = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
    static let stroke = Color(red: 50 / 255, green: 50 / 255, blue: 50 / 255)
    static let muted = Color(red: 130 / 255, green: 130 / 255, blue: 130 / 255)
    static let red = Color(red: 229 / 255, green: 53 / 255, blue: 53 / 255)
}
