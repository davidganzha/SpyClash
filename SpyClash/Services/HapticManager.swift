import UIKit

@MainActor
final class HapticManager {
    static let shared = HapticManager()

    enum HapticType {
        case buttonPress
        case tabSelection
        case notification(UINotificationFeedbackGenerator.FeedbackType)
        case milestone
        case reveal
        case navigation
    }

    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private init() {
        selectionGenerator.prepare()
        impactGenerator.prepare()
        rigidGenerator.prepare()
    }

    func fire(_ type: HapticType, isEnabled: Bool = true) {
        guard isEnabled else { return }

        switch type {
        case .buttonPress:
            impactGenerator.impactOccurred(intensity: 0.62)
        case .tabSelection, .navigation:
            selectionGenerator.selectionChanged()
        case .notification(let feedback):
            notificationGenerator.notificationOccurred(feedback)
        case .milestone:
            notificationGenerator.notificationOccurred(.success)
        case .reveal:
            rigidGenerator.impactOccurred(intensity: 0.52)
        }
    }

    func playToastDismissFeedback() {
        rigidGenerator.impactOccurred(intensity: 0.22)
        rigidGenerator.prepare()
    }

}
