import Foundation
import Observation
import ClaudeAgent

@MainActor
@Observable
final class AgentModel {
    private static let keyAccount = "anthropic-api-key"
    private static let modelKey = "agentModel"

    private(set) var messages: [Message] = []
    private(set) var hasAPIKey: Bool
    var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: Self.modelKey) }
    }

    private(set) var isRunning = false
    private(set) var runningToolIDs: Set<String> = []
    private(set) var sessionUsage = Usage()
    var errorMessage: String? = nil

    private var task: Task<Void, Never>? = nil

    init() {
        hasAPIKey = !(KeychainStore.read(Self.keyAccount) ?? "").isEmpty
        modelID = UserDefaults.standard.string(forKey: Self.modelKey) ?? ClaudeModel.opus.id
        messages = Self.loadConversation()
    }

    var model: ClaudeModel { ClaudeModel.named(modelID) }

    // MARK: - API klíč

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(Self.keyAccount)
        } else {
            KeychainStore.save(trimmed, for: Self.keyAccount)
        }
        hasAPIKey = !trimmed.isEmpty
    }

    func removeAPIKey() {
        KeychainStore.delete(Self.keyAccount)
        hasAPIKey = false
    }

    /// Maskovaný klíč pro zobrazení v nastavení.
    var maskedAPIKey: String? {
        guard let key = KeychainStore.read(Self.keyAccount), key.count > 12 else { return nil }
        return String(key.prefix(7)) + "…" + String(key.suffix(4))
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

    func send(_ text: String, app: AppModel) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        guard let key = KeychainStore.read(Self.keyAccount), !key.isEmpty else {
            errorMessage = ClaudeAPIError.missingAPIKey.localizedDescription
            return
        }
        errorMessage = nil
        messages = messages.appendingUserText(prompt)
        save()

        let agent = Agent(
            transport: HTTPMessagesTransport(apiKey: key),
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
            errorMessage = error.localizedDescription
            return
        }
        switch stop {
        case .maxTokens: errorMessage = "Odpověď byla useknuta (limit délky)."
        case .refusal: errorMessage = "Model odmítl odpovědět."
        case .turnLimit: errorMessage = "Agent dosáhl limitu kroků. Napiš „pokračuj“."
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
        - apply_to_app nastav na true jen tehdy, když uživatel výslovně chce strategii nahrát do aplikace.
        - Odpovídej česky, stručně a věcně. Formátuj v markdownu: krátké odstavce, odrážky, případně malá tabulka. Čísla piš s jednotkami (USD, %, dny).
        """
    }
}
