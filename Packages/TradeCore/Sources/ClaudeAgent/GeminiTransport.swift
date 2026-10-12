import Foundation

/// Google Gemini přes `models/{model}:generateContent` (v1beta).
/// Části odpovědi modelu (včetně `thoughtSignature`) se ukládají do skrytého bloku
/// a v dalším kole se posílají beze změny – Gemini 3 bez podpisů volání nástrojů odmítne.
public struct GeminiTransport: MessagesTransport {
    public static let base = "https://generativelanguage.googleapis.com/v1beta/models/"
    /// Podpis pro volání nástrojů, která nevznikla v Gemini (konverzace začatá jiným modelem).
    static let foreignSignature = "skip_thought_signature_validator"
    /// Prefix ID pro volání, která Gemini vrátí bez `id`.
    static let localIDPrefix = "gem_"

    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        let key = try JSONPoster.checkedKey(apiKey)
        let model = request.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? request.model
        guard let url = URL(string: Self.base + model + ":generateContent") else { throw ClaudeAPIError.invalidResponse }
        let json = try await JSONPoster.post(url, headers: ["x-goog-api-key": key], body: Self.body(for: request))
        return try Self.parse(json)
    }

    // MARK: - Převod požadavku

    static func body(for request: MessagesRequest) -> JSONValue {
        var o: [String: JSONValue] = [
            "contents": .array(contents(for: request.messages)),
            // Myšlení se počítá do limitu výstupu.
            "generationConfig": ["maxOutputTokens": .number(Double(max(request.maxTokens, 16_000)))],
        ]
        if let system = request.system, !system.isEmpty {
            o["systemInstruction"] = ["parts": [["text": .string(system)]]]
        }
        if !request.tools.isEmpty {
            let declarations: [JSONValue] = request.tools.map { tool in
                var d: [String: JSONValue] = ["name": .string(tool.name), "description": .string(tool.description)]
                // Gemini nepřijímá objekt s prázdnými properties – nástroj bez parametrů je bez schématu.
                if let properties = tool.inputSchema["properties"]?.objectValue, !properties.isEmpty {
                    d["parameters"] = tool.inputSchema
                }
                return .object(d)
            }
            o["tools"] = [["functionDeclarations": .array(declarations)]]
        }
        return .object(o)
    }

    static func contents(for messages: [Message]) -> [JSONValue] {
        // Jméno nástroje podle ID volání (functionResponse ho vyžaduje).
        var toolNames: [String: String] = [:]
        for message in messages where message.role == .assistant {
            for use in message.toolUses { toolNames[use.id] = use.name }
        }

        var contents: [JSONValue] = []
        for message in messages {
            switch message.role {
            case .user:
                var responses: [JSONValue] = []
                var texts: [JSONValue] = []
                for block in message.content {
                    switch block["type"]?.stringValue {
                    case "tool_result":
                        guard let result = ToolResult(block: block) else { continue }
                        var response: [String: JSONValue] = [
                            "name": .string(toolNames[result.toolUseID] ?? "unknown"),
                            "response": responseObject(result),
                        ]
                        if !result.toolUseID.hasPrefix(localIDPrefix) {
                            response["id"] = .string(result.toolUseID)
                        }
                        responses.append(["functionResponse": .object(response)])
                    case "text":
                        if let text = block["text"]?.stringValue { texts.append(["text": .string(text)]) }
                    default:
                        break
                    }
                }
                let parts = responses + texts
                if !parts.isEmpty { contents.append(["role": "user", "parts": .array(parts)]) }

            case .assistant:
                if let raw = ProviderBlock.payload(in: message, for: .gemini)?.arrayValue, !raw.isEmpty {
                    contents.append(["role": "model", "parts": .array(raw)])
                    continue
                }
                var parts: [JSONValue] = []
                for block in message.content {
                    switch block["type"]?.stringValue {
                    case "text":
                        if let text = block["text"]?.stringValue, !text.isEmpty { parts.append(["text": .string(text)]) }
                    case "tool_use":
                        guard let use = ToolUse(block: block) else { continue }
                        var call: [String: JSONValue] = ["name": .string(use.name), "args": use.input]
                        if !use.id.hasPrefix(localIDPrefix) { call["id"] = .string(use.id) }
                        parts.append(["functionCall": .object(call), "thoughtSignature": .string(foreignSignature)])
                    default:
                        break
                    }
                }
                if !parts.isEmpty { contents.append(["role": "model", "parts": .array(parts)]) }
            }
        }
        return contents
    }

    /// `functionResponse.response` musí být objekt: JSON výstup nástroje přímo, jinak zabalený.
    static func responseObject(_ result: ToolResult) -> JSONValue {
        if result.isError { return ["error": .string(result.content)] }
        if let data = result.content.data(using: .utf8),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data), json.objectValue != nil {
            return json
        }
        return ["result": .string(result.content)]
    }

    // MARK: - Převod odpovědi

    static func parse(_ json: JSONValue) throws -> MessagesResponse {
        let usage = json["usageMetadata"]
        let cached = usage?["cachedContentTokenCount"]?.intValue ?? 0
        let prompt = usage?["promptTokenCount"]?.intValue ?? 0
        let output = (usage?["candidatesTokenCount"]?.intValue ?? 0) + (usage?["thoughtsTokenCount"]?.intValue ?? 0)
        let tokens = Usage(inputTokens: max(prompt - cached, 0), outputTokens: output, cacheReadTokens: cached)

        guard let candidate = json["candidates"]?.arrayValue?.first else {
            if let reason = json["promptFeedback"]?["blockReason"]?.stringValue {
                return MessagesResponse(content: [Block.text("Gemini požadavek zablokovalo (\(reason)).")],
                                        stopReason: "refusal", usage: tokens)
            }
            throw ClaudeAPIError.invalidResponse
        }

        let parts = candidate["content"]?["parts"]?.arrayValue ?? []
        var content: [JSONValue] = []
        var hasToolCall = false
        for part in parts {
            if part["thought"]?.boolValue == true { continue }
            if let text = part["text"]?.stringValue, !text.isEmpty {
                content.append(Block.text(text))
            } else if let call = part["functionCall"], let name = call["name"]?.stringValue {
                let id = call["id"]?.stringValue ?? localIDPrefix + UUID().uuidString.prefix(12).lowercased()
                content.append(["type": "tool_use", "id": .string(id), "name": .string(name), "input": call["args"] ?? [:]])
                hasToolCall = true
            }
        }
        if !parts.isEmpty {
            content.append(ProviderBlock.make(.gemini, .array(parts)))
        }

        let stop: String
        switch candidate["finishReason"]?.stringValue {
        case _ where hasToolCall: stop = "tool_use"
        case "MAX_TOKENS": stop = "max_tokens"
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII": stop = "refusal"
        case "MALFORMED_FUNCTION_CALL": stop = "malformed_function_call"
        default: stop = "end_turn"
        }
        return MessagesResponse(id: json["responseId"]?.stringValue ?? "", content: content, stopReason: stop, usage: tokens)
    }
}
