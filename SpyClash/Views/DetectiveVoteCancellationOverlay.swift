import Foundation
import SwiftUI

struct DetectiveVoteCancellationEvent: Equatable, Identifiable {
    static let supportedReason = "no_viable_candidate"

    let roomID: String
    let eventID: String
    let roundID: String
    let presentAt: Date
    let reason: String

    var id: String { "\(roomID)|\(eventID)" }

    init?(room: GameRoom) {
        let roomID = Self.clean(room.id)
        let eventID = Self.clean(room.detectiveVoteCancellationEventID)
        let roundID = Self.clean(room.detectiveVoteCancellationRoundID)
        let reason = Self.clean(room.detectiveVoteCancellationReason).lowercased()
        guard !roomID.isEmpty,
              !eventID.isEmpty,
              !roundID.isEmpty,
              reason == Self.supportedReason,
              let presentAt = Self.parseISO8601(room.detectiveVoteCancellationPresentAt) else {
            return nil
        }

        self.roomID = roomID
        self.eventID = eventID
        self.roundID = roundID
        self.presentAt = presentAt
        self.reason = reason
    }

    init(
        roomID: String,
        eventID: String,
        roundID: String,
        presentAt: Date,
        reason: String = DetectiveVoteCancellationEvent.supportedReason
    ) {
        self.roomID = roomID
        self.eventID = eventID
        self.roundID = roundID
        self.presentAt = presentAt
        self.reason = reason
    }

    private static func clean(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        let normalized = clean(value)
        guard !normalized.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: normalized) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: normalized)
    }
}

struct DetectiveVoteCancellationTiming: Equatable {
    let startDelay: TimeInterval
    let elapsedAtStart: TimeInterval
    let visibleDuration: TimeInterval
    let endAt: Date
}

enum DetectiveVoteCancellationPresentationPolicy {
    /// Every device derives the scene from the same absolute server timestamp.
    /// A client joining mid-scene renders only the remaining synchronized time.
    static let presentationDuration: TimeInterval = 4.8
    static let maximumFutureLead: TimeInterval = 8

    static func timing(
        for event: DetectiveVoteCancellationEvent,
        now: Date,
        handledEventIDs: Set<String>
    ) -> DetectiveVoteCancellationTiming? {
        guard !handledEventIDs.contains(event.id) else { return nil }

        let startDelay = max(event.presentAt.timeIntervalSince(now), 0)
        guard startDelay <= maximumFutureLead else { return nil }

        let endAt = event.presentAt.addingTimeInterval(presentationDuration)
        let visibleDuration = endAt.timeIntervalSince(max(now, event.presentAt))
        guard visibleDuration > 0 else { return nil }

        return DetectiveVoteCancellationTiming(
            startDelay: startDelay,
            elapsedAtStart: max(now.timeIntervalSince(event.presentAt), 0),
            visibleDuration: visibleDuration,
            endAt: endAt
        )
    }
}

struct DetectiveVoteCancellationCopy: Equatable {
    let title: String
    let body: String
    let footer: String

    var accessibilityAnnouncement: String {
        "\(title). \(body) \(footer)."
    }

    static func localized(languageCode rawLanguageCode: String) -> Self {
        let languageCode = rawLanguageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? "en"

        switch languageCode {
        case "ru":
            return Self(
                title: "МНЕНИЯ РАЗДЕЛИЛИСЬ",
                body: "Ни один подозреваемый уже не сможет набрать достаточно голосов.",
                footer: "ГОЛОСОВАНИЕ ОТМЕНЕНО · ИГРА ПРОДОЛЖАЕТСЯ"
            )
        case "es":
            return Self(
                title: "OPINIONES DIVIDIDAS",
                body: "Ningún sospechoso podrá reunir ya los votos suficientes.",
                footer: "VOTACIÓN CANCELADA · LA PARTIDA CONTINÚA"
            )
        case "uk":
            return Self(
                title: "ДУМКИ РОЗДІЛИЛИСЯ",
                body: "Жоден підозрюваний уже не зможе набрати достатньо голосів.",
                footer: "ГОЛОСУВАННЯ СКАСОВАНО · ГРА ТРИВАЄ"
            )
        default:
            return Self(
                title: "OPINIONS ARE DIVIDED",
                body: "No suspect can still receive enough votes.",
                footer: "VOTING CANCELLED · GAME CONTINUES"
            )
        }
    }
}

