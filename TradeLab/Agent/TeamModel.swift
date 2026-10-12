import Foundation
import Observation
import ClaudeAgent

/// Uložený běh týmu.
struct TeamRun: Codable, Identifiable, Hashable {
    enum Status: String, Codable { case waiting, running, done, failed }

    struct ToolCall: Codable, Hashable, Identifiable {
        var id: String
        var name: String
        var detail: String
        var running: Bool
        var isError: Bool
    }

    struct Role: Codable, Hashable, Identifiable {
        var id: String
        var name: String
        var icon: String
        var stage: Int
        var isFinal: Bool
        var status: Status = .waiting
        var report: String = ""
        var error: String? = nil
        var toolCalls: [ToolCall] = []
    }

    struct Proposal: Codable, Hashable, Identifiable {
        var id: String
        var input: JSONValue
        var output: String
    }

    var id = UUID()
    var presetID: String
    var presetName: String
    var presetIcon: String
    var subject: String
    var note: String
    var date: Date
    var modelName: String
    var roles: [Role]
    var proposals: [Proposal] = []
    var finished = false
    var error: String? = nil

    var finalRole: Role? { roles.last { $0.isFinal } }
}

@MainActor
@Observable
final class TeamModel {
    private(set) var runs: [TeamRun] = []
    private(set) var isRunning = false
    var selectedRunID: UUID? = nil
    /// Méně souběžných požadavků – pro bezplatné klíče s nízkým limitem.
    var sequential: Bool {
        didSet { UserDefaults.standard.set(sequential, forKey: "team.sequential") }
    }

    private var task: Task<Void, Never>? = nil
    private static let maxStoredRuns = 15

    init() {
        sequential = UserDefaults.standard.bool(forKey: "team.sequential")
        runs = Self.load()
    }

    var selectedRun: TeamRun? {
        guard let selectedRunID else { return nil }
        return runs.first { $0.id == selectedRunID }
    }

    // MARK: - Běh

