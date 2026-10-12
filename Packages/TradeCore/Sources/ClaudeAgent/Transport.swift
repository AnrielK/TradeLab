import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Odešle požadavek na Messages API. V testech se nahrazuje maketou.
public protocol MessagesTransport: Sendable {
    func send(_ request: MessagesRequest) async throws -> MessagesResponse
}

/// Skutečné volání `https://api.anthropic.com/v1/messages`.
public struct HTTPMessagesTransport: MessagesTransport {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"

    private let apiKey: String
    private let session: URLSession
    private let maxRetries: Int

    public init(apiKey: String, session: URLSession? = nil, maxRetries: Int = 2) {
        self.apiKey = apiKey
        self.maxRetries = maxRetries
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
    }

    public func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClaudeAPIError.missingAPIKey }

        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONEncoder().encode(request.body)

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw ClaudeAPIError.invalidResponse }
            if (200..<300).contains(http.statusCode) {
                let json = try JSONDecoder().decode(JSONValue.self, from: data)
                return try MessagesResponse(json: json)
            }
            let error = ClaudeAPIError.from(status: http.statusCode, body: data)
            guard error.isRetryable, attempt < maxRetries else { throw error }
            attempt += 1
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? Double(attempt * 2)
            try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 20) * 1_000_000_000))
        }
    }
}
