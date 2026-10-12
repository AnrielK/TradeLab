import XCTest
@testable import ClaudeAgent

final class ProviderTests: XCTestCase {
    private func decode(_ s: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    private let tool = ToolDefinition(name: "get_quote", description: "Cena",
                                      inputSchema: Schema.object(["symbol": Schema.string("Ticker")], required: ["symbol"]))
    private let noArgs = ToolDefinition(name: "get_watchlist", description: "Watchlist", inputSchema: Schema.object([:]))

    // MARK: - OpenAI

    func testOpenAIRoundTrip() throws {
        let response = try OpenAITransport.parse(decode("""
        {"id":"resp_1","status":"completed","output":[
          {"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"ENC"},
          {"type":"reasoning","id":"rs_2","summary":[]},
          {"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"Zjistím cenu."}]},
          {"type":"function_call","id":"fc_1","call_id":"call_A","name":"get_quote","arguments":"{\\"symbol\\":\\"NVDA\\"}"}
        ],"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":40},"output_tokens":20}}
        """))
        XCTAssertEqual(response.stopReason, "tool_use")
        XCTAssertEqual(response.usage.inputTokens, 60)
        XCTAssertEqual(response.usage.cacheReadTokens, 40)
        let assistant = Message(role: .assistant, content: response.content)
        XCTAssertEqual(assistant.text, "Zjistím cenu.")
        XCTAssertEqual(assistant.toolUses.first?.id, "call_A")
        XCTAssertEqual(assistant.toolUses.first?.input["symbol"]?.stringValue, "NVDA")

        let reply = Message(role: .user, content: [Block.toolResult(id: "call_A", content: "{\"price\":1}", isError: false)])
        let request = MessagesRequest(model: "gpt-6.1-sol", maxTokens: 8000, system: "Sys",
                                      messages: [.user("Cena NVDA?"), assistant, reply], tools: [tool])
        let body = OpenAITransport.body(for: request)
        XCTAssertEqual(body["instructions"]?.stringValue, "Sys")
        XCTAssertEqual(body["store"], .bool(false))
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["type"]?.stringValue, "function")
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["parameters"]?["type"]?.stringValue, "object")

