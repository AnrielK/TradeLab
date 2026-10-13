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
            AgentView()
                .tabItem { Label("Agent", systemImage: "sparkles") }
                .tag(AppTab.agent)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .task { await model.refreshRiskFreeRate() }
    }
}
