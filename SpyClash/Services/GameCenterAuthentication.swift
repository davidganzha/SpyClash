#if SPYCLASH_SUPABASE
import Foundation
@preconcurrency import GameKit
@preconcurrency import UIKit

/// Apple signs the player, bundle, timestamp and salt. The server must verify
/// that signature before it creates or returns a SpyClash account.
struct GameCenterIdentityProof: Codable, Equatable, Sendable {
    let teamPlayerID: String
    let bundleID: String
    let publicKeyURL: String
    let signature: String
    let salt: String
    let timestamp: UInt64
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case teamPlayerID = "team_player_id"
        case bundleID = "bundle_id"
        case publicKeyURL = "public_key_url"
        case signature, salt, timestamp
        case displayName = "display_name"
    }
}

enum GameCenterAuthenticationError: Error, Equatable {
    case cancelled, unavailable, timedOut, invalidProof, presentationUnavailable
}

@MainActor
protocol GameCenterAuthenticating: AnyObject {
    func authenticate() async throws -> GameCenterIdentityProof
    func cancel()
}

@MainActor
protocol GameCenterPlayerClient: AnyObject {
    var isAuthenticated: Bool { get }
    var teamPlayerID: String { get }
    var displayName: String { get }
    func initialize(handler: @escaping @MainActor (UIViewController?, Error?) -> Void)
    func fetchIdentity(handler: @escaping @MainActor (URL?, Data?, Data?, UInt64, Error?) -> Void)
    func stop()
}

@MainActor
private final class SystemGameCenterPlayer: GameCenterPlayerClient {
    var isAuthenticated: Bool { GKLocalPlayer.local.isAuthenticated }
    var teamPlayerID: String { GKLocalPlayer.local.teamPlayerID }
    var displayName: String { GKLocalPlayer.local.displayName }

    func initialize(handler: @escaping @MainActor (UIViewController?, Error?) -> Void) {
        GKLocalPlayer.local.authenticateHandler = { controller, error in
            Task { @MainActor in handler(controller, error) }
        }
    }

    func fetchIdentity(handler: @escaping @MainActor (URL?, Data?, Data?, UInt64, Error?) -> Void) {
        GKLocalPlayer.local.fetchItems(forIdentityVerificationSignature: { url, signature, salt, timestamp, error in
            Task { @MainActor in handler(url, signature, salt, timestamp, error) }
        })
    }

    func stop() { GKLocalPlayer.local.authenticateHandler = nil }
}

/// One attempt owns its GameKit callbacks and presentation. In particular,
/// a delayed callback cannot complete a newer manual sign-in or a second call.
@MainActor
final class GameCenterAuthentication: GameCenterAuthenticating {
    private let player: any GameCenterPlayerClient
    private let bundleID: String
    private let timeout: Duration
    private let presenter: @MainActor (UIViewController) -> Bool
    private var continuation: CheckedContinuation<GameCenterIdentityProof, Error>?
    private var attemptID: UUID?
    private var isFetchingProof = false
    private var timeoutTask: Task<Void, Never>?
    private weak var presentedController: UIViewController?

    init(
        player: (any GameCenterPlayerClient)? = nil,
        bundleID: String = Bundle.main.bundleIdentifier ?? "",
        timeout: Duration = .seconds(90),
        presenter: @escaping @MainActor (UIViewController) -> Bool = GameCenterAuthentication.present
    ) {
        self.player = player ?? SystemGameCenterPlayer()
        self.bundleID = bundleID
        self.timeout = timeout
        self.presenter = presenter
    }

