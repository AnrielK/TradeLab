import SwiftUI
import ClaudeAgent
import MarketData

enum AgentMode: String, CaseIterable, Identifiable {
    case chat
    case team

    var id: String { rawValue }
    var title: String { self == .chat ? "Chat" : "Tým" }
}

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
        "Zakresli do grafu NVDA silné supporty, rezistence a trendlinie z 1W, 1D a 4H.",
    ]

    @AppStorage("agent.mode") private var mode: AgentMode = .chat

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .chat: chat
                case .team: TeamView(showSettings: $showSettings)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Režim", selection: $mode) {
                        ForEach(AgentMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                if mode == .chat {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { confirmClear = true } label: { Image(systemName: "square.and.pencil") }
                            .disabled(agent.messages.isEmpty)
                    }
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

    private var chat: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if !agent.hasAPIKey {
                            apiKeyCard
                        }
                        if agent.messages.isEmpty {
                            emptyState
                        }
                        let results = agent.toolResults
                        ForEach(Array(agent.messages.enumerated()), id: \.element.id) { index, message in
                            MessageView(message: message)
                            if let drawing = agent.chartDrawing(endingAt: index, results: results) {
                                ChartDrawingCard(info: drawing)
                            }
                            if let proposal = agent.proposal(endingAt: index, results: results) {
                                StrategyProposalCard(proposal: proposal)
                            }
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

struct ToolChip: View {
    let use: ToolUse
    let result: ToolResult?
    let running: Bool
    @State private var expanded = false

    private var title: String { Self.title(for: use.name) }

    static func title(for name: String) -> String {
        switch name {
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
        case "run_options_backtest": return "Opční backtest"
        case "find_levels": return "Hladiny"
        case "draw_on_chart": return "Kreslení do grafu"
        default: return name
        }
    }

    private var detail: String { Self.detail(for: use.input) }

    static func detail(for input: JSONValue) -> String {
        var parts: [String] = []
        if let symbol = input["symbol"]?.stringValue { parts.append(symbol.uppercased()) }
        if let expiration = input["expiration"]?.stringValue { parts.append(expiration) }
        if let strategy = input["strategy"]?.stringValue { parts.append(strategy) }
        if let timeframe = input["timeframe"]?.stringValue { parts.append(timeframe) }
        if let levels = input["levels"]?.arrayValue { parts.append("\(levels.count) hl.") }
        if let lines = input["trendlines"]?.arrayValue { parts.append("\(lines.count) TL") }
        if let fibs = input["fibonacci"]?.arrayValue, !fibs.isEmpty { parts.append("Fib") }
        if let legs = input["legs"]?.arrayValue { parts.append("\(legs.count) noh\(legs.count == 1 ? "a" : (legs.count < 5 ? "y" : ""))") }
        if input["apply_to_app"]?.boolValue == true { parts.append("→ aplikace") }
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

// MARK: - Kresby v grafu

struct ChartDrawingCard: View {
    let info: ChartDrawingInfo
    @State private var showChart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Zakresleno do grafu", systemImage: "chart.line.text.clipboard")
                    .font(.headline)
                Spacer()
                Text(info.tvSymbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                if info.levels > 0 {
                    Label("\(info.levels) hladin", systemImage: "line.horizontal.3")
                }
                if info.trendLines > 0 {
                    Label("\(info.trendLines) trendlinií", systemImage: "line.diagonal")
                }
                if info.fibs > 0 {
                    Label("Fibonacci", systemImage: "square.stack.3d.down.right")
                }
                if !info.timeframes.isEmpty {
                    Text(info.timeframes.joined(separator: " · ")).foregroundStyle(.secondary)
                }
            }
            .font(.footnote)

            Button {
                showChart = true
            } label: {
                Label("Otevřít graf", systemImage: "arrow.up.left.and.arrow.down.right")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)

            Text("Zelená = support, červená = rezistence. Týdenní čáry jsou nejsilnější, 4H čárkované. Kresby najdeš i v seznamu objektů grafu a v detailu tickeru.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor.opacity(0.35)))
        .fullScreenCover(isPresented: $showChart) {
            TVChartScreen(initialSymbol: info.tvSymbol, initialResolution: info.resolution)
        }
    }
}

// MARK: - Návrh strategie

struct StrategyProposalCard: View {
    @Environment(AppModel.self) private var app
    let proposal: StrategyProposal
    @State private var isOpening = false
    @State private var error: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(proposal.name, systemImage: "square.stack.3d.up.fill")
                    .font(.headline)
                Spacer()
                Text(proposal.underlying)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(proposal.legs.enumerated()), id: \.offset) { _, leg in
                    legRow(leg)
                }
            }

            HStack(spacing: 16) {
                if let premium = proposal.netPremium {
                    metric(premium >= 0 ? "Debet" : "Kredit", abs(premium).usdWhole,
                           color: premium >= 0 ? .primary : ChainTheme.long)
                }
                if let maxLoss = proposal.maxLoss {
                    metric("Max. ztráta", value(maxLoss), color: ChainTheme.short)
                }
                if let maxProfit = proposal.maxProfit {
                    metric("Max. zisk", value(maxProfit), color: ChainTheme.long)
                }
                if !proposal.breakevens.isEmpty {
                    metric("BE", proposal.breakevens.map { $0.fixed(2) }.joined(separator: " / "), color: .purple)
                }
            }

            Button {
                open()
            } label: {
                HStack {
                    if isOpening { ProgressView().controlSize(.small) }
                    Label("Otevřít v Opcích", systemImage: "arrow.up.forward.app")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(isOpening)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text("Nahraje nohy s aktuálními kotacemi do builderu a rozbalí expiraci v řetězci.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor.opacity(0.35)))
    }

    private func legRow(_ leg: JSONValue) -> some View {
        let isLong = leg["side"]?.stringValue == "long"
        let type = leg["type"]?.stringValue ?? ""
        let quantity = leg["quantity"]?.intValue ?? 1
        let label: String
        switch type {
        case "call": label = "CALL"
        case "put": label = "PUT"
        default: label = "AKCIE"
        }
        return HStack(spacing: 8) {
            Text("\(isLong ? "+" : "−")\(quantity)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(minWidth: 30)
                .padding(.vertical, 2)
                .background(isLong ? ChainTheme.long : ChainTheme.short, in: Capsule())
            Text(label).font(.caption.weight(.semibold)).frame(width: 44, alignment: .leading)
            if type == "stock" {
                Text(leg["entry_price"]?.doubleValue.map { $0.fixed(2) } ?? "")
            } else {
                Text(leg["strike"]?.doubleValue.map { $0.strikeLabel } ?? "").fontWeight(.semibold)
                Text(expirationLabel(leg["expiration"]?.stringValue)).foregroundStyle(.secondary)
                Spacer()
                if let mid = leg["mid"]?.doubleValue {
                    Text("mid \(mid.fixed(2))").foregroundStyle(.secondary)
                }
            }
        }
        .font(.footnote)
        .monospacedDigit()
    }

    private func metric(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote.weight(.semibold)).foregroundStyle(color).monospacedDigit()
        }
    }

    private func value(_ v: JSONValue) -> String {
        if let d = v.doubleValue { return d.usdWhole }
        return v.stringValue ?? "–"
    }

    private func expirationLabel(_ day: String?) -> String {
        guard let day, let date = AgentToolbox.dayFormatter.date(from: day) else { return day ?? "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d. M. yyyy"
        let days = Int(OptionChain.daysToExpiry(date).rounded())
        return "\(f.string(from: date)) · \(days) d"
    }

    private func open() {
        isOpening = true
        error = nil
        Task {
            defer { isOpening = false }
            do {
                let (strategy, spot) = try await AgentToolbox.buildStrategy(proposal.input, model: app)
                app.openAgentStrategy(strategy, spot: spot)
            } catch {
                self.error = error.localizedDescription
            }
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
