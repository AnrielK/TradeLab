import Foundation

/// ChatGPT přes OpenAI Responses API (`POST /v1/responses`).
/// Chat Completions u GPT-6 Astra / 6.1 Sol nástroje nepodporuje, proto Responses.
/// Bezstavově (`store: false`): celá historie se posílá znovu a výstupní položky
/// (včetně šifrovaného reasoning) se vrací beze změny ze skrytého bloku zprávy.
public struct OpenAITransport: MessagesTransport {
    public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        let key = try JSONPoster.checkedKey(apiKey)
        let json = try await JSONPoster.post(Self.endpoint, headers: ["authorization": "Bearer \(key)"],
                                             body: Self.body(for: request))
        return try Self.parse(json)
    }

    // MARK: - Převod požadavku

    static func body(for request: MessagesRequest) -> JSONValue {
        var o: [String: JSONValue] = [
            "model": .string(request.model),
            "input": .array(input(for: request.messages)),
            // Reasoning tokeny se počítají do limitu výstupu.
            "max_output_tokens": .number(Double(max(request.maxTokens, 16_000))),
            "store": false,
            "include": ["reasoning.encrypted_content"],
        ]
        if let system = request.system, !system.isEmpty {
            o["instructions"] = .string(system)
        }
        if !request.tools.isEmpty {
            o["tools"] = .array(request.tools.map { tool in
                [
                    "type": "function",
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.inputSchema,
                ]
            })
            o["tool_choice"] = "auto"
        }
        return .object(o)
    }

    static func input(for messages: [Message]) -> [JSONValue] {
        var items: [JSONValue] = []
        for message in messages {
            switch message.role {
            case .user:
                var texts: [JSONValue] = []
                for block in message.content {
                    switch block["type"]?.stringValue {
                    case "tool_result":
                        guard let result = ToolResult(block: block) else { continue }
                        items.append([
                            "type": "function_call_output",
                            "call_id": .string(result.toolUseID),
                            "output": .string(result.isError ? "CHYBA: \(result.content)" : result.content),
                        ])
                    case "text":
                        if let text = block["text"]?.stringValue {
                            texts.append(["type": "input_text", "text": .string(text)])
                        }
                    default:
                        break
                    }
                }
                if !texts.isEmpty {
                    items.append(["role": "user", "content": .array(texts)])
                }

            case .assistant:
                if let raw = ProviderBlock.payload(in: message, for: .openai)?.arrayValue {
                    // Vlastní výstup – vrátit beze změny (reasoning jen se šifrovaným obsahem).
                    items.append(contentsOf: raw.filter { item in
                        item["type"]?.stringValue != "reasoning" || item["encrypted_content"]?.stringValue != nil
                    })
                    continue
                }
                // Zpráva od jiného poskytovatele.
                for block in message.content {
                    switch block["type"]?.stringValue {
                    case "text":
                        if let text = block["text"]?.stringValue, !text.isEmpty {
                            items.append(["role": "assistant", "content": .string(text)])
                        }
                    case "tool_use":
                        guard let use = ToolUse(block: block) else { continue }
                        items.append([
                            "type": "function_call",
                            "call_id": .string(use.id),
                            "name": .string(use.name),
                            "arguments": .string(use.input.jsonString),
                        ])
                    default:
                        break
                    }
                }
            }
        }
        return items
    }

    // MARK: - Převod odpovědi

    static func parse(_ json: JSONValue) throws -> MessagesResponse {
        guard let output = json["output"]?.arrayValue else { throw ClaudeAPIError.invalidResponse }
        var content: [JSONValue] = []
        var hasToolCall = false

        for item in output {
            switch item["type"]?.stringValue {
            case "message":
                for part in item["content"]?.arrayValue ?? [] {
                    let text = part["text"]?.stringValue ?? part["refusal"]?.stringValue
                    if let text, !text.isEmpty { content.append(Block.text(text)) }
                }
            case "function_call":
                guard let callID = item["call_id"]?.stringValue, let name = item["name"]?.stringValue else { continue }
                let arguments = item["arguments"]?.stringValue ?? "{}"
                let input = (try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8))) ?? [:]
                content.append(["type": "tool_use", "id": .string(callID), "name": .string(name), "input": input])
                hasToolCall = true
            default:
                break
            }
        }
        content.append(ProviderBlock.make(.openai, .array(output)))

        let stop: String
        if hasToolCall {
            stop = "tool_use"
        } else if json["status"]?.stringValue == "incomplete" {
            let reason = json["incomplete_details"]?["reason"]?.stringValue
            stop = reason == "content_filter" ? "refusal" : "max_tokens"
        } else {
            stop = "end_turn"
        }

        let usage = json["usage"]
        let cached = usage?["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0
        let input = usage?["input_tokens"]?.intValue ?? 0
        return MessagesResponse(id: json["id"]?.stringValue ?? "",
                                content: content,
                                stopReason: stop,
                                usage: Usage(inputTokens: max(input - cached, 0),
                                             outputTokens: usage?["output_tokens"]?.intValue ?? 0,
                                             cacheReadTokens: cached))
    }
}
