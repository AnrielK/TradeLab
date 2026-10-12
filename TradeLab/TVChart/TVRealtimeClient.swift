import Foundation

/// Jeden OHLCV bar tak, jak ho chce graf.
struct Bar: Codable, Equatable {
    let time: Double
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?
}

enum TVError: LocalizedError {
    case badSymbolFormat
    case symbolNotFound(String)
    case seriesError(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .badSymbolFormat:
            return "Symbol musí být ve tvaru BURZA:SYMBOL, např. BINANCE:BTCUSDT"
        case .symbolNotFound(let s):
            return "Symbol „\(s)“ na TradingView neexistuje"
        case .seriesError(let m):
            return "TradingView odmítl sérii: \(m)"
        case .transport(let m):
            return m
        }
    }
}

@MainActor
protocol TVRealtimeClientDelegate: AnyObject {
    /// Historie z prvního `timescale_update` - přijde jednou, hromadně.
    func client(_ client: TVRealtimeClient, didReceiveHistory bars: [Bar])
    /// Živá aktualizace - typicky poslední (rozpracovaný) bar.
    func client(_ client: TVRealtimeClient, didReceiveBar bar: Bar)
    func client(_ client: TVRealtimeClient, didChangeStatus status: String)
    func client(_ client: TVRealtimeClient, didFailWith error: Error)
}

/// Nativní klient pro real-time OHLCV z TradingView.
///
/// Mluví přímo s `wss://data.tradingview.com/socket.io/websocket` - stejným
/// protokolem, jaký používá knihovna `tradingview-scraper` (RealTimeData).
/// Díky tomu není potřeba žádný Python ani lokální server.
///
/// Protokol v kostce:
///  - rámce mají tvar `~m~<délka>~m~<payload>`
///  - payload je buď JSON `{"m": funkce, "p": [parametry]}` nebo heartbeat `~h~<n>`
///  - heartbeat se musí poslat zpátky beze změny, jinak server spojení zavře
@MainActor
final class TVRealtimeClient: NSObject {

    weak var delegate: TVRealtimeClientDelegate?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var quoteSession = ""
    private var chartSession = ""
    private var currentSymbol = ""
    private var didSendHistory = false
    private var isStopping = false

