import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try box.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .object(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .string(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .bool(let value): try box.encode(value)
        case .null: try box.encodeNil()
        }
    }

    subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var array: [JSONValue] { if case .array(let value) = self { return value }; return [] }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var integer: Int { if case .number(let value) = self { return Int(value) }; return 0 }
    var bool: Bool { if case .bool(let value) = self { return value }; return false }
    var isNull: Bool { self == .null }
    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

struct LabFailure: Error, LocalizedError {
    let code: String
    var ambiguous = false
    var errorDescription: String? { code }
    var json: JSONValue { .object(["code": .string(code), "message": .string(code), "ambiguous": .bool(ambiguous)]) }
}

func safeFailure(_ error: Error) -> LabFailure {
    if let error = error as? LabFailure { return error }
    if let error = error as? URLError { return LabFailure(code: "transport_\(error.code.rawValue)", ambiguous: true) }
    if error is CancellationError { return LabFailure(code: "cancelled", ambiguous: true) }
    return LabFailure(code: "unexpected_response", ambiguous: true)
}
