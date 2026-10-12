import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Odešle požadavek na model. Vstup i výstup jsou ve formátu Claude Messages API;
/// transporty OpenAI a Gemini ho převádějí tam a zpět. V testech se nahrazuje maketou.
public protocol MessagesTransport: Sendable {
    func send(_ request: MessagesRequest) async throws -> MessagesResponse
}

/// Společné HTTP: POST JSON, rozparsování chyb a opakování při 429/5xx.
enum JSONPoster {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    static func post(_ url: URL, headers: [String: String], body: JSONValue,
                     session: URLSession = session, maxRetries: Int = 2) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONEncoder().encode(body)

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClaudeAPIError.invalidResponse }
            if (200..<300).contains(http.statusCode) {
                return try JSONDecoder().decode(JSONValue.self, from: data)
            }
            let error = ClaudeAPIError.from(status: http.statusCode, body: data)
            guard error.isRetryable, attempt < maxRetries else { throw error }
            attempt += 1
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? Double(attempt * 2)
            try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 20) * 1_000_000_000))
        }
    }

    static func checkedKey(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClaudeAPIError.missingAPIKey }
        return trimmed
    }
}

/// Claude: `https://api.anthropic.com/v1/messages`.
public struct HTTPMessagesTransport: MessagesTransport {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"

    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        let key = try JSONPoster.checkedKey(apiKey)
        let json = try await JSONPoster.post(Self.endpoint,
                                             headers: ["x-api-key": key, "anthropic-version": Self.apiVersion],
                                             body: request.body)
        return try MessagesResponse(json: json)
    }
}