    func start(_ preset: TeamPreset, symbol: String, note: String, agent: AgentModel, app: AppModel) {
        guard !isRunning else { return }
        guard let connection = agent.connection() else {
            agent.errorMessage = "Chybí API klíč pro \(agent.provider.displayName)."
            return
        }
        let ticker = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        if preset.needsSymbol, ticker.isEmpty { return }

        let finalStage = preset.stages.count - 1
        var roles: [TeamRun.Role] = []
        for (index, stage) in preset.stages.enumerated() {
            for role in stage.roles {
                roles.append(TeamRun.Role(id: role.id, name: role.name, icon: role.icon, stage: index,
                                          isFinal: index == finalStage))
            }
        }
        let subject: String
        switch preset.id {
        case "position-review": subject = app.strategy.legs.isEmpty ? "Bez pozice" : "\(app.strategy.name) · \(app.strategy.underlying)"
        case "watchlist": subject = "Watchlist"
        default: subject = ticker
        }
        let run = TeamRun(presetID: preset.id, presetName: preset.name, presetIcon: preset.icon, subject: subject,
                          note: note.trimmingCharacters(in: .whitespacesAndNewlines), date: Date(),
                          modelName: "\(agent.provider.displayName) · \(connection.model.name)", roles: roles)
        runs.insert(run, at: 0)
        if runs.count > Self.maxStoredRuns { runs.removeLast(runs.count - Self.maxStoredRuns) }
        selectedRunID = run.id
        isRunning = true

        let runner = TeamRunner(transport: connection.transport, model: connection.model.id,
                                baseSystem: AgentModel.systemPrompt(rate: app.riskFreeRate),
                                tools: AgentToolbox.tools(model: app),
                                maxConcurrent: sequential ? 1 : 3)
        let taskText = Self.task(for: preset, symbol: ticker, note: run.note)
        let runID = run.id

        task = Task {
            do {
                try await runner.run(preset, task: taskText) { event in
                    await self.handle(event, runID: runID, agent: agent)
                }
                self.finish(runID: runID, error: nil)
            } catch is CancellationError {
                self.finish(runID: runID, error: "Zastaveno.")
            } catch {
                self.finish(runID: runID, error: error.localizedDescription)
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    func delete(_ id: UUID) {
        runs.removeAll { $0.id == id }
        if selectedRunID == id { selectedRunID = nil }
        save()
    }

    static func task(for preset: TeamPreset, symbol: String, note: String) -> String {
        var text: String
        switch preset.id {
        case "position-review":
            text = "Úkol týmu: zkontrolovat opční pozici, kterou má uživatel sestavenou v aplikaci (načti ji přes get_current_position)."
        case "watchlist":
            text = "Úkol týmu: projít watchlist uživatele (get_watchlist) a připravit přehled trhu."
        case "options-desk":
            text = "Úkol týmu: navrhnout a otestovat opční strategii na \(symbol)."
        default:
            text = "Úkol týmu: posoudit akcii \(symbol) a vynést investiční verdikt."
        }
        if !note.isEmpty { text += "\nPoznámka uživatele: \(note)" }
        return text
    }

    // MARK: - Události

    private func update(_ runID: UUID, _ change: (inout TeamRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        change(&runs[index])
    }

    private func updateRole(_ runID: UUID, _ roleID: String, _ change: (inout TeamRun.Role) -> Void) {
        update(runID) { run in
            guard let index = run.roles.firstIndex(where: { $0.id == roleID }) else { return }
            change(&run.roles[index])
        }
    }

    private func handle(_ event: TeamEvent, runID: UUID, agent: AgentModel) {
        switch event {
        case .roleStarted(let roleID):
            updateRole(runID, roleID) { $0.status = .running }
        case .roleFinished(let roleID, let report):
            updateRole(runID, roleID) { role in
                role.status = .done
                role.report = report
            }
            save()
        case .roleFailed(let roleID, let error):
            updateRole(runID, roleID) { role in
                role.status = .failed
                role.error = error
            }
        case .agent(let roleID, let event):
            switch event {
            case .usage(let usage):
                agent.addUsage(usage)
            case .toolStarted(let use):
                updateRole(runID, roleID) { role in
                    role.toolCalls.append(.init(id: use.id, name: use.name, detail: ToolChip.detail(for: use.input),
                                                running: true, isError: false))
                }
            case .toolFinished(let use, let output, let isError):
                updateRole(runID, roleID) { role in
                    if let index = role.toolCalls.firstIndex(where: { $0.id == use.id }) {
                        role.toolCalls[index].running = false
                        role.toolCalls[index].isError = isError
                    }
                }
                if use.name == "analyze_strategy", !isError {
                    update(runID) { run in
                        run.proposals.append(.init(id: use.id, input: use.input, output: output))
                    }
                }
            case .message:
                break
            }
        }
    }

    private func finish(runID: UUID, error: String?) {
        update(runID) { run in
            run.finished = true
            run.error = error
            for index in run.roles.indices where run.roles[index].status == .running || run.roles[index].status == .waiting {
                run.roles[index].status = error == nil ? run.roles[index].status : .failed
                for t in run.roles[index].toolCalls.indices { run.roles[index].toolCalls[t].running = false }
            }
            if error == nil, let final = run.finalRole, final.status != .done {
                run.error = final.error ?? "Závěrečná role nedoběhla."
            }
        }
        isRunning = false
        task = nil
        save()
    }

    // MARK: - Uložení

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("team-runs.json")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(runs) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    private static func load() -> [TeamRun] {
        guard let data = try? Data(contentsOf: fileURL),
              var runs = try? JSONDecoder().decode([TeamRun].self, from: data) else { return [] }
        // Běh přerušený ukončením aplikace.
        for i in runs.indices where !runs[i].finished {
            runs[i].finished = true
            runs[i].error = runs[i].error ?? "Přerušeno."
        }
        return runs
    }
}
