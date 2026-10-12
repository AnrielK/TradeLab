import XCTest
@testable import ClaudeAgent

/// Maketa API: vrací předem připravené odpovědi a ukládá požadavky.
final class MockTransport: MessagesTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [MessagesResponse]
    private(set) var requests: [MessagesRequest] = []

    init(_ responses: [MessagesResponse]) {
        self.responses = responses
    }

    func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !responses.isEmpty else { throw ClaudeAPIError.invalidResponse }
        return responses.removeFirst()
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AgentEvent] = []
    var events: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func add(_ e: AgentEvent) { lock.lock(); _events.append(e); lock.unlock() }

    var messages: [Message] {
        events.compactMap { if case .message(let m) = $0 { return m } else { return nil } }
    }
}

final class AgentTests: XCTestCase {
    private func toolUse(_ id: String, _ name: String, _ input: JSONValue) -> JSONValue {
        ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
    }

    private let quoteTool = AgentTool(
        name: "get_quote",
        description: "Cena",
        inputSchema: Schema.object(["symbol": Schema.string("Ticker")], required: ["symbol"])
    ) { input in
        guard let symbol = input["symbol"]?.stringValue else { throw ToolError("Chybí symbol") }
        return "{\"symbol\":\"\(symbol)\",\"price\":123.4}"
    }

    func testToolLoopSendsResultsWithMatchingIDs() async throws {
        let transport = MockTransport([
            MessagesResponse(content: [
                Block.text("Zjistím cenu."),
                toolUse("toolu_1", "get_quote", ["symbol": "NVDA"]),
                toolUse("toolu_2", "get_quote", ["symbol": "AAPL"]),
            ], stopReason: "tool_use", usage: Usage(inputTokens: 100, outputTokens: 20)),
            MessagesResponse(content: [Block.text("NVDA stojí 123,4 $.")], stopReason: "end_turn"),
        ])
        let agent = Agent(transport: transport, system: "Test", tools: [quoteTool])
        let log = EventLog()
        let stop = try await agent.run(conversation: [.user("Kolik stojí NVDA?")]) { log.add($0) }

        XCTAssertEqual(stop, .endTurn)
        XCTAssertEqual(transport.requests.count, 2)

        // Druhý požadavek: user, assistant(tool_use), user(tool_result × 2)
        let second = transport.requests[1].messages
        XCTAssertEqual(second.map(\.role), [.user, .assistant, .user])
        let results = second[2].toolResults
        XCTAssertEqual(results.map(\.toolUseID), ["toolu_1", "toolu_2"])
        XCTAssertTrue(results[0].content.contains("NVDA"))
        XCTAssertTrue(results[1].content.contains("AAPL"))
        XCTAssertFalse(results[0].isError)
        // Všechny bloky odpovědi jsou výsledky nástrojů (žádný text před nimi).
        XCTAssertEqual(second[2].content.count, 2)

        // Aplikace dostane assistant, výsledky a závěrečnou odpověď.
        XCTAssertEqual(log.messages.count, 3)
        XCTAssertEqual(log.messages.last?.text, "NVDA stojí 123,4 $.")
    }

    func testToolErrorAndUnknownToolAreReportedAsErrors() async throws {
        let transport = MockTransport([
            MessagesResponse(content: [
                toolUse("a", "get_quote", [:]),
                toolUse("b", "neexistuje", [:]),
            ], stopReason: "tool_use"),
            MessagesResponse(content: [Block.text("Omlouvám se.")], stopReason: "end_turn"),
        ])
        let agent = Agent(transport: transport, tools: [quoteTool])
        try await agent.run(conversation: [.user("?")]) { _ in }

        let results = transport.requests[1].messages[2].toolResults
        XCTAssertEqual(results.map(\.isError), [true, true])
        XCTAssertTrue(results[0].content.contains("Chybí symbol"))
        XCTAssertTrue(results[1].content.contains("neexistuje"))
    }

