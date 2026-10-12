import Foundation

/// Jeden člen týmu agentů.
public struct TeamRole: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var icon: String
    /// Popis role a co má odevzdat (přidá se k systémovému promptu).
    public var instructions: String
    /// Povolené nástroje (prázdné = žádné, jen syntéza).
    public var tools: [String]
    public var maxTurns: Int

    public init(id: String, name: String, icon: String, instructions: String, tools: [String], maxTurns: Int = 10) {
        self.id = id
        self.name = name
        self.icon = icon
        self.instructions = instructions
        self.tools = tools
        self.maxTurns = maxTurns
    }
}

/// Fáze týmu – role ve fázi pracují souběžně a vidí závěry všech předchozích fází.
public struct TeamStage: Hashable, Sendable {
    public var roles: [TeamRole]

    public init(_ roles: [TeamRole]) {
        self.roles = roles
    }
}

public struct TeamPreset: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var icon: String
    public var summary: String
    /// Potřebuje ticker (jinak pracuje s pozicí nebo watchlistem).
    public var needsSymbol: Bool
    public var notePlaceholder: String
    public var stages: [TeamStage]

    public init(id: String, name: String, icon: String, summary: String, needsSymbol: Bool,
                notePlaceholder: String, stages: [TeamStage]) {
        self.id = id
        self.name = name
        self.icon = icon
        self.summary = summary
        self.needsSymbol = needsSymbol
        self.notePlaceholder = notePlaceholder
        self.stages = stages
    }

    public var roles: [TeamRole] { stages.flatMap(\.roles) }
}

public enum TeamEvent: Sendable {
    case roleStarted(roleID: String)
    case agent(roleID: String, AgentEvent)
    case roleFinished(roleID: String, report: String)
    case roleFailed(roleID: String, error: String)
}

/// Spouští tým: fáze postupně, role ve fázi souběžně (s limitem kvůli rate limitům).
public struct TeamRunner: Sendable {
    public var transport: MessagesTransport
    public var model: String
    public var baseSystem: String
    public var tools: [AgentTool]
    public var maxTokens: Int
    public var maxConcurrent: Int

    public init(transport: MessagesTransport, model: String, baseSystem: String, tools: [AgentTool],
                maxTokens: Int = 6_000, maxConcurrent: Int = 3) {
        self.transport = transport
        self.model = model
        self.baseSystem = baseSystem
        self.tools = tools
        self.maxTokens = maxTokens
        self.maxConcurrent = max(maxConcurrent, 1)
    }

    /// Vrátí reporty podle ID role (neúspěšné role chybí).
    @discardableResult
    public func run(_ preset: TeamPreset, task: String,
                    onEvent: @escaping @Sendable (TeamEvent) async -> Void) async throws -> [String: String] {
        var reports: [String: String] = [:]
        var transcript: [(role: TeamRole, report: String)] = []

        for stage in preset.stages {
            try Task.checkCancellation()
            let prompt = Self.prompt(task: task, previous: transcript)
            var stageReports: [String: String] = [:]

            for chunk in stride(from: 0, to: stage.roles.count, by: maxConcurrent).map({
                Array(stage.roles[$0..<min($0 + maxConcurrent, stage.roles.count)])
            }) {
                try await withThrowingTaskGroup(of: (String, String?).self) { group in
                    for role in chunk {
                        let agent = makeAgent(for: role)
                        group.addTask {
                            await onEvent(.roleStarted(roleID: role.id))
                            do {
                                let collector = MessageCollector()
                                try await agent.run(conversation: [.user(prompt)]) { event in
                                    if case .message(let m) = event { await collector.add(m) }
                                    await onEvent(.agent(roleID: role.id, event))
                                }
                                let final = await collector.messages
                                let report = Self.report(from: final)
                                await onEvent(.roleFinished(roleID: role.id, report: report))
                                return (role.id, report)
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                await onEvent(.roleFailed(roleID: role.id, error: error.localizedDescription))
                                return (role.id, nil)
                            }
                        }
                    }
                    for try await (id, report) in group {
                        if let report { stageReports[id] = report }
                    }
                }
            }

            for role in stage.roles {
                if let report = stageReports[role.id] {
                    reports[role.id] = report
                    transcript.append((role, report))
                }
            }
        }
        return reports
    }

    func makeAgent(for role: TeamRole) -> Agent {
        let allowed = tools.filter { role.tools.contains($0.name) }
        let system = """
        \(baseSystem)

        Pracuješ jako člen týmu analytiků. Tvoje role: \(role.name).
        \(role.instructions)
        Svůj výstup piš jako stručný report pro ostatní členy týmu (nejvýš ~250 slov), s konkrétními čísly z nástrojů. \
        Neopakuj zadání ani úvodní fráze.
        """
        return Agent(transport: transport, model: model, system: system, tools: allowed,
                     maxTokens: maxTokens, maxTurns: role.maxTurns)
    }

    static func prompt(task: String, previous: [(role: TeamRole, report: String)]) -> String {
        guard !previous.isEmpty else { return task }
        let reports = previous.map { "### \($0.role.name)\n\($0.report)" }.joined(separator: "\n\n")
        return "\(task)\n\nZávěry ostatních členů týmu:\n\n\(reports)"
    }

    /// Text všech asistentových zpráv (typicky jen ta poslední má text).
    static func report(from messages: [Message]) -> String {
        let texts = messages.filter { $0.role == .assistant }.map(\.text).filter { !$0.isEmpty }
        return texts.last ?? "(bez textového výstupu)"
    }
}

actor MessageCollector {
    private(set) var messages: [Message] = []
    func add(_ message: Message) { messages.append(message) }
}