    func authenticate() async throws -> GameCenterIdentityProof {
        guard continuation == nil else { throw GameCenterAuthenticationError.unavailable }
        let attempt = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                attemptID = attempt
                isFetchingProof = false
                timeoutTask = Task { @MainActor [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(.failure(GameCenterAuthenticationError.timedOut), attempt: attempt)
                }
                player.initialize { [weak self] controller, error in
                    self?.received(controller: controller, error: error, attempt: attempt)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()), attempt: attempt)
            }
        }
    }

    func cancel() {
        guard let attemptID else { return }
        finish(.failure(CancellationError()), attempt: attemptID)
    }

    private func received(controller: UIViewController?, error: Error?, attempt: UUID) {
        guard attemptID == attempt, continuation != nil else { return }
        if let error {
            let nsError = error as NSError
            let failure: GameCenterAuthenticationError = nsError.domain == GKErrorDomain && nsError.code == GKError.cancelled.rawValue ? .cancelled : .unavailable
            finish(.failure(failure), attempt: attempt)
            return
        }
        if let controller {
            if presentedController === controller { return }
            guard presentedController == nil, presenter(controller) else {
                finish(.failure(GameCenterAuthenticationError.presentationUnavailable), attempt: attempt)
                return
            }
            presentedController = controller
            return
        }
        guard player.isAuthenticated else {
            finish(.failure(GameCenterAuthenticationError.unavailable), attempt: attempt)
            return
        }
        guard !isFetchingProof else { return }
        isFetchingProof = true
        let playerID = player.teamPlayerID
        let displayName = player.displayName
        guard !playerID.isEmpty, !bundleID.isEmpty else {
            finish(.failure(GameCenterAuthenticationError.invalidProof), attempt: attempt)
            return
        }
        player.fetchIdentity { [weak self] url, signature, salt, timestamp, error in
            guard let self, self.attemptID == attempt, self.continuation != nil else { return }
            guard error == nil, self.player.isAuthenticated, self.player.teamPlayerID == playerID,
                  let url, url.scheme?.lowercased() == "https", url.host != nil,
                  let signature, !signature.isEmpty, let salt, !salt.isEmpty, timestamp > 0 else {
                self.finish(.failure(GameCenterAuthenticationError.invalidProof), attempt: attempt)
                return
            }
            self.finish(.success(GameCenterIdentityProof(
                teamPlayerID: playerID, bundleID: self.bundleID, publicKeyURL: url.absoluteString,
                signature: signature.base64EncodedString(), salt: salt.base64EncodedString(),
                timestamp: timestamp, displayName: displayName
            )), attempt: attempt)
        }
    }

    private func finish(_ result: Result<GameCenterIdentityProof, Error>, attempt: UUID) {
        guard attemptID == attempt, let continuation else { return }
        self.continuation = nil
        attemptID = nil
        isFetchingProof = false
        timeoutTask?.cancel()
        timeoutTask = nil
        player.stop()
        if let controller = presentedController, controller.presentingViewController != nil {
            controller.dismiss(animated: false)
        }
        presentedController = nil
        continuation.resume(with: result)
    }

    static func present(_ controller: UIViewController) -> Bool {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return false }
        while let presented = top.presentedViewController { top = presented }
        guard !top.isBeingDismissed, !top.isBeingPresented else { return false }
        top.present(controller, animated: true)
        return true
    }
}

/// Auto entry is a cold-start convenience, not permission to undo logout or
/// replace an account whose saved session is awaiting a network retry.
@MainActor
final class GameCenterAutomaticEntryPolicy {
    static let optOutKey = "spyclash.gamecenter.automatic-entry-disabled"
    private let defaults: UserDefaults
    private(set) var hasAttempted = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func begin(hasUser: Bool, hasSavedSession: Bool, isBusy: Bool, recoveryPresented: Bool) -> Bool {
        guard !hasAttempted, !defaults.bool(forKey: Self.optOutKey),
              !hasUser, !hasSavedSession, !isBusy, !recoveryPresented else { return false }
        hasAttempted = true
        return true
    }

    func disableAutomaticEntry() {
        hasAttempted = true
        defaults.set(true, forKey: Self.optOutKey)
    }

    /// Only an explicit Game Center button may clear a previous choice to
    /// stay signed out. Foreground activation never calls this method.
    func allowExplicitEntry() {
        hasAttempted = false
        defaults.removeObject(forKey: Self.optOutKey)
    }
}
#endif