    func testTurnLimitStops() async throws {
        let loop = MessagesResponse(content: [toolUse("x", "get_quote", ["symbol": "SPY"])], stopReason: "tool_use")
        let transport = MockTransport([loop, loop, loop])
        let agent = Agent(transport: transport, tools: [quoteTool], maxTurns: 2)
        let log = EventLog()
        let stop = try await agent.run(conversation: [.user("?")]) { log.add($0) }
        XCTAssertEqual(stop, .turnLimit)
        XCTAssertEqual(transport.requests.count, 2)

        // Konverzace končí výsledky nástroje → další text se připojí za ně.
        let conversation = [Message.user("?")] + log.messages
        let next = conversation.appendingUserText("Pokračuj")
        XCTAssertEqual(next.count, conversation.count)
        XCTAssertEqual(next.last?.content.first?["type"]?.stringValue, "tool_result")
        XCTAssertEqual(next.last?.content.last?["text"]?.stringValue, "Pokračuj")
    }

    func testPauseTurnResends() async throws {
        let transport = MockTransport([
            MessagesResponse(content: [Block.text("…")], stopReason: "pause_turn"),
            MessagesResponse(content: [Block.text("Hotovo")], stopReason: "end_turn"),
        ])
        let agent = Agent(transport: transport)
        let stop = try await agent.run(conversation: [.user("?")]) { _ in }
        XCTAssertEqual(stop, .endTurn)
        XCTAssertEqual(transport.requests[1].messages.map(\.role), [.user, .assistant])
    }

    func testRequestBody() throws {
        let request = MessagesRequest(model: "claude-opus-5-5", maxTokens: 1000, system: "Sys",
                                      messages: [.user("Ahoj")], tools: [quoteTool.definition])
        let body = request.body
        XCTAssertEqual(body["model"]?.stringValue, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"]?.intValue, 1000)
        XCTAssertEqual(body["tool_choice"]?["type"]?.stringValue, "auto")
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["name"]?.stringValue, "get_quote")
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["input_schema"]?["type"]?.stringValue, "object")
        XCTAssertEqual(body["system"]?.arrayValue?.first?["cache_control"]?["type"]?.stringValue, "ephemeral")
        let message = body["messages"]?.arrayValue?.first
        XCTAssertEqual(message?["role"]?.stringValue, "user")
        XCTAssertEqual(message?["content"]?.arrayValue?.last?["cache_control"]?["type"]?.stringValue, "ephemeral")
        // Interní id zprávy se do API neposílá.
        XCTAssertNil(message?["id"])

        // Kódování do JSON a zpět
        let data = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, body)
    }

    func testResponseAndErrorParsing() throws {
        let json = """
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5",
         "content":[{"type":"text","text":"Ahoj"},{"type":"tool_use","id":"toolu_9","name":"get_quote","input":{"symbol":"SPY"}}],
         "stop_reason":"tool_use","usage":{"input_tokens":12,"output_tokens":5,"cache_read_input_tokens":3}}
        """.data(using: .utf8)!
        let response = try MessagesResponse(json: JSONDecoder().decode(JSONValue.self, from: json))
        XCTAssertEqual(response.stopReason, "tool_use")
        XCTAssertEqual(response.usage.inputTokens, 12)
        XCTAssertEqual(response.usage.totalInput, 15)
        let message = Message(role: .assistant, content: response.content)
        XCTAssertEqual(message.text, "Ahoj")
        XCTAssertEqual(message.toolUses.first?.input["symbol"]?.stringValue, "SPY")

        let errorBody = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.data(using: .utf8)!
        let error = ClaudeAPIError.from(status: 401, body: errorBody)
        XCTAssertEqual(error, .http(status: 401, type: "authentication_error", message: "invalid x-api-key"))
        XCTAssertTrue(error.localizedDescription.contains("Neplatný API klíč"))
        XCTAssertFalse(error.isRetryable)
        XCTAssertTrue(ClaudeAPIError.http(status: 529, type: nil, message: nil).isRetryable)
    }

    func testJSONValueDecodesNumbersAndBools() throws {
        let data = #"{"a":true,"b":1.5,"c":[1,"x",null]}"#.data(using: .utf8)!
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(v["a"], .bool(true))
        XCTAssertEqual(v["b"]?.doubleValue, 1.5)
        XCTAssertEqual(v["c"]?.arrayValue, [.number(1), .string("x"), .null])
    }

    func testMissingKey() async {
        let transport = HTTPMessagesTransport(apiKey: "  ")
        do {
            _ = try await transport.send(MessagesRequest(model: "m", maxTokens: 1, system: nil, messages: [], tools: []))
            XCTFail("Mělo selhat")
        } catch {
            XCTAssertEqual(error as? ClaudeAPIError, .missingAPIKey)
        }
    }
}