    /// Kolik historických svíček si vyžádat při připojení.
    var historyBarCount: Int = 300
    /// Rozlišení: "1", "5", "15", "60", "240", "1D", "1W", "1M"
    var resolution: String = "1"

    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }

    // MARK: - Veřejné API

    func connect(symbol rawSymbol: String) {
        let symbol = rawSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard symbol.split(separator: ":").count == 2 else {
            delegate?.client(self, didFailWith: TVError.badSymbolFormat)
            return
        }
        stop()
        isStopping = false
        currentSymbol = symbol
        reconnectAttempt = 0
        openSocket()
    }

    func stop() {
        isStopping = true
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        didSendHistory = false
    }

    // MARK: - Spojení

    private func openSocket() {
        didSendHistory = false

        var request = URLRequest(url: URL(string: "wss://data.tradingview.com/socket.io/websocket?from=chart%2F")!)
        // Origin je povinný, jinak server handshake odmítne.
        request.setValue("https://www.tradingview.com", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")

        let ws = session.webSocketTask(with: request)
        task = ws
        ws.resume()

        delegate?.client(self, didChangeStatus: "Připojuji se · \(currentSymbol)")

        quoteSession = Self.randomSession(prefix: "qs_")
        chartSession = Self.randomSession(prefix: "cs_")

        initializeSessions()
        addSymbolToSessions(currentSymbol)
        receiveLoop()
    }

    private func initializeSessions() {
        send("set_auth_token", ["unauthorized_user_token"])
        send("set_locale", ["en", "US"])
        send("chart_create_session", [chartSession, ""])
        send("quote_create_session", [quoteSession])
        send("quote_set_fields", [quoteSession] + Self.quoteFields)
        send("quote_hibernate_all", [quoteSession])
    }

    private func addSymbolToSessions(_ symbol: String) {
        // Server chce symbol jako JSON string uvozený '=' - přesně jak to dělá price.py.
        let resolve: [String: Any] = ["adjustment": "splits", "symbol": symbol]
        guard let data = try? JSONSerialization.data(withJSONObject: resolve),
              let json = String(data: data, encoding: .utf8) else { return }
        let packed = "=" + json

        send("quote_add_symbols", [quoteSession, packed])
        send("resolve_symbol", [chartSession, "sds_sym_1", packed])
        send("create_series", [chartSession, "sds_1", "s1", "sds_sym_1", resolution, historyBarCount, ""])
        send("quote_fast_symbols", [quoteSession, symbol])
        send("quote_hibernate_all", [quoteSession])
    }

    // MARK: - Odesílání

    private func send(_ function: String, _ params: [Any]) {
        guard let task else { return }
        guard let body = try? JSONSerialization.data(
            withJSONObject: ["m": function, "p": params], options: [.withoutEscapingSlashes]),
              let json = String(data: body, encoding: .utf8) else { return }

        let framed = Self.frame(json)
        task.send(.string(framed)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.handleTransportError(error)
            }
        }
    }

    private func sendRaw(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    /// `~m~<délka>~m~<payload>` - délka se počítá v UTF-8 bajtech.
    private static func frame(_ payload: String) -> String {
        "~m~\(payload.utf8.count)~m~\(payload)"
    }

    // MARK: - Příjem

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.isStopping else { return }
                switch result {
                case .failure(let error):
                    self.handleTransportError(error)
                case .success(let message):
                    switch message {
                    case .string(let text): self.handleFrames(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handleFrames(text) }
                    @unknown default: break
                    }
                    self.receiveLoop()
                }
            }
        }
    }

    /// Jedna zpráva může obsahovat víc slepených `~m~` rámců.
    private func handleFrames(_ raw: String) {
        reconnectAttempt = 0
        for payload in Self.splitFrames(raw) {
            if payload.hasPrefix("~h~") {
                // heartbeat - pošli přesně to samé zpátky, jinak nás server odpojí
                sendRaw(Self.frame(payload))
                continue
            }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            handlePacket(obj)
        }
    }

    nonisolated static func splitFrames(_ raw: String) -> [String] {
        var out: [String] = []
        var rest = Substring(raw)
        while let open = rest.range(of: "~m~") {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "~m~"),
                  let length = Int(afterOpen[..<close.lowerBound])
            else { break }

            let body = afterOpen[close.upperBound...]
            // délka je v bajtech, proto krájíme přes UTF-8 view
            let bytes = Array(body.utf8)
            guard bytes.count >= length else { break }
            if let payload = String(bytes: bytes[0..<length], encoding: .utf8) {
                out.append(payload)
                let consumed = payload.utf8.count
                rest = Substring(String(bytes: bytes[consumed...], encoding: .utf8) ?? "")
            } else { break }
        }
        return out
    }

    private func handlePacket(_ packet: [String: Any]) {
        guard let method = packet["m"] as? String else { return }

        switch method {
        case "symbol_error", "critical_error":
            delegate?.client(self, didFailWith: TVError.symbolNotFound(currentSymbol))
            stop()
            return
        case "series_error":
            let detail = (packet["p"] as? [Any])?.compactMap { $0 as? String }.joined(separator: " ") ?? ""
            delegate?.client(self, didFailWith: TVError.seriesError(detail))
            stop()
            return
        case "timescale_update", "du":
            break
        case "series_completed":
            delegate?.client(self, didChangeStatus: "Živě · \(currentSymbol)")
            return
        default:
            return
        }

        let bars = Self.extractBars(from: packet)
        guard !bars.isEmpty else { return }

        if method == "timescale_update" && !didSendHistory {
            didSendHistory = true
            delegate?.client(self, didReceiveHistory: bars)
        } else {
            for bar in bars { delegate?.client(self, didReceiveBar: bar) }
        }
    }

    /// Vytáhne bary z `{"m":"du"|"timescale_update","p":[session,{"sds_1":{"s":[{"v":[t,o,h,l,c,v]}]}}]}`
    nonisolated static func extractBars(from packet: [String: Any]) -> [Bar] {
        guard let p = packet["p"] as? [Any], p.count >= 2,
              let payload = p[1] as? [String: Any],
              let series = payload["sds_1"] as? [String: Any],
              let rows = series["s"] as? [[String: Any]]
        else { return [] }

        return rows.compactMap { row in
            guard let v = row["v"] as? [Any], v.count >= 5 else { return nil }
            let nums = v.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard nums.count >= 5 else { return nil }
            return Bar(time: nums[0], open: nums[1], high: nums[2],
                       low: nums[3], close: nums[4],
                       volume: nums.count > 5 ? nums[5] : nil)
        }
    }

    // MARK: - Chyby a reconnect

    private func handleTransportError(_ error: Error) {
        guard !isStopping else { return }
        task = nil

        reconnectAttempt += 1
        guard reconnectAttempt <= 5 else {
            delegate?.client(self, didFailWith: TVError.transport(
                "Spojení s TradingView se nepodařilo obnovit: \(error.localizedDescription)"))
            return
        }

        let delay = min(pow(2.0, Double(reconnectAttempt)), 30.0)
        delegate?.client(self, didChangeStatus:
            "Spojení přerušeno, obnovuji za \(Int(delay)) s (pokus \(reconnectAttempt)/5)")

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isStopping else { return }
            self.openSocket()
        }
    }

    // MARK: - Pomocné

    private static func randomSession(prefix: String) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyz"
        return prefix + String((0..<12).map { _ in letters.randomElement()! })
    }

    private static let quoteFields = [
        "ch", "chp", "current_session", "description", "local_description",
        "language", "exchange", "fractional", "is_tradable", "lp",
        "lp_time", "minmov", "minmove2", "original_name", "pricescale",
        "pro_name", "short_name", "type", "update_mode", "volume",
        "currency_code", "rchp", "rtc"
    ]
}
