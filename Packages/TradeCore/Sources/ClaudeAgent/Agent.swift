import Foundation

/// Lokální nástroj, který Claude může zavolat.
public struct AgentTool: Sendable {
    public var definition: ToolDefinition
    public var run: @Sendable (JSONValue) async throws -> String

    public init(name: String, description: String, inputSchema: JSONValue,
                run: @escaping @Sendable (JSONValue) async throws -> String) {
        definition = ToolDefinition(name: name, description: description, inputSchema: inputSchema)
        self.run = run
    }

    public var name: String { definition.name }
}

/// Chyba nástroje se zprávou, kterou dostane model (a může na ni reagovat).
public struct ToolError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Průběh běhu agenta.
public enum AgentEvent: Sendable {
    /// Zpráva byla definitivně přidána do konverzace (aplikace ji má uložit).
    case message(Message)
    /// Začíná běh nástroje.
    case toolStarted(ToolUse)
    /// Nástroj doběhl.
    case toolFinished(ToolUse, output: String, isError: Bool)
    /// Spotřeba tokenů jednoho volání API.
    case usage(Usage)
}

public enum AgentStopReason: Equatable, Sendable {
    case endTurn
    case maxTokens
    case refusal
    case turnLimit
    case other(String)

    init(apiValue: String?) {
        switch apiValue {
        case "end_turn", "stop_sequence", nil: self = .endTurn
        case "max_tokens": self = .maxTokens
        case "refusal": self = .refusal
        case let other?: self = .other(other)
        }
    }
}

/// Smyčka tool use nad Messages API.
///
/// Pravidla API, která smyčka dodržuje:
/// - po asistentově zprávě s `tool_use` musí hned následovat uživatelská zpráva,
///   jejíž první bloky jsou `tool_result` se stejnými `tool_use_id`;
/// - asistentova zpráva a výsledky se do konverzace zapisují až společně,
///   takže zrušení uprostřed běhu nástrojů nenechá konverzaci v neplatném stavu;
/// - `pause_turn` znamená, že se má stejná konverzace poslat znovu.
public struct Agent: Sendable {
    public var transport: MessagesTransport
    public var model: String
    public var system: String?
    public var tools: [AgentTool]
    public var maxTokens: Int
    public var maxTurns: Int

    public init(transport: MessagesTransport, model: String = Provider.anthropic.defaultModel.id, system: String? = nil,
                tools: [AgentTool] = [], maxTokens: Int = 8_000, maxTurns: Int = 10) {
        self.transport = transport
        self.model = model
        self.system = system
        self.tools = tools
        self.maxTokens = maxTokens
        self.maxTurns = maxTurns
    }

    /// Pokračuje v konverzaci (poslední zpráva má být od uživatele) a vrátí důvod zastavení.
    @discardableResult
    public func run(conversation start: [Message],
                    onEvent: @escaping @Sendable (AgentEvent) async -> Void) async throws -> AgentStopReason {
        var conversation = start
        let definitions = tools.map(\.definition)

        for _ in 0..<maxTurns {
            try Task.checkCancellation()
            let request = MessagesRequest(model: model, maxTokens: maxTokens, system: system,
                                          messages: conversation, tools: definitions)
            let response = try await transport.send(request)
            await onEvent(.usage(response.usage))

            let assistant = Message(role: .assistant, content: response.content)

            switch response.stopReason {
            case "tool_use":
                let uses = assistant.toolUses
                var results: [JSONValue] = []
                for use in uses {
                    try Task.checkCancellation()
                    await onEvent(.toolStarted(use))
                    let (output, isError) = await execute(use)
                    await onEvent(.toolFinished(use, output: output, isError: isError))
                    results.append(Block.toolResult(id: use.id, content: output, isError: isError))
                }
                let reply = Message(role: .user, content: results)
                conversation.append(assistant)
                conversation.append(reply)
                await onEvent(.message(assistant))
                await onEvent(.message(reply))

            case "pause_turn":
                conversation.append(assistant)
                await onEvent(.message(assistant))

            default:
                if !assistant.content.isEmpty {
                    conversation.append(assistant)
                    await onEvent(.message(assistant))
                }
                return AgentStopReason(apiValue: response.stopReason)
            }
        }
        return .turnLimit
    }

    func execute(_ use: ToolUse) async -> (String, Bool) {
        guard let tool = tools.first(where: { $0.name == use.name }) else {
            return ("Neznámý nástroj: \(use.name)", true)
        }
        do {
            let output = try await tool.run(use.input)
            return (output.isEmpty ? "(prázdný výsledek)" : output, false)
        } catch {
            return ("Chyba: \(error.localizedDescription)", true)
        }
    }
}

extension Array where Element == Message {
    /// Přidá text uživatele. Pokud konverzace končí výsledky nástrojů
    /// (např. po limitu kol), text se připojí za ně do stejné zprávy.
    public func appendingUserText(_ text: String) -> [Message] {
        var copy = self
        if let last = copy.last, last.role == .user {
            copy[copy.count - 1].content.append(Block.text(text))
        } else {
            copy.append(.user(text))
        }
        return copy
    }
}
