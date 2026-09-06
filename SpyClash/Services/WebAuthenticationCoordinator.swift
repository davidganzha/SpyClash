import AuthenticationServices
import Foundation

enum WebAuthenticationError: Error, Equatable, Sendable {
    case cancelled
    case expired
    case temporarilyUnavailable
    case invalidCallback
    case failed
    case couldNotStart
}

@MainActor
protocol WebAuthenticationSession: AnyObject {
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: WebAuthenticationSession {}

/// Owns the browser lifetime independently from the later token exchange.
/// Every terminal path clears ownership before cancelling the framework, whose
/// completion can arrive late or synchronously from a test/session adapter.
@MainActor
final class WebAuthenticationCoordinator {
    typealias Completion = @MainActor @Sendable (URL?, (any Error)?) -> Void
    typealias SessionFactory = @MainActor (URL, @escaping Completion) -> any WebAuthenticationSession
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct Attempt {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<URL, any Error>
        var session: (any WebAuthenticationSession)?
        var timeoutTask: Task<Void, Never>?
    }

    private let makeSession: SessionFactory
    private let now: @MainActor () -> Date
    private let sleep: Sleep
    private var attempt: Attempt?

    init(
        makeSession: @escaping SessionFactory,
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.makeSession = makeSession
        self.now = now
        self.sleep = sleep
    }

    func authenticate(url: URL, timeout: TimeInterval = 300) async throws -> URL {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0 else { throw WebAuthenticationError.expired }
        let id = UUID()
        let callback: URL = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                cancel()
                let deadline = now().addingTimeInterval(timeout)
                attempt = Attempt(id: id, deadline: deadline, continuation: continuation)
                let session = makeSession(url) { [weak self] callback, error in
                    self?.complete(id: id, callback: callback, error: error)
                }
                guard attempt?.id == id else {
                    session.cancel()
                    return
                }
                attempt?.session = session
                guard session.start() else {
                    finish(id: id, result: .failure(WebAuthenticationError.couldNotStart), cancelSession: true)
                    return
                }
                guard attempt?.id == id else { return }
                let remaining = deadline.timeIntervalSince(now())
                guard remaining > 0 else {
                    finish(id: id, result: .failure(WebAuthenticationError.expired), cancelSession: true)
                    return
                }
                let sleep = self.sleep
                attempt?.timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await sleep(.seconds(remaining))
                        try Task.checkCancellation()
                    } catch is CancellationError {
                        return
                    } catch {
                        self?.finish(id: id, result: .failure(WebAuthenticationError.failed), cancelSession: true)
                        return
                    }
                    self?.finish(id: id, result: .failure(WebAuthenticationError.expired), cancelSession: true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id: id, result: .failure(CancellationError()), cancelSession: true)
            }
        }
        // The framework callback may win the MainActor queue before the
        // cancellation handler arrives. The awaiting task still owns the
        // final cancellation check before returning a credential-bearing URL.
        try Task.checkCancellation()
        return callback
    }

    func cancel() {
        guard let id = attempt?.id else { return }
        finish(id: id, result: .failure(WebAuthenticationError.cancelled), cancelSession: true)
    }

    private func complete(id: UUID, callback: URL?, error: (any Error)?) {
        guard let current = attempt, current.id == id else { return }
        // The watchdog may not run while the app is suspended. A callback
        // arriving after that wall-clock deadline must still be rejected.
        guard now() < current.deadline else {
            finish(id: id, result: .failure(WebAuthenticationError.expired), cancelSession: true)
            return
        }
        if let error {
            let error = error as NSError
            let cancelled = error.domain == ASWebAuthenticationSessionError.errorDomain &&
                error.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
            finish(id: id, result: .failure(cancelled ? WebAuthenticationError.cancelled : .failed))
        } else if let callback {
            finish(id: id, result: .success(callback))
        } else {
            finish(id: id, result: .failure(WebAuthenticationError.invalidCallback))
        }
    }

    private func finish(id: UUID, result: Result<URL, any Error>, cancelSession: Bool = false) {
        guard let current = attempt, current.id == id else { return }
        attempt = nil
        current.timeoutTask?.cancel()
        if cancelSession { current.session?.cancel() }
        current.continuation.resume(with: result)
    }
}

enum WebAuthenticationCallback {
    static func accessToken(from url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "spyclash",
              components.percentEncodedHost?.lowercased() == "auth",
              ["", "/"].contains(components.percentEncodedPath),
              components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil else {
            throw WebAuthenticationError.invalidCallback
        }

        let items = components.queryItems ?? []
        let names = items.map(\.name)
        guard Set(names).count == names.count else { throw WebAuthenticationError.invalidCallback }
        let tokenItem = items.first { $0.name == "access_token" }
        let errorItem = items.first { $0.name == "error" }
        let errorDescription = items.first { $0.name == "error_description" }
        guard tokenItem == nil || (errorItem == nil && errorDescription == nil) else {
            throw WebAuthenticationError.invalidCallback
        }
        if let providerError = errorItem?.value, !providerError.isEmpty {
            switch providerError.lowercased() {
            case "access_denied", "user_cancelled", "user_canceled", "cancelled", "canceled":
                throw WebAuthenticationError.cancelled
            case "invalid_state":
                throw WebAuthenticationError.invalidCallback
            case "state_expired", "expired_state", "session_expired":
                throw WebAuthenticationError.expired
            case "temporarily_unavailable", "server_error", "service_unavailable":
                throw WebAuthenticationError.temporarilyUnavailable
            default:
                throw WebAuthenticationError.failed
            }
        }
        guard let token = tokenItem?.value,
              !token.isEmpty, token.count <= 20_000,
              token == token.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WebAuthenticationError.invalidCallback
        }
        return token
    }
}
