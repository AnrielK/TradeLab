import SwiftUI
import MarketData

struct MarketView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [SymbolMatch] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty {
                    Section("Výsledky hledání") {
                        if results.isEmpty {
                            Text("Nic nenalezeno")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(results) { match in
                            Button {
                                model.addToWatchlist(match.symbol)
                                query = ""
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(match.symbol).font(.headline)
                                        Text(match.name ?? "")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(match.exchange ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "plus.circle")
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }

                Section("Sledované") {
                    ForEach(model.watchlist, id: \.self) { symbol in
                        NavigationLink(value: symbol) {
                            QuoteRow(symbol: symbol, quote: model.quotes[symbol])
                        }
                    }
                    .onDelete { model.removeFromWatchlist(at: $0) }
                    .onMove { model.moveWatchlist(from: $0, to: $1) }
                }
            }
            .navigationTitle("Trh")
            .navigationDestination(for: String.self) { symbol in
                SymbolDetailView(symbol: symbol)
            }
            .searchable(text: $query, prompt: "Hledat ticker nebo firmu")
            .autocorrectionDisabled()
            .onChange(of: query) { _, newValue in
                scheduleSearch(newValue)
            }
            .refreshable { await model.refreshQuotes() }
            .task { await model.refreshQuotes() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { AgentToolbarButton() }
            }
        }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        let client = model.client
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = (try? await client.search(trimmed)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run { results = found }
        }
    }
}

struct QuoteRow: View {
    let symbol: String
    let quote: QuoteSnapshot?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(symbol).font(.headline)
                if let name = quote?.name {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let quote {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(quote.price.usd)
                        .monospacedDigit()
                    if let change = quote.changePercent {
                        Text(change.signedPercent)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.pnl(change))
                    }
                }
            } else {
                ProgressView()
            }
        }
    }
}
