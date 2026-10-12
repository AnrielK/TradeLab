import SwiftUI
import ClaudeAgent

/// Týmy agentů: výběr presetu, spuštění, průběh a historie.
struct TeamView: View {
    @Environment(AppModel.self) private var app
    @Environment(AgentModel.self) private var agent
    @Environment(TeamModel.self) private var team
    @Binding var showSettings: Bool

    @AppStorage("team.preset") private var presetID = TeamPresets.committee.id
    @State private var symbol = ""
    @State private var note = ""

    private var preset: TeamPreset { TeamPresets.preset(presetID) ?? TeamPresets.committee }

    var body: some View {
        Group {
            if let run = team.selectedRun {
                TeamRunView(run: run)
            } else {
                launcher
            }
        }
        .toolbar {
            if team.selectedRun != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button { team.selectedRunID = nil } label: { Image(systemName: "chevron.left") }
                }
            }
        }
        .onAppear {
            if symbol.isEmpty { symbol = app.optionsSymbol }
        }
    }

    // MARK: - Spuštění

    private var launcher: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !agent.hasAPIKey {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Chybí API klíč pro \(agent.provider.displayName)", systemImage: "key.fill")
                            .font(.headline)
                        Button("Zadat klíč") { showSettings = true }
                            .buttonStyle(.glassProminent)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                }

                Text("Tým agentů").font(.title3.weight(.semibold))
                ForEach(TeamPresets.all) { p in
                    PresetCard(preset: p, selected: p.id == presetID)
                        .onTapGesture { withAnimation(.snappy) { presetID = p.id } }
                }

                inputs

                if !team.runs.isEmpty {
                    history
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var canStart: Bool {
        guard agent.hasAPIKey, !team.isRunning else { return false }
        if preset.needsSymbol { return !symbol.trimmingCharacters(in: .whitespaces).isEmpty }
        if preset.id == "position-review" { return !app.strategy.legs.isEmpty }
        return true
    }

    private var inputs: some View {
        @Bindable var team = team
        return VStack(alignment: .leading, spacing: 10) {
            if preset.needsSymbol {
                TextField("Ticker", text: $symbol)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.title3.weight(.semibold).monospaced())
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            } else if preset.id == "position-review" {
                Label(app.strategy.legs.isEmpty ? "Na záložce Opce nemáš sestavenou žádnou strategii."
                                                : "Pozice: \(app.strategy.name) · \(app.strategy.underlying)",
                      systemImage: app.strategy.legs.isEmpty ? "exclamationmark.triangle" : "square.stack.3d.up")
                    .font(.subheadline)
                    .foregroundStyle(app.strategy.legs.isEmpty ? .orange : .primary)
            }
            TextField(preset.notePlaceholder, text: $note, axis: .vertical)
                .lineLimit(1...4)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

            Toggle(isOn: $team.sequential) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Šetřit limity API")
                    Text("Role poběží postupně – pomalejší, ale vhodné pro bezplatné klíče.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Button {
                team.start(preset, symbol: symbol, note: note, agent: agent, app: app)
            } label: {
                Label("Spustit tým", systemImage: "play.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!canStart)

            Text("\(agent.provider.displayName) · \(agent.model.name) · \(preset.roles.count) rolí. Každá role je samostatný agent, takže běh stojí víc tokenů než jeden dotaz v chatu.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = agent.errorMessage, !agent.hasAPIKey {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Historie").font(.headline).padding(.top, 8)
            ForEach(team.runs) { run in
                Button {
                    team.selectedRunID = run.id
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: run.presetIcon)
                            .frame(width: 28)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(run.presetName) · \(run.subject)").font(.subheadline.weight(.semibold))
                            Text("\(run.date.formatted(date: .abbreviated, time: .shortened)) · \(run.modelName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        RunStatusIcon(run: run)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Smazat", systemImage: "trash", role: .destructive) { team.delete(run.id) }
                        .disabled(team.isRunning && !run.finished)
                }
            }
        }
    }
}

