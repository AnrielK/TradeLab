import SwiftUI
import ClaudeAgent

struct AgentView: View {
    @Environment(AppModel.self) private var app
    @Environment(AgentModel.self) private var agent
    @State private var draft = ""
    @State private var showSettings = false
    @State private var confirmClear = false
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "Jak si vedla NVDA za poslední rok? Trend, volatilita, RSI.",
        "Navrhni bull put spread na SPY s expirací kolem 30 dní a spočítej riziko.",
        "Backtest SMA 50/200 na QQQ za 10 let proti buy & hold.",
        "Zhodnoť moji aktuální opční pozici.",
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if !agent.hasAPIKey {
                            apiKeyCard
                        }
                        if agent.messages.isEmpty {
                            emptyState
                        }
                        ForEach(agent.messages) { message in
                            MessageView(message: message)
                        }
                        if agent.isRunning, agent.runningToolIDs.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Přemýšlím…").font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(.leading, 4)
                        }
                        if let error = agent.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .onChange(of: agent.messages.count) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: agent.isRunning) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { confirmClear = true } label: { Image(systemName: "square.and.pencil") }
                        .disabled(agent.messages.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .confirmationDialog("Začít novou konverzaci?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Smazat konverzaci", role: .destructive) { agent.clear() }
            }
            .sheet(isPresented: $showSettings) {
                AgentSettingsView()
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - Části

    private var apiKeyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Chybí API klíč pro \(agent.provider.displayName)", systemImage: "key.fill")
                .font(.headline)
            Text("Agent volá API \(agent.provider.company) s tvým klíčem. Klíč se uloží jen do Keychainu v tomto iPhonu. V nastavení můžeš přepnout na Claude, ChatGPT nebo Gemini.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Zadat klíč") { showSettings = true }
                .buttonStyle(.glassProminent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Zeptej se na akcie, opce nebo backtest.")
                .font(.title3.weight(.semibold))
            Text("Agent si sám načte ceny, opční řetězce a spočítá strategie nástroji aplikace. Výzkum, ne investiční doporučení.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    agent.send(suggestion, app: app)
                } label: {
                    Text(suggestion)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.glass)
                .disabled(!agent.hasAPIKey || agent.isRunning)
            }
        }
        .padding(.top, 24)
    }

    private var canSend: Bool {
        agent.hasAPIKey && !agent.isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Zeptej se – \(agent.model.name)", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))

            if agent.isRunning {
                Button { agent.stop() } label: {
                    Image(systemName: "stop.fill").frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
            } else {
                Button {
                    agent.send(draft, app: app)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 22, height: 22)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - Zprávy

private struct MessageView: View {
    @Environment(AgentModel.self) private var agent
    let message: Message

    var body: some View {
        switch message.role {
        case .user:
            let text = message.text
            if !text.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    Text(text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        case .assistant:
            let results = agent.toolResults
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(message.content.enumerated()), id: \.offset) { _, block in
                    switch block["type"]?.stringValue {
                    case "text":
                        if let text = block["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            MarkdownText(text: text)
                        }
                    case "tool_use":
                        if let use = Message(role: .assistant, content: [block]).toolUses.first {
                            ToolChip(use: use, result: results[use.id], running: agent.runningToolIDs.contains(use.id))
                        }
                    default:
                        EmptyView()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ToolChip: View {
    let use: ToolUse
    let result: ToolResult?
    let running: Bool
    @State private var expanded = false

    private var title: String {
        switch use.name {
        case "get_quote": return "Cena"
        case "search_symbol": return "Hledání tickeru"
        case "get_watchlist": return "Watchlist"
        case "get_price_history": return "Historie ceny"
        case "get_option_expirations": return "Expirace"
        case "get_option_chain": return "Opční řetězec"
        case "price_option": return "Ocenění opce"
        case "analyze_strategy": return "Analýza strategie"
        case "get_current_position": return "Aktuální pozice"
        case "run_backtest": return "Backtest"
        default: return use.name
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let symbol = use.input["symbol"]?.stringValue { parts.append(symbol.uppercased()) }
        if let expiration = use.input["expiration"]?.stringValue { parts.append(expiration) }
        if let strategy = use.input["strategy"]?.stringValue { parts.append(strategy) }
        if let legs = use.input["legs"]?.arrayValue { parts.append("\(legs.count) noh\(legs.count == 1 ? "a" : (legs.count < 5 ? "y" : ""))") }
        if use.input["apply_to_app"]?.boolValue == true { parts.append("→ aplikace") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    statusIcon
                    Text(title).fontWeight(.semibold)
                    if !detail.isEmpty {
                        Text(detail).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground), in: Capsule())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vstup").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(use.input.jsonString)
                    if let result {
                        Text(result.isError ? "Chyba" : "Výstup").font(.caption2.weight(.semibold))
                            .foregroundStyle(result.isError ? .red : .secondary)
                        Text(result.content.count > 3000 ? String(result.content.prefix(3000)) + "…" : result.content)
                    }
                }
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if running {
            ProgressView().controlSize(.mini)
        } else if let result {
            Image(systemName: result.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(result.isError ? .red : .green)
        } else {
            Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Nastavení

struct AgentSettingsView: View {
    @Environment(AgentModel.self) private var agent
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var customModel = ""

    var body: some View {
        @Bindable var agent = agent
        let provider = agent.provider
        NavigationStack {
            Form {
                Section {
                    Picker("Poskytovatel", selection: $agent.provider) {
                        ForEach(Provider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(agent.isRunning)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Konverzace pokračuje i po přepnutí – nový model dostane celou dosavadní historii.")
                }

                Section {
                    if let masked = agent.maskedAPIKey(for: provider) {
                        LabeledContent("Uložený klíč", value: masked)
                            .monospaced()
                    }
                    SecureField(provider.keyPlaceholder, text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(agent.hasAPIKey ? "Nahradit klíč" : "Uložit klíč") {
                        agent.saveAPIKey(keyDraft, for: provider)
                        keyDraft = ""
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if agent.hasAPIKey {
                        Button("Odebrat klíč", role: .destructive) { agent.removeAPIKey(for: provider) }
                    }
                } header: {
                    Text("API klíč \(provider.company)")
                } footer: {
                    Text("Klíč vytvoříš na \(provider.keyConsole). Ukládá se jen do Keychainu tohoto zařízení a posílá se pouze na \(provider.apiHost).")
                }

                Section {
                    Picker("Model", selection: $agent.modelID) {
                        ForEach(provider.models) { m in
                            VStack(alignment: .leading) {
                                Text(m.name)
                                Text("\(m.id) · \(m.note)").font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(m.id)
                        }
                        if !provider.models.contains(where: { $0.id == agent.modelID }) {
                            VStack(alignment: .leading) {
                                Text(agent.modelID)
                                Text("vlastní model").font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(agent.modelID)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    HStack {
                        TextField("Vlastní ID modelu", text: $customModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())
                        Button("Použít") {
                            agent.modelID = customModel.trimmingCharacters(in: .whitespaces)
                            customModel = ""
                        }
                        .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Když poskytovatel vydá nový model, stačí zadat jeho ID.")
                }

                Section("Spotřeba v této relaci") {
                    LabeledContent("Vstupní tokeny", value: agent.sessionUsage.totalInput.formatted())
                    LabeledContent("Z toho z cache", value: agent.sessionUsage.cacheReadTokens.formatted())
                    LabeledContent("Výstupní tokeny", value: agent.sessionUsage.outputTokens.formatted())
                }
            }
            .navigationTitle("Nastavení agenta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hotovo") { dismiss() }
                }
            }
            .onChange(of: agent.provider) { keyDraft = "" }
        }
    }
}
