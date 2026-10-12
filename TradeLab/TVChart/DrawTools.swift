import Foundation

/// Kreslicí nástroj tak, jak ho zná `chart.html` (shodná `id`).
struct DrawTool: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String       // SF Symbol
}

/// Skupina nástrojů v panelu — stejné dělení jako v mobilním TradingView.
struct ToolGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let tools: [DrawTool]
}

enum DrawTools {

    static let groups: [ToolGroup] = [
        ToolGroup(id: "cursor", title: "Kurzor", tools: [
            DrawTool(id: "cursor", name: "Výběr",        symbol: "cursorarrow"),
            DrawTool(id: "cross",  name: "Kříž natrvalo", symbol: "plus")
        ]),
        ToolGroup(id: "trend", title: "Trendové nástroje", tools: [
            DrawTool(id: "trend", name: "Trendová čára",    symbol: "line.diagonal"),
            DrawTool(id: "ray",   name: "Paprsek",          symbol: "arrow.up.right"),
            DrawTool(id: "arrow", name: "Šipka",            symbol: "arrow.up.right.square"),
            DrawTool(id: "hline", name: "Vodorovná čára",   symbol: "minus"),
            DrawTool(id: "hray",  name: "Vodorovný paprsek", symbol: "arrow.right"),
            DrawTool(id: "vline", name: "Svislá čára",      symbol: "line.3.horizontal.decrease")
        ]),
        ToolGroup(id: "shapes", title: "Tvary", tools: [
            DrawTool(id: "rect",    name: "Obdélník", symbol: "rectangle"),
            DrawTool(id: "ellipse", name: "Elipsa",   symbol: "circle")
        ]),
        ToolGroup(id: "fib", title: "Fibonacci a měření", tools: [
            DrawTool(id: "fib",     name: "Fib retracement", symbol: "square.stack.3d.down.right"),
            DrawTool(id: "measure", name: "Měřítko",         symbol: "ruler")
        ]),
        ToolGroup(id: "misc", title: "Ostatní", tools: [
            DrawTool(id: "brush", name: "Volná kresba", symbol: "scribble"),
            DrawTool(id: "text",  name: "Text",         symbol: "textformat"),
            DrawTool(id: "erase", name: "Guma",         symbol: "eraser")
        ])
    ]

    static let all: [DrawTool] = groups.flatMap(\.tools)

    static func tool(id: String) -> DrawTool? {
        all.first { $0.id == id }
    }

    /// Barvy odpovídají poli COLORS v chart.html.
    static let colors = ["#e0a83c", "#4aa8ff", "#2ea98c", "#e0566b", "#b58cff", "#e6edf3"]
}