        let items = body["input"]?.arrayValue ?? []
        let types = items.map { $0["type"]?.stringValue ?? "role:" + ($0["role"]?.stringValue ?? "") }
        // user, reasoning (jen se šifrovaným obsahem), message, function_call, function_call_output
        XCTAssertEqual(types, ["role:user", "reasoning", "message", "function_call", "function_call_output"])
        XCTAssertEqual(items[1]["encrypted_content"]?.stringValue, "ENC")
        XCTAssertEqual(items[4]["call_id"]?.stringValue, "call_A")
        XCTAssertEqual(items[4]["output"]?.stringValue, "{\"price\":1}")
    }

    func testOpenAIFinalAndIncomplete() throws {
        let done = try OpenAITransport.parse(decode("""
        {"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Hotovo"}]}]}
        """))
        XCTAssertEqual(done.stopReason, "end_turn")
        let cut = try OpenAITransport.parse(decode("""
        {"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}
        """))
        XCTAssertEqual(cut.stopReason, "max_tokens")
    }

    func testOpenAIConvertsForeignHistory() {
        let assistant = Message(role: .assistant, content: [
            Block.text("Podívám se."),
            ["type": "tool_use", "id": "toolu_1", "name": "get_quote", "input": ["symbol": "SPY"]],
        ])
        let items = OpenAITransport.input(for: [.user("?"), assistant])
        XCTAssertEqual(items[1]["role"]?.stringValue, "assistant")
        XCTAssertEqual(items[2]["type"]?.stringValue, "function_call")
        XCTAssertEqual(items[2]["call_id"]?.stringValue, "toolu_1")
        XCTAssertEqual(items[2]["arguments"]?.stringValue, "{\"symbol\":\"SPY\"}")
    }

    // MARK: - Gemini

    func testGeminiRoundTripKeepsSignature() throws {
        let response = try GeminiTransport.parse(decode("""
        {"candidates":[{"content":{"role":"model","parts":[
          {"text":"Zjistím cenu."},
          {"functionCall":{"name":"get_quote","args":{"symbol":"AAPL"}},"thoughtSignature":"SIG"}
        ]},"finishReason":"STOP"}],
         "usageMetadata":{"promptTokenCount":50,"candidatesTokenCount":10,"thoughtsTokenCount":5}}
        """))
        XCTAssertEqual(response.stopReason, "tool_use")
        XCTAssertEqual(response.usage.outputTokens, 15)
        let assistant = Message(role: .assistant, content: response.content)
        let use = try XCTUnwrap(assistant.toolUses.first)
        XCTAssertTrue(use.id.hasPrefix("gem_"))
        XCTAssertEqual(use.input["symbol"]?.stringValue, "AAPL")

        let reply = Message(role: .user, content: [Block.toolResult(id: use.id, content: "{\"price\":200}", isError: false)])
        let request = MessagesRequest(model: "gemini-3.8-flash", maxTokens: 8000, system: "Sys",
                                      messages: [.user("Cena?"), assistant, reply], tools: [tool, noArgs])
        let body = GeminiTransport.body(for: request)
        XCTAssertEqual(body["systemInstruction"]?["parts"]?.arrayValue?.first?["text"]?.stringValue, "Sys")
        let declarations = body["tools"]?.arrayValue?.first?["functionDeclarations"]?.arrayValue ?? []
        XCTAssertEqual(declarations.count, 2)
        XCTAssertNotNil(declarations[0]["parameters"])
        XCTAssertNil(declarations[1]["parameters"])

        let contents = body["contents"]?.arrayValue ?? []
        XCTAssertEqual(contents.map { $0["role"]?.stringValue }, ["user", "model", "user"])
        // Části modelu se vrací beze změny včetně podpisu.
        XCTAssertEqual(contents[1]["parts"]?.arrayValue?[1]["thoughtSignature"]?.stringValue, "SIG")
        let fr = contents[2]["parts"]?.arrayValue?.first?["functionResponse"]
        XCTAssertEqual(fr?["name"]?.stringValue, "get_quote")
        XCTAssertNil(fr?["id"])
        XCTAssertEqual(fr?["response"]?["price"]?.doubleValue, 200)
    }

    func testGeminiForeignHistoryAndErrors() throws {
        let assistant = Message(role: .assistant, content: [
            ["type": "tool_use", "id": "toolu_9", "name": "get_quote", "input": ["symbol": "SPY"]],
        ])
        let reply = Message(role: .user, content: [Block.toolResult(id: "toolu_9", content: "nenalezeno", isError: true)])
        let contents = GeminiTransport.contents(for: [.user("?"), assistant, reply])
        let call = contents[1]["parts"]?.arrayValue?.first
        XCTAssertEqual(call?["thoughtSignature"]?.stringValue, GeminiTransport.foreignSignature)
        XCTAssertEqual(call?["functionCall"]?["id"]?.stringValue, "toolu_9")
        let fr = contents[2]["parts"]?.arrayValue?.first?["functionResponse"]
        XCTAssertEqual(fr?["id"]?.stringValue, "toolu_9")
        XCTAssertEqual(fr?["response"]?["error"]?.stringValue, "nenalezeno")

        let cut = try GeminiTransport.parse(decode("""
        {"candidates":[{"content":{"parts":[{"text":"…"}]},"finishReason":"MAX_TOKENS"}]}
        """))
        XCTAssertEqual(cut.stopReason, "max_tokens")
        let blocked = try GeminiTransport.parse(decode(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#))
        XCTAssertEqual(blocked.stopReason, "refusal")

        let error = ClaudeAPIError.from(status: 400, body: Data(#"{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}"#.utf8))
        XCTAssertEqual(error, .http(status: 400, type: "INVALID_ARGUMENT", message: "API key not valid"))
    }

    // MARK: - Claude s cizí historií

    func testAnthropicBodyDropsProviderBlocks() {
        let assistant = Message(role: .assistant, content: [
            Block.text("Ahoj"),
            ProviderBlock.make(.gemini, [["text": "Ahoj", "thoughtSignature": "SIG"]]),
        ])
        let hiddenOnly = Message(role: .assistant, content: [ProviderBlock.make(.openai, [])])
        let request = MessagesRequest(model: "claude-opus-5-5", maxTokens: 100, system: nil,
                                      messages: [.user("?"), assistant, hiddenOnly, .user("Dál")], tools: [])
        let messages = request.body["messages"]?.arrayValue ?? []
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[1]["content"]?.arrayValue?.count, 1)
        XCTAssertEqual(messages[1]["content"]?.arrayValue?.first?["type"]?.stringValue, "text")
    }

    func testModelCatalog() {
        for provider in Provider.allCases {
            XCTAssertFalse(provider.models.isEmpty)
        }
        XCTAssertEqual(Provider.anthropic.defaultModel.id, "claude-opus-5-5")
        XCTAssertEqual(ModelOption.named("muj-model", provider: .openai).provider, .openai)
    }
}
