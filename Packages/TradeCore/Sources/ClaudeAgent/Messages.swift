import Foundation

/// Modely Claude, které agent nabízí.
public struct ClaudeModel: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var note: String

    public init(id: String, name: String, note: String) {
        self.id = id
        self.name = name
        self.note = note
    }

    public static let opus = ClaudeModel(id: "claude-opus-5-5", name: "Opus 5.5", note: "nejchytřejší, výchozí")
    public static let sonnet = ClaudeModel(id: "claude-sonnet-5-5", name: "Sonnet 5.5", note: "rychlý a levnější")
    public static let haiku = ClaudeModel(id: "claude-haiku-5-5", name: "Haiku 5.5", note: "nejrychlejší a nejlevnější")

    public static let all: [ClaudeModel] = [.opus, .sonnet, .haiku]

    public static func named(_ id: String) -> ClaudeModel {
        all.first { $0.id == id } ?? .opus
    }
}

public enum Role: String, Codable, Sendable {
    case user
    case assistant
}

/// Jedna zpráva konverzace. Bloky obsahu se drží jako surový JSON,
/// aby se API vracely přesně tak, jak přišly (i neznámé typy bloků).
public struct Message: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var role: Role
    public var content: [JSONValue]

    public init(id: UUID = UUID(), role: Role, content: [JSONValue]) {
        self.id = id
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> Message {
        Message(role: .user, content: [Block.text(text)])
    }

    /// Text všech textových bloků zprávy.
    public var text: String {
        content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
            .joined(separator: "\n\n")
    }

    /// Volání nástrojů v asistentově zprávě.
    public var toolUses: [ToolUse] {
        content.compactMap(ToolUse.init(block:))
    }

    /// Výsledky nástrojů v uživatelské zprávě.
    public var toolResults: [ToolResult] {
        content.compactMap(ToolResult.init(block:))
    }

    var apiValue: JSONValue {
        ["role": .string(role.rawValue), "content": .array(content)]
    }
}

/// Konstruktory bloků obsahu.
public enum Block {
    public static func text(_ text: String) -> JSONValue {
        ["type": "text", "text": .string(text)]
    }

    public static func toolResult(id: String, content: String, isError: Bool) -> JSONValue {
        var o: [String: JSONValue] = [
            "type": "tool_result",
            "tool_use_id": .string(id),
            "content": .string(content),
        ]
        if isError { o["is_error"] = true }
        return .object(o)
    }
}

public struct ToolUse: Hashable, Sendable {
    public var id: String
    public var name: String
    public var input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }

    init?(block: JSONValue) {
        guard block["type"]?.stringValue == "tool_use",
              let id = block["id"]?.stringValue,
              let name = block["name"]?.stringValue else { return nil }
        self.init(id: id, name: name, input: block["input"] ?? [:])
    }
}

public struct ToolResult: Hashable, Sendable {
    public var toolUseID: String
    public var content: String
    public var isError: Bool

    init?(block: JSONValue) {
        guard block["type"]?.stringValue == "tool_result",
              let id = block["tool_use_id"]?.stringValue else { return nil }
        toolUseID = id
        if let s = block["content"]?.stringValue {
            content = s
        } else if let parts = block["content"]?.arrayValue {
            content = parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        } else {
            content = ""
        }
        isError = block["is_error"]?.boolValue ?? false
    }
}

public struct Usage: Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    init(json: JSONValue?) {
        self.init(inputTokens: json?["input_tokens"]?.intValue ?? 0,
                  outputTokens: json?["output_tokens"]?.intValue ?? 0,
                  cacheReadTokens: json?["cache_read_input_tokens"]?.intValue ?? 0,
                  cacheWriteTokens: json?["cache_creation_input_tokens"]?.intValue ?? 0)
    }

    public static func + (a: Usage, b: Usage) -> Usage {
        Usage(inputTokens: a.inputTokens + b.inputTokens,
              outputTokens: a.outputTokens + b.outputTokens,
              cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens,
              cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens)
    }

    /// Všechny vstupní tokeny včetně cache.
    public var totalInput: Int { inputTokens + cacheReadTokens + cacheWriteTokens }
}

