#if SPYCLASH_SUPABASE
import Foundation

/// App-service writes retain their exact request ID and payload across transport failures.
/// Each action has one unresolved intent per account. Credential-link bodies are never persisted here.
@MainActor
final class SupabaseAppMutationJournal {
    private struct Entry: Codable {
        let actorID: String
        let source: JSONValue
        let body: JSONValue
    }
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SupabaseAppMutations/bbkfsgnordtdiblgdzkg", isDirectory: true)
    }

    func prepare(actorID: String, body: [String: JSONValue]) throws -> [String: JSONValue] {
        guard UUID(uuidString: actorID) != nil,
              let service = body["service"]?.string, let action = body["action"]?.string,
              !Self.containsCredential(.object(body)) else { throw Self.invalidIntent }
        var source = body; source.removeValue(forKey: "request_id")
        var entries = try load(actorID)
        if let prior = entries.first(where: { $0.source["service"].string == service && $0.source["action"].string == action }) {
            guard prior.actorID == actorID, prior.source == .object(source),
                  let saved = prior.body.object else { throw Self.recoveryRequired }
            // Reopened views can suggest a new UUID. The unresolved logical
            // action must still use its original durable request and body.
            return saved
        }
        guard entries.count < 32 else { throw Self.recoveryRequired }
        var command = body
        if command["request_id"] == nil { command["request_id"] = .string(UUID().uuidString.lowercased()) }
        guard let requestID = command["request_id"]?.string, UUID(uuidString: requestID) != nil else { throw Self.invalidIntent }
        entries.append(Entry(actorID: actorID, source: .object(source), body: .object(command)))
        try save(entries, actorID: actorID)
        return command
    }

    func acknowledge(actorID: String, requestID: String) throws {
        let entries = try load(actorID).filter { $0.body["request_id"].string != requestID }
        try save(entries, actorID: actorID)
    }

    private func load(_ actorID: String) throws -> [Entry] {
        let file = try fileURL(actorID)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([Entry].self, from: data),
              entries.count <= 32, entries.allSatisfy({ $0.actorID == actorID }) else { throw Self.storageFailure }
        return entries
    }

    private func save(_ entries: [Entry], actorID: String) throws {
        do {
            let file = try fileURL(actorID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(entries).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { throw Self.storageFailure }
    }

    private func fileURL(_ actorID: String) throws -> URL {
        guard UUID(uuidString: actorID) != nil else { throw Self.invalidIntent }
        return directory.appendingPathComponent(actorID.lowercased() + ".json")
    }

    private static func containsCredential(_ value: JSONValue) -> Bool {
        if let object = value.object {
            let forbidden = Set(["password", "access_token", "refresh_token", "base44_access_token", "base44_token", "legacy_access_token"])
            return object.contains { forbidden.contains($0.key.lowercased()) || containsCredential($0.value) }
        }
        return value.array.contains(where: containsCredential)
    }
    private static var recoveryRequired: Base44Error { Base44Error(message: "A previous action is still saved. Retry that same action before changing it.", statusCode: 409, code: "app_action_recovery_required", retryable: true) }
    private static var invalidIntent: Base44Error { Base44Error(message: "This action cannot be stored safely.", code: "invalid_app_action") }
    private static var storageFailure: Base44Error { Base44Error(message: "The action could not be saved securely. Retry when device storage is available.", code: "app_action_storage_failed", retryable: true) }
}
#endif
