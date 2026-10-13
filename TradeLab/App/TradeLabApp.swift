import SwiftUI

@main
struct TradeLabApp: App {
    @State private var model = AppModel()
    @State private var agent = AgentModel()
    @State private var team = TeamModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(agent)
                .environment(team)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            MarketView()
                .tabItem { Label("Trh", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(AppTab.market)
            OptionsHomeView()
                .tabItem { Label("Opce", systemImage: "list.bullet.rectangle") }
                .tag(AppTab.options)
            BacktestView()
                .tabItem { Label("Backtest", systemImage: "testtube.2") }
                .tag(AppTab.backtest)
        }
        .task { await model.refreshRiskFreeRate() }
        .sheet(isPresented: $model.showAgent) {
            AgentView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// Kulaté tlačítko agenta v navigační liště každé záložky.
struct AgentToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.showAgent = true
        } label: {
            Image(systemName: "sparkles")
        }
        .accessibilityLabel("Agent")
    }
}