/// Definice nástroje pro API.
public struct ToolDefinition: Hashable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    var apiValue: JSONValue {
        ["name": .string(name), "description": .string(description), "input_schema": inputSchema]
    }
}

/// Požadavek na `POST /v1/messages`.
public struct MessagesRequest: Sendable {
    public var model: String
    public var maxTokens: Int
    public var system: String?
    public var messages: [Message]
    public var tools: [ToolDefinition]

    public init(model: String, maxTokens: Int, system: String?, messages: [Message], tools: [ToolDefinition]) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.tools = tools
    }

    /// Tělo požadavku. Cache breakpointy: konec systémového promptu (nástroje + systém)
    /// a poslední blok poslední zprávy (rostoucí konverzace).
    public var body: JSONValue {
        var o: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
        ]
        if let system, !system.isEmpty {
            o["system"] = [["type": "text", "text": .string(system), "cache_control": ["type": "ephemeral"]]]
        }
        var apiMessages = messages.map(\.apiValue)
        if var last = apiMessages.last?.objectValue,
           var blocks = last["content"]?.arrayValue,
           var lastBlock = blocks.last?.objectValue {
            lastBlock["cache_control"] = ["type": "ephemeral"]
            blocks[blocks.count - 1] = .object(lastBlock)
            last["content"] = .array(blocks)
            apiMessages[apiMessages.count - 1] = .object(last)
        }
        o["messages"] = .array(apiMessages)
        if !tools.isEmpty {
            o["tools"] = .array(tools.map(\.apiValue))
            o["tool_choice"] = ["type": "auto"]
        }
        return .object(o)
    }
}

public struct MessagesResponse: Sendable {
    public var id: String
    public var content: [JSONValue]
    public var stopReason: String?
    public var usage: Usage

    public init(id: String = "msg", content: [JSONValue], stopReason: String?, usage: Usage = Usage()) {
        self.id = id
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }

    public init(json: JSONValue) throws {
        guard json["type"]?.stringValue == "message", let content = json["content"]?.arrayValue else {
            throw ClaudeAPIError.invalidResponse
        }
        self.init(id: json["id"]?.stringValue ?? "",
                  content: content,
                  stopReason: json["stop_reason"]?.stringValue,
                  usage: Usage(json: json["usage"]))
    }
}

public enum ClaudeAPIError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case http(status: Int, type: String?, message: String?)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Chybí API klíč. Zadej ho v nastavení agenta."
        case .invalidResponse:
            return "Neočekávaná odpověď Claude API."
        case .http(let status, let type, let message):
            let base: String
            switch status {
            case 401: base = "Neplatný API klíč"
            case 403: base = "Klíč nemá oprávnění"
            case 404: base = "Model nenalezen"
            case 413: base = "Požadavek je moc velký"
            case 429: base = "Překročen limit požadavků"
            case 529: base = "Claude API je přetížené"
            case 500...599: base = "Chyba serveru Claude API"
            default: base = "Chyba Claude API (\(status))"
            }
            if let message, !message.isEmpty {
                return "\(base): \(message)"
            }
            return type.map { "\(base) (\($0))" } ?? base
        }
    }

    /// Rozparsuje chybové tělo `{"type":"error","error":{"type":…,"message":…}}`.
    public static func from(status: Int, body: Data) -> ClaudeAPIError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        return .http(status: status,
                     type: json?["error"]?["type"]?.stringValue,
                     message: json?["error"]?["message"]?.stringValue)
    }

    var isRetryable: Bool {
        if case .http(let status, _, _) = self { return status == 429 || status == 529 || (500...599).contains(status) }
        return false
    }
}
