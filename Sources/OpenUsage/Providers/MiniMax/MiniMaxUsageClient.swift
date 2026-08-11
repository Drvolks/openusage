import Foundation

struct MiniMaxUsageClient: Sendable {
    /// The global host. MiniMax also runs a mainland-China host (`api.minimaxi.com`) with the same
    /// path; OpenUsage targets the global one only.
    static let remainsURL = URL(string: "https://api.minimax.io/v1/token_plan/remains")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Token Plan quota for the 5-hour rolling window and the weekly window. Answers to a Token Plan
    /// (coding plan) key; a pay-as-you-go API key is rejected.
    func fetchRemains(apiKey: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.remainsURL,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum MiniMaxUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// The request reached MiniMax and returned 200, but the payload carries a business-level failure
    /// in `base_resp` — MiniMax reports most errors that way rather than with an HTTP status.
    case apiError(code: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .apiError(let code, let message):
            if let message, !message.isEmpty {
                return "MiniMax request failed: \(message) (code \(code))."
            }
            return "MiniMax request failed (code \(code))."
        }
    }
}
