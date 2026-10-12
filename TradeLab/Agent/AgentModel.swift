import Foundation
import Observation
import ClaudeAgent

@MainActor
@Observable
final class AgentModel {
    private static let providerKey = "agentProvider"

    private(set) var messages: [Message] = []
    /// Poskytovatelé s uloženým klíčem.
    private(set) var configuredProviders: Set<Provider> = []

    var provider: Provider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            modelID = Self.storedModel(for: provider)
        }
    }

    var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: Self.modelKey(provider)) }
    }

    private(set) var isRunning = false
    private(set) var runningToolIDs: Set<String> = []
    private(set) var sessionUsage = Usage()
    var errorMessage: String? = nil

    private var task: Task<Void, Never>? = nil

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.providerKey).flatMap(Provider.init(rawValue:)) ?? .anthropic
        provider = stored
        modelID = Self.storedModel(for: stored)
        configuredProviders = Set(Provider.allCases.filter { !(KeychainStore.read(Self.keyAccount($0)) ?? "").isEmpty })
        messages = Self.loadConversation()
    }

    private static func keyAccount(_ provider: Provider) -> String { "\(provider.rawValue)-api-key" }
    private static func modelKey(_ provider: Provider) -> String { "agentModel.\(provider.rawValue)" }

    private static func storedModel(for provider: Provider) -> String {
        UserDefaults.standard.string(forKey: modelKey(provider)) ?? provider.defaultModel.id
    }

    var model: ModelOption { ModelOption.named(modelID, provider: provider) }
    var hasAPIKey: Bool { configuredProviders.contains(provider) }

    // MARK: - API klíče

    func saveAPIKey(_ key: String, for provider: Provider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStore.save(trimmed, for: Self.keyAccount(provider))
        configuredProviders.insert(provider)
    }

    func removeAPIKey(for provider: Provider) {
        KeychainStore.delete(Self.keyAccount(provider))
        configuredProviders.remove(provider)
    }

    /// Maskovaný klíč pro zobrazení v nastavení.
    func maskedAPIKey(for provider: Provider) -> String? {
        guard configuredProviders.contains(provider),
              let key = KeychainStore.read(Self.keyAccount(provider)), key.count > 12 else { return nil }
        return String(key.prefix(6)) + "…" + String(key.suffix(4))
    }

    // MARK: - Konverzace

    /// Výsledky nástrojů podle `tool_use_id`.
    var toolResults: [String: ToolResult] {
        var map: [String: ToolResult] = [:]
        for message in messages where message.role == .user {
            for result in message.toolResults { map[result.toolUseID] = result }
        }
        return map
    }

    /// Strategie navržená v tahu agenta, který končí zprávou `index`
    /// (poslední úspěšné `analyze_strategy` od posledního dotazu uživatele).
    func proposal(endingAt index: Int, results: [String: ToolResult]) -> StrategyProposal? {
        guard messages.indices.contains(index), messages[index].role == .assistant else { return nil }
        if index == messages.count - 1 {
            if isRunning { return nil }
        } else {
            let next = messages[index + 1]
            if next.role == .user, !next.toolResults.isEmpty { return nil }
        }
        var i = index
        while i >= 0 {
            let message = messages[i]
            if message.role == .user, message.toolResults.isEmpty { break }
            if message.role == .assistant {
                for use in message.toolUses.reversed() where use.name == "analyze_strategy" {
                    if let result = results[use.id], !result.isError,
                       let proposal = StrategyProposal(use: use, result: result) {
                        return proposal
                    }
                }
            }
            i -= 1
        }
        return nil
    }

    func send(_ text: String, app: AppModel) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        guard let key = KeychainStore.read(Self.keyAccount(provider)), !key.isEmpty else {
            errorMessage = "Chybí API klíč pro \(provider.displayName). Zadej ho v nastavení agenta."
            return
        }
        errorMessage = nil
        messages = messages.appendingUserText(prompt)
        save()

        let agent = Agent(
            transport: provider.transport(apiKey: key),
            model: modelID,
            system: Self.systemPrompt(rate: app.riskFreeRate),
            tools: AgentToolbox.tools(model: app),
            maxTokens: 8_000,
            maxTurns: 12
        )
        let conversation = messages
        isRunning = true
        task = Task {
            do {
                let stop = try await agent.run(conversation: conversation) { event in
                    await self.handle(event)
                }
                self.finish(stop: stop)
            } catch is CancellationError {
                self.finish(stop: nil)
            } catch {
                self.finish(stop: nil, error: error)
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    func clear() {
        stop()
        messages = []
        sessionUsage = Usage()
        errorMessage = nil
        save()
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .message(let message):
            messages.append(message)
            save()
        case .toolStarted(let use):
            runningToolIDs.insert(use.id)
        case .toolFinished(let use, _, _):
            runningToolIDs.remove(use.id)
        case .usage(let usage):
            sessionUsage = sessionUsage + usage
        }
    }

    private func finish(stop: AgentStopReason?, error: Error? = nil) {
        isRunning = false
        runningToolIDs = []
        task = nil
        if let error {
            if (error as? URLError)?.code == .cancelled { return }
            errorMessage = "\(provider.displayName): \(error.localizedDescription)"
            return
        }
        switch stop {
        case .maxTokens: errorMessage = "Odpověď byla useknuta (limit délky)."
        case .refusal: errorMessage = "Model odmítl odpovědět."
        case .turnLimit: errorMessage = "Agent dosáhl limitu kroků. Napiš „pokračuj“."
        case .other("malformed_function_call"): errorMessage = "Model poslal neplatné volání nástroje. Zkus dotaz zopakovat."
        case .other(let reason): errorMessage = "Zastaveno: \(reason)"
        default: break
        }
    }

    // MARK: - Uložení

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent-conversation.json")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    private static func loadConversation() -> [Message] {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Message].self, from: data) else { return [] }
        // Konverzace nesmí končit nezodpovězeným voláním nástroje.
        if let last = saved.last, last.role == .assistant, !last.toolUses.isEmpty {
            return Array(saved.dropLast())
        }
        return saved
    }

    // MARK: - Systémový prompt

    static func systemPrompt(rate: Double, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "cs_CZ")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "EEEE d. MMMM yyyy"
        let date = formatter.string(from: now)
        return """
        Jsi TradeLab – analytický asistent pro americké akcie a opce v iOS aplikaci uživatele.
        Dnes je \(date) (newyorský čas). Bezriziková sazba (13týdenní T-bill) je \(String(format: "%.2f", rate * 100)) %.

        Zásady:
        - Všechna čísla (ceny, IV, greeks, výnosy, metriky backtestu) ber výhradně z nástrojů. Nic si nevymýšlej a nepočítej z hlavy, co umí spočítat nástroj.
        - Než navrhneš opční strategii, ověř expirace a striky přes get_option_expirations / get_option_chain a návrh přepočítej přes analyze_strategy.
        - Data pocházejí z neoficiálního Yahoo Finance a mohou být zpožděná; mimo obchodní hodiny bývají opční kotace zastaralé. Pokud to ovlivňuje závěr, zmiň to.
        - Jde o výzkum a vzdělávání, ne o investiční doporučení. U návrhů vždy uveď hlavní rizika: max. ztrátu, likviditu (spread bid/ask, open interest) a co by musel trh udělat.
        - Když nástroj vrátí chybu, uprav vstup (jiný strike, expiraci, ticker) a zkus to znovu.
        - Pod odpovědí s analyze_strategy aplikace sama ukáže kartu „Otevřít v Opcích“, takže apply_to_app nastav na true jen tehdy, když uživatel výslovně chce strategii nahrát hned.
        - Odpovídej česky, stručně a věcně. Formátuj v markdownu: krátké odstavce, odrážky, případně malá tabulka. Čísla piš s jednotkami (USD, %, dny).
        """
    }
}

/// Strategie z výsledku `analyze_strategy` pro kartu pod odpovědí agenta.
struct StrategyProposal: Identifiable {
    let id: String
    let input: JSONValue
    let name: String
    let underlying: String
    let legs: [JSONValue]
    let netPremium: Double?
    let maxProfit: JSONValue?
    let maxLoss: JSONValue?
    let breakevens: [Double]

    init?(use: ToolUse, result: ToolResult) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(result.content.utf8)),
              let legs = json["legs"]?.arrayValue, !legs.isEmpty else { return nil }
        id = use.id
        input = use.input
        name = json["name"]?.stringValue ?? "Strategie"
        underlying = json["underlying"]?.stringValue ?? use.input["symbol"]?.stringValue?.uppercased() ?? ""
        self.legs = legs
        netPremium = json["net_premium_usd"]?.doubleValue
        maxProfit = json["max_profit_usd"]
        maxLoss = json["max_loss_usd"]
        breakevens = json["breakevens"]?.arrayValue?.compactMap(\.doubleValue) ?? []
    }
}