private struct PresetCard: View {
    let preset: TeamPreset
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: preset.icon).foregroundStyle(.tint)
                Text(preset.name).font(.headline)
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            Text(preset.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(preset.stages.map { $0.roles.map(\.name).joined(separator: " + ") }.joined(separator: "  →  "))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct RunStatusIcon: View {
    let run: TeamRun

    var body: some View {
        if !run.finished {
            ProgressView().controlSize(.small)
        } else if run.error != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

// MARK: - Běh

private struct TeamRunView: View {
    @Environment(AppModel.self) private var app
    @Environment(AgentModel.self) private var agent
    @Environment(TeamModel.self) private var team
    let run: TeamRun

    private var stages: [[TeamRun.Role]] {
        let grouped = Dictionary(grouping: run.roles, by: \.stage)
        return grouped.keys.sorted().map { grouped[$0] ?? [] }
    }

    /// Unikátní návrhy strategií (poslední 3).
    private var proposals: [StrategyProposal] {
        var seen: [String: StrategyProposal] = [:]
        var order: [String] = []
        for p in run.proposals {
            guard let proposal = StrategyProposal(id: p.id, input: p.input, output: p.output) else { continue }
            let key = proposal.underlying + proposal.legs.map(\.jsonString).joined()
            if seen[key] == nil { order.append(key) }
            seen[key] = proposal
        }
        return order.suffix(3).compactMap { seen[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                ForEach(Array(stages.enumerated()), id: \.offset) { index, roles in
                    if let first = roles.first, !first.isFinal {
                        Text("Fáze \(index + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(roles) { role in
                            RoleCard(role: role)
                        }
                    }
                }

                if let final = run.finalRole {
                    FinalReport(role: final)
                }

                if run.finished {
                    ForEach(proposals) { proposal in
                        StrategyProposalCard(proposal: proposal)
                    }
                }

                if let error = run.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                actions
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(run.presetName) · \(run.subject)", systemImage: run.presetIcon)
                .font(.title3.weight(.semibold))
            Text("\(run.date.formatted(date: .abbreviated, time: .shortened)) · \(run.modelName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !run.note.isEmpty {
                Text("„\(run.note)“").font(.footnote).italic().foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if !run.finished {
            Button(role: .destructive) { team.stop() } label: {
                Label("Zastavit tým", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        } else if let preset = TeamPresets.preset(run.presetID) {
            Button {
                team.start(preset, symbol: preset.needsSymbol ? run.subject : "", note: run.note, agent: agent, app: app)
            } label: {
                Label("Spustit znovu", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(team.isRunning || !agent.hasAPIKey)
        }
    }
}

private struct RoleCard: View {
    let role: TeamRun.Role
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: role.icon)
                        .frame(width: 26)
                        .foregroundStyle(.tint)
                    Text(role.name).font(.subheadline.weight(.semibold))
                    Spacer()
                    status
                    if role.status == .done {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(role.status != .done)

            if !role.toolCalls.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(role.toolCalls) { call in
                            HStack(spacing: 4) {
                                if call.running {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: call.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(call.isError ? .red : .green)
                                }
                                Text(ToolChip.title(for: call.name)).fontWeight(.medium)
                                if !call.detail.isEmpty {
                                    Text(call.detail).foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.tertiarySystemBackground), in: Capsule())
                        }
                    }
                }
            }

            if let error = role.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if expanded, !role.report.isEmpty {
                MarkdownText(text: role.report)
                    .font(.callout)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var status: some View {
        switch role.status {
        case .waiting:
            Text("čeká").font(.caption).foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

private struct FinalReport: View {
    let role: TeamRun.Role

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(role.name, systemImage: role.icon).font(.headline)
                Spacer()
                if role.status == .running { ProgressView().controlSize(.small) }
            }
            if !role.report.isEmpty {
                MarkdownText(text: role.report)
            } else if role.status == .waiting {
                Text("Čeká na závěry týmu…").font(.footnote).foregroundStyle(.secondary)
            } else if let error = role.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor.opacity(0.5)))
    }
}
