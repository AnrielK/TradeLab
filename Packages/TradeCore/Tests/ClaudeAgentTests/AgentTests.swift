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

/// Maketa, která odpovídá podle role v systémovém promptu.
final class RoleTransport: MessagesTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [MessagesRequest] = []

    func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        lock.lock(); requests.append(request); lock.unlock()
        let system = request.system ?? ""
        if system.contains("Tvoje role: Selhávající") {
            throw ClaudeAPIError.http(status: 400, type: "invalid_request_error", message: "test")
        }
        if system.contains("Tvoje role: Analytik"), request.messages.count == 1 {
            return MessagesResponse(content: [
                ["type": "tool_use", "id": "t1", "name": "get_quote", "input": ["symbol": "SPY"]],
            ], stopReason: "tool_use")
        }
        let role = system.components(separatedBy: "Tvoje role: ").last?.components(separatedBy: ".").first ?? "?"
        return MessagesResponse(content: [Block.text("Report \(role)")], stopReason: "end_turn")
    }
}

final class TeamTests: XCTestCase {
    func testStagesPassReportsForward() async throws {
        let transport = RoleTransport()
        let quote = AgentTool(name: "get_quote", description: "", inputSchema: Schema.object([:])) { _ in "{\"price\":1}" }
        let other = AgentTool(name: "run_backtest", description: "", inputSchema: Schema.object([:])) { _ in "{}" }
        let preset = TeamPreset(id: "t", name: "Test", icon: "x", summary: "", needsSymbol: true, notePlaceholder: "", stages: [
            TeamStage([
                TeamRole(id: "a", name: "Analytik", icon: "", instructions: "", tools: ["get_quote"]),
                TeamRole(id: "b", name: "Kvant", icon: "", instructions: "", tools: []),
                TeamRole(id: "f", name: "Selhávající", icon: "", instructions: "", tools: []),
            ]),
            TeamStage([TeamRole(id: "c", name: "Předseda", icon: "", instructions: "", tools: [])]),
        ])
        let runner = TeamRunner(transport: transport, model: "m", baseSystem: "Base", tools: [quote, other], maxConcurrent: 2)
        let log = TeamLog()
        let reports = try await runner.run(preset, task: "Posuď SPY") { log.add($0) }

        XCTAssertEqual(reports["a"], "Report Analytik")
        XCTAssertEqual(reports["b"], "Report Kvant")
        XCTAssertNil(reports["f"])
        XCTAssertEqual(reports["c"], "Report Předseda")
        XCTAssertEqual(log.failed, ["f"])

        // Analytik dostal jen svůj nástroj, kvant žádný.
        let analyst = transport.requests.first { $0.system?.contains("Tvoje role: Analytik") == true }
        XCTAssertEqual(analyst?.tools.map(\.name), ["get_quote"])
        let quant = transport.requests.first { $0.system?.contains("Tvoje role: Kvant") == true }
        XCTAssertEqual(quant?.tools.count, 0)

        // Předseda vidí reporty první fáze.
        let chair = try XCTUnwrap(transport.requests.first { $0.system?.contains("Tvoje role: Předseda") == true })
        let prompt = chair.messages[0].text
        XCTAssertTrue(prompt.hasPrefix("Posuď SPY"))
        XCTAssertTrue(prompt.contains("### Analytik\nReport Analytik"))
        XCTAssertTrue(prompt.contains("### Kvant\nReport Kvant"))
        XCTAssertFalse(prompt.contains("Selhávající"))
    }
}

final class TeamLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _failed: [String] = []
    var failed: [String] { lock.lock(); defer { lock.unlock() }; return _failed }
    func add(_ e: TeamEvent) {
        if case .roleFailed(let id, _) = e { lock.lock(); _failed.append(id); lock.unlock() }
    }
}