struct DetectiveVoteCancellationOverlay: View {
    @SpyReduceMotion private var reduceMotion

    let event: DetectiveVoteCancellationEvent
    let languageCode: String
    var previewProgress: Double? = nil

    private var copy: DetectiveVoteCancellationCopy {
        .localized(languageCode: languageCode)
    }

    var body: some View {
        Group {
            if let previewProgress {
                scene(progress: min(max(previewProgress, 0), 1))
            } else {
                TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 24.0 : 1.0 / 60.0)) { timeline in
                    scene(progress: progress(at: timeline.date))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.accessibilityAnnouncement)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("detective-vote-cancellation-overlay")
    }

    private func progress(at date: Date) -> Double {
        min(
            max(
                date.timeIntervalSince(event.presentAt) /
                    DetectiveVoteCancellationPresentationPolicy.presentationDuration,
                0
            ),
            1
        )
    }

    private func scene(progress: Double) -> some View {
        let entrance = segment(progress, from: 0, to: 0.14)
        let exit = segment(progress, from: 0.76, to: 1)
        let contentOpacity = entrance * (1 - exit)
        let backdropEntrance = segment(progress, from: 0, to: 0.08)
        let backdropExit = segment(progress, from: 0.90, to: 1)
        let backdropOpacity = backdropEntrance * (1 - backdropExit)
        let pulse = sin(progress * .pi * 6)

        return ZStack {
            Color.black
                .opacity(0.91 * backdropOpacity)

            RadialGradient(
                colors: [
                    SpyTheme.red.opacity(0.16 * backdropOpacity),
                    Color.clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: 360
            )
            .scaleEffect(reduceMotion ? 1 : 0.94 + (CGFloat(entrance) * 0.08))
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .stroke(SpyTheme.red.opacity(0.34), lineWidth: 1)
                        .frame(width: 70, height: 70)
                        .scaleEffect(reduceMotion ? 1 : 1 + (CGFloat(pulse) * 0.035))

                    Image(systemName: "person.2.fill")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(SpyTheme.bodyText)

                    Rectangle()
                        .fill(SpyTheme.red)
                        .frame(width: 49, height: 2)
                        .rotationEffect(.degrees(-38))
                        .shadow(color: SpyTheme.red.opacity(0.62), radius: 7)
                }
                .padding(.bottom, 28)
                .accessibilityHidden(true)

                Text(copy.title)
                    .font(SpyTheme.brandFont(size: 35))
                    .tracking(2.4)
                    .foregroundStyle(SpyTheme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 24)

                Rectangle()
                    .fill(SpyTheme.red)
                    .frame(width: 44, height: 2)
                    .padding(.vertical, 20)
                    .accessibilityHidden(true)

                Text(copy.body)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SpyTheme.bodyText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 370)
                    .padding(.horizontal, 30)

                HStack(spacing: 12) {
                    Rectangle()
                        .fill(SpyTheme.strokeStrong)
                        .frame(maxWidth: 42, maxHeight: 1)

                    Text(copy.footer)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(SpyTheme.red)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)

                    Rectangle()
                        .fill(SpyTheme.strokeStrong)
                        .frame(maxWidth: 42, maxHeight: 1)
                }
                .padding(.horizontal, 24)
                .padding(.top, 29)
            }
            .opacity(contentOpacity)
            .scaleEffect(
                reduceMotion
                    ? 1
                    : 0.94 + (CGFloat(entrance) * 0.06) + (CGFloat(exit) * 0.018)
            )
            .blur(radius: reduceMotion ? 0 : CGFloat(exit) * 5)
            .offset(y: reduceMotion ? 0 : CGFloat(1 - entrance) * 10)
        }
    }

    private func segment(_ value: Double, from start: Double, to end: Double) -> Double {
        guard end > start else { return value >= end ? 1 : 0 }
        return min(max((value - start) / (end - start), 0), 1)
    }
}

#if DEBUG
#Preview("Vote cancellation · RU") {
    ZStack {
        SpyTheme.dark
            .ignoresSafeArea()

        DetectiveVoteCancellationOverlay(
            event: DetectiveVoteCancellationEvent(
                roomID: "preview-room",
                eventID: "preview-event",
                roundID: "preview-round",
                presentAt: Date()
            ),
            languageCode: "ru",
            previewProgress: 0.42
        )
    }
}
#endif
